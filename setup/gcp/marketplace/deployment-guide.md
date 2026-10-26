# Deployment Guide

## Part 1: Before you start

### Prerequisites

#### Google Cloud project

- You need a Google Cloud project with billing enabled. Note its project ID and project number:

  ```bash
  gcloud projects describe <project-id> --format='value(projectNumber)'
  ```

- Decide the region you will deploy into up front. You share it with Fundamental during onboarding ([Step 1](#1-onboarding-with-fundamental-one-time)). Choose whichever region fits your desired deployment pattern.
- The accounts involved need the permissions below.

| Who | Needs | Why |
|---|---|---|
| The person doing the onboarding ([Step 1](#1-onboarding-with-fundamental-one-time)) | Owner (`roles/owner`) on the project | Creates the deployer service account and grants it its role. |
| The deployer service account ([Step 1](#1-onboarding-with-fundamental-one-time)) | Owner (`roles/owner`) on the project | The deployment creates networks, a GKE cluster, KMS keys, secrets, service accounts and project-level IAM grants, sets project metadata and enables APIs. A narrower role works when it holds every permission the [prerequisite check](preflight.py) tests. |
| The person running the deployment ([Step 5](#5-deploy-the-platform)) | Service Account Token Creator on the deployer service account | The deploy script acts as the deployer. No key file is created. |

> [!NOTE]
> The deployment runs from your machine into your own project, as a service account you own. Once onboarding is done, the service accounts of your project can read Fundamental's release bucket. 
>
>  The only access Fundamental gets is a custom role for its attestation broker service account with one permission, `compute.instances.getShieldedInstanceIdentity`. This allows Fundamental to attest the machine running the model.

#### Required APIs

Enable these APIs on the project before you deploy:

```bash
gcloud services enable compute.googleapis.com cloudkms.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com \
  storage.googleapis.com logging.googleapis.com monitoring.googleapis.com serviceusage.googleapis.com \
  --project <project-id>
```

The deployment enables `container.googleapis.com`, `dns.googleapis.com` and `parametermanager.googleapis.com` itself on the first run. When you enable HTTPS on the customer edge ([DNS and TLS](#dns-and-tls)), also enable `certificatemanager.googleapis.com`.

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

You reach the GKE control plane through an IAM-gated DNS endpoint. You need no VPN, bastion host or path into the deployment network to deploy or operate the cluster.

#### Compute capacity

The platform runs its model workloads on managed instance groups of Shielded VMs, one per tier, and everything else on a private GKE cluster. Make sure your project has quota in the region for the machine types you pick.

| Tier | Default machine type | vCPU | GPU | Quota to check |
|---|---|---|---|---|
| Model CPU (`modelcpu`) | `n2-standard-32` | 32 | | `N2_CPUS`, `CPUS` |
| Model GPU (`modelgpu`) | `a3-ultragpu-8g` | 224 | 8x NVIDIA H200 | `CPUS` plus the H200 GPU quota |
| Model GPU, smaller alternative | `g4-standard-48` (or `-96`, `-192`, `-384`) | 48 | 1x NVIDIA RTX PRO 6000 (2, 4, 8) | `CPUS` plus the RTX PRO 6000 GPU quota |
| Orchestration (`temporal_worker`) | `n2-highmem-32` | 32 | | `N2_CPUS`, `CPUS` |
| GKE platform node pool | `n2-standard-16`, 1 node per zone at start, up to 64 per zone | 16 per node | | `N2_CPUS`, `CPUS` |


Each tier starts with one instance. Spot instances count against the `PREEMPTIBLE_*` quotas instead.

> [!WARNING]
> Only a few zones offer `a3-ultragpu-8g`, and it often needs a reservation. Check the zones before you pick them: `gcloud compute machine-types list --filter='name=a3-ultragpu-8g AND zone:(<region>)'`. The GPU tier can run in a different region from the rest of the platform (`modelgpu.region`), so it can follow GPU capacity.

> [!WARNING] Factional vGPU slices of one card, and incompatible with the machine image. For the g4 family `g4-standard-48` is the smallest G4 shape that attaches a whole GPU.

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

Change these only if they overlap a network you plan to peer or connect from. You cannot change the GKE pod and service ranges after the cluster exists.

The deployment has no internet egress and no public addresses. It reaches Google APIs over Private Google Access and Fundamental's services over Private Service Connect.

#### Existing VPC

To deploy into a network you already own, set `existing_network` instead ([Parameters Reference](./parameters-reference.md#existing-vpc)). The deployment creates nothing in that network. The network must meet these conditions:

- It has a private subnet in the deployment region, with Private Google Access on and two secondary ranges for GKE pods and services (named `pods` and `services` by default).
- When the GPU tier runs in another region (`modelgpu.region`), it has a subnet in that region with Private Google Access on.
- Unless the region is `us-central1`, it has a subnet in `us-central1` for the attestation endpoint.
- It holds no other Fundamental deployment. Each deployment attaches its own private DNS zones, and Cloud DNS allows one zone per name per network.
- It does not belong to a Shared VPC host project. Shared VPC is not supported yet.

### DNS and TLS

How users and applications reach the platform depends on customer exposure (`customer_exposure_enabled`):

- With customer exposure off, the default, the platform is reachable only inside the deployment VPC and only over plain HTTP. It answers on fixed private names under `ftm-int.net`: `fundamental-portal.ftm-int.net`, `fundamental-api.ftm-int.net`, `fundamental-keycloak.ftm-int.net` and `fundamental-grafana.ftm-int.net`.
- With customer exposure on, the platform publishes the portal, API, sign-in and dashboards over Private Service Connect under a domain you own. You create a PSC endpoint in one of your VPCs and point your DNS at it ([Step 7](#7-connect-your-network)).

With customer exposure on, have these ready:

- Your domain is a DNS suffix you control. The four hostnames live under it, with names you choose in `exposed_apps`. The example uses:

  | Hostname | Used by |
  |---|---|
  | `fundamental-portal.<your-domain>` | Platform UI |
  | `fundamental-api.<your-domain>` | Platform API and SDK |
  | `fundamental-keycloak.<your-domain>` | Sign-in |
  | `fundamental-grafana.<your-domain>` | Dashboards (logs and metrics) |

- The consumer projects are every project that will create the PSC endpoint. List their project IDs in `allowed_consumer_projects`.
- A TLS certificate is optional. Without one the edge serves plain HTTP. For HTTPS, create a certificate in Certificate Manager in the deployment region. It must cover `*.<your-domain>` or all four hostnames. Pass its resource name as `edge_certificate_id`, in the form `projects/<project>/locations/<region>/certificates/<name>`. The deployment never creates, validates or renews it.

### What Fundamental needs from you

Onboarding happens once per project. Send your Fundamental contact the project ID, the project number and the region.

Fundamental then grants your project read access to its release bucket, allows your project to connect to its attestation broker and makes the hardened machine image readable by your project. Wait for Fundamental's confirmation before you deploy.

### Container images and models

You do not host or pull any images yourself. The deploy script copies Fundamental's container images and charts into an Artifact Registry repository it creates inside your project, and the sealed tiers fetch their encrypted model artifacts over Private Service Connect. Nothing reaches the internet.

---

## Part 2: Deploy Nexus

Work through the eight steps in order.

### 1. Onboarding with Fundamental (one time)

```bash
export PROJECT_ID=<your-project-id>
export REGION=<region>                      # for example us-east5

gcloud config set project "$PROJECT_ID"
echo "Project ID:     $PROJECT_ID"
echo "Project number: $(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
echo "Region:         $REGION"
```

Create the deployer service account the deployment runs as. It owns the project like an operator would. You get only the right to act as it, and no key is created:

```bash
export DEPLOYER="fundamental-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create fundamental-deployer --project "$PROJECT_ID"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:$DEPLOYER" --role roles/owner
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER" --project "$PROJECT_ID" \
  --member "user:$(gcloud config get account)" --role roles/iam.serviceAccountTokenCreator
```

Give every colleague who will run the deployment the same Token Creator binding. A new binding takes about a minute to take effect.

> [!IMPORTANT]
> Send the project ID, the project number and the region to your Fundamental contact, and wait for their confirmation before you deploy. Fundamental also names the `bundle_version` and `hardened_image` you need in [Step 4](#4-configure-the-deployment).

---

### 2. Get the package and tools

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

### 3. Run the prerequisite check

Copy [`preflight.py`](./preflight.py) from this folder into `cloud/gcp` and run it. It is read-only and needs only Python 3.8 or newer and `gcloud`.

```bash
python3 preflight.py -p "$PROJECT_ID" -s "$DEPLOYER"
```

If a [required API](#required-apis) is off, the script stops there. Enable the APIs with the command it prints, wait a minute and run it again. From the deployer service account check on, every check runs as that account, so the results describe the identity that will deploy.

Once your tfvars file exists ([Step 4](#4-configure-the-deployment)), run it again with `-t terraform/<name>.tfvars`. It then checks the exact region, zones, bundle, image, network and certificate you configured, and takes the deployer account from the file.

The script checks the project, billing, APIs, the deployer account and its permissions, local tools, the onboarding grants, zones, organization policies and the network. It does not check compute capacity, and points you to the documentation page for that instead. Fix every `FAIL` before you continue. A `SKIP` means the account running the check lacks the permission for it. Ask a project owner to run the script, or verify the item yourself. Run `python3 preflight.py -h` for all options.

---

### 4. Configure the deployment

One file configures a deployment: `terraform/<name>.tfvars`. Start from the example:

```bash
cp terraform/example.tfvars terraform/my-deployment.tfvars
```

You must set four values:

| Variable | Description | Example |
|---|---|---|
| `project_id` | The project you deploy into | `my-project-123456` |
| `deployer_service_account` | The service account from [Step 1](#1-onboarding-with-fundamental-one-time) | `fundamental-deployer@my-project-123456.iam.gserviceaccount.com` |
| `bundle_version` | The release bundle, as `X.Y.Z` | `1.0.2` |
| `hardened_image` | The sealed-tier boot image Fundamental named for the release | `projects/fundamental-public/global/images/fun-gce-secure-1-0-0` |

The example lists every other setting commented out, with its default. The settings most deployments change:

| Setting | When to change it |
|---|---|
| `region`, `zones` | Your region. List every zone of the region you want the tiers spread over; changing a tier's zones later replaces its instance group. |
| `modelgpu.machine_type`, `modelgpu.zones` | The GPU shape and the zones that offer it. See [Compute capacity](#compute-capacity). |
| `modelgpu.region` | The GPU tier runs in a different region from the rest of the platform. |
| `modelcpu.machine_type` | A bigger Model CPU machine. See [Compute capacity](#compute-capacity). |
| `vpc_cidr` and the subnet ranges | The defaults overlap a network you will connect from. |
| `existing_network` | You deploy into a VPC you already own. |
| `customer_exposure_enabled` and the `edge_*`, `exposed_apps`, `allowed_consumer_projects` settings | Users reach the platform from outside the deployment VPC. See [DNS and TLS](#dns-and-tls) and the note in [Step 7](#7-connect-your-network). |
| `storage_location` | Your buckets and key ring should live somewhere other than the `US` multi-region. |
| `retain_volumes` | Database and metrics disks should survive an uninstall. |

The [Parameters Reference](./parameters-reference.md) has the full list. The file stays on your machine. It is not part of the package and holds nothing secret.

---

### 5. Deploy the platform

```bash
scripts/deploy/deploy.sh --tfvars terraform/my-deployment.tfvars
```

The script acts as `deployer_service_account` for everything it does and prints `running as <account>` first. It works in five stages:

1. It creates the Terraform state bucket `<project_id>-tfstate-fun` in your project on the first run and points Terraform at it. Every later run, from any machine, finds the deployment through this bucket.
2. It prints a Terraform plan and asks `Apply this plan? [y/N]`. The plan lists every resource the run will create, change or destroy. Read it, then answer `y`. Answering `n` stops the run and leaves the plan file in `terraform/` for inspection. `--auto-approve` skips the prompt.
3. It applies the plan: network, KMS keys, buckets, secrets, service accounts, the attestation endpoint, the sealed tiers, the Artifact Registry and the GKE cluster.
4. It copies the release's container images into your Artifact Registry, four at a time (`--import-jobs N` changes that). It skips images that are already present.
5. It installs the charts into the cluster in release order and waits for each.

> [!NOTE]
> On a first install, the operators' admission webhooks are not serving yet when the script applies their custom resources. The script reports the failed attempt, waits for the webhook and retries. This is expected and needs no action.


The run is idempotent. If it stops, fix the cause and run the same command again. A rerun continues from the recorded state. It should take 60-90 minutes.

---

### 6. Verify the deployment

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

### 7. Connect your network

With customer exposure off, the platform answers only inside the deployment VPC, over HTTP. The names it answers on are in the `internal_hostnames` output. For access from your own network, turn customer exposure on.

With customer exposure on, the edge publishes a Private Service Connect service attachment. Connect to it from the consumer project you listed in `allowed_consumer_projects`.

> [!NOTE]
> Turn customer exposure on in a second run. The edge looks up the apps' network endpoint groups, which exist only once the first run has installed the charts. Deploy with exposure off first, then set `customer_exposure_enabled = true` with the `edge_*`, `exposed_apps` and `allowed_consumer_projects` settings and run `deploy.sh` again. TODO @danv - check this

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

In the DNS your users resolve, create A records for the hostnames in the `customer_exposure` output, all pointing at the endpoint's IP. A single wildcard record `*.<your-domain>` also works.

If you use a Cloud DNS private zone for `<your-domain>`, attach it to the consumer VPC and add the records there.

---

### 8. First login

From a machine inside the connected network, open `<scheme>://fundamental-portal.<your-domain>` (`https` when you set `edge_certificate_id`, `http` otherwise). Without customer exposure, open `http://fundamental-portal.ftm-int.net` from inside the deployment VPC.

Sign in as `admin` with the password `admin`. The portal asks you to set a new password straight away. The initial one is temporary and stops working once you change it.

Use the portal to create API keys and invite the rest of your team.

---

## Part 3: Connect your application

The platform API is at `<scheme>://fundamental-api.<your-domain>` (or `http://fundamental-api.ftm-int.net` inside the deployment VPC). Only networks with a route to your PSC endpoint can reach it.

1. In the portal, create an API key for your application.
2. Install the Fundamental SDK using the package index and token Fundamental provides.
3. Point the client at your API hostname.

---

## Troubleshooting

If a run fails or you cannot reach the platform, see the [Troubleshooting guide](./troubleshooting.md).

---

## Removing the platform

```bash
scripts/deploy/destroy.sh --tfvars terraform/my-deployment.tfvars
```

The script asks you to type the project ID. It then removes the charts, then the infrastructure, then the load balancer resources that the cluster created for itself. `-y` skips the confirmation.

> [!WARNING]
> Never run `terraform destroy` on its own. With the charts still installed, it leaves behind load balancers, firewall rules, endpoint groups and DNS records that Terraform cannot see, and each of them blocks the next deletion. See [Troubleshooting](./troubleshooting.md#terraform-destroy-stops-on-resources-it-did-not-create).

An uninstall leaves these behind:

- The state bucket `<project_id>-tfstate-fun` stays.
- The KMS key rings stay, because Google Cloud cannot delete key rings. They cost nothing.
- The database, queue, metrics and log disks stay when you set `retain_volumes = true`. The script lists them with the command to delete them.
- Your PSC endpoint and DNS records stay, since they live in your own network.
