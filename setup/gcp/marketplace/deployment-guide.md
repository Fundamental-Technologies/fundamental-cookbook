# Deployment Guide

## Part 1: Before You Start

Read this part once and gather what it asks for. Nothing here changes your project yet.

### Prerequisites

#### Google Cloud Project

- A Google Cloud project with **billing enabled**. A project holds one deployment. Note the **project ID** and the **project number**:

  ```bash
  gcloud projects describe <project-id> --format='value(projectNumber)'
  ```

- The **region** you will deploy into, decided up front. You share it with Fundamental during onboarding ([Step 1](#1-onboarding-with-fundamental-one-time)).
- The permissions below, for the person running the deployment.

| Who | Needs | Why |
|---|---|---|
| The person doing the onboarding ([Step 1](#1-onboarding-with-fundamental-one-time)) | **Owner** (`roles/owner`) on the project | Creates the deployer service account and grants it its role. |
| The deployer service account ([Step 1](#1-onboarding-with-fundamental-one-time)) | **Owner** (`roles/owner`) on the project | The deployment creates networks, a GKE cluster, KMS keys, secrets, service accounts and project-level IAM grants, sets project metadata and enables APIs. A narrower role works when it holds every permission the [prerequisite check](preflight.sh) tests. |
| The person running the deployment ([Step 5](#5-deploy-the-platform)) | **Service Account Token Creator** on the deployer service account | The deploy script acts as the deployer. No key file is created. |

> **Note:** The deployment runs from your machine into your own project, as a service account you own. Fundamental's release bucket is readable by the service accounts of your project once onboarding is done; it is never readable by a user account, which is why the deployment runs as one. The only access Fundamental's side gets is a read-only `roles/compute.viewer` grant for its attestation broker service account, which the deployment adds so the broker can verify the identity of the sealed virtual machines.

#### Required APIs

Enable these APIs on the project before you deploy:

```bash
gcloud services enable compute.googleapis.com cloudkms.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com \
  storage.googleapis.com logging.googleapis.com monitoring.googleapis.com serviceusage.googleapis.com \
  --project <project-id>
```

The deployment enables `container.googleapis.com`, `dns.googleapis.com` and `parametermanager.googleapis.com` itself on the first run. When you enable HTTPS on the customer edge ([DNS and TLS](#dns-and-tls)), `certificatemanager.googleapis.com` must be enabled too.

#### Tools

The deploy script runs on your machine and needs:

| Tool | Notes |
|---|---|
| `gcloud` | Signed in, with the deployment project set. Also install the component `gke-gcloud-auth-plugin` (`gcloud components install gke-gcloud-auth-plugin`). |
| `terraform` | Version 1.9.0 or newer. |
| `helm` | Version 4 or newer. |
| `kubectl` | |
| `crane` | Copies the container images into your Artifact Registry. |
| `perl`, `python3` | Used by the script itself. |

The GKE control plane is reached through its DNS endpoint, gated by IAM. You need no VPN, bastion host or path into the deployment network to deploy or to operate the cluster.

#### Compute Capacity

The platform runs its model workloads on managed instance groups of Shielded VMs, one per tier, and the rest on a private GKE cluster. Make sure your project has quota in the region for the machine types you pick.

| Tier | Default machine type | vCPU | GPU | Quota to check |
|---|---|---|---|---|
| Model CPU (`modelcpu`) | `n2-standard-32` | 32 | | `N2_CPUS`, `CPUS` |
| Model GPU (`modelgpu`) | `a3-ultragpu-8g` | 224 | 8x NVIDIA H200 | `CPUS` plus the H200 GPU quota |
| Model GPU, smaller alternative | `g4-standard-48` (or `-96`, `-192`, `-384`) | 48 | 1x NVIDIA RTX PRO 6000 (2, 4, 8) | `CPUS` plus the RTX PRO 6000 GPU quota |
| Orchestration (`temporal_worker`) | `n2-highmem-32` | 32 | | `N2_CPUS`, `CPUS` |
| GKE platform node pool | `n2-standard-16`, 1 node per zone at start, up to 64 per zone | 16 per node | | `N2_CPUS`, `CPUS` |

<!-- TODO: the quota metric names for H200 (a3-ultragpu) and RTX PRO 6000 (g4) could not be verified with gcloud; neither appears in `gcloud compute regions describe` even in a region that offers G4. Fill in once confirmed in the Console quota page. -->

Each tier starts with one instance. Spot instances count against the `PREEMPTIBLE_*` quotas instead.

> [!WARNING]
> `a3-ultragpu-8g` is offered in a few zones only and often needs a reservation. Check the zones before you pick them: `gcloud compute machine-types list --filter='name=a3-ultragpu-8g AND zone:(<region>)'`. The GPU tier can run in a different region from the rest of the platform (`modelgpu.region`), so it can follow GPU capacity.

> [!WARNING]
> Never pick `g4-standard-6`, `-12` or `-24` for the GPU tier. They are fractional vGPU slices of one card, and the NVIDIA driver in the hardened image refuses them. `g4-standard-48` is the smallest G4 shape that attaches a whole GPU.

The Model CPU and orchestration defaults match the sizes Fundamental uses on the other clouds. Ask your Fundamental contact for the sizing that matches your workload.

### Networking

By default the deployment creates its own VPC. You do not need to prepare one.

| Range | Default | Used for |
|---|---|---|
| `vpc_cidr` | `10.0.0.0/16` | Internal firewall rules |
| `private_subnet_1_cidr` | `10.0.0.0/22` | GKE nodes and the sealed CPU tiers |
| `gke_pods_cidr` | `10.0.128.0/17` | GKE pods (secondary range) |
| `gke_services_cidr` | `10.0.16.0/20` | GKE services (secondary range) |
| `modelgpu_subnet_cidr` | `10.0.48.0/22` | The GPU tier, in its own region when `modelgpu.region` is set |
| `attestation_psc_subnet_cidr` | `10.0.32.0/28` | A small subnet in `us-central1` for the endpoint to Fundamental's attestation broker (not created when the region is `us-central1`) |
| `gke_master_ipv4_cidr` | `172.16.0.0/28` | The GKE control plane |

Change these only if they overlap a network you plan to peer or connect from. The GKE pod and service ranges cannot be changed after the cluster exists.

The deployment has **no internet egress and no public addresses**. Google APIs are reached over Private Google Access, Fundamental's services over Private Service Connect.

**Existing VPC.** To deploy into a network you already own, set `existing_network` instead ([Parameters Reference](./parameters-reference.md#existing-vpc)). The network must meet these conditions, and the deployment creates nothing in it:

- A private subnet in the deployment region with **Private Google Access** on and two secondary ranges for GKE pods and services (named `pods` and `services` by default).
- When the GPU tier runs in another region (`modelgpu.region`), a subnet in that region with Private Google Access on.
- Unless the region is `us-central1`, a subnet in `us-central1` for the attestation endpoint.
- No other Fundamental deployment in the same network: each deployment attaches its own private DNS zones, and Cloud DNS allows one zone per name per network.
- Shared VPC host projects are not supported yet.

### DNS and TLS

How users and applications reach the platform depends on **customer exposure** (`customer_exposure_enabled`):

- **Off (default):** the platform is reachable only inside the deployment VPC, on fixed private names under `ftm-int.net` (`fundamental-portal.ftm-int.net`, `fundamental-api.ftm-int.net`, `fundamental-keycloak.ftm-int.net`, `fundamental-grafana.ftm-int.net`), over plain HTTP.
- **On:** the platform publishes the portal, API, sign-in and dashboards over **Private Service Connect** under a domain you own. You create a PSC endpoint in a VPC of yours and point your DNS at it ([Step 7](#7-connect-your-network)).

With customer exposure on, have ready:

- **Your domain**: a DNS suffix you control. The four hostnames are created under it; the names are yours to choose in `exposed_apps`, the example uses:

  | Hostname | Used by |
  |---|---|
  | `fundamental-portal.<your-domain>` | Platform UI |
  | `fundamental-api.<your-domain>` | Platform API and SDK |
  | `fundamental-keycloak.<your-domain>` | Sign-in |
  | `fundamental-grafana.<your-domain>` | Dashboards (logs and metrics) |

- **The consumer project(s)**: the project ID of every project that will create the PSC endpoint (`allowed_consumer_projects`).
- **TLS certificate (optional)**: without one the edge serves plain HTTP. For HTTPS, create a certificate in **Certificate Manager**, in the deployment region, covering `*.<your-domain>` or all four hostnames, and pass its resource name as `edge_certificate_id` (`projects/<project>/locations/<region>/certificates/<name>`). The deployment never creates, validates or renews it.

### What Fundamental Needs From You

Onboarding happens once per project. Send your Fundamental contact:

- the **project ID**,
- the **project number**,
- the **region**.

Fundamental then grants your project read access to its release bucket, allows your project to connect to its attestation broker, and makes the hardened machine image readable by your project. Wait for the confirmation before you deploy.

### Container Images and Models

You do not host or pull any images yourself. The deploy script copies Fundamental's container images and charts into an Artifact Registry repository created inside your project, and the sealed tiers fetch their encrypted model artifacts over Private Service Connect. Nothing reaches the internet.

---

## Part 2: Deploy Fundamental

Work through the eight steps in order. Each step builds on the one before it.

### 1. Onboarding With Fundamental (One Time)

```bash
export PROJECT_ID=<your-project-id>
export REGION=<region>                      # for example us-east5

gcloud config set project "$PROJECT_ID"
echo "Project ID:     $PROJECT_ID"
echo "Project number: $(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
echo "Region:         $REGION"
```

Create the **deployer service account** the deployment runs as. It owns the project like an operator would; you only get the right to act as it, and no key is created:

```bash
export DEPLOYER="fundamental-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create fundamental-deployer --project "$PROJECT_ID"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:$DEPLOYER" --role roles/owner
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER" --project "$PROJECT_ID" \
  --member "user:$(gcloud config get account)" --role roles/iam.serviceAccountTokenCreator
```

Every colleague who will run the deployment gets the same Token Creator binding. A new binding takes about a minute to take effect.

> [!IMPORTANT]
> Send the project ID, the project number and the region to your Fundamental contact and **wait for Fundamental to confirm** before you deploy. Fundamental also names the `bundle_version` and `hardened_image` you need in [Step 4](#4-configure-the-deployment).

---

### 2. Get the Package and Tools

<!-- TODO: delivery mechanism -->
Fundamental provides the deployment package. Unpack it and change into its `cloud/gcp` directory. Every command below runs from there.

```bash
cd <package>/cloud/gcp
ls
# docs/  helm-overlays/  scripts/  terraform/
```

Install the [tools](#tools), sign in and set the project:

```bash
gcloud auth login
gcloud config set project "$PROJECT_ID"
gcloud components install gke-gcloud-auth-plugin
```

---

### 3. Run the Prerequisite Check

Copy [`preflight.sh`](./preflight.sh) from this folder into `cloud/gcp` and run it. It is read-only.

```bash
./preflight.sh -p "$PROJECT_ID" -s "$DEPLOYER"
```

If a [required API](#required-apis) is off, the script stops there: enable them with the command it prints, wait a minute, and run it again. From the deployer service account check on, every check runs as that account, so the results describe the identity that will deploy.

Run it again with `-t terraform/<name>.tfvars` once your tfvars file exists ([Step 4](#4-configure-the-deployment)): it then checks the exact region, zones, machine types, quota, bundle, image, network and certificate you configured, and takes the deployer account from the file.

It checks the project, billing, APIs, the deployer account and its permissions, local tools, the onboarding grants, zones, machine type availability, quota, organization policies and the network. Fix every `FAIL` before you continue. A `SKIP` means your account lacks the permission to run that check; ask a project owner to run the script, or verify the item yourself. Run `./preflight.sh -h` for all options.

---

### 4. Configure the Deployment

One file configures a deployment: `terraform/<name>.tfvars`. Start from the example:

```bash
cp terraform/example.tfvars terraform/my-deployment.tfvars
```

Four values are required:

| Variable | Description | Example |
|---|---|---|
| `project_id` | The project you deploy into | `my-project-123456` |
| `deployer_service_account` | The service account from [Step 1](#1-onboarding-with-fundamental-one-time) | `fundamental-deployer@my-project-123456.iam.gserviceaccount.com` |
| `bundle_version` | The release bundle, as `X.Y.Z` | `1.0.2` |
| `hardened_image` | The sealed-tier boot image Fundamental named for the release | `projects/fundamental-public/global/images/fun-gce-secure-1-0-0` |

Everything else is commented out in the example with its default. The settings most deployments change:

| Setting | When to change it |
|---|---|
| `region`, `zones` | Your region. List every zone of the region you want the tiers spread over; changing a tier's zones later replaces its instance group. |
| `modelgpu.machine_type`, `modelgpu.zones` | The GPU shape and the zones that offer it. See [Compute Capacity](#compute-capacity). |
| `modelgpu.region` | The GPU tier runs in another region than the rest of the platform. |
| `modelcpu.machine_type` | A bigger Model CPU machine, see [Compute Capacity](#compute-capacity). |
| `vpc_cidr` and the subnet ranges | The defaults overlap a network you will connect from. |
| `existing_network` | You deploy into a VPC you already own. |
| `customer_exposure_enabled` and the `edge_*`, `exposed_apps`, `allowed_consumer_projects` settings | Users reach the platform from outside the deployment VPC. See [DNS and TLS](#dns-and-tls) and the note in [Step 7](#7-connect-your-network). |
| `storage_location` | Your buckets and key ring should live somewhere other than the `US` multi-region. |
| `retain_volumes` | Database and metrics disks should survive an uninstall. |

The full list is in the [Parameters Reference](./parameters-reference.md). The file stays local to you; it is not part of the package and holds nothing secret.

---

### 5. Deploy the Platform

```bash
scripts/deploy/deploy.sh --tfvars terraform/my-deployment.tfvars
```

The script acts as `deployer_service_account` for everything it does (it prints `running as <account>` first), and:

1. Creates the Terraform state bucket `<project_id>-tfstate-fun` in your project on the first run and points Terraform at it. Every later run, from any machine, finds the deployment through this bucket.
2. Prints a Terraform **plan** and asks `Apply this plan? [y/N]`. The plan lists every resource the run will create, change or destroy. Read it, then answer `y`. Answering `n` stops the run and leaves the plan file in `terraform/` for inspection. `--auto-approve` skips the prompt.
3. Applies the plan: network, KMS keys, buckets, secrets, service accounts, the attestation endpoint, the sealed tiers, the Artifact Registry and the GKE cluster.
4. Copies the release's container images into your Artifact Registry, four at a time (`--import-jobs N` changes that). Images already present are skipped.
5. Installs the charts into the cluster in release order and waits for each.

> **Note:** On a first install, the operators' admission webhooks are not serving yet when their custom resources are applied. The script reports the failed attempt, waits for the webhook, and retries. This is expected and needs no action.

<!-- TODO: deployment duration is not known yet; add a figure after the clean-project deployment test. -->

The run is idempotent: if it stops, fix the cause and run the same command again. It continues from the state it has.

---

### 6. Verify the Deployment

The script ends with `done: <deployment_name> in <project_id>, bundle <version>` and lists any pod that is not yet running. It also registers the cluster in your kubeconfig as `gke_<project_id>_<region>_<deployment_name>-gke`:

```bash
export KUBE_CONTEXT="gke_${PROJECT_ID}_${REGION}_fundamental-gke"
kubectl --context "$KUBE_CONTEXT" get pods -A
```

Every pod shows `Running` or `Completed` once the platform is up.

Read the deployment outputs:

```bash
terraform -chdir=terraform output
```

| Output | Use case |
|---|---|
| `internal_hostnames` | The private names the platform answers on inside the deployment VPC |
| `customer_exposure` | Whether the edge is on, whether it serves TLS, and your hostnames per app |
| `edge_psc_service_attachment_self_link` | Target for your PSC endpoint ([Step 7](#7-connect-your-network)); `null` while exposure is off |
| `gke_cluster_name`, `image_registry_url` | The cluster and the registry the images went into |
| `trained_models_bucket_name`, `ephemeral_data_bucket_name` | Your buckets for trained models and uploaded data |

---

### 7. Connect Your Network

**Customer exposure off:** the platform answers only inside the deployment VPC, on the `internal_hostnames` output, over HTTP. For access from your own network, turn customer exposure on.

**Customer exposure on:** the edge publishes a Private Service Connect service attachment. Connect to it from the consumer project you listed in `allowed_consumer_projects`.

> **Note:** Turn customer exposure on in a second run. The edge looks up the apps' network endpoint groups, which exist only once the charts from the first run are installed. Deploy with exposure off first, then set `customer_exposure_enabled = true` with the `edge_*`, `exposed_apps` and `allowed_consumer_projects` settings and run `deploy.sh` again.
<!-- TODO: verify on a clean project that a first run with customer_exposure_enabled = true fails as the module's data sources suggest, or drop this note. -->

#### A. Create a PSC endpoint

In the VPC your users and applications connect from, in the deployment region:

```bash
ATTACHMENT=$(terraform -chdir=terraform output -raw edge_psc_service_attachment_self_link)

gcloud compute addresses create fundamental-psc-ip \
  --project <consumer-project> --region "$REGION" \
  --subnet <consumer-subnet>

gcloud compute forwarding-rules create fundamental-psc \
  --project <consumer-project> --region "$REGION" \
  --network <consumer-vpc> --address fundamental-psc-ip \
  --target-service-attachment "$ATTACHMENT"

gcloud compute forwarding-rules describe fundamental-psc \
  --project <consumer-project> --region "$REGION" \
  --format='value(IPAddress,pscConnectionStatus)'
```

The connection shows `ACCEPTED` when the consumer project is in `allowed_consumer_projects`. Note the IP address.

#### B. Create the DNS records

In the DNS your users resolve, create **A records** for the hostnames in the `customer_exposure` output, all pointing at the endpoint's IP. A single wildcard record `*.<your-domain>` also works.

If you use a Cloud DNS private zone for `<your-domain>`, attach it to the consumer VPC and add the records there.

---

### 8. First Login

From a machine inside the connected network, open `<scheme>://fundamental-portal.<your-domain>` (`https` when you set `edge_certificate_id`, `http` otherwise). Without customer exposure, open `http://fundamental-portal.ftm-int.net` from inside the deployment VPC.

Sign in as `admin` with the password `admin`. You are asked to set a new password immediately; the initial one is temporary and stops working once you change it.

Use the portal to create API keys and invite the rest of your team.

---

## Part 3: Connect Your Application

The platform API is served at `<scheme>://fundamental-api.<your-domain>` (or `http://fundamental-api.ftm-int.net` inside the deployment VPC). It is reachable only from networks that can reach your PSC endpoint.

1. In the portal, create an API key for your application.
2. Install the Fundamental SDK using the package index and token Fundamental provides.
3. Point the client at your API hostname.

---

## Troubleshooting

If a run fails or you cannot reach the platform, see the [Troubleshooting guide](./troubleshooting.md).

---

## Removing the Platform

```bash
scripts/deploy/destroy.sh --tfvars terraform/my-deployment.tfvars
```

The script asks you to type the project ID, removes the charts, then the infrastructure, then the load balancer pieces the cluster created for itself. `-y` skips the confirmation.

> [!WARNING]
> Never run `terraform destroy` on its own. With the charts still installed it leaves load balancers, firewall rules, endpoint groups and DNS records behind that Terraform cannot see, and each of them blocks the next deletion. See [Troubleshooting](./troubleshooting.md#terraform-destroy-stops-on-resources-it-did-not-create).

What stays after an uninstall:

- The state bucket `<project_id>-tfstate-fun`.
- The KMS key rings (Google Cloud cannot delete key rings; they cost nothing).
- The database, queue, metrics and log disks when you set `retain_volumes = true`. The script lists them with the command to delete them.
- Your PSC endpoint and DNS records, which live in your own network.
