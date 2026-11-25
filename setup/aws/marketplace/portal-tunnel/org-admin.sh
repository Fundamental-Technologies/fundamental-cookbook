#!/bin/bash
# ==============================================================================
# Fundamental Platform - Check or reset the portal's org admin login
# ==============================================================================
#
# USAGE:
#   ./org-admin.sh check [region]
#   ./org-admin.sh reset [region]
#
# EXAMPLE:
#   AWS_PROFILE=my-profile ./org-admin.sh check ap-northeast-2
#
# The first portal login is user "admin", password "admin", followed by a
# forced password change. When that is rejected, `check` shows the state of the
# admin user and `reset` sets a new password you type (at least 12 characters,
# must not contain "admin") and clears any login lockout.
#
# Reaches the private EKS API over AWS Systems Manager through one of the
# deployment's worker nodes, so no VPN or bastion is needed. Gives the IAM role
# you run it as cluster-admin access (an EKS access entry) if it has none yet.
# Needs the AWS CLI v2, the Session Manager plugin and kubectl.
# ==============================================================================

set -euo pipefail

MODE="${1:?usage: org-admin.sh <check|reset> [region]}"
export AWS_REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "${AWS_REGION}" ] || { echo "ERROR: set the region (arg 2, or AWS_REGION)"; exit 1; }
case "${MODE}" in check|reset) ;; *) echo "ERROR: mode must be check or reset"; exit 1;; esac

CLUSTER="fundamental-eks"
REALM="fundamental-private"
LOCAL_PORT=18443

for bin in aws session-manager-plugin kubectl; do
  command -v "${bin}" >/dev/null || { echo "ERROR: ${bin} not found on PATH"; exit 1; }
done

CALLER=$(aws sts get-caller-identity --query Arn --output text)
case "${CALLER}" in
  *:assumed-role/*)
    ROLE_NAME=$(echo "${CALLER}" | cut -d/ -f2)
    PRINCIPAL=$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text) ;;
  *) PRINCIPAL="${CALLER}" ;;
esac

if ! aws eks describe-access-entry --cluster-name "${CLUSTER}" --principal-arn "${PRINCIPAL}" >/dev/null 2>&1; then
  echo "==> granting ${PRINCIPAL} cluster-admin on ${CLUSTER}"
  aws eks create-access-entry --cluster-name "${CLUSTER}" --principal-arn "${PRINCIPAL}" >/dev/null
  aws eks associate-access-policy --cluster-name "${CLUSTER}" --principal-arn "${PRINCIPAL}" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster >/dev/null
fi

ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER}" --query cluster.endpoint --output text)
CA=$(aws eks describe-cluster --name "${CLUSTER}" --query cluster.certificateAuthority.data --output text)
HOST="${ENDPOINT#https://}"
NODE=$(aws ec2 describe-instances --query 'Reservations[].Instances[0].InstanceId' --output text \
  --filters "Name=tag:Name,Values=*eks-node*" "Name=instance-state-name,Values=running" | awk '{print $1}')
[ -n "${NODE}" ] && [ "${NODE}" != "None" ] || { echo "ERROR: no running EKS worker node found in ${AWS_REGION}"; exit 1; }

WORK=$(mktemp -d)
export KUBECONFIG="${WORK}/kubeconfig"
cat > "${KUBECONFIG}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER}
  cluster:
    server: https://127.0.0.1:${LOCAL_PORT}
    tls-server-name: ${HOST}
    certificate-authority-data: ${CA}
users:
- name: ${CLUSTER}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args: [eks, get-token, --cluster-name, ${CLUSTER}, --region, ${AWS_REGION}]
contexts:
- name: ${CLUSTER}
  context: {cluster: ${CLUSTER}, user: ${CLUSTER}}
current-context: ${CLUSTER}
EOF

echo "==> opening a tunnel to the EKS API through worker node ${NODE}"
aws ssm start-session --target "${NODE}" --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${HOST}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}" \
  > "${WORK}/ssm.log" 2>&1 &
SSM_PID=$!
disown
trap 'kill ${SSM_PID} 2>/dev/null; rm -rf "${WORK}"' EXIT
for _ in $(seq 30); do
  (exec 3<>"/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null && break
  sleep 1
done
kubectl -n serving get deploy/auth >/dev/null || { echo "ERROR: cannot reach the cluster"; cat "${WORK}/ssm.log"; exit 1; }

# kcadm runs inside the Keycloak pod and logs in with the pod's own admin credentials.
# shellcheck disable=SC2016
KCADM='kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.cfg; }
trap "rm -f /tmp/kcadm.cfg" EXIT
kc config credentials --server http://localhost:8080 --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1'

if [ "${MODE}" = "check" ]; then
  echo "==> setup job"
  kubectl -n serving get jobs -o wide | grep -E 'NAME|auth' || true
  echo "==> admin user in realm ${REALM}"
  kubectl -n serving exec deploy/auth -c keycloak -- bash -c "${KCADM}
    kc get users -r ${REALM} -q username=admin -q exact=true --fields id,username,email,enabled,requiredActions
    ID=\$(kc get users -r ${REALM} -q username=admin -q exact=true --fields id --format csv --noquotes)
    [ -n \"\$ID\" ] && { echo 'lockout:'; kc get attack-detection/brute-force/users/\$ID -r ${REALM}; }
    true"
else
  read -rsp "New password for admin (12+ characters, must not contain 'admin'): " NEWPW; echo
  printf '%s\n' "${NEWPW}" | kubectl -n serving exec -i deploy/auth -c keycloak -- bash -c "${KCADM}
    read -r NEWPW
    kc set-password -r ${REALM} --username admin --new-password \"\$NEWPW\"
    kc delete attack-detection/brute-force/users -r ${REALM}
    ID=\$(kc get users -r ${REALM} -q username=admin -q exact=true --fields id --format csv --noquotes)
    kc update users/\$ID -r ${REALM} -s enabled=true -s 'requiredActions=[]'"
  echo "==> done: sign in to the portal as admin with the new password"
fi
