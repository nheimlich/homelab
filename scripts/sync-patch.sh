#!/usr/bin/env bash
set -eo pipefail

ACTION=$1
APP_NAME=$2
NAMESPACE="argocd"

if [[ "${ACTION}" == "enable" ]]; then
	echo "Enabling sync policy for ${APP_NAME}..."
	kubectl patch application "${APP_NAME}" -n "${NAMESPACE}" --type=merge -p '{
      "spec": {
        "syncPolicy": {
          "automated": {
            "prune": true,
            "selfHeal": true,
            "allowEmpty": true
          }
        }
      }
    }'
elif [[ "${ACTION}" == "disable" ]]; then
	echo "Disabling sync policy for ${APP_NAME}..."
	kubectl patch application "${APP_NAME}" -n "${NAMESPACE}" --type=json -p '[{
      "op": "remove",
      "path": "/spec/syncPolicy/automated"
    }]'
else
	echo "Invalid action: ${ACTION}. Use 'enable' or 'disable'."
	exit 1
fi
