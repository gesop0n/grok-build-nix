#!/usr/bin/env bash
#
# Update the pinned Grok Build release in sources.json.
#
# Fetches the current version pointer for the configured channel, re-prefetches
# the release artifact hash for every platform, and verifies the result builds.

set -euo pipefail

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly NC=$'\033[0m'

# Exit codes: 0 = nothing to do, 1 = update available (--check), 2 = error.
readonly EXIT_UPDATE_AVAILABLE=1
readonly EXIT_ERROR=2

readonly PRIMARY_BASE_URL="https://x.ai/cli"
readonly MIRROR_BASE_URL="https://storage.googleapis.com/grok-build-public-artifacts/cli"
readonly SOURCES_FILE="sources.json"

# Written next to sources.json so the final move is atomic (same filesystem) and
# the new file inherits the umask instead of mktemp's 0600.
readonly TMP_SOURCES="sources.json.tmp.$$"
readonly BACKUP_SOURCES="sources.json.bak.$$"

cleanup() { rm -f "$TMP_SOURCES" "$BACKUP_SOURCES"; }
trap cleanup EXIT INT TERM

log_info() { echo "${GREEN}[INFO]${NC} $*" >&2; }
log_warn() { echo "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<'USAGE'
Usage: scripts/update.sh [OPTIONS]

Options:
  --version VERSION  Pin a specific version instead of the channel's latest
  --channel CHANNEL  Channel to follow: stable, alpha, or enterprise
                     (default: the channel recorded in sources.json)
  --check            Report whether an update is available, change nothing.
                     Exits 1 when an update is available, 2 on error.
  --no-verify        Skip the `nix build` verification step
  --help             Show this message

Examples:
  scripts/update.sh                      # update to the latest stable release
  scripts/update.sh --check              # CI probe: is there anything new?
  scripts/update.sh --version 1.0.34     # pin an exact version
  scripts/update.sh --channel alpha      # follow the alpha channel
USAGE
}

require_tools() {
    local missing=()
    local tool
    for tool in nix nix-prefetch-url jq curl; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        exit "$EXIT_ERROR"
    fi
}

require_repository_root() {
    if [ ! -f "$SOURCES_FILE" ] || [ ! -f "flake.nix" ]; then
        log_error "Run this script from the repository root ($SOURCES_FILE not found)."
        exit "$EXIT_ERROR"
    fi
}

# Resolve the channel pointer, preferring x.ai and falling back to the GCS origin.
fetch_latest_version() {
    local channel="$1"
    local version
    for base in "$PRIMARY_BASE_URL" "$MIRROR_BASE_URL"; do
        version=$(curl -fsSL --max-time 20 --retry 2 --retry-delay 1 "${base}/${channel}" 2>/dev/null \
            | tr -d '\r' | head -n1 | tr -d '[:space:]') || true
        if [ -n "$version" ]; then
            printf '%s' "$version"
            return 0
        fi
        log_warn "Could not read ${base}/${channel}"
    done
    return 1
}

validate_version() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?$ ]]; then
        log_error "Invalid version format: '$version' (expected X.Y.Z or X.Y.Z-suffix)"
        exit "$EXIT_ERROR"
    fi
}

# Prefetch one artifact and echo its SRI hash.
prefetch_hash() {
    local version="$1" artifact="$2"
    local url="${PRIMARY_BASE_URL}/grok-${version}-${artifact}.zst"
    local raw
    if ! raw=$(nix-prefetch-url "$url" 2>/dev/null | tail -n1) || [ -z "$raw" ]; then
        log_warn "Primary URL failed, trying mirror for ${artifact}"
        url="${MIRROR_BASE_URL}/grok-${version}-${artifact}.zst"
        raw=$(nix-prefetch-url "$url" 2>/dev/null | tail -n1) || raw=""
    fi
    [ -n "$raw" ] || return 1
    nix hash to-sri --type sha256 "$raw"
}

