#!/usr/bin/env bash

# media_optimize.sh — copy a media archive and optimize the copy
#
# Originals are NEVER modified. The script:
#   1. Copies SOURCE_DIR → DESTINATION_DIR with rsync
#   2. Optimizes the copy based on the chosen level
#   3. Prints a savings report with top files
#
# Supported formats:
#   HEIC/HEIF  → JPEG (always — huge savings, opens everywhere)
#   MOV        → MP4 H.264 + AAC (always — plays everywhere)
#   JPEG/WEBP  → recompressed (strip EXIF, slightly lower quality)
#   PNG        → lossless recompression (strip EXIF)
#   MP4/MKV/AVI/etc → re-encoded at levels aggressive and maximum

set -euo pipefail

# ── Level presets ────────────────────────────────────────────────────────────
# archive: convert formats only, near-lossless quality
readonly ARC_JPEG_QUALITY=95   ARC_PNG_COMPRESSION=6  ARC_IMG_MAX_DIM=99999
readonly ARC_VIDEO_CRF=18      ARC_VIDEO_PRESET="slow"
readonly ARC_VIDEO_MAX_W=3840  ARC_VIDEO_MAX_H=2160   ARC_AUDIO_BITRATE="256k"
readonly ARC_REENCODE_ALL_VIDEO=0

# moderate: safe everyday optimization, loss barely noticeable
readonly MOD_JPEG_QUALITY=88   MOD_PNG_COMPRESSION=7  MOD_IMG_MAX_DIM=8000
readonly MOD_VIDEO_CRF=23      MOD_VIDEO_PRESET="medium"
readonly MOD_VIDEO_MAX_W=3840  MOD_VIDEO_MAX_H=2160   MOD_AUDIO_BITRATE="192k"
readonly MOD_REENCODE_ALL_VIDEO=0

# aggressive: visible savings, quality still acceptable
readonly AGG_JPEG_QUALITY=80   AGG_PNG_COMPRESSION=9  AGG_IMG_MAX_DIM=3840
readonly AGG_VIDEO_CRF=26      AGG_VIDEO_PRESET="medium"
readonly AGG_VIDEO_MAX_W=1920  AGG_VIDEO_MAX_H=1080   AGG_AUDIO_BITRATE="192k"
readonly AGG_REENCODE_ALL_VIDEO=1

# maximum: max space savings, noticeable quality loss
readonly MAX_JPEG_QUALITY=70   MAX_PNG_COMPRESSION=9  MAX_IMG_MAX_DIM=2560
readonly MAX_VIDEO_CRF=28      MAX_VIDEO_PRESET="medium"
readonly MAX_VIDEO_MAX_W=1280  MAX_VIDEO_MAX_H=720    MAX_AUDIO_BITRATE="128k"
readonly MAX_REENCODE_ALL_VIDEO=1

# Estimated savings ratios per level (used only for dry-run estimates).
# Format: HEIC→JPEG / JPEG+WEBP / PNG / MOV→MP4 / existing video (if re-encoded)
# Positive = savings (smaller), negative = growth (larger).
# These are typical values — actual results vary by content.
readonly ARC_EST="−40%  −5%  −3%  +15%   skip"   # archive makes video files larger (higher quality)
readonly MOD_EST="  0%  −12%  −5%  +30%   skip"
readonly AGG_EST="+15%  −22%  −8%  +50%  +35%"
readonly MAX_EST="+40%  −35%  −10%  +65%  +55%"

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: media_optimize.sh [OPTIONS] SOURCE_DIR [DESTINATION_DIR]

Creates an optimized copy of SOURCE_DIR. Originals are never modified.
Default destination: SOURCE_DIR_optimized

Options:
  --level LEVEL                Level of optimization (default: moderate)
  --only-exts EXT[,EXT,...]   Process only these extensions, e.g. heic,mov,jpg
  --dry-run                   Show estimated savings per type, make no changes
  --log FILE                  Append all output to FILE and terminal
  --jobs N                    Parallel workers for photo/HEIC processing (default: 1)
  -h, --help                  Show this help

Levels (--level):
  archive    Near-lossless. Only converts formats (HEIC→JPEG, MOV→MP4).
             JPEG 95, no resize, CRF 18 slow 4K. Good for precious originals.

  moderate   Safe optimization. Loss barely noticeable. (default)
             JPEG 88, max 8000px, CRF 23 medium 4K. Skips existing MP4/MKV.

  aggressive Strong compression. Quality still acceptable for everyday use.
             JPEG 80, max 3840px, CRF 26 medium 1080p. Re-encodes MP4/MKV too.

  maximum    Maximum space savings. Noticeable quality loss.
             JPEG 70, max 2560px, CRF 28 medium 720p. Re-encodes everything.

