#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="$(dirname "$0")/config.sh"

if [[ -f ${CONFIG_FILE} ]]; then
  source "${CONFIG_FILE}"
else
  echo "Error: Missing ${CONFIG_FILE}" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

log() { printf "\033[36m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[31m[ERR]\033[0m %s\n" "$*"; }

excluded_apps=("default-backend" "shared-gateway")
valid_apps=$(declare -F | awk '{print $3}' | grep -vE "^(fetch_|slice_|lint_|log|warn|err|versions|usage|generate_|main|print_)")
missing_apps=$(comm -13 <(echo "${valid_apps}" | sort) <(ls -1 "${MANIFESTS_DIR}" | tr ' ' '\n' | sort) | grep -v -E "$(IFS="|"; echo "${excluded_apps[*]}")")

update_overlays() {
    local app="$1"
    local env="$2"

    local manifest_root="manifests"
    local app_dir="${manifest_root}/${app}"
    local overlay_dir="${app_dir}/overlays/${env}"
    local target_file="${overlay_dir}/kustomization.yaml"
    local base_components_dir="${app_dir}/components"

    local ver2_path=$(find "${base_components_dir}" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n1)

    if [[ -z "${ver2_path}" ]]; then
        echo "Error: No component versions found in ${base_components_dir}" >&2
        return 1
    fi
    local ver2=$(basename "${ver2_path}")

    echo "Regenerating ${target_file} (Version: ${ver2})..."

cat << EOF > "${target_file}"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../components/${ver2}
EOF

    list_resources() {
        local search_dir="$1"
        local prefix="$2"
        if [[ -d "${search_dir}" ]]; then
            # Find yaml files, sort them, exclude kustomization.yaml
            find "${search_dir}" -maxdepth 1 -type f -name "*.yaml" ! -name "kustomization.yaml" | sort | while read -r file; do
                local filename=$(basename "$file")
                echo "  - ${prefix}/${filename}" >> "${target_file}"
            done
        fi
    }

    list_resources "${app_dir}/resources" "../../resources"

    list_resources "${overlay_dir}/resources" "resources"

    find "${overlay_dir}" -maxdepth 1 -type f -name "*.yaml" ! -name "kustomization.yaml" | sort | while read -r file; do
        echo "  - $(basename "$file")" >> "${target_file}"
    done

    local has_patches=false

    if [[ -d "${app_dir}/patches" ]] && [[ -n "$(ls -A "${app_dir}/patches"/*.yaml 2>/dev/null)" ]]; then has_patches=true; fi
    if [[ -d "${overlay_dir}/patches" ]] && [[ -n "$(ls -A "${overlay_dir}/patches"/*.yaml 2>/dev/null)" ]]; then has_patches=true; fi

    if [[ "$has_patches" == "true" ]]; then
        echo "" >> "${target_file}"
        echo "patches:" >> "${target_file}"

        list_patches() {
            local search_dir="$1"
            local prefix="$2"
            if [[ -d "${search_dir}" ]]; then
                find "${search_dir}" -maxdepth 1 -type f -name "*.yaml" ! -name "kustomization.yaml" | sort | while read -r file; do
                    local filename=$(basename "$file")
                    echo "  - path: ${prefix}/${filename}" >> "${target_file}"
                done
            fi
        }

        list_patches "${app_dir}/patches" "../../patches"

        list_patches "${overlay_dir}/patches" "patches"
    fi

    echo "Successfully updated ${app}/${env}"
}

