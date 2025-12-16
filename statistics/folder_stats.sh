#!/usr/bin/env bash

set -euo pipefail

DEFAULT_DEPTH="${FOLDER_STATS_DEPTH:-2}"
DEFAULT_TOP_FILES="${FOLDER_STATS_TOP_FILES:-50}"

usage() {
    cat <<'EOF'
Usage: folder_stats.sh TARGET_DIR [--depth N] [--top-files K]

Prints a quick summary of disk usage per subdirectory and lists the largest files
inside TARGET_DIR. No files are modified; this is purely informational so you can spot
heavy folders before running optimization scripts.

Environment overrides:
  FOLDER_STATS_DEPTH      default 2
  FOLDER_STATS_TOP_FILES  default 50
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but was not found in PATH"
}

print_directory_usage() {
    local target="$1"
    local depth="$2"
    echo "Directory usage (depth $depth):"
    du -h --max-depth="$depth" "$target" | sort -h
}

print_largest_files() {
    local target="$1"
    local limit="$2"
    echo
    echo "Top $limit largest files:"
    find "$target" -type f -printf '%s\t%p\n' | sort -nr | head -n "$limit" | \
        awk '{
            split("B KB MB GB TB", unit);
            asize=$1;
            u=1;
            while(asize>=1024 && u<5){asize/=1024;u++}
            printf "  %-6.1f %s  %s\n", asize, unit[u], $2
        }'
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    [[ $# -ge 1 ]] || { usage; exit 1; }
    local target_dir="$1"
    shift

    [[ -d "$target_dir" ]] || fail "Directory '$target_dir' does not exist"

    local depth="$DEFAULT_DEPTH"
    local top_files="$DEFAULT_TOP_FILES"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --depth)
                shift
                [[ -n "${1:-}" ]] || fail "--depth requires a value"
                depth="$1"
                ;;
            --top-files)
                shift
                [[ -n "${1:-}" ]] || fail "--top-files requires a value"
                top_files="$1"
                ;;
            *)
                fail "Unknown option: $1"
                ;;
        esac
        shift || break
    done

    [[ "$depth" =~ ^[0-9]+$ ]] || fail "Depth must be an integer"
    [[ "$top_files" =~ ^[0-9]+$ ]] || fail "Top file count must be an integer"

    require_command du
    require_command find

    echo "Analyzing: $(realpath "$target_dir")"
    echo
    print_directory_usage "$target_dir" "$depth"
    print_largest_files "$target_dir" "$top_files"
}

main "$@"
