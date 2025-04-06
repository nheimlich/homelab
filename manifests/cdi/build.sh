#!/usr/bin/env bash
set -euo pipefail

export TAG=$(curl -s -w %{redirect_url} https://github.com/kubevirt/containerized-data-importer/releases/latest)
export VERSION=$(echo ${TAG##*/})

if [ -z "$TAG" ]; then
  echo "Failed to extract release tag. Exiting." >&2
  exit 1
fi

curl -sL https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-operator.yaml | kubectl-slice -o base/
curl -sL https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-cr.yaml | kubectl-slice -o overlay/

for dir in base overlay; do
  if [ -d "$dir" ]; then
    pushd "$dir" > /dev/null
    kustomize create --autodetect
    popd > /dev/null
  else
    echo "Directory $dir does not exist. Exiting." >&2
    exit 1
  fi
done

cat << EOF > kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- base
- overlay
EOF


printf "Kustomization files created successfully.\n"
