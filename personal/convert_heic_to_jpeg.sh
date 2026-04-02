#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_JPEG_QUALITY="${HEIC_JPEG_QUALITY:-90}"

usage() {
    cat <<'EOF'
Usage: convert_heic_to_jpeg.sh [OPTIONS] SOURCE_DIR [OUTPUT_DIR]

Recursively finds all HEIC/HEIF files in SOURCE_DIR and converts them to JPEG.

By default, converted files are placed next to the originals (same directory)
with a .jpg extension. Original files are kept unless --replace is used.

If OUTPUT_DIR is given, the directory tree is mirrored there.

Options:
  --replace        Remove each original HEIC/HEIF file after successful conversion
  --quality N      JPEG quality 1-100 (default: 90, override: HEIC_JPEG_QUALITY)
  -h, --help       Show this help

Requirements: ImageMagick (magick or convert) with HEIC support, or heif-convert
              Install on Ubuntu/Debian: sudo apt install libheif-examples imagemagick
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

# Detect available HEIC conversion tool and set CONVERT_CMD
init_convert_tool() {
    if command -v magick >/dev/null 2>&1; then
        CONVERT_TOOL="magick_convert"
    elif command -v convert >/dev/null 2>&1; then
        # Make sure it's ImageMagick, not some other 'convert'
        if convert --version 2>&1 | grep -qi imagemagick; then
            CONVERT_TOOL="im_convert"
        else
            CONVERT_TOOL=""
        fi
    fi

    if [[ -z "${CONVERT_TOOL:-}" ]] && command -v heif-convert >/dev/null 2>&1; then
        CONVERT_TOOL="heif_convert"
    fi

    if [[ -z "${CONVERT_TOOL:-}" ]]; then
        fail "No suitable converter found. Install ImageMagick (with HEIC support) or libheif-examples (heif-convert)."
    fi
}

convert_one_file() {
    local src="$1"
    local dst="$2"
    local quality="$3"

    mkdir -p "$(dirname "$dst")"

    case "${CONVERT_TOOL}" in
        magick_convert)
            magick convert -auto-orient -strip -quality "$quality" "$src" "$dst"
            ;;
        im_convert)
            convert -auto-orient -strip -quality "$quality" "$src" "$dst"
            ;;
        heif_convert)
            # heif-convert doesn't have a quality flag in the same form; use -q
            heif-convert -q "$quality" "$src" "$dst"
            ;;
    esac
}

main() {
    local replace=0
    local quality="$DEFAULT_JPEG_QUALITY"
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --replace) replace=1; shift ;;
            --quality)
                [[ $# -ge 2 ]] || fail "--quality requires a value"
                quality="$2"; shift 2 ;;
            --quality=*)
                quality="${1#--quality=}"; shift ;;
            --) shift; positional+=("$@"); break ;;
            -*) fail "Unknown option: $1" ;;
            *) positional+=("$1"); shift ;;
        esac
    done

    [[ ${#positional[@]} -ge 1 ]] || { usage; exit 1; }

    local source_dir="${positional[0]}"
    local output_dir="${positional[1]:-}"

    [[ -d "$source_dir" ]] || fail "Source directory '$source_dir' does not exist"
    [[ "$quality" =~ ^[0-9]+$ ]] || fail "--quality must be an integer"
    (( quality >= 1 && quality <= 100 )) || fail "--quality must be between 1 and 100"

    require_command python3

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

    init_convert_tool

    mapfile -d '' -t heic_files < <(find "$src_abs" -type f \( \
        -iname '*.heic' -o -iname '*.heif' \) -print0)

    local total="${#heic_files[@]}"
    if (( total == 0 )); then
        echo "No HEIC/HEIF files found in '$src_abs'."
        exit 0
    fi

    echo "Found $total HEIC/HEIF file(s). Converting to JPEG (quality=$quality) ..."
    echo "Converter: $CONVERT_TOOL"
    [[ "$replace" -eq 1 ]] && echo "Mode: replace originals after conversion"
    echo

    local ok=0
    local failed=0
    local skipped=0
    local bytes_before=0
    local bytes_after=0

    local index=0
    for src in "${heic_files[@]}"; do
        (( ++index ))
        local rel="${src#$src_abs/}"
        local base="${src%.*}"
        local dst

        if (( mirror_mode )); then
            dst="$out_abs/${rel%.*}.jpg"
        else
            dst="${base}.jpg"
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

        if convert_one_file "$src" "$dst" "$quality"; then
            local size_after
            size_after=$(stat -c%s -- "$dst")
            bytes_after=$(( bytes_after + size_after ))
            printf '  %s -> %s  (%s -> %s)\n' \
                "$rel" \
                "${rel%.*}.jpg" \
                "$(format_bytes "$size_before")" \
                "$(format_bytes "$size_after")"
            (( ++ok ))
            if [[ "$replace" -eq 1 ]]; then
                rm -f "$src"
            fi
        else
            echo "  FAILED: $rel" >&2
            rm -f "$dst"
            (( ++failed ))
        fi
    done

    echo
    echo "=== HEIC → JPEG Conversion Summary ==="
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
