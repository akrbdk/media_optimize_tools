#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_MAX_DIM="${NOTES_MAX_DIM:-2048}"
readonly DEFAULT_JPEG_QUALITY="${NOTES_JPEG_QUALITY:-82}"
readonly DEFAULT_WEBP_QUALITY="${NOTES_WEBP_QUALITY:-80}"
readonly DEFAULT_PNG_COMPRESSION="${NOTES_PNG_COMPRESSION:-9}"

readonly DEFAULT_MAX_WIDTH="${NOTES_VIDEO_MAX_WIDTH:-1920}"
readonly DEFAULT_MAX_HEIGHT="${NOTES_VIDEO_MAX_HEIGHT:-1080}"
readonly DEFAULT_VIDEO_CRF="${NOTES_VIDEO_CRF:-23}"
readonly DEFAULT_VIDEO_PRESET="${NOTES_VIDEO_PRESET:-medium}"
readonly DEFAULT_AUDIO_BITRATE="${NOTES_VIDEO_AUDIO_BITRATE:-128k}"

usage() {
    cat <<'EOF'
Usage: copy_optimize_media_with_report.sh SOURCE_DIR [DESTINATION_DIR]

Creates an optimized copy of SOURCE_DIR (images + videos) and prints a detailed before/after
report showing counts, sizes, and savings so you can judge the benefit before importing
into Google Notes/Keep.

Environment overrides (images):
  NOTES_MAX_DIM
  NOTES_JPEG_QUALITY
  NOTES_WEBP_QUALITY
  NOTES_PNG_COMPRESSION

Environment overrides (videos):
  NOTES_VIDEO_MAX_WIDTH
  NOTES_VIDEO_MAX_HEIGHT
  NOTES_VIDEO_CRF
  NOTES_VIDEO_PRESET
  NOTES_VIDEO_AUDIO_BITRATE
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but was not found in PATH"
}

abs_path() {
    python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

copy_directory() {
    local source="$1"
    local dest="$2"

    mkdir -p "$dest"
    rsync -a --info=progress2 --human-readable "$source"/ "$dest"/
}

format_bytes() {
    local value="$1"
    python3 - "$value" <<'PY'
import sys
value = int(sys.argv[1])
sign = "-" if value < 0 else ""
value = abs(value)
units = ["B", "KB", "MB", "GB", "TB"]
v = float(value)
for unit in units:
    if v < 1024 or unit == units[-1]:
        if unit == "B":
            print(f"{sign}{int(v)} {unit}")
        else:
            print(f"{sign}{v:.1f} {unit}")
        break
    v /= 1024
PY
}

format_percent_saved() {
    local before="$1"
    local after="$2"
    if (( before == 0 )); then
        echo "n/a"
        return
    fi
    python3 - "$before" "$after" <<'PY'
import sys
before = int(sys.argv[1])
after = int(sys.argv[2])
saved = before - after
percent = (saved / before) * 100
print(f"{percent:+.1f}%")
PY
}

declare -a FILE_ORDER=()
declare -A FILE_TYPE=()
declare -A FILE_BEFORE_SIZE=()
declare -A FILE_AFTER_SIZE=()
declare -A TYPE_COUNT=([images]=0 [videos]=0)
declare -A TYPE_BEFORE=([images]=0 [videos]=0)
declare -A TYPE_AFTER=([images]=0 [videos]=0)

record_source_file() {
    local file="$1"
    local type_key="$2"
    local rel="${file#$SRC_ABS/}"
    local size
    size=$(stat -c%s -- "$file")

    FILE_ORDER+=("$rel")
    FILE_TYPE["$rel"]="$type_key"
    FILE_BEFORE_SIZE["$rel"]="$size"
    FILE_AFTER_SIZE["$rel"]=0

    TYPE_COUNT["$type_key"]=$(( TYPE_COUNT["$type_key"] + 1 ))
    TYPE_BEFORE["$type_key"]=$(( TYPE_BEFORE["$type_key"] + size ))
}

gather_files() {
    mapfile -d '' -t IMAGE_SOURCE_FILES < <(find "$SRC_ABS" -type f \( \
        -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o \
        -iname '*.heic' -o -iname '*.heif' \) -print0)
    for img in "${IMAGE_SOURCE_FILES[@]}"; do
        record_source_file "$img" "images"
    done

    mapfile -d '' -t VIDEO_SOURCE_FILES < <(find "$SRC_ABS" -type f \( \
        -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.mkv' -o \
        -iname '*.avi' -o -iname '*.webm' -o -iname '*.mpg' -o -iname '*.mpeg' \) -print0)
    for vid in "${VIDEO_SOURCE_FILES[@]}"; do
        record_source_file "$vid" "videos"
    done
}

init_image_tool() {
    if command -v magick >/dev/null 2>&1; then
        IMAGE_TOOL=("magick" "mogrify")
    elif command -v mogrify >/dev/null 2>&1; then
        IMAGE_TOOL=("mogrify")
    else
        fail "ImageMagick (magick or mogrify) is required for image optimization"
    fi
}

run_mogrify() {
    "${IMAGE_TOOL[@]}" "$@"
}

optimize_jpeg() {
    local file="$1"
    run_mogrify -auto-orient -strip -resize "${MAX_DIMENSION}x${MAX_DIMENSION}>" \
        -quality "${JPEG_QUALITY}" "$file"
}

optimize_png() {
    local file="$1"
    run_mogrify -auto-orient -strip -resize "${MAX_DIMENSION}x${MAX_DIMENSION}>" \
        -define png:compression-level="${PNG_COMPRESSION}" \
        -define png:exclude-chunk=all "$file"
}

optimize_webp() {
    local file="$1"
    run_mogrify -strip -resize "${MAX_DIMENSION}x${MAX_DIMENSION}>" \
        -quality "${WEBP_QUALITY}" "$file"
}

optimize_heic() {
    optimize_jpeg "$1"
}

optimize_image_file() {
    local file="$1"
    local ext="${file##*.}"
    ext="${ext,,}"
    case "$ext" in
        jpg|jpeg) optimize_jpeg "$file" ;;
        png) optimize_png "$file" ;;
        webp) optimize_webp "$file" ;;
        heic|heif) optimize_heic "$file" ;;
        *) return 1 ;;
    esac
}

