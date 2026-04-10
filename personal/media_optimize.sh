#!/usr/bin/env bash

# media_optimize.sh — copy a media archive and optimize the copy
#
# Originals are NEVER modified. The script:
#   1. Copies SOURCE_DIR → DESTINATION_DIR with rsync
#   2. Optimizes the copy based on the chosen level
#   3. Prints a savings report with top files
#
# Supported formats:
#   MOV        → MP4 H.264 + AAC (always — plays everywhere)
#   JPEG/WEBP  → recompressed (strip EXIF, slightly lower quality)
#   PNG        → lossless recompression (strip EXIF)
#   MP4/MKV/AVI/etc → re-encoded at levels aggressive and maximum

set -euo pipefail

# ── Level presets ────────────────────────────────────────────────────────────
# archive: convert formats only, near-lossless quality
readonly ARC_JPEG_QUALITY=95   ARC_IMG_MAX_DIM=99999
readonly ARC_VIDEO_CRF=20      ARC_VIDEO_PRESET="slow"
readonly ARC_VIDEO_MAX_W=3840  ARC_VIDEO_MAX_H=2160   ARC_AUDIO_BITRATE="256k"
readonly ARC_REENCODE_ALL_VIDEO=0

# moderate: safe everyday optimization, loss barely noticeable
readonly MOD_JPEG_QUALITY=88   MOD_IMG_MAX_DIM=8000
readonly MOD_VIDEO_CRF=25      MOD_VIDEO_PRESET="medium"
readonly MOD_VIDEO_MAX_W=3840  MOD_VIDEO_MAX_H=2160   MOD_AUDIO_BITRATE="192k"
readonly MOD_REENCODE_ALL_VIDEO=1

# aggressive: visible savings, quality still acceptable
readonly AGG_JPEG_QUALITY=80   AGG_IMG_MAX_DIM=3840
readonly AGG_VIDEO_CRF=28      AGG_VIDEO_PRESET="medium"
readonly AGG_VIDEO_MAX_W=1920  AGG_VIDEO_MAX_H=1080   AGG_AUDIO_BITRATE="192k"
readonly AGG_REENCODE_ALL_VIDEO=1

# maximum: max space savings, noticeable quality loss
readonly MAX_JPEG_QUALITY=70   MAX_IMG_MAX_DIM=2560
readonly MAX_VIDEO_CRF=32      MAX_VIDEO_PRESET="medium"
readonly MAX_VIDEO_MAX_W=1280  MAX_VIDEO_MAX_H=720    MAX_AUDIO_BITRATE="128k"
readonly MAX_REENCODE_ALL_VIDEO=1

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: media_optimize.sh [OPTIONS] SOURCE_DIR [DESTINATION_DIR]

Creates an optimized copy of SOURCE_DIR. Originals are never modified.
Default destination: SOURCE_DIR_<level>  (e.g. Photos_aggressive)

Options:
  --level LEVEL                Level of optimization (default: moderate)
  --only-exts EXT[,EXT,...]   Process only these extensions, e.g. mov,jpg,png
  --skip-exts EXT[,EXT,...]   Skip these extensions, e.g. mp4,mkv
  --dry-run                   Show estimated savings per type, make no changes
  --skip-copy                 Skip rsync step; optimize an already-copied directory
  --copy-dupes DIR            Find duplicate files and copy redundant ones to DIR
  --delete-dupes              Find duplicate files and delete redundant ones (asks confirmation)
  --log FILE                  Append all output to FILE and terminal
  --jobs N                    Parallel workers for photo/video processing (default: 1)
  -h, --help                  Show this help

Levels (--level):
  archive    Near-lossless. Only converts formats (MOV→MP4).
             JPEG 95, no resize, CRF 18 slow 4K. Good for precious originals.

  moderate   Safe optimization. Loss barely noticeable. (default)
             JPEG 88, max 8000px, CRF 23 medium 4K. Re-encodes all video.

  aggressive Strong compression. Quality still acceptable for everyday use.
             JPEG 80, max 3840px, CRF 26 medium 1080p. Re-encodes MP4/MKV too.

  maximum    Maximum space savings. Noticeable quality loss.
             JPEG 70, max 2560px, CRF 28 medium 720p. Re-encodes everything.

Extension filters:
  --only-exts and --skip-exts are mutually exclusive.
  Examples:
    --only-exts mov              only convert videos
    --only-exts jpg,jpeg,png     only optimize photos
    --skip-exts mp4,mkv,avi      skip all video re-encoding
    --skip-exts mov              skip MOV conversion

Quality overrides (applied on top of --level, for fine-tuning):
  --jpeg-quality N     JPEG/WEBP/PNG quality 1-100 (PNG is converted to JPEG)
  --max-image-dim N    Resize if longest side > N pixels
  --crf N              Video CRF 0-51 (lower = better quality)
  --preset NAME        ffmpeg preset: ultrafast fast medium slow veryslow
  --max-width N        Downscale video if wider than N px
  --max-height N       Downscale video if taller than N px
  --audio-bitrate VAL  AAC bitrate e.g. 128k 192k 256k
  --min-photo-mb N     Skip photos already smaller than N MB
  --min-video-mb N     Skip videos/MOV already smaller than N MB

