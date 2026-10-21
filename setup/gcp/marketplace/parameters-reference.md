# Parameters Reference

Every variable you can set in `terraform/<name>.tfvars` when deploying the **Fundamental Platform** on Google Cloud, with defaults. Required variables have no default and must be in your file. Everything else can be left out to use the default.

---

## Required

| Variable | Type | Description |
|---|---|---|
| `project_id` | string | Project where resources are deployed. |
| `bundle_version` | string | The release bundle this deployment runs, as a plain `X.Y.Z`. Published versions are immutable. Change it and run the deploy script again to upgrade. |
| `hardened_image` | string | Producer hardened GCE image for the sealed tiers, `projects/fundamental-public/global/images/fun-gce-<profile>-<version>`. Fundamental names the image for the release. |

---

## Region

| Variable | Type | Default | Description |
|---|---|---|---|
| `region` | string | `"us-west1"` | Primary region for regional resources. |
| `zones` | list(string) | `["us-west1-a", "us-west1-b"]` | Primary zones used for zonal resources. Every tier spreads over these unless it names its own. List every zone you want from the start: changing a tier's zones later replaces its instance group. |
| `deployment_name` | string | `"fundamental"` | Logical deployment name, used in naming and labels. Every resource name starts with it. |

---

## Network

A new VPC with these ranges. The GKE pod and service ranges are immutable after the cluster is created.

| Variable | Type | Default | Description |
|---|---|---|---|
| `vpc_cidr` | string | `"10.0.0.0/16"` | CIDR block used for internal network policy defaults. |
| `private_subnet_1_cidr` | string | `"10.0.0.0/22"` | CIDR for private subnet 1 (GKE nodes and the sealed CPU tiers). The default /22 leaves room for about 1,000 nodes. |
| `modelgpu_subnet_cidr` | string | `"10.0.48.0/22"` | CIDR for the modelgpu subnet, created in the modelgpu tier's region. |
| `attestation_psc_subnet_cidr` | string | `"10.0.32.0/28"` | CIDR for the `us-central1` attestation PSC subnet, created when the region is not `us-central1`. |
| `gke_master_ipv4_cidr` | string | `"172.16.0.0/28"` | RFC 1918 CIDR for the GKE control plane. Must not overlap the VPC, pod or service ranges. |
| `gke_pods_cidr` | string | `"10.0.128.0/17"` | Secondary range on private subnet 1 for GKE pod IPs. Immutable after cluster creation. The default /17 pairs with 128 pods per node for about 128 nodes. |
| `gke_services_cidr` | string | `"10.0.16.0/20"` | Secondary range on private subnet 1 for GKE ClusterIP services. Immutable after cluster creation. |
| `gke_master_authorized_cidrs` | map(string) | `{ private-rfc1918 = "10.0.0.0/8" }` | CIDRs allowed to reach the GKE control plane's private endpoint (map key = display name). The deploy script uses the DNS endpoint and is not affected. |

---

## Existing VPC

Deploy into a VPC you already own instead of creating one. All values are self-links. Nothing in the network is created or destroyed by the deployment, and a network carries one deployment.

| Variable | Type | Default | Description |
|---|---|---|---|
| `existing_network` | object | `null` | `null` creates the network. Set the object below to use yours. |
| `existing_network.network` | string | | The VPC, `projects/<project>/global/networks/<name>`. |
| `existing_network.private_subnet` | string | | The private subnet in `region`, `projects/<project>/regions/<region>/subnetworks/<name>`. Carries the GKE nodes and the sealed CPU tiers; needs Private Google Access and secondary ranges for pods and services. |
| `existing_network.pods_range_name` | string | `"pods"` | Name of the secondary range for GKE pods on the private subnet. |
| `existing_network.services_range_name` | string | `"services"` | Name of the secondary range for GKE services on the private subnet. |
| `existing_network.modelgpu_subnet` | string | `null` | Subnet for the GPU tier. Required when `modelgpu.region` is set; otherwise the GPU tier shares the private subnet. |
| `existing_network.attestation_psc_subnet` | string | `null` | Subnet in `us-central1` for the attestation endpoint. Required unless `region` is `us-central1`. |
| `existing_network.proxy_only_subnet` | string | `null` | An existing `REGIONAL_MANAGED_PROXY` subnet for the customer edge, instead of `edge_proxy_only_subnet_cidr`. |
| `existing_network.psc_nat_subnet` | string | `null` | An existing `PRIVATE_SERVICE_CONNECT` subnet for the customer edge, instead of `edge_psc_nat_subnet_cidr`. |

