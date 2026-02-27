# Production

## Upgrade Talos

```bash
talosctl upgrade -i factory.talos.dev/metal-installer-secureboot/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:$(curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | sed -Ene '/^ *"tag_name": *"(v.+)",$/s//\1/p') --context k8s.nhlabs.local --wait=false
```

## Upgrade K8s

```bash
talosctl upgrade-k8s --context k8s.nhlabs.local --to $(curl -s https://api.github.com/repos/siderolabs/kubelet/releases/latest | sed -Ene '/^ *"tag_name": *"(v.+)",$/s//\1/p') -n 10.0.0.111
```

## Rotate Certs

```bash
cp ${HOME}/.talos/config{,.bak}
cp ${HOME}/.kube/config{,.bak}


make generate

yq -r .machine.ca.crt controlplane.yaml | base64 -d > ca.crt
yq -r .machine.ca.key controlplane.yaml | base64 -d > ca.key

talosctl gen key --name admin
talosctl gen csr --key admin.key --ip 127.0.0.1
talosctl gen crt --ca ca --csr admin.csr --name admin --hours 8760

yq eval '.contexts."k8s.nhlabs.local".ca = "'"$(base64 -b0 -i ca.crt)"'" | .contexts."k8s.nhlabs.local".crt = "'"$(base64 -b0 -i admin.crt)"'" | .contexts."k8s.nhlabs.local".key = "'"$(base64 -b0 -i admin.key)"'"' -i ${HOME}/.talos/config

talosctl kubeconfig "${HOME}/.kube/config" -n 10.0.0.115
```
