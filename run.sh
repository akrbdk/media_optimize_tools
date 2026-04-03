#!/usr/bin/env bash

# Single entry point for all media scripts in this repository.
# Usage: ./run.sh <command> [arguments and options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: run.sh <command> [arguments]

Commands:
  optimize   SOURCE_DIR [DEST_DIR]   Copy + optimize media archive (main command)
  stats      TARGET_DIR              Show disk usage and largest files

Pass --help after any command for full options.

Examples:
  run.sh optimize /media/usb/Photos
  run.sh optimize --level aggressive /media/usb/Photos /media/usb/Photos_opt
  run.sh optimize --dry-run --level aggressive /media/usb/Photos
  run.sh optimize --level moderate --crf 20 --preset slow /media/usb/Photos
  run.sh optimize --jpeg-quality 92 --max-image-dim 6000 /media/usb/Photos
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
    optimize)
        exec "$SCRIPT_DIR/personal/media_optimize.sh" "$@"
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
