#!/usr/bin/env bash
#bootstrap.sh
set -euo pipefail
set -x

# Source config if it exists, otherwise exit
CONFIG_FILE="$(dirname "$0")/config.sh"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=./scripts/config.sh
    source "$CONFIG_FILE"
else
    echo "Error: Missing $CONFIG_FILE" >&2
    exit 1
fi

source "./dhcp_data.sh"

# Apply Talos configurations
bootstrap() {
    validation() {
        local msg="$1" cmd_template="$2"
        shift 2
        for pair in "$@"; do
            IFS=":" read -r n i <<< "$pair"
            local cmd="${cmd_template//\$\{n\}/$n}"
            cmd="${cmd//\$\{i\}/$i}"

            echo "Waiting for condition: ${msg} on ${n} (${network}${i})..."
            until eval "$cmd" >/dev/null 2>&1; do
                sleep 5
            done

            echo "${n} (${network}${i}), condition met: ${msg}."
        done
    }

    # Wait for nodes to be online
    validation "come online" "nc -v -w 1 ${network}${i} 50000" "${dhcp_data[@]}"

    # Apply Talos config
    for pair in "${dhcp_data[@]}"; do
        IFS=":" read -r n i <<< "$pair"
        echo "Applying config to ${n} (${network}${i})..."
        until talosctl apply-config --insecure -n "${network}${i}" --file "configs/${n}.yaml"; do
            echo "Retrying..."
            sleep 5
        done
    done

    sleep 20 # Wait for nodes to come back online
    validation "respond to ping" "ping -c 3 -W 1 ${network}${i}" "${stat_data[@]}"

    # Wait for certificates
    validation "certificate issued" \
    "openssl s_client -connect ${network}${i}:50000 -showcerts </dev/null 2>/dev/null | \
    openssl x509 -noout -text | grep -q 'Subject: CN=${n}'" \
    "${stat_data[@]}"

    # Bootstrap the first node
    IFS=":" read -r first_n first_i <<< "${stat_data[0]}"
    echo "Bootstrapping Talos on ${first_n} (${network}${first_i})..."
    talosctl bootstrap -n "${network}${first_i}" -e "${network}${first_i}"
}

bootstrap
