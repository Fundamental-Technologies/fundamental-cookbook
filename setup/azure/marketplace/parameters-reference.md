# Parameters Reference

Every parameter you can set when deploying the **Fundamental Platform** on Azure, with defaults. Required parameters have no default and must be in your `params.json`. Everything else can be left out to use the default.

---

## Required Parameters

| Parameter | What it is | How to get the value |
|---|---|---|
| `deploymentName` | Prefix for all resource names. 2 to 12 chars, lowercase letters, digits and hyphens, starting with a letter. | Choose it. Use the same value as in identity onboarding. |
| `computeImageId` | Resource ID of the platform machine image used for every scale set | Provided by Fundamental with each release |
| `infraBundleVersion` | Version of the platform infrastructure bundle | Fundamental release notes. |
| `appBundleVersion` | Version of the platform application bundle | Fundamental release notes. |
| `aksAdminGroupObjectIds` | Array with the object ID of the Entra group whose members get AKS Cluster Admin | `az ad group show -g <group-name> --query id -o tsv` |
| `userDomain` | DNS suffix for user-facing hostnames, lowercase, no scheme, no wildcard. | A domain you control |
| `skrMiResourceId` | Resource ID of the user-assigned managed identity created during identity onboarding | `az identity show -n <name> -g <rg> --query id -o tsv` |
| `skrAppClientId` | Client ID of the platform access app registration created during identity onboarding. | `az ad app list --display-name <name> --query "[0].appId" -o tsv` |

---

## Strongly Recommended

| Parameter | Default | Notes |
|---|---|---|
| `additionalConsumerSubscriptionIds` | *(empty)* | Space-separated subscription IDs allowed to connect a Private Endpoint. Your deployment subscription is always included. |
| `tags` | `{}` | Object of `name: value` pairs applied to every resource. |

---

## Enable TLS (HTTPS)

| Parameter | Default | Notes |
|---|---|---|
| `userCertificateKeyVaultResourceId` | *(empty)* | Resource ID of a Key Vault **certificate**, in the form `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>/certificates/<name>`. Empty means HTTP. |

The certificate must:

