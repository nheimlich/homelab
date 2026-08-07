#!/usr/bin/env bash
set -euo pipefail

# --- Global Configuration ---
declare -a stat_data=("sol:111" "clu:112" "ion:113")
declare -a dhcp_data=("sol:<missing>" "clu:<missing>" "ion:<missing>")
suffix=".nhlabs.org"
network="10.0.0."
lbvip="115"
install_disk="/dev/nvme0n1"
image="factory.talos.dev/installer-secureboot/9ed5fecdacb36b5c5427b87d409f1065cfb2df69b0f71c58b868d9d466d8dab3:v1.13.3"
cluster_name="k8s.nhlabs.local"
gcp_project_id="homelab-a70a4db3c74cf8cd"
oidc_issuer="https://nhlabs.org/oidc"
wif_audience="//iam.googleapis.com/projects/285407169922/locations/global/workloadIdentityPools/homelab/providers/k8s-oidc"

# --- Validation ---
: "${stat_data:?Error: stat_data is not set}"
: "${network:?Error: network is not set}"
: "${install_disk:?Error: install_disk is not set}"
: "${image:?Error: image is not set}"
: "${lbvip:?Error: lbvip is not set}"
: "${cluster_name:?Error: cluster_name is not set}"
: "${suffix:?Error: suffix is not set}"
: "${dhcp_data:?Error: dhcp_data is not set}"
: "${gcp_project_id:?Error: gcp_project_id is not set}"
: "${oidc_issuer:?Error: oidc_issuer is not set}"
: "${wif_audience:?Error: wif_audience is not set}"

if [[ ${gcp_project_id} == *CHANGEME* ]]; then
  echo "Error: set gcp_project_id in config.sh (run: tofu output -raw gcp_project_id)" >&2
  exit 1
fi
