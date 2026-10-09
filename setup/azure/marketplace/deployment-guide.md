# Deployment Guide

## Part 1: Before You Start

Read this part once and gather what it asks for. Nothing here changes your subscription yet.

### Prerequisites

#### Azure Subscription

- An Azure subscription and a **resource group** in the region where you want the platform. An existing resource group works. If you do not have one, Step 1 creates it.
- The identity running the deployment must have the **Owner** role on that resource group.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and signed in.
- Permission in **Microsoft Entra** to create app registrations. You need this once, during identity onboarding ([Step 1](#1-identity-onboarding-one-time)).


> **Note:** The deployment is a standard Azure Resource Manager (ARM) deployment into your own subscription. Fundamental never has access to your subscription.

#### Microsoft Entra Group for Cluster Admins

The platform runs on a private Azure Kubernetes Service (AKS) cluster. Local cluster accounts are disabled. Create or pick a Microsoft Entra group and note its **object ID**. Members of this group get Cluster Admin rights.

#### Consumer Network

The platform is private. There is no public address for the portal or the API. Users and applications reach it through a **Private Endpoint** you create in a virtual network (VNet) you own, after the deployment finishes ([Step 6](#6-connect-your-network)).

Decide which VNet your users and client applications will connect from.

> **Note:** Private Endpoints are only accepted from the subscription you deploy into. To connect from other subscriptions, list them in `additionalConsumerSubscriptionIds` deployment parameter at deploy time.

#### DNS and TLS

The platform is reached on four hostnames under a domain you own. The deployment does not create public DNS records or certificates. Have ready:

- **User domain**: a DNS suffix you control. The four hostnames are created under it:

  | Hostname | Used by |
  |---|---|
  | `fundamental-portal.<userDomain>` | Platform UI |
  | `fundamental-api.<userDomain>` | Platform API and SDK |
  | `fundamental-auth.<userDomain>` | Sign-in |
  | `fundamental-grafana.<userDomain>` | Dashboards (logs and metrics) |

- **TLS certificate (optional)**: the platform serves plain HTTP by default. To serve HTTPS, store a certificate in an Azure Key Vault and pass its resource ID at deploy time. The certificate must:
  - cover `*.<userDomain>` or list all four hostnames,
  - have an exportable private key (PKCS#8),
  - live in a Key Vault that uses **Azure RBAC** permissions and is in the same tenant as the deployment.

  The identity running the deployment needs **Owner** on that Key Vault so the deployment can grant the platform read access to the certificate.

#### Compute Capacity

The platform runs model workloads on virtual machine scale sets, one per tier. Make sure your subscription has quota in the region for the sizes you pick.

| Tier | Recommended | Alternative |
|---|---|---|
| Model CPU | `Standard_D32s_v7` | `Standard_E32s_v7` |
| Model GPU | `Standard_ND96isr_H200_v5` | `Standard_NC80ads_H100_v5`, `Standard_ND96isr_H100_v5` |
| Model orchestration | `Standard_E32s_v7` | `Standard_D32s_v7` |
| AKS user node pool | `Standard_E16as_v7` (3 to 6 nodes) | `Standard_E32as_v7` |

Each tier starts with 1 instance. for zero-downtime upgrade setting, you need quota for **instance count + 1** of each size so a replacement machine can start before the old one is removed.

> [!WARNING]
> Check that the sizes you choose are offered in your region and, if you select availability zones, in those zones. GPU sizes are often only offered in some zones.

### Networking

The deployment creates its own VNet. You do not need to prepare one.

- Address space `172.22.0.0/20`, with a separate pod range `10.244.0.0/16`.
- Change these only if they overlap a network you plan to peer or connect from.
- No inbound public IP is created. The only public IP is an outbound NAT gateway address, used by the platform to reach Azure managed services.

### Container Images and Models

You do not host or pull any images yourself. During deployment, the platform copies Fundamental's container images, charts and model files into an Azure Container Registry created inside your resource group.

---

## Part 2: Deploy Fundamental

Work through the seven steps in order. Each step builds on the one before it.

### 1. Identity Onboarding (One Time)

Before the first deployment, create an identity that lets the platform download Fundamental's release files, and **provide Fundamental its ID**. You do this once per environment.

Set a short name for the deployment. It becomes the prefix of every resource name, so keep it to 12 characters, lowercase letters, digits and hyphens.

```bash
export SUBSCRIPTION_ID=<your-subscription-id>
export DEPLOYMENT_NAME=fundamental
export LOCATION=<azure-region>
export RG=<your-resource-group>           # existing group, or a new name such as rg-fundamental

az account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID=$(az account show --query tenantId -o tsv)
```

#### A. Create the managed identity

If you already have a resource group, skip this command. Otherwise create one:

```bash
az group create -n "$RG" -l "$LOCATION"
```

Then create the managed identity in that resource group:

```bash
az identity create -n "$DEPLOYMENT_NAME-fun-mi-01" -g "$RG"
MI_RESOURCE_ID=$(az identity show -n "$DEPLOYMENT_NAME-fun-mi-01" -g "$RG" --query id -o tsv)
MI_PRINCIPAL_ID=$(az identity show -n "$DEPLOYMENT_NAME-fun-mi-01" -g "$RG" --query principalId -o tsv)
```

The managed identity must be in the resource group you deploy into. The platform attaches it to its machines.

#### B. Create the platform access app registration

Fundamental grants this app registration read access to its release files. A federated credential binds it to the managed identity from Step 1A, so the platform's machines can use that access without any secret or certificate.

```bash
SKR_APP_CLIENT_ID=$(az ad app create \
  --display-name "$DEPLOYMENT_NAME-skr-app" \
  --sign-in-audience AzureADMultipleOrgs \
  --query appId -o tsv)

az ad sp create --id "$SKR_APP_CLIENT_ID"

az ad app federated-credential create --id "$SKR_APP_CLIENT_ID" --parameters "{
  \"name\": \"$DEPLOYMENT_NAME-fun-mi-01\",
  \"issuer\": \"https://login.microsoftonline.com/$TENANT_ID/v2.0\",
  \"subject\": \"$MI_PRINCIPAL_ID\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
```

#### C. Create the deployment app registration

The identity running the deployment must be a multi-tenant app registration that Fundamental grant read access to.

```bash
DEPLOY_APP_CLIENT_ID=$(az ad app create \
  --display-name "$DEPLOYMENT_NAME-deploy-app" \
  --sign-in-audience AzureADMultipleOrgs \
  --query appId -o tsv)

DEPLOY_SP_ID=$(az ad sp create --id "$DEPLOY_APP_CLIENT_ID" --query id -o tsv)

az role assignment create --assignee-object-id "$DEPLOY_SP_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Owner \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG"
```

Add a client secret, certificate or federated credential in the way your organization prefers. If you plan to serve HTTPS, also give this identity Owner on the Key Vault that holds your certificate.

> **Note:** If you already have a multi-tenant deployment identity, reuse it and skip this step. Just make sure it has Owner on the resource group.

#### D. Share the two application IDs with Fundamental

```bash
echo "Platform access app ID: $SKR_APP_CLIENT_ID"
echo "Deployment app ID:      $DEPLOY_APP_CLIENT_ID"
```

> [!IMPORTANT]
> Send both IDs to your Fundamental contact and **wait for Fundamental to confirm** before you deploy. Fundamental will then send back the values you need for [Step 2](#2-required-information).

---

### 2. Required Information

Collect these values before deploying.

| Parameter | Description | Example | Notes |
|---|---|---|---|
| `deploymentName` | Prefix for all resource names | `fundamental` | 2 to 12 chars, lowercase letters, digits, hyphens. Same value you used in Step 1. |
| `computeImageId` | Resource ID of the platform machine image | `/subscriptions/.../versions/2026.09.1` | Provided by Fundamental |
| `Fundamental tenant ID` | Used only on the deploy command | `<fundamental-tenant-id>` | Provided by Fundamental |
| `infraBundleVersion` | Platform bundle version | `1.7.0` | From Fundamental's release notes |
| `appBundleVersion` | Application bundle version | `1.7.0` | From Fundamental's release notes |
| `aksAdminGroupObjectIds` | Entra group that gets cluster admin | `["2f1c...-..."]` | Object ID of the group from the prerequisites |
| `userDomain` | DNS suffix for the hostnames | `customer-fundamental.com` | No scheme, no wildcard |
| `skrMiResourceId` | Managed identity from Step 1A | `/subscriptions/.../userAssignedIdentities/fundamental-fun-mi-01` | `$MI_RESOURCE_ID` |
| `skrAppClientId` | Platform access app client ID from Step 1B | `9d3a...-...` | `$SKR_APP_CLIENT_ID` |


The full parameter list, including every optional setting and a ready-to-edit `params.json`, is in the [Parameters Reference](./parameters-reference.md).

---

### 3. Optional Configuration

The defaults give you one CPU, one GPU and one orchestration machine, a 3 to 6 node AKS pool, HTTP endpoints and the default address space. Change them in `params.json` if you need to:

| Setting | When to change it |
|---|---|
| Machine sizes and counts | See [Compute Tiers](./parameters-reference.md#compute-tiers). |
| Split train and predict tiers | See [Split Tiers](./parameters-reference.md#optional-split-trainpredict-tiers). |
| Availability zones | Your region has zones and you want zonal placement, or a GPU size is only offered in one zone. |
| Capacity reservations or dedicated hosts | You already own reserved capacity for a tier. |
| `userCertificateKeyVaultResourceId` | You want HTTPS. See [DNS and TLS](#dns-and-tls). |
| `additionalConsumerSubscriptionIds` | Users connect from subscriptions other than the one you deploy into. |
| Log and metric retention | You need to keep platform logs or metrics for more than 7 days. |
| Tags | Your organization requires tags on every resource. |

---

### 4. Deploy the Platform

#### A. Deploy with the Azure CLI

Fundamental provides the template file `mainTemplate.json` with each release. Put it next to your `params.json` ([template here](./parameters-reference.md#paramsjson-template-cli-deploy)).

Sign in as the deployment identity from Step 1C, then start the deployment:

```bash
az login --service-principal -u <deployAppClientId> -p <credential> --tenant "$TENANT_ID"
az account set --subscription "$SUBSCRIPTION_ID"

az deployment group create \
  --name fundamental \
  --resource-group "$RG" \
  --template-file mainTemplate.json \
  --parameters @params.json \
  --aux-tenants <fundamental-tenant-id> \
  --no-wait
```

The `--aux-tenants` flag lets Azure read the machine image from Fundamental's gallery. Use the tenant ID Fundamental gave you.

> **Deployment time:** 30 to 60 minutes. It only reports success once every tier is healthy.

Watch progress:

```bash
az deployment group show -g "$RG" -n fundamental --query properties.provisioningState -o tsv
```

Or in the portal: **Resource groups** -> your resource group -> **Deployments** -> `fundamental`.

---

### 5. Verify Deployment

#### A. Check the deployment state

**Using Azure Portal:**

1. Open your resource group and select **Deployments**.
2. The `fundamental` deployment shows **Succeeded**.

**Using Azure CLI:**

```bash
az deployment group show -g "$RG" -n fundamental --query properties.provisioningState -o tsv
```

If it shows **Failed**, list the failed steps:

```bash
az deployment operation group list -g "$RG" -n fundamental \
  --query "[?properties.provisioningState=='Failed'].{step:properties.targetResource.resourceName, error:properties.statusMessage.error.message}" -o table
```

#### B. Note the deployment outputs

```bash
az deployment group show -g "$RG" -n fundamental --query properties.outputs -o json
```

| Output | Use case |
|---|---|
| `privateLinkServiceAlias` | Target when you create your Private Endpoint (Step 6) |
| `privateLinkServiceResourceId` | Same, if your tooling prefers a resource ID |
| `dnsRecords` | The four hostnames you must create |

---

### 6. Connect Your Network

#### A. Create a Private Endpoint

In the VNet your users and applications connect from, create a Private Endpoint that targets the `privateLinkServiceAlias` output:

```bash
az network private-endpoint create \
  -g <consumer-rg> -n fundamental-pe -l "$LOCATION" \
  --vnet-name <consumer-vnet> --subnet <consumer-subnet> \
  --private-connection-resource-id "<privateLinkServiceResourceId>" \
  --connection-name fundamental \
  --manual-request false
```

The connection is approved automatically when the subscription is in `consumerSubscriptionIds`. Note the endpoint's private IP:

```bash
az network private-endpoint show -g <consumer-rg> -n fundamental-pe \
  --query "customDnsConfigs[0].ipAddresses[0]" -o tsv
```

#### B. Create the DNS records

In the DNS your users resolve, create **A records** for the four names in the `dnsRecords` output, all pointing at the Private Endpoint IP. A single wildcard record `*.<userDomain>` also works.

If you use an Azure Private DNS zone for `<userDomain>`, link it to the consumer VNet and add the records there.

---

### 7. First Login

From a machine inside the connected network, open `<scheme>://fundamental-portal.<userDomain>`.

Sign in as `admin` with the password `admin`. You are asked to set a new password immediately; the initial one is temporary and stops working once you change it.

Use the portal to create API keys and invite the rest of your team.

---

## Part 3: Connect Your Application

The platform API is served at `<scheme>://fundamental-api.<userDomain>`. It is reachable only from networks that can reach your Private Endpoint.

1. In the portal, create an API key for your application.
2. Install the Fundamental SDK using the package index and token Fundamental provides.
3. Point the client at your API:

---

## Troubleshooting

If a deployment fails or you cannot reach the platform, see the [Troubleshooting guide](./troubleshooting.md).

---

## Removing the Platform

Delete the resource group:

```bash
az group delete -n "$RG" --yes --no-wait
```

Before you do, note:

- The platform Key Vault keeps its name reserved for 90 days after deletion. If you redeploy within 90 days, use a different `deploymentName`, or purge the vault first if your policy allows it.
- The managed identity from Step 1A lives in the same resource group and is deleted with it. If you redeploy later, repeat Step 1 and send Fundamental the new IDs.
- Your Private Endpoint and DNS records live in your own network and must be removed separately.
- Capacity reservation groups, dedicated host groups and your certificate Key Vault are never changed or deleted by the platform.
