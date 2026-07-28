#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="$(dirname "$0")/config.sh"
if [[ -f ${CONFIG_FILE} ]]; then
  source "${CONFIG_FILE}"
else
  echo "Error: Missing ${CONFIG_FILE}" >&2
  exit 1
fi
source "./dhcp_data.sh"
bootstrap() {
  printf "waiting for nodes to come online...\n"
  for pair in "${dhcp_data[@]}"; do
    IFS=":" read -r n i <<< "${pair}"
    nc -v -w 1 "${network}${i}" 50000
  done
  for pair in "${dhcp_data[@]}"; do
    IFS=":" read -r n i <<< "${pair}"
    echo "Applying config to ${n} (${network}${i})..."
    until talosctl apply-config --insecure -n "${network}${i}" --file "configs/${n}.yaml"; do
      echo "Retrying..."
      sleep 5
    done
  done
  printf "waiting for nodes to come online...\n"
  sleep 20
  for pair in "${stat_data[@]}"; do
    IFS=":" read -r n i <<< "${pair}"
    until ping -c 3 -W 1 "${network}${i}"; do
      echo "Retrying..."
      sleep 5
    done
  done
  for pair in "${stat_data[@]}"; do
    IFS=":" read -r n i <<< "${pair}"
    printf "validating certificate issued for %s\n" "${n}"
    until openssl s_client -connect "${network}${i}:50000" -showcerts < /dev/null 2> /dev/null | openssl x509 -noout -text | grep -q "Subject: CN=${n}"; do
      echo "Retrying..."
      sleep 5
    done
    printf "wiping disk for ceph installation on %s\n" "${n}"
    until talosctl wipe disk sda -n "${network}${i}" -e "${network}${i}"; do
      echo "Retrying..."
      sleep 5
    done
  done

  IFS=":" read -r first_n first_i <<< "${stat_data[0]}"
  echo "Bootstrapping Talos on ${first_n} (${network}${first_i})..."
  until talosctl bootstrap -n "${network}${first_i}" -e "${network}${first_i}"; do
    echo "Retrying..."
    sleep 5
  done
  until ping -c 3 -W 1 "${network}${lbvip}"; do
    echo "Retrying..."
    sleep 5
  done
  echo "Bootstrapping complete!"
  echo ""
  echo "Waiting for manifest bootstrap job to complete (~3 mins wait...)"
  sleep 180
  until kubectl -n kube-system wait --for condition=Complete job/bootstrap-install; do
    echo "Retrying..."
    sleep 10
  done
  echo "Bootstrap Job Completed"
  echo ""
  for pair in "${stat_data[@]}"; do
    IFS=":" read -r n i <<< "${pair}"
    printf "Removing InlineManifests Config\n"
    until talosctl patch mc -n "${network}${i}" -e "${network}${i}" --patch 'cluster: {inlineManifests: {$patch: delete}}'; do
      echo "Retrying..."
      sleep 5
    done
  done
}
bootstrap
