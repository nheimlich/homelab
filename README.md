## Personal Kubernetes Cluster Repository

**Directory Structure:**
```sh
├── clusters/
│   ├── default_app_config.yaml   # App source definitions (URL/helm repos)
│   ├── types/
│   │   └── {type}/               # Cluster types: talos, kind, openshift, etc.
│   │       ├── config.yaml       # Type metadata
│   │       ├── app_config.yaml   # Install list + version pins per app
│   │       └── provision/        # Bootstrap scripts for this type
│   └── envs/
│       └── {env}/                # Environments: homelab, local, etc.
│           ├── config.yaml       # Links to a type (type: talos)
│           ├── applications.yaml # ArgoCD ApplicationSet
│           └── docs.md
├── manifests/
│   └── {app_name}/
│       ├── values/
│       │   ├── default.yaml      # Helm values for all types
│       │   └── {type}.yaml       # Type-specific Helm values
│       ├── components/
│       │   ├── {version}/        # URL-sourced app components (shared across types)
│       │   └── {type}/{version}/ # Helm-rendered components (type-specific)
│       ├── overlays/
│       │   └── {env}/
│       │       ├── kustomization.yaml  # Generated, points to components
│       │       ├── patches/           # Environment-specific patches
│       │       └── resources/         # Additional overlay resources
│       ├── patches/             # Shared patches
│       └── resources/           # Shared non-versioned resources
├── scripts/
│   ├── generate-manifests       # Wrapper for the Go tool
│   └── tool/
│       ├── main.go              # Manifest generator (Go)
│       ├── go.mod
│       └── go.sum
└── Makefile
```

**Cluster Types:**
- `talos` — Production 3-node Talos cluster
- `kind` — Local development on laptop

**Environments:**
- `homelab` — type: talos, [docs](clusters/envs/homelab/docs.md)
- `local` — type: kind, [docs](clusters/envs/local/docs.md)

**Manifest Generation:**
```sh
./scripts/generate-manifests --type talos --app cilium
./scripts/generate-manifests --all-types                    # All apps for all types
./scripts/generate-manifests --type talos -u                # Update versions to latest
./scripts/generate-manifests --check --type talos           # Version check only
./scripts/generate-manifests --type talos --app cilium -f   # Force regenerate
./scripts/generate-manifests --type talos --app cilium --diff  # Diff last two versions
./scripts/generate-manifests -l                             # List available apps
```

Generated components are committed to git for GitOps simplicity — ArgoCD scans `manifests/*/overlays/{env}/` and applies them via Kustomize.

**Creating a New App:**
1. Add source definition to `clusters/default_app_config.yaml`
2. Add to `install_list` + set version in `clusters/types/{type}/app_config.yaml`
3. Create Helm values at `manifests/{app}/values/default.yaml` (and `{type}.yaml` if needed)
4. Run the generator