Examples:
  media_optimize.sh /media/usb/Photos
  media_optimize.sh --level aggressive /media/usb/Photos /media/usb/Photos_opt
  media_optimize.sh --dry-run --level aggressive /media/usb/Photos
  media_optimize.sh --only-exts mov,jpg,jpeg /media/usb/Photos
  media_optimize.sh --skip-exts mp4,mkv /media/usb/Photos
  media_optimize.sh --log ~/opt.log --jobs 4 /media/usb/Photos
  media_optimize.sh --skip-copy --level aggressive /media/usb/Photos_aggressive
  media_optimize.sh --copy-dupes /tmp/dupes_review /media/usb/Photos
  media_optimize.sh --delete-dupes /media/usb/Photos
EOF
}

fail()            { echo "Error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not found in PATH."; }
abs_path()        { realpath -m "$1"; }

# Pure-awk formatting — no Python subprocess per call
format_bytes() {
    awk -v v="$1" 'BEGIN{
        s = (v < 0) ? "-" : ""; v = (v < 0) ? -v : v
        u = "B"
        if (v >= 1024) { v /= 1024; u = "KB" }
        if (v >= 1024) { v /= 1024; u = "MB" }
        if (v >= 1024) { v /= 1024; u = "GB" }
        if (v >= 1024) { v /= 1024; u = "TB" }
        if (u == "B") printf "%s%d %s\n", s, v, u
        else          printf "%s%.1f %s\n", s, v, u
    }'
}

format_percent() {
    local before="$1" after="$2"
    (( before == 0 )) && { echo "n/a"; return; }
    awk -v b="$before" -v a="$after" 'BEGIN{ printf "%+.1f%%\n", (b-a)/b*100 }'
}

format_elapsed() {
    local s="$1"
    local h=$(( s/3600 )) m=$(( (s%3600)/60 )) sec=$(( s%60 ))
    (( h > 0 )) && { printf '%dh %dm %ds' "$h" "$m" "$sec"; return; }
    (( m > 0 )) && { printf '%dm %ds' "$m" "$sec"; return; }
    printf '%ds' "$sec"
}

check_free_space() {
    local src="$1" dest_parent="$2" level="${3:-moderate}"
    local src_bytes free_bytes
    src_bytes=$(du -sb "$src" 2>/dev/null | cut -f1) || return 0
    free_bytes=$(df -B1 --output=avail "$dest_parent" 2>/dev/null | tail -1 | tr -d ' ') || return 0

    # Estimate output size based on level (conservative but realistic)
    local ratio
    case "$level" in
        archive)    ratio=100 ;;
        moderate)   ratio=85  ;;
        aggressive) ratio=60  ;;
        maximum)    ratio=45  ;;
        *)          ratio=85  ;;
    esac
    local est_bytes
    est_bytes=$(awk -v s="$src_bytes" -v r="$ratio" 'BEGIN{ printf "%d\n", s*r/100 }')

    if (( est_bytes > free_bytes )); then
        echo "WARNING: Estimated output ~$(format_bytes "$est_bytes") but only $(format_bytes "$free_bytes") free on destination." >&2
        printf 'Continue anyway? [y/N] ' >&2
        local reply; read -r reply </dev/tty || reply=n
        [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted." >&2; exit 1; }
    fi
}

# ── Extension filter ──────────────────────────────────────────────────────────
FILTER_EXTS=""   # --only-exts: empty = allow all
SKIP_EXTS=""     # --skip-exts: empty = skip nothing
MIN_PHOTO_BYTES=0  # --min-photo-mb: skip photos smaller than this (0 = process all)
MIN_VIDEO_BYTES=0  # --min-video-mb: skip videos smaller than this (0 = process all)

ext_allowed() {
    local ext="${1,,}"
    local IFS=',' e
    if [[ -n "$SKIP_EXTS" ]]; then
        for e in $SKIP_EXTS; do [[ "${e,,}" == "$ext" ]] && return 1; done
        return 0
    fi
    [[ -z "$FILTER_EXTS" ]] && return 0
    for e in $FILTER_EXTS; do [[ "${e,,}" == "$ext" ]] && return 0; done
    return 1
}

# ── Image tool ────────────────────────────────────────────────────────────────
# Stored as array to avoid word-split issues with paths containing spaces
IMGCMD=()
init_image_tool() {
    if command -v magick >/dev/null 2>&1; then
        IMGCMD=(magick convert)
    elif command -v convert >/dev/null 2>&1 && convert --version 2>&1 | grep -qi imagemagick; then
        IMGCMD=(convert)
    else
        fail "ImageMagick (magick or convert) is required for photo processing."
    fi
}
run_convert() { "${IMGCMD[@]}" "$@"; }

