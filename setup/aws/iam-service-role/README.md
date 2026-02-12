# CloudFormation Service Role for Fundamental Platform

This directory contains IAM policies and scripts to create a CloudFormation Service Role. This role allows CloudFormation to deploy the Fundamental Platform stack on behalf of users who may not have direct permissions on all underlying AWS resources.
Review each policy file before deployment to ensure it meets your organization's security requirements

## How It Works

When you deploy a CloudFormation stack with a service role (`--role-arn`), CloudFormation **assumes that role** to create resources instead of using the deploying user's permissions. This means:

- The **user** only needs permission to:
  - `cloudformation:CreateStack`, `UpdateStack`, `DeleteStack`
  - `iam:PassRole` for the service role
- The **service role** has permissions for all underlying resources (EC2, VPC, S3, etc.)

## Files

```
iam-service-role/
├── trust-policy.json              # Trust policy allowing CloudFormation to assume the role
├── policies/
│   ├── 01-cloudformation-s3.json  # CloudFormation + S3 buckets
│   ├── 02-networking.json         # VPC, Subnets, NAT, IGW, Routes, Endpoints, Security Groups
│   ├── 03-compute.json            # EC2, Launch Templates, ASG, Load Balancers
│   ├── 04-iam.json                # IAM Roles, Instance Profiles (scoped)
│   ├── 05-data-services.json      # KMS, Secrets, AmazonMQ, ElastiCache, SSM, CloudWatch Logs
│   └── 06-api-gateway.json        # REST API Gateway, VPC Links
├── create-role.sh                 # Script to create the role
├── delete-role.sh                 # Script to delete the role
└── README.md
```

## Quick Start

### Option 1: Use the Scripts

```bash
# Create the role
./create-role.sh

# Or with a custom name
./create-role.sh MyCompany-FundamentalPlatform-CFRole
```

### Option 2: Manual AWS CLI

```bash
# 1. Create the role
aws iam create-role \
  --role-name FundamentalPlatform-CFServiceRole \
  --assume-role-policy-document file://trust-policy.json \
  --description "CloudFormation service role for Fundamental Platform"

# 2. Attach each policy
aws iam put-role-policy \
  --role-name FundamentalPlatform-CFServiceRole \
  --policy-name cloudformation \
  --policy-document file://policies/01-cloudformation.json

# ... repeat for each policy file
```

### Option 3: AWS Console

1. Go to **IAM → Roles → Create role**
2. Select **Custom trust policy** and paste contents of `trust-policy.json`
3. Skip adding managed policies
4. Name the role (e.g., `FundamentalPlatform-CFServiceRole`)
5. After creation, go to the role → **Add permissions → Create inline policy**
6. For each file in `policies/`, create an inline policy with that JSON

## Deploying the Stack with the Service Role

Once the role is created, deploy the Fundamental Platform stack:

```bash
aws cloudformation create-stack \
  --stack-name my-fundamental-deployment \
  --template-url https://ec2-marketplace-cloudformation-templates.s3.us-west-1.amazonaws.com/<version>/templates/root-template.yaml \
  --role-arn arn:aws:iam::<account-id>:role/FundamentalPlatform-CFServiceRole \
  --parameters \
    ParameterKey=DeploymentName,ParameterValue=my-deployment \
    ParameterKey=AmiId,ParameterValue=ami-xxxxxxxxx \
    ParameterKey=ConsumerVpc1Id,ParameterValue=vpc-xxxxxxxxx \
    ParameterKey=ConsumerVpc1SubnetIds,ParameterValue=subnet-xxx,subnet-yyy
```

## User Permissions Required

The user deploying the stack needs this minimal IAM policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DeleteStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:GetTemplate"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/FundamentalPlatform-CFServiceRole"
    }
  ]
}
```

## Cleanup

To delete the service role:

```bash
./delete-role.sh

# Or with a custom name
./delete-role.sh MyCompany-FundamentalPlatform-CFRole
```
