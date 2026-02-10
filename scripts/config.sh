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
  CONNECT_VERSION=${CONNECT_VERSION:-2.2.1}
  CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.19.3}
  EXTERNAL_DNS_VERSION=${EXTERNAL_DNS_VERSION:-1.20.0}
  ROOK_CEPH_VERSION=${ROOK_CEPH_VERSION:-v1.19.0}
  LOCAL_PATH_VERSION=${LOCAL_PATH_VERSION:-v0.0.34}
  OPENTELEMETRY_OPERATOR_VERSION=${OPENTELEMETRY_OPERATOR_VERSION:-0.105.0}
  METRICS_SERVER_VERSION=${METRICS_SERVER_VERSION:-v0.8.1}
  KUBELET_SERVING_VERSION=${KUBELET_SERVING_VERSION:-v0.10.3}
  ARGOCD_VERSION=${ARGOCD_VERSION:-v3.3.0}
  GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.4.1}
  CILIUM_VERSION=${CILIUM_VERSION:-1.18.6}
}

# --- App Definitions (URL Based) ---
# fetch_url()
#  1: app    - Folder name in manifests/
#  2: ver    - Version tag (e.g., v1.0.0)
#  3: url    - Source manifest URL
#  4: ns     - K8s namespace
#  5: cns    - Create 01-namespace.yaml manifest? (true/false)
#  6: uns    - Set 'namespace:' in kustomization.yaml? (true/false)
#  7: args   - Extra kubectl-slice flags
#  8: filter - Pipe filter (e.g. 'grep -v')
#  9: owner  - GitHub Owner for version check
# 10: repo   - GitHub Repo for version check

kubevirt() {
  fetch_url \
    "kubevirt" \
    "${KUBEVIRT_VERSION}" \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml" \
    "kubevirt" \
    "true" \
    "true" \
    "" \
    "" \
    "kubevirt" \
    "kubevirt"
}

cdi() {
  fetch_url \
    "cdi" \
    "${CDI_VERSION}" \
    "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml" \
    "cdi" \
    "true" \
    "true" \
    "" \
    "" \
    "kubevirt" \
    "containerized-data-importer"
}

local-path() {
  fetch_url \
    "local-path" \
    "${LOCAL_PATH_VERSION}" \
    "https://raw.githubusercontent.com/rancher/local-path-provisioner/refs/tags/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" \
    "local-path-storage" \
    "true" \
    "true" \
    "" \
    "" \
    "rancher" \
    "local-path-provisioner"
}

metrics-server() {
  fetch_url \
    "metrics-server" \
    "${METRICS_SERVER_VERSION}" \
    "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" \
    "kube-system" \
    "false" \
    "false" \
    "" \
    "" \
    "kubernetes-sigs" \
    "metrics-server"
}

kubelet-serving() {
  fetch_url \
    "kubelet-serving" \
    "${KUBELET_SERVING_VERSION}" \
    "https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/${KUBELET_SERVING_VERSION}/deploy/standalone-install.yaml" \
    "kubelet-serving-cert-approver" \
    "true" \
    "true" \
    "" \
    "" \
    "alex1989hu" \
    "kubelet-serving-cert-approver"
}

argocd() {
  fetch_url \
    "argocd" \
    "${ARGOCD_VERSION}" \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
    "argocd" \
    "true" \
    "true" \
    "" \
    "" \
    "argoproj" \
    "argo-cd"
}

shared-gateway() {
  fetch_url \
    "shared-gateway" \
    "${GATEWAY_API_VERSION}" \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    "shared-gateway" \
    "true" \
    "true" \
    "" \
    'grep -Ev "^#.*"' \
    "kubernetes-sigs" \
    "gateway-api"
}

# --- App Definitions (Helm Based) ---
# fetch_helm()
#  1: app    - Folder name in manifests/
#  2: ver    - Version tag
#  3: rname  - Helm repo alias
#  4: rurl   - Helm repo URL
#  5: chart  - Chart name (defaults to app name if empty)
#  6: rel    - Release name (defaults to app name if empty)
#  7: ns     - K8s namespace
#  8: cns    - Create namespace manifest? (true/false)
#  9: uns    - Set 'namespace:' in kustomization.yaml? (true/false)
# 10: cb     - Values generator function (_vals)
# 11: args   - Extra kubectl-slice flags
# 12: filter - Pipe filter (e.g. 'grep -v')

connect() {
  _vals() {
    cat <<EOF
operator:
  create: true
acceptanceTests:
  enabled: false
  healthCheck:
    enabled: false
EOF
  }
  fetch_helm \
    "connect" \
    "${CONNECT_VERSION}" \
    "1password" \
    "https://1password.github.io/connect-helm-charts" \
    "connect" \
    "connect" \
    "connect" \
    "true" \
    "true" \
    "_vals" \
    "" \
    ""
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
  fetch_helm \
    "cert-manager" \
    "${CERT_MANAGER_VERSION}" \
    "jetstack" \
    "https://charts.jetstack.io" \
    "cert-manager" \
    "cert-manager" \
    "cert-manager" \
    "true" \
    "false" \
    "_vals" \
    "" \
    ""
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
  fetch_helm \
    "external-dns" \
    "${EXTERNAL_DNS_VERSION}" \
    "external-dns" \
    "https://kubernetes-sigs.github.io/external-dns/" \
    "external-dns" \
    "external-dns" \
    "external-dns" \
    "true" \
    "true" \
    "_vals" \
    "" \
    ""
}

rook-ceph() {
  _vals() { cat <<EOF
EOF
  }
  fetch_helm \
    "rook-ceph" \
    "${ROOK_CEPH_VERSION}" \
    "rook-release" \
    "https://charts.rook.io/release" \
    "rook-ceph" \
    "rook-ceph" \
    "rook-ceph" \
    "true" \
    "true" \
    "_vals" \
    "" \
    'grep -Ev "^#.*"'
}

rook-ceph-cluster() {
  _vals() {
    cat <<EOF
cephObjectStores: []
toolbox:
  enabled: true
cephBlockPoolsVolumeSnapshotClass:
  enabled: true
cephFileSystemVolumeSnapshotClass:
  enabled: true
cephBlockPools:
- name: ceph-blockpool
  spec:
    failureDomain: host
    replicated:
      size: 1
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
  fetch_helm \
    "rook-ceph-cluster" \
    "${ROOK_CEPH_VERSION}" \
    "rook-release" \
    "https://charts.rook.io/release" \
    "rook-ceph-cluster" \
    "rook-ceph-cluster" \
    "rook-ceph" \
    "false" \
    "true" \
    "_vals" \
    "" \
    'grep -Ev "^#.*"'
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
  fetch_helm \
    "cilium" \
    "${CILIUM_VERSION}" \
    "cilium" \
    "https://helm.cilium.io/" \
    "cilium" \
    "cilium" \
    "kube-system" \
    "false" \
    "false" \
    "_vals" \
    "" \
    'grep -Ev "^#.*"'
}
opentelemetry-operator() {
  _vals() {
    cat <<EOF
manager:
  collectorImage:
    repository: "otel/opentelemetry-collector-k8s"
admissionWebhooks:
  certManager:
    enabled: true
  autoGenerateCert:
    enabled: false
EOF
}
  fetch_helm \
    "opentelemetry-operator" \
    "${OPENTELEMETRY_OPERATOR_VERSION}" \
    "opentelemetry" \
    "https://open-telemetry.github.io/opentelemetry-helm-charts" \
    "" \
    "" \
    "opentelemetry-operator" \
    "true" \
    "false" \
    "_vals" \
    "" \
    ""
}
