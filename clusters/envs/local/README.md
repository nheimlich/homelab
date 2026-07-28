# Local Kubernetes Cluster with KIND and Podman

## creating cluster
`KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster`
## deleting cluster
`kind delete cluster
## cloud controller manager with lb port mapping
```bash
podman run --rm --privileged --network host -v /var/run/docker.sock:/var/run/docker.sock registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.9.0 -enable-lb-port-mapping
```
