# Deployment Guide

## Part 1: Deploy Fundamental

### Prerequisites

#### AWS Account

- AWS Account with appropriate permissions
- AWS CLI installed and configured
- Active subscription to the **Fundamental Platform** on [AWS Marketplace](https://aws.amazon.com/marketplace). Navigate to the product listing, click **Continue to Subscribe**, and accept the terms. Once the subscription is active, you can proceed with deployment.

#### Networking

The Fundamental platform deploys into its own isolated VPC, but requires a "Consumer" VPC where your client applications will reside.

You must have:

- **Consumer VPC ID**: An existing VPC where your client applications will run
- **Consumer Subnet IDs**: Subnets within that VPC with outbound internet access (to download packages) and connectivity to the Fundamental endpoint

> **Note:** Ensure you have the full VPC ID (e.g., `vpc-0abc123def456789a`) and Subnet ID (e.g., `subnet-0abc123def456789a`).

#### Compute Capacity

Ensure your AWS account has capacity for the following instance types in your deployment region:

| Tier | Recommended | Alternative |
|------|-------------|-------------|
| **API** | `m7i.4xlarge` | `m7i.2xlarge` |
| **Model CPU** | `c7i.48xlarge` | `c7i.24xlarge` |
| **Model GPU** | `p5en.48xlarge` | `p5e.48xlarge` |

### Set Environment Variables

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export DEPLOYMENT_REGION=us-west-1
export FUNDAMENTAL_VERSION=0.1.0
```

> **Supported Regions:** `us-west-1`, `us-east-1`

### 1. Permissions

You have two options for permissions:

#### Option A: Deploy as Admin

If you have access to your AWS account's root user or an IAM user with `AdministratorAccess`, you can deploy directly without additional setup.

#### Option B: Use CloudFormation Service Role

We provide a pre-configured CloudFormation Service Role that allows deployment without needing direct permissions on all underlying AWS resources.

**How it works:**

- You create an IAM role that CloudFormation assumes during deployment
- Users only need permission to run CloudFormation and pass the role
- The role has the permissions required to create the platform resources

**To create the service role:**

1. Download the IAM service role package from:

```
git clone https://github.com/Fundamental-Technologies/fundamental-cookbook.git
```

2. Navigate to the `setup/aws/marketplace/cloudformation-deploy-role` directory:

```bash
cd setup/aws/marketplace/cloudformation-deploy-role
```

3. Run the setup script:

```bash
./create-role.sh
```

4. Note the Role ARN output - you'll use this when deploying.

**What the script creates:**

- IAM Role: `FundamentalPlatform-CFServiceRole`

**User permissions required:**

Users running the deployment need this minimal policy to use the service role:

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

### 2. Required Information

Before deploying, collect the following:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `ConsumerVpc1Id` | VPC ID where your applications will call the API | vpc-0abc123def456 |
| `ConsumerVpc1SubnetIds` | Comma-separated subnet IDs in that VPC | subnet-111,subnet-222 |

### 3. Stack Configuration (Optional)

The platform deploys with sensible defaults, but you can customize the configuration based on your workload requirements.

#### Compute Tiers

The platform consists of three compute tiers:

| Tier | Purpose | Default Instance | Default Count |
|------|---------|-----------------|---------------|
| **API** | Handles incoming API requests | `m7i.4xlarge` | 1 |
| **ModelCPU** | Runs CPU-based model processing and orchestration | `c7i.48xlarge` | 1 |
| **ModelGPU** | Runs GPU-accelerated inference workloads | `p5en.48xlarge` | 1 |

| Parameter | Description |
|-----------|-------------|
| `ApiInstanceType` | Instance type for API tier |
| `ApiDesiredCapacity` | Number of API instances |
| `ModelCpuInstanceType` | Instance type for CPU model tier |
| `ModelCpuDesiredCapacity` | Number of CPU model instances |
| `ModelGpuInstanceType` | Instance type for GPU tier |
| `ModelGpuDesiredCapacity` | Number of GPU instances |

#### Capacity Blocks

For guaranteed GPU capacity, you can use [EC2 Capacity Blocks](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-blocks.html). Capacity Blocks are tied to a specific Availability Zone, so the GPU instances must be launched in that AZ.

| Parameter | Description |
|-----------|-------------|
| `PreferredAvailabilityZone` | The AZ where your Capacity Block is reserved (e.g., `us-west-1a`) |
| `CapacityReservationId` | Your Capacity Block reservation ID (e.g., `cr-1234567890abcdef0`) |

> **Note:** When using Capacity Blocks, the GPU instances will only launch in the specified Availability Zone. Ensure your Capacity Block is active and has sufficient capacity for your `ModelGpuDesiredCapacity`.

### 4. Deploy the Platform

The Fundamental Platform is deployed through your AWS Marketplace subscription.

1. Go to **AWS Marketplace** → **Manage subscriptions** → select **Fundamental Platform**
2. Click **Launch CloudFormation stack**
3. Select your preferred **region** and **version**, then click **Continue to Launch**
4. Under **Launch action**, choose **Launch CloudFormation**
5. Click **Launch**

This opens the CloudFormation console with the template pre-filled. From here:

6. Fill in the parameters from Step 2 (VPC, Subnets, etc.)
7. Customize compute tiers and capacity blocks as needed (see Step 3)
8. If using the service role (Option B), under **Permissions**, select the `FundamentalPlatform-CFServiceRole`
9. Check the box acknowledging IAM resource creation
10. Click **Create stack**

### 5. Verify Deployment

#### A. Verify Root Stack

Ensure the root stack reports `CREATE_COMPLETE`.

**Using AWS Console:**

Go to **CloudFormation** → **Stacks** → select your stack → verify the status shows **CREATE_COMPLETE**.

**Using AWS CLI:**

> **Note:** Replace `<your-stack-name>` with your actual stack name (e.g., `fundamental`).

```bash
aws cloudformation describe-stacks \
  --stack-name <your-stack-name> \
  --region $DEPLOYMENT_REGION \
  --query 'Stacks[0].StackStatus' \
  --output text
```

#### B. Verify Nested Stacks

Fundamental uses nested stacks. Ensure all substacks are healthy.

**Using AWS Console:**

Go to **CloudFormation** → **Stacks** → select your stack → **Resources** tab. All nested stacks (type `AWS::CloudFormation::Stack`) should show **CREATE_COMPLETE**.

**Using AWS CLI:**

> **Note:** Replace `<your-stack-name>` with your actual stack name (e.g., `fundamental`).

```bash
aws cloudformation describe-stack-resources \
  --stack-name <your-stack-name> \
  --region $DEPLOYMENT_REGION \
  --query 'StackResources[?ResourceType==`AWS::CloudFormation::Stack`].ResourceStatus' \
  --output text | tr '\t' '\n' | sort | uniq -c
```

#### C. Verify EC2 Instances

You should see 3 instances running: `api`, `modelcpu`, and `modelgpu`.

**Using AWS Console:**

Go to **EC2** → **Instances** → filter by tag `DeploymentName` = your stack name. Verify 3 instances are in the **Running** state.

**Using AWS CLI:**

> **Note:** Replace `<your-stack-name>` with your actual stack name.

```bash
aws ec2 describe-instances \
  --region $DEPLOYMENT_REGION \
  --filters "Name=tag:DeploymentName,Values=<your-stack-name>" "Name=instance-state-name,Values=running" \
  --query 'length(Reservations[*].Instances[*])' \
  --output text
```

#### D. Note Stack Outputs

**Using AWS Console:**

Go to **CloudFormation** → **Stacks** → select your stack → **Outputs** tab. Note the values listed — you will need these to connect your application.

**Using AWS CLI:**

> **Note:** Replace `<your-stack-name>` with your actual stack name.

```bash
aws cloudformation describe-stacks \
  --stack-name <your-stack-name> \
  --region $DEPLOYMENT_REGION \
  --query 'Stacks[0].Outputs' \
  --output table
```

---

## Part 2: Connect Your Application

To call the Fundamental API from your applications, you need to grant your application IAM permissions to invoke the API.

### Stack Outputs Reference

The deployment provides these outputs for connecting your applications:

| Output | Use Case |
|--------|----------|
| `RestApiEndpoint` | The API URL your application calls |
| `ApiGatewayInvokePolicyArn` | Attach to your existing IAM roles |
| `ApiGatewayExecuteRoleArn` | Use directly if you don't have existing roles |
| `ApiGatewayExecuteInstanceProfileArn` | Attach to EC2 instances |

### Grant API Access

Choose the option that fits your use case:

| Option | When to Use | What to Do |
|--------|-------------|------------|
| **A. Attach Managed Policy** | Your application already has an IAM role | Attach `ApiGatewayInvokePolicyArn` to your existing role |
| **B. Use Provided Role** | You don't have an existing role (Lambda, ECS, etc.) | Use `ApiGatewayExecuteRoleArn` directly |
| **C. Use Instance Profile** | EC2 instances | Attach `ApiGatewayExecuteInstanceProfileArn` when launching |

For a quick test, see [Appendix: Quick Test with EC2](#appendix-quick-test-with-ec2).
 
---

## Troubleshooting

### Stack creation fails with "Access Denied"

- Ensure you're using an admin user or the CloudFormation service role
- If using the service role, verify it was created successfully with `./create-role.sh`

### Stack creation fails with IAM errors

- Ensure you included `--capabilities CAPABILITY_NAMED_IAM` in the CLI command
- Or checked the IAM acknowledgment box in the Console

### Cannot connect to API

- Verify your application's IAM role has the `ApiGatewayInvokePolicyArn` policy attached (or is using the provided role)
- Ensure your application is running in the VPC/subnets you specified during deployment

---

## Appendix: Quick Test with EC2

This section shows how to create a test EC2 instance and verify the deployment works.

### 1. Get Stack Outputs

```bash
# Set your stack name
export STACK_NAME=fundamental

# Get API endpoint
export API_URL=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --region $DEPLOYMENT_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`RestApiEndpoint`].OutputValue' \
  --output text)
