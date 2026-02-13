#!/bin/bash
# ==============================================================================
# Fundamental Platform - Create CloudFormation Service Role
# ==============================================================================
#
# USAGE:
#   ./create-role.sh [ROLE_NAME]
#
# EXAMPLE:
#   ./create-role.sh FundamentalPlatform-CFServiceRole
#
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_NAME="${1:-FundamentalPlatform-CFServiceRole}"

echo "=============================================="
echo "Creating CloudFormation Service Role"
echo "=============================================="
echo "Role Name: ${ROLE_NAME}"
echo "=============================================="

# Create the IAM role
echo ""
echo "Step 1: Creating IAM role..."
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document "file://${SCRIPT_DIR}/trust-policy.json" \
  --description "CloudFormation service role for deploying Fundamental Platform" \
  --tags Key=Purpose,Value=CloudFormationServiceRole Key=Platform,Value=fundamental

# Attach all policies
echo ""
echo "Step 2: Attaching policies..."

for policy_file in "${SCRIPT_DIR}/policies/"*.json; do
  policy_name=$(basename "${policy_file}" .json | sed 's/^[0-9]*-//')
  echo "  - Attaching: ${policy_name}"
  aws iam put-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-name "${policy_name}" \
    --policy-document "file://${policy_file}"
done

# Get the role ARN
ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)

echo ""
echo "=============================================="
echo "SUCCESS - Role Created"
echo "=============================================="
echo ""
echo "Role ARN:"
echo "  ${ROLE_ARN}"
echo ""
echo "To deploy the Fundamental Platform stack:"
echo ""
echo "  aws cloudformation create-stack \\"
echo "    --stack-name <your-deployment-name> \\"
echo "    --template-url <template-url> \\"
echo "    --role-arn ${ROLE_ARN} \\"
echo "    --parameters ..."
echo ""
