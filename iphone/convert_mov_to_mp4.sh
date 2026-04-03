#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_VIDEO_CRF="${MOV_VIDEO_CRF:-23}"
readonly DEFAULT_VIDEO_PRESET="${MOV_VIDEO_PRESET:-medium}"
readonly DEFAULT_AUDIO_BITRATE="${MOV_AUDIO_BITRATE:-192k}"
readonly DEFAULT_MAX_WIDTH="${MOV_MAX_WIDTH:-3840}"
readonly DEFAULT_MAX_HEIGHT="${MOV_MAX_HEIGHT:-2160}"
readonly DEFAULT_PARALLEL_JOBS="${MOV_JOBS:-1}"

usage() {
    cat <<'EOF'
Usage: convert_mov_to_mp4.sh [OPTIONS] SOURCE_DIR [OUTPUT_DIR]

Recursively finds all MOV files in SOURCE_DIR and converts them to MP4
(H.264 video + AAC audio) — a format that plays everywhere.

By default, converted files are placed next to the originals (same directory)
with a .mp4 extension. Original files are kept unless --replace is used.
If OUTPUT_DIR is given, the directory tree is mirrored there.

Options:
  --replace        Remove each original MOV file after successful conversion
  --dry-run        Show what would be converted without doing anything
  --jobs N         Convert N files in parallel (default: 1, override: MOV_JOBS)
                   Warning: parallel mode shows interleaved ffmpeg progress
  --crf N          Video quality: 0 (lossless) – 51 (worst). Default: 23.
                   Lower = better quality + larger file. 18–28 is a good range.
                   Override: MOV_VIDEO_CRF
  --preset NAME    ffmpeg encoding preset (ultrafast/fast/medium/slow/veryslow).
                   Default: medium. Slower = smaller file at same quality.
                   Override: MOV_VIDEO_PRESET
  --audio-bitrate  AAC audio bitrate, e.g. 128k, 192k, 256k. Default: 192k.
                   Override: MOV_AUDIO_BITRATE
  --max-width N    Downscale if wider than N pixels (default: 3840). Override: MOV_MAX_WIDTH
  --max-height N   Downscale if taller than N pixels (default: 2160). Override: MOV_MAX_HEIGHT
  --log FILE       Append all output to FILE in addition to the terminal
  -h, --help       Show this help

Requirements: ffmpeg
              Install on Ubuntu/Debian: sudo apt install ffmpeg
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

format_bytes() {
    python3 - "$1" <<'PY'
import sys
value = abs(int(sys.argv[1]))
units = ["B", "KB", "MB", "GB", "TB"]
v = float(value)
for unit in units:
    if v < 1024 or unit == units[-1]:
        print(f"{int(v)} {unit}" if unit == "B" else f"{v:.1f} {unit}")
        break
    v /= 1024
PY
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

check_free_space() {
    local src="$1"
    local dest_parent="$2"
    local src_bytes free_bytes
    src_bytes=$(du -sb "$src" 2>/dev/null | cut -f1) || return 0
    free_bytes=$(df -B1 --output=avail "$dest_parent" 2>/dev/null | tail -1 | tr -d ' ') || return 0
    if (( src_bytes > free_bytes )); then
        echo "WARNING: Source is ~$(format_bytes "$src_bytes") but only $(format_bytes "$free_bytes") free on destination." >&2
        printf 'Continue anyway? [y/N] ' >&2
        local reply
        read -r reply </dev/tty || reply=n
        [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted." >&2; exit 1; }
    fi
}

# Wait until fewer than $PARALLEL_JOBS background jobs are running
wait_for_slot() {
    while (( $(jobs -rp | wc -l) >= PARALLEL_JOBS )); do
        wait -n 2>/dev/null || sleep 0.05
    done
}

RESULTS_DIR=""
cleanup() {
    [[ -n "$RESULTS_DIR" ]] && rm -rf "$RESULTS_DIR"
}
trap cleanup EXIT INT TERM

convert_one_file() {
    local src="$1"
    local dst="$2"
    local crf="$3"
    local preset="$4"
    local audio_bitrate="$5"
    local max_width="$6"
    local max_height="$7"
    local show_progress="$8"   # 1 = show ffmpeg stats, 0 = silent
    local tmp="${dst}.tmp.$$.mp4"

    mkdir -p "$(dirname "$dst")"

    # Scale only if larger than max dimensions; ensure w/h divisible by 2 (yuv420p requirement)
    local scale="scale='if(gt(iw,${max_width}),${max_width},iw)':'if(gt(ih,${max_height}),${max_height},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

    local loglevel="warning"
    local stats_flag="-stats"
    if [[ "$show_progress" -eq 0 ]]; then
        loglevel="error"
        stats_flag="-nostats"
    fi

    if ffmpeg -hide_banner -loglevel "$loglevel" $stats_flag -y \
        -i "$src" \
        -vf "$scale" \
        -c:v libx264 \
        -preset "$preset" \
        -crf "$crf" \
        -pix_fmt yuv420p \
        -movflags +faststart \
        -c:a aac \
        -b:a "$audio_bitrate" \
        "$tmp"; then
        mv "$tmp" "$dst"
        return 0
    else
        rm -f "$tmp"
        return 1
    fi
}

main() {
    local replace=0
    local dry_run=0
    local crf="$DEFAULT_VIDEO_CRF"
    local preset="$DEFAULT_VIDEO_PRESET"
    local audio_bitrate="$DEFAULT_AUDIO_BITRATE"
    local max_width="$DEFAULT_MAX_WIDTH"
    local max_height="$DEFAULT_MAX_HEIGHT"
    local log_file=""
    local positional=()
    PARALLEL_JOBS="$DEFAULT_PARALLEL_JOBS"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)          usage; exit 0 ;;
            --replace)          replace=1; shift ;;
            --dry-run)          dry_run=1; shift ;;
            --crf)              [[ $# -ge 2 ]] || fail "--crf requires a value"; crf="$2"; shift 2 ;;
            --crf=*)            crf="${1#--crf=}"; shift ;;
            --preset)           [[ $# -ge 2 ]] || fail "--preset requires a value"; preset="$2"; shift 2 ;;
            --preset=*)         preset="${1#--preset=}"; shift ;;
            --audio-bitrate)    [[ $# -ge 2 ]] || fail "--audio-bitrate requires a value"; audio_bitrate="$2"; shift 2 ;;
            --audio-bitrate=*)  audio_bitrate="${1#--audio-bitrate=}"; shift ;;
            --max-width)        [[ $# -ge 2 ]] || fail "--max-width requires a value"; max_width="$2"; shift 2 ;;
            --max-width=*)      max_width="${1#--max-width=}"; shift ;;
            --max-height)       [[ $# -ge 2 ]] || fail "--max-height requires a value"; max_height="$2"; shift 2 ;;
            --max-height=*)     max_height="${1#--max-height=}"; shift ;;
            --jobs)             [[ $# -ge 2 ]] || fail "--jobs requires a value"; PARALLEL_JOBS="$2"; shift 2 ;;
            --jobs=*)           PARALLEL_JOBS="${1#--jobs=}"; shift ;;
            --log)              [[ $# -ge 2 ]] || fail "--log requires a value"; log_file="$2"; shift 2 ;;
            --log=*)            log_file="${1#--log=}"; shift ;;
            --)                 shift; positional+=("$@"); break ;;
            -*)                 fail "Unknown option: $1" ;;
            *)                  positional+=("$1"); shift ;;
        esac
    done

    [[ ${#positional[@]} -ge 1 ]] || { usage; exit 1; }

    [[ "$crf" =~ ^[0-9]+$ ]]          || fail "--crf must be an integer"
    (( crf <= 51 ))                    || fail "--crf must be between 0 and 51"
    [[ "$max_width" =~ ^[0-9]+$ ]]    || fail "--max-width must be an integer"
    [[ "$max_height" =~ ^[0-9]+$ ]]   || fail "--max-height must be an integer"
    [[ "$audio_bitrate" =~ ^[0-9]+[kKmM]?$ ]] || fail "--audio-bitrate must be like 192k"
    [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || fail "--jobs must be an integer"
    (( PARALLEL_JOBS >= 1 ))           || fail "--jobs must be at least 1"
    case "$preset" in
        ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
        *) fail "--preset must be one of: ultrafast superfast veryfast faster fast medium slow slower veryslow" ;;
    esac

    local source_dir="${positional[0]}"
    local output_dir="${positional[1]:-}"
    [[ -d "$source_dir" ]] || fail "Source directory '$source_dir' does not exist"

    require_command python3

    # Set up log file tee before any output
    if [[ -n "$log_file" ]]; then
        exec > >(tee -a "$log_file") 2>&1
        echo "Logging to: $log_file"
    fi

    [[ "$dry_run" -eq 0 ]] && require_command ffmpeg

    local src_abs out_abs mirror_mode=0
    src_abs="$(abs_path "$source_dir")"

    if [[ -n "$output_dir" ]]; then
        out_abs="$(abs_path "$output_dir")"
        mirror_mode=1
        [[ "$out_abs" == "$src_abs" ]]   && fail "OUTPUT_DIR must differ from SOURCE_DIR"
        [[ "$out_abs" == "$src_abs"/* ]] && fail "OUTPUT_DIR may not be inside SOURCE_DIR"
        [[ "$dry_run" -eq 0 ]] && mkdir -p "$out_abs"
    fi

    mapfile -d '' -t mov_files < <(find "$src_abs" -type f -iname '*.mov' -print0)

    local total="${#mov_files[@]}"
    if (( total == 0 )); then
        echo "No MOV files found in '$src_abs'."
        exit 0
    fi

    # Disk space check (only when writing to separate output dir)
    if [[ "$dry_run" -eq 0 && "$mirror_mode" -eq 1 ]]; then
        check_free_space "$src_abs" "$out_abs"
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        echo "DRY RUN — no files will be modified."
        echo
        local would_convert=0 would_skip=0
        local total_size=0
        for src in "${mov_files[@]}"; do
            local rel="${src#$src_abs/}"
            local dst
            if (( mirror_mode )); then dst="$out_abs/${rel%.*}.mp4"
            else dst="${src%.*}.mp4"; fi
            if [[ -f "$dst" ]]; then
                printf '  SKIP  (exists): %s\n' "$rel"
                (( ++would_skip ))
            else
                local sz
                sz=$(stat -c%s -- "$src")
                total_size=$(( total_size + sz ))
                printf '  CONVERT: %s  ->  %s  (%s)\n' "$rel" "${rel%.*}.mp4" "$(format_bytes "$sz")"
                (( ++would_convert ))
            fi
        done
        echo
        printf 'Would convert : %d  (~%s source data)\n' "$would_convert" "$(format_bytes "$total_size")"
        printf 'Would skip    : %d\n' "$would_skip"
        exit 0
    fi

    # With parallel jobs, suppress per-file ffmpeg stats to avoid garbled output
    local show_progress=1
    (( PARALLEL_JOBS > 1 )) && show_progress=0

    echo "Found $total MOV file(s). Converting to MP4 (crf=$crf, preset=$preset, audio=$audio_bitrate, jobs=$PARALLEL_JOBS) ..."
    [[ "$replace" -eq 1 ]] && echo "Mode: replace originals after conversion"
    [[ "$PARALLEL_JOBS" -gt 1 ]] && echo "Note: ffmpeg progress suppressed in parallel mode"
    echo

    RESULTS_DIR=$(mktemp -d)

    local START_TIME=$SECONDS
    local index=0
    for src in "${mov_files[@]}"; do
        (( ++index ))
        local rel="${src#$src_abs/}"
        local dst
        if (( mirror_mode )); then dst="$out_abs/${rel%.*}.mp4"
        else dst="${src%.*}.mp4"; fi

        if [[ -f "$dst" ]]; then
            printf '[%d/%d] SKIP (exists): %s\n' "$index" "$total" "$rel"
            echo "skip|0|0" > "$RESULTS_DIR/$index"
            continue
        fi

        local size_before
        size_before=$(stat -c%s -- "$src")
        printf '[%d/%d] Converting: %s  (%s)\n' "$index" "$total" "$rel" "$(format_bytes "$size_before")"

        wait_for_slot

        local _src="$src" _dst="$dst" _sb="$size_before" _idx="$index" _rel="$rel"
        local _crf="$crf" _preset="$preset" _ab="$audio_bitrate" _mw="$max_width" _mh="$max_height"
        local _replace="$replace" _sp="$show_progress"
        {
            if convert_one_file "$_src" "$_dst" "$_crf" "$_preset" "$_ab" "$_mw" "$_mh" "$_sp"; then
                local size_after
                size_after=$(stat -c%s -- "$_dst")
                printf '  done: %s -> %s\n' "$(format_bytes "$_sb")" "$(format_bytes "$size_after")"
                if [[ "$_replace" -eq 1 ]]; then rm -f "$_src"; fi
                echo "ok|$_sb|$size_after" > "$RESULTS_DIR/$_idx"
            else
                echo "  FAILED: $_rel" >&2
                echo "failed|$_sb|0" > "$RESULTS_DIR/$_idx"
            fi
        } &
    done
    wait

    # Collect results
    local ok=0 failed=0 skipped=0
    local bytes_before=0 bytes_after=0
    for result_file in "$RESULTS_DIR"/*; do
        [[ -f "$result_file" ]] || continue
        IFS='|' read -r status sb sa < "$result_file"
        case "$status" in
            ok)     (( ++ok )); bytes_before=$(( bytes_before + sb )); bytes_after=$(( bytes_after + sa )) ;;
            failed) (( ++failed )) ;;
            skip)   (( ++skipped )) ;;
        esac
    done

    local elapsed=$(( SECONDS - START_TIME ))
    echo
    echo "=== MOV → MP4 Conversion Summary ==="
    printf 'Converted : %d\n' "$ok"
    printf 'Skipped   : %d\n' "$skipped"
    printf 'Failed    : %d\n' "$failed"
    if (( ok > 0 )); then
        printf 'Size      : %s -> %s\n' "$(format_bytes "$bytes_before")" "$(format_bytes "$bytes_after")"
    fi
    printf 'Elapsed   : %s\n' "$(format_elapsed "$elapsed")"
    echo

    if (( failed > 0 )); then
        echo "WARNING: $failed file(s) failed to convert." >&2
        exit 1
    fi
}

main "$@"
