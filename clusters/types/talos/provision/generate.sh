#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="$(dirname "$0")/config.sh"
if [[ -f ${CONFIG_FILE} ]]; then
  source "${CONFIG_FILE}"
else
  echo "Error: Missing ${CONFIG_FILE}" >&2
  exit 1
fi

: "${stat_data:?Error: stat_data is not set}"
: "${network:?Error: network is not set}"
: "${install_disk:?Error: install_disk is not set}"
: "${image:?Error: image is not set}"
: "${lbvip:?Error: lbvip is not set}"
: "${gcp_project_id:?Error: gcp_project_id is not set}"
: "${oidc_issuer:?Error: oidc_issuer is not set}"
: "${wif_audience:?Error: wif_audience is not set}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../" && pwd)"

gcloud secrets versions access latest --secret=talos-secrets --project="${gcp_project_id}" > secrets.yaml

JWKS_TMP="$(mktemp)"
"${REPO_ROOT}/scripts/gen-oidc-jwk" secrets.yaml "${JWKS_TMP}" > /dev/null
if ! cmp -s "${JWKS_TMP}" "${REPO_ROOT}/oidc/openid/v1/jwks"; then
  echo "Error: OIDC JWKS is out of date. Regenerate and sync to the site repo: scripts/gen-oidc-jwk <secrets.yaml> oidc/openid/v1/jwks" >&2
  rm -f "${JWKS_TMP}"
  exit 1
fi
rm -f "${JWKS_TMP}"

generate_configs() {
  mkdir -p configs/patches
  talosctl gen config k8s.nhlabs.local --with-secrets secrets.yaml https://"${network}${lbvip}":6443 --force --additional-sans \
    "${network}"111,"${network}"112,"${network}"113,sol,clu,ion,sol.nhlabs.local,clu.nhlabs.local,ion.nhlabs.local --with-docs=false \
    --install-image "${image}" --output-types controlplane -o controlplane.yaml
  for pair in "${stat_data[@]}"; do
    IFS=":" read -r n i <<< "${pair}"
    echo "Generating patch for ${n} (IP: ${network}${i})..."
    cat << EOF > configs/patches/"${n}".patch
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: "${n}"
auto: off
---
debug: false
machine:
  files:
    - path: /etc/cri/conf.d/20-customization.part
      op: create
      content: |
        [plugins."io.containerd.cri.v1.images"]
          discard_unpacked_layers = false
  kubelet:
    extraMounts:
      - destination: /var/local-path-provisioner
        type: bind
        source: /var/local-path-provisioner
        options:
          - bind
          - rshared
          - rw
    extraArgs:
      rotate-server-certificates: true
      feature-gates: "InPlacePodVerticalScaling=true"

  systemDiskEncryption:
    ephemeral:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}
    state:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}

  install:
      disk: "${install_disk}"
      image: "${image}"
      wipe: true

  nodeLabels:
    \$patch: delete

  network:
    interfaces:
      - deviceSelector:
          physical: true
        dhcp: false
        vip:
          ip: "${network}${lbvip}"
        addresses:
          - "${network}${i}/24"
        routes:
          - network: 0.0.0.0/0
            gateway: "${network}1"
cluster:

  network:
    cni:
      name: none

  proxy:
    disabled: true

  apiServer:
    extraArgs:
      service-account-issuer: "${oidc_issuer}"
      api-audiences: "https://${network}${lbvip}:6443,${wif_audience}"
    admissionControl:
      - name: PodSecurity
        configuration:
          defaults:
            enforce: privileged

  allowSchedulingOnControlPlanes: true

  inlineManifests:
    - name: cluster-bootstrap
      contents: |-
        ---
        apiVersion: v1
        kind: Namespace
        metadata:
          name: external-secrets
        ---
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: bootstrap-admin
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: cluster-admin
        subjects:
        - kind: ServiceAccount
          name: default
          namespace: kube-system
        ---
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: bootstrap-install
          namespace: kube-system
        spec:
          backoffLimit: 6
          activeDeadlineSeconds: 900
          ttlSecondsAfterFinished: 1000
          template:
            metadata:
              labels:
                app: bootstrap-install
            spec:
              restartPolicy: OnFailure
              tolerations:
                - effect: NoSchedule
                  operator: Exists
                - effect: NoExecute
                  operator: Exists
                - effect: PreferNoSchedule
                  operator: Exists
                - key: node-role.kubernetes.io/control-plane
                  operator: Exists
                  effect: NoSchedule
                - key: node-role.kubernetes.io/control-plane
                  operator: Exists
                  effect: NoExecute
                - key: node-role.kubernetes.io/control-plane
                  operator: Exists
                  effect: PreferNoSchedule
              affinity:
                nodeAffinity:
                  requiredDuringSchedulingIgnoredDuringExecution:
                    nodeSelectorTerms:
                      - matchExpressions:
                          - key: node-role.kubernetes.io/control-plane
                            operator: Exists
              serviceAccount: default
              serviceAccountName: default
              hostNetwork: true
              volumes:
              - name: bootstrap-log
                hostPath:
                  path: /var/log/bootstrap
                  type: DirectoryOrCreate
              containers:
              - name: bootstrap-install
                image: alpine/curl
                volumeMounts:
                - name: bootstrap-log
                  mountPath: /var/log/bootstrap
                env:
                - name: KUBERNETES_SERVICE_HOST
                  value: "localhost"
                - name: KUBERNETES_SERVICE_PORT
                  value: "7445"
                command:
                  - "/bin/sh"
                  - "-c"
                  - |
                    set -uo pipefail
                    LOG=/var/log/bootstrap/bootstrap-install.log
                    : > "\${LOG}"
                    exec >> "\${LOG}" 2>&1

                    TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
                    API_SERVER="https://localhost:7445"
                    AUTH_HEADER="Authorization: Bearer \${TOKEN}"

                    retry() {
                      until "\$@"; do
                        echo "retrying: \$*"
                        sleep 5
                      done
                    }

                    until curl -sfk -H "\${AUTH_HEADER}" "\${API_SERVER}/readyz" > /dev/null 2>&1; do
                      sleep 2
                    done

                    apk update && apk add --no-cache git kubectl kustomize helm

                    rm -rf /repo
                    retry git clone -b dev --single-branch https://github.com/nheimlich/homelab.git /repo

                    cd /repo/manifests || exit 1

                    kustomize build cilium/overlays/homelab | kubectl apply --server-side --force-conflicts -f -
                    sleep 5

                    kustomize build argocd/overlays/homelab | kubectl apply --server-side --force-conflicts -n argocd -f -

                    cd /repo || exit 1

                    retry sh -c 'kubectl apply --server-side --force-conflicts -f clusters/envs/homelab/applications.yaml'

                    until kubectl get deployment -n argocd argocd-server > /dev/null 2>&1; do
                      sleep 5
                    done

                    until ! kubectl get clusterrolebinding bootstrap-admin > /dev/null 2>&1; do
                      kubectl delete clusterrolebinding bootstrap-admin --wait=false > /dev/null 2>&1 || true
                      sleep 10
                    done

                    echo "Bootstrap complete!"
EOF
    echo "Creating config for ${n} (${network}${i})..."
    talosctl machineconfig patch controlplane.yaml --patch @configs/patches/"${n}".patch --output configs/"${n}".yaml
  done
}
generate_configs
