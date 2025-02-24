#!/usr/bin/env bash
#config.sh
set -euo pipefail

# Configuration
declare -a stat_data=("sol:111" "clu:112" "ion:113")
declare -a dhcp_data=("sol:<missing>" "clu:<missing>" "ion:<missing>")
suffix=".nhlabs.org"
network="10.0.0."
lbvip="115"
install_disk="/dev/nvme0n1"
image="factory.talos.dev/installer-secureboot/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.9.4"
cluster_name="k8s.nhlabs.local"

# Ensure required variables are set
: "${stat_data:?Error: stat_data is not set}"
: "${network:?Error: network is not set}"
: "${install_disk:?Error: install_disk is not set}"
: "${image:?Error: image is not set}"
: "${lbvip:?Error: lbvip is not set}"
: "${cluster_name:?Error: cluster_name is not set}"
: "${suffix:?Error: suffix is not set}"
: "${dhcp_data:?Error: dhcp_data is not set}"
