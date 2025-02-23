#!/usr/bin/env bash
set -euo pipefail

check() {
  declare -a tools=("talosctl" "op" "nmap" "kubectl")
  for command in "${tools[@]}" ; do
    if ! command -v "${command}" >/dev/null 2>&1; then
      echo \""${command}" is missing\"
      exit 1
    fi
  done
  echo "All required tools are available."
  unset tools
}

clean() {
  declare -a files=("./controlplane.yaml" "./secrets.yaml" "./credentials.json")
  for file in "${files[@]}" ; do
    if [[ -f "${file}" ]]; then
      echo \"Removing "${file}"\"
      rm -f "${file}"
    fi
  done
  unset files
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
