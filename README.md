# homelab (talos)
```

#generating configuration for standalone cluster
talosctl gen config talos.nhlabs.org https://10.0.0.5:6443 --install-image=factory.talos.dev/installer-secureboot/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.8.0 --config-patch @patch.yaml --force
#bootstrapping cluster
talosctl -n 10.0.0.5 -e 10.0.0.5 bootstrap --talosconfig talosconfig
#perfoming upgrades
talosctl upgrade --preserve -n 10.0.0.5 -e 10.0.0.5 --talosconfig=talosconfig --image factory.talos.dev/installer-secureboot/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.8.3
```
### custom releases for patch.yaml
```
# Local Storage Class
kustomize build . > local-storage-provisioner.yaml

# Cilium CNI
helm template cilium cilium/cilium -f cilium-config.yaml > cilium.yaml

```
