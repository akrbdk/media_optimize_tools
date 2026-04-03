#!/usr/bin/env bash

# optimize_backup.sh — safe backup optimizer (copy first, then optimize the copy)
#
# Creates an optimized copy of SOURCE_DIR. Originals are never touched.
# Supports two optimization levels so you can choose between safety and savings.
#
# Level "moderate" (default) — barely noticeable quality loss, safe for archives:
#   Photos : JPEG quality 88, strip EXIF, resize only if > 8000 px
#   PNG    : lossless, strip EXIF (compression 7)
#   WEBP   : quality 85, strip
#   HEIC   : convert to JPEG quality 88  (huge savings, always done)
#   MOV    : convert to MP4 H.264 CRF 23, max 4K  (compatibility + savings)
#   MP4/MKV: skip re-encoding  (too risky without knowing original quality)
#
# Level "aggressive" — visible savings, still perfectly usable:
#   Photos : JPEG quality 80, resize to max 3840 px
#   PNG    : lossless, compression 9
#   WEBP   : quality 75
#   HEIC   : convert to JPEG quality 80
#   MOV    : convert to MP4 H.264 CRF 26, max 1080p
#   MP4/MKV/AVI: re-encode CRF 26, max 1080p  (big savings, some quality loss)
#
# Safety: each file is processed into a temp file first; the copy is only updated
# on success. If anything fails the original copy stays untouched.

set -euo pipefail

# ── Level presets ────────────────────────────────────────────────────────────
MODERATE_JPEG_QUALITY=88
MODERATE_WEBP_QUALITY=85
MODERATE_PNG_COMPRESSION=7
MODERATE_IMG_MAX_DIM=8000
MODERATE_VIDEO_CRF=23
MODERATE_VIDEO_PRESET="medium"
MODERATE_VIDEO_MAX_W=3840
MODERATE_VIDEO_MAX_H=2160
MODERATE_REENCODE_ALL_VIDEO=0   # only MOV and other non-MP4

AGGRESSIVE_JPEG_QUALITY=80
AGGRESSIVE_WEBP_QUALITY=75
AGGRESSIVE_PNG_COMPRESSION=9
AGGRESSIVE_IMG_MAX_DIM=3840
AGGRESSIVE_VIDEO_CRF=26
AGGRESSIVE_VIDEO_PRESET="medium"
AGGRESSIVE_VIDEO_MAX_W=1920
AGGRESSIVE_VIDEO_MAX_H=1080
AGGRESSIVE_REENCODE_ALL_VIDEO=1  # re-encode MP4/MKV/AVI too

# ── Helpers ──────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: optimize_backup.sh [OPTIONS] SOURCE_DIR [DESTINATION_DIR]

Creates an optimized copy of SOURCE_DIR. SOURCE_DIR is never modified.
Default destination: SOURCE_DIR_optimized

Options:
  --level moderate|aggressive   Optimization strength (default: moderate)
  --dry-run                     Show what would be done, make no changes
  --log FILE                    Append all output to FILE in addition to terminal
  --jobs N                      Parallel image workers (default: 1)
  -h, --help                    Show this help

Level comparison:
  moderate   — safe quality, HEIC→JPEG, MOV→MP4, skip existing MP4/MKV
  aggressive — max savings, all videos re-encoded to 1080p CRF 26

Examples:
  optimize_backup.sh /media/usb/Photos
  optimize_backup.sh --level aggressive /media/usb/Backup /media/usb/Backup_opt
  optimize_backup.sh --dry-run --level aggressive /media/usb/Photos
  optimize_backup.sh --level moderate --log ~/opt.log /media/usb/Photos
EOF
}

fail() { echo "Error: $*" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but was not found. Install it and retry."
}

