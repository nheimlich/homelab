#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="$(dirname "$0")/config.sh"
[[ -f "${CONFIG_FILE}" ]] || { echo "Error: Missing ${CONFIG_FILE}" >&2; exit 1; }
source "${CONFIG_FILE}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

log_info() { printf "[INFO] %s\n" "$*"; }
log_warn() { printf "[WARN] %s\n" "$*"; }
log_err()  { printf "[ERR]  %s\n" "$*"; }

valid_apps=$(declare -F | awk '{print $3}' | grep -vE "^(_|fetch_|slice_|lint_|log_|versions|usage|generate_|main|process_|check_v|diff_|update_|run_)")

check_version() {
  local type="$1" app="$2" current="$3" latest=""
  case "${type}" in
    github) latest=$(curl -s "https://api.github.com/repos/${4}/${5}/releases/latest" | jq -r '.tag_name // empty') ;;
    helm)   latest=$(helm search repo "${4}/${5}" -o json | jq -r '.[0].version // empty') ;;
  esac

  if [[ -z "${latest}" || "${latest}" == "null" ]]; then
    log_warn "Version check failed: ${app}"
  elif [[ "${current}" != "${latest}" ]]; then
    log_warn "Update available: ${app} (${current} -> ${latest})"
    local app_upper=$(echo "${app}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    local var_name="${app_upper}_VERSION"
    if grep -q "${var_name}=" "${CONFIG_FILE}"; then
      sed -i '' "s|${var_name}=.*|${var_name}=\${${var_name}:-${latest}}|" "${CONFIG_FILE}"
      log_info "Updated ${var_name} in config.sh"
    fi
  else
    log_info "Up-to-date: ${app} (${current})"
  fi
}

_fetch_internal() {
  local app="$1" ver="$2" type="$3"
  local dir="${MANIFESTS_DIR}/${app}/components/${ver}"
  if [[ "${CHECK_ONLY:-false}" == "true" ]]; then
    shift 3
    check_version "${type}" "${app}" "${ver}" "$@"
    return 0
  fi
  if [[ -d "${dir}" && "${FORCE_GENERATE:-false}" != "true" ]]; then
    log_info "Exists: ${app} ${ver}"
    return 0
  fi
  return 1
}

process_manifests() {
  local app="$1" ver="$2" dir="$3" ns="$4" cns="$5" uns="$6" args="$7" filter="$8"
  rm -rf "${dir}" && mkdir -p "${dir}"
  if [[ -n "${filter}" ]]; then
    eval "${filter}" | slice_manifests "${dir}" "${args}"
  else
    slice_manifests "${dir}" "${args}"
  fi
  generate_kustomization "${dir}" "${ns}" "${cns}" "${uns}"
  lint_manifests "${dir}"
}

fetch_url() {
  local app="$1" ver="$2" url="$3" ns="${4:-$1}" cns="${5:-true}" uns="${6:-true}" args="${7:-}" filter="${8:-}" owner="${9:-}" repo="${10:-}"
  local dir="${MANIFESTS_DIR}/${app}/components/${ver}"
  _fetch_internal "${app}" "${ver}" github "${owner}" "${repo}" && return 0
  log_info "Fetching: ${app} ${ver}"
  curl -sfL "${url}" | process_manifests "${app}" "${ver}" "${dir}" "${ns}" "${cns}" "${uns}" "${args}" "${filter}"
}

fetch_helm() {
  local app="$1" ver="$2" rname="$3" rurl="$4" chart="${5:-$1}" rel="${6:-$1}" ns="${7:-}" cns="${8:-true}" uns="${9:-true}" cb="${10:-}" args="${11:-}" filter="${12:-}"
  local dir="${MANIFESTS_DIR}/${app}/components/${ver}"
  _fetch_internal "${app}" "${ver}" helm "${rname}" "${chart}" && return 0
  log_info "Helm template: ${app} ${ver}"
  helm repo add "${rname}" "${rurl}" >/dev/null 2>&1
  helm repo update "${rname}" >/dev/null 2>&1
  local vfile=""
  [[ -n "${cb}" ]] && vfile=$(mktemp -t "helm_vars_XXXX") && ${cb} > "${vfile}"
  local helm_cmd="helm template ${rel} ${rname}/${chart} --version ${ver} --namespace ${ns} --include-crds"
  [[ -n "${vfile}" ]] && helm_cmd="${helm_cmd} -f ${vfile}"
  eval "${helm_cmd}" | sed -E '/helm.sh\/chart:|app.kubernetes.io\/managed-by:|heritage: Tiller|created-by: helm/d' | \
    process_manifests "${app}" "${ver}" "${dir}" "${ns}" "${cns}" "${uns}" "${args}" "${filter}"
  [[ -n "${vfile}" ]] && rm -f "${vfile}"
}

