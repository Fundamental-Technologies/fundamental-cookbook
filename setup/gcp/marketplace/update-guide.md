# Upgrade Guide

## Upgrading a Fundamental Platform Deployment on Google Cloud

Upgrades are in-place. You change one line in your tfvars file and run the same deploy script again. The script continues from the deployment's state in the bucket `<project_id>-tfstate-fun`, so it can run from any machine with the same tfvars file.

---

## In-place update to a new bundle version

Fundamental's release notes name the new `bundle_version` and, when the sealed-tier boot image changed, a new `hardened_image`.

### Steps

1. Open your `terraform/<name>.tfvars`.
2. Set `bundle_version` to the new release.
3. If the release notes name a new `hardened_image`, update that too.
4. Leave every other setting as it was. Changing sizes, zones or layout at the same time is possible but makes a failed upgrade harder to read.
5. Run the same command as for the first deployment, from `cloud/gcp`:

   ```bash
   scripts/deploy/deploy.sh --tfvars terraform/my-deployment.tfvars
   ```

6. Read the plan and answer `y`. Then wait for `done: <deployment_name> in <project_id>, bundle <version>`.
7. Open the portal and confirm the new version.

If the run fails, see [Finding the error](./troubleshooting.md#finding-the-error) in the Troubleshooting guide. The run is idempotent: fix the cause and run the same command again.

### What changes

- **The sealed tiers** (Model CPU, Model GPU, orchestration) receive the release's artifact versions as instance metadata. Terraform updates each instance group's template and rolls its instances. A new `hardened_image` replaces the instances' boot disks the same way.
- **Container images** of the new release are copied into your Artifact Registry. Images already present from the previous release are skipped.
- **The charts** are upgraded in place (`helm upgrade`), one release after the other. Workloads roll out replica by replica.

### What does not change

- The network, KMS keys, buckets, secrets, service accounts, the GKE cluster and the Artifact Registry stay as they are. Data in the buckets and in the cluster's volumes is kept.
- Your tfvars file, apart from the version line.
- The chart overlay files (below): they are applied again on every run.

> **Note:** The platform API and the sealed controller tier must agree on the model version. The queue the API publishes tasks to carries that version in its name, and the controller consumes the queue of its own version. Both come from the same release bundle, so upgrading through `bundle_version` keeps them aligned. Pinning a tier's `ftm_version` to another build, or upgrading only the charts (`--skip-terraform`) or only the tiers (`--skip-charts`), can break the alignment. The failure is silent: a task is accepted and never completes. See [Troubleshooting](./troubleshooting.md#a-task-is-accepted-but-never-completes).

---

## Chart settings support asks for

Two overlay files hold Helm values applied on top of the release's charts: `helm-overlays/infra-overlay.yaml` on the infrastructure release (`fun-infra`) and `helm-overlays/app-overlay.yaml` on the application release (`fun-app`). Both ship empty and are applied on every run, so a setting put there survives upgrades.

The tfvars file configures the deployment. An overlay is for a setting Fundamental support asks you to set. To add one:

1. Before each install the script writes the release's effective base values to `helm-overlays/generated/<project_id>/<release>.base.yaml`. Find the value there.
2. Put the changed value under the same path in the overlay file.
3. Run the deploy script again. `--skip-terraform --skip-images` applies only the charts:

   ```bash
   scripts/deploy/deploy.sh --tfvars terraform/my-deployment.tfvars --skip-terraform --skip-images
   ```

After the fact, `helm get values <release> -n <namespace> --all` shows the installed values.

---

## Changing infrastructure settings

Most settings in the tfvars file can be changed on a running deployment: edit the file, run the deploy script, read the plan, answer `y`. Examples: a tier's machine type, disk size or instance count, the GKE node pool limits, the storage class retention, customer exposure and its certificate.

Three cases need care:

| Change | Effect |
|---|---|
| A tier's `zones` | Replaces that tier's instance group. The GPU tiers sit behind an internal load balancer, and Google Cloud refuses to delete an instance group a load balancer still points at. Detach it first, then run the script; see [Troubleshooting](./troubleshooting.md#changing-a-tiers-zones-fails-on-the-load-balancer). List every zone of the region from the start and the group is never replaced. |
| `modelcpu_layout` / `modelgpu_layout` | Switching between `combined` and `split` creates the new tiers and removes the old ones in one run. Tasks running on the old tiers are lost, and a GPU tier behind a load balancer can block its own removal the same way a zone change does. |
| GKE pod or service ranges, `gke_master_ipv4_cidr`, the network the cluster sits in | Immutable cluster fields. Terraform would replace the cluster, which leaves the deployment inconsistent. Do not apply such a plan against a live deployment: uninstall with `scripts/deploy/destroy.sh`, change the setting, and deploy again. |

> [!WARNING]
> When the plan shows the GKE cluster as `must be replaced`, answer `n`. Rebuild instead.
