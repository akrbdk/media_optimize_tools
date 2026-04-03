#!/usr/bin/env bash

# Single entry point for all media scripts in this repository.
# Usage: ./run.sh <command> [arguments and options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: run.sh <command> [arguments]

Commands:
  optimize-backup SOURCE_DIR [DEST_DIR]   Backup optimizer: copy + optimize with --level
  convert-heic    SOURCE_DIR [OUTPUT_DIR] Convert HEIC/HEIF photos -> JPEG
  convert-mov     SOURCE_DIR [OUTPUT_DIR] Convert MOV videos -> MP4
  optimize        SOURCE_DIR [DEST_DIR]   Personal archive: copy + gentle optimize
  optimize-notes  SOURCE_DIR [DEST_DIR]   Google Notes: copy + compress for import
  stats           TARGET_DIR             Show disk usage and largest files

Pass --help after any command for full options.

Examples:
  run.sh optimize-backup /media/usb/Photos
  run.sh optimize-backup --level aggressive /media/usb/Photos /media/usb/Photos_opt
  run.sh optimize-backup --dry-run --level aggressive /media/usb/Photos
  run.sh convert-heic --replace --jobs 4 /media/usb/Photos
  run.sh convert-mov --dry-run /media/usb/Videos
  run.sh optimize --log ~/optimize.log /media/usb/Photos
  run.sh stats --top-files 100 /media/usb
EOF
}

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

command="$1"
shift

case "$command" in
    optimize-backup)
        exec "$SCRIPT_DIR/personal/optimize_backup.sh" "$@"
        ;;
    convert-heic)
        exec "$SCRIPT_DIR/iphone/convert_heic_to_jpeg.sh" "$@"
        ;;
    convert-mov)
        exec "$SCRIPT_DIR/iphone/convert_mov_to_mp4.sh" "$@"
        ;;
    optimize)
        exec "$SCRIPT_DIR/personal/personal_media_optimize.sh" "$@"
        ;;
    optimize-notes)
        exec "$SCRIPT_DIR/google_notes/copy_optimize_media_with_report.sh" "$@"
        ;;
    stats)
        exec "$SCRIPT_DIR/statistics/folder_stats.sh" "$@"
        ;;
    *)
        echo "Error: Unknown command '$command'" >&2
        echo "Run './run.sh --help' to see available commands." >&2
        exit 1
        ;;
esac
