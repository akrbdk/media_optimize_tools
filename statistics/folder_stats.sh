#!/usr/bin/env bash

set -euo pipefail

DEFAULT_DEPTH="${FOLDER_STATS_DEPTH:-2}"
DEFAULT_TOP_FILES="${FOLDER_STATS_TOP_FILES:-50}"

usage() {
    cat <<'EOF'
Usage: folder_stats.sh [OPTIONS] TARGET_DIR

Prints a quick summary of disk usage per subdirectory and lists the largest files
inside TARGET_DIR. No files are modified; this is purely informational so you can spot
heavy folders before running optimization scripts.

Options:
  --depth N        Subdirectory depth for du breakdown (default: 2, override: FOLDER_STATS_DEPTH)
  --top-files K    Show top K largest files (default: 50, override: FOLDER_STATS_TOP_FILES)
  --log FILE       Append all output to FILE in addition to the terminal
  -h, --help       Show this help
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but was not found in PATH"
}

format_elapsed() {
    local secs="$1"
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    if (( h > 0 )); then
        printf '%dh %dm %ds' "$h" "$m" "$s"
    elif (( m > 0 )); then
        printf '%dm %ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
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
    local depth="$DEFAULT_DEPTH"
    local top_files="$DEFAULT_TOP_FILES"
    local log_file=""
    local target_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage; exit 0 ;;
            --depth)
                [[ $# -ge 2 ]] || fail "--depth requires a value"
                depth="$2"; shift 2 ;;
            --depth=*)
                depth="${1#--depth=}"; shift ;;
            --top-files)
                [[ $# -ge 2 ]] || fail "--top-files requires a value"
                top_files="$2"; shift 2 ;;
            --top-files=*)
                top_files="${1#--top-files=}"; shift ;;
            --log)
                [[ $# -ge 2 ]] || fail "--log requires a value"
                log_file="$2"; shift 2 ;;
            --log=*)
                log_file="${1#--log=}"; shift ;;
            -*)
                fail "Unknown option: $1" ;;
            *)
                [[ -z "$target_dir" ]] || fail "Unexpected argument: $1"
                target_dir="$1"; shift ;;
        esac
    done

    [[ -n "$target_dir" ]] || { usage; exit 1; }
    [[ -d "$target_dir" ]] || fail "Directory '$target_dir' does not exist"
    [[ "$depth" =~ ^[0-9]+$ ]]     || fail "--depth must be an integer"
    [[ "$top_files" =~ ^[0-9]+$ ]] || fail "--top-files must be an integer"

    require_command du
    require_command find

    # Set up log file tee before any output
    if [[ -n "$log_file" ]]; then
        exec > >(tee -a "$log_file") 2>&1
        echo "Logging to: $log_file"
    fi

    local START_TIME=$SECONDS

    echo "Analyzing: $(realpath "$target_dir")"
    echo
    print_directory_usage "$target_dir" "$depth"
    print_largest_files "$target_dir" "$top_files"

    echo
    printf 'Elapsed: %s\n' "$(format_elapsed "$(( SECONDS - START_TIME ))")"
}

main "$@"
