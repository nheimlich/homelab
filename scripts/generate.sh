#!/usr/bin/env bash
#generate.sh
set -euo pipefail

# Source config if it exists, otherwise exit
CONFIG_FILE="$(dirname "$0")/config.sh"

if [[ -f "${CONFIG_FILE}" ]]; then
    source "${CONFIG_FILE}"
else
    echo "Error: Missing ${CONFIG_FILE}" >&2
    exit 1
fi

# Ensure required variables are set
: "${stat_data:?Error: stat_data is not set}"
: "${network:?Error: network is not set}"
: "${install_disk:?Error: install_disk is not set}"
: "${image:?Error: image is not set}"
: "${lbvip:?Error: lbvip is not set}"

# Pre-setup 1Password Connect server and retrieve secrets
OP_TOKEN=$(op document get "op.nhlabs.org-token")
OP_DOCUMENT=$(op document get "op.nhlabs.org-credentials" | base64)
op document get "Talos Secrets" -o secrets.yaml --force >/dev/null 2>&1

: "${OP_TOKEN:?Error: OP_TOKEN is not set}"
: "${OP_DOCUMENT:?Error: OP_DOCUMENT is not set}"

# Generate configuration patches for Talos
generate_configs() {
    mkdir -p configs/patches

    talosctl gen config k8s.nhlabs.local --with-secrets secrets.yaml https://"${network}${lbvip}":6443 --force --additional-sans \
      "${network}"111,"${network}"112,"${network}"113,sol,clu,ion,sol.nhlabs.local,clu.nhlabs.local,ion.nhlabs.local --with-docs=false -p \
      --install-image "${image}" --output-types controlplane -o controlplane.yaml

    for pair in "${stat_data[@]}"; do
        IFS=":" read -r n i <<< "$pair"
        echo "Generating patch for $n (IP: ${network}${i})..."

        cat <<EOF > configs/patches/"${n}".patch
debug: false
machine:
  kubelet:
    extraConfig:
      featureGates:
        UserNamespacesSupport: true
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

  extraManifests:
  - https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/main/deploy/standalone-install.yaml
  - https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  - https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

  apiServer:
    admissionControl:
      - name: PodSecurity
        configuration:
          defaults:
            enforce: privileged

  allowSchedulingOnControlPlanes: true

  inlineManifests:
    - name: secrets-bootstrap
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
    - name: cilium-install
      contents: |
        ---
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: cilium-install
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: cluster-admin
        subjects:
        - kind: ServiceAccount
          name: cilium-install
          namespace: kube-system
        ---
        apiVersion: v1
        kind: ServiceAccount
        metadata:
          name: cilium-install
          namespace: kube-system
        ---
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: cilium-install
          namespace: kube-system
        spec:
          backoffLimit: 10
          template:
            metadata:
              labels:
                app: cilium-install
            spec:
              restartPolicy: OnFailure
              tolerations:
                - operator: Exists
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
              serviceAccount: cilium-install
              serviceAccountName: cilium-install
              hostNetwork: true
              containers:
              - name: cilium-install
                image: quay.io/cilium/cilium-cli-ci:latest
                env:
                - name: KUBERNETES_SERVICE_HOST
                  valueFrom:
                    fieldRef:
                      apiVersion: v1
                      fieldPath: status.podIP
                - name: KUBERNETES_SERVICE_PORT
                  value: "6443"
                command:
                  - cilium
                  - install
                  - --set
                  - ipam.mode=kubernetes
                  - --set
                  - kubeProxyReplacement=true
                  - --set
                  - securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}
                  - --set
                  - securityContext.capabilities.cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}
                  - --set
                  - cgroup.autoMount.enabled=false
                  - --set
                  - cgroup.hostRoot=/sys/fs/cgroup
                  - --set
                  - k8sServiceHost=localhost
                  - --set
                  - k8sServicePort=7445
EOF
    echo "Creating config for ${n} (${network}${i})..."
    talosctl machineconfig patch controlplane.yaml --patch @configs/patches/"${n}".patch --output configs/"${n}".yaml
done
}

generate_configs