echo "API URL: $API_URL"

# Get instance profile ARN for EC2
export INSTANCE_PROFILE_ARN=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --region $DEPLOYMENT_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiGatewayExecuteInstanceProfileArn`].OutputValue' \
  --output text)
echo "Instance Profile ARN: $INSTANCE_PROFILE_ARN"
```

### 2. Create SSH Key Pair

```bash
aws ec2 create-key-pair \
  --key-name fundamental-test-key \
  --region $DEPLOYMENT_REGION \
  --query 'KeyMaterial' \
  --output text > fundamental-test-key.pem

chmod 400 fundamental-test-key.pem
```

### 3. Create Client EC2 Instance

Launch an EC2 in your consumer subnet to interact with the API:

> **Note:** Replace `<your-vpc-id>` and `<your-subnet-id>` with your Consumer VPC and subnet IDs.

```bash
# Get latest Amazon Linux 2023 AMI
export AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 \
  --region $DEPLOYMENT_REGION \
  --query 'Parameter.Value' \
  --output text)

# Create security group (replace <your-vpc-id>)
export CLIENT_SG=$(aws ec2 create-security-group \
  --region $DEPLOYMENT_REGION \
  --group-name fundamental-client-sg \
  --description "Fundamental client access" \
  --vpc-id <your-vpc-id> \
  --query 'GroupId' \
  --output text)

# Note: Replace 0.0.0.0/0 with your CIDR to limit access to the EC2 instances. You can quickly check your
# local IP by running curl -s checkip.amazonaws.com
aws ec2 authorize-security-group-ingress \
  --region $DEPLOYMENT_REGION \
  --group-id $CLIENT_SG \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

# Launch instance (replace <your-subnet-id>)
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.large \
  --subnet-id <your-subnet-id> \
  --security-group-ids $CLIENT_SG \
  --iam-instance-profile Arn=$INSTANCE_PROFILE_ARN \
  --key-name fundamental-test-key \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=fundamental-client}]' \
  --region $DEPLOYMENT_REGION \
  --query 'Instances[0].InstanceId' \
  --output text)

# Wait for instance and get public IP
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $DEPLOYMENT_REGION
export CLIENT_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --region $DEPLOYMENT_REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
echo "Client instance IP: $CLIENT_IP"
```