abs_path() {
    python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

format_bytes() {
    python3 - "$1" <<'PY'
import sys
value = int(sys.argv[1])
sign = "-" if value < 0 else ""
value = abs(value)
units = ["B","KB","MB","GB","TB"]
v = float(value)
for unit in units:
    if v < 1024 or unit == units[-1]:
        print(f"{sign}{int(v)} {unit}" if unit == "B" else f"{sign}{v:.1f} {unit}")
        break
    v /= 1024
PY
}

format_percent() {
    python3 - "$1" "$2" <<'PY'
import sys
before, after = int(sys.argv[1]), int(sys.argv[2])
if before == 0:
    print("n/a")
else:
    print(f"{(before - after) / before * 100:+.1f}%")
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
        echo "WARNING: Source needs ~$(format_bytes "$src_bytes") but only $(format_bytes "$free_bytes") free on destination." >&2
        printf 'Continue anyway? [y/N] ' >&2
        local reply; read -r reply </dev/tty || reply=n
        [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted." >&2; exit 1; }
    fi
}

# ── Image tool detection ─────────────────────────────────────────────────────
IMGCMD=""
init_image_tool() {
    if command -v magick >/dev/null 2>&1; then
        IMGCMD="magick convert"
    elif command -v convert >/dev/null 2>&1 && convert --version 2>&1 | grep -qi imagemagick; then
        IMGCMD="convert"
    else
        fail "ImageMagick (magick or convert) is required for photo optimization."
    fi
}

run_convert() { $IMGCMD "$@"; }

# ── Temp file cleanup ────────────────────────────────────────────────────────
CURRENT_TEMP=""
cleanup() { [[ -n "$CURRENT_TEMP" ]] && rm -f "$CURRENT_TEMP"; }
trap cleanup EXIT INT TERM

# ── Per-file processors ──────────────────────────────────────────────────────

# Optimize JPEG/WEBP/PNG in-place inside the copy.
# Only replaces the file if the result is smaller.
optimize_image() {
    local file="$1" quality="$2" max_dim="$3" png_comp="$4"
    local ext="${file##*.}"; ext="${ext,,}"
    local tmp="${file}.opt.$$"
    CURRENT_TEMP="$tmp"

    local extra_args=()
    case "$ext" in
        jpg|jpeg|heic|heif)
            extra_args=(-quality "$quality") ;;
        webp)
            extra_args=(-quality "$quality") ;;
        png)
            extra_args=(-define "png:compression-level=${png_comp}" -define png:exclude-chunk=all) ;;
    esac

    run_convert \
        -auto-orient -strip \
        -resize "${max_dim}x${max_dim}>" \
        "${extra_args[@]}" \
        "$file" "$tmp" 2>/dev/null

    local sz_before sz_after
    sz_before=$(stat -c%s -- "$file")
    sz_after=$(stat -c%s -- "$tmp" 2>/dev/null || echo 0)

    if (( sz_after > 0 && sz_after < sz_before )); then
        mv "$tmp" "$file"
        CURRENT_TEMP=""
        echo "$sz_before $sz_after"
    else
        rm -f "$tmp"
        CURRENT_TEMP=""
        echo "$sz_before $sz_before"   # no improvement, keep original
    fi
}

# Convert HEIC/HEIF → JPEG. Returns "sz_before sz_after new_path" or "failed".
convert_heic() {
    local file="$1" quality="$2"
    local dst="${file%.*}.jpg"
    local tmp="${dst}.opt.$$"
    CURRENT_TEMP="$tmp"

    # If a .jpg already exists at that path, skip to avoid overwriting
    if [[ -f "$dst" ]]; then
        CURRENT_TEMP=""
        echo "skip"
        return
    fi

    if run_convert -auto-orient -strip -quality "$quality" "$file" "$tmp" 2>/dev/null; then
        local sz_before sz_after
        sz_before=$(stat -c%s -- "$file")
        sz_after=$(stat -c%s -- "$tmp" 2>/dev/null || echo 0)
        if (( sz_after > 0 )); then
            mv "$tmp" "$dst"
            rm -f "$file"
            CURRENT_TEMP=""
            echo "$sz_before $sz_after $dst"
            return
        fi
    fi

    rm -f "$tmp"
    CURRENT_TEMP=""
    echo "failed"
}

