#!/bin/bash
# ==============================================================================
# Fundamental Platform - Remove the laptop tunnel
# ==============================================================================
#
# USAGE:
#   ./stop-tunnel.sh <base-domain> [region]
#
# Terminates the relay instance(s), deletes the instance profile and role, and
# removes the hostnames from /etc/hosts.
# ==============================================================================

set -euo pipefail

BASE_DOMAIN="${1:?usage: stop-tunnel.sh <base-domain> [region]}"
export AWS_REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "${AWS_REGION}" ] || { echo "ERROR: set the region (arg 2, or AWS_REGION)"; exit 1; }

ROLE_NAME="fundamental-tunnel-ssm"
TAG_KEY="fundamental-tunnel"

IIDS=$(aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' --output text \
  --filters "Name=tag-key,Values=${TAG_KEY}" "Name=instance-state-name,Values=pending,running,stopping,stopped")
if [ -n "${IIDS}" ]; then
  echo "==> terminating ${IIDS}"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids ${IIDS} >/dev/null
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids ${IIDS}
fi

if aws iam get-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "==> deleting instance profile and role ${ROLE_NAME}"
  aws iam remove-role-from-instance-profile --instance-profile-name "${ROLE_NAME}" --role-name "${ROLE_NAME}" || true
  aws iam delete-instance-profile --instance-profile-name "${ROLE_NAME}"
  aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
  aws iam delete-role --role-name "${ROLE_NAME}"
fi

if grep -q "fundamental-portal.${BASE_DOMAIN}" /etc/hosts; then
  echo "==> removing the hostnames from /etc/hosts (sudo)"
  sudo cp /etc/hosts /etc/hosts.fundamental-tunnel.bak
  grep -v "fundamental-portal.${BASE_DOMAIN}" /etc/hosts.fundamental-tunnel.bak | sudo tee /etc/hosts >/dev/null
fi
echo "==> done"
