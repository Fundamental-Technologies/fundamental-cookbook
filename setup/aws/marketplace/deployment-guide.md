# Deployment Guide

## Part 1: Deploy Fundamental

### Prerequisites

#### AWS Account

- AWS Account with appropriate permissions
- AWS CLI installed and configured
- Active subscription to the **Fundamental Platform** on [AWS Marketplace](https://aws.amazon.com/marketplace). In the product listing, choose **Continue to Subscribe** and accept the terms before deploying.
- **AutoScaling service-linked role** present in the account. The platform's KMS key grants this role access so EC2 Auto Scaling can encrypt compute-tier EBS volumes. AWS usually creates the role on first Auto Scaling use; in a brand-new account, create it once up front:

  ```bash
  aws iam create-service-linked-role --aws-service-name autoscaling.amazonaws.com
  ```

  If the role already exists, AWS returns `InvalidInput: Service role name ... has been taken`; you can ignore that. Other service-linked roles, including EKS and Elastic Load Balancing, are created by the stack when needed.

#### Consumer VPC

The platform API is private. To call it, provide at least one consumer VPC: the VPC where your client applications run, or where you plan to run a test client. The stack creates an API Gateway VPC endpoint in the subnets you provide.

You must supply:

- **`ConsumerVpc1Id`**: VPC ID for your client application network (for example, `vpc-0abc123def456789a`).
- **`ConsumerVpc1SubnetIds`**: Comma-separated subnet IDs in that VPC (for example, `subnet-111,subnet-222`). These subnets receive the private API endpoint and do not need internet egress.

> **Note:** The consumer subnet does not require a NAT gateway or internet gateway. API traffic stays on the AWS network through the VPC endpoint.

### Networking

#### Platform VPC (created automatically by the stack)

We recommend letting the stack create the platform networking. By default, it creates a dedicated platform VPC with two private subnets across two Availability Zones, route tables, and the required VPC endpoints.

**Bringing an existing VPC (optional):** Set `ExistingVpcId` only when you want the platform resources placed in an existing VPC. You must also supply the six accompanying parameters listed below. The VPC must have:

- Two private subnets in two different Availability Zones (no public IP auto-assignment)
- One route table per subnet, each with a route to a NAT gateway or equivalent egress path
- `EnableDnsHostnames` and `EnableDnsSupport` both enabled on the VPC
- Sufficient CIDR space. The stack's default sizing is a **/16 VPC with two /24 private subnets** (one per AZ). Each private subnet must be **/24 at minimum**; do **not** use /25 or /26 subnets. These IPs are consumed by EKS pod IPs (assigned from the subnets by the VPC CNI), internal load balancers, and VPC endpoint ENIs. Use larger subnets if you expect to scale.

| Parameter | Description |
|-----------|-------------|
| `ExistingVpcId` | ID of the existing VPC (e.g., `vpc-0abc123def456789a`) |
| `ExistingPrivateSubnet1Id` | Private subnet in AZ 1 (e.g., `subnet-0abc123def456789a`) |
| `ExistingPrivateSubnet2Id` | Private subnet in AZ 2 (e.g., `subnet-0def456abc789012b`) |
| `ExistingPrivateRouteTable1Id` | Route table associated with subnet 1 |
| `ExistingPrivateRouteTable2Id` | Route table associated with subnet 2 |
| `ExistingPrivateSubnet1Az` | AZ name for subnet 1 (e.g., `<REGION>a`) |
| `ExistingPrivateSubnet2Az` | AZ name for subnet 2 (e.g., `<REGION>b`) |

For a new account or standard deployment, skip this block and let the stack create the platform VPC.

### Compute Capacity

Ensure your AWS account has capacity for the following instance types in your deployment region:

| Tier | Recommended | Alternative |
|------|-------------|-------------|
| **API** | `m7i.4xlarge` | `m7i.2xlarge` |
| **Model CPU** | `c7i.48xlarge` | `c7i.24xlarge` |
| **Model GPU** | `p5en.48xlarge` | `p5e.48xlarge` |
| **ModelOrchestration** | `m7i.8xlarge` (1 instance) | `m7i.4xlarge`, `m7i.12xlarge` |
| **EKS worker nodes** | `m7i.4xlarge` × 2 (one per AZ) | — |
| **EKS additional node** | `m7i.4xlarge` × 1 | `m7i.8xlarge`, `r7i.2xlarge`, `r7i.4xlarge` |

### Container Images

You do **not** host images, supply registry credentials, or run any manual image step. The stack loads the required container images and Helm charts into **your own account's Amazon ECR** before workloads start, so the deployment is self-contained in your account.

**How it works (automatic - this is the default):**

- Fundamental publishes separate **infra** and **app** bundles, each with a `manifest.json`, to an S3 bucket your account can read. `FunInfraBundleVersion` and `FunAppBundleVersion` select the release; the stack derives the bundle, manifest, and `crane` keys from those values.
- The stack's image-importer Lambda runs inside the platform VPC before the Kubernetes workloads, creates the needed ECR repositories in your account, and pushes the bundle contents there. The helm-deployer Lambda and EKS nodes then pull from your own registry.

Nothing leaves AWS: the bundle download and the image pushes stay inside AWS over VPC endpoints the stack provisions for you (S3 for the bundle, ECR API/Docker for the images). There is no cross-account image pull and no registry credential to manage.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `FunInfraBundleVersion` | Selects the **infra** bundle release (CRDs + infrastructure + helm-deployer + third-party images). The stack derives the infra bundle/crane/manifest S3 keys from it. Pre-filled for this version; change it on an infra upgrade. | *(version-pinned)* |
| `FunAppBundleVersion` | Selects the **app** bundle release (application + app images). The stack derives the app bundle/manifest S3 keys from it. Pre-filled for this version; change it on an app upgrade. | *(version-pinned)* |
| `BundleS3Bucket` | S3 bucket holding the bundle, crane binary, and `manifest.json`. Defaults to the shared bundle bucket your account is granted read access to. | *(shared bundle bucket)* |
| `ImageRegistryUri` | ECR prefix the platform pulls from. Leave empty to use your own account's registry (`<account>.dkr.ecr.<region>.amazonaws.com/fundamental`), which the importer populates. | *(empty)* |
| `SkipImageImport` | Leave `false` for the automatic import. Set `true` only if you have loaded the bundle into your ECR yourself (see the optional pre-scan path below). | `false` |

**Optional - pre-scan the images first.** If your security process requires scanning every image before it reaches your cluster, ask Fundamental for the bundle, load it into your ECR yourself with the included loader, then deploy with `SkipImageImport=true`. The stack then skips the importer and uses the images you already loaded. See the [Image Bundle Guide](./image-bundle-guide.md).

> **Note:** Service-role customers updating from a pre-EKS version must refresh the deploy role before upgrading to v2.0.0 or later. See the [Upgrade Guide](./update-guide.md).

### Set Environment Variables

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export DEPLOYMENT_REGION=us-west-1
export FUNDAMENTAL_VERSION=2.0.0
```

> **Supported Regions:** `us-west-1`, `us-east-1`

### 1. Permissions — Create the CloudFormation Service Role

Deploy with the provided **CloudFormation Service Role**. CloudFormation assumes this role to create the platform, and the stack grants it EKS cluster-admin so it can bootstrap cluster access entries. This is the supported deployment path.

**How it works:**

- Create the IAM role once.
- Give deployers permission to run CloudFormation and pass that role.
- Pass the same role ARN as the stack's `CloudFormationExecutionRoleArn` parameter and as the deploy command's `--role-arn` (Console: **Permissions**).

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
- Customer-managed policies named `FundamentalPlatform-CFServiceRole-*`, attached to the role.

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

Collect these values before launching the stack:

| Parameter | Description | Example | Notes |
|-----------|-------------|---------|-------|
| `FunInfraBundleVersion` | The **infra** bundle version to deploy. | `2.0.0` | Required. The Console pre-fills it; CLI deploys must pass it explicitly. Use the value Fundamental provides. |
| `FunAppBundleVersion` | The **app** bundle version to deploy. | `1.7.0` | Required. The Console pre-fills it; CLI deploys must pass it explicitly. Use the value Fundamental provides. |
| `AmiId` | Platform AMI for the three EC2 compute tiers | `ami-0abc123def456789a` | Shared with your account by Fundamental (one per region). The Console Launch page pre-fills it; for a CLI deploy, copy it from that page or ask Fundamental. |
| `CloudFormationExecutionRoleArn` | IAM role CloudFormation runs as (also granted EKS cluster-admin to bootstrap access entries) | `arn:aws:iam::123456789012:role/FundamentalPlatform-CFServiceRole` | The service-role ARN from `create-role.sh` (pass the same ARN as `--role-arn`). Keep it **different** from `EksAdminRoleArn`. |
| `ConsumerVpc1Id` | VPC where your applications call the API | `vpc-0abc123def456` | At least one Consumer VPC is required - see [Networking](#networking). |
| `ConsumerVpc1SubnetIds` | Comma-separated subnet IDs in that VPC | `subnet-111,subnet-222` | |
| `DeploymentName` | Name prefix for resources/buckets (default `fundamental`) | `fundamental` | **Max 19 characters** (it is embedded in S3 bucket names bound by the 63-char limit). |

For every parameter and a ready-to-edit `params.json`, see the [Parameters Reference](./parameters-reference.md).

### 3. Stack Configuration (Optional)

The defaults are suitable for a standard deployment. Change these only when you need different capacity, versions, or access settings.

#### Compute Tiers

The platform consists of four EC2 compute tiers:

| Tier | Purpose | Default Instance | Default Count |
|------|---------|-----------------|---------------|
| **API** | Handles incoming API requests | `m7i.4xlarge` | 1 |
| **ModelCPU** | Runs CPU-based model processing and orchestration | `c7i.48xlarge` | 1 |
| **ModelGPU** | Runs GPU-accelerated inference workloads | `p5en.48xlarge` | 1 |
| **ModelOrchestration** | Temporal workflow worker (confidential compute) | `m7i.8xlarge` | 1 |

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ApiInstanceType` | Instance type for API tier | `m7i.4xlarge` |
| `ApiDesiredCapacity` | Number of API instances | `1` |
| `ModelCpuInstanceType` | Instance type for CPU model tier | `c7i.48xlarge` |
| `ModelCpuDesiredCapacity` | Number of CPU model instances | `1` |
| `ModelGpuInstanceType` | Instance type for GPU tier | `p5en.48xlarge` |
| `ModelGpuDesiredCapacity` | Number of GPU instances | `1` |
| `ModelOrchestrationInstanceType` | Instance type for the Temporal worker tier | `m7i.8xlarge` |
| `ModelOrchestrationDesiredCapacity` | Number of Temporal worker instances. Set `0` to disable this tier. | `1` |

#### Optional: Split Train/Predict Tiers

CPU and GPU workloads can be split into separate **train** and **predict** fleets with independent instance types and sizes. When a split tier is enabled, it replaces the corresponding legacy tier for that workload type. Leave these at `false` for a standard deployment.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `EnableModelCpuTrain` / `EnableModelCpuPredict` | Deploy a dedicated ModelCPU train or predict fleet | `false` |
| `ModelCpuTrainInstanceType` / `ModelCpuPredictInstanceType` | Instance types for each fleet | `c7i.48xlarge` |
| `ModelCpuTrainDesiredCapacity` / `ModelCpuPredictDesiredCapacity` | Fleet sizes | `1` |
| `EnableModelGpuTrain` / `EnableModelGpuPredict` | Deploy a dedicated ModelGPU train or predict fleet | `false` |
| `ModelGpuTrainInstanceType` / `ModelGpuPredictInstanceType` | Instance types for each GPU fleet | `p5en.48xlarge` |
| `ModelGpuTrainDesiredCapacity` / `ModelGpuPredictDesiredCapacity` | Fleet sizes | `1` |

#### Capacity Blocks

For guaranteed GPU capacity, you can use [EC2 Capacity Blocks](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-blocks.html). Capacity Blocks are tied to a specific Availability Zone, so the GPU instances must be launched in that AZ.

| Parameter | Description |
|-----------|-------------|
| `PreferredAvailabilityZone` | The AZ where your Capacity Block is reserved (e.g., `us-west-1a`) |
| `CapacityReservationId` | Your Capacity Block reservation ID (e.g., `cr-1234567890abcdef0`) |

> **Note:** When using Capacity Blocks, the GPU instances will only launch in the specified Availability Zone. Ensure your Capacity Block is active and has sufficient capacity for your `ModelGpuDesiredCapacity`.

#### EKS Platform

The stack creates a private EKS cluster for Kubernetes application workloads. Most deployments do not need to change the EKS settings. See the [Parameters Reference](./parameters-reference.md#eks) for the full EKS parameter list, including optional `kubectl` access through `EksAdminRoleArn`.

### 4. Deploy the Platform

Deploy the platform from your AWS Marketplace subscription.

1. Go to **AWS Marketplace** → **Manage subscriptions** → select **Fundamental Platform**
2. Click **Launch CloudFormation stack**
3. Select your preferred **region** and **version**, then click **Continue to Launch**
4. Under **Launch action**, choose **Launch CloudFormation**
5. Click **Launch**

This opens the CloudFormation console with the template pre-filled:

6. Fill in the parameters from Step 2
7. Customize compute tiers and capacity blocks as needed (see Step 3)
8. Under **Permissions**, select the `FundamentalPlatform-CFServiceRole` (created in Step 1)
9. Check the box acknowledging IAM resource creation
10. Click **Create stack**

#### Alternative: Deploy via the AWS CLI (`params.json`)

For automation or repeatable deploys, use a `params.json` file instead of the Console form. Copy the **template URL** from the Marketplace **Launch CloudFormation** page, fill in the required values, and run `create-stack`:

```bash
aws cloudformation create-stack \
  --stack-name fundamental \
  --region "$DEPLOYMENT_REGION" \
  --template-url "<MARKETPLACE_TEMPLATE_URL>" \
  --parameters file://params.json \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/FundamentalPlatform-CFServiceRole
```

Set `CloudFormationExecutionRoleArn` in `params.json` to the same service-role ARN you pass as `--role-arn`. A minimal `params.json` and the full parameter list are in the [Parameters Reference](./parameters-reference.md).

> **Deployment time:** the stack takes roughly **45 minutes** to reach `CREATE_COMPLETE`. The private EKS cluster, image import, and Helm install run sequentially.

### 5. Verify Deployment

#### A. Verify Root Stack

The root stack should report `CREATE_COMPLETE`.

**Using AWS Console:**

Go to **CloudFormation** → **Stacks** → select your stack → verify the status shows **CREATE_COMPLETE**.

**Using AWS CLI:**

Replace `<your-stack-name>` with your stack name, for example `fundamental`.

```bash
aws cloudformation describe-stacks \
  --stack-name <your-stack-name> \
  --region $DEPLOYMENT_REGION \
  --query 'Stacks[0].StackStatus' \
  --output text
```

#### B. Verify Nested Stacks

Fundamental uses nested stacks. Confirm the nested stacks are healthy.

**Using AWS Console:**

Go to **CloudFormation** → **Stacks** → select your stack → **Resources** tab. All nested stacks (type `AWS::CloudFormation::Stack`) should show **CREATE_COMPLETE**.

**Using AWS CLI:**

Replace `<your-stack-name>` with your stack name, for example `fundamental`.

```bash
aws cloudformation describe-stack-resources \
  --stack-name <your-stack-name> \
  --region $DEPLOYMENT_REGION \
  --query 'StackResources[?ResourceType==`AWS::CloudFormation::Stack`].ResourceStatus' \
  --output text | tr '\t' '\n' | sort | uniq -c
```

#### C. Verify EC2 Instances

You should see the EC2 compute tiers running: `api`, `modelcpu`, `modelgpu`, and `modelorchestration` unless you disabled that tier. The private EKS worker nodes also appear as EC2 instances.

**Using AWS Console:**

Go to **EC2** -> **Instances** -> filter by tag `DeploymentName` = your stack name. Verify the expected compute-tier and EKS instances are **Running**.

**Using AWS CLI:**

Replace `<your-stack-name>` with your stack name.

```bash
aws ec2 describe-instances \
  --region $DEPLOYMENT_REGION \
  --filters "Name=tag:DeploymentName,Values=<your-stack-name>" "Name=instance-state-name,Values=running" \
  --query 'length(Reservations[*].Instances[*])' \
  --output text
```

#### D. Note Stack Outputs

**Using AWS Console:**

Go to **CloudFormation** -> **Stacks** -> select your stack -> **Outputs**. Keep these values for application setup.

**Using AWS CLI:**

Replace `<your-stack-name>` with your stack name.

```bash
aws cloudformation describe-stacks \
  --stack-name <your-stack-name> \
  --region $DEPLOYMENT_REGION \
  --query 'Stacks[0].Outputs' \
  --output table
```

### 6. First Login

The platform UI runs on the private hosted zone the stack creates. It resolves inside the platform VPC and your consumer VPCs, and is not reachable from the internet.

Get the portal address from the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name <your-stack-name> \
  --region $DEPLOYMENT_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`PlatformPortalHostName`].OutputValue' \
  --output text
```

From a host in your consumer VPC, open `https://<PlatformPortalHostName>` and sign in as `admin` with the password `admin`. You are asked to set a new password immediately; the initial one is temporary and stops working once you change it.

Use the portal to create API keys and invite the rest of your team.

---

## Part 2: Connect Your Application

To call the Fundamental API, grant your application IAM permission to invoke it.

### Stack Outputs Reference

The stack provides these outputs for application access:

| Output | Use Case |
|--------|----------|
| `RestApiEndpoint` | The API URL your application calls |
| `ApiGatewayInvokePolicyArn` | Attach to your existing IAM roles |
| `ApiGatewayExecuteRoleArn` | Use directly if you don't have existing roles |
| `ApiGatewayExecuteInstanceProfileArn` | Attach to EC2 instances |

### Grant API Access

Choose the option that matches where your application runs:

| Option | When to Use | What to Do |
|--------|-------------|------------|
| **A. Attach Managed Policy** | Your application already has an IAM role | Attach `ApiGatewayInvokePolicyArn` to your existing role |
| **B. Use Provided Role** | You don't have an existing role (Lambda, ECS, etc.) | Use `ApiGatewayExecuteRoleArn` directly |
| **C. Use Instance Profile** | EC2 instances | Attach `ApiGatewayExecuteInstanceProfileArn` when launching |

For a quick test, see [Appendix: Quick Test](#appendix-quick-test).
 
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

## Appendix: Quick Test

There are two ways to verify the deployment end to end. The helper script is the fastest; the manual CLI steps are included for teams that prefer to run each command themselves.

Both paths require your **Cloudsmith token** to install the SDK. The SDK is not on public PyPI; Fundamental provides a token for your organization.

### Option A: Helper script (recommended)

The scripts in [`model-test-access/`](./model-test-access/) launch a small jumpbox in your consumer VPC, install the SDK, and open a shell for a smoke test against the private API. See the directory README for connection options and cleanup details.

**Prerequisites**

- An SSH client, or the AWS CLI **Session Manager plugin** for the default SSM connection mode. The script supports both; see `ACCESS_MODE` in the README.
- A consumer VPC whose `execute-api` endpoint is registered with the API.
- Your Cloudsmith token.

**Run it** from the `model-test-access/` directory:

```bash
CLOUDSMITH_API_KEY=<your-token> AWS_PROFILE=<your-profile> \
  ./start-model-test.sh <stack-name> <region>
```

When the shell opens, run the bundled smoke test:

```bash
nexus-test
```

**Success criteria:** the test prints a `trained_model_id` and an `accuracy`
value. Tear everything down when done:

```bash
AWS_PROFILE=<your-profile> ./stop-model-test.sh <stack-name> <region>
```

### Option B: Do it yourself (AWS CLI)

These are the same steps by hand: launch an EC2 instance in your consumer VPC, attach the API invoke role the stack created, install the SDK, and run a short test.

#### 1. Get stack outputs

```bash
export STACK_NAME=fundamental          # your DeploymentName
export DEPLOYMENT_REGION=us-west-1

export API_URL=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME --region $DEPLOYMENT_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`RestApiEndpoint`].OutputValue' --output text)

export INSTANCE_PROFILE_ARN=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME --region $DEPLOYMENT_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiGatewayExecuteInstanceProfileArn`].OutputValue' --output text)

echo "API URL:          $API_URL"
echo "Instance profile: $INSTANCE_PROFILE_ARN"
```

#### 2. Create an SSH key pair

```bash
aws ec2 create-key-pair --key-name fundamental-test-key \
  --region $DEPLOYMENT_REGION --query 'KeyMaterial' --output text > fundamental-test-key.pem
chmod 400 fundamental-test-key.pem
```

#### 3. Launch a client EC2 in your consumer VPC

Use a **public subnet** of the consumer VPC (the VPC whose `execute-api` endpoint
is registered with the API) so you can SSH in. Replace `<your-vpc-id>` and
`<your-public-subnet-id>`.

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region $DEPLOYMENT_REGION --query 'Parameter.Value' --output text)

# Security group allowing SSH from your IP only
export MY_IP=$(curl -s https://checkip.amazonaws.com)
export CLIENT_SG=$(aws ec2 create-security-group \
  --region $DEPLOYMENT_REGION --group-name fundamental-client-sg \
  --description "Fundamental client access" --vpc-id <your-vpc-id> \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --region $DEPLOYMENT_REGION \
  --group-id $CLIENT_SG --protocol tcp --port 22 --cidr ${MY_IP}/32

export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.large \
  --subnet-id <your-public-subnet-id> --security-group-ids $CLIENT_SG \
  --associate-public-ip-address \
  --iam-instance-profile Arn=$INSTANCE_PROFILE_ARN \
  --key-name fundamental-test-key \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=fundamental-client}]' \
  --region $DEPLOYMENT_REGION --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $DEPLOYMENT_REGION
export CLIENT_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --region $DEPLOYMENT_REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Client IP: $CLIENT_IP"
```

#### 4. SSH into the instance

```bash
ssh -i fundamental-test-key.pem ec2-user@$CLIENT_IP
```

#### 5. Install the SDK and run a test

On the instance, set your values (the `API_URL` printed in step 1, your region,
and your Cloudsmith token), then run:

```bash
export AWS_REGION=<your-region>
export FUNDAMENTAL_API_URL=<your-api-url>

sudo dnf install -y python3.11 python3.11-pip
pip3.11 install \
  --extra-index-url "https://token:<your-cloudsmith-token>@dl.cloudsmith.io/basic/fundamental/fundamental-client/python/simple/" \
  "fundamental-client[aws-marketplace]==0.15.0" numpy pandas

cat > test_fundamental.py <<'EOF'
import os
import numpy as np
import pandas as pd
import fundamental
from fundamental import NEXUSClassifier, FundamentalAWSMarketplaceClient

fundamental.set_client(FundamentalAWSMarketplaceClient(
    aws_region=os.environ["AWS_REGION"],
    api_url=os.environ["FUNDAMENTAL_API_URL"],
))

model = NEXUSClassifier(mode="speed")
model.fit(X=pd.DataFrame(np.array([[1], [0]])), y=pd.Series(np.array([0, 1])))
print("Trained model ID:", model.trained_model_id_)
print("Predictions:", model.predict(pd.DataFrame(np.array([[1], [0]]))))
EOF

python3.11 test_fundamental.py
```

**Success criteria:** a `Trained model ID` followed by a prediction array (e.g.
`[0 1]`).

#### 6. Clean up

```bash
exit   # leave the SSH session
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $DEPLOYMENT_REGION
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID --region $DEPLOYMENT_REGION
aws ec2 delete-security-group --group-id $CLIENT_SG --region $DEPLOYMENT_REGION
aws ec2 delete-key-pair --key-name fundamental-test-key --region $DEPLOYMENT_REGION
```