generate_kustomization() {
  local dir="$1" ns="$2" cns="$3" uns="$4"
  pushd "${dir}" >/dev/null
    if [[ -n "${ns}" && "${cns}" == "true" ]]; then
      cat <<EOF > 01-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    shared-gateway-access: "true"
EOF
    fi
    rm -f kustomization.yaml
    if [[ -n "${ns}" && "${uns}" == "true" ]]; then
      kustomize create --autodetect --recursive --namespace "${ns}"
    else
      kustomize create --autodetect --recursive
    fi
  popd >/dev/null
}

slice_manifests() {
  kubectl-slice --prune --remove-comments --exclude-kind Namespace --template "{{ .kind | lower }}.yaml" --output-dir "$1" ${@:2}
}

lint_manifests() {
  if command -v pre-commit >/dev/null; then
    find "$1" -type f -name "*.yaml" -print0 | xargs -0 pre-commit run --config .pre-commit-config.yaml --files || true
  fi
}

update_overlay() {
  local app="${1:-}" env="${2:-}"
  [[ -z "${app}" || -z "${env}" ]] && return 1
  local app_dir="${MANIFESTS_DIR}/${app}"
  local ovl_dir="${app_dir}/overlays/${env}"
  local target="${ovl_dir}/kustomization.yaml"
  local ver=$(find "${app_dir}/components" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n1 | xargs basename)
  mkdir -p "${ovl_dir}"
  cat << EOF > "${target}"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../components/${ver}
EOF
  _write_list() {
    local sdir="$1" pref="$2" key="$3"
    [[ -d "${sdir}" ]] || return 0
    local files=$(find "${sdir}" -maxdepth 1 -type f -name "*.yaml" ! -name "kustomization.yaml")
    [[ -n "${files}" ]] || return 0
    if [[ "${key}" == "resources" ]]; then
      pushd "${sdir}" > /dev/null; rm -f kustomization.yaml && kustomize create --autodetect && popd > /dev/null
      echo "  - ${pref}" >> "${ovl_dir}/kustomization.yaml"
    elif [[ "${key}" == "patches" ]]; then
      echo "patches:" >> "${ovl_dir}/kustomization.yaml"
      for i in $(ls "${sdir}"/*.yaml | xargs -n 1 basename); do
        echo "  - path: ${pref}/${i}" >> "${ovl_dir}/kustomization.yaml"
      done
    fi
  }
  _write_list "${app_dir}/resources" "../../resources" "resources"
  _write_list "${ovl_dir}/resources" "resources" "resources"
  _write_list "${ovl_dir}/patches" "patches" "patches"
}

diff_app() {
  local app="${1:-}"
  local base="${MANIFESTS_DIR}/${app}/components"
  local vers=($(find "${base}" -mindepth 1 -maxdepth 1 -type d | sort -rV))
  [[ ${#vers[@]} -lt 2 ]] && return 1
  local v1="${vers[1]}" v2="${vers[0]}"
  find "${v1}" -type f -name "*.yaml" | while read -r f; do
    rel="${f#"${v1}"/}" f2="${v2}/${rel}"
    [[ -f "${f2}" ]] && ! cmp -s "${f}" "${f2}" && dyff between "${f}" "${f2}" -s || true
  done
}

usage() {
  printf "Usage: %s [options] [app]\n" "$0"
  printf "  -f, --force    Force regeneration\n"
  printf "  -k, --check    Version check only\n"
  printf "  -a, --all      Process all apps\n"
  printf "  -l, --list     List available apps\n"
  printf "  -d, --diff     Diff <app> versions\n"
  printf "  -u, --update   Update <app> <env> overlay\n"
}

main() {
  versions
  FORCE_GENERATE=false
  CHECK_ONLY=false
  local run_mode=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      -f|--force) FORCE_GENERATE=true; shift ;;
      -k|--check) CHECK_ONLY=true; shift ;;
      -a|--all)   run_mode="all"; shift ;;
      -l|--list)  echo "${valid_apps}"; exit 0 ;;
      -d|--diff)  diff_app "${2:-}"; exit 0 ;;
      -u|--update) update_overlay "${2:-}" "${3:-}"; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if echo "${valid_apps}" | grep -qx "$1"; then
          "$1"; exit 0
        else
          usage; exit 1
        fi
        ;;
    esac
  done
  if [[ "${run_mode}" == "all" || "${CHECK_ONLY}" == "true" ]]; then
    for app in ${valid_apps}; do "${app}"; done
  else
    usage
  fi
}

main "$@"