# Convert video to MP4 in the copy. Handles format conversion with file rename.
convert_video() {
    local file="$1" crf="$2" preset="$3" max_w="$4" max_h="$5"
    local dst="${file%.*}.mp4"
    local tmp="${dst}.opt.$$.mp4"
    CURRENT_TEMP="$tmp"

    # If source is already .mp4 optimize in-place (same path)
    local ext="${file##*.}"; ext="${ext,,}"
    if [[ "$ext" == "mp4" ]]; then
        dst="$file"
        tmp="${file}.opt.$$.mp4"
        CURRENT_TEMP="$tmp"
    fi

    local scale="scale='if(gt(iw,${max_w}),${max_w},iw)':'if(gt(ih,${max_h}),${max_h},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

    if ffmpeg -hide_banner -loglevel warning -stats -y \
        -i "$file" \
        -vf "$scale" \
        -c:v libx264 -preset "$preset" -crf "$crf" \
        -pix_fmt yuv420p -movflags +faststart \
        -c:a aac -b:a 192k \
        "$tmp" 2>/dev/null; then

        local sz_before sz_after
        sz_before=$(stat -c%s -- "$file")
        sz_after=$(stat -c%s -- "$tmp" 2>/dev/null || echo 0)

        if (( sz_after > 0 )); then
            mv "$tmp" "$dst"
            # Remove source only if we renamed (non-mp4 → mp4)
            [[ "$file" != "$dst" ]] && rm -f "$file"
            CURRENT_TEMP=""
            echo "$sz_before $sz_after $dst"
            return
        fi
    fi

    rm -f "$tmp"
    CURRENT_TEMP=""
    echo "failed"
}

# ── Parallel job pool ────────────────────────────────────────────────────────
PARALLEL_JOBS=1
wait_for_slot() {
    while (( $(jobs -rp | wc -l) >= PARALLEL_JOBS )); do
        wait -n 2>/dev/null || sleep 0.05
    done
}