---

## GKE

| Variable | Type | Default | Description |
|---|---|---|---|
| `gke_node_machine_types` | list(string) | `["e2-standard-4"]` | Machine types for the platform node pools, one pool each, in order of preference. The first keeps `gke_min_node_count_per_zone`; the others start at zero and grow when an earlier type is out of capacity in a zone. |
| `gke_node_disk_size_gb` | number | `100` | Boot disk size (GB) for GKE platform nodes. |
| `gke_min_node_count_per_zone` | number | `1` | Minimum nodes per zone in the platform node pool; also its start size per zone. Keep it at least 1 with customer exposure: the edge needs a node in every zone. |
| `gke_max_node_count_per_zone` | number | `64` | Maximum nodes per zone in the platform node pool (autoscaler ceiling; mutable in place). |
| `gke_public_control_plane` | bool | `false` | Expose the GKE control plane on a public endpoint. Dev and test only; production keeps the private endpoint. |
| `gke_deletion_protection` | bool | `false` | Prevent accidental GKE cluster deletion. Off by default so an uninstall works without a prior apply; set `true` to guard a long-lived cluster. |

---

## Sealed Tiers

Each tier is one object. Name only the keys that differ from the defaults. `zones` falls back to the deployment-wide `zones`; set it per tier when a tier's capacity differs from the rest. `ftm_version` pins another build than the release's; leave it unset unless Fundamental tells you otherwise.

| Variable | Type | Default | Description |
|---|---|---|---|
| `modelcpu` | object | `{}` | Sealed modelcpu tier (FTM controller / Dramatiq workers). |
| `modelgpu` | object | `{}` | Sealed modelgpu tier (Triton inference server). The default machine type is the only H200 shape on GCP; `g4-standard-48` and larger are the G4 alternatives. `region` places the tier where GPU capacity is; `null` keeps it in `region`. |
| `temporal_worker` | object | `{}` | Sealed temporal-worker tier (Temporal worker, light and heavy containers). `target_size = 0` disables the tier. The machine type must support `pd-balanced` boot disks (`n4` and `c4` do not). |

Keys of each object:

| Key | Type | Default | Description |
|---|---|---|---|
| `machine_type` | string | `"e2-standard-4"` (modelcpu), `"a3-ultragpu-8g"` (modelgpu), `"e2-standard-8"` (temporal_worker) | Machine type of the tier's instances. |
| `zones` | list(string) | `zones` | Zones the instance group spreads over. With `modelgpu.region` set, `modelgpu.zones` is required and must lie in that region. |
| `spot` | bool | `false` | Run the tier on Spot VMs. |
| `disk_type` | string | `"pd-balanced"` (CPU tiers), `"hyperdisk-balanced"` (GPU tier) | Boot disk type. A3 Ultra and G4 require Hyperdisk; A2 (A100) requires Persistent Disk, so set `"pd-balanced"` for an A2 shape. |
| `disk_size_gb` | number | `40` | Boot disk size (GB). |
| `target_size` | number | `1` | Number of instances. |
| `ftm_version` | string | `null` | Pins another build than the release's artifact for this tier. |
| `region` | string | `null` | `modelgpu` only: the region the GPU tier runs in. |

---

## Layout

By default each compute type is one **combined** tier handling both training and prediction. With a **split** layout, training and prediction get their own tiers, sized independently.

