#!/bin/bash
# ==============================================================================
# Fundamental Platform - Portal Tunnel
# ==============================================================================
#
# USAGE:
#   ./portal-tunnel.sh up     [region]   open the tunnel (blocks until Ctrl-C)
#   ./portal-tunnel.sh status [region]   show the deployment, relay and local state
#   ./portal-tunnel.sh down   [region]   delete everything `up` created
#
# EXAMPLE:
#   AWS_PROFILE=my-profile ./portal-tunnel.sh up ap-northeast-2
#
# Opens the platform UI (portal, sign-in, API, Grafana) in your laptop's browser
# without a VPN or a host in the consumer VPC. A tiny relay instance in the
# consumer VPC forwards your local port 443 to the platform's PrivateLink
# endpoint over AWS Systems Manager, and /etc/hosts points the four platform
# hostnames at 127.0.0.1. TLS is end to end with the platform's own certificate.
#
# The relay is locked down: no inbound rules, outbound 443 only to the platform
# endpoint and SSM, a role that can only register with SSM and carry sessions,
# IMDSv2 only, an encrypted root volume, and no key pair.
#
# Re-running `up` reuses the relay. Asks for your sudo password once: binding
# port 443 and editing /etc/hosts need root.
# ==============================================================================

set -euo pipefail

CMD="${1:-}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
STACK_NAME="${STACK_NAME:-fundamental}"
CONSUMER="${CONSUMER:-1}"
RELAY_SUBNET="${RELAY_SUBNET:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.micro}"

# IAM is global, so the role is per stack and region: `down` in one region never
# breaks a tunnel in another.
ROLE_NAME="fundamental-portal-tunnel-${STACK_NAME}-${REGION}"
ROLE_NAME="${ROLE_NAME:0:64}"
SG_NAME="fundamental-portal-tunnel-${STACK_NAME}"
TAG_KEY="fundamental-portal-tunnel"
HOSTS_MARK="fundamental-portal-tunnel ${STACK_NAME}"

# The minimum Session Manager needs on the instance: register, then open the
# control and data channels. No Run Command, S3, Parameter Store or logs.
RELAY_POLICY='{"Version":"2012-10-17","Statement":[
  {"Sid":"Register","Effect":"Allow","Action":"ssm:UpdateInstanceInformation","Resource":"*"},
  {"Sid":"Sessions","Effect":"Allow","Action":["ssmmessages:CreateControlChannel","ssmmessages:CreateDataChannel","ssmmessages:OpenControlChannel","ssmmessages:OpenDataChannel"],"Resource":"*"}]}'

usage() { sed -n '6,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
die() { echo "ERROR: $*" >&2; exit 1; }
awsr() { aws --region "${REGION}" "$@"; }

case "${CMD}" in up|status|down) ;; *) usage ;; esac
[ -n "${REGION}" ] || die "set the region (arg 2, or AWS_REGION)"
command -v aws >/dev/null || die "install the AWS CLI v2"
awsr sts get-caller-identity >/dev/null || die "no valid AWS credentials (set AWS_PROFILE; run 'aws sso login' if expired)"

