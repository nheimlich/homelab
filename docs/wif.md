# WIF Secret Migration Reference

How the cluster authenticates to Google Secret Manager via Workload Identity Federation (no long-lived keys).

## Architecture

```
ESO (external-secrets ns)
  │ 1. TokenRequest → k8s SA token (JWT)
  │    aud = cluster default: https://10.0.0.115:6443, <STS audience>
  │    iss = https://nhlabs.org/oidc
  ▼
kube-apiserver (Talos)
  │ 2. JWT signed by OIDC key from talos-secrets (GSM)
  ▼
Google STS (https://sts.googleapis.com/v1/token)
  │ 3. Token exchange: aud must EXACTLY equal the pool provider URI
  ▼
Workload Identity Pool "homelab" / provider "k8s-oidc"
  │ 4. Verifies signature via public JWKS at https://nhlabs.org/oidc/openid/v1/jwks
  ▼
GSM access token → Secret Manager
```

## Key Values

| Item | Value |
|------|-------|
| GCP project | `homelab-a70a4db3c74cf8cd` (#`285407169922`) |
| Issuer | `https://nhlabs.org/oidc` (Cloudflare Pages, public JWKS) |
| WIF pool / provider | `homelab` / `k8s-oidc` |
| STS audience | `//iam.googleapis.com/projects/285407169922/locations/global/workloadIdentityPools/homelab/providers/k8s-oidc` |
| Apiserver flags | `--service-account-issuer=https://nhlabs.org/oidc`, `--api-audiences=https://10.0.0.115:6443,<STS audience>` |
| ESO image | `ghcr.io/external-secrets/external-secrets:v2.8.0` |
| Store | `ClusterSecretStore gcp` (gcpsm, `workloadIdentityFederation`) |
| IAM | pool member → `roles/secretmanager.secretAccessor` (read-only) |

## Gotchas (learned the hard way)

- **Two different "audience" fields on the store**: `workloadIdentityFederation.audience` is only the STS exchange audience. The k8s token's audiences come from `serviceAccountRef.audiences`; if empty, the apiserver uses its default `--api-audiences`. Our store relies on the cluster default (an array incl. the STS URI) — do not confuse the two.
- **Talos**: `api-audiences` is set via `cluster.apiServer.extraArgs` in the per-node patch (generate.sh). It must be a comma-joined string in the config; the rendered apiserver takes effect on re-render/reboot.
- **k8s v1.36**: flag is `--api-audiences`
- **STS acceptance**: audience must be a single-element array `[<STS URI>]` or contained in the aud array. A comma-joined *string* audience → `invalid_grant`.
- **`ReadWrite`** in status is the provider's inherent capability, not IAM permission. Writes are blocked by the read-only IAM role.
- **JWKS drift guard**: `generate.sh` regenerates the JWKS from GSM `talos-secrets` and fails if `oidc/openid/v1/jwks` is out of date (regenerate + sync to the site repo).

## Verification

```bash
# 1. Token the apiserver mints by default (decode .payload: iss + aud)
kubectl create token external-secrets -n external-secrets

# 2. Store + secrets
kubectl get clustersecretstore gcp        # Ready=True, Valid
kubectl get externalsecrets -A            # SecretSynced

# 3. Byte-compare against local copy
gcloud secrets versions access latest --secret=cloudflare-token \
  --project=homelab-a70a4db3c74cf8cd | cmp - secrets/cloudflare-token.json

# 4. Manual STS exchange (T1-style):
#    POST https://sts.googleapis.com/v1/token
#    subject_token=<k8s jwt>, audience=<STS URI>,
#    grant_type=urn:ietf:params:oauth:grant-type:token-exchange,
#    subject_token_type=urn:ietf:params:oauth:token-type:jwt
```

## Files

- `tofu/gcp/main.tf` — project, WIF pool/provider, GSM secrets, IAM, budget (state: `tofu/.ic_state/homelab/`)
- `clusters/types/talos/provision/config.sh` — `oidc_issuer`, `wif_audience`
- `clusters/types/talos/provision/generate.sh` — apiserver flags + bootstrap-install job
- `manifests/external-secrets/overlays/homelab/resources/clustersecretstore.yaml` — the store
- `secrets/` (gitignored) — local copies; `scripts/seed-secrets.sh` (gitignored) regenerates from 1Password + pushes JWKS to the site repo
