#!/usr/bin/env bash
#reset.sh
set -euo pipefail

# Source config if it exists, otherwise exit
CONFIG_FILE="$(dirname "$0")/config.sh"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=./scripts/config.sh
    source "$CONFIG_FILE"
else
    echo "Error: Missing $CONFIG_FILE" >&2
    exit 1
fi

# Ensure required variables are set
: "${stat_data:?Error: stat_data is not set}"
: "${network:?Error: network is not set}"

for pair in "${stat_data[@]}"; do
    IFS=":" read -r n i <<< "$pair"
    echo "Resetting node: ${n} (${network}${i})..."
    talosctl reset --graceful=false -n "${network}${i}" -e "${network}${i}" \
        --wait=false --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --reboot=true
done
