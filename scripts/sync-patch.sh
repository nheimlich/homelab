#!/usr/bin/env bash
set -eo pipefail

ACTION=$1
APP_NAME=$2
NAMESPACE="argocd"

usage() {
  printf "Usage: %s <enable|disable> <app-name>\n" "$0"
  printf "Options:\n"
  printf "  -h, --help  Show this help message\n"
}

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
  echo "Invalid action: ${ACTION}"
  usage
  exit 1
fi
