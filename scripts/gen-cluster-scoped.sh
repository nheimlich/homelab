#!/usr/bin/env bash
set -euo pipefail
OUT="${1:-clusters/cluster-scoped.yaml}"
kubectl api-resources --namespaced=false --no-headers 2>/dev/null |
	awk '{print $NF}' | sort -u |
	while read -r k; do echo "  - \"$k\""; done > "$OUT"
echo "Wrote $OUT ($(wc -l < "$OUT") kinds)"
