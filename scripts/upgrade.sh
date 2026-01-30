#!/usr/bin/env bash
set -euo pipefail

# Config
CTX="k8s.nhlabs.local"
NODE="10.0.0.111"
FACTORY_ID="376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"

# Fetch Clean Versions (xargs trims whitespace, head ensures single line)
CUR_TALOS=$(talosctl version --short 2>/dev/null | grep -E 'Tag:' | awk '{print $2}' | tr -d 'v' | head -n1)
UP_TALOS=$(curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | sed -nE 's/.*"tag_name": "v?([0-9.]+).*/\1/p' | head -n1)

CUR_K8S=$(kubectl get --raw /version --context "${CTX}" 2>/dev/null | sed -nE 's/.*"gitVersion": "v?([0-9.]+).*/\1/p' | head -n1)
UP_K8S=$(curl -s https://api.github.com/repos/siderolabs/kubelet/releases/latest | sed -nE 's/.*"tag_name": "v?([0-9.]+).*/\1/p' | head -n1)

# Helper
check_upgrade() {
    local name=$1; local cur=$2; local up=$3; local cmd=$4

    # Check if vars are empty (error handling)
    if [[ -z "${cur}" || -z "${up}" ]]; then echo "${name}: Could not determine version"; return; fi

    # Strict string inequality + Version comparison
    if [[ "${cur}" != "${up}" && "$(printf '%s\n%s' "${cur}" "${up}" | sort -V | tail -n1)" == "${up}" ]]; then
        echo "${name} upgrade available: v${cur} -> v${up}"
        echo "${cmd}"
    else
        echo "${name}: v${cur} (Up to date)"
    fi
}

check_upgrade "Talos" "${CUR_TALOS}" "${UP_TALOS}" \
  "talosctl upgrade -i factory.talos.dev/metal-installer-secureboot/${FACTORY_ID}:v${UP_TALOS} --context ${CTX} --wait=false"

check_upgrade "K8s" "${CUR_K8S}" "${UP_K8S}" \
  "talosctl upgrade-k8s --context ${CTX} --to v${UP_K8S} --nodes ${NODE}"
