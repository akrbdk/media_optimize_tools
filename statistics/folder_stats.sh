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
  --dupes             Find duplicate files by content hash (requires python3)
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

print_duplicate_stats() {
    local target="$1"
    echo
    echo "Duplicate files (by content hash):"

    require_command python3
    local tmp_dupes
    tmp_dupes=$(mktemp)

    python3 - "$target" >"$tmp_dupes" 2>/dev/null <<'PY'
import sys, os, hashlib, collections

def md5_file(path, buf=65536):
    h = hashlib.md5()
    try:
        with open(path, 'rb') as f:
            while True:
                chunk = f.read(buf)
                if not chunk: break
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None

target = sys.argv[1]
by_size = collections.defaultdict(list)
for root, dirs, files in os.walk(target):
    dirs.sort(); files.sort()
    for fname in files:
        path = os.path.join(root, fname)
        try:
            by_size[os.path.getsize(path)].append(path)
        except OSError:
            pass

by_hash = collections.defaultdict(list)
for sz, paths in by_size.items():
    if len(paths) < 2:
        continue
    for path in paths:
        h = md5_file(path)
        if h:
            by_hash[h].append(path)

groups = 0
dup_files = []
for h, paths in sorted(by_hash.items()):
    if len(paths) < 2:
        continue
    groups += 1
    for path in sorted(paths)[1:]:
        dup_files.append(path)

dup_bytes = sum(os.path.getsize(p) for p in dup_files if os.path.exists(p))
print("STATS\t{}\t{}\t{}".format(groups, len(dup_files), dup_bytes))
for p in dup_files:
    print(p)
PY

    if [[ ! -s "$tmp_dupes" ]]; then
        rm -f "$tmp_dupes"
        echo "  No duplicate files found."
        return
    fi

    local stats_line groups dup_count dup_bytes
    stats_line=$(head -1 "$tmp_dupes")
    IFS=$'\t' read -r _ groups dup_count dup_bytes <<< "$stats_line"

    if [[ "$groups" == "0" || -z "$groups" ]]; then
        rm -f "$tmp_dupes"
        echo "  No duplicate files found."
        return
    fi

    tail -n +2 "$tmp_dupes" | while IFS= read -r path; do
        local sz; sz=$(stat -c%s -- "$path" 2>/dev/null || echo 0)
        printf '  [dup]  %s\n' "$path"
    done

    echo
    printf '  Duplicate groups : %d\n' "$groups"
    printf '  Redundant files  : %d\n' "$dup_count"
    printf '  Wasted space     : %s\n' \
        "$(awk -v s="$dup_bytes" 'BEGIN{
            if (s>=1073741824) printf "%.1f GB", s/1073741824
            else if (s>=1048576) printf "%.1f MB", s/1048576
            else if (s>=1024) printf "%.1f KB", s/1024
            else printf "%d B", s
        }')"

    rm -f "$tmp_dupes"
}

print_largest_files() {
    local target="$1" limit="$2" photo_mb="$3" video_mb="$4"
    local photo_bytes=$(( photo_mb * 1024 * 1024 ))
    local video_bytes=$(( video_mb * 1024 * 1024 ))
    echo
    echo "Top $limit largest files (photos > ${photo_mb} MB, videos > ${video_mb} MB):"
    find "$target" -type f -printf '%s\t%p\n' | sort -t$'\t' -k1,1nr | \
        awk -F'\t' -v pb="$photo_bytes" -v vb="$video_bytes" -v lim="$limit" '
        count >= lim { exit }
        {
            sz = $1 + 0; path = $2
            ext = tolower(path); sub(/.*\./, "", ext)
            if (ext ~ /^(jpg|jpeg|png|webp)$/ && sz < pb) next
            if (ext ~ /^(mp4|mkv|avi|m4v|webm|mpg|mpeg|mov)$/ && sz < vb) next
            if (sz >= 1073741824)      printf "  %6.1f GB  %s\n", sz/1073741824, path
            else if (sz >= 1048576)    printf "  %6.1f MB  %s\n", sz/1048576, path
            else if (sz >= 1024)       printf "  %6.1f KB  %s\n", sz/1024, path
            else                       printf "  %6d  B   %s\n", sz, path
            count++
        }'
}

main() {
    local depth="$DEFAULT_DEPTH"
    local top_files="$DEFAULT_TOP_FILES"
    local photo_mb="$DEFAULT_PHOTO_MB"
    local video_mb="$DEFAULT_VIDEO_MB"
    local log_file=""
    local target_dir=""
    local show_dupes=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage; exit 0 ;;
            --dupes)
                show_dupes=1; shift ;;
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
    print_largest_files "$target_dir" "$top_files" "$photo_mb" "$video_mb"
    print_problematic_files "$target_dir" "$photo_mb" "$video_mb"
    (( show_dupes )) && print_duplicate_stats "$target_dir"

    echo
    printf 'Elapsed: %s\n' "$(format_elapsed "$(( SECONDS - START_TIME ))")"
}

main "$@"
