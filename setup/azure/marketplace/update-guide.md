# Upgrade Guide

## Upgrading a Fundamental Platform Deployment on Azure

Upgrades are in-place. You run the same deployment again into the same resource group with new version values.

> **Deployment time:** 30 to 60 minutes, the same as a first deployment. The platform stays available during most of the upgrade. Each model tier is replaced one machine at a time.

---

## In-place update

Fundamental's release notes tell you which bundle versions changed and give you the matching `mainTemplate.json`.

### Steps

1. Open your existing `params.json`.
2. Set `infraBundleVersion` and/or `appBundleVersion` to the versions from the release notes.
3. If the release notes ship a new `computeImageId`, update that too.
4. Leave every other parameter as it was. Changing sizes, zones or layout at the same time is possible but makes a failed upgrade harder to read.
5. Sign in as the deployment identity and run the same command as for the first deployment:

   ```bash
   az deployment group create \
     --name fundamental \
     --resource-group <your-resource-group> \
     --template-file mainTemplate.json \
     --parameters @params.json \
     --aux-tenants <fundamental-tenant-id> \
     --no-wait
   ```

6. Wait for the deployment to show **Succeeded**:

   ```bash
   az deployment group show -g <your-resource-group> -n fundamental \
     --query properties.provisioningState -o tsv
   ```

7. Open the portal and confirm the new version.

If the deployment fails, see [Finding the error](./troubleshooting.md#finding-the-error) in the Troubleshooting guide.

---

## What happens during an upgrade

- **Platform services** on AKS are upgraded in place and roll out one replica at a time.
- **Model tiers** roll machine by machine. With `enableSurgeUpgrade` set to `true` (the default), a new machine starts and passes its health check before the old one is removed.
- **Kubernetes patch releases** are applied automatically by Azure, separately from platform upgrades, on the first Sunday of each month between 02:00 and 06:00 UTC. Turn this off with `enableAutoUpgrade: false`.

---

## Changing the tier layout

Switching a compute type between `combined` and `split` adds the new tiers but does not remove the old ones, because an Azure deployment never deletes resources that are no longer in the template. The old tier keeps running and keeps billing until you delete it.

After the upgrade shows **Succeeded**, delete the previous tier's scale set and its internal load balancer. For a CPU switch from `combined` to `split`:

```bash
az vmss delete -g <your-resource-group> -n <deploymentName>-vmss-model-cpu-01
az network lb delete -g <your-resource-group> -n <deploymentName>-lbi-model-cpu-01
```

Switching back from `split` to `combined` works the same way with the `-train-` and `-predict-` scale sets and load balancers.