### 4. SSH into Client Instance

```bash
ssh -i "fundamental-test-key.pem" ec2-user@$CLIENT_IP
```

### 5. Install SDK and Run Test

From the client instance:

```bash
# Install Python and SDK
sudo dnf update -y && sudo dnf install python3.11 python3.11-pip -y
pip3.11 install fundamental-client[aws-marketplace]

# Create test script (replace DEPLOYMENT_REGION and API_URL with your values)
cat << EOF > test_fundamental.py
import numpy as np
import pandas as pd
import fundamental
from fundamental import NEXUSClassifier, FundamentalAWSMarketplaceClient

fundamental.set_client(FundamentalAWSMarketplaceClient(
    aws_region="${DEPLOYMENT_REGION}",
    api_url="${API_URL}"
))

model = NEXUSClassifier(mode="speed")

# Simple test: Input 1 -> Output 0, Input 0 -> Output 1
model.fit(
    X=pd.DataFrame(np.array([[1], [0]])),
    y=pd.Series(np.array([0, 1]))
)
print(f"Trained model ID: {model.trained_model_id_}")

preds = model.predict(pd.DataFrame(np.array([[1], [0]])))
print(f"Predictions: {preds}")
EOF

# Run the test
python3.11 test_fundamental.py
```

**Success Criteria:**

You should see output indicating a `Trained model ID` followed by a prediction array (e.g., `[0, 1]`).