#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_VIDEO_CRF="${MOV_VIDEO_CRF:-23}"
readonly DEFAULT_VIDEO_PRESET="${MOV_VIDEO_PRESET:-medium}"
readonly DEFAULT_AUDIO_BITRATE="${MOV_AUDIO_BITRATE:-192k}"
readonly DEFAULT_MAX_WIDTH="${MOV_MAX_WIDTH:-3840}"
readonly DEFAULT_MAX_HEIGHT="${MOV_MAX_HEIGHT:-2160}"

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
  --crf N          Video quality: 0 (lossless) – 51 (worst). Default: 23.
                   Lower = better quality + larger file. 18–28 is a good range.
                   Override: MOV_VIDEO_CRF
  --preset NAME    ffmpeg encoding preset (ultrafast/fast/medium/slow/veryslow).
                   Default: medium. Slower preset = smaller file at same quality.
                   Override: MOV_VIDEO_PRESET
  --audio-bitrate  AAC audio bitrate, e.g. 128k, 192k, 256k. Default: 192k.
                   Override: MOV_AUDIO_BITRATE
  --max-width N    Downscale if wider than N pixels (default: 3840). Override: MOV_MAX_WIDTH
  --max-height N   Downscale if taller than N pixels (default: 2160). Override: MOV_MAX_HEIGHT
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

convert_one_file() {
    local src="$1"
    local dst="$2"
    local crf="$3"
    local preset="$4"
    local audio_bitrate="$5"
    local max_width="$6"
    local max_height="$7"
    local tmp="${dst}.tmp.$$.mp4"

    mkdir -p "$(dirname "$dst")"

    # scale filter: only downscale if larger than max dimensions, preserve aspect ratio,
    # and ensure width/height are divisible by 2 (required for yuv420p)
    local scale="scale='if(gt(iw,${max_width}),${max_width},iw)':'if(gt(ih,${max_height}),${max_height},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

    if ffmpeg -hide_banner -loglevel error -y \
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
    local crf="$DEFAULT_VIDEO_CRF"
    local preset="$DEFAULT_VIDEO_PRESET"
    local audio_bitrate="$DEFAULT_AUDIO_BITRATE"
    local max_width="$DEFAULT_MAX_WIDTH"
    local max_height="$DEFAULT_MAX_HEIGHT"
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --replace) replace=1; shift ;;
            --crf)
                [[ $# -ge 2 ]] || fail "--crf requires a value"
                crf="$2"; shift 2 ;;
            --crf=*) crf="${1#--crf=}"; shift ;;
            --preset)
                [[ $# -ge 2 ]] || fail "--preset requires a value"
                preset="$2"; shift 2 ;;
            --preset=*) preset="${1#--preset=}"; shift ;;
            --audio-bitrate)
                [[ $# -ge 2 ]] || fail "--audio-bitrate requires a value"
                audio_bitrate="$2"; shift 2 ;;
            --audio-bitrate=*) audio_bitrate="${1#--audio-bitrate=}"; shift ;;
            --max-width)
                [[ $# -ge 2 ]] || fail "--max-width requires a value"
                max_width="$2"; shift 2 ;;
            --max-width=*) max_width="${1#--max-width=}"; shift ;;
            --max-height)
                [[ $# -ge 2 ]] || fail "--max-height requires a value"
                max_height="$2"; shift 2 ;;
            --max-height=*) max_height="${1#--max-height=}"; shift ;;
            --) shift; positional+=("$@"); break ;;
            -*) fail "Unknown option: $1" ;;
            *) positional+=("$1"); shift ;;
        esac
    done

    [[ ${#positional[@]} -ge 1 ]] || { usage; exit 1; }

    local source_dir="${positional[0]}"
    local output_dir="${positional[1]:-}"

    [[ -d "$source_dir" ]] || fail "Source directory '$source_dir' does not exist"
    [[ "$crf" =~ ^[0-9]+$ ]] || fail "--crf must be an integer"
    (( crf <= 51 )) || fail "--crf must be between 0 and 51"
    [[ "$max_width" =~ ^[0-9]+$ ]] || fail "--max-width must be an integer"
    [[ "$max_height" =~ ^[0-9]+$ ]] || fail "--max-height must be an integer"
    [[ "$audio_bitrate" =~ ^[0-9]+[kKmM]?$ ]] || fail "--audio-bitrate must be like 192k"
    case "$preset" in
        ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
        *) fail "--preset must be one of: ultrafast fast medium slow veryslow" ;;
    esac

    require_command python3
    require_command ffmpeg

    local src_abs
    src_abs="$(abs_path "$source_dir")"
    local out_abs=""
    local mirror_mode=0

    if [[ -n "$output_dir" ]]; then
        out_abs="$(abs_path "$output_dir")"
        mirror_mode=1
        [[ "$out_abs" == "$src_abs" ]] && fail "OUTPUT_DIR must differ from SOURCE_DIR"
        [[ "$out_abs" == "$src_abs"/* ]] && fail "OUTPUT_DIR may not be inside SOURCE_DIR"
        mkdir -p "$out_abs"
    fi

    mapfile -d '' -t mov_files < <(find "$src_abs" -type f -iname '*.mov' -print0)

    local total="${#mov_files[@]}"
    if (( total == 0 )); then
        echo "No MOV files found in '$src_abs'."
        exit 0
    fi

    echo "Found $total MOV file(s). Converting to MP4 (crf=$crf, preset=$preset, audio=$audio_bitrate) ..."
    [[ "$replace" -eq 1 ]] && echo "Mode: replace originals after conversion"
    echo

    local ok=0
    local failed=0
    local skipped=0
    local bytes_before=0
    local bytes_after=0

    local index=0
    for src in "${mov_files[@]}"; do
        (( ++index ))
        local rel="${src#$src_abs/}"
        local dst

        if (( mirror_mode )); then
            dst="$out_abs/${rel%.*}.mp4"
        else
            dst="${src%.*}.mp4"
        fi

        # Skip if destination already exists
        if [[ -f "$dst" ]]; then
            printf '[%d/%d] SKIP (already exists): %s\n' "$index" "$total" "$rel"
            (( ++skipped ))
            continue
        fi

        printf '[%d/%d] Converting: %s\n' "$index" "$total" "$rel"

        local size_before
        size_before=$(stat -c%s -- "$src")
        bytes_before=$(( bytes_before + size_before ))

        if convert_one_file "$src" "$dst" "$crf" "$preset" "$audio_bitrate" "$max_width" "$max_height"; then
            local size_after
            size_after=$(stat -c%s -- "$dst")
            bytes_after=$(( bytes_after + size_after ))
            printf '  %s -> %s  (%s -> %s)\n' \
                "$rel" \
                "${rel%.*}.mp4" \
                "$(format_bytes "$size_before")" \
                "$(format_bytes "$size_after")"
            (( ++ok ))
            if [[ "$replace" -eq 1 ]]; then
                rm -f "$src"
            fi
        else
            echo "  FAILED: $rel" >&2
            (( ++failed ))
        fi
    done

    echo
    echo "=== MOV → MP4 Conversion Summary ==="
    printf 'Converted : %d\n' "$ok"
    printf 'Skipped   : %d\n' "$skipped"
    printf 'Failed    : %d\n' "$failed"
    if (( ok > 0 )); then
        printf 'Size      : %s -> %s\n' "$(format_bytes "$bytes_before")" "$(format_bytes "$bytes_after")"
    fi
    echo

    if (( failed > 0 )); then
        echo "WARNING: $failed file(s) failed to convert." >&2
        exit 1
    fi
}

main "$@"
