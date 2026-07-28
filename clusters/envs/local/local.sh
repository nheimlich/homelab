OP_TOKEN=$(op item get "Service Account Auth Token: Homelab" --fields credential --reveal)
cat << EOF | kubectl apply -f -
---
apiVersion: v1
kind: Secret
metadata:
  name: onepassword-connect-token
  namespace: external-secrets
type: Opaque
stringData:
  token: ${OP_TOKEN}
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: onepassword
  namespace: external-secrets
spec:
  provider:
    onepasswordSDK:
      vault: "kubernetes"
      auth:
        serviceAccountSecretRef:
          name: onepassword-connect-token
          key: token
          namespace: external-secrets
EOF
