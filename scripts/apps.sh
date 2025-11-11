#!/usr/bin/env bash
set -euo pipefail

valid_names=$(find manifests -mindepth 1 -maxdepth 1 -type d | sed 's|manifests/||')

usage() {
  printf "Generates base manifests; run from the root of homelab repo\n"
  printf "Usage: %s <app-name> [options]\n" "$0"
  printf "Options:\n"
  printf "  -h, --help  Show this help message\n"
  printf "  -v, --version  Show versions of components\n"
  printf "  -g, --generate  Generate new versions of components\n"
  printf "  -i, --interactive  Select an app to generate using fzf\n"
  printf "  -a, --all  Generate all apps\n"
  printf "Available Apps:\n"
  for i in ${valid_names}; do
    printf " - %s\n" "${i}"
  done
}

print_helper() {
  printf "creating %s base\n" "$1"
}

versions() {
  KUBEVIRT_VERSION=${KUBEVIRT_VERSION:-v1.6.1}
  CDI_VERSION=${CDI_VERSION:-v1.62.0}
  CONNECT_VERSION=${CONNECT_VERSION:-1.17.0}
  CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.17.2}
  EXTERNAL_DNS_VERSION=${EXTERNAL_DNS_VERSION:-v1.19.0}
  ROOK_VERSION=${ROOK_VERSION:-1.17.5}
  LOCAL_PATH_VERSION=${LOCAL_PATH_VERSION:-v0.0.31}
  MULTUS_VERSION=${MULTUS_VERSION:-v4.2.2}
}

print_versions() {
  versions
  printf "Kubevirt Version: %s\n" "${KUBEVIRT_VERSION}"
  printf "CDI Version: %s\n" "${CDI_VERSION}"
  printf "Connect Version: %s\n" "${CONNECT_VERSION}"
  printf "Cert-Manager Version: %s\n" "${CERT_MANAGER_VERSION}"
  printf "External DNS Version: %s\n" "${EXTERNAL_DNS_VERSION}"
  printf "Rook Version: %s\n" "${ROOK_VERSION}"
  printf "Local Path Version: %s\n" "${LOCAL_PATH_VERSION}"
  printf "Multus Version: %s\n" "${MULTUS_VERSION}"
}

generate_versions() {
  local CDI_URL_PATH="https://github.com/kubevirt/containerized-data-importer/releases"
  local KUBEVIRT_URL="https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt"
  versions
  NEW_CDI_VERSION=$(curl -s -w '%{redirect_url}' -o /dev/null "${CDI_URL_PATH}/latest" | awk -F/ '{print $NF}')
  NEW_KUBEVIRT_VERSION=$(curl -s -w '%{redirect_url}' "${KUBEVIRT_URL}")
  printf "Generating new versions...\n"
  printf "CDI: %s -> %s\n" "${CDI_VERSION}" "${NEW_CDI_VERSION}"
  printf "KUBEVIRT: %s -> %s\n" "${KUBEVIRT_VERSION}" "${NEW_KUBEVIRT_VERSION}"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
  else
    while [[ $# -gt 0 ]]; do
      case $1 in
        -h | --help)
          usage
          exit 0
          ;;
        -v | --version)
          print_versions
          exit 0
          ;;
        -g | --generate)
          generate_versions
          exit 0
          ;;
        -i | --interactive)
          echo "${valid_names}" | fzf --header "Select an app to generate" | xargs -I {} bash -c "scripts/apps.sh {}"
          exit 0
          ;;
        -a | all)
          versions
          for i in ${valid_names}; do
            if declare -f "${i}" > /dev/null; then
              "${i}"
            fi
          done
          exit 0
          ;;
        *)
          versions
          if echo "${valid_names}" | grep -qx "$1"; then
            if declare -f "$1" > /dev/null; then
              "$1"
              shift
            else
              echo "Function '$1' not defined"
              exit 1
            fi
          else
            echo "Unknown option: $1"
            usage
            exit 1
          fi
          ;;
      esac
    done
  fi
}

## Applications ##

kubevirt() {
  print_helper "${FUNCNAME[@]}"

  curl -Ls https://github.com/kubevirt/kubevirt/releases/download/"${KUBEVIRT_VERSION}"/kubevirt-operator.yaml | kubectl-slice --prune --remove-comments -t "{{ .kind | lower }}.yaml" -o manifests/kubevirt/base/
  pushd manifests/kubevirt/base/ && rm -rf kustomization.yaml && kustomize create --autodetect --recursive && popd
  printf "\n"
}