optimize_video_file() {
    local file="$1"
    local tmp="${file}.optimized.$$"
    local scale="scale='min(${MAX_WIDTH},iw)':'min(${MAX_HEIGHT},ih)':force_original_aspect_ratio=decrease"

    if ffmpeg -hide_banner -loglevel error -y -i "$file" \
        -vf "$scale" \
        -c:v libx264 -preset "$VIDEO_PRESET" -crf "$VIDEO_CRF" -pix_fmt yuv420p -movflags +faststart \
        -c:a aac -b:a "$AUDIO_BITRATE" \
        "$tmp"; then
        mv "$tmp" "$file"
        return 0
    else
        rm -f "$tmp"
        return 1
    fi
}

optimize_tracked_files() {
    local total="${#FILE_ORDER[@]}"
    if (( total == 0 )); then
        echo "No supported images or videos found. Created a straight copy without changes."
        return
    fi

    local index=0
    for rel in "${FILE_ORDER[@]}"; do
        (( ++index ))
        local type_key="${FILE_TYPE[$rel]}"
        local dest_file="$DEST_ABS/$rel"
        local label="image"
        [[ "$type_key" == "videos" ]] && label="video"
        printf '[%d/%d] Optimizing %s: %s\n' "$index" "$total" "$label" "$rel"

        if [[ "$type_key" == "images" ]]; then
            optimize_image_file "$dest_file" || printf '  Skipped (unsupported format): %s\n' "$rel"
        else
            if ! optimize_video_file "$dest_file"; then
                printf '  Failed to optimize video: %s\n' "$rel" >&2
            fi
        fi
    done
}

update_after_sizes() {
    for rel in "${FILE_ORDER[@]}"; do
        local dest_file="$DEST_ABS/$rel"
        [[ -f "$dest_file" ]] || continue
        local size
        size=$(stat -c%s -- "$dest_file")
        FILE_AFTER_SIZE["$rel"]="$size"
        local type_key="${FILE_TYPE[$rel]}"
        TYPE_AFTER["$type_key"]=$(( TYPE_AFTER["$type_key"] + size ))
    done
}

print_summary_line() {
    local label="$1"
    local count="$2"
    local before="$3"
    local after="$4"
    local saved=$(( before - after ))

    printf '%-7s %6d files  %12s -> %12s  savings: %12s (%s)\n' \
        "$label" \
        "$count" \
        "$(format_bytes "$before")" \
        "$(format_bytes "$after")" \
        "$(format_bytes "$saved")" \
        "$(format_percent_saved "$before" "$after")"
}

