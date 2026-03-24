#!/usr/bin/env bash
#
# Build / release script for FS Property Borders mod.
#
# Usage:
#   ./build.sh build   [--fs_ver VER]          Build the zip artifact
#   ./build.sh release-test [--fs_ver VER]     Alias for build (local snapshot)
#   ./build.sh release <semver> [--fs_ver VER] Tag + push to trigger CI release
#
# --fs_ver accepts a single version or comma-separated list (e.g. 25,28).
# If omitted, defaults to the highest-numbered FS*_Src directory found.
#
# Examples:
#   ./build.sh build                              # builds for latest FS version
#   ./build.sh build --fs_ver 28                  # builds FS28_PropertyBorders.zip
#   ./build.sh release 1.0.0.0                    # release for latest FS version
#   ./build.sh release 1.0.0.0 --fs_ver 25,28     # release for both FS25 and FS28
#   ./build.sh release 1.0.0.0-beta.1 --fs_ver 25

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Find the highest-numbered FS*_Src directory
detect_latest_fs_version() {
    local latest=""
    for d in "${SCRIPT_DIR}"/FS*_Src; do
        [ -d "$d" ] || continue
        local name
        name="$(basename "$d")"
        local ver="${name#FS}"
        ver="${ver%_Src}"
        if [ -z "$latest" ] || [ "$ver" -gt "$latest" ] 2>/dev/null; then
            latest="$ver"
        fi
    done

    if [ -z "$latest" ]; then
        echo "ERROR: No FS*_Src directories found in ${SCRIPT_DIR}" >&2
        exit 1
    fi
    echo "$latest"
}

# Parse comma-separated --fs_ver value into the FS_VERSIONS array
parse_fs_versions() {
    local raw="$1"
    IFS=',' read -ra FS_VERSIONS <<< "$raw"
}

usage() {
    echo "Usage:"
    echo "  $0 build [--fs_ver VER]"
    echo "  $0 release-test [--fs_ver VER]"
    echo "  $0 release <semver> [--fs_ver VER]"
    echo ""
    echo "VER is a single version (25) or comma-separated list (25,28)."
    echo "Defaults to the latest FS*_Src directory if omitted."
    exit 1
}

do_build() {
    local fs_ver="$1"
    local src_dir="${SCRIPT_DIR}/FS${fs_ver}_Src"
    local mod_name="FS${fs_ver}_PropertyBorders"
    local out_dir="${SCRIPT_DIR}/dist"
    local zip_path="${out_dir}/${mod_name}.zip"

    if [ ! -d "$src_dir" ]; then
        echo "ERROR: Source directory not found: ${src_dir}" >&2
        exit 1
    fi

    echo "Building ${mod_name}.zip from FS${fs_ver}_Src ..."

    mkdir -p "$out_dir"

    # Remove previous artifact
    rm -f "$zip_path"

    # Stage into a temp dir
    local staging
    staging="$(mktemp -d)"

    # Copy mod contents (exclude dev-only files)
    cp -r "$src_dir"/* "$staging/"

    # Remove dev-only files from staging
    find "$staging" -name '*.bak' -delete 2>/dev/null || true
    find "$staging" -name '*.log' -delete 2>/dev/null || true
    find "$staging" -name '*.png' -delete 2>/dev/null || true

    # Create the zip with contents at the archive root
    if command -v zip &>/dev/null; then
        (cd "$staging" && zip -r "$zip_path" .)
    elif command -v git &>/dev/null; then
        (cd "$staging" && git init -q && git add -A && git commit -qm "build" && git archive --format=zip -o "$zip_path" HEAD)
        rm -rf "$staging/.git"
    else
        echo "ERROR: No zip tool found. Install 'zip' or 'git'." >&2
        rm -rf "$staging"
        exit 1
    fi

    rm -rf "$staging"

    local size
    size=$(du -k "$zip_path" | cut -f1)
    echo "  Created: ${zip_path} (${size} KB)"
    echo "Done."
}

do_release() {
    local version="$1"
    shift
    local fs_versions=("$@")

    local tag="release/${version}"

    # Validate version format: X.Y.Z.W or X.Y.Z.W-prerelease.N
    if ! echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z]+\.[0-9]+)?$'; then
        echo "ERROR: Invalid version format '${version}'." >&2
        echo "  Expected: X.Y.Z.W  or  X.Y.Z.W-alpha.N  or  X.Y.Z.W-beta.N" >&2
        exit 1
    fi

    # Validate that source dirs exist for all requested FS versions
    for fv in "${fs_versions[@]}"; do
        local src_dir="${SCRIPT_DIR}/FS${fv}_Src"
        if [ ! -d "$src_dir" ]; then
            echo "ERROR: Source directory not found: ${src_dir}" >&2
            exit 1
        fi
    done

    # Ensure working tree is clean
    if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]; then
        echo "ERROR: Working tree is not clean. Commit or stash changes first." >&2
        exit 1
    fi

    # Build all versions locally to verify artifacts are valid
    for fv in "${fs_versions[@]}"; do
        do_build "$fv"
    done

    # Update fs_versions.json so CI knows which versions to build
    local json_array
    json_array=$(printf '%s\n' "${fs_versions[@]}" | jq -s '.')
    echo "{\"versions\": ${json_array}}" > "${SCRIPT_DIR}/fs_versions.json"

    # Commit the config change
    git -C "$SCRIPT_DIR" add fs_versions.json
    if ! git -C "$SCRIPT_DIR" diff --cached --quiet; then
        git -C "$SCRIPT_DIR" commit -m "Set build targets to FS$(IFS=,; echo "${fs_versions[*]}") for ${version}"
    fi

    echo ""
    local fs_list
    fs_list=$(IFS=', '; echo "${fs_versions[*]}")
    echo "Creating tag: ${tag} (FS versions: ${fs_list})"
    git -C "$SCRIPT_DIR" tag -a "$tag" -m "Release ${version} (FS${fs_list})"

    echo "Pushing commit and tag to origin ..."
    git -C "$SCRIPT_DIR" push origin HEAD "$tag"

    echo ""
    echo "Release tag '${tag}' pushed. CI will build and publish the GitHub release."
}

# ---------------------------------------------------------------------------
# Main — parse arguments
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
    usage
fi

COMMAND="$1"
shift

# Collect positional args and --fs_ver flag
POSITIONAL=()
FS_VERSIONS=()
FS_VER_RAW=""

while [ $# -gt 0 ]; do
    case "$1" in
        --fs_ver)
            if [ $# -lt 2 ]; then
                echo "ERROR: --fs_ver requires a value (e.g. --fs_ver 25,28)" >&2
                exit 1
            fi
            FS_VER_RAW="$2"
            shift 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

# Parse --fs_ver or detect latest
if [ -n "$FS_VER_RAW" ]; then
    parse_fs_versions "$FS_VER_RAW"
else
    FS_VERSIONS=("$(detect_latest_fs_version)")
fi

case "$COMMAND" in
    build)
        do_build "${FS_VERSIONS[0]}"
        ;;
    release-test)
        do_build "${FS_VERSIONS[0]}"
        ;;
    release)
        if [ ${#POSITIONAL[@]} -lt 1 ]; then
            echo "ERROR: release requires a version argument." >&2
            usage
        fi
        do_release "${POSITIONAL[0]}" "${FS_VERSIONS[@]}"
        ;;
    *)
        echo "ERROR: Unknown command '${COMMAND}'" >&2
        usage
        ;;
esac
