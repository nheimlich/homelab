# homelab (talos)
---
## Personal Kubernetes Cluster Repository

**Directory Structure:**
```sh
├── apps
|   ├── application
│   └── ...
├── base
|   ├── manifests
│   └── ...
├── overlay
|   ├── kustomization
│   └── ...
└── clusters
    ├── standalone (local)
    └── production (dedicated)
```
**Supporting Applications:**
```sh
(Network) - Cilium
(Storage) - Local Storage Provisioner
```
**Additional Applications:**
```sh
(Virtualization) - KubeVirt
```
## Cluster Provisioning & Lifecycle

**production cluster configuration**

- creating configuration
```sh
talosctl gen config talos.nhlabs.org https://10.0.0.5:6443 --install-image=factory.talos.dev/installer-secureboot/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.8.0 --config-patch @talos/patch.yaml --force
```
- bootstrap cluster

```sh
talosctl -n 10.0.0.5 -e 10.0.0.5 bootstrap --talosconfig talosconfig
```
- upgrade cluster
```sh
talosctl upgrade --preserve -n 10.0.0.5 -e 10.0.0.5 --talosconfig=talosconfig --image factory.talos.dev/installer-secureboot/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.8.3
```
**custom manifests for bootstraping**
```sh
# Local Storage Class
pwd: ~/talos/local-storage
kustomize build . > local-storage-provisioner.yaml

# Cilium CNI
pwd: ~/talos/cilium
helm template cilium cilium/cilium -f cilium-config.yaml > cilium.yaml
```
