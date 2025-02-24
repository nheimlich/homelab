#!/usr/bin/env bash
#install.sh
set -euo pipefail

# Source config if it exists, otherwise exit
CONFIG_FILE="$(dirname "$0")/config.sh"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=./scripts/config.sh
    source "$CONFIG_FILE"
else
    echo "Error: Missing $CONFIG_FILE" >&2
    exit 1
fi

# Ensure required variables are set
: "${network:?Error: network is not set}"
: "${lbvip:?Error: lbvip is not set}"

# Post-installation setup/cleanup
post_install() {
    until nc -v -w 1 "${network}${lbvip}" 6443; do
        echo "Waiting for API server to come online..."
        sleep 5
    done
    printf "Validating that API server is ready to receive requests..."
    until kubectl get --raw='/readyz' &> /dev/null; do
        printf "."
        sleep 5
    done
    printf "Waiting for Cilium to be installed..."
    kubectl -n kube-system wait --for=condition=complete job/cilium-install --timeout="6000s" || true
    kubectl delete clusterrolebinding cilium-install -n kube-system || true
    kubectl delete serviceaccount cilium-install -n kube-system || true
    kubectl delete job cilium-install -n kube-system || true

    pushd ./overlays/production/connect/ || exit
    kustomize build . | kubectl apply -f -
    popd || exit

    pushd ./overlays/production/argocd/ || exit
    kustomize build . | kubectl apply -f -
    popd || exit

    kubectl apply -f ./clusters/production/applications.yaml
}

post_install
