# Fundamental Platform on Google Cloud. Copy to terraform/<name>.tfvars, set
# the four required values, then decide region, zones and customer exposure.
# Every optional setting and its default is listed in parameters-reference.md.

project_id               = "my-project-123456"                                              # The Google Cloud project you deploy into
deployer_service_account = "fundamental-deployer@my-project-123456.iam.gserviceaccount.com" # The service account the deployment runs as (deployment guide, Step 1)
bundle_version           = "1.0.2"                                                          # The release bundle Fundamental named, as X.Y.Z
hardened_image           = "projects/fundamental-public/global/images/fun-gce-secure-0-1-0" # The sealed-tier boot image Fundamental named for the release

# Decide for every deployment (deployment guide, Step 3).
region = "us-west1"                   # The region you shared during onboarding
zones  = ["us-west1-a", "us-west1-b"] # Every zone of the region the tiers spread over; changing them later replaces the instance groups

# How users reach the platform. Prepare the values now, keep it false for the
# first run and switch it on in a second run (deployment guide, Step 7).
customer_exposure_enabled = false
# exposed_apps = [
#   { name = "portal",   host = "fundamental-portal.example.com",   neg_name = "portal-neg",   port = 80 },
#   { name = "api",      host = "fundamental-api.example.com",      neg_name = "api-neg",      port = 8000, health_path = "/health" },
#   { name = "keycloak", host = "fundamental-keycloak.example.com", neg_name = "keycloak-neg", port = 8080, health_path = "/health/ready", health_port = 9000 },
#   { name = "grafana",  host = "fundamental-grafana.example.com",  neg_name = "grafana-neg",  port = 3000 },
# ]
# edge_certificate_id         = "projects/my-project-123456/locations/us-west1/certificates/edge-cert" # Optional; plain HTTP without it
# allowed_consumer_projects   = ["my-consumer-project"]
# edge_proxy_only_subnet_cidr = "10.0.40.0/26"
# edge_psc_nat_subnet_cidr    = "10.0.40.64/28"