# Render the whole updated document in one jq pass, then swap it in atomically.
# This function is called from an `if !` condition, where `set -e` does not apply
# inside the body, so every step is checked explicitly.
update_sources() {
    local version="$1" channel="$2"

    local -a jq_args=(--arg version "$version" --arg channel "$channel")
    # $version / $channel here are jq variables, not shell ones.
    # shellcheck disable=SC2016
    local filter='.version = $version | .channel = $channel'
    local system artifact hash index=0

    local -a entries=()
    if ! mapfile -t entries < <(jq -r '.platforms | to_entries[] | "\(.key)\t\(.value.artifact)"' "$SOURCES_FILE"); then
        log_error "Could not read platforms from $SOURCES_FILE"
        return 1
    fi

    if [ "${#entries[@]}" -eq 0 ]; then
        log_error "$SOURCES_FILE lists no platforms"
        return 1
    fi

    local entry
    for entry in "${entries[@]}"; do
        IFS=$'\t' read -r system artifact <<<"$entry"
        log_info "  Prefetching ${system} (${artifact})..."
        if ! hash=$(prefetch_hash "$version" "$artifact"); then
            log_error "Failed to prefetch the artifact for ${system} (${artifact})"
            return 1
        fi
        log_info "    ${hash}"
        jq_args+=(--arg "system${index}" "$system" --arg "hash${index}" "$hash")
        filter+=" | .platforms[\$system${index}].hash = \$hash${index}"
        index=$((index + 1))
    done

    if ! jq "${jq_args[@]}" "$filter" "$SOURCES_FILE" >"$TMP_SOURCES"; then
        log_error "Failed to render the updated $SOURCES_FILE"
        return 1
    fi

    if ! jq -e '.version and .channel and (.platforms | length > 0)' "$TMP_SOURCES" >/dev/null; then
        log_error "Rendered $SOURCES_FILE failed validation"
        return 1
    fi

    if ! mv "$TMP_SOURCES" "$SOURCES_FILE"; then
        log_error "Failed to move the updated file into place"
        return 1
    fi
}

verify_build() {
    log_info "Verifying the package builds..."
    if ! nix build .#grok --no-link --print-build-logs; then
        log_error "Build verification failed."
        return 1
    fi
    log_info "Build verification passed."
}

main() {
    local target_version="" target_channel="" check_only=false verify=true

    while [ $# -gt 0 ]; do
        case "$1" in
            --version)
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    log_error "--version needs an argument"
                    exit "$EXIT_ERROR"
                fi
                target_version="$2"; shift 2 ;;
            --channel)
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    log_error "--channel needs an argument"
                    exit "$EXIT_ERROR"
                fi
                target_channel="$2"; shift 2 ;;
            --check) check_only=true; shift ;;
            --no-verify) verify=false; shift ;;
            --help|-h) usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage >&2; exit "$EXIT_ERROR" ;;
        esac
    done

    require_repository_root
    require_tools

    local current_version current_channel channel latest_version
    current_version=$(jq -r '.version' "$SOURCES_FILE")
    current_channel=$(jq -r '.channel' "$SOURCES_FILE")
    channel="${target_channel:-$current_channel}"

    case "$channel" in
        stable|alpha|enterprise) ;;
        *) log_error "Invalid channel: '$channel' (expected stable, alpha, or enterprise)"; exit "$EXIT_ERROR" ;;
    esac

    if [ -n "$target_version" ]; then
        latest_version="$target_version"
    elif ! latest_version=$(fetch_latest_version "$channel"); then
        log_error "Could not determine the latest version for channel '$channel'."
        exit "$EXIT_ERROR"
    fi
    validate_version "$latest_version"

    log_info "Channel:         $channel"
    log_info "Current version: $current_version"
    log_info "Target version:  $latest_version"

    if [ "$current_version" = "$latest_version" ] && [ "$current_channel" = "$channel" ]; then
        log_info "Already up to date."
        exit 0
    fi

    if [ "$check_only" = true ]; then
        log_info "Update available: $current_version -> $latest_version"
        exit "$EXIT_UPDATE_AVAILABLE"
    fi

    # -p keeps the original mode, so restoring cannot silently tighten it.
    if ! cp -p "$SOURCES_FILE" "$BACKUP_SOURCES"; then
        log_error "Could not back up $SOURCES_FILE"
        exit "$EXIT_ERROR"
    fi

    if ! update_sources "$latest_version" "$channel"; then
        log_error "Update failed; restoring $SOURCES_FILE"
        cp -p "$BACKUP_SOURCES" "$SOURCES_FILE"
        exit "$EXIT_ERROR"
    fi

    if [ "$verify" = true ] && ! verify_build; then
        log_error "Update failed verification; restoring $SOURCES_FILE"
        cp -p "$BACKUP_SOURCES" "$SOURCES_FILE"
        exit "$EXIT_ERROR"
    fi

    log_info "Updated grok $current_version -> $latest_version"
    git --no-pager diff --stat "$SOURCES_FILE" 2>/dev/null || true
}

main "$@"