Extension filter (--only-exts):
  Process only the listed extensions. Useful to run just one pass at a time.
  Examples:
    --only-exts heic           only convert iPhone photos
    --only-exts mov            only convert iPhone videos
    --only-exts jpg,jpeg,png   only optimize still images
    --only-exts heic,mov       iPhone formats only

Quality overrides (applied on top of --level, for fine-tuning):
  --jpeg-quality N     JPEG/WEBP quality 1-100
  --png-compression N  PNG compression 0-9 (lossless)
  --max-image-dim N    Resize if longest side > N pixels
  --crf N              Video CRF 0-51 (lower = better quality)
  --preset NAME        ffmpeg preset: ultrafast fast medium slow veryslow
  --max-width N        Downscale video if wider than N px
  --max-height N       Downscale video if taller than N px
  --audio-bitrate VAL  AAC bitrate e.g. 128k 192k 256k

Examples:
  media_optimize.sh /media/usb/Photos
  media_optimize.sh --level aggressive /media/usb/Photos /media/usb/Photos_opt
  media_optimize.sh --dry-run --level aggressive /media/usb/Photos
  media_optimize.sh --only-exts heic,mov /media/usb/Photos
  media_optimize.sh --level archive --only-exts heic /media/usb/Photos
  media_optimize.sh --log ~/opt.log --jobs 4 /media/usb/Photos
EOF
}

fail()            { echo "Error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not found in PATH."; }
abs_path()        { python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1"; }

format_bytes() {
    python3 - "$1" <<'PY'
import sys
value = int(sys.argv[1])
sign = "-" if value < 0 else ""
value = abs(value)
v = float(value)
for unit in ["B","KB","MB","GB","TB"]:
    if v < 1024 or unit == "TB":
        print(f"{sign}{int(v)} {unit}" if unit == "B" else f"{sign}{v:.1f} {unit}")
        break
    v /= 1024
PY
}

format_percent() {
    local before="$1" after="$2"
    (( before == 0 )) && { echo "n/a"; return; }
    python3 - "$before" "$after" <<'PY'
import sys
b, a = int(sys.argv[1]), int(sys.argv[2])
print(f"{(b-a)/b*100:+.1f}%")
PY
}

format_elapsed() {
    local s="$1"
    local h=$(( s/3600 )) m=$(( (s%3600)/60 )) sec=$(( s%60 ))
    (( h > 0 )) && { printf '%dh %dm %ds' "$h" "$m" "$sec"; return; }
    (( m > 0 )) && { printf '%dm %ds' "$m" "$sec"; return; }
    printf '%ds' "$sec"
}

check_free_space() {
    local src="$1" dest_parent="$2"
    local src_bytes free_bytes
    src_bytes=$(du -sb "$src" 2>/dev/null | cut -f1) || return 0
    free_bytes=$(df -B1 --output=avail "$dest_parent" 2>/dev/null | tail -1 | tr -d ' ') || return 0
    if (( src_bytes > free_bytes )); then
        echo "WARNING: Source ~$(format_bytes "$src_bytes") but only $(format_bytes "$free_bytes") free on destination." >&2
        printf 'Continue anyway? [y/N] ' >&2
        local reply; read -r reply </dev/tty || reply=n
        [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted." >&2; exit 1; }
    fi
}

# ── Extension filter ──────────────────────────────────────────────────────────
FILTER_EXTS=""   # empty = allow all

ext_allowed() {
    local ext="${1,,}"
    [[ -z "$FILTER_EXTS" ]] && return 0
    local IFS=','
    local e
    for e in $FILTER_EXTS; do
        [[ "${e,,}" == "$ext" ]] && return 0
    done
    return 1
}

# Filter an array in-place by allowed extensions (nameref, bash 4.3+)
filter_by_ext() {
    local -n _arr="$1"
    local -a _filtered=()
    local _f _ext
    for _f in "${_arr[@]+"${_arr[@]}"}"; do
        _ext="${_f##*.}"
        ext_allowed "$_ext" && _filtered+=("$_f")
    done
    _arr=("${_filtered[@]+"${_filtered[@]}"}")
}

# ── Image tool ────────────────────────────────────────────────────────────────
IMGCMD=""
init_image_tool() {
    if command -v magick >/dev/null 2>&1; then
        IMGCMD="magick convert"
    elif command -v convert >/dev/null 2>&1 && convert --version 2>&1 | grep -qi imagemagick; then
        IMGCMD="convert"
    else
        fail "ImageMagick (magick or convert) is required for photo processing."
    fi
}
run_convert() { $IMGCMD "$@"; }

# ── Temp file cleanup ─────────────────────────────────────────────────────────
STATS_DIR=""
CURRENT_TEMP=""
cleanup() {
    [[ -n "$CURRENT_TEMP" ]] && rm -f "$CURRENT_TEMP"
    [[ -n "$STATS_DIR"    ]] && rm -rf "$STATS_DIR"
}
trap cleanup EXIT INT TERM

# ── Parallel pool ─────────────────────────────────────────────────────────────
PARALLEL_JOBS=1
wait_for_slot() {
    while (( $(jobs -rp | wc -l) >= PARALLEL_JOBS )); do
        wait -n 2>/dev/null || sleep 0.05
    done
}

# ── Per-file processors ───────────────────────────────────────────────────────

# Optimize JPEG/WEBP/PNG in the copy. Replaces only if result is smaller.
# Writes result to $stats_file: "photo|rel|sz_before|sz_after"
optimize_photo() {
    local file="$1" rel="$2" stats_file="$3"
    local ext="${file##*.}"; ext="${ext,,}"
    local tmp="${file}.opt.${BASHPID}"
    trap 'rm -f "$tmp"' EXIT

    local extra_args=()
    case "$ext" in
        jpg|jpeg|webp) extra_args=(-quality "$JPEG_QUALITY") ;;
        png)           extra_args=(-define "png:compression-level=${PNG_COMPRESSION}" \
                                   -define png:exclude-chunk=all) ;;
    esac

    local sz_before sz_after
    sz_before=$(stat -c%s -- "$file")

    if run_convert -auto-orient -strip \
        -resize "${IMG_MAX_DIM}x${IMG_MAX_DIM}>" \
        "${extra_args[@]}" "$file" "$tmp" 2>/dev/null; then
        sz_after=$(stat -c%s -- "$tmp" 2>/dev/null || echo 0)
        if (( sz_after > 0 && sz_after < sz_before )); then
            mv "$tmp" "$file"
            printf 'photo|%s|%d|%d\n' "$rel" "$sz_before" "$sz_after" > "$stats_file"
            return
        fi
    fi
    rm -f "$tmp"
    printf 'photo|%s|%d|%d\n' "$rel" "$sz_before" "$sz_before" > "$stats_file"
}

# Convert HEIC/HEIF → JPEG. Writes result to $stats_file.
convert_heic() {
    local file="$1" rel="$2" stats_file="$3"
    local dst="${file%.*}.jpg"
    local tmp="${dst}.opt.${BASHPID}"
    CURRENT_TEMP="$tmp"

    if [[ -f "$dst" ]]; then
        CURRENT_TEMP=""
        printf 'heic|%s|0|0|skip\n' "$rel" > "$stats_file"
        return
    fi

    local sz_before sz_after
    sz_before=$(stat -c%s -- "$file")

    if run_convert -auto-orient -strip -quality "$JPEG_QUALITY" "$file" "$tmp" 2>/dev/null; then
        sz_after=$(stat -c%s -- "$tmp" 2>/dev/null || echo 0)
        if (( sz_after > 0 )); then
            mv "$tmp" "$dst"
            rm -f "$file"
            CURRENT_TEMP=""
            printf 'heic|%s|%d|%d\n' "$rel" "$sz_before" "$sz_after" > "$stats_file"
            return
        fi
    fi
    rm -f "$tmp"
    CURRENT_TEMP=""
    printf 'heic|%s|%d|%d|fail\n' "$rel" "$sz_before" "$sz_before" > "$stats_file"
}

# Convert video → MP4. Renames if source is not .mp4. Writes result to $stats_file.
convert_video() {
    local file="$1" rel="$2" stats_file="$3"
    local ext="${file##*.}"; ext="${ext,,}"
    local dst tmp

    if [[ "$ext" == "mp4" ]]; then
        dst="$file"; tmp="${file}.opt.${BASHPID}.mp4"
    else
        dst="${file%.*}.mp4"; tmp="${dst}.opt.${BASHPID}.mp4"
    fi
    CURRENT_TEMP="$tmp"

    local scale="scale='if(gt(iw,${VIDEO_MAX_W}),${VIDEO_MAX_W},iw)':'if(gt(ih,${VIDEO_MAX_H}),${VIDEO_MAX_H},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

    local sz_before sz_after
    sz_before=$(stat -c%s -- "$file")

    if ffmpeg -hide_banner -loglevel warning -stats -y \
        -i "$file" -vf "$scale" \
        -c:v libx264 -preset "$VIDEO_PRESET" -crf "$VIDEO_CRF" \
        -pix_fmt yuv420p -movflags +faststart \
        -c:a aac -b:a "$AUDIO_BITRATE" "$tmp"; then
        sz_after=$(stat -c%s -- "$tmp" 2>/dev/null || echo 0)
        if (( sz_after > 0 )); then
            mv "$tmp" "$dst"
            [[ "$file" != "$dst" ]] && rm -f "$file"
            CURRENT_TEMP=""
            printf 'video|%s|%d|%d\n' "$rel" "$sz_before" "$sz_after" > "$stats_file"
            return
        fi
    fi
    rm -f "$tmp"
    CURRENT_TEMP=""
    printf 'video|%s|%d|%d|fail\n' "$rel" "$sz_before" "$sz_before" > "$stats_file"
}

# ── Top-savings report ────────────────────────────────────────────────────────
print_top_savings() {
    local stats_dir="$1"
    local top=20
    local tmp_all
    tmp_all=$(mktemp)
    cat "$stats_dir"/*.result 2>/dev/null > "$tmp_all" || true
    [[ -s "$tmp_all" ]] || { rm -f "$tmp_all"; return; }

    echo
    echo "Top $top files by bytes saved:"
    local printed=0
    while IFS='|' read -r type rel before after rest; do
        [[ "${rest:-}" == "skip" || "${rest:-}" == "fail" ]] && continue
        local saved=$(( before - after ))
        (( saved <= 0 )) && continue
        (( ++printed ))
        printf '  #%-3d [%-5s] %s\n        %s → %s  saved %s (%s)\n' \
            "$printed" "$type" "$rel" \
            "$(format_bytes "$before")" "$(format_bytes "$after")" \
            "$(format_bytes "$saved")" "$(format_percent "$before" "$after")"
        (( printed >= top )) && break
    done < <(awk -F'|' '{saved=$3-$4; print saved"|"$0}' "$tmp_all" | sort -t'|' -k1,1nr | cut -d'|' -f2-)
    (( printed == 0 )) && echo "  No files were reduced in size."
    rm -f "$tmp_all"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    local stats_dir="$1" elapsed="$2"
    local heic_ok=0 heic_before=0 heic_after=0 heic_fail=0 heic_skip=0
    local photo_ok=0 photo_before=0 photo_after=0 photo_fail=0
    local video_ok=0 video_before=0 video_after=0 video_fail=0

    while IFS='|' read -r type rel before after rest; do
        case "$type" in
            heic)
                case "${rest:-}" in
                    skip) (( ++heic_skip )) ;;
                    fail) (( ++heic_fail )) ;;
                    *) heic_before=$(( heic_before+before )); heic_after=$(( heic_after+after )); (( ++heic_ok )) ;;
                esac ;;
            photo)
                case "${rest:-}" in
                    fail) (( ++photo_fail )) ;;
                    *) photo_before=$(( photo_before+before )); photo_after=$(( photo_after+after )); (( ++photo_ok )) ;;
                esac ;;
            video)
                case "${rest:-}" in
                    fail) (( ++video_fail )) ;;
                    *) video_before=$(( video_before+before )); video_after=$(( video_after+after )); (( ++video_ok )) ;;
                esac ;;
        esac
    done < <(cat "$stats_dir"/*.result 2>/dev/null || true)

    local total_before=$(( heic_before+photo_before+video_before ))
    local total_after=$(( heic_after+photo_after+video_after ))
    local total_fail=$(( heic_fail+photo_fail+video_fail ))

    echo
    echo "=== Optimization Summary ==="
    printf '%-8s  %5d files  %12s → %12s  %s\n' \
        "HEIC"   "$heic_ok"  "$(format_bytes "$heic_before")"  "$(format_bytes "$heic_after")"  "$(format_percent "$heic_before"  "$heic_after")"
    printf '%-8s  %5d files  %12s → %12s  %s\n' \
        "Photos" "$photo_ok" "$(format_bytes "$photo_before")" "$(format_bytes "$photo_after")" "$(format_percent "$photo_before" "$photo_after")"
    printf '%-8s  %5d files  %12s → %12s  %s\n' \
        "Videos" "$video_ok" "$(format_bytes "$video_before")" "$(format_bytes "$video_after")" "$(format_percent "$video_before" "$video_after")"
    echo "──────────────────────────────────────────────────────────────────"
    printf '%-8s  %5d files  %12s → %12s  %s\n' \
        "Total" "$(( heic_ok+photo_ok+video_ok ))" \
        "$(format_bytes "$total_before")" "$(format_bytes "$total_after")" \
        "$(format_percent "$total_before" "$total_after")"
    printf 'Elapsed : %s\n' "$(format_elapsed "$elapsed")"
    (( heic_skip  > 0 )) && printf 'Skipped : %d HEIC (target .jpg already existed)\n' "$heic_skip"
    (( total_fail > 0 )) && printf 'Failed  : %d file(s) — originals preserved in copy\n' "$total_fail" >&2
}

# ── Main optimizer (runs on the copy) ─────────────────────────────────────────
run_optimization() {
    local dest="$1"
    local idx

    local -a heic_files img_files video_primary video_other
    mapfile -d '' -t heic_files    < <(find "$dest" -type f \( -iname '*.heic' -o -iname '*.heif' \) -print0)
    mapfile -d '' -t img_files     < <(find "$dest" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0)
    mapfile -d '' -t video_primary < <(find "$dest" -type f -iname '*.mov' -print0)
    if (( REENCODE_ALL_VIDEO )); then
        mapfile -d '' -t video_other < <(find "$dest" -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.m4v' -o -iname '*.webm' -o -iname '*.mpg' -o -iname '*.mpeg' \) -print0)
    else
        video_other=()
    fi

    filter_by_ext heic_files
    filter_by_ext img_files
    filter_by_ext video_primary
    filter_by_ext video_other

    printf 'Found: %d HEIC, %d photos, %d videos to process\n' \
        "${#heic_files[@]}" "${#img_files[@]}" "$(( ${#video_primary[@]} + ${#video_other[@]} ))"
    echo

    # HEIC → JPEG
    if (( ${#heic_files[@]} > 0 )); then
        printf '--- HEIC/HEIF → JPEG  (quality=%d) ---\n' "$JPEG_QUALITY"
        idx=0
        for file in "${heic_files[@]}"; do
            (( ++idx ))
            local rel="${file#$dest/}"
            printf '[%d/%d] %s\n' "$idx" "${#heic_files[@]}" "$rel"
            local sf="$STATS_DIR/heic_${idx}.result"
            wait_for_slot
            local _f="$file" _r="$rel" _sf="$sf"
            { convert_heic "$_f" "$_r" "$_sf"; } &
        done
        wait; echo
    fi

    # Photos
    if (( ${#img_files[@]} > 0 )); then
        printf '--- Photos  (quality=%d, max=%dpx) ---\n' "$JPEG_QUALITY" "$IMG_MAX_DIM"
        idx=0
        for file in "${img_files[@]}"; do
            (( ++idx ))
            local rel="${file#$dest/}"
            printf '[%d/%d] %s\n' "$idx" "${#img_files[@]}" "$rel"
            local sf="$STATS_DIR/photo_${idx}.result"
            wait_for_slot
            local _f="$file" _r="$rel" _sf="$sf"
            { optimize_photo "$_f" "$_r" "$_sf"; } &
        done
        wait; echo
    fi

    # Videos
    local -a all_videos=("${video_primary[@]+"${video_primary[@]}"}" "${video_other[@]+"${video_other[@]}"}")
    if (( ${#all_videos[@]} > 0 )); then
        printf '--- Videos  (CRF=%d, preset=%s, max %dx%d, audio=%s) ---\n' \
            "$VIDEO_CRF" "$VIDEO_PRESET" "$VIDEO_MAX_W" "$VIDEO_MAX_H" "$AUDIO_BITRATE"
        idx=0
        for file in "${all_videos[@]}"; do
            (( ++idx ))
            local rel="${file#$dest/}"
            local sz; sz=$(stat -c%s -- "$file")
            printf '[%d/%d] %s  (%s)\n' "$idx" "${#all_videos[@]}" "$rel" "$(format_bytes "$sz")"
            local sf="$STATS_DIR/video_${idx}.result"
            convert_video "$file" "$rel" "$sf"
        done; echo
    fi
}

# ── Dry-run with estimated savings ────────────────────────────────────────────
dry_run_estimate() {
    # Compute estimated size after based on level ratios.
    # Args: sz_total ratio_pct  (ratio_pct = expected savings 0-100, negative = grows)
    python3 - "$1" "$2" <<'PY'
import sys
total = int(sys.argv[1])
ratio = float(sys.argv[2])   # positive = savings %
after = int(total * (1 - ratio / 100))
print(after)
PY
}

run_dry_run() {
    local src="$1"
    echo "DRY RUN — no files will be copied or modified."
    echo "Savings estimates are approximate (typical values, actual depends on content)."
    echo

    local -a heic_files img_files video_primary video_other skipped_vid
    mapfile -d '' -t heic_files    < <(find "$src" -type f \( -iname '*.heic' -o -iname '*.heif' \) -print0)
    mapfile -d '' -t img_files     < <(find "$src" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0)
    mapfile -d '' -t video_primary < <(find "$src" -type f -iname '*.mov' -print0)
    if (( REENCODE_ALL_VIDEO )); then
        mapfile -d '' -t video_other < <(find "$src" -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.m4v' -o -iname '*.webm' -o -iname '*.mpg' -o -iname '*.mpeg' \) -print0)
        skipped_vid=()
    else
        video_other=()
        mapfile -d '' -t skipped_vid < <(find "$src" -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' \) -print0)
    fi

    filter_by_ext heic_files
    filter_by_ext img_files
    filter_by_ext video_primary
    filter_by_ext video_other
    filter_by_ext skipped_vid

    # Estimated savings ratios (%) by level
    local heic_ratio img_ratio vid_ratio other_ratio
    case "$LEVEL" in
        archive)    heic_ratio=-40; img_ratio=5;  vid_ratio=15;  other_ratio=0  ;;
        moderate)   heic_ratio=0;   img_ratio=12; vid_ratio=30;  other_ratio=0  ;;
        aggressive) heic_ratio=15;  img_ratio=22; vid_ratio=50;  other_ratio=35 ;;
        maximum)    heic_ratio=40;  img_ratio=35; vid_ratio=65;  other_ratio=55 ;;
    esac

    # Sum sizes per type
    local heic_sz=0 img_sz=0 vid_sz=0 other_sz=0 skipped_sz=0
    local f
    for f in "${heic_files[@]+"${heic_files[@]}"}";    do heic_sz=$(( heic_sz + $(stat -c%s -- "$f") ));    done
    for f in "${img_files[@]+"${img_files[@]}"}";      do img_sz=$(( img_sz + $(stat -c%s -- "$f") ));      done
    for f in "${video_primary[@]+"${video_primary[@]}"}"; do vid_sz=$(( vid_sz + $(stat -c%s -- "$f") ));   done
    for f in "${video_other[@]+"${video_other[@]}"}";  do other_sz=$(( other_sz + $(stat -c%s -- "$f") ));  done
    for f in "${skipped_vid[@]+"${skipped_vid[@]}"}";  do skipped_sz=$(( skipped_sz + $(stat -c%s -- "$f") )); done

    local heic_est img_est vid_est other_est
    heic_est=$(dry_run_estimate "$heic_sz" "$heic_ratio")
    img_est=$(dry_run_estimate "$img_sz" "$img_ratio")
    vid_est=$(dry_run_estimate "$vid_sz" "$vid_ratio")
    other_est=$(dry_run_estimate "$other_sz" "$other_ratio")

    local total_before=$(( heic_sz + img_sz + vid_sz + other_sz ))
    local total_after=$(( heic_est + img_est + vid_est + other_est ))

    printf 'Level       : %s\n' "$LEVEL"
    [[ -n "$FILTER_EXTS" ]] && printf 'Extensions  : %s\n' "$FILTER_EXTS"
    echo
    printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
        "HEIC→JPEG" "${#heic_files[@]}" \
        "$(format_bytes "$heic_sz")" "$(format_bytes "$heic_est")" \
        "$(format_percent "$heic_sz" "$heic_est")"
    printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
        "Photos" "${#img_files[@]}" \
        "$(format_bytes "$img_sz")" "$(format_bytes "$img_est")" \
        "$(format_percent "$img_sz" "$img_est")"
    printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
        "MOV→MP4" "$(( ${#video_primary[@]} + ${#video_other[@]} ))" \
        "$(format_bytes "$vid_sz")" "$(format_bytes "$vid_est")" \
        "$(format_percent "$vid_sz" "$vid_est")"
    if (( REENCODE_ALL_VIDEO && other_sz > 0 )); then
        printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
            "MP4/MKV" "${#video_other[@]}" \
            "$(format_bytes "$other_sz")" "$(format_bytes "$other_est")" \
            "$(format_percent "$other_sz" "$other_est")"
    fi
    echo "──────────────────────────────────────────────────────────────────"
    printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
        "Total" "$(( ${#heic_files[@]} + ${#img_files[@]} + ${#video_primary[@]} + ${#video_other[@]} ))" \
        "$(format_bytes "$total_before")" "$(format_bytes "$total_after")" \
        "$(format_percent "$total_before" "$total_after")"

    if (( ${#skipped_vid[@]} > 0 )); then
        echo
        printf 'Skipped (not re-encoded at this level): %d MP4/MKV/AVI  ~%s\n' \
            "${#skipped_vid[@]}" "$(format_bytes "$skipped_sz")"
        printf '  → use --level aggressive or maximum to include them\n'
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    local level="moderate"
    local dry_run=0
    local log_file=""
    local positional=()
    local ov_jpeg_quality="" ov_png_comp="" ov_img_max_dim=""
    local ov_crf="" ov_preset="" ov_max_w="" ov_max_h="" ov_audio=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)           usage; exit 0 ;;
            --dry-run)           dry_run=1; shift ;;
            --level)             [[ $# -ge 2 ]] || fail "--level requires a value"; level="$2"; shift 2 ;;
            --level=*)           level="${1#--level=}"; shift ;;
            --only-exts)         [[ $# -ge 2 ]] || fail "--only-exts requires a value"; FILTER_EXTS="$2"; shift 2 ;;
            --only-exts=*)       FILTER_EXTS="${1#--only-exts=}"; shift ;;
            --jobs)              [[ $# -ge 2 ]] || fail "--jobs requires a value"; PARALLEL_JOBS="$2"; shift 2 ;;
            --jobs=*)            PARALLEL_JOBS="${1#--jobs=}"; shift ;;
            --log)               [[ $# -ge 2 ]] || fail "--log requires a value"; log_file="$2"; shift 2 ;;
            --log=*)             log_file="${1#--log=}"; shift ;;
            --jpeg-quality)      [[ $# -ge 2 ]] || fail "--jpeg-quality requires a value"; ov_jpeg_quality="$2"; shift 2 ;;
            --jpeg-quality=*)    ov_jpeg_quality="${1#--jpeg-quality=}"; shift ;;
            --png-compression)   [[ $# -ge 2 ]] || fail "--png-compression requires a value"; ov_png_comp="$2"; shift 2 ;;
            --png-compression=*) ov_png_comp="${1#--png-compression=}"; shift ;;
            --max-image-dim)     [[ $# -ge 2 ]] || fail "--max-image-dim requires a value"; ov_img_max_dim="$2"; shift 2 ;;
            --max-image-dim=*)   ov_img_max_dim="${1#--max-image-dim=}"; shift ;;
            --crf)               [[ $# -ge 2 ]] || fail "--crf requires a value"; ov_crf="$2"; shift 2 ;;
            --crf=*)             ov_crf="${1#--crf=}"; shift ;;
            --preset)            [[ $# -ge 2 ]] || fail "--preset requires a value"; ov_preset="$2"; shift 2 ;;
            --preset=*)          ov_preset="${1#--preset=}"; shift ;;
            --max-width)         [[ $# -ge 2 ]] || fail "--max-width requires a value"; ov_max_w="$2"; shift 2 ;;
            --max-width=*)       ov_max_w="${1#--max-width=}"; shift ;;
            --max-height)        [[ $# -ge 2 ]] || fail "--max-height requires a value"; ov_max_h="$2"; shift 2 ;;
            --max-height=*)      ov_max_h="${1#--max-height=}"; shift ;;
            --audio-bitrate)     [[ $# -ge 2 ]] || fail "--audio-bitrate requires a value"; ov_audio="$2"; shift 2 ;;
            --audio-bitrate=*)   ov_audio="${1#--audio-bitrate=}"; shift ;;
            --)                  shift; positional+=("$@"); break ;;
            -*)                  fail "Unknown option: $1" ;;
            *)                   positional+=("$1"); shift ;;
        esac
    done

    [[ ${#positional[@]} -ge 1 ]] || { usage; exit 1; }
    case "$level" in
        archive|moderate|aggressive|maximum) ;;
        *) fail "--level must be: archive, moderate, aggressive, or maximum" ;;
    esac
    [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] && (( PARALLEL_JOBS >= 1 )) \
        || fail "--jobs must be a positive integer"

    # Apply level preset
    LEVEL="$level"
    case "$level" in
        archive)
            JPEG_QUALITY=$ARC_JPEG_QUALITY  PNG_COMPRESSION=$ARC_PNG_COMPRESSION
            IMG_MAX_DIM=$ARC_IMG_MAX_DIM    VIDEO_CRF=$ARC_VIDEO_CRF
            VIDEO_PRESET=$ARC_VIDEO_PRESET  VIDEO_MAX_W=$ARC_VIDEO_MAX_W
            VIDEO_MAX_H=$ARC_VIDEO_MAX_H    AUDIO_BITRATE=$ARC_AUDIO_BITRATE
            REENCODE_ALL_VIDEO=$ARC_REENCODE_ALL_VIDEO ;;
        moderate)
            JPEG_QUALITY=$MOD_JPEG_QUALITY  PNG_COMPRESSION=$MOD_PNG_COMPRESSION
            IMG_MAX_DIM=$MOD_IMG_MAX_DIM    VIDEO_CRF=$MOD_VIDEO_CRF
            VIDEO_PRESET=$MOD_VIDEO_PRESET  VIDEO_MAX_W=$MOD_VIDEO_MAX_W
            VIDEO_MAX_H=$MOD_VIDEO_MAX_H    AUDIO_BITRATE=$MOD_AUDIO_BITRATE
            REENCODE_ALL_VIDEO=$MOD_REENCODE_ALL_VIDEO ;;
        aggressive)
            JPEG_QUALITY=$AGG_JPEG_QUALITY  PNG_COMPRESSION=$AGG_PNG_COMPRESSION
            IMG_MAX_DIM=$AGG_IMG_MAX_DIM    VIDEO_CRF=$AGG_VIDEO_CRF
            VIDEO_PRESET=$AGG_VIDEO_PRESET  VIDEO_MAX_W=$AGG_VIDEO_MAX_W
            VIDEO_MAX_H=$AGG_VIDEO_MAX_H    AUDIO_BITRATE=$AGG_AUDIO_BITRATE
            REENCODE_ALL_VIDEO=$AGG_REENCODE_ALL_VIDEO ;;
        maximum)
            JPEG_QUALITY=$MAX_JPEG_QUALITY  PNG_COMPRESSION=$MAX_PNG_COMPRESSION
            IMG_MAX_DIM=$MAX_IMG_MAX_DIM    VIDEO_CRF=$MAX_VIDEO_CRF
            VIDEO_PRESET=$MAX_VIDEO_PRESET  VIDEO_MAX_W=$MAX_VIDEO_MAX_W
            VIDEO_MAX_H=$MAX_VIDEO_MAX_H    AUDIO_BITRATE=$MAX_AUDIO_BITRATE
            REENCODE_ALL_VIDEO=$MAX_REENCODE_ALL_VIDEO ;;
    esac

    # Apply individual overrides
    [[ -n "$ov_jpeg_quality" ]] && JPEG_QUALITY="$ov_jpeg_quality"
    [[ -n "$ov_png_comp"     ]] && PNG_COMPRESSION="$ov_png_comp"
    [[ -n "$ov_img_max_dim"  ]] && IMG_MAX_DIM="$ov_img_max_dim"
    [[ -n "$ov_crf"          ]] && VIDEO_CRF="$ov_crf"
    [[ -n "$ov_preset"       ]] && VIDEO_PRESET="$ov_preset"
    [[ -n "$ov_max_w"        ]] && VIDEO_MAX_W="$ov_max_w"
    [[ -n "$ov_max_h"        ]] && VIDEO_MAX_H="$ov_max_h"
    [[ -n "$ov_audio"        ]] && AUDIO_BITRATE="$ov_audio"

    # Validate
    [[ "$JPEG_QUALITY"    =~ ^[0-9]+$ ]] || fail "--jpeg-quality must be an integer"
    [[ "$PNG_COMPRESSION" =~ ^[0-9]+$ ]] || fail "--png-compression must be an integer"
    [[ "$IMG_MAX_DIM"     =~ ^[0-9]+$ ]] || fail "--max-image-dim must be an integer"
    [[ "$VIDEO_CRF"       =~ ^[0-9]+$ ]] || fail "--crf must be an integer"
    [[ "$VIDEO_MAX_W"     =~ ^[0-9]+$ ]] || fail "--max-width must be an integer"
    [[ "$VIDEO_MAX_H"     =~ ^[0-9]+$ ]] || fail "--max-height must be an integer"
    [[ "$AUDIO_BITRATE"   =~ ^[0-9]+[kKmM]?$ ]] || fail "--audio-bitrate must be like 192k"
    case "$VIDEO_PRESET" in
        ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
        *) fail "--preset must be: ultrafast superfast veryfast faster fast medium slow slower veryslow" ;;
    esac

    local source_dir="${positional[0]}"
    [[ -d "$source_dir" ]] || fail "Source directory '$source_dir' does not exist"
    local dest_dir="${positional[1]:-}"
    [[ -z "$dest_dir" ]] && dest_dir="${source_dir%/}_optimized"

    require_command python3
    require_command rsync

    if [[ -n "$log_file" ]]; then
        exec > >(tee -a "$log_file") 2>&1
        echo "Logging to: $log_file"
    fi

    local src_abs dest_abs
    src_abs="$(abs_path "$source_dir")"
    dest_abs="$(abs_path "$dest_dir")"

    [[ -e "$dest_abs"              ]] && fail "Destination '$dest_abs' already exists. Delete it or choose another path."
    [[ "$dest_abs" == "$src_abs"   ]] && fail "Destination must differ from source."
    [[ "$dest_abs" == "$src_abs"/* ]] && fail "Destination may not be inside source."
    [[ "$src_abs"  == "$dest_abs"/*]] && fail "Source may not be inside destination."

    echo "============================================"
    printf 'Source      : %s\n' "$src_abs"
    printf 'Destination : %s\n' "$dest_abs"
    printf 'Level       : %s\n' "$level"
    [[ -n "$FILTER_EXTS" ]] && printf 'Extensions  : %s\n' "$FILTER_EXTS"
    printf 'Settings    : JPEG %d  PNG-comp %d  max-dim %dpx  CRF %d  preset %s  %dx%d  audio %s\n' \
        "$JPEG_QUALITY" "$PNG_COMPRESSION" "$IMG_MAX_DIM" \
        "$VIDEO_CRF" "$VIDEO_PRESET" "$VIDEO_MAX_W" "$VIDEO_MAX_H" "$AUDIO_BITRATE"
    echo "============================================"
    echo

    if [[ "$dry_run" -eq 1 ]]; then
        run_dry_run "$src_abs"
        exit 0
    fi

    check_free_space "$src_abs" "$(dirname "$dest_abs")"
    init_image_tool
    require_command ffmpeg

    STATS_DIR=$(mktemp -d)
    local START_TIME=$SECONDS

    echo "Step 1/2: Copying '$src_abs' → '$dest_abs' ..."
    mkdir -p "$dest_abs"
    rsync -a --info=progress2 --human-readable "$src_abs"/ "$dest_abs"/
    echo

    echo "Step 2/2: Optimizing copy ..."
    echo
    run_optimization "$dest_abs"

    local elapsed=$(( SECONDS - START_TIME ))
    print_summary "$STATS_DIR" "$elapsed"
    print_top_savings "$STATS_DIR"

    echo
    echo "Disk usage (du -sh):"
    du -sh "$src_abs" "$dest_abs"
    echo
    echo "Done."
    echo "  Optimized copy : $dest_abs"
    echo "  Original       : $src_abs  (untouched)"
}

main "$@"
