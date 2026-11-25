#!/bin/bash
# ==============================================================================
# Fundamental Platform - Laptop tunnel to a private deployment
# ==============================================================================
#
# USAGE:
#   ./start-tunnel.sh <base-domain> <consumer-subnet-id> [region]
#
# EXAMPLE:
#   AWS_PROFILE=my-profile ./start-tunnel.sh nexus.example.com subnet-0abc123 ap-northeast-2
#
# Launches a tiny relay instance in the consumer VPC (reused on re-runs), points
# fundamental-{api,portal,keycloak,grafana}.<base-domain> at 127.0.0.1 in
# /etc/hosts, and forwards local port 443 to the deployment over AWS Systems
# Manager. Keep it running, then open https://fundamental-portal.<base-domain>.
# The subnet needs a route to SSM (internet gateway with public IP, NAT, or SSM
# VPC endpoints). Needs the AWS CLI v2 and the Session Manager plugin.
# Tear down with ./stop-tunnel.sh.
# ==============================================================================

set -euo pipefail

BASE_DOMAIN="${1:?usage: start-tunnel.sh <base-domain> <consumer-subnet-id> [region]}"
SUBNET_ID="${2:?usage: start-tunnel.sh <base-domain> <consumer-subnet-id> [region]}"
export AWS_REGION="${3:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "${AWS_REGION}" ] || { echo "ERROR: set the region (arg 3, or AWS_REGION)"; exit 1; }

ROLE_NAME="fundamental-tunnel-ssm"
TAG_KEY="fundamental-tunnel"
HOSTS="fundamental-api.${BASE_DOMAIN} fundamental-portal.${BASE_DOMAIN} fundamental-keycloak.${BASE_DOMAIN} fundamental-grafana.${BASE_DOMAIN}"

command -v session-manager-plugin >/dev/null || { echo "ERROR: install the Session Manager plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"; exit 1; }

if ! aws iam get-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "==> creating instance profile ${ROLE_NAME}"
  aws iam create-role --role-name "${ROLE_NAME}" >/dev/null --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "${ROLE_NAME}" --role-name "${ROLE_NAME}"
  sleep 15
fi

IID=$(aws ec2 describe-instances --query 'Reservations[].Instances[0].InstanceId' --output text \
  --filters "Name=tag-key,Values=${TAG_KEY}" "Name=subnet-id,Values=${SUBNET_ID}" "Name=instance-state-name,Values=pending,running" | awk '{print $1}')
if [ -z "${IID}" ] || [ "${IID}" = "None" ]; then
  echo "==> launching relay instance in ${SUBNET_ID}"
  IID=$(aws ec2 run-instances \
    --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --instance-type t3.micro --subnet-id "${SUBNET_ID}" --associate-public-ip-address \
    --iam-instance-profile "Name=${ROLE_NAME}" --metadata-options HttpTokens=required \
    --tag-specifications "ResourceType=instance,Tags=[{Key=${TAG_KEY},Value=true},{Key=Name,Value=${TAG_KEY}}]" \
    --query 'Instances[0].InstanceId' --output text)
fi
echo "==> relay ${IID}, waiting for SSM (1-3 min on first launch)"
ONLINE=""
for _ in $(seq 60); do
  [ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${IID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = "Online" ] && { ONLINE=1; break; }
  sleep 5
done
[ -n "${ONLINE}" ] || { echo "ERROR: ${IID} never registered with SSM; the subnet needs internet (IGW + public IP or NAT) or SSM VPC endpoints"; exit 1; }

if ! grep -q "fundamental-portal.${BASE_DOMAIN}" /etc/hosts; then
  echo "==> adding the hostnames to /etc/hosts (sudo)"
  echo "127.0.0.1 ${HOSTS}" | sudo tee -a /etc/hosts >/dev/null
  if [ "$(uname)" = "Darwin" ]; then sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder; fi
fi
# Linux only lets root bind ports below 1024 by default.
if [ "$(uname)" = "Linux" ]; then sudo sysctl -qw net.ipv4.ip_unprivileged_port_start=443; fi

echo "==> tunnel up: open https://fundamental-portal.${BASE_DOMAIN} (Ctrl-C to close, re-run to reopen)"
exec aws ssm start-session --target "${IID}" --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"fundamental-api.${BASE_DOMAIN}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"443\"]}"
