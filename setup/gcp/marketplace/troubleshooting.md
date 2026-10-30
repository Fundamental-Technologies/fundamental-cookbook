# Troubleshooting

Common problems when deploying or connecting to the **Fundamental Platform** on Google Cloud, and how to fix them. Step numbers refer to the [Deployment Guide](./deployment-guide.md). Every command runs from `cloud/gcp`.

## Finding the error

The deploy script stops at the first failing stage and prints the error above its last lines. The stage tells you where to look:

| Stage | Where the error comes from |
|---|---|
| `terraform plan` / `terraform apply` | Terraform. The message names the resource and the Google Cloud API error. |
| `importing images into ...` | `gcloud storage` or `crane`, copying images into your Artifact Registry. |
| `helm upgrade --install <release>` | Helm or the cluster. `kubectl --context gke_<project_id>_<region>_<deployment_name>-gke get pods -A` shows what is not running. |

The run is idempotent: fix the cause and run the same command again.

---

## Deployment errors

### "could not find default credentials"

**Symptom:** the first `terraform plan` stops with `google: could not find default credentials. See https://cloud.google.com/docs/authentication/external/set-up-adc`.

**Cause:** Terraform's Google provider does not use the `gcloud auth login` session. It reads Application Default Credentials and uses them as the source identity to act as `deployer_service_account`.

**Fix:**

```bash
gcloud auth application-default login
```

Run the deploy script again. The prerequisite check reports missing credentials under "gcloud and sign-in".

### "local state still holds resources"

**Symptom:** the script stops right away with `local state still holds resources: terraform/terraform.tfstate`.

**Cause:** a Terraform state file in `terraform/` holds resources. The deployment keeps its state in the bucket `<project_id>-tfstate-fun`, never locally, and the script refuses to run next to a local state that could describe another deployment.

**Fix:** if the local file is this deployment's state, push it into the bucket once, then move the local files out of `terraform/`:

```bash
terraform -chdir=terraform init -reconfigure \
  -backend-config=bucket=<project_id>-tfstate-fun -backend-config=prefix=terraform
terraform -chdir=terraform state push terraform/terraform.tfstate
mv terraform/terraform.tfstate* <somewhere outside the package>
```

If it is a leftover of a deployment that no longer exists, move it out of the way.

### The plan fails reading `app-manifest.json`

**Symptom:** `terraform plan` fails on `data.google_storage_bucket_object_content.app_manifest` with a `403` or `AccessDenied` on `bundles/<version>/app-manifest.json`, or `404` / `object doesn't exist`.

**Cause:** Terraform reads the release's manifest from Fundamental's release bucket. A `403` means the identity reading it is not covered by Fundamental's read grant, which applies to the service accounts of the onboarded project only: onboarding is not complete, or `deployer_service_account` is unset and the run used your own account. A `404` means `bundle_version` names a release that is not published.

**Fix:** for a `403`, confirm with your Fundamental contact that onboarding for your project number is complete (Step 1) and run as an account with a role in that project. For a `404`, set `bundle_version` to the release Fundamental named. The prerequisite check tests both.

### Image not found, or the attestation endpoint is never accepted

**Symptom:** `terraform apply` fails on an instance template with `The resource 'projects/fundamental-public/global/images/...' was not found`. Or the apply succeeds, but the sealed tiers never become healthy and the attestation endpoint shows a status other than `ACCEPTED`:

```bash
gcloud compute forwarding-rules describe attestation --region us-central1 \
  --format='value(pscConnectionStatus)'
```

**Cause:** onboarding is incomplete. Fundamental makes the hardened image readable by your project and allows your project number on its attestation broker. An image you cannot read reports `not found`, not `permission denied`.

**Fix:** send your project number and region to your Fundamental contact if you have not, and wait for the confirmation. Then run the deploy script again. If the image name in `hardened_image` is not the one Fundamental named for the release, correct it.

### GPU instances boot but the driver refuses the GPU

**Symptom:** the GPU tier's instances start and stop in a loop, and their serial console shows:

```
NVRM: The NVIDIA vGPU ... installed in this system is not supported by open nvidia.ko
```

**Cause:** the tier runs on `g4-standard-6`, `-12` or `-24`. Those shapes attach a fractional vGPU slice of one card, and the open NVIDIA driver in the hardened image does not support vGPU.

**Fix:** set `modelgpu.machine_type` to `g4-standard-48` or larger (a whole GPU), or to `a3-ultragpu-8g`, and run the deploy script again.

### The GPU tier cannot get an instance

**Symptom:** `terraform apply` succeeds, but the GPU instance group stays at zero running instances. Its errors name `ZONE_RESOURCE_POOL_EXHAUSTED`, `The resource ... is not available in zone ...`, or a reservation.

**Cause:** `a3-ultragpu-8g` is offered in few zones and often only with a reservation. Spot capacity for any GPU shape comes and goes per zone.

**Fix:**

- List the zones that offer the shape and set `modelgpu.zones` to all of them: `gcloud compute machine-types list --filter='name=a3-ultragpu-8g AND zone:(<region>)'`.
- Move the GPU tier to a region with capacity with `modelgpu.region` (and `modelgpu.zones` in that region).
- Ask Google Cloud for a reservation, or switch to a G4 shape (`g4-standard-48` or larger).

Changing the zones replaces the instance group; see the next entry.

### Changing a tier's zones fails on the load balancer

**Symptom:** after a change to a tier's `zones`, `terraform apply` fails deleting the instance group with `resourceInUseByAnotherResource` (the backend service still references it).

