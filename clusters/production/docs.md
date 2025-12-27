# Production

## Upgrade Talos

```bash
talosctl upgrade -i factory.talos.dev/metal-installer-secureboot/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:$(curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | sed -Ene '/^ *"tag_name": *"(v.+)",$/s//\1/p') --context k8s.nhlabs.local --wait=false
```

## Upgrade K8s
```bash
talosctl upgrade-k8s --context k8s.nhlabs.local --to $(curl -s https://api.github.com/repos/siderolabs/kubelet/releases/latest | sed -Ene '/^ *"tag_name": *"(v.+)",$/s//\1/p') -n 10.0.0.111
```