- cover `*.<userDomain>` or list all four hostnames (`fundamental-portal`, `fundamental-api`, `fundamental-auth`, `fundamental-grafana`),
- have an exportable private key (PKCS#8),
- sit in a Key Vault that uses **Azure RBAC** permissions and is in the same tenant as the deployment.

The identity running the deployment needs **Owner** on that Key Vault. The vault can be in another resource group or subscription.

---

## Images and Versions

| Parameter | Default | Notes |
|---|---|---|
| `computeImageId` | *(required)* | Machine image for every scale set. Provided by Fundamental. |
| `infraBundleVersion` | *(required)* | Platform bundle. Bump on upgrade. |
| `appBundleVersion` | *(required)* | Application bundle. Bump on upgrade. |
| `modelCpuVersion` | *(empty)* | Leave empty to use the CPU model shipped with the app bundle. Set only when the release notes say so. |
| `modelGpuVersion` | *(empty)* | Same, for the GPU model. |

---

## Networking

Every subnet must sit inside the VNet range and must not overlap another subnet or the pod range.

| Parameter | Purpose | Default |
|---|---|---|
| `vnetAddressPrefix` | VNet address space | `172.22.0.0/20` |
| `snAksPrefix` | AKS nodes | `172.22.0.0/23` |
| `snVmsPrefix` | Model scale sets | `172.22.2.0/25` |
| `snLbVmsPrefix` | Internal load balancers for the scale sets | `172.22.2.128/28` |
| `snLbAksPrefix` | Internal load balancer for the platform entry point | `172.22.2.144/28` |
| `snPePrefix` | Private endpoints for platform services | `172.22.2.160/27` |
| `snAksApiPrefix` | AKS API server | `172.22.2.192/28` |
| `snAciPrefix` | Short-lived deployment jobs | `172.22.2.208/28` |
| `snPlsPrefix` | Private Link Service | `172.22.2.224/28` |
| `podCidr` | Kubernetes pod range. Must not overlap the VNet or any peered network. | `10.244.0.0/16` |

---

## Compute Tiers

Each model tier is a virtual machine scale set. Set a size, an instance count and, optionally, availability zones per tier.

| Parameter | Default | Notes |
|---|---|---|
| `modelCpuVmSize` | `Standard_D32s_v7` | CPU inference and training |
| `modelCpuInstanceCount` | `1` | 1 to 5 |
| `modelCpuZones` | `[]` | For example `["1","2"]`. Empty means regional. |
| `modelGpuVmSize` | `Standard_NC40ads_H100_v5` | GPU inference and training |
| `modelGpuInstanceCount` | `1` | 1 to 5 |
| `modelGpuZones` | `[]` | GPU sizes are often offered in only some zones. |
| `modelOrchestrationVmSize` | `Standard_E32s_v7` | Workflow orchestration |
| `modelOrchestrationInstanceCount` | `1` | 1 to 5 |
| `modelOrchestrationZones` | `[]` | |
| `enableSurgeUpgrade` | `true` | Set `false` if quota is tight; upgrades then cause a short outage per tier. |


### Optional: Split Train/Predict Tiers

By default each compute type is one **combined** scale set handling both training and prediction. With a **split** layout, training and prediction get their own scale sets sized independently.

| Parameter | Default | Notes |
|---|---|---|
| `modelCpuLayout` | `combined` | `combined` or `split` |
| `modelGpuLayout` | `combined` | `combined` or `split`. A split GPU layout requires a split CPU layout. |
| `modelCpuTrainVmSize` / `modelCpuPredictVmSize` | `Standard_D32s_v7` | Used only when `modelCpuLayout` is `split` |
| `modelCpuTrainInstanceCount` / `modelCpuPredictInstanceCount` | `1` | 1 to 5 |
| `modelGpuTrainVmSize` / `modelGpuPredictVmSize` | `Standard_NC40ads_H100_v5` | Used only when `modelGpuLayout` is `split` |
| `modelGpuTrainInstanceCount` / `modelGpuPredictInstanceCount` | `1` | 1 to 5 |


> **On upgrade:** switching a layout on an existing deployment adds the new tiers but does not remove the old ones. See the [Upgrade Guide](./update-guide.md#changing-the-tier-layout).

### Optional: Capacity Reservations and Dedicated Hosts

Tiers can use capacity you already own. The deployment only references these groups. It never creates, changes or deletes them.

| Parameter | Default | Notes |
|---|---|---|
| `modelCpuCapacityReservationGroupId` | *(empty)* | Resource ID of an on-demand capacity reservation group |
| `modelGpuCapacityReservationGroupId` | *(empty)* | |
| `modelOrchestrationCapacityReservationGroupId` | *(empty)* | |
| `modelCpuTrainCapacityReservationGroupId` / `modelCpuPredictCapacityReservationGroupId` | *(empty)* | Split CPU tiers |
| `modelGpuTrainCapacityReservationGroupId` / `modelGpuPredictCapacityReservationGroupId` | *(empty)* | Split GPU tiers |
| `modelCpuHostGroupId` | *(empty)* | Resource ID of a dedicated host group |
| `modelGpuHostGroupId` | *(empty)* | |
| `modelOrchestrationHostGroupId` | *(empty)* | |
| `modelCpuTrainHostGroupId` / `modelCpuPredictHostGroupId` | *(empty)* | Split CPU tiers |
| `modelGpuTrainHostGroupId` / `modelGpuPredictHostGroupId` | *(empty)* | Split GPU tiers |

Requirements for each group you supply:

- Same region as the deployment.
- A capacity reservation group must hold a reservation for that tier's exact size, with enough reserved machines for the instance count plus one while surge upgrades are on. A tier does not fall back to standard capacity.
- A dedicated host group must have hosts of a family that supports the tier's size, with enough free capacity. Tiers on dedicated hosts are limited to 100 instances.
- If the group is zonal, its zone must be in that tier's zone list.
- The deploying identity needs `Microsoft.Compute/capacityReservationGroups/deploy/action` on a reservation group, or read access on a host group and its hosts.

---

## AKS

| Parameter | Default | Notes |
|---|---|---|
| `kubernetesVersion` | `1.36` | Only supported value |
| `aksUserNodeVmSize` | `Standard_E16as_v7` | User nodes instance type |
| `aksUserNodeMin` | `3` | 1 to 10. The pool starts at this size and autoscales. |
| `aksUserNodeMax` | `6` | 2 to 10. Must be at least the minimum. |
| `aksAvailabilityZones` | `["1","2"]` | Zones for both node pools. Set `[]` in regions without zones. |
| `enableAksApiVnetIntegration` | `true` | Places the AKS API server inside the VNet. Recommended. Cannot be changed after the cluster is created. |
| `enableAutoUpgrade` | `true` | Applies Kubernetes patch releases automatically on the first Sunday of each month, 02:00 to 06:00 UTC. |

---

## Logging

| Parameter | Default | Notes |
|---|---|---|
| `logsRetentionDays` | `7` | Days platform logs are kept. 1 to 720. |
| `metricsRetentionDays` | `7` | Days platform metrics are kept. 1 to 720. |

---

## `params.json` template (CLI deploy)

Start from [`params.example.json`](./params.example.json). It holds only the eight required values:

```bash
cp params.example.json params.json
```

Fill the eight required values. Everything else uses the template default. The longer version below also shows the most common optional rows. Remove the optional rows you do not need.

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "deploymentName":            { "value": "fundamental" },
    "computeImageId":            { "value": "REPLACE_WITH_IMAGE_ID_FROM_FUNDAMENTAL" },
    "infraBundleVersion":        { "value": "REPLACE_WITH_INFRA_VERSION" },
    "appBundleVersion":          { "value": "REPLACE_WITH_APP_VERSION" },
    "aksAdminGroupObjectIds":    { "value": ["REPLACE_WITH_ENTRA_GROUP_OBJECT_ID"] },
    "userDomain":                { "value": "apps.example.com" },
    "skrMiResourceId":           { "value": "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/fundamental-fun-mi-01" },
    "skrAppClientId":            { "value": "REPLACE_WITH_SKR_APP_CLIENT_ID" },

    "userCertificateKeyVaultResourceId": { "value": "" },
    "additionalConsumerSubscriptionIds": { "value": "" },
    "modelGpuVmSize":            { "value": "Standard_NC80ads_H100_v5" },
    "modelGpuZones":             { "value": [] },
    "aksAvailabilityZones":      { "value": ["1", "2"] },
    "tags":                      { "value": { "vendor": "fundamental" } }
  }
}
```

### Deploy command

```bash
az deployment group create \
  --name fundamental \
  --resource-group <your-resource-group> \
  --template-file mainTemplate.json \
  --parameters @params.json \
  --aux-tenants <fundamental-tenant-id> \
  --no-wait
```

Track progress with:

```bash
az deployment group show -g <your-resource-group> -n fundamental \
  --query properties.provisioningState -o tsv
```

The deployment takes **30 to 60 minutes**. See the [Deployment Guide](./deployment-guide.md) for verification, network connection and first login.