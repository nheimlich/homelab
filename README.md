## Personal Kubernetes Cluster Repository

**Directory Structure:**
```sh
├── clusters/
│   └── {environment}/        # Argo ApplicationSets
├── Makefile                  # Build/deployment automation
├── manifests/
│   └── {app_name}/           # argocd, cdi, kubevirt, etc
│       ├── components/
│       │   └── {version}/    # Versioned components (v3.0.5, v3.2.1, etc.)
│       │       └── *.yaml
│       ├── overlays/         # Environment-specific customization layer
│       │   └── {environment}/
│       │       └── kustomization.yaml  # Points to components (Optionally, patches and resources)
│       ├── patches/          # Patches applied to components/resources (used in overlays)
│       └── resources/        # Additional, non-component, non-versioned resource files
└── scripts/                  # Automation scripts (apps.sh, setup.sh, etc.)
```

**Environments:**
- `production`: Production environment (3-node + talos)
  - [reference-docs](clusters/production/docs.md)
- `standalone`: Standalone environment (laptop + kind)
  - [reference-docs](clusters/standalone/docs.md)

**Application Management:**
- Applications are managed using ArgoCD and Kustomize.
- Each application has its own directory under `manifests/` with versioned components and environment-specific overlays.`
```
❯ ./scripts/apps.sh
Usage: ./scripts/apps.sh [options] <app>
Options:
  -f, --force    Force regeneration of components
  -a, --all      Generate all apps
  -l, --list     List available apps
  -m, --missing  List missing app functions
  -c, --compare  Compare versions for the specified app
  -u, --update   Update overlays for the specified app
  -h, --help     Show this help message
```

```
❯ ./scripts/apps.sh argocd
[INFO] Generating argocd v3.2.1 from URL...
Wrote manifests/argocd/components/v3.2.1/resource.yaml -- 1384000 bytes.
...
12 files generated.
```
**Creating Directory Structure for New Applications:**
```
ls -1 manifests | xargs -I {} bash -c "mkdir -p manifests/{}/{overlays/{production,standalone}/,}{patches,resources} && touch manifests/{}/{overlays/{production,standalone}/,}{patches,resources}/.gitkeep"
```