| Variable | Type | Default | Description |
|---|---|---|---|
| `modelcpu_layout` | string | `"combined"` | Controller tiers: `"combined"` (one modelcpu tier, both queues) or `"split"` (modelcpu-train and modelcpu-predict, one queue each). |
| `modelgpu_layout` | string | `"combined"` | Triton tiers: `"combined"` (one modelgpu tier) or `"split"` (modelgpu-train and modelgpu-predict, a load balancer and DNS name each, called by the matching controller). Requires `modelcpu_layout = "split"`. |
| `tier_overrides` | map(object) | `{}` | Per split tier (`modelcpu-train`, `modelcpu-predict`, `modelgpu-train`, `modelgpu-predict`), what differs from its base tier (`modelcpu` or `modelgpu`). Unset attributes inherit; the keys are those of the tier objects above. GPU zones must lie in `modelgpu.region`. |

---

## Storage

| Variable | Type | Default | Description |
|---|---|---|---|
| `storage_location` | string | `"US"` | Location for the GCS buckets. The key ring follows: `US` puts it in the `us` multi-region, anything else in `region`. |
| `retain_volumes` | bool | `false` | Keep the disks behind the cluster's PersistentVolumeClaims when the claims go: the charts put every volume on the `pd-balanced-retained` StorageClass instead of `pd-balanced`. An uninstall then leaves the disks for you to keep or delete. |
| `force_destroy_buckets` | bool | `false` | Allow Terraform to delete non-empty GCS buckets during an uninstall. |
| `trained_models_kms_key_name` | string | `null` | Optional CMEK key resource ID for the trained models bucket. By default the deployment's own key is used. |

---

## Customer Exposure

