#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
YAML_FILE="$REPO_ROOT/clusters/default_app_config.yaml"

if [[ -z "$1" ]]; then
  APP=$(yq eval '.apps | to_entries | .[] | select(.value.type == "helm") | .value.chart' "$YAML_FILE" | fzf --prompt="Select App: " )
fi

REPO_URL=$(yq ".apps.${APP}.repo_url" "$YAML_FILE")
CHART=$(yq ".apps.${APP}.chart" "$YAML_FILE")

if [[ "$REPO_URL" == oci://* ]]; then
    helm show values "${REPO_URL}"
else
    helm show values "$CHART" --repo "$REPO_URL"
fi
