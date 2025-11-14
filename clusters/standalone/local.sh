OP_TOKEN=$(op document get "op.nhlabs.org-token")
OP_DOCUMENT=$(op document get "op.nhlabs.org-credentials" | base64)
cat << EOF | kubectl apply -f -
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
EOF