# ── Temp file cleanup ─────────────────────────────────────────────────────────
STATS_DIR=""
cleanup() {
    # Kill any still-running background jobs before exiting
    jobs -rp 2>/dev/null | xargs -r kill 2>/dev/null || true
    [[ -n "$STATS_DIR" ]] && rm -rf "$STATS_DIR"
}
trap cleanup EXIT INT TERM

# ── Parallel pool ─────────────────────────────────────────────────────────────
PARALLEL_JOBS=1
wait_for_slot() {
    while (( $(jobs -rp | wc -l) >= PARALLEL_JOBS )); do
        wait -n 2>/dev/null || sleep 0.05
    done
}

# ── File collection ───────────────────────────────────────────────────────────
# Single find pass — avoids re-reading the directory tree multiple times.
# Sets globals (must be declared local -a by the caller):
#   img_files  img_sizes
#   video_primary  video_primary_sizes   video_other  video_other_sizes
#   skipped_vid  skipped_vid_sizes
#
# Sizes are collected in the same pass, so no separate stat calls are needed.
# with_skipped=1 → populate skipped_vid (videos not re-encoded at this level)
collect_media_files() {
    local dir="$1" with_skipped="${2:-0}"
    local _sz _path _ext

    printf 'Scanning %s ...\n' "$dir"

    while IFS= read -r -d '' _sz && IFS= read -r -d '' _path; do
        _ext="${_path##*.}"; _ext="${_ext,,}"
        ext_allowed "$_ext" || continue
        case "$_ext" in
            jpg|jpeg|png|webp)
                (( MIN_PHOTO_BYTES > 0 && _sz < MIN_PHOTO_BYTES )) && continue
                img_files+=("$_path"); img_sizes+=("$_sz") ;;
            mov)
                (( MIN_VIDEO_BYTES > 0 && _sz < MIN_VIDEO_BYTES )) && continue
                video_primary+=("$_path"); video_primary_sizes+=("$_sz") ;;
            mp4|mkv|avi|m4v|webm|mpg|mpeg)
                (( MIN_VIDEO_BYTES > 0 && _sz < MIN_VIDEO_BYTES )) && continue
                if (( REENCODE_ALL_VIDEO )); then
                    video_other+=("$_path"); video_other_sizes+=("$_sz")
                elif (( with_skipped )); then
                    skipped_vid+=("$_path"); skipped_vid_sizes+=("$_sz")
                fi
                ;;
        esac
    done < <(find "$dir" -type f -printf '%s\0%p\0')
}

# ── Per-file processors ───────────────────────────────────────────────────────

# Optimize JPEG/WEBP in place, convert PNG → JPEG. Replaces only if result is smaller.
# Writes result to $stats_file: "photo|rel|sz_before|sz_after"
optimize_photo() {
    local file="$1" rel="$2" stats_file="$3"
    local ext="${file##*.}"; ext="${ext,,}"
    local dst tmp

    # PNG is converted to JPEG (much smaller for photos); other formats re-encode in place
    if [[ "$ext" == "png" ]]; then
        dst="${file%.*}.jpg"
        tmp="${file%.*}.opt.${BASHPID}.jpg"   # explicit .jpg so ImageMagick outputs JPEG
    else
        dst="$file"
        tmp="${file}.opt.${BASHPID}"
    fi

    local sz_before sz_after
    sz_before=$(stat -c%s -- "$file")

    if run_convert -auto-orient +profile "!exif,*" \
        -resize "${IMG_MAX_DIM}x${IMG_MAX_DIM}>" \
        -quality "$JPEG_QUALITY" "$file" "$tmp" 2>/dev/null; then
        sz_after=$(stat -c%s -- "$tmp" 2>/dev/null || echo 0)
        if (( sz_after > 0 && sz_after < sz_before )); then
            mv "$tmp" "$dst"
            [[ "$file" != "$dst" ]] && rm -f "$file"
            printf 'photo|%s|%d|%d\n' "$rel" "$sz_before" "$sz_after" > "$stats_file"
            return
        fi
    fi
    rm -f "$tmp"
    printf 'photo|%s|%d|%d\n' "$rel" "$sz_before" "$sz_before" > "$stats_file"
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
    local scale="scale='if(gt(iw,${VIDEO_MAX_W}),${VIDEO_MAX_W},iw)':'if(gt(ih,${VIDEO_MAX_H}),${VIDEO_MAX_H},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

    # Suppress per-second stats when multiple videos run in parallel (output would interleave)
    local stats_flag="-stats"
    (( PARALLEL_JOBS > 1 )) && stats_flag="-nostats"

    local sz_before sz_after
    sz_before=$(stat -c%s -- "$file")

    if ffmpeg -hide_banner -loglevel warning $stats_flag -y \
        -i "$file" -vf "$scale" \
        -c:v libx264 -preset "$VIDEO_PRESET" -crf "$VIDEO_CRF" \
        -level:v 5.2 -fps_mode vfr \
        -pix_fmt yuv420p -movflags +faststart \
        -max_muxing_queue_size 4096 \
        -c:a aac -b:a "$AUDIO_BITRATE" "$tmp"; then
        sz_after=$(stat -c%s -- "$tmp" 2>/dev/null || echo 0)
        if (( sz_after > 0 )); then
            mv "$tmp" "$dst"
            [[ "$file" != "$dst" ]] && rm -f "$file"
            printf 'video|%s|%d|%d\n' "$rel" "$sz_before" "$sz_after" > "$stats_file"
            return
        fi
    fi
    rm -f "$tmp"
    printf 'video|%s|%d|%d|fail\n' "$rel" "$sz_before" "$sz_before" > "$stats_file"
}

