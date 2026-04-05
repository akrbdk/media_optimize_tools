#!/usr/bin/env bash

set -euo pipefail

DEFAULT_DEPTH="${FOLDER_STATS_DEPTH:-2}"
DEFAULT_TOP_FILES="${FOLDER_STATS_TOP_FILES:-50}"
DEFAULT_PHOTO_MB="${FOLDER_STATS_PHOTO_MB:-4}"
DEFAULT_VIDEO_MB="${FOLDER_STATS_VIDEO_MB:-80}"

usage() {
    cat <<'EOF'
Usage: folder_stats.sh [OPTIONS] TARGET_DIR

Prints a quick summary of disk usage per subdirectory, lists the largest files,
and shows files that would benefit most from aggressive-level optimization.

Options:
  --depth N           Subdirectory depth for du breakdown (default: 2)
  --top-files K       Show top K largest files (default: 50)
  --photo-mb N        Flag photos larger than N MB (default: 4)
  --video-mb N        Flag videos larger than N MB (default: 80)
  --log FILE          Append all output to FILE in addition to the terminal
  -h, --help          Show this help
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

print_problematic_files() {
    local target="$1" photo_mb="$2" video_mb="$3"
    local photo_bytes=$(( photo_mb * 1024 * 1024 ))
    local video_bytes=$(( video_mb * 1024 * 1024 ))

    echo
    echo "Files that need aggressive compression:"
    echo "  Photos > ${photo_mb} MB | Videos/MOV > ${video_mb} MB | All MOV (need conversion)"
    echo

    local photo_count=0 video_count=0 mov_count=0
    local photo_total=0 video_total=0 mov_total=0

    while IFS= read -r -d '' line; do
        local sz path ext
        sz="${line%%$'\t'*}"
        path="${line#*$'\t'}"
        ext="${path##*.}"; ext="${ext,,}"

        case "$ext" in
            jpg|jpeg|png|webp)
                if (( sz >= photo_bytes )); then
                    printf '  [photo %5.1f MB]  %s\n' "$(awk -v s="$sz" 'BEGIN{printf "%.1f", s/1024/1024}')" "$path"
                    (( ++photo_count ))
                    (( photo_total += sz ))
                fi ;;
            mov)
                printf '  [MOV   %5.1f MB]  %s\n' "$(awk -v s="$sz" 'BEGIN{printf "%.1f", s/1024/1024}')" "$path"
                (( ++mov_count ))
                (( mov_total += sz )) ;;
            mp4|mkv|avi|m4v|webm|mpg|mpeg)
                if (( sz >= video_bytes )); then
                    printf '  [video %5.1f MB]  %s\n' "$(awk -v s="$sz" 'BEGIN{printf "%.1f", s/1024/1024}')" "$path"
                    (( ++video_count ))
                    (( video_total += sz ))
                fi ;;
        esac
    done < <(find "$target" -type f -printf '%s\t%p\0' | sort -rz)

    local total_count=$(( photo_count + video_count + mov_count ))
    local total_bytes=$(( photo_total + video_total + mov_total ))

    echo
    if (( total_count == 0 )); then
        echo "  No problematic files found."
        return
    fi

    (( photo_count > 0 )) && printf '  Large photos : %d files  %.1f MB\n' "$photo_count" "$(awk -v s="$photo_total" 'BEGIN{printf "%.1f", s/1024/1024}')"
    (( mov_count   > 0 )) && printf '  MOV files    : %d files  %.1f MB\n' "$mov_count"   "$(awk -v s="$mov_total"   'BEGIN{printf "%.1f", s/1024/1024}')"
    (( video_count > 0 )) && printf '  Large videos : %d files  %.1f MB\n' "$video_count" "$(awk -v s="$video_total" 'BEGIN{printf "%.1f", s/1024/1024}')"
    printf '  Total        : %d files  %.1f MB\n' "$total_count" "$(awk -v s="$total_bytes" 'BEGIN{printf "%.1f", s/1024/1024}')"
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
    local photo_mb="$DEFAULT_PHOTO_MB"
    local video_mb="$DEFAULT_VIDEO_MB"
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
            --photo-mb)
                [[ $# -ge 2 ]] || fail "--photo-mb requires a value"
                photo_mb="$2"; shift 2 ;;
            --photo-mb=*)
                photo_mb="${1#--photo-mb=}"; shift ;;
            --video-mb)
                [[ $# -ge 2 ]] || fail "--video-mb requires a value"
                video_mb="$2"; shift 2 ;;
            --video-mb=*)
                video_mb="${1#--video-mb=}"; shift ;;
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
    [[ "$depth"     =~ ^[0-9]+$ ]] || fail "--depth must be an integer"
    [[ "$top_files" =~ ^[0-9]+$ ]] || fail "--top-files must be an integer"
    [[ "$photo_mb"  =~ ^[0-9]+$ ]] || fail "--photo-mb must be an integer"
    [[ "$video_mb"  =~ ^[0-9]+$ ]] || fail "--video-mb must be an integer"

    require_command du
    require_command find

    if [[ -n "$log_file" ]]; then
        exec > >(tee -a "$log_file") 2>&1
        echo "Logging to: $log_file"
    fi

    local START_TIME=$SECONDS

    echo "Analyzing: $(realpath "$target_dir")"
    echo
    print_directory_usage "$target_dir" "$depth"
    print_largest_files "$target_dir" "$top_files"
    print_problematic_files "$target_dir" "$photo_mb" "$video_mb"

    echo
    printf 'Elapsed: %s\n' "$(format_elapsed "$(( SECONDS - START_TIME ))")"
}

main "$@"