# ── Main optimizer (runs on the copy) ───────────────────────────────────────
run_optimization() {
    local dest="$1"

    # ── Gather files ────────────────────────────────────────────────────────
    local -a img_files=() heic_files=() video_primary=() video_other=()

    mapfile -d '' -t img_files < <(find "$dest" -type f \(
        -iname '*.jpg' -o -iname '*.jpeg' -o
        -iname '*.png' -o -iname '*.webp' \) -print0)

    mapfile -d '' -t heic_files < <(find "$dest" -type f \(
        -iname '*.heic' -o -iname '*.heif' \) -print0)

    mapfile -d '' -t video_primary < <(find "$dest" -type f -iname '*.mov' -print0)

    if (( REENCODE_ALL_VIDEO )); then
        mapfile -d '' -t video_other < <(find "$dest" -type f \(
            -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o
            -iname '*.m4v' -o -iname '*.webm' -o -iname '*.mpg' -o
            -iname '*.mpeg' \) -print0)
    fi

    local total_img="${#img_files[@]}"
    local total_heic="${#heic_files[@]}"
    local total_vid=$(( ${#video_primary[@]} + ${#video_other[@]} ))

    echo "  Found: $total_img photos, $total_heic HEIC files, $total_vid videos"
    echo

    # Counters
    local img_ok=0 img_skip=0 img_fail=0
    local heic_ok=0 heic_skip=0 heic_fail=0
    local vid_ok=0 vid_fail=0
    local img_before=0 img_after=0
    local heic_before=0 heic_after=0
    local vid_before=0 vid_after=0

    # ── HEIC → JPEG ─────────────────────────────────────────────────────────
    if (( total_heic > 0 )); then
        echo "--- Converting HEIC/HEIF → JPEG (quality=$JPEG_QUALITY) ---"
        local idx=0
        for file in "${heic_files[@]}"; do
            (( ++idx ))
            local rel="${file#$dest/}"
            printf '[%d/%d] %s\n' "$idx" "$total_heic" "$rel"

            result=$(convert_heic "$file" "$JPEG_QUALITY")
            case "$result" in
                skip)
                    echo "  SKIP: .jpg already exists"
                    (( ++heic_skip )) ;;
                failed)
                    echo "  FAILED" >&2
                    (( ++heic_fail )) ;;
                *)
                    read -r sb sa _ <<< "$result"
                    echo "  $(format_bytes "$sb") → $(format_bytes "$sa")"
                    heic_before=$(( heic_before + sb ))
                    heic_after=$(( heic_after + sa ))
                    (( ++heic_ok )) ;;
            esac
        done
        echo
    fi

    # ── Regular photo optimization ───────────────────────────────────────────
    if (( total_img > 0 )); then
        echo "--- Optimizing photos (quality=$JPEG_QUALITY, max=${IMG_MAX_DIM}px) ---"
        local RESULTS_DIR
        RESULTS_DIR=$(mktemp -d)

        local idx=0
        for file in "${img_files[@]}"; do
            (( ++idx ))
            local rel="${file#$dest/}"
            printf '[%d/%d] %s\n' "$idx" "$total_img" "$rel"

            wait_for_slot
            local _file="$file" _idx="$idx" _rdir="$RESULTS_DIR"
            {
                result=$(optimize_image "$_file" "$JPEG_QUALITY" "$IMG_MAX_DIM" "$PNG_COMPRESSION")
                echo "$result" > "$_rdir/$_idx"
            } &
        done
        wait

        for rfile in "$RESULTS_DIR"/*; do
            [[ -f "$rfile" ]] || continue
            read -r sb sa < "$rfile"
            if (( sb > 0 )); then
                img_before=$(( img_before + sb ))
                img_after=$(( img_after + sa ))
                (( ++img_ok ))
            else
                (( ++img_fail ))
            fi
        done
        rm -rf "$RESULTS_DIR"
        echo
    fi

    # ── Video conversion ─────────────────────────────────────────────────────
    local all_videos=("${video_primary[@]}" "${video_other[@]}")
    local total_all_vid="${#all_videos[@]}"
    if (( total_all_vid > 0 )); then
        echo "--- Converting videos (CRF=$VIDEO_CRF, preset=$VIDEO_PRESET, max ${VIDEO_MAX_W}x${VIDEO_MAX_H}) ---"
        local idx=0
        for file in "${all_videos[@]}"; do
            (( ++idx ))
            local rel="${file#$dest/}"
            local sz_before
            sz_before=$(stat -c%s -- "$file")
            printf '[%d/%d] %s  (%s)\n' "$idx" "$total_all_vid" "$rel" "$(format_bytes "$sz_before")"

            result=$(convert_video "$file" "$VIDEO_CRF" "$VIDEO_PRESET" "$VIDEO_MAX_W" "$VIDEO_MAX_H")
            case "$result" in
                failed)
                    echo "  FAILED" >&2
                    (( ++vid_fail )) ;;
                *)
                    read -r sb sa _ <<< "$result"
                    echo "  $(format_bytes "$sb") → $(format_bytes "$sa")  ($(format_percent "$sb" "$sa"))"
                    vid_before=$(( vid_before + sb ))
                    vid_after=$(( vid_after + sa ))
                    (( ++vid_ok )) ;;
            esac
        done
        echo
    fi

    # ── Summary ──────────────────────────────────────────────────────────────
    echo "=== Optimization Summary ==="
    printf '%-8s  %5s files  %12s → %12s  %s\n' \
        "HEIC"   "$heic_ok" \
        "$(format_bytes "$heic_before")" "$(format_bytes "$heic_after")" \
        "$(format_percent "$heic_before" "$heic_after")"
    printf '%-8s  %5s files  %12s → %12s  %s\n' \
        "Photos"  "$img_ok" \
        "$(format_bytes "$img_before")" "$(format_bytes "$img_after")" \
        "$(format_percent "$img_before" "$img_after")"
    printf '%-8s  %5s files  %12s → %12s  %s\n' \
        "Videos"  "$vid_ok" \
        "$(format_bytes "$vid_before")" "$(format_bytes "$vid_after")" \
        "$(format_percent "$vid_before" "$vid_after")"

    local total_before=$(( heic_before + img_before + vid_before ))
    local total_after=$(( heic_after + img_after + vid_after ))
    echo "─────────────────────────────────────────────────────────────────"
    printf '%-8s  %5s files  %12s → %12s  %s\n' \
        "Total" "$(( heic_ok + img_ok + vid_ok ))" \
        "$(format_bytes "$total_before")" "$(format_bytes "$total_after")" \
        "$(format_percent "$total_before" "$total_after")"

    if (( heic_fail + img_fail + vid_fail > 0 )); then
        echo
        echo "WARNING: $((heic_fail + img_fail + vid_fail)) file(s) failed — originals preserved in copy." >&2
    fi
}

# ── Dry-run: show what would happen ─────────────────────────────────────────
run_dry_run() {
    local src="$1"
    echo "DRY RUN — no files will be copied or modified."
    echo

    local -a img_files heic_files video_primary video_other
    mapfile -d '' -t img_files   < <(find "$src" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0)
    mapfile -d '' -t heic_files  < <(find "$src" -type f \( -iname '*.heic' -o -iname '*.heif' \) -print0)
    mapfile -d '' -t video_primary < <(find "$src" -type f -iname '*.mov' -print0)
    if (( REENCODE_ALL_VIDEO )); then
        mapfile -d '' -t video_other < <(find "$src" -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.m4v' -o -iname '*.webm' -o -iname '*.mpg' -o -iname '*.mpeg' \) -print0)
    else
        video_other=()
    fi

    local total_size=0
    local count_img="${#img_files[@]}"
    local count_heic="${#heic_files[@]}"
    local count_vid=$(( ${#video_primary[@]} + ${#video_other[@]} ))

    for f in "${heic_files[@]}"; do total_size=$(( total_size + $(stat -c%s -- "$f") )); done
    for f in "${img_files[@]}";  do total_size=$(( total_size + $(stat -c%s -- "$f") )); done
    for f in "${video_primary[@]}" "${video_other[@]}"; do total_size=$(( total_size + $(stat -c%s -- "$f") )); done

    printf 'Level      : %s\n' "$LEVEL"
    printf 'HEIC/HEIF  : %d files  → would convert to JPEG (quality %d)\n' "$count_heic" "$JPEG_QUALITY"
    printf 'Photos     : %d files  → would optimize (quality %d, max %dpx)\n' "$count_img" "$JPEG_QUALITY" "$IMG_MAX_DIM"
    printf 'Videos     : %d files  → would convert to MP4 (CRF %d, %s, max %dx%d)\n' \
        "$count_vid" "$VIDEO_CRF" "$VIDEO_PRESET" "$VIDEO_MAX_W" "$VIDEO_MAX_H"
    printf 'Total size : %s\n' "$(format_bytes "$total_size")"
    echo
    if (( ! REENCODE_ALL_VIDEO )); then
        local skipped_mp4
        mapfile -d '' -t skipped_mp4 < <(find "$src" -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' \) -print0)
        if (( ${#skipped_mp4[@]} > 0 )); then
            printf 'Skipped    : %d existing MP4/MKV/AVI (use --level aggressive to re-encode)\n' "${#skipped_mp4[@]}"
        fi
    fi
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    local level="moderate"
    local dry_run=0
    local log_file=""
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)   usage; exit 0 ;;
            --dry-run)   dry_run=1; shift ;;
            --level)     [[ $# -ge 2 ]] || fail "--level requires a value"; level="$2"; shift 2 ;;
            --level=*)   level="${1#--level=}"; shift ;;
            --jobs)      [[ $# -ge 2 ]] || fail "--jobs requires a value"; PARALLEL_JOBS="$2"; shift 2 ;;
            --jobs=*)    PARALLEL_JOBS="${1#--jobs=}"; shift ;;
            --log)       [[ $# -ge 2 ]] || fail "--log requires a value"; log_file="$2"; shift 2 ;;
            --log=*)     log_file="${1#--log=}"; shift ;;
            --)          shift; positional+=("$@"); break ;;
            -*)          fail "Unknown option: $1" ;;
            *)           positional+=("$1"); shift ;;
        esac
    done

    [[ ${#positional[@]} -ge 1 ]] || { usage; exit 1; }
    [[ "$level" == "moderate" || "$level" == "aggressive" ]] \
        || fail "--level must be 'moderate' or 'aggressive'"
    [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ && "$PARALLEL_JOBS" -ge 1 ]] \
        || fail "--jobs must be a positive integer"

    # Apply level presets
    LEVEL="$level"
    if [[ "$level" == "moderate" ]]; then
        JPEG_QUALITY=$MODERATE_JPEG_QUALITY
        WEBP_QUALITY=$MODERATE_WEBP_QUALITY
        PNG_COMPRESSION=$MODERATE_PNG_COMPRESSION
        IMG_MAX_DIM=$MODERATE_IMG_MAX_DIM
        VIDEO_CRF=$MODERATE_VIDEO_CRF
        VIDEO_PRESET=$MODERATE_VIDEO_PRESET
        VIDEO_MAX_W=$MODERATE_VIDEO_MAX_W
        VIDEO_MAX_H=$MODERATE_VIDEO_MAX_H
        REENCODE_ALL_VIDEO=$MODERATE_REENCODE_ALL_VIDEO
    else
        JPEG_QUALITY=$AGGRESSIVE_JPEG_QUALITY
        WEBP_QUALITY=$AGGRESSIVE_WEBP_QUALITY
        PNG_COMPRESSION=$AGGRESSIVE_PNG_COMPRESSION
        IMG_MAX_DIM=$AGGRESSIVE_IMG_MAX_DIM
        VIDEO_CRF=$AGGRESSIVE_VIDEO_CRF
        VIDEO_PRESET=$AGGRESSIVE_VIDEO_PRESET
        VIDEO_MAX_W=$AGGRESSIVE_VIDEO_MAX_W
        VIDEO_MAX_H=$AGGRESSIVE_VIDEO_MAX_H
        REENCODE_ALL_VIDEO=$AGGRESSIVE_REENCODE_ALL_VIDEO
    fi

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

    [[ -e "$dest_abs" ]] && fail "Destination '$dest_abs' already exists. Delete it or choose another path."
    [[ "$dest_abs" == "$src_abs" ]]    && fail "Destination must differ from source."
    [[ "$dest_abs" == "$src_abs"/* ]]  && fail "Destination may not be inside source."
    [[ "$src_abs"  == "$dest_abs"/* ]] && fail "Source may not be inside destination."

    echo "============================================"
    printf 'Source      : %s\n' "$src_abs"
    printf 'Destination : %s\n' "$dest_abs"
    printf 'Level       : %s\n' "$level"
    echo "============================================"
    echo

    if [[ "$dry_run" -eq 1 ]]; then
        run_dry_run "$src_abs"
        exit 0
    fi

    check_free_space "$src_abs" "$(dirname "$dest_abs")"

    init_image_tool
    require_command ffmpeg

    local START_TIME=$SECONDS

    echo "Step 1/2: Copying '$src_abs' → '$dest_abs' ..."
    mkdir -p "$dest_abs"
    rsync -a --info=progress2 --human-readable "$src_abs"/ "$dest_abs"/
    echo

    echo "Step 2/2: Optimizing copy ..."
    echo
    run_optimization "$dest_abs"

    local elapsed=$(( SECONDS - START_TIME ))
    echo
    echo "Disk usage (du -sh):"
    du -sh "$src_abs" "$dest_abs"
    echo
    printf 'Elapsed : %s\n' "$(format_elapsed "$elapsed")"
    echo
    echo "Done. Optimized copy at: $dest_abs"
    echo "Original untouched at : $src_abs"
}

main "$@"
