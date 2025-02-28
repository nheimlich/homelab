#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="$(dirname "$0")/config.sh"
if [[ -f $CONFIG_FILE ]]; then
	source "$CONFIG_FILE"
else
	echo "Error: Missing $CONFIG_FILE" >&2
	exit 1
fi
: "${stat_data:?Error: stat_data is not set}"
: "${network:?Error: network is not set}"
for pair in "${stat_data[@]}"; do
	IFS=":" read -r n i <<<"$pair"
	echo "Resetting node: $n ($network$i)..."
	talosctl reset --graceful=false -n "$network$i" -e "$network$i" \
		--wait=false --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --reboot=true
done