**Cause:** a change of zones replaces the tier's managed instance group, and Google Cloud refuses to delete an instance group an internal load balancer's backend service still points at. This affects the GPU tiers, which sit behind a load balancer.

**Fix:** detach the group from the backend service, then run the deploy script again:

```bash
gcloud compute backend-services remove-backend <deployment_name>-modelgpu --region <region> \
  --instance-group <deployment_name>-modelgpu --instance-group-region <region>
```

With a split layout the tier is `<deployment_name>-modelgpu-train` or `-predict`. List every zone of the region from the start and the group is never replaced.

### `terraform destroy` stops on resources it did not create

**Symptom:** a bare `terraform destroy` fails, one resource at a time, on subnet, network, node pool or DNS zone deletion.

**Cause:** the charts create resources outside the cluster that Terraform cannot see, and each blocks a deletion:

| Orphan | Blocks |
|---|---|
| PodDisruptionBudgets at 0 allowed disruptions | Node pool drain, indefinitely |
| The ingress forwarding rule, backend service and address | Subnet deletion |
| `k8s-fw-*` firewall rules | VPC deletion |
| Network endpoint groups | VPC deletion |
| DNS A and TXT records | Managed zone deletion |

**Fix:** always uninstall with `scripts/deploy/destroy.sh --tfvars terraform/<name>.tfvars`. It removes the charts first, then the infrastructure, then what the cluster left behind. If you already ran `terraform destroy`, delete each orphan the error names by hand (`gcloud compute forwarding-rules delete`, `gcloud compute firewall-rules delete`, `gcloud compute network-endpoint-groups delete`, `gcloud dns record-sets delete`), then run `destroy.sh`.

### "no endpoints available for service" during the first install

**Symptom:** a `helm upgrade --install` attempt fails with `Internal error occurred: failed calling webhook ...: no endpoints available for service "<name>"`, and the script prints `waiting for <name> to serve` and `attempt 2`.

**Cause:** on a first install the operators ship together with their custom resources, and the operators' admission webhooks are not serving yet when the resources are applied.

**Fix:** none. The script waits for the webhook and retries up to four times. Only a fourth failed attempt is an error; then check the webhook's pods with `kubectl get pods -A`.

### A task is accepted but never completes

**Symptom:** the API returns a task ID for a training or prediction request, and the task stays pending forever. No error anywhere.

**Cause:** the API and the sealed controller tier disagree on the model version. The API publishes to a queue named after its version, the controller consumes the queue of its own version, and a task on a queue nobody consumes sits there until it is dead-lettered. This happens when a tier pins an `ftm_version` that does not match the release, or when only the charts (`--skip-terraform`) or only the tiers (`--skip-charts`) were upgraded.

**Fix:** remove the `ftm_version` pin unless Fundamental told you to set it, make sure `bundle_version` is the same for the tiers and the charts, and run the deploy script without `--skip-*` flags. Ask your Fundamental contact if a pin is needed for your GPU shape.

### Quota exceeded

**Symptom:** `terraform apply` or the instance group reports `QUOTA_EXCEEDED` or `Quota '<METRIC>' exceeded. Limit: <n> in region <region>`.

**Cause:** the project's quota for that metric (`CPUS`, `E2_CPUS`, a GPU metric, `SSD_TOTAL_GB`, ...) in that region does not cover the deployment.

**Fix:** request an increase in the Console under IAM & Admin > Quotas, filtered on the metric and region, or pick a smaller machine type. The prerequisite check compares the quota with your tfvars file beforehand.

### API has not been used in project

**Symptom:** `Error 403: <service>.googleapis.com API has not been used in project <number> before or it is disabled`.

**Cause:** a required API is not enabled.

**Fix:** enable it and run the script again:

```bash
gcloud services enable <service>.googleapis.com --project <project-id>
```

The full list is in [Required APIs](./deployment-guide.md#required-apis).

### kubectl cannot reach the cluster API

**Symptom:** the script stops after `GKE credentials` with `kubectl cannot reach the cluster API`, or `kubectl` reports `gke-gcloud-auth-plugin: command not found`.

**Cause:** the cluster is reached through its DNS endpoint, which needs the `gke-gcloud-auth-plugin` component and the `container.clusters.get` permission for your account.

**Fix:** `gcloud components install gke-gcloud-auth-plugin`, and confirm your account holds `roles/owner` (or `roles/container.admin`) on the project.

---

## Connection errors

### Cannot reach the portal

- The PSC endpoint's connection is not `ACCEPTED`: the consumer project is not in `allowed_consumer_projects`. Add it, run the deploy script, then check the endpoint again (Step 7).
- The DNS records do not point at the endpoint's IP, or your machine does not resolve the zone that holds them. Check with `nslookup fundamental-portal.<your-domain>`.
- You use `https://` but deployed without `edge_certificate_id`. Check the `customer_exposure` output: `tls_enabled`.
- Customer exposure is off: the platform answers only inside the deployment VPC, on the `ftm-int.net` names.

### The edge answers 503 for one app

**Symptom:** the portal works but the API (or another app) returns `503` through the edge.

**Cause:** the edge health check for that app probes a path or port the app does not answer `200` on, so its backend has no healthy endpoint. The same misconfiguration also stops the app's deployment from rolling out.

**Fix:** keep the `exposed_apps` entries as in the template (`health_path` and `health_port` per app) and change only the hosts. Run the deploy script again after a correction.

### API calls fail with a certificate error

HTTPS is enabled but the certificate does not cover the hostname, or the client does not trust the issuing authority. The certificate must cover `*.<your-domain>` or every exposed host.

---

## Still stuck

Collect the script's output from the failing stage, your tfvars file, the deployment name and region, and send them to your Fundamental contact.
