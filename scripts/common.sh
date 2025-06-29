#!/usr/bin/env bash
set -euo pipefail

check() {
  printf "Checking for required tools...\n"
  declare -a tools=("talosctl" "op" "nmap" "kubectl")
  for command in "${tools[@]}"; do
    if ! command -v "${command}" > /dev/null 2>&1; then
      echo \""${command}" is missing\"
      exit 1
    fi
  done
  echo "All required tools are available."
  unset tools
  printf "\n"
}

clean() {
  printf "Cleaning up Environment...\n"
  declare -a files=("./controlplane.yaml" "./secrets.yaml" "./credentials.json" "./dhcp_data.sh")
  declare -a dirs=("./configs")
  for file in "${files[@]}"; do
    if [[ -f ${file} ]]; then
      echo \"Removing "${file}"\"
      rm -f "${file}"
    fi
  done
  for dir in "${dirs[@]}"; do
    if [[ -d ${dir} ]]; then
      echo \"Removing "${dir}"\"
      rm -rf "${dir}"
    fi
  done
  unset files dirs
  printf "\n"
}

case "$1" in
  clean)
    clean
    ;;
  check)
    check
    ;;
  *)
    echo "Usage: $0 {clean|check}"
    exit 1
    ;;
esac
