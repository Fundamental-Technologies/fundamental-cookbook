# Fundamental Platform - Google Cloud

Deploy the Fundamental Platform into your own Google Cloud project. The deployment is Terraform and Helm, driven by one script you run from your machine.

## Customer guides

| Resource | Description |
|----------|-------------|
| [Deployment Guide](deployment-guide.md) | Step-by-step instructions: onboarding, prerequisites, deploying, connecting your network and first login |
| [Prerequisite Check](preflight.sh) | Read-only script that checks your project, permissions, APIs, quota, tools and onboarding before you deploy |
| [Example tfvars](example.tfvars) | Minimal `terraform/<name>.tfvars` with only the three required values |
| [Parameters Reference](parameters-reference.md) | Every deployment variable with type, default and description, plus a ready-to-edit tfvars file |
| [Upgrade Guide](update-guide.md) | In-place upgrades to a new bundle version, chart overlays, and infrastructure changes |
| [Troubleshooting](troubleshooting.md) | Deployment and connection errors and how to fix them |
