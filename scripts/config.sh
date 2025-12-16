#!/usr/bin/env bash
set -euo pipefail
declare -a stat_data=("sol:111" "clu:112" "ion:113")
declare -a dhcp_data=("sol:<missing>" "clu:<missing>" "ion:<missing>")
suffix=".nhlabs.org"
network="10.0.0."
lbvip="115"
install_disk="/dev/nvme0n1"
image="factory.talos.dev/installer-secureboot/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.9.5"
cluster_name="k8s.nhlabs.local"
: "${stat_data:?Error: stat_data is not set}"
: "${network:?Error: network is not set}"
: "${install_disk:?Error: install_disk is not set}"
: "${image:?Error: image is not set}"
: "${lbvip:?Error: lbvip is not set}"
: "${cluster_name:?Error: cluster_name is not set}"
: "${suffix:?Error: suffix is not set}"
: "${dhcp_data:?Error: dhcp_data is not set}"

### Application Definitions

# --- Versions ---
versions() {
    KUBEVIRT_VERSION=${KUBEVIRT_VERSION:-v1.7.0}
    CDI_VERSION=${CDI_VERSION:-v1.64.0}
    CONNECT_VERSION=${CONNECT_VERSION:-2.1.1}
    CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.19.2}
    EXTERNAL_DNS_VERSION=${EXTERNAL_DNS_VERSION:-1.19.0}
    ROOK_VERSION=${ROOK_VERSION:-v1.18.8}
    LOCAL_PATH_VERSION=${LOCAL_PATH_VERSION:-v0.0.32}
    MULTUS_VERSION=${MULTUS_VERSION:-v4.2.3}
    OPENTELEMETRY_VERSION=${OPENTELEMETRY_VERSION:-0.79.0}
    METRICS_SERVER_VERSION=${METRICS_SERVER_VERSION:-v0.8.0}
    KUBELET_SERVING_CERT_VERSION=${KUBELET_SERVING_CERT_VERSION:-v0.10.1}
    ARGOCD_VERSION=${ARGOCD_VERSION:-v3.2.1}
    GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.4.1}
    CILIUM_VERSION=${CILIUM_VERSION:-1.18.4}
}

# -- URL Based Apps --
## Usage: fetch_url <app> <ver> <url> [namespace] [extra_slice_args] [stream_filter] [create_ns]
kubevirt() {
    local owner="kubevirt"
    local repo="kubevirt"

    fetch_url "kubevirt" "${KUBEVIRT_VERSION}" \
        "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml" \
        "kubevirt" \
        "" \
        "" \
        "true" \
        "${owner}" \
        "${repo}"
}

cdi() {
    local owner="kubevirt"
    local repo="containerized-data-importer"

    fetch_url "cdi" "${CDI_VERSION}" \
        "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml" \
        "cdi" \
        "--exclude CustomResourceDefinition/cdis.cdi.kubevirt.io" \
        "" \
        "true" \
        "${owner}" \
        "${repo}"
}

local-path() {
    local owner="rancher"
    local repo="local-path-provisioner"

    fetch_url "local-path" "${LOCAL_PATH_VERSION}" \
        "https://raw.githubusercontent.com/rancher/local-path-provisioner/refs/tags/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" \
        "local-path-storage" \
        "" \
        "" \
        "true" \
        "${owner}" \
        "${repo}"
}

multus() {
    local owner="k8snetworkplumbingwg"
    local repo="multus-cni"

    fetch_url "multus" "${MULTUS_VERSION}" \
        "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/refs/tags/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml" \
        "kube-system" \
        "" \
        'grep -Ev "^#.*"' \
        "false" \
        "${owner}" \
        "${repo}"
}

metrics-server() {
    local owner="kubernetes-sigs"
    local repo="metrics-server"

    fetch_url "metrics-server" "${METRICS_SERVER_VERSION}" \
      "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" \
      "kube-system" \
      "" \
      "" \
      "false" \
      "${owner}" \
      "${repo}"
}

kubelet-serving() {
    local owner="alex1989hu"
    local repo="kubelet-serving-cert-approver"
    fetch_url "kubelet-serving" "${KUBELET_SERVING_CERT_VERSION}" \
      "https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/${KUBELET_SERVING_CERT_VERSION}/deploy/standalone-install.yaml" \
      "kubelet-serving-cert-approver" \
      "" \
      "" \
      "true" \
      "${owner}" \
      "${repo}"
}

