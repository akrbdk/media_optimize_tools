# Copy & Optimize Media With Report

`copy_optimize_media_with_report.sh` combines the image and video optimizers in one pass, copies the source directory, and prints a detailed before/after report so you can gauge the savings before importing into Google Notes/Keep.

```
./tools/copy_optimize_media_with_report.sh SOURCE_DIR [DEST_DIR]
```

## What The Script Does

1. Verifies dependencies (`python3`, `rsync`, ImageMagick and/or `ffmpeg` if needed).
2. Creates a copy of the directory (default: `SOURCE_DIR_compressed`).
3. Finds all supported images/videos and optimizes them using the exact same settings as the standalone scripts.
4. Tracks the size of each file before/after, aggregates totals, and highlights the top files by absolute savings.
5. Prints the summary table plus `du -sh` for the original vs. optimized directories.

## Requirements

- `python3`
- `rsync`
- ImageMagick (`magick` or `mogrify`) for images
- `ffmpeg` for videos

Ubuntu install example:

```
sudo apt update
sudo apt install -y rsync python3 imagemagick ffmpeg
```

## Quality Controls

All the same environment variables remain available:

### Images

| Variable | Default | Meaning |
| --- | --- | --- |
| `NOTES_MAX_DIM` | `2048` | Max width/height in pixels. |
| `NOTES_JPEG_QUALITY` | `82` | JPEG/HEIC quality percentage. |
| `NOTES_WEBP_QUALITY` | `80` | WEBP quality percentage. |
| `NOTES_PNG_COMPRESSION` | `9` | PNG compression level (`0-9`). |

### Video

| Variable | Default | Meaning |
| --- | --- | --- |
| `NOTES_VIDEO_MAX_WIDTH` | `1920` | Maximum width. |
| `NOTES_VIDEO_MAX_HEIGHT` | `1080` | Maximum height. |
| `NOTES_VIDEO_CRF` | `23` | libx264 CRF (lower = better quality). |
| `NOTES_VIDEO_PRESET` | `medium` | libx264 speed/compression preset. |
| `NOTES_VIDEO_AUDIO_BITRATE` | `128k` | AAC audio bitrate. |

Example run with custom caps:

```
NOTES_MAX_DIM=1600 NOTES_VIDEO_MAX_WIDTH=1280 NOTES_VIDEO_MAX_HEIGHT=720 \
  ./tools/copy_optimize_media_with_report.sh media/source
```

## Reading The Report

After optimization you’ll see:

- A summary table (counts, before/after sizes, savings) for images, videos, and the total.
- Top 5 files by absolute savings.
- `du -sh` output for both directories.

If savings are minimal, the originals were likely already small or used unsupported formats.

## Workflow Tips

1. Keep originals untouched (e.g., `photos/`) and use the `_compressed` copy for sharing/importing.
2. Run the script on smaller batches to spot-check the benefit quickly.