cdi() {
  print_helper "${FUNCNAME[@]}"
  local URL_PATH="https://github.com/kubevirt/containerized-data-importer/releases"

  mv manifests/cdi/base/customresourcedefinition.yaml /tmp/customresourcedefinition.yaml
  curl -sL "${URL_PATH}"/download/"${CDI_VERSION}"/cdi-operator.yaml | kubectl-slice --exclude CustomResourceDefinition/cdis.cdi.kubevirt.io --prune --remove-comments -t "{{ .kind | lower }}.yaml" -o manifests/cdi/base/
  mv /tmp/customresourcedefinition.yaml manifests/cdi/base/customresourcedefinition.yaml
  pushd manifests/cdi/base/ && kustomize create --autodetect --recursive && popd
  printf "\n"
}

connect() {
  print_helper "${FUNCNAME[@]}"

  cat > manifests/connect/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
helmCharts:
- name: connect
  namespace: connect
  releaseName: connect
  version: ${CONNECT_VERSION}
  repo: https://1password.github.io/connect-helm-charts
  includeCRDs: true
  skipHooks: true
  skipTests: true
  valuesInline:
    operator:
      create: true
EOF
  printf "Wrote manifests/connect/kustomization.yaml -- 82 bytes\n\n"
}

cert-manager() {
  print_helper "${FUNCNAME[@]}"

  patch=$(
    cat << EOF
config:
  enableGatewayAPI: true
  apiVersion: "controller.config.cert-manager.io/v1alpha1"
  kind: "ControllerConfiguration"
crds:
  enabled: true
EOF
  )

  helm template cert-manager jetstack/cert-manager --namespace cert-manager --version "${CERT_MANAGER_VERSION}" -f <(echo "${patch}") \
    | kubectl-slice --prune --remove-comments -t "{{ .kind | lower }}.yaml" -o manifests/cert-manager/base/ && pushd manifests/cert-manager/base \
    && kubectl create ns cert-manager --dry-run=client -oyaml > 01-namespace.yaml && kustomize create --recursive --autodetect && popd
}

external-dns() {
  print_helper "${FUNCNAME[@]}"

  patch=$(
    cat << EOF
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
  - name: CF_API_EMAIL
    valueFrom:
      secretKeyRef:
        name: cloudflare-secret
        key: email
sources:
  - service
  - gateway-httproute
domainFilters:
  - nhlabs.org
provider:
  name: cloudflare
policy: sync
EOF
  )

  helm template external-dns external-dns/external-dns --version "${EXTERNAL_DNS_VERSION}" --namespace external-dns --no-hooks --include-crds --skip-tests \
    -f <(echo "${patch}") | sed '/helm.sh\/chart:/d; /app.kubernetes.io\/managed-by:/d; /app.kubernetes.io\/version:/d; /app.kubernetes.io\/component:/d; /app.kubernetes.io\/part-of:/d' | kubectl-slice --prune --remove-comments -t "{{ .kind | lower }}.yaml" -o manifests/external-dns/base/
  pushd manifests/external-dns/base/ && kubectl create ns external-dns --dry-run=client -oyaml > 01-namespace.yaml && kustomize create --recursive --autodetect && popd
  unset patch
}

rook() {
  print_helper "${FUNCNAME[@]}"

  patch=$(
    cat << EOF
crds:
  enabled: true
rbacEnable: true
nfs:
  enabled: true

EOF
  )
  helm template --namespace rook-ceph rook-ceph rook-release/rook-ceph --version "${ROOK_VERSION}" -f <(echo "${patch}") | sed -e 's/^#.*//g' | kubectl-slice --prune --remove-comments -t "{{ .kind | lower }}.yaml" -o manifests/rook/base/
  pushd manifests/rook/base/ && kubectl create ns rook-ceph --dry-run=client -oyaml > 01-namespace.yaml && kustomize create --autodetect --recursive && popd

  patch2=$(
    cat << EOF
toolbox:
  enabled: true
EOF
  )
  helm template --namespace rook-ceph rook-ceph-cluster rook-release/rook-ceph-cluster --version "${ROOK_VERSION}" -f <(echo "${patch2}") | sed -e 's/^#.*//g' | kubectl-slice --prune --remove-comments -t "{{ .kind | lower }}.yaml" -o manifests/rook/overlays/
  pushd manifests/rook/overlays/ && kustomize create --autodetect --recursive && popd
}

local-path() {
  print_helper "${FUNCNAME[@]}"

  rm -rf manifests/local-path-provisioner/base/*
  curl -sL "https://raw.githubusercontent.com/rancher/local-path-provisioner/refs/tags/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" | kubectl-slice --prune --remove-comments -t "{{ .kind | lower }}.yaml" -o manifests/local-path/base/
  pushd manifests/local-path/base/ && kustomize create --autodetect --recursive && popd

}

multus() {
  print_helper "${FUNCNAME[@]}"

  rm -rf manifests/multus/base/*
  curl -sL "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/refs/tags/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml" | grep -Ev "^#.*" | kubectl-slice --prune --remove-comments -t "{{ .kind | lower }}.yaml" -o manifests/multus/base/
  pushd manifests/multus/base/ && kustomize create --autodetect --recursive && popd

}

# Main execution
main "$@"
