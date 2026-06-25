# Deployment Guide

## Part 1: Deploy Fundamental

> **Platform version:** This guide covers **v1.2.0**, the minor release that introduces the fully managed, private EKS tier described below. If you are updating an existing deployment from an earlier (pre-EKS) version, follow the [Update Guide](./update-guide.md) instead. Service-role deployments must refresh the deploy role before updating to v1.2.0 or later.

### Prerequisites

#### AWS Account

- AWS Account with appropriate permissions
- AWS CLI installed and configured
- Active subscription to the **Fundamental Platform** on [AWS Marketplace](https://aws.amazon.com/marketplace). Navigate to the product listing, click **Continue to Subscribe**, and accept the terms. Once the subscription is active, you can proceed with deployment.
- **AutoScaling service-linked role** present in the account. The platform's KMS key grants this role use of the key (so EC2 Auto Scaling can encrypt the compute tiers' EBS volumes), and the key is created before any Auto Scaling group, so the role must already exist. AWS normally creates it on first Auto Scaling use; in a brand-new account, create it once up front:

  ```bash
  aws iam create-service-linked-role --aws-service-name autoscaling.amazonaws.com
  ```

  (If it already exists you'll get `InvalidInput: Service role name ... has been taken` - safe to ignore.) Other service-linked roles (EKS, Elastic Load Balancing) are created automatically while the stack provisions those services, so only this one needs creating in advance.

#### Networking

##### Platform VPC (created automatically by the stack)

The Fundamental platform provisions its own isolated VPC during deployment. You do not need to create or supply a VPC for the platform itself: leave `ExistingVpcId` empty (the default) and the stack creates a new VPC with two private subnets across two Availability Zones, the required route tables, and all VPC endpoints.

**Bringing an existing VPC (optional):** If you want the platform to deploy into a VPC you already control, set `ExistingVpcId` and supply the six accompanying parameters listed in the table below. The existing VPC must meet these requirements:

- Two private subnets in two different Availability Zones (no public IP auto-assignment)
- One route table per subnet, each with a route to a NAT gateway or equivalent egress path
- `EnableDnsHostnames` and `EnableDnsSupport` both enabled on the VPC
- Sufficient CIDR space. The stack's default sizing is a **/16 VPC with two /24 private subnets** (one per AZ); size each private subnet at **/24 or larger** so there is room for EKS pod IPs (assigned from the subnets by the VPC CNI), the internal load-balancer subnets, and the VPC endpoint ENIs

| Parameter | Description |
|-----------|-------------|
| `ExistingVpcId` | ID of the existing VPC (e.g., `vpc-0abc123def456789a`) |
| `ExistingPrivateSubnet1Id` | Private subnet in AZ 1 (e.g., `subnet-0abc123def456789a`) |
| `ExistingPrivateSubnet2Id` | Private subnet in AZ 2 (e.g., `subnet-0def456abc789012b`) |
| `ExistingPrivateRouteTable1Id` | Route table associated with subnet 1 |
| `ExistingPrivateRouteTable2Id` | Route table associated with subnet 2 |
| `ExistingPrivateSubnet1Az` | AZ name for subnet 1 (e.g., `<REGION>a`) |
| `ExistingPrivateSubnet2Az` | AZ name for subnet 2 (e.g., `<REGION>b`) |

If you are deploying into a brand-new account, skip this block entirely and let the stack create the VPC for you.

---

##### Consumer VPC (REQUIRED - for client application access)

The `ConsumerVpc1Id` and `ConsumerVpc1SubnetIds` parameters connect an existing VPC in your account (where your client applications live) to the platform's private API endpoint. **At least one Consumer VPC is required** - the template rejects a deployment with neither set ("At least one Consumer VPC must be configured"). The platform's API is private, so it must have a consumer-side VPC endpoint to be reachable; the platform VPC it creates for itself does not serve that purpose.

If you do not already have a VPC to use, create a minimal one first (see below). You must supply:

- **`ConsumerVpc1Id`**: The VPC ID of the network where your applications will call the platform API (e.g., `vpc-0abc123def456789a`)
- **`ConsumerVpc1SubnetIds`**: Comma-separated subnet IDs within that VPC (e.g., `subnet-111,subnet-222`). These subnets receive a VPC endpoint that routes traffic to the platform privately, so they do not need internet egress.

Up to five Consumer VPCs are supported (`ConsumerVpc1*` through `ConsumerVpc5*`).

**If your account has no existing VPC yet**, create one before deploying. The minimum viable setup for a Consumer VPC is a single private subnet in one AZ:

```bash
# Replace <REGION>, <VPC_CIDR>, and <SUBNET_CIDR> with your values.
# Example: REGION=us-west-1, VPC_CIDR=10.1.0.0/16, SUBNET_CIDR=10.1.1.0/24

VPC_ID=$(aws ec2 create-vpc \
  --cidr-block <VPC_CIDR> \
  --region <REGION> \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region <REGION>
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region <REGION>

# Create a private subnet in the first AZ (e.g., <REGION>a)
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block <SUBNET_CIDR> \
  --availability-zone <REGION>a \
  --region <REGION> \
  --query 'Subnet.SubnetId' --output text)

echo "VPC ID:    $VPC_ID"
echo "Subnet ID: $SUBNET_ID"
```

Pass `$VPC_ID` as `ConsumerVpc1Id` and `$SUBNET_ID` as `ConsumerVpc1SubnetIds` when launching the stack.

> **Note:** The Consumer VPC subnet does not require a NAT gateway or internet gateway. The stack provisions a VPC endpoint inside it so traffic to the platform API stays entirely within the AWS network.

#### Compute Capacity

The platform also provisions a **fully managed, private EKS cluster** for its Kubernetes application workloads. You do not create or operate this cluster, but you must have capacity for its worker nodes.

Ensure your AWS account has capacity for the following instance types in your deployment region:

| Tier | Recommended | Alternative |
|------|-------------|-------------|
| **API** | `m7i.4xlarge` | `m7i.2xlarge` |
| **Model CPU** | `c7i.48xlarge` | `c7i.24xlarge` |
| **Model GPU** | `p5en.48xlarge` | `p5e.48xlarge` |
| **EKS worker nodes** | `m7i.4xlarge` × 2 (one per AZ) | — |
| **EKS additional node** | `m7i.4xlarge` × 1 | `m7i.8xlarge`, `r7i.2xlarge`, `r7i.4xlarge` |

The platform also runs **one additional EKS node** for heavier workloads, on top of the two worker nodes. It is enabled by default; you can turn it off (`EnableEksHeavyNodeGroup=false`) if you do not need the extra capacity. Check with Fundamental before disabling it.

#### Container Images

You do **not** host images, supply registry credentials, or run any manual image step. At deploy time the stack loads every container image and Helm chart into **your own account's Amazon ECR**, and the platform pulls from there. The deployment ends up fully self-contained in your account.

**How it works (automatic - this is the default):**

- Fundamental publishes a single **offline image bundle** (all images + Helm charts), a small `crane` binary, and a `manifest.json` to an S3 bucket your account is granted read access to, all under a `<FunBundleVersion>/` prefix. The `FunBundleVersion` parameter selects which release to deploy; the stack derives the bundle and crane keys from it and reads the chart and image versions from the manifest.
- A native **image-importer Lambda** - created by the stack and running inside the platform VPC - downloads the bundle, creates the ECR repositories in your account, and pushes every image: the Fundamental charts (CRDs, infrastructure, application), the helm-deployer image, and all third-party dependencies (Temporal, database operator, ingress, load-balancer controller, monitoring).
- It runs **before** the rest of the platform, so by the time the Kubernetes workloads start, every image already exists in your ECR. The helm-deployer Lambda and the EKS nodes then pull from your own registry.

Nothing leaves AWS: the bundle download and the image pushes stay inside AWS over VPC endpoints the stack provisions for you (S3 for the bundle, ECR API/Docker for the images). There is no cross-account image pull and no registry credential to manage.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `FunBundleVersion` | The single knob that selects the release. The stack derives the offline bundle and crane binary S3 keys from it and reads the chart and helm-deployer image versions from the bundle's `manifest.json`. Pre-filled for this version; you change it only on an upgrade, using the version string Fundamental provides. | *(version-pinned)* |
| `BundleS3Bucket` | S3 bucket holding the bundle, crane binary, and `manifest.json`. Defaults to the shared bundle bucket your account is granted read access to. | *(shared bundle bucket)* |
| `ImageRegistryUri` | ECR prefix the platform pulls from. Leave empty to use your own account's registry (`<account>.dkr.ecr.<region>.amazonaws.com/fundamental`), which the importer populates. | *(empty)* |
| `SkipImageImport` | Leave `false` for the automatic import. Set `true` only if you have loaded the bundle into your ECR yourself (see the optional pre-scan path below). | `false` |

**Optional - pre-scan the images first.** If your security process requires scanning every image before it reaches your cluster, ask Fundamental for the bundle, load it into your ECR yourself with the included loader, then deploy with `SkipImageImport=true`. The stack then skips the importer and uses the images you already loaded. See the [Image Bundle Guide](./image-bundle-guide.md).

> **Note:** Service-role customers updating from a pre-EKS version must refresh the deploy role before upgrading to v1.2.0 or later. See the [Upgrade Guide](./update-guide.md).

### Set Environment Variables

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export DEPLOYMENT_REGION=us-west-1
export FUNDAMENTAL_VERSION=1.2.0
```

> **Supported Regions:** `us-west-1`, `us-east-1`

### 1. Permissions — Create the CloudFormation Service Role

Always deploy with the provided **CloudFormation Service Role**. CloudFormation assumes this role to create the platform, and the role is granted EKS cluster-admin so the stack can bootstrap the cluster's access entries. Deploying this way (rather than as a plain admin user) is what keeps the EKS access-entry bootstrap reliable, so it is the supported path for every deployment.

**How it works:**

- You create an IAM role that CloudFormation assumes during deployment.
- Users only need permission to run CloudFormation and pass the role.
- The role has the permissions required to create the platform resources.
- You pass this role's ARN both as the stack's `CloudFormationExecutionRoleArn` parameter **and** as the deploy command's `--role-arn` (Console: the **Permissions** field).

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
- Customer-managed policies `FundamentalPlatform-CFServiceRole-*` (one per permission area), attached to the role. (Managed, not inline, because the combined permission set exceeds the 10,240-char inline-policy limit.)

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

The platform creates its own VPC and loads its own images, but a handful of parameters have **no default and must be supplied**. Collect these before launching:

| Parameter | Description | Example | Notes |
|-----------|-------------|---------|-------|
| `AmiId` | Platform AMI for the three EC2 compute tiers | `ami-0abc123def456789a` | Shared with your account by Fundamental (one per region). The Console Launch page pre-fills it; for a CLI deploy, copy it from that page or ask Fundamental. |
| `CloudFormationExecutionRoleArn` | IAM role CloudFormation runs as (also granted EKS cluster-admin to bootstrap access entries) | `arn:aws:iam::123456789012:role/FundamentalPlatform-CFServiceRole` | The service-role ARN from `create-role.sh` (pass the same ARN as `--role-arn`). Keep it **different** from `EksAdminRoleArn`. |
| `ConsumerVpc1Id` | VPC where your applications call the API | `vpc-0abc123def456` | At least one Consumer VPC is required - see [Networking](#networking). |
| `ConsumerVpc1SubnetIds` | Comma-separated subnet IDs in that VPC | `subnet-111,subnet-222` | |
| `DeploymentName` | Name prefix for resources/buckets (default `fundamental`) | `fundamental` | **Max 19 characters** (it is embedded in S3 bucket names bound by the 63-char limit). |

> For the **complete** parameter list (with every default and a ready-to-edit `params.json` for CLI deploys), see the **[Parameters Reference](./parameters-reference.md)**.

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

#### EKS Platform

The platform includes a **private, fully managed EKS cluster** that runs its Kubernetes application workloads. It is created and operated by the stack, has a **private-only API endpoint** (no public access), and runs managed worker nodes across two Availability Zones. The defaults are production-ready, so most deployments need no changes here.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `EksNodeInstanceType` | Instance type for the EKS worker nodes | `m7i.4xlarge` |
| `EksNodeDesiredCapacity` | Number of EKS worker nodes (one per AZ recommended) | `1` |
| `EksNodeMinCapacity` / `EksNodeMaxCapacity` | Auto Scaling bounds for the worker nodes | `1` |
| `EksNodeRootVolumeSize` | Root EBS volume size (GiB) per node | `100` |
| `EnableEksHeavyNodeGroup` | Run one additional EKS node for heavier workloads. Enabled by default; turn off if you do not need the extra capacity (check with Fundamental first). | `true` |
| `EksHeavyNodeInstanceType` | Instance type for the additional node | `m7i.4xlarge` |
| `EksHeavyNodeDesiredCapacity` / `EksHeavyNodeMinCapacity` / `EksHeavyNodeMaxCapacity` | Auto Scaling bounds for the additional node | `1` |
| `EksAdminRoleArn` | *(Optional)* ARN of an IAM role to grant `kubectl` (cluster-admin) access. Leave empty if you don't need direct cluster access. | *(empty)* |

> The EKS control-plane version is fixed internally (currently **1.36**) and is not a customer-settable parameter.

> **Note:** Because the cluster endpoint is private, any `kubectl` access (when `EksAdminRoleArn` is set) must originate from inside the deployment VPC. Direct cluster access is **not** required to use the platform.

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
8. Under **Permissions**, select the `FundamentalPlatform-CFServiceRole` (created in Step 1)
9. Check the box acknowledging IAM resource creation
10. Click **Create stack**

#### Alternative: Deploy via the AWS CLI (`params.json`)

If you prefer to deploy from the CLI (for automation or repeatability), use a `params.json` file instead of the Console form. Copy the **template URL** shown on the Marketplace **Launch CloudFormation** page, fill in the required values, and run `create-stack`:

```bash
aws cloudformation create-stack \
  --stack-name fundamental \
  --region "$DEPLOYMENT_REGION" \
  --template-url "<MARKETPLACE_TEMPLATE_URL>" \
  --parameters file://params.json \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/FundamentalPlatform-CFServiceRole
```

Set `CloudFormationExecutionRoleArn` (in `params.json`) to the **same** service-role ARN you pass as `--role-arn`. A minimal `params.json` and the full parameter list are in the **[Parameters Reference](./parameters-reference.md)**.

> **Deployment time:** the stack takes roughly **45 minutes** to reach `CREATE_COMPLETE` — the private EKS cluster, the image import into your ECR, and the Helm install run sequentially. This is expected; let it run.

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

Go to **CloudFormation** → **Stacks** → select your stack → **Outputs** tab. Note the values listed; you will need these to connect your application.

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

- Verify the `FundamentalPlatform-CFServiceRole` was created successfully with `./create-role.sh`, and that you selected it under **Permissions** (Console) or passed it as `--role-arn` (CLI)
- Confirm `CloudFormationExecutionRoleArn` is set to that same role ARN

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