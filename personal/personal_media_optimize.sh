#!/usr/bin/env bash

set -euo pipefail

# Gentle defaults intended for personal archives (high quality, minimal resizing).
readonly DEFAULT_IMG_MAX_DIM="${PERSONAL_MAX_DIM:-4096}"
readonly DEFAULT_JPEG_QUALITY="${PERSONAL_JPEG_QUALITY:-90}"
readonly DEFAULT_WEBP_QUALITY="${PERSONAL_WEBP_QUALITY:-88}"
readonly DEFAULT_PNG_COMPRESSION="${PERSONAL_PNG_COMPRESSION:-6}"

readonly DEFAULT_VIDEO_MAX_WIDTH="${PERSONAL_VIDEO_MAX_WIDTH:-3840}"
readonly DEFAULT_VIDEO_MAX_HEIGHT="${PERSONAL_VIDEO_MAX_HEIGHT:-2160}"
readonly DEFAULT_VIDEO_CRF="${PERSONAL_VIDEO_CRF:-20}"
readonly DEFAULT_VIDEO_PRESET="${PERSONAL_VIDEO_PRESET:-slow}"
readonly DEFAULT_AUDIO_BITRATE="${PERSONAL_VIDEO_AUDIO_BITRATE:-192k}"

usage() {
    cat <<'EOF'
Usage: personal_media_optimize.sh SOURCE_DIR [DESTINATION_DIR]

Creates a safety copy of SOURCE_DIR (default: SOURCE_DIR_safe) and gently optimizes
photos/videos with high-quality settings suitable for personal archives stored on external drives.

Environment overrides:
  PERSONAL_MAX_DIM               (default 4096)
  PERSONAL_JPEG_QUALITY          (default 90)
  PERSONAL_WEBP_QUALITY          (default 88)
  PERSONAL_PNG_COMPRESSION       (default 6)
  PERSONAL_VIDEO_MAX_WIDTH       (default 3840)
  PERSONAL_VIDEO_MAX_HEIGHT      (default 2160)
  PERSONAL_VIDEO_CRF             (default 20)
  PERSONAL_VIDEO_PRESET          (default slow)
  PERSONAL_VIDEO_AUDIO_BITRATE   (default 192k)
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
    local type="$2"
    local rel="${file#$SRC_ABS/}"
    local size
    size=$(stat -c%s -- "$file")

    FILE_ORDER+=("$rel")
    FILE_TYPE["$rel"]="$type"
    FILE_BEFORE_SIZE["$rel"]="$size"
    FILE_AFTER_SIZE["$rel"]=0
    TYPE_COUNT["$type"]=$(( TYPE_COUNT["$type"] + 1 ))
    TYPE_BEFORE["$type"]=$(( TYPE_BEFORE["$type"] + size ))
}