compare_versions() {
    local app="$1"
    local base_dir="manifests/${app}/components"

    local ver_paths=$(find "${base_dir}" -mindepth 1 -maxdepth 1 -type d | sort -V)
    local ver_list_count=0
    local all_paths=""

    while IFS= read -r path; do
        all_paths="${all_paths}${path}\n"
        ver_list_count=$((ver_list_count + 1))
    done <<< "${ver_paths}"

    if [[ ${ver_list_count} -ge 2 ]]; then
        local ver1_path=$(echo -e "${ver_paths}" | tail -n2 | head -n1)
        local ver2_path=$(echo -e "${ver_paths}" | tail -n1)
    else
        echo "Error: Found fewer than 2 versions to compare in ${base_dir}" >&2
        return 1
    fi

    local ver1=$(basename "${ver1_path}")
    local ver2=$(basename "${ver2_path}")

    local path_prefix="${ver1_path%/*}/"

    echo "Comparing ${app} versions: ${ver1} -> ${ver2}"
    echo "---"
    find "${ver1_path}" -type f -name "*.yaml" -print0 | while IFS= read -r -d $'\0' i; do
        local rel_path="${i#${ver1_path}/}"
        local file_ver2="${ver2_path}/${rel_path}"

        if [[ ! -f "${file_ver2}" ]]; then
            log WARN "File ${rel_path} is missing in version ${ver2} (REMOVED)"
            echo "Command: dyff between ${i} /dev/null"
            continue
        fi

        if ! cmp -s "${i}" "${file_ver2}"; then
            if diff_output=$(dyff -c off between "${i}" "${file_ver2}" -s); then
              continue
            else
                local dyff_status=$?

                if [[ ${dyff_status} -eq 1 ]]; then
                    log "${rel_path} (Returned differences)"
                    dyff between ${path_prefix}{${ver1},${ver2}}/${rel_path} --multi-line-context-lines 0 -i -b --ignore-whitespace-changes --exclude-regexp 'description$'
                elif [[ ${dyff_status} -eq 2 ]]; then
                    err "dyff failed on ${rel_path}. Status: 2"
                    echo "Dyff error output: ${diff_output}"
                fi
            fi
        fi
    done
}

generate_kustomization() {
    local target_dir="$1"
    local namespace="$2"
    local create_ns="${3:-true}"

    pushd "${target_dir}" >/dev/null

    if [[ -n "${namespace}" && "${create_ns}" == true ]]; then
    cat <<EOF > 01-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
  labels:
    shared-gateway-access: "true"
EOF
    fi

    if [[ ! -f kustomization.yaml ]]; then
        kustomize create --autodetect --recursive
    fi
    popd >/dev/null
}


slice_manifests() {
    local output_dir="$1"
    kubectl-slice --prune --remove-comments --exclude-kind Namespace \
      --template "{{ .kind | lower }}.yaml" \
      --output-dir "${output_dir}" \
      "${@:2}"
}

lint_manifests() {
    local target_dir="$1"
    log "Linting manifests in ${target_dir}..."

    find "${target_dir}" -type f -name "*.yaml" -print0 | xargs -0 pre-commit run \
        --config .pre-commit-config.yaml \
        --files || true
}

fetch_url() {
    local app="$1"
    local ver="$2"
    local url="$3"
    local ns="${4:-}"
    local extra_slice_args="${5:-}"
    local stream_filter="${6:-}"
    local create_ns="${7:-true}"
    local owner="${8:-}"
    local repo="${9:-}"

    local target_dir="${MANIFESTS_DIR}/${app}/components/${ver}"

    if [[ -d "${target_dir}" && "${FORCE_GENERATE:-false}" != "true" ]]; then
        log "Skipping ${app} ${ver} (already exists). Use -f to force."
        return 0
    fi

    log "Generating ${app} ${ver} from URL..."
    rm -rf "${target_dir}" && mkdir -p "${target_dir}"

    curl -sL "${url}" | \
        if [[ -n "${stream_filter}" ]]; then
            eval "${stream_filter}"
        else
            cat
        fi | \
    slice_manifests "${target_dir}" ${extra_slice_args}

    generate_kustomization "${target_dir}" "${ns}" "${create_ns}"

    lint_manifests "${target_dir}"

    local latest_ver=$(curl -s "https://api.github.com/repos/"${owner}/${repo}"/releases/latest" | jq -r '.tag_name')

    if [[ "${ver}" != "${latest_ver}" ]]; then
        warn "A newer version (${latest_ver}) of ${app} is available (current: ${ver})"
    elif [[ -z "${latest_ver}" ]]; then
        warn "Could not determine the latest version of ${app}"
    elif [[ "${ver}" == "${latest_ver}" ]]; then
        log "${app} is up-to-date (version: ${ver}, upstream: ${latest_ver})"
    fi
}