print_summary() {
    local images_before="${TYPE_BEFORE[images]}"
    local images_after="${TYPE_AFTER[images]}"
    local videos_before="${TYPE_BEFORE[videos]}"
    local videos_after="${TYPE_AFTER[videos]}"

    local total_before=$(( images_before + videos_before ))
    local total_after=$(( images_after + videos_after ))

    echo
    echo "=== Media Optimization Report ==="
    print_summary_line "Images" "${TYPE_COUNT[images]}" "$images_before" "$images_after"
    print_summary_line "Videos" "${TYPE_COUNT[videos]}" "$videos_before" "$videos_after"
    print_summary_line "Total"  "$(( TYPE_COUNT[images] + TYPE_COUNT[videos] ))" "$total_before" "$total_after"

    if (( total_before > 0 )); then
        echo
        echo "Top files by savings:"
        local report_file
        report_file=$(mktemp)
        for rel in "${FILE_ORDER[@]}"; do
            local before="${FILE_BEFORE_SIZE[$rel]}"
            local after="${FILE_AFTER_SIZE[$rel]}"
            local saved=$(( before - after ))
            printf '%s|%s|%s|%s|%s\0' "$rel" "${FILE_TYPE[$rel]}" "$before" "$after" "$saved" >>"$report_file"
        done
        if [[ -s "$report_file" ]]; then
            local printed=0
            while IFS='|' read -r -d '' rel type before after saved; do
                (( ++printed ))
                printf '  #%d %s (%s): %s -> %s  saved %s (%s)\n' \
                    "$printed" \
                    "$rel" \
                    "${type%?}" \
                    "$(format_bytes "$before")" \
                    "$(format_bytes "$after")" \
                    "$(format_bytes "$saved")" \
                    "$(format_percent_saved "$before" "$after")"
                (( printed == 1000 )) && break
            done < <(sort -z -t'|' -k5,5nr "$report_file")
            (( printed == 0 )) && echo "  No files changed."
        else
            echo "  No files changed."
        fi
        rm -f "$report_file"
    fi
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    [[ $# -ge 1 ]] || { usage; exit 1; }

    local source_dir="$1"
    [[ -d "$source_dir" ]] || fail "Source directory '$source_dir' does not exist"

    local destination_dir="${2:-}"
    if [[ -z "$destination_dir" ]]; then
        destination_dir="${source_dir%/}_compressed"
    fi

    require_command python3
    require_command rsync

    SRC_ABS="$(abs_path "$source_dir")"
    DEST_ABS="$(abs_path "$destination_dir")"

    [[ -e "$DEST_ABS" ]] && fail "Destination '$DEST_ABS' already exists. Delete it or choose another path."
    [[ "$DEST_ABS" == "$SRC_ABS" ]] && fail "Destination must differ from source."
    [[ "$DEST_ABS" == "$SRC_ABS"/* ]] && fail "Destination may not be inside the source directory."
    [[ "$SRC_ABS" == "$DEST_ABS"/* ]] && fail "Source may not be inside the destination directory."

    gather_files

    local has_images=0
    local has_videos=0
    (( TYPE_COUNT[images] > 0 )) && has_images=1
    (( TYPE_COUNT[videos] > 0 )) && has_videos=1

    if (( has_images )); then
        init_image_tool
    fi
    if (( has_videos )); then
        require_command ffmpeg
    fi

    MAX_DIMENSION="$DEFAULT_MAX_DIM"
    JPEG_QUALITY="$DEFAULT_JPEG_QUALITY"
    WEBP_QUALITY="$DEFAULT_WEBP_QUALITY"
    PNG_COMPRESSION="$DEFAULT_PNG_COMPRESSION"

    MAX_WIDTH="$DEFAULT_MAX_WIDTH"
    MAX_HEIGHT="$DEFAULT_MAX_HEIGHT"
    VIDEO_CRF="$DEFAULT_VIDEO_CRF"
    VIDEO_PRESET="$DEFAULT_VIDEO_PRESET"
    AUDIO_BITRATE="$DEFAULT_AUDIO_BITRATE"

    [[ "$MAX_DIMENSION" =~ ^[0-9]+$ ]] || fail "NOTES_MAX_DIM must be an integer"
    [[ "$JPEG_QUALITY" =~ ^[0-9]+$ ]] || fail "NOTES_JPEG_QUALITY must be an integer"
    [[ "$WEBP_QUALITY" =~ ^[0-9]+$ ]] || fail "NOTES_WEBP_QUALITY must be an integer"
    [[ "$PNG_COMPRESSION" =~ ^[0-9]+$ ]] || fail "NOTES_PNG_COMPRESSION must be an integer"

    [[ "$MAX_WIDTH" =~ ^[0-9]+$ ]] || fail "NOTES_VIDEO_MAX_WIDTH must be an integer"
    [[ "$MAX_HEIGHT" =~ ^[0-9]+$ ]] || fail "NOTES_VIDEO_MAX_HEIGHT must be an integer"
    [[ "$VIDEO_CRF" =~ ^[0-9]+$ ]] || fail "NOTES_VIDEO_CRF must be an integer"
    [[ "$AUDIO_BITRATE" =~ ^[0-9]+[kKmM]?$ ]] || fail "NOTES_VIDEO_AUDIO_BITRATE must be like 128k"

    echo "Copying '$SRC_ABS' -> '$DEST_ABS' ..."
    copy_directory "$SRC_ABS" "$DEST_ABS"

    if (( has_images || has_videos )); then
        echo "Optimizing tracked media files ..."
        optimize_tracked_files
    fi

    update_after_sizes
    print_summary

    echo
    echo "Disk usage (du -sh):"
    du -sh "$SRC_ABS" "$DEST_ABS"
}

main "$@"