argocd() {
    local owner="argoproj"
    local repo="argo-cd"

    fetch_url "argocd" "${ARGOCD_VERSION}" \
      "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
      "argocd" \
      "" \
      "" \
      "true" \
      "${owner}" \
      "${repo}"
}

shared-gateway() {
    local owner="kubernetes-sigs"
    local repo="gateway-api"

    fetch_url "shared-gateway" "${GATEWAY_API_VERSION}" \
      "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
      "shared-gateway" \
      "" \
      'grep -Ev "^#.*"' \
      "true" \
      "${owner}" \
      "${repo}"
}

# -- Helm Based Apps --
## Usage: fetch_helm <app> <ver> <repo_name> <repo_url> <chart> <release_name> <namespace> [values_callback_function]
connect() {
    _connect_values() {
        cat <<EOF
operator:
  create: true
EOF
    }
    fetch_helm "connect" "${CONNECT_VERSION}" \
        "1password" "https://1password.github.io/connect-helm-charts" "connect" \
        "connect" "connect" "_connect_values"
}

cert-manager() {
    _cert_values() {
        cat <<EOF
config:
  enableGatewayAPI: true
  apiVersion: "controller.config.cert-manager.io/v1alpha1"
  kind: "ControllerConfiguration"
crds:
  enabled: true
extraArgs:
  - --dns01-recursive-nameservers-only
  - --dns01-recursive-nameservers=1.1.1.1:53
EOF
    }
    fetch_helm "cert-manager" "${CERT_MANAGER_VERSION}" \
        "jetstack" "https://charts.jetstack.io" "cert-manager" \
        "cert-manager" "cert-manager" "_cert_values"
}

external-dns() {
    _ext_dns_values() {
        cat <<EOF
rbac:
  create: true
serviceAccount:
  create: true
  automountServiceAccountToken: true
env:
  - name: CF_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflare-secret
        key: apikey
domainFilters:
  - nhlabs.org
provider:
  name: cloudflare
policy: sync
sources:
  - service
  - gateway-httproute
EOF
    }
    fetch_helm "external-dns" "${EXTERNAL_DNS_VERSION}" \
        "external-dns" "https://kubernetes-sigs.github.io/external-dns/" "external-dns" \
        "external-dns" "external-dns" "_ext_dns_values"
}

rook() {
    _rook_values() {
        cat <<EOF
crds:
  enabled: true
rbacEnable: true
nfs:
  enabled: true
EOF
    }
    fetch_helm "rook" "${ROOK_VERSION}" \
        "rook-release" "https://charts.rook.io/release" "rook-ceph" \
        "rook-ceph" "rook-ceph" "_rook_values" "" 'grep -Ev "^#.*"'
}

cilium() {
    _cilium_values() {
        cat <<EOF
    hubble:
      relay:
        enabled: true
      tls:
        auto:
          enabled: true
          method: certmanager
          certValidityDuration: 60
          certManagerIssuerRef:
            name: "ca-issuer"
            kind: "ClusterIssuer"
            group: "cert-manager.io"
    operator:
      replicas: 1
    k8sServiceHost: localhost
    k8sServicePort: 7445
    debug:
      verbose: ""
    cgroup:
      hostRoot: /sys/fs/cgroup
      autoMount:
        enabled: false
    bandwidthManager:
      enabled: true
      bbr: true
    ipam:
      mode: kubernetes
    l2announcements:
      enabled: true
      leaseDuration: 3s
      leaseRenewDeadline: 1s
      leaseRetryPeriod: 200ms
    k8sClientRateLimit:
      qps: 100
      burst: 200
    gatewayAPI:
      enabled: true
    kubeProxyReplacement: true
    cni:
      exclusive: true
    encryption:
      enabled: true
      type: wireguard
    securityContext:
      capabilities:
        ciliumAgent:
        - CHOWN
        - KILL
        - NET_ADMIN
        - NET_RAW
        - IPC_LOCK
        - SYS_ADMIN
        - SYS_RESOURCE
        - DAC_OVERRIDE
        - FOWNER
        - SETGID
        - SETUID
        cleanCiliumState:
        - NET_ADMIN
        - SYS_ADMIN
        - SYS_RESOURCE
EOF
    }
    fetch_helm "cilium" "${CILIUM_VERSION}" \
        "cilium" "https://helm.cilium.io/" "cilium" \
        "cilium" "kube-system" "_cilium_values" "" 'grep -Ev "^#.*"'
}
