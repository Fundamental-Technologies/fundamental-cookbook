# Fundamental Platform on Google Cloud. Copy to terraform/<name>.tfvars and set
# the four required values. Every optional setting and its default is listed
# in parameters-reference.md.

project_id               = "my-project-123456"                                              # The Google Cloud project you deploy into
deployer_service_account = "fundamental-deployer@my-project-123456.iam.gserviceaccount.com" # The service account the deployment runs as (deployment guide, Step 1)
bundle_version           = "1.0.2"                                                          # The release bundle Fundamental named, as X.Y.Z
hardened_image           = "projects/fundamental-public/global/images/fun-gce-secure-0-1-0" # The sealed-tier boot image Fundamental named for the release