# Strategy: Helm Chart
# Usage: fetch_helm <app> <ver> <repo_name> <repo_url> <chart> <release_name> <namespace> [values_callback_function]
fetch_helm() {
    local app="$1"
    local ver="$2"
    local repo_name="$3"
    local repo_url="$4"
    local chart="$5"
    local release_name="$6"
    local namespace="$7"
    local callback="${8:-}"
    local extra_slice_args="${9:-}"
    local stream_filter="${10:-}"

    local target_dir="${MANIFESTS_DIR}/${app}/components/${ver}"

    if [[ -d "${target_dir}" && "${FORCE_GENERATE:-false}" != "true" ]]; then
        log "Skipping ${app} ${ver} (already exists). Use -f to force."
        return 0
    fi

    log "Generating ${app} ${ver} from Helm..."
    rm -rf "${target_dir}" && mkdir -p "${target_dir}"

    helm repo add "${repo_name}" "${repo_url}" >/dev/null 2>&1
    helm repo update "${repo_name}" >/dev/null 2>&1

    local values_file=""
    if [[ -n "${callback}" ]]; then
        values_file=$(mktemp)
        ${callback} > "${values_file}"
    fi

    local cmd=(helm template "${release_name}" "${repo_name}/${chart}" --version "${ver}" --namespace "${namespace}" --include-crds)
    if [[ -n "${values_file}" ]]; then
        cmd+=(-f "${values_file}")
    fi

    "${cmd[@]}" | \
        if [[ -n "${stream_filter}" ]]; then
            eval "${stream_filter}"
        else
            cat
        fi | \
    sed '/helm.sh\/chart:/d; /app.kubernetes.io\/managed-by:/d; /app.kubernetes.io\/created-by:/d' | \
    slice_manifests "${target_dir}" ${extra_slice_args}

    [[ -n "${values_file}" ]] && rm -f "${values_file}"

    local latest_ver=$(helm search repo "${repo_name}/${chart}" -o json | jq -r '.[].version' | head -n1)

    if [[ "${ver}" != "${latest_ver}" ]]; then
        warn "A newer version (${latest_ver}) of ${app} is available (current: ${ver})"
    elif [[ -z "${latest_ver}" ]]; then
        warn "Could not determine the latest version of ${app}"
    elif [[ "${ver}" == "${latest_ver}" ]]; then
        log "${app} is up-to-date (version: ${ver}, upstream: ${latest_ver})"
    fi

    generate_kustomization "${target_dir}" "${namespace}"

    lint_manifests "${target_dir}"

}

missing_applications() {
  echo "${missing_apps}" | while read -r app; do
      err "Warning: Function for app '${app}' is missing in apps.sh"
  done
}


usage() {
    printf "Usage: %s [options] <app>\n" "$0"
    printf "Options:\n"
    printf "  -f, --force    Force regeneration of components\n"
    printf "  -a, --all      Generate all apps\n"
    printf "  -l, --list     List available apps\n"
    printf "  -m, --missing  List missing app functions\n"
    printf "  -c, --compare <app>  Compare latest and n-1 versions for the specified app\n"
    printf "  -u, --update <app> <env>  Update overlays for the specified app and environment\n"
    printf "  -h, --help     Show this help message\n"
}

main() {
    versions
    FORCE_GENERATE=false
    RUN_ALL=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force) FORCE_GENERATE=true; shift ;;
            -a|--all) RUN_ALL=true; shift ;;
            -l|--list) echo "${valid_apps}"; exit 0 ;;
            -m|--missing) missing_applications; exit 0 ;;
            -c|--compare) compare_versions "$2"; exit 0 ;;
            -u|--update) update_overlays "$2" "$3"; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            *)
                if echo "${valid_apps}" | grep -qx "$1"; then
                    "$1"
                    exit 0
                else
                    err "Unknown app or option: $1"
                    usage
                    exit 1
                fi
                ;;
        esac
    done

    if [[ "${RUN_ALL}" == "true" ]]; then
        for app in ${valid_apps}; do
          # Skip internal helpers if present (e.g., functions starting with '_')
            [[ "${app}" == "_"* ]] && continue
            "${app}"
        done
    else
        usage
    fi
}

main "$@"