gather_media_files() {
    mapfile -d '' -t IMAGE_FILES < <(find "$SRC_ABS" -type f \( \
        -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o \
        -iname '*.heic' -o -iname '*.heif' \) -print0)
    for img in "${IMAGE_FILES[@]}"; do
        record_source_file "$img" "images"
    done

    mapfile -d '' -t VIDEO_FILES < <(find "$SRC_ABS" -type f \( \
        -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.mkv' -o \
        -iname '*.avi' -o -iname '*.webm' -o -iname '*.mpg' -o -iname '*.mpeg' \) -print0)
    for vid in "${VIDEO_FILES[@]}"; do
        record_source_file "$vid" "videos"
    done
}

init_image_tool() {
    if command -v magick >/dev/null 2>&1; then
        IMAGE_TOOL=("magick" "mogrify")
    elif command -v mogrify >/dev/null 2>&1; then
        IMAGE_TOOL=("mogrify")
    else
        fail "ImageMagick (magick or mogrify) is required for photo optimization"
    fi
}

run_mogrify() {
    "${IMAGE_TOOL[@]}" "$@"
}

optimize_jpeg() {
    local file="$1"
    run_mogrify -auto-orient -strip -resize "${IMG_MAX_DIMENSION}x${IMG_MAX_DIMENSION}>" \
        -quality "${JPEG_QUALITY}" "$file"
}

optimize_png() {
    local file="$1"
    run_mogrify -auto-orient -strip -resize "${IMG_MAX_DIMENSION}x${IMG_MAX_DIMENSION}>" \
        -define png:compression-level="${PNG_COMPRESSION}" "$file"
}

optimize_webp() {
    local file="$1"
    run_mogrify -strip -resize "${IMG_MAX_DIMENSION}x${IMG_MAX_DIMENSION}>" \
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
    local scale="scale='min(${VIDEO_MAX_WIDTH},iw)':'min(${VIDEO_MAX_HEIGHT},ih)':force_original_aspect_ratio=decrease"

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

optimize_tracked_media() {
    local target_dir="$1"
    local total="${#FILE_ORDER[@]}"
    if (( total == 0 )); then
        echo "No supported photos or videos found. Copy remains untouched."
        return
    fi

    local index=0
    for rel in "${FILE_ORDER[@]}"; do
        (( ++index ))
        local dest_file="$target_dir/$rel"
        local type="${FILE_TYPE[$rel]}"
        printf '[%d/%d] Processing %s (%s)\n' "$index" "$total" "$rel" "$type"
        if [[ "$type" == "images" ]]; then
            optimize_image_file "$dest_file" || printf '  Skipped unsupported photo: %s\n' "$rel"
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
        local type="${FILE_TYPE[$rel]}"
        TYPE_AFTER["$type"]=$(( TYPE_AFTER["$type"] + size ))
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
    echo "=== Personal Media Optimization Report ==="
    print_summary_line "Photos" "${TYPE_COUNT[images]}" "$images_before" "$images_after"
    print_summary_line "Videos" "${TYPE_COUNT[videos]}" "$videos_before" "$videos_after"
    print_summary_line "Total"  "$(( TYPE_COUNT[images] + TYPE_COUNT[videos] ))" "$total_before" "$total_after"
}

print_top_savings() {
    local total="${#FILE_ORDER[@]}"
    (( total == 0 )) && return

    local temp
    temp=$(mktemp)
    for rel in "${FILE_ORDER[@]}"; do
        local before="${FILE_BEFORE_SIZE[$rel]}"
        local after="${FILE_AFTER_SIZE[$rel]}"
        local saved=$(( before - after ))
        printf '%s|%s|%s|%s|%s\0' "$rel" "${FILE_TYPE[$rel]}" "$before" "$after" "$saved" >>"$temp"
    done

    if [[ -s "$temp" ]]; then
        echo
        echo "Top files by savings:"
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
        done < <(sort -z -t'|' -k5,5nr "$temp")
        (( printed == 0 )) && echo "  No files changed."
    fi
    rm -f "$temp"
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
        destination_dir="${source_dir%/}_safe"
    fi

    require_command python3
    require_command rsync

    SRC_ABS="$(abs_path "$source_dir")"
    DEST_ABS="$(abs_path "$destination_dir")"

    [[ -e "$DEST_ABS" ]] && fail "Destination '$DEST_ABS' already exists. Delete it or pick another path."
    [[ "$DEST_ABS" == "$SRC_ABS" ]] && fail "Destination must differ from source."
    [[ "$DEST_ABS" == "$SRC_ABS"/* ]] && fail "Destination may not be inside the source directory."
    [[ "$SRC_ABS" == "$DEST_ABS"/* ]] && fail "Source may not be inside the destination directory."

    gather_media_files

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

    IMG_MAX_DIMENSION="$DEFAULT_IMG_MAX_DIM"
    JPEG_QUALITY="$DEFAULT_JPEG_QUALITY"
    WEBP_QUALITY="$DEFAULT_WEBP_QUALITY"
    PNG_COMPRESSION="$DEFAULT_PNG_COMPRESSION"

    VIDEO_MAX_WIDTH="$DEFAULT_VIDEO_MAX_WIDTH"
    VIDEO_MAX_HEIGHT="$DEFAULT_VIDEO_MAX_HEIGHT"
    VIDEO_CRF="$DEFAULT_VIDEO_CRF"
    VIDEO_PRESET="$DEFAULT_VIDEO_PRESET"
    AUDIO_BITRATE="$DEFAULT_AUDIO_BITRATE"

    [[ "$IMG_MAX_DIMENSION" =~ ^[0-9]+$ ]] || fail "PERSONAL_MAX_DIM must be an integer"
    [[ "$JPEG_QUALITY" =~ ^[0-9]+$ ]] || fail "PERSONAL_JPEG_QUALITY must be an integer"
    [[ "$WEBP_QUALITY" =~ ^[0-9]+$ ]] || fail "PERSONAL_WEBP_QUALITY must be an integer"
    [[ "$PNG_COMPRESSION" =~ ^[0-9]+$ ]] || fail "PERSONAL_PNG_COMPRESSION must be an integer"
    [[ "$VIDEO_MAX_WIDTH" =~ ^[0-9]+$ ]] || fail "PERSONAL_VIDEO_MAX_WIDTH must be an integer"
    [[ "$VIDEO_MAX_HEIGHT" =~ ^[0-9]+$ ]] || fail "PERSONAL_VIDEO_MAX_HEIGHT must be an integer"
    [[ "$VIDEO_CRF" =~ ^[0-9]+$ ]] || fail "PERSONAL_VIDEO_CRF must be an integer"
    [[ "$AUDIO_BITRATE" =~ ^[0-9]+[kKmM]?$ ]] || fail "PERSONAL_VIDEO_AUDIO_BITRATE must be like 192k"

    echo "Copying '$SRC_ABS' -> '$DEST_ABS' ..."
    copy_directory "$SRC_ABS" "$DEST_ABS"

    if (( has_images || has_videos )); then
        echo "Optimizing media in '$DEST_ABS' with gentle settings ..."
        optimize_tracked_media "$DEST_ABS"
        update_after_sizes
        print_summary
        print_top_savings
    else
        echo "No supported media detected; copy created without modifications."
    fi

    echo
    echo "Disk usage (du -sh):"
    du -sh "$SRC_ABS" "$DEST_ABS"

    echo
    echo "Done. Safe copy located at: $DEST_ABS"
}

main "$@"
