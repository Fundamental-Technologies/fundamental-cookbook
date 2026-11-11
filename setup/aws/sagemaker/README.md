# NEXUS on Amazon SageMaker - Prerequisites

Run NEXUS as an Amazon SageMaker asynchronous inference endpoint in your own AWS account, from the NEXUS model package on AWS Marketplace, and call it with the Fundamental Python SDK.

## What you'll deploy

A SageMaker model created from the NEXUS Marketplace model package, an async endpoint configuration, and one endpoint on a single GPU instance.

The endpoint runs with network isolation, so it reads requests from and writes results to an S3 bucket you own. The Fundamental SDK serializes your data to that bucket, invokes the endpoint and polls for the result.

Nothing in this deployment calls Fundamental's hosted platform. The only Fundamental service you use is the package registry that serves the SDK.

## Prerequisites

Work through this list in the AWS account that will run the endpoint before you open the quickstart notebook.

### AWS Marketplace subscription

- [ ] The AWS account that will run the endpoint is subscribed to the NEXUS model package on AWS Marketplace. A subscription belongs to one AWS account. If your organization subscribed from a different account (for example a management or procurement account), the endpoint account still needs its own subscription or a license grant from that account.
- [ ] The user or role that subscribes has `aws-marketplace:ViewSubscriptions`, `aws-marketplace:Subscribe` and `aws-marketplace:Unsubscribe`.
- [ ] You have selected your region on the listing's configuration page and copied the model package ARN. The ARN is region specific.

### AWS License Manager

- [ ] The NEXUS license is accepted and active in AWS License Manager in the endpoint account. Open **AWS License Manager > Granted licenses** in the endpoint's region, find the NEXUS license, then accept and activate the grant. Until the grant is active, creating the SageMaker model from the package fails.
- [ ] The user or role that accepts the license has License Manager permissions, at least `license-manager:ListReceivedLicenses`, `license-manager:ListReceivedGrants`, `license-manager:GetGrant`, `license-manager:AcceptGrant` and `license-manager:CreateGrantVersion`.

### IAM

- [ ] A SageMaker execution role that the endpoint runs as. It needs `AmazonSageMakerFullAccess` (or an equivalent scoped policy) and read and write access to your payload bucket.
- [ ] The identity that runs the notebook can call `sagemaker:CreateModel`, `sagemaker:CreateEndpointConfig`, `sagemaker:CreateEndpoint`, `sagemaker:DescribeEndpoint` and the matching delete calls, can pass the execution role (`iam:PassRole`), and can read and write the payload bucket.

### Region, instance type and quota

- [ ] A region where the NEXUS listing is offered and `ml.p5en.48xlarge` is available for SageMaker endpoints. The listing's configuration page shows the supported regions.
- [ ] Service Quotas for SageMaker in that region allow at least one `ml.p5en.48xlarge` for endpoint usage. The default for this instance type is often zero, so request an increase early; approval can take several days.
- [ ] Optional: a SageMaker Training Plan if you want the endpoint pinned to reserved GPU capacity. The notebook shows where to add it.

NEXUS currently supports one instance type, `ml.p5en.48xlarge` (8x NVIDIA H200), and processes one request at a time per instance.

### S3

- [ ] An S3 bucket in the same region as the endpoint. SageMaker uses it for async request and response routing, and the SDK uses it for training payloads and model artifacts.

### Fundamental SDK

- [ ] A Cloudsmith access token from Fundamental. The SDK (`fundamental-client`) is served from Fundamental's private Cloudsmith repository, not from PyPI. Ask your Fundamental contact for a token and keep it out of source control; the notebook reads it from the `CLOUDSMITH_API_KEY` environment variable.
- [ ] Python 3.10 or newer, and `boto3` 1.35.81 or newer.
- [ ] An SDK version that matches the model version on SageMaker. As of November 2026, the SDK 2.x line targets a newer model than the one published to SageMaker, so install the latest 1.x release by pinning below 2:

```bash
pip install --extra-index-url "https://token:${CLOUDSMITH_API_KEY}@dl.cloudsmith.io/basic/fundamental/fundamental-client/python/simple/" "fundamental-client[sagemaker]<2"
```

When the newer model reaches the SageMaker listing, Fundamental will confirm when to move to SDK 2.x. Without the `<2` pin the registry may report the 2.x release as unavailable.

## Deploy

With the checklist complete, follow the [NEXUS on Amazon SageMaker Quickstart](../../../examples/nexus_sagemaker_quickstart.ipynb). It creates the model, endpoint configuration and endpoint, connects the SDK, trains and predicts on a sample dataset, and tears everything down.

The endpoint bills for as long as it runs, so delete it when you are done.
