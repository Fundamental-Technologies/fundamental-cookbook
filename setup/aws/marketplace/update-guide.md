# Update Guide

## Updating a Fundamental Platform Deployment (AWS Marketplace + CloudFormation)

This guide walks customers through updating an existing Fundamental Platform deployment that was purchased through AWS Marketplace and deployed via CloudFormation.

### Prerequisites

- An active AWS Marketplace subscription for the Fundamental Platform
- An existing CloudFormation stack deployed from a previous version
- Access to the AWS Management Console with permissions to update CloudFormation stacks

### 1. Get the New Version Details from AWS Marketplace

1. Go to **AWS Marketplace Console** → **Manage Subscriptions** → Find your Fundamental Platform subscription → Click **Launch**

2. In the Launch page:
   - Select the **new version** from the version dropdown
   - Select your **Region** (must match your existing deployment region)
   - Select **Launch with CloudFormation**

3. Copy these values before proceeding:

   > **Important:** Keep these values handy — you will paste them into your CloudFormation stack update.

   - Copy the **Amazon S3 URL** of the CloudFormation template (you will need this in Step 2)
   - Click **Next**
   - Copy the **AmiId** value shown on the page (you will need this in Step 2)

### 2. Update Your CloudFormation Stack

1. Go to the **AWS CloudFormation Console** → Find your existing Fundamental Platform stack → Click **Update**

2. Select **Replace existing template** → Choose **Amazon S3 URL** → Paste the S3 URL you copied in Step 1 → Click **Next**

3. Update the following parameters:

   | Parameter | Action |
   |-----------|--------|
   | `MPS3KeyPrefix` | Select the new value from the dropdown that corresponds to the version you selected in Step 1 |
   | `AmiId` | Paste the AmiId you copied from the Marketplace launch page in Step 1 |

4. Click **Next** through the remaining screens → Review the changes → Acknowledge any IAM capability warnings if prompted → Click **Submit** / **Update stack**

5. Monitor the stack update progress in the CloudFormation **Events** tab. The update may take several minutes depending on which resources are being changed.
