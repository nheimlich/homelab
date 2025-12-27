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
OP_TOKEN=$(op document get "op.nhlabs.org-token")
OP_DOCUMENT=$(op document get "op.nhlabs.org-credentials" | base64)
op document get "Talos Secrets" -o secrets.yaml --force > /dev/null 2>&1
: "${OP_TOKEN:?Error: OP_TOKEN is not set}"
: "${OP_DOCUMENT:?Error: OP_DOCUMENT is not set}"

generate_configs() {
  mkdir -p configs/patches
  talosctl gen config k8s.nhlabs.local --with-secrets secrets.yaml https://"${network}${lbvip}":6443 --force --additional-sans \
    "${network}"111,"${network}"112,"${network}"113,sol,clu,ion,sol.nhlabs.local,clu.nhlabs.local,ion.nhlabs.local --with-docs=false -p \
    --install-image "${image}" --output-types controlplane -o controlplane.yaml
  for pair in "${stat_data[@]}"; do
    IFS=":" read -r n i <<< "${pair}"
    echo "Generating patch for ${n} (IP: ${network}${i})..."
    cat << EOF > configs/patches/"${n}".patch
debug: false
machine:
  kubelet:
    extraMounts:
      - destination: /var/local-path-provisioner
        type: bind
        source: /var/local-path-provisioner
        options:
          - bind
          - rshared
          - rw
    extraConfig:
      featureGates:
        UserNamespacesPodSecurityStandards: true
    extraArgs:
      rotate-server-certificates: true

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
    hostname: "${n}"
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
          name: connect
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: op-credentials
          namespace: connect
        type: Opaque
        stringData:
          1password-credentials.json: |-
            ${OP_DOCUMENT}
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: onepassword-token
          namespace: connect
        type: Opaque
        stringData:
          token: ${OP_TOKEN}
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
          backoffLimit: 2
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
              containers:
              - name: bootstrap-install
                image: alpine/curl
                env:
                - name: KUBERNETES_SERVICE_HOST
                  value: "localhost"
                - name: KUBERNETES_SERVICE_PORT
                  value: "7445"
                command:
                  - "/bin/sh"
                  - "-c"
                  - |
                    TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
                    NAMESPACE="kube-system"
                    API_SERVER="https://\${KUBERNETES_SERVICE_HOST}:\${KUBERNETES_SERVICE_PORT}"
                    AUTH_HEADER="Authorization: Bearer \${TOKEN}"
                    ACCEPT_HEADER="Accept: application/json"
                    DEPLOYMENT_URL="\${API_SERVER}/apis/apps/v1/namespaces/\${NAMESPACE}/deployments/cilium-operators"
                    CRB_URL="\${API_SERVER}/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/bootstrap-admin"

                    status=\$(curl -sSk -o /dev/null -w "%{http_code}" -H "\${AUTH_HEADER}" -H "\${ACCEPT_HEADER}" "\${DEPLOYMENT_URL}")

                    if [ "\${status}" -eq 200 ]; then
                        echo "cilium-operator deployment exists. Deleting ClusterRoleBinding."
                        curl -sSk -X DELETE -H "\${AUTH_HEADER}" -H "\${ACCEPT_HEADER}" "\${CRB_URL}" -o /dev/null -w "%{http_code}\n"
                        exit 0
                    fi

                    echo "Updating APK and installing dependencies..."
                    apk update && apk add --no-cache kubectl kustomize helm git

                    echo "Cloning repository..."
                    git clone -b main --single-branch https://github.com/nheimlich/homelab.git /repo
                    cd /repo/overlays/production || exit

                    echo "Applying Cilium manifests..."
                    kubectl apply -f <(kustomize build --enable-helm cilium)

                    sleep 10

                    echo "Applying Connect manifests..."
                    kubectl apply -f <(kustomize build --enable-helm connect)

                    sleep 10

                    echo "Applying cert-manager manifests..."
                    kubectl apply -f <(kustomize build --enable-helm cert-manager)

                    sleep 10

                    echo "Applying Shared Gateway manifests..."
                    kubectl apply -f <(kustomize build --enable-helm shared-gateway)

                    sleep 10

                    echo "Applying ArgoCD manifests..."
                    kubectl apply -f <(kustomize build --enable-helm argocd)

                    sleep 10

                    cd /repo || exit

                    until kubectl apply -f clusters/production/applications.yaml; do
                      echo "Failed to apply ArgoCD applications, retrying in 5 seconds..."
                      sleep 5
                    done

                    echo "Deleting bootstrap-admin ClusterRoleBinding..."
                    kubectl delete clusterrolebinding bootstrap-admin || true

                    echo "Bootstrap complete!"
EOF
    echo "Creating config for ${n} (${network}${i})..."
    talosctl machineconfig patch controlplane.yaml --patch @configs/patches/"${n}".patch --output configs/"${n}".yaml
  done
}
generate_configs