# ── Top-savings report ────────────────────────────────────────────────────────
print_top_savings() {
    local stats_dir="$1"
    local top=20
    local tmp_all
    tmp_all=$(mktemp)

    cat "$stats_dir"/*.result 2>/dev/null > "$tmp_all" || true
    if [[ ! -s "$tmp_all" ]]; then
        rm -f "$tmp_all"
        return
    fi

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
    local photo_ok=0 photo_before=0 photo_after=0 photo_fail=0
    local video_ok=0 video_before=0 video_after=0 video_fail=0

    while IFS='|' read -r type rel before after rest; do
        case "$type" in
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

    local total_before=$(( photo_before+video_before ))
    local total_after=$(( photo_after+video_after ))
    local total_fail=$(( photo_fail+video_fail ))

    echo
    echo "=== Optimization Summary ==="
    (( photo_ok > 0 || photo_fail > 0 )) && printf '%-8s  %5d files  %12s → %12s  %s\n' \
        "Photos" "$photo_ok" "$(format_bytes "$photo_before")" "$(format_bytes "$photo_after")" "$(format_percent "$photo_before" "$photo_after")"
    (( video_ok > 0 || video_fail > 0 )) && printf '%-8s  %5d files  %12s → %12s  %s\n' \
        "Videos" "$video_ok" "$(format_bytes "$video_before")" "$(format_bytes "$video_after")" "$(format_percent "$video_before" "$video_after")"
    echo "──────────────────────────────────────────────────────────────────"
    printf '%-8s  %5d files  %12s → %12s  %s\n' \
        "Total" "$(( photo_ok+video_ok ))" \
        "$(format_bytes "$total_before")" "$(format_bytes "$total_after")" \
        "$(format_percent "$total_before" "$total_after")"
    printf 'Elapsed : %s\n' "$(format_elapsed "$elapsed")"
    (( total_fail > 0 )) && printf 'Failed  : %d file(s) — originals preserved in copy\n' "$total_fail" >&2
}

# ── Main optimizer (runs on the copy) ─────────────────────────────────────────
run_optimization() {
    local dest="$1"
    local idx

    local -a img_files=() img_sizes=()
    local -a video_primary=() video_primary_sizes=()
    local -a video_other=() video_other_sizes=()
    local -a skipped_vid=() skipped_vid_sizes=()
    collect_media_files "$dest"

    printf 'Found: %d photos, %d videos to process\n' \
        "${#img_files[@]}" "$(( ${#video_primary[@]} + ${#video_other[@]} ))"
    echo

    # Photos
    if (( ${#img_files[@]} > 0 )); then
        printf -- '--- Photos  (quality=%d, max=%dpx) ---\n' "$JPEG_QUALITY" "$IMG_MAX_DIM"
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
        printf -- '--- Videos  (CRF=%d, preset=%s, max %dx%d, audio=%s) ---\n' \
            "$VIDEO_CRF" "$VIDEO_PRESET" "$VIDEO_MAX_W" "$VIDEO_MAX_H" "$AUDIO_BITRATE"
        idx=0
        for file in "${all_videos[@]}"; do
            (( ++idx ))
            local rel="${file#$dest/}"
            local sz; sz=$(stat -c%s -- "$file")
            printf '[%d/%d] %s  (%s)\n' "$idx" "${#all_videos[@]}" "$rel" "$(format_bytes "$sz")"
            local sf="$STATS_DIR/video_${idx}.result"
            wait_for_slot
            local _f="$file" _r="$rel" _sf="$sf"
            { convert_video "$_f" "$_r" "$_sf"; } &
        done
        wait; echo
    fi
}

# ── Dry-run with estimated savings ────────────────────────────────────────────
run_dry_run() {
    local src="$1"
    echo "DRY RUN — no files will be copied or modified."
    echo "Savings estimates are approximate (typical values, actual depends on content)."
    echo

    local -a img_files=() img_sizes=()
    local -a video_primary=() video_primary_sizes=()
    local -a video_other=() video_other_sizes=()
    local -a skipped_vid=() skipped_vid_sizes=()
    collect_media_files "$src" 1
    echo

    # Estimated savings ratios (%) by level.
    local img_ratio vid_ratio other_ratio
    case "$LEVEL" in
        archive)    img_ratio=-5;  vid_ratio=15; other_ratio=0  ;;
        moderate)   img_ratio=12;  vid_ratio=30; other_ratio=0  ;;
        aggressive) img_ratio=22;  vid_ratio=50; other_ratio=35 ;;
        maximum)    img_ratio=35;  vid_ratio=65; other_ratio=55 ;;
    esac

    # Sum sizes from arrays collected during scan — no stat calls needed
    local img_sz=0 vid_sz=0 other_sz=0 skipped_sz=0
    local _s
    for _s in "${img_sizes[@]+"${img_sizes[@]}"}";            do (( img_sz     += _s )); done
    for _s in "${video_primary_sizes[@]+"${video_primary_sizes[@]}"}"; do (( vid_sz += _s )); done
    for _s in "${video_other_sizes[@]+"${video_other_sizes[@]}"}";  do (( other_sz  += _s )); done
    for _s in "${skipped_vid_sizes[@]+"${skipped_vid_sizes[@]}"}";  do (( skipped_sz += _s )); done

    # Compute all estimated sizes in one Python call
    local img_est vid_est other_est
    read -r img_est vid_est other_est < <(python3 - \
        "$img_sz" "$img_ratio" "$vid_sz" "$vid_ratio" "$other_sz" "$other_ratio" <<'PY'
import sys
a = sys.argv[1:]
out = []
for i in range(0, 6, 2):
    total, ratio = int(a[i]), float(a[i+1])
    out.append(str(int(total * (1 - ratio / 100))))
print(' '.join(out))
PY
)

    local total_before=$(( img_sz + vid_sz + other_sz ))
    local total_after=$(( img_est + vid_est + other_est ))

    printf 'Level       : %s\n' "$LEVEL"
    [[ -n "$FILTER_EXTS" ]] && printf 'Only exts   : %s\n' "$FILTER_EXTS"
    [[ -n "$SKIP_EXTS"   ]] && printf 'Skip exts   : %s\n' "$SKIP_EXTS"
    echo
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
        "Total" "$(( ${#img_files[@]} + ${#video_primary[@]} + ${#video_other[@]} ))" \
        "$(format_bytes "$total_before")" "$(format_bytes "$total_after")" \
        "$(format_percent "$total_before" "$total_after")"

    if (( ${#skipped_vid[@]} > 0 )); then
        echo
        printf 'Skipped (not re-encoded at this level): %d MP4/MKV/AVI  ~%s\n' \
            "${#skipped_vid[@]}" "$(format_bytes "$skipped_sz")"
        printf '  → use --level aggressive or maximum to include them\n'
    fi
}

# ── Duplicate management ──────────────────────────────────────────────────────
# Finds duplicate files by MD5 hash.
# Writes to out_file:
#   Line 1:  STATS\t<groups>\t<dup_count>\t<dup_bytes>
#   Lines 2+: paths of redundant files (keep first alphabetically per group)
collect_duplicates() {
    local target="$1" out_file="$2"
    printf 'Scanning for duplicates in %s ...\n' "$target"
    python3 - "$target" >"$out_file" 2>/dev/null <<'PY'
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
}

run_copy_dupes() {
    local target="$1" dest="$2"
    require_command python3

    local tmp_dupes; tmp_dupes=$(mktemp)
    collect_duplicates "$target" "$tmp_dupes"

    local stats_line groups dup_count dup_bytes
    stats_line=$(head -1 "$tmp_dupes")
    IFS=$'\t' read -r _ groups dup_count dup_bytes <<< "$stats_line"

    if [[ -z "$groups" || "$groups" == "0" ]]; then
        rm -f "$tmp_dupes"
        echo "No duplicate files found."
        return
    fi

    printf 'Found: %d groups, %d redundant files (%s)\n' \
        "$groups" "$dup_count" "$(format_bytes "$dup_bytes")"
    echo

    [[ -e "$dest" ]] && fail "Destination '$dest' already exists. Remove it first."
    mkdir -p "$dest"

    local copied=0
    local target_abs; target_abs=$(abs_path "$target")
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local rel="${path#$target_abs/}"
        local dst_path="$dest/$rel"
        mkdir -p "$(dirname "$dst_path")"
        cp -p -- "$path" "$dst_path"
        printf '  [copy]  %s\n' "$rel"
        (( ++copied ))
    done < <(tail -n +2 "$tmp_dupes")

    rm -f "$tmp_dupes"
    echo
    printf 'Copied %d redundant files to: %s\n' "$copied" "$dest"
    echo "Review them manually, then use --delete-dupes to remove from the original."
}

run_delete_dupes() {
    local target="$1"
    require_command python3

    local tmp_dupes; tmp_dupes=$(mktemp)
    collect_duplicates "$target" "$tmp_dupes"

    local stats_line groups dup_count dup_bytes
    stats_line=$(head -1 "$tmp_dupes")
    IFS=$'\t' read -r _ groups dup_count dup_bytes <<< "$stats_line"

    if [[ -z "$groups" || "$groups" == "0" ]]; then
        rm -f "$tmp_dupes"
        echo "No duplicate files found."
        return
    fi

    printf 'Found: %d groups, %d redundant files (%s)\n' \
        "$groups" "$dup_count" "$(format_bytes "$dup_bytes")"
    echo "Files to be deleted:"
    local target_abs; target_abs=$(abs_path "$target")
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local sz; sz=$(stat -c%s -- "$path" 2>/dev/null || echo 0)
        printf '  [del]  %s  (%s)\n' "${path#$target_abs/}" "$(format_bytes "$sz")"
    done < <(tail -n +2 "$tmp_dupes")

    echo
    printf 'Delete %d files and free %s? [y/N] ' "$dup_count" "$(format_bytes "$dup_bytes")"
    local reply; read -r reply </dev/tty || reply=n
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        rm -f "$tmp_dupes"
        echo "Aborted."
        return
    fi

    local deleted=0
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        rm -f -- "$path"
        (( ++deleted ))
    done < <(tail -n +2 "$tmp_dupes")

    rm -f "$tmp_dupes"
    echo
    printf 'Deleted %d files, freed %s.\n' "$deleted" "$(format_bytes "$dup_bytes")"
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    local level="moderate"
    local dry_run=0
    local skip_copy=0
    local log_file=""
    local positional=()
    local ov_jpeg_quality="" ov_img_max_dim=""
    local ov_crf="" ov_preset="" ov_max_w="" ov_max_h="" ov_audio=""
    local ov_min_photo_mb="" ov_min_video_mb=""
    local copy_dupes_dir="" delete_dupes=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)           usage; exit 0 ;;
            --dry-run)           dry_run=1; shift ;;
            --skip-copy)         skip_copy=1; shift ;;
            --copy-dupes)        [[ $# -ge 2 ]] || fail "--copy-dupes requires a directory"; copy_dupes_dir="$2"; shift 2 ;;
            --copy-dupes=*)      copy_dupes_dir="${1#--copy-dupes=}"; shift ;;
            --delete-dupes)      delete_dupes=1; shift ;;
            --level)             [[ $# -ge 2 ]] || fail "--level requires a value"; level="$2"; shift 2 ;;
            --level=*)           level="${1#--level=}"; shift ;;
            --only-exts)         [[ $# -ge 2 ]] || fail "--only-exts requires a value"; FILTER_EXTS="$2"; shift 2 ;;
            --only-exts=*)       FILTER_EXTS="${1#--only-exts=}"; shift ;;
            --skip-exts)         [[ $# -ge 2 ]] || fail "--skip-exts requires a value"; SKIP_EXTS="$2"; shift 2 ;;
            --skip-exts=*)       SKIP_EXTS="${1#--skip-exts=}"; shift ;;
            --jobs)              [[ $# -ge 2 ]] || fail "--jobs requires a value"; PARALLEL_JOBS="$2"; shift 2 ;;
            --jobs=*)            PARALLEL_JOBS="${1#--jobs=}"; shift ;;
            --log)               [[ $# -ge 2 ]] || fail "--log requires a value"; log_file="$2"; shift 2 ;;
            --log=*)             log_file="${1#--log=}"; shift ;;
            --jpeg-quality)      [[ $# -ge 2 ]] || fail "--jpeg-quality requires a value"; ov_jpeg_quality="$2"; shift 2 ;;
            --jpeg-quality=*)    ov_jpeg_quality="${1#--jpeg-quality=}"; shift ;;
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
            --min-photo-mb)      [[ $# -ge 2 ]] || fail "--min-photo-mb requires a value"; ov_min_photo_mb="$2"; shift 2 ;;
            --min-photo-mb=*)    ov_min_photo_mb="${1#--min-photo-mb=}"; shift ;;
            --min-video-mb)      [[ $# -ge 2 ]] || fail "--min-video-mb requires a value"; ov_min_video_mb="$2"; shift 2 ;;
            --min-video-mb=*)    ov_min_video_mb="${1#--min-video-mb=}"; shift ;;
            --)                  shift; positional+=("$@"); break ;;
            -*)                  fail "Unknown option: $1" ;;
            *)                   positional+=("$1"); shift ;;
        esac
    done

    [[ ${#positional[@]} -ge 1 ]] || { usage; exit 1; }

    # ── Duplicate management mode (mutually exclusive with optimization) ────────
    if [[ -n "$copy_dupes_dir" || "$delete_dupes" -eq 1 ]]; then
        local target_abs; target_abs=$(abs_path "${positional[0]}")
        [[ -d "$target_abs" ]] || fail "Directory '$target_abs' does not exist"
        if [[ -n "$log_file" ]]; then
            exec > >(tee -a "$log_file") 2>&1
            echo "Logging to: $log_file"
        fi
        echo "============================================"
        printf 'Directory : %s\n' "$target_abs"
        echo "============================================"
        echo
        if [[ -n "$copy_dupes_dir" ]]; then
            local dupes_abs; dupes_abs=$(abs_path "$copy_dupes_dir")
            run_copy_dupes "$target_abs" "$dupes_abs"
            echo
        fi
        if (( delete_dupes )); then
            run_delete_dupes "$target_abs"
        fi
        exit 0
    fi

    [[ -n "$FILTER_EXTS" && -n "$SKIP_EXTS" ]] && fail "--only-exts and --skip-exts are mutually exclusive"
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
            JPEG_QUALITY=$ARC_JPEG_QUALITY  IMG_MAX_DIM=$ARC_IMG_MAX_DIM
            VIDEO_CRF=$ARC_VIDEO_CRF        VIDEO_PRESET=$ARC_VIDEO_PRESET
            VIDEO_MAX_W=$ARC_VIDEO_MAX_W    VIDEO_MAX_H=$ARC_VIDEO_MAX_H
            AUDIO_BITRATE=$ARC_AUDIO_BITRATE REENCODE_ALL_VIDEO=$ARC_REENCODE_ALL_VIDEO ;;
        moderate)
            JPEG_QUALITY=$MOD_JPEG_QUALITY  IMG_MAX_DIM=$MOD_IMG_MAX_DIM
            VIDEO_CRF=$MOD_VIDEO_CRF        VIDEO_PRESET=$MOD_VIDEO_PRESET
            VIDEO_MAX_W=$MOD_VIDEO_MAX_W    VIDEO_MAX_H=$MOD_VIDEO_MAX_H
            AUDIO_BITRATE=$MOD_AUDIO_BITRATE REENCODE_ALL_VIDEO=$MOD_REENCODE_ALL_VIDEO ;;
        aggressive)
            JPEG_QUALITY=$AGG_JPEG_QUALITY  IMG_MAX_DIM=$AGG_IMG_MAX_DIM
            VIDEO_CRF=$AGG_VIDEO_CRF        VIDEO_PRESET=$AGG_VIDEO_PRESET
            VIDEO_MAX_W=$AGG_VIDEO_MAX_W    VIDEO_MAX_H=$AGG_VIDEO_MAX_H
            AUDIO_BITRATE=$AGG_AUDIO_BITRATE REENCODE_ALL_VIDEO=$AGG_REENCODE_ALL_VIDEO ;;
        maximum)
            JPEG_QUALITY=$MAX_JPEG_QUALITY  IMG_MAX_DIM=$MAX_IMG_MAX_DIM
            VIDEO_CRF=$MAX_VIDEO_CRF        VIDEO_PRESET=$MAX_VIDEO_PRESET
            VIDEO_MAX_W=$MAX_VIDEO_MAX_W    VIDEO_MAX_H=$MAX_VIDEO_MAX_H
            AUDIO_BITRATE=$MAX_AUDIO_BITRATE REENCODE_ALL_VIDEO=$MAX_REENCODE_ALL_VIDEO ;;
    esac

    # Apply individual overrides
    [[ -n "$ov_jpeg_quality" ]] && JPEG_QUALITY="$ov_jpeg_quality"
    [[ -n "$ov_img_max_dim"  ]] && IMG_MAX_DIM="$ov_img_max_dim"
    [[ -n "$ov_crf"          ]] && VIDEO_CRF="$ov_crf"
    [[ -n "$ov_preset"       ]] && VIDEO_PRESET="$ov_preset"
    [[ -n "$ov_max_w"        ]] && VIDEO_MAX_W="$ov_max_w"
    [[ -n "$ov_max_h"        ]] && VIDEO_MAX_H="$ov_max_h"
    [[ -n "$ov_audio"        ]] && AUDIO_BITRATE="$ov_audio"
    if [[ -n "$ov_min_photo_mb" ]]; then
        [[ "$ov_min_photo_mb" =~ ^[0-9]+$ ]] || fail "--min-photo-mb must be an integer"
        MIN_PHOTO_BYTES=$(( ov_min_photo_mb * 1024 * 1024 ))
    fi
    if [[ -n "$ov_min_video_mb" ]]; then
        [[ "$ov_min_video_mb" =~ ^[0-9]+$ ]] || fail "--min-video-mb must be an integer"
        MIN_VIDEO_BYTES=$(( ov_min_video_mb * 1024 * 1024 ))
    fi

    # Validate
    [[ "$JPEG_QUALITY"    =~ ^[0-9]+$ ]] || fail "--jpeg-quality must be an integer"
    [[ "$IMG_MAX_DIM"     =~ ^[0-9]+$ ]] || fail "--max-image-dim must be an integer"
    [[ "$VIDEO_CRF"       =~ ^[0-9]+$ ]] || fail "--crf must be an integer"
    [[ "$VIDEO_MAX_W"     =~ ^[0-9]+$ ]] || fail "--max-width must be an integer"
    [[ "$VIDEO_MAX_H"     =~ ^[0-9]+$ ]] || fail "--max-height must be an integer"
    [[ "$AUDIO_BITRATE"   =~ ^[0-9]+[kKmM]?$ ]] || fail "--audio-bitrate must be like 192k"
    case "$VIDEO_PRESET" in
        ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
        *) fail "--preset must be: ultrafast superfast veryfast faster fast medium slow slower veryslow" ;;
    esac

    local source_dir dest_dir
    if (( skip_copy )) && [[ ${#positional[@]} -eq 1 ]]; then
        # --skip-copy with one arg: that arg IS the directory to optimize in-place
        source_dir="${positional[0]}"
        dest_dir="${positional[0]}"
    else
        source_dir="${positional[0]}"
        dest_dir="${positional[1]:-}"
        [[ -z "$dest_dir" ]] && dest_dir="${source_dir%/}_${level}"
    fi
    [[ -d "$source_dir" ]] || fail "Source directory '$source_dir' does not exist"

    require_command python3

    if [[ -n "$log_file" ]]; then
        exec > >(tee -a "$log_file") 2>&1
        echo "Logging to: $log_file"
    fi

    local src_abs dest_abs
    src_abs="$(abs_path "$source_dir")"
    dest_abs="$(abs_path "$dest_dir")"

    if (( ! skip_copy )); then
        require_command rsync
        [[ -e "$dest_abs"              ]] && fail "Destination '$dest_abs' already exists. Delete it or use --skip-copy."
        [[ "$dest_abs" == "$src_abs"   ]] && fail "Destination must differ from source."
        [[ "$dest_abs" == "$src_abs"/* ]] && fail "Destination may not be inside source."
        [[ "$src_abs"  == "$dest_abs"/* ]] && fail "Source may not be inside destination."
    else
        [[ -d "$dest_abs" ]] || fail "--skip-copy: destination '$dest_abs' does not exist"
    fi

    echo "============================================"
    if (( skip_copy )); then
        printf 'Directory   : %s\n' "$dest_abs"
    else
        printf 'Source      : %s\n' "$src_abs"
        printf 'Destination : %s\n' "$dest_abs"
    fi
    printf 'Level       : %s\n' "$level"
    [[ -n "$FILTER_EXTS" ]] && printf 'Only exts   : %s\n' "$FILTER_EXTS"
    [[ -n "$SKIP_EXTS"   ]] && printf 'Skip exts   : %s\n' "$SKIP_EXTS"
    (( MIN_PHOTO_BYTES > 0 )) && printf 'Min photo   : %d MB (skip smaller)\n' "$(( MIN_PHOTO_BYTES / 1024 / 1024 ))"
    (( MIN_VIDEO_BYTES > 0 )) && printf 'Min video   : %d MB (skip smaller)\n' "$(( MIN_VIDEO_BYTES / 1024 / 1024 ))"
    printf 'Settings    : JPEG/PNG %d  max-dim %dpx  CRF %d  preset %s  %dx%d  audio %s\n' \
        "$JPEG_QUALITY" "$IMG_MAX_DIM" \
        "$VIDEO_CRF" "$VIDEO_PRESET" "$VIDEO_MAX_W" "$VIDEO_MAX_H" "$AUDIO_BITRATE"
    echo "============================================"
    echo

    if [[ "$dry_run" -eq 1 ]]; then
        run_dry_run "$src_abs"
        exit 0
    fi

    if (( ! skip_copy )); then
        check_free_space "$src_abs" "$(dirname "$dest_abs")" "$level"
    fi
    init_image_tool
    require_command ffmpeg

    STATS_DIR=$(mktemp -d)
    local START_TIME=$SECONDS

    if (( ! skip_copy )); then
        echo "Step 1/2: Copying '$src_abs' → '$dest_abs' ..."
        mkdir -p "$dest_abs"
        rsync -a --info=progress2 --human-readable "$src_abs"/ "$dest_abs"/
        echo
        echo "Step 2/2: Optimizing copy ..."
    else
        echo "Skipping copy (--skip-copy). Optimizing '$dest_abs' in place ..."
    fi
    echo
    run_optimization "$dest_abs"

    local elapsed=$(( SECONDS - START_TIME ))
    print_summary "$STATS_DIR" "$elapsed"
    print_top_savings "$STATS_DIR"

    echo
    echo "Done."
    echo "  Optimized copy : $dest_abs"
    (( ! skip_copy )) && echo "  Original       : $src_abs  (untouched)"

    # Final folder statistics
    local stats_script
    stats_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../statistics/folder_stats.sh"
    if [[ -x "$stats_script" ]]; then
        if (( ! skip_copy )); then
            echo
            echo "============================================"
            echo "Folder stats: original"
            echo "============================================"
            "$stats_script" "$src_abs"
            echo
            echo "============================================"
            echo "Folder stats: optimized copy"
            echo "============================================"
            "$stats_script" "$dest_abs"
        else
            echo
            echo "============================================"
            echo "Folder stats"
            echo "============================================"
            "$stats_script" "$dest_abs"
        fi
    fi
}

main "$@"
