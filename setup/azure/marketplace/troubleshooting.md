# Troubleshooting

Common problems when deploying or connecting to the **Fundamental Platform** on Azure, and how to fix them. Step numbers refer to the [Deployment Guide](./deployment-guide.md).

## Finding the error

When a deployment shows **Failed**, list the steps that failed and their messages:

```bash
az deployment operation group list -g <your-resource-group> -n fundamental \
  --query "[?properties.provisioningState=='Failed'].{step:properties.targetResource.resourceName, error:properties.statusMessage.error.message}" -o table
```

In the portal: **Resource groups** -> your resource group -> **Deployments** -> `fundamental` -> **Operation details**.

---

## Deployment errors

### "AuthorizationFailed" or a role assignment error

The deploying identity is missing **Owner** on the resource group, or Owner on the certificate Key Vault when HTTPS is enabled. Fix the role and redeploy with the same command.

### Image or gallery error

Either the `--aux-tenants` flag is missing from the deploy command, or Fundamental has not yet granted your deployment app access to the machine image. Check Step 1D and Step 4A.

### Quota or allocation error

Your subscription does not have enough quota for the selected size, or the size is not offered in the selected region or zone. Request quota, pick another size or zone, and redeploy.

> **Warning: start the scale set before you redeploy.** When a scale set fails to allocate a machine (`AllocationFailed`, usually a GPU size with no capacity), Azure leaves the instance powered off. This is a known Azure limitation: redeploying does not start it.
>
> What to do depends on whether you keep the same size:
>
> - **Same size, capacity is available again.** Start every scale set named in the message, then run the deployment again:
>
>   ```bash
>   az vmss start -g <your-resource-group> -n <deploymentName>-vmss-model-gpu-01
>   ```
>
> - **You changed the size or zone in `params.json`.** The powered-off instance still has the old size. Delete the powered-off instance instead, then run the deployment again. The deployment creates a new machine with the new size:
>
>   ```bash
>   az vmss delete-instances -g <your-resource-group> -n <deploymentName>-vmss-model-gpu-01 --instance-ids <id-from-the-message>
>   ```

### Deployment fails at the health gate

A tier did not become healthy within the time limit. Open the scale set in the portal and check its instances. Common causes:

- The size is not available in the selected zone.
- A capacity reservation group does not match the tier's size or zone.
- A dedicated host group has no free capacity for the tier.

### Deployment fails after the managed identity step

The managed identity was created in a different resource group than the one you deploy into. Create it in the deployment resource group (Step 1A) and pass its new resource ID.

---

## Connection errors

### Cannot reach the portal

- The Private Endpoint subscription is not in the `consumerSubscriptionIds` output. Redeploy with the subscription added to `additionalConsumerSubscriptionIds`.
- The DNS records do not point at the Private Endpoint IP, or your machine is not resolving the DNS zone that holds them. Check with `nslookup fundamental-portal.<userDomain>`.
- You are using `https://` but deployed without a certificate. Check the `scheme` output.

### Private Endpoint connection stays pending

The subscription that owns the Private Endpoint is not in `consumerSubscriptionIds`. Only listed subscriptions are approved automatically. Redeploy with the subscription added to `additionalConsumerSubscriptionIds`, then create the Private Endpoint again.

### API calls fail with a certificate error

HTTPS is enabled but the certificate does not cover the hostname, or the client does not trust the issuing authority. The certificate must cover `*.<userDomain>` or all four hostnames.

---

## Still stuck

Collect the failed operation output from [Finding the error](#finding-the-error), the deployment name and region, and send them to your Fundamental contact.
