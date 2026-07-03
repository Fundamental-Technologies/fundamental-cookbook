# Fundamental Platform - AWS Marketplace

Deploy the Fundamental Platform into your AWS environment via AWS Marketplace and CloudFormation.

## Customer guides

| Resource | Description |
|----------|-------------|
| [Deployment Guide](deployment-guide.md) | Step-by-step instructions for deploying and connecting to the platform (v2.0.0) |
| [Parameters Reference](parameters-reference.md) | Every CloudFormation parameter (required + optional) with defaults, plus a ready-to-edit `params.json` for CLI deploys |
| [Upgrade Guide](update-guide.md) | In-place updates: new bundle + chart versions, and infrastructure/template changes |
| [Phase 2 Extended Bundle Guide](phase2-extended-bundle-guide.md) | Deploy + validation runbook for the Phase 2 extended bundle (in-cluster Keycloak, Postgres, fun-portal, events-handler; API Gateway removed) |
| [Image Bundle Guide](image-bundle-guide.md) | Optional: load the image bundle into your own ECR yourself (to pre-scan images first). By default the platform loads it automatically. |
| [CloudFormation Deploy Role](cloudformation-deploy-role/) | IAM service role for deploying the platform |
| [Cluster Debug Access](cluster-debug-access/) | Temporary `kubectl` access to the private EKS cluster over AWS Systems Manager (no SSH, VPN, or NAT) |
