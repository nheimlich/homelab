#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="$(dirname "$0")/config.sh"
OUTPUT_FILE="dhcp_data.sh"
if [[ -f $CONFIG_FILE ]]; then
	source "$CONFIG_FILE"
else
	echo "Error: Missing $CONFIG_FILE" >&2
	exit 1
fi
: "${network:?Error: network is not set}"
dhcp_setup() {
	echo "Updating ARP cache (requires sudo)..."
	sudo arp -a -d >/dev/null
	sudo nmap -T4 -sP -n "${network}2-100" >/dev/null
	for i in "${!dhcp_data[@]}"; do
		IFS=":" read -r name _ <<<"${dhcp_data[$i]}"
		mac_addr=$(op document get "$name-macaddr" --vault kubernetes | tr '[:upper:]' '[:lower:]' | cut -d ':' -f 4,5,6)
		if [[ -n $mac_addr ]]; then
			ip=$(arp -an | grep -E "$mac_addr" | awk '{print $2}' | sed 's/[()]//g' | grep -Eo '[0-9]{1,3}$' | grep -Ev "111$|112$|113$|115$")
			if [[ -z $ip ]]; then
				print "IP not found for $name"
			fi
			dhcp_data[i]="$name:${ip:-<not found>}"
		fi
		echo "dhcp_data[$i]=\"${dhcp_data[$i]}\"" >>"$OUTPUT_FILE"
	done
	echo "Updated DHCP Data:"
	printf "%s\n" "${dhcp_data[@]}"
	echo "Updated DHCP Data saved to $OUTPUT_FILE"
}
dhcp_setup
