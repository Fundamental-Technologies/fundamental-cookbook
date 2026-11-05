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
SG_NAME="fundamental-portal-tunnel-sg"
TAG_KEY="fundamental-portal-tunnel"
HOSTS_MARK="fundamental-portal-tunnel ${STACK_NAME}"

usage() { sed -n '6,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
die() { echo "ERROR: $*" >&2; exit 1; }
awsr() { aws --region "${REGION}" "$@"; }

case "${CMD}" in up|status|down) ;; *) usage ;; esac
[ -n "${REGION}" ] || die "set the region (arg 2, or AWS_REGION)"
command -v aws >/dev/null || die "install the AWS CLI v2"
awsr sts get-caller-identity >/dev/null || die "no valid AWS credentials (set AWS_PROFILE; run 'aws sso login' if expired)"

# ------------------------------------------------------------------------------
# Deployment discovery: hostnames and PrivateLink endpoint from the stack
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

  VPC_ID=$(awsr ec2 describe-vpc-endpoints --vpc-endpoint-ids "${ENDPOINT_ID}" \
    --query 'VpcEndpoints[0].VpcId' --output text)
  [ -n "${RELAY_SUBNET}" ] || RELAY_SUBNET=$(awsr ec2 describe-vpc-endpoints --vpc-endpoint-ids "${ENDPOINT_ID}" \
    --query 'VpcEndpoints[0].SubnetIds[0]' --output text)

  # SSM needs a path out: an internet gateway (public IP), a NAT, or SSM VPC endpoints.
  local rt gw
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
    *nat-*) PUBLIC_IP="--no-associate-public-ip-address"; SSM_PATH="NAT gateway" ;;
    *) PUBLIC_IP="--no-associate-public-ip-address"; SSM_PATH="SSM VPC endpoints (required, no internet route)" ;;
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
  echo "Relay subnet: ${RELAY_SUBNET}, SSM via ${SSM_PATH}"
  if [ "${IID}" != "None" ]; then echo "Relay:        ${IID}, SSM $(ssm_ping "${IID}")"; else echo "Relay:        none"; fi
  if grep -qF "${HOSTS_MARK}" /etc/hosts; then echo "/etc/hosts:   set"; else echo "/etc/hosts:   not set"; fi
  if lsof -nP -iTCP:443 -sTCP:LISTEN >/dev/null 2>&1; then echo "Local 443:    listening"; else echo "Local 443:    closed"; fi
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
  for SG_ID in $(awsr ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" \
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
    aws iam detach-role-policy --role-name "${ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
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
if lsof -nP -iTCP:443 -sTCP:LISTEN >/dev/null 2>&1; then
  die "something already listens on local port 443 (an earlier tunnel?). Close it and re-run."
fi

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
echo "   Portal:   https://${PORTAL_HOST}"
echo "   Endpoint: ${ENDPOINT_ID}"
echo "   Subnet:   ${RELAY_SUBNET} (SSM via ${SSM_PATH})"

echo ""
echo "2. Ensuring the relay's SSM role..."
if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --description "Fundamental Platform portal tunnel relay" \
    --tags Key=Platform,Value=fundamental >/dev/null
  aws iam attach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi
if ! aws iam get-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "${ROLE_NAME}" --role-name "${ROLE_NAME}"
fi

echo ""
echo "3. Ensuring the relay security group (no inbound, outbound 443 only)..."
SG_ID=$(awsr ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "${SG_ID}" = "None" ]; then
  SG_ID=$(awsr ec2 create-security-group --group-name "${SG_NAME}" --vpc-id "${VPC_ID}" \
    --description "Fundamental portal tunnel relay (SSM port-forward)" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},{Key=Platform,Value=fundamental}]" \
    --query GroupId --output text)
fi
# Replace the default allow-all egress with 443 only. Both calls are no-ops on re-runs.
awsr ec2 revoke-security-group-egress --group-id "${SG_ID}" \
  --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true
awsr ec2 authorize-security-group-egress --group-id "${SG_ID}" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"SSM and the platform endpoint"}]}]' >/dev/null 2>&1 || true
echo "   ${SG_ID}"

echo ""
echo "4. Finding or launching the relay instance..."
IID=$(find_relay)
if [ "${IID}" = "None" ]; then
  ARCH=$(awsr ec2 describe-instance-types --instance-types "${INSTANCE_TYPE}" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' --output text)
  AMI=$(awsr ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${ARCH}" \
    --query Parameter.Value --output text)
  # A new instance profile takes a few seconds to become usable by EC2.
  for attempt in 1 2 3 4 5 6 7 8; do
    if OUT=$(awsr ec2 run-instances --image-id "${AMI}" --instance-type "${INSTANCE_TYPE}" \
      --subnet-id "${RELAY_SUBNET}" --security-group-ids "${SG_ID}" "${PUBLIC_IP}" \
      --iam-instance-profile "Name=${ROLE_NAME}" \
      --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=fundamental-portal-tunnel},{Key=${TAG_KEY},Value=${STACK_NAME}},{Key=Platform,Value=fundamental}]" \
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
[ "${PING}" = "Online" ] || die "${IID} never registered with SSM. Subnet ${RELAY_SUBNET} needs an internet gateway, a NAT, or ssm/ssmmessages/ec2messages VPC endpoints (or set RELAY_SUBNET)."

echo ""
echo "5. Pointing the platform hostnames at this laptop (sudo)..."
sudo -v
hosts_remove
printf '# >>> %s\n127.0.0.1 %s\n# <<< %s\n' "${HOSTS_MARK}" "${HOSTS}" "${HOSTS_MARK}" | sudo tee -a /etc/hosts >/dev/null
flush_dns

# Port 443 needs root. Resolve credentials as you, then hand only those to the
# root process so it never touches your ~/.aws config or caches.
CREDS=$(aws configure export-credentials --format env) \
  || die "could not read your AWS credentials (AWS CLI v2.9+ needed; run 'aws sso login' if expired)"
eval "${CREDS}"
export AWS_REGION="${REGION}"

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
  env "PATH=${PATH}" aws ssm start-session --target "${IID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${ENDPOINT_DNS}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"443\"]}"
