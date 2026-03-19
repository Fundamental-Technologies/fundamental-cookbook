#!/bin/bash
# ==============================================================================
# Fundamental Platform - Delete CloudFormation Service Role
# ==============================================================================
#
# USAGE:
#   ./delete-role.sh [ROLE_NAME]
#
# ==============================================================================

set -e

ROLE_NAME="${1:-FundamentalPlatform-CFServiceRole}"

echo "=============================================="
echo "Deleting CloudFormation Service Role"
echo "=============================================="
echo "Role Name: ${ROLE_NAME}"
echo "=============================================="

# List and delete all inline policies
echo ""
echo "Step 1: Removing inline policies..."
POLICIES=$(aws iam list-role-policies --role-name "${ROLE_NAME}" --query 'PolicyNames' --output text 2>/dev/null || echo "")

for policy in ${POLICIES}; do
  echo "  - Removing: ${policy}"
  aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${policy}"
done

# Delete the role
echo ""
echo "Step 2: Deleting role..."
aws iam delete-role --role-name "${ROLE_NAME}"

echo ""
echo "=============================================="
echo "SUCCESS - Role Deleted"
echo "=============================================="