# ------------------------------------------------------------------------------
# Deployment discovery: hostnames, PrivateLink endpoint and SSM path
# ------------------------------------------------------------------------------
discover() {
  local nested
  nested=$(awsr cloudformation describe-stack-resource --stack-name "${STACK_NAME}" \
    --logical-resource-id "ConsumerVpc${CONSUMER}EndpointStack" \
    --query StackResourceDetail.PhysicalResourceId --output text 2>/dev/null) \
    || die "stack ${STACK_NAME} in ${REGION} has no consumer VPC ${CONSUMER} (set STACK_NAME / CONSUMER)"
  output() {
    awsr cloudformation describe-stacks --stack-name "${nested}" \
      --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
  }
  ENDPOINT_ID=$(output ApiEndpointId)
  ENDPOINT_DNS=$(output ApiEndpointDnsName)
  PORTAL_HOST=$(output PortalHostName)
  [ -n "${ENDPOINT_ID}" ] && [ -n "${ENDPOINT_DNS}" ] \
    || die "stack ${STACK_NAME} has no PrivateLink endpoint outputs; this script needs a deployment with the consumer VPC endpoint"
  BASE_DOMAIN="${PORTAL_HOST#fundamental-portal.}"
  [ -n "${BASE_DOMAIN}" ] || die "the deployment has no BaseDomain; the portal needs one"
  HOSTS="fundamental-api.${BASE_DOMAIN} fundamental-portal.${BASE_DOMAIN} fundamental-keycloak.${BASE_DOMAIN} fundamental-grafana.${BASE_DOMAIN}"

  local first_subnet
  # shellcheck disable=SC2016
  read -r VPC_ID first_subnet ENDPOINT_SGS <<<"$(awsr ec2 describe-vpc-endpoints --vpc-endpoint-ids "${ENDPOINT_ID}" \
    --query 'VpcEndpoints[0].[VpcId,SubnetIds[0],join(`,`,Groups[].GroupId)]' --output text)"
  [ -n "${RELAY_SUBNET}" ] || RELAY_SUBNET="${first_subnet}"

  # SSM path, most private first: ssm + ssmmessages VPC endpoints with private
  # DNS (egress only to their security groups), then an internet gateway (the
  # relay gets a public IP), then a NAT. SSM's public IPs are not a fixed range,
  # so the last two need outbound 443 to 0.0.0.0/0.
  local ssm_eps rt gw
  # shellcheck disable=SC2016
  ssm_eps=$(awsr ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" \
    "Name=service-name,Values=com.amazonaws.${REGION}.ssm,com.amazonaws.${REGION}.ssmmessages" \
    "Name=vpc-endpoint-state,Values=available" \
    --query 'VpcEndpoints[?PrivateDnsEnabled].[ServiceName,join(`,`,Groups[].GroupId)]' --output text)
  PUBLIC_IP="--no-associate-public-ip-address"
  SSM_EPS=""
  SSM_SGS=""
  SSM_PATH=""
  if [ "$(cut -f1 <<<"${ssm_eps}" | sort -u | grep -c .)" = 2 ]; then
    SSM_PATH="SSM VPC endpoints"
    SSM_EPS="${ssm_eps}"
    SSM_SGS=$(cut -f2 <<<"${ssm_eps}" | paste -sd, -)
    return
  fi
  rt=$(awsr ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${RELAY_SUBNET}" \
    --query 'RouteTables[0].RouteTableId' --output text)
  [ "${rt}" != "None" ] || rt=$(awsr ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' --output text)
  # shellcheck disable=SC2016
  gw=$(awsr ec2 describe-route-tables --route-table-ids "${rt}" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`] | [0].[GatewayId,NatGatewayId]' --output text)
  case "${gw}" in
    igw-*) PUBLIC_IP="--associate-public-ip-address"; SSM_PATH="internet gateway" ;;
    *nat-*) SSM_PATH="NAT gateway" ;;
  esac
}

find_relay() {
  awsr ec2 describe-instances \
    --filters "Name=tag:${TAG_KEY},Values=${STACK_NAME}" "Name=vpc-id,Values=${VPC_ID}" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[0].InstanceId | [0]' --output text
}

ssm_ping() {
  awsr ssm describe-instance-information --filters "Key=InstanceIds,Values=$1" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true
}

ip2int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }

# Whether IPv4 CIDR $1 contains CIDR $2.
cidr_contains() {
  local outer="${1%/*}" olen="${1#*/}" inner="${2%/*}" ilen="${2#*/}"
  [ "${ilen}" -ge "${olen}" ] \
    && [ $(( $(ip2int "${outer}") >> (32 - olen) )) -eq $(( $(ip2int "${inner}") >> (32 - olen) )) ]
}

# Whether every SSM endpoint accepts 443 from the relay (its security group or
# subnet). Checked before launch so a closed endpoint fails fast, and the script
# never widens your endpoints' rules itself.
ssm_endpoints_admit_relay() {
  local subnet_cidr svc sgs rules ok g c
  subnet_cidr=$(awsr ec2 describe-subnets --subnet-ids "${RELAY_SUBNET}" --query 'Subnets[0].CidrBlock' --output text)
  # shellcheck disable=SC2016
  rules='SecurityGroups[].IpPermissions[?IpProtocol==`-1` || (IpProtocol==`tcp` && FromPort<=`443` && ToPort>=`443`)][]'
  while IFS=$'\t' read -r svc sgs; do
    ok=""
    # shellcheck disable=SC2046
    for g in $(awsr ec2 describe-security-groups --group-ids $(tr ',' ' ' <<<"${sgs}") \
        --query "${rules} | [].UserIdGroupPairs[].GroupId" --output text); do
      [ "${g}" = "$1" ] && ok=1
    done
    # shellcheck disable=SC2046
    for c in $(awsr ec2 describe-security-groups --group-ids $(tr ',' ' ' <<<"${sgs}") \
        --query "${rules} | [].IpRanges[].CidrIp" --output text); do
      cidr_contains "${c}" "${subnet_cidr}" && ok=1
    done
    [ -n "${ok}" ] || { echo "${svc}"; return 1; }
  done <<<"${SSM_EPS}"
}

# A connect test also sees listeners owned by root, which lsof run as you does not.
local_443_open() { (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; }

hosts_remove() {
  grep -qF "${HOSTS_MARK}" /etc/hosts || return 0
  echo "   Removing the platform hostnames from /etc/hosts (sudo)..."
  sudo sed -i.fundamental-tunnel.bak "/^# >>> ${HOSTS_MARK}\$/,/^# <<< ${HOSTS_MARK}\$/d" /etc/hosts
  flush_dns
}

flush_dns() {
  if [ "$(uname)" = "Darwin" ]; then sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder; fi
}

# ------------------------------------------------------------------------------
# status
# ------------------------------------------------------------------------------
if [ "${CMD}" = "status" ]; then
  discover
  IID=$(find_relay)
  echo "Stack:        ${STACK_NAME} (${REGION}), consumer VPC ${CONSUMER}: ${VPC_ID}"
  echo "Portal:       https://${PORTAL_HOST}"
  echo "Endpoint:     ${ENDPOINT_ID} (${ENDPOINT_DNS})"
  echo "Relay subnet: ${RELAY_SUBNET}, SSM via ${SSM_PATH:-none (needs SSM VPC endpoints, an internet gateway or a NAT)}"
  if [ "${IID}" != "None" ]; then echo "Relay:        ${IID}, SSM $(ssm_ping "${IID}")"; else echo "Relay:        none"; fi
  if grep -qF "${HOSTS_MARK}" /etc/hosts; then echo "/etc/hosts:   set"; else echo "/etc/hosts:   not set"; fi
  if local_443_open; then echo "Local 443:    listening"; else echo "Local 443:    closed"; fi
  exit 0
fi

# ------------------------------------------------------------------------------
# down
# ------------------------------------------------------------------------------
if [ "${CMD}" = "down" ]; then
  echo "1. Terminating relay instances..."
  IIDS=$(awsr ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' --output text \
    --filters "Name=tag:${TAG_KEY},Values=${STACK_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped")
  if [ -n "${IIDS}" ]; then
    echo "   ${IIDS}"
    # shellcheck disable=SC2086
    awsr ec2 terminate-instances --instance-ids ${IIDS} >/dev/null
    # shellcheck disable=SC2086
    awsr ec2 wait instance-terminated --instance-ids ${IIDS}
  fi

  echo "2. Deleting the relay security group..."
  for SG_ID in $(awsr ec2 describe-security-groups --filters "Name=tag:${TAG_KEY},Values=${STACK_NAME}" \
      --query 'SecurityGroups[].GroupId' --output text); do
    DELETED=""
    for _ in 1 2 3 4 5 6; do
      awsr ec2 delete-security-group --group-id "${SG_ID}" 2>/dev/null && { DELETED=1; break; }
      sleep 10
    done
    [ -n "${DELETED}" ] || echo "   WARN: ${SG_ID} is still in use; delete it later from the EC2 console"
  done

  echo "3. Deleting the instance profile and role..."
  if aws iam get-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null 2>&1; then
    aws iam remove-role-from-instance-profile --instance-profile-name "${ROLE_NAME}" --role-name "${ROLE_NAME}" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "${ROLE_NAME}"
  fi
  if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    for P in $(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text); do
      aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${P}"
    done
    for P in $(aws iam list-role-policies --role-name "${ROLE_NAME}" --query PolicyNames --output text); do
      aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${P}"
    done
    aws iam delete-role --role-name "${ROLE_NAME}"
  fi

  echo "4. Restoring /etc/hosts..."
  hosts_remove
  echo ""
  echo "Done."
  exit 0
fi

# ------------------------------------------------------------------------------
# up
# ------------------------------------------------------------------------------
command -v session-manager-plugin >/dev/null \
  || die "install the Session Manager plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
local_443_open && die "something already listens on local port 443 (an earlier tunnel?). Close it and re-run."

echo "=============================================="
echo "Fundamental Platform - Portal Tunnel"
echo "  Stack:  ${STACK_NAME}"
echo "  Region: ${REGION}"
echo "=============================================="
echo "Port 443 and /etc/hosts need root; sudo may ask for your password."
sudo -v

echo ""
echo "1. Reading the deployment..."
discover
[ -n "${SSM_PATH}" ] \
  || die "subnet ${RELAY_SUBNET} has no path to SSM. It needs an internet gateway or a NAT, or the VPC needs ssm and ssmmessages endpoints with private DNS (or set RELAY_SUBNET)."
echo "   Portal:   https://${PORTAL_HOST}"
echo "   Endpoint: ${ENDPOINT_ID}"
echo "   Subnet:   ${RELAY_SUBNET} (SSM via ${SSM_PATH})"

echo ""
echo "2. Ensuring the relay's SSM role..."
if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --description "Fundamental Platform portal tunnel relay (Session Manager only)" \
    --tags Key=Platform,Value=fundamental >/dev/null
fi
aws iam put-role-policy --role-name "${ROLE_NAME}" --policy-name session-manager-minimal \
  --policy-document "${RELAY_POLICY}"
if ! aws iam get-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "${ROLE_NAME}" --role-name "${ROLE_NAME}"
fi

echo ""
echo "3. Ensuring the relay security group..."
SG_ID=$(awsr ec2 describe-security-groups \
  --filters "Name=tag:${TAG_KEY},Values=${STACK_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "${SG_ID}" = "None" ]; then
  SG_ID=$(awsr ec2 create-security-group --group-name "${SG_NAME}" --vpc-id "${VPC_ID}" \
    --description "Fundamental portal tunnel relay: no inbound, outbound 443 to the platform and SSM only" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},{Key=${TAG_KEY},Value=${STACK_NAME}},{Key=Platform,Value=fundamental}]" \
    --query GroupId --output text)
fi
# Egress is rebuilt on every run so it always matches the current SSM path, and
# any wider rule (like the default allow-all) is removed. There is never inbound.
if [ "${SSM_PATH}" = "SSM VPC endpoints" ]; then
  PAIRS=""
  for G in $(tr ',' '\n' <<<"${ENDPOINT_SGS},${SSM_SGS}" | grep . | sort -u); do
    PAIRS="${PAIRS}{\"GroupId\":\"${G}\",\"Description\":\"Platform endpoint and SSM endpoints\"},"
  done
  EGRESS="[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"UserIdGroupPairs\":[${PAIRS%,}]}]"
  echo "   Outbound: 443 to the platform and SSM endpoint security groups only"
else
  EGRESS='[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"SSM public endpoints (no fixed IP range) and the platform endpoint"}]}]'
  echo "   Outbound: 443 only (SSM's public endpoints have no fixed IP range)"
fi
OLD_EGRESS=$(awsr ec2 describe-security-groups --group-ids "${SG_ID}" \
  --query 'SecurityGroups[0].IpPermissionsEgress' --output json)
if [ "$(tr -d ' \n' <<<"${OLD_EGRESS}")" != "[]" ]; then
  awsr ec2 revoke-security-group-egress --group-id "${SG_ID}" --ip-permissions "${OLD_EGRESS}" >/dev/null
fi
awsr ec2 authorize-security-group-egress --group-id "${SG_ID}" --ip-permissions "${EGRESS}" >/dev/null
echo "   ${SG_ID}"
if [ "${SSM_PATH}" = "SSM VPC endpoints" ] && ! CLOSED=$(ssm_endpoints_admit_relay "${SG_ID}"); then
  die "the ${CLOSED} VPC endpoint does not accept 443 from the relay. Allow only the relay with:
  aws ec2 authorize-security-group-ingress --region ${REGION} --group-id <that endpoint's security group: ${SSM_SGS}> --protocol tcp --port 443 --source-group ${SG_ID}
then re-run 'up'. ('down' removes what this run created.)"
fi

echo ""
echo "4. Finding or launching the relay instance..."
IID=$(find_relay)
if [ "${IID}" = "None" ]; then
  ARCH=$(awsr ec2 describe-instance-types --instance-types "${INSTANCE_TYPE}" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' --output text)
  AMI=$(awsr ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${ARCH}" \
    --query Parameter.Value --output text)
  ROOT_DEV=$(awsr ec2 describe-images --image-ids "${AMI}" --query 'Images[0].RootDeviceName' --output text)
  TAGS="{Key=Name,Value=fundamental-portal-tunnel},{Key=${TAG_KEY},Value=${STACK_NAME}},{Key=Platform,Value=fundamental}"
  # A new instance profile takes a few seconds to become usable by EC2.
  for attempt in 1 2 3 4 5 6 7 8; do
    if OUT=$(awsr ec2 run-instances --image-id "${AMI}" --instance-type "${INSTANCE_TYPE}" \
      --subnet-id "${RELAY_SUBNET}" --security-group-ids "${SG_ID}" "${PUBLIC_IP}" \
      --iam-instance-profile "Name=${ROLE_NAME}" \
      --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled,InstanceMetadataTags=disabled' \
      --block-device-mappings "DeviceName=${ROOT_DEV},Ebs={Encrypted=true,DeleteOnTermination=true,VolumeType=gp3}" \
      --tag-specifications "ResourceType=instance,Tags=[${TAGS}]" "ResourceType=volume,Tags=[${TAGS}]" \
      --query 'Instances[0].InstanceId' --output text 2>&1); then
      IID="${OUT}"; break
    fi
    case "${OUT}" in
      *iamInstanceProfile*) echo "   instance profile not ready yet, retrying (${attempt}/8)..."; sleep 5 ;;
      *) die "could not launch the relay in ${RELAY_SUBNET} (set INSTANCE_TYPE or RELAY_SUBNET to try another): ${OUT}" ;;
    esac
  done
  case "${IID}" in i-*) ;; *) die "the relay's instance profile never became usable; re-run in a minute" ;; esac
fi
echo "   ${IID}"

echo "   Waiting for SSM (1-3 min on first launch)..."
PING=""
for _ in $(seq 60); do
  PING=$(ssm_ping "${IID}")
  [ "${PING}" = "Online" ] && break
  sleep 5
done
if [ "${PING}" != "Online" ]; then
  if [ "${SSM_PATH}" = "SSM VPC endpoints" ]; then
    die "${IID} never registered with SSM. The security groups of the ssm and ssmmessages VPC endpoints (${SSM_SGS}) must allow inbound 443 from ${SG_ID}."
  fi
  die "${IID} never registered with SSM through the ${SSM_PATH} of subnet ${RELAY_SUBNET}. Check its network ACL and egress firewall, or set RELAY_SUBNET."
fi

echo ""
echo "5. Pointing the platform hostnames at this laptop (sudo)..."
sudo -v
hosts_remove
printf '# >>> %s\n127.0.0.1 %s\n# <<< %s\n' "${HOSTS_MARK}" "${HOSTS}" "${HOSTS_MARK}" | sudo tee -a /etc/hosts >/dev/null
flush_dns

# Port 443 needs root. Resolve credentials as you, then hand only those to the
# root process so it never touches your ~/.aws config or caches. Root gets a
# PATH of just the AWS CLI, the plugin and the system directories.
CREDS=$(aws configure export-credentials --format env) \
  || die "could not read your AWS credentials (AWS CLI v2.9+ needed; run 'aws sso login' if expired)"
eval "${CREDS}"
export AWS_REGION="${REGION}"
AWS_BIN=$(command -v aws)
ROOT_PATH="$(dirname "${AWS_BIN}"):$(dirname "$(command -v session-manager-plugin)"):/usr/bin:/bin"

cat <<EOF

==============================================
Tunnel is opening. In your browser open:

  https://${PORTAL_HOST}

First sign-in: user admin, password admin, then set a new password.
API for the SDK: https://fundamental-api.${BASE_DOMAIN}

Press Ctrl-C here to close the tunnel; re-run 'up' to reopen it.
When finished: ./portal-tunnel.sh down ${REGION}
==============================================

EOF

exec sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_SESSION_TOKEN,AWS_REGION \
  env "PATH=${ROOT_PATH}" "${AWS_BIN}" ssm start-session --target "${IID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${ENDPOINT_DNS}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"443\"]}"