Publish the apps under your own domain, reachable over Private Service Connect from the listed projects. Plain HTTP without `edge_certificate_id`. See [DNS and TLS](./deployment-guide.md#dns-and-tls).

| Variable | Type | Default | Description |
|---|---|---|---|
| `customer_exposure_enabled` | bool | `false` | Create a Terraform-owned regional application load balancer exposing the apps in `exposed_apps` under your own domain, reachable over PSC. |
| `exposed_apps` | list(object) | `[]` | One entry per exposed app: `name`, `host`, `neg_name` (must match that app's `cloud.google.com/neg` Service annotation), `port` (the pod's target port), optional `health_path` (default `/`) and `health_port` (default `port`) the app answers 200 on. Required (non-empty) when exposure is on. Copy the block from the template below; change only the hosts. |
| `edge_certificate_id` | string | `null` | Existing Certificate Manager certificate for the edge, `projects/<project>/locations/<region>/certificates/<name>`. Never created or validated by the deployment. Unset serves plain HTTP. |
| `edge_proxy_only_subnet_cidr` | string | `null` | CIDR for the dedicated `REGIONAL_MANAGED_PROXY` subnet the edge requires. Required when exposure is on (unless `existing_network.proxy_only_subnet` is set). |
| `edge_psc_nat_subnet_cidr` | string | `null` | CIDR for the dedicated `PRIVATE_SERVICE_CONNECT` NAT subnet backing the edge's service attachment. Required when exposure is on (unless `existing_network.psc_nat_subnet` is set). |
| `allowed_consumer_projects` | list(string) | `[]` | Your project IDs or numbers allowed to create a PSC endpoint against the edge's service attachment. Required (non-empty) when exposure is on. |

---

## Producer Settings

These point at Fundamental's side and are set for you. Do not change them unless Fundamental tells you to.

| Variable | Type | Default | Description |
|---|---|---|---|
| `producer_broker_service_account_email` | string | `"fun-attestation-broker@fun-marketplace-prod.iam.gserviceaccount.com"` | Fundamental's broker service account, granted `roles/compute.viewer` in your project to verify the sealed VMs' identity. |
| `producer_release_bucket_name` | string | `"fun-marketplace-us"` | Fundamental's release bucket. The bundle and the feature flags for your project are read from it. |
| `producer_attestation_service_attachment` | string | `"https://www.googleapis.com/compute/v1/projects/fun-marketplace-prod/regions/us-central1/serviceAttachments/fun-attestation-broker-psc"` | Fundamental's PSC service attachment for the attestation broker. Empty skips creating the endpoint. |

---

## `terraform/<name>.tfvars` template

Start from [`example.tfvars`](./example.tfvars). It holds only the three required values:

```bash
cp example.tfvars terraform/my-deployment.tfvars
```

The longer version below shows every variable with its default. Delete the lines you do not change; a line left at its default is harmless.

```hcl
# ----------------------------------------------------------------- required --
project_id     = "my-project-123456"
bundle_version = "1.0.2"
hardened_image = "projects/fundamental-public/global/images/fun-gce-secure-1-0-0"

# ------------------------------------------------------------------- region --
region          = "us-west1"
zones           = ["us-west1-a", "us-west1-b"]
deployment_name = "fundamental"

# ------------------------------------------------------------------ network --
vpc_cidr                    = "10.0.0.0/16"
private_subnet_1_cidr       = "10.0.0.0/22"
modelgpu_subnet_cidr        = "10.0.48.0/22"
attestation_psc_subnet_cidr = "10.0.32.0/28"
gke_master_ipv4_cidr        = "172.16.0.0/28"
gke_pods_cidr               = "10.0.128.0/17"
gke_services_cidr           = "10.0.16.0/20"
gke_master_authorized_cidrs = { private-rfc1918 = "10.0.0.0/8" }

# An existing VPC instead of the ranges above (self-links).
# existing_network = {
#   network                = "projects/my-project-123456/global/networks/my-vpc"
#   private_subnet         = "projects/my-project-123456/regions/us-west1/subnetworks/my-private-subnet"
#   pods_range_name        = "pods"
#   services_range_name    = "services"
#   modelgpu_subnet        = "projects/my-project-123456/regions/us-west1/subnetworks/my-gpu-subnet"
#   attestation_psc_subnet = "projects/my-project-123456/regions/us-central1/subnetworks/my-attestation-subnet"
# }

# ---------------------------------------------------------------------- gke --
gke_node_machine_types      = ["e2-standard-4"]
gke_node_disk_size_gb       = 100
gke_min_node_count_per_zone = 1
gke_max_node_count_per_zone = 64
gke_public_control_plane    = false
gke_deletion_protection     = false

# ------------------------------------------------------------- sealed tiers --
modelcpu = {
  machine_type = "e2-standard-4"
  disk_size_gb = 40
  target_size  = 1
}
modelgpu = {
  machine_type = "a3-ultragpu-8g"
  zones        = ["us-west1-a"]
  spot         = false
  target_size  = 1
}
temporal_worker = {
  machine_type = "e2-standard-8"
  target_size  = 1
}

# ------------------------------------------------------------------- layout --
modelcpu_layout = "combined"
modelgpu_layout = "combined"
tier_overrides  = {}

# ------------------------------------------------------------------ storage --
storage_location            = "US"
retain_volumes              = false
force_destroy_buckets       = false
trained_models_kms_key_name = null

# -------------------------------------------------------- customer exposure --
customer_exposure_enabled   = false
edge_proxy_only_subnet_cidr = "10.0.40.0/26"
edge_psc_nat_subnet_cidr    = "10.0.40.64/28"
edge_certificate_id         = null
allowed_consumer_projects   = []
exposed_apps = [
  { name = "portal", host = "fundamental-portal.example.com", neg_name = "portal-neg", port = 80 },
  { name = "api", host = "fundamental-api.example.com", neg_name = "api-neg", port = 8000, health_path = "/health" },
  { name = "keycloak", host = "fundamental-keycloak.example.com", neg_name = "keycloak-neg", port = 8080, health_path = "/health/ready", health_port = 9000 },
  { name = "grafana", host = "fundamental-grafana.example.com", neg_name = "grafana-neg", port = 3000 },
]
```

### Deploy command

```bash
scripts/deploy/deploy.sh --tfvars terraform/my-deployment.tfvars
```

See the [Deployment Guide](./deployment-guide.md) for the prerequisite check, verification, network connection and first login.
