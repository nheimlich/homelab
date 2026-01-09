#!/usr/bin/env bash
set -euo pipefail

# --- Global Configuration ---
declare -a stat_data=("sol:111" "clu:112" "ion:113")
declare -a dhcp_data=("sol:<missing>" "clu:<missing>" "ion:<missing>")
suffix=".nhlabs.org"
network="10.0.0."
lbvip="115"
install_disk="/dev/nvme0n1"
image="factory.talos.dev/installer-secureboot/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.12.1"
cluster_name="k8s.nhlabs.local"

# --- Validation ---
: "${stat_data:?Error: stat_data is not set}"
: "${network:?Error: network is not set}"
: "${install_disk:?Error: install_disk is not set}"
: "${image:?Error: image is not set}"
: "${lbvip:?Error: lbvip is not set}"
: "${cluster_name:?Error: cluster_name is not set}"
: "${suffix:?Error: suffix is not set}"
: "${dhcp_data:?Error: dhcp_data is not set}"

# --- Version Definitions ---
versions() {
  KUBEVIRT_VERSION=${KUBEVIRT_VERSION:-v1.7.0}
  CDI_VERSION=${CDI_VERSION:-v1.64.0}
  CONNECT_VERSION=${CONNECT_VERSION:-2.1.1}
  CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.19.2}
  EXTERNAL_DNS_VERSION=${EXTERNAL_DNS_VERSION:-1.20.0}
  ROOK_VERSION=${ROOK_VERSION:-v1.18.8}
  LOCAL_PATH_VERSION=${LOCAL_PATH_VERSION:-v0.0.33}
  MULTUS_VERSION=${MULTUS_VERSION:-v4.2.3}
  OPENTELEMETRY_VERSION=${OPENTELEMETRY_VERSION:-0.79.0}
  METRICS_SERVER_VERSION=${METRICS_SERVER_VERSION:-v0.8.0}
  KUBELET_SERVING_CERT_VERSION=${KUBELET_SERVING_CERT_VERSION:-v0.10.1}
  ARGOCD_VERSION=${ARGOCD_VERSION:-v3.2.3}
  GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.4.1}
  CILIUM_VERSION=${CILIUM_VERSION:-1.18.5}
}

# --- App Definitions (URL Based) ---

kubevirt() {
  fetch_url "kubevirt" "${KUBEVIRT_VERSION}" \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml" \
    "kubevirt" "true" "" "" "kubevirt" "kubevirt"
}

cdi() {
  fetch_url "cdi" "${CDI_VERSION}" \
    "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml" \
    "cdi" "true" "" "" "kubevirt" "containerized-data-importer"
}

local-path() {
  fetch_url "local-path" "${LOCAL_PATH_VERSION}" \
    "https://raw.githubusercontent.com/rancher/local-path-provisioner/refs/tags/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" \
    "local-path-storage" "true" "" "" "rancher" "local-path-provisioner"
}

multus() {
  fetch_url "multus" "${MULTUS_VERSION}" \
    "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/refs/tags/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml" \
    "kube-system" "false" "" 'grep -Ev "^#.*"' "k8snetworkplumbingwg" "multus-cni"
}

metrics-server() {
  fetch_url "metrics-server" "${METRICS_SERVER_VERSION}" \
    "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" \
    "kube-system" "false" "" "" "kubernetes-sigs" "metrics-server"
}

kubelet-serving() {
  fetch_url "kubelet-serving" "${KUBELET_SERVING_CERT_VERSION}" \
    "https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/${KUBELET_SERVING_CERT_VERSION}/deploy/standalone-install.yaml" \
    "kubelet-serving-cert-approver" "true" "" "" "alex1989hu" "kubelet-serving-cert-approver"
}

argocd() {
  fetch_url "argocd" "${ARGOCD_VERSION}" \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
    "argocd" "true" "" "" "argoproj" "argo-cd"
}

shared-gateway() {
  fetch_url "shared-gateway" "${GATEWAY_API_VERSION}" \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    "shared-gateway" "true" "" 'grep -Ev "^#.*"' "kubernetes-sigs" "gateway-api"
}

# --- App Definitions (Helm Based) ---

connect() {
  _vals() {
    cat <<EOF
operator:
  create: true
EOF
  }
  fetch_helm "connect" "${CONNECT_VERSION}" "1password" "https://1password.github.io/connect-helm-charts" "connect" "connect" "connect" "true" "_vals"
}

cert-manager() {
  _vals() {
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
  fetch_helm "cert-manager" "${CERT_MANAGER_VERSION}" "jetstack" "https://charts.jetstack.io" "cert-manager" "cert-manager" "cert-manager" "true" "_vals"
}

external-dns() {
  _vals() {
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
  fetch_helm "external-dns" "${EXTERNAL_DNS_VERSION}" "external-dns" "https://kubernetes-sigs.github.io/external-dns/" "external-dns" "external-dns" "external-dns" "true" "_vals"
}

#app="$1" ver="$2" rname="$3" rurl="$4" chart="$5" rel="$6" ns="${7:-}" cns="${8:-true}" cb="${9:-}" args="${10:-}" filter="${11:-}"
rook() {
  _vals() {
    cat <<EOF
EOF
  }
  fetch_helm "rook" "${ROOK_VERSION}" "rook-release" "https://charts.rook.io/release" "rook-ceph" "rook-ceph" "rook-ceph" "true" "_vals" "" 'grep -Ev "^#.*"'
}
rook-ceph-cluster() {
  _vals() {
    cat <<EOF
cephObjectStores: []
toolbox:
  enabled: true
cephBlockPools:
- name: ceph-blockpool
  spec:
    failureDomain: host
    replicated:
      size: 2
  storageClass:
    enabled: true
    name: ceph-block
    isDefault: true
    reclaimPolicy: Delete
    allowVolumeExpansion: true
    volumeBindingMode: "Immediate"
    allowedTopologies: []
    parameters:
      csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
      csi.storage.k8s.io/controller-expand-secret-namespace: 'rook-ceph'
      csi.storage.k8s.io/controller-publish-secret-name: rook-csi-rbd-provisioner
      csi.storage.k8s.io/controller-publish-secret-namespace: 'rook-ceph'
      csi.storage.k8s.io/fstype: ext4
      csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
      csi.storage.k8s.io/node-stage-secret-namespace: 'rook-ceph'
      csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
      csi.storage.k8s.io/provisioner-secret-namespace: 'rook-ceph'
      imageFeatures: layering
      imageFormat: "2"
EOF
  }
  fetch_helm "rook-ceph-cluster" "${ROOK_VERSION}" "rook-release" "https://charts.rook.io/release" "rook-ceph-cluster" "rook-ceph-cluster" "rook-ceph" "false" "_vals" "" 'grep -Ev "^#.*"'
}

cilium() {
  _vals() {
    cat <<EOF
hubble:
  enabled: false
operator:
  replicas: 1
k8sServiceHost: localhost
k8sServicePort: 7445
debug:
  enabled: true
cgroup:
  hostRoot: /sys/fs/cgroup
  autoMount:
    enabled: false
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
bandwidthManager:
  enabled: true
  bbr: true
gatewayAPI:
  enabled: true
  gatewayClass:
    create: "true"
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
  fetch_helm "cilium" "${CILIUM_VERSION}" "cilium" "https://helm.cilium.io/" "cilium" "cilium" "kube-system" "false" "_vals" "" 'grep -Ev "^#.*"'
}
