# Personal Media Optimizer

`personal_media_optimize.sh` is a gentle workflow for cleaning up large personal photo/video folders that live on external drives. It keeps quality high (4K caps, high JPEG quality, CRF 20 video) while still trimming excess metadata or oversized files, always working on a copy so originals stay safe and now prints a detailed savings report after each run.

```
./tools/personal_media_optimize.sh /mnt/usb/Photos [DEST_DIR]
```

If `DEST_DIR` is omitted the script writes to `SOURCE_DIR_safe`.

## Why use this instead of the Google Notes scripts?

- Designed for personal archives: higher quality targets, wider resize limits.
- Uses conservative defaults (JPEG 90, CRF 20, AAC 192k) to avoid noticeable degradation.
- Leaves the source untouched and reports only minimal logs—perfect for “backup-cleanup” runs on external disks.

## Requirements

- `python3`
- `rsync`
- ImageMagick (`magick`/`mogrify`) for photos
- `ffmpeg` for videos

Install on Ubuntu:

```
sudo apt update
sudo apt install -y rsync python3 imagemagick ffmpeg
```

## Quality Controls (Environment Variables)

| Variable | Default | Purpose |
| --- | --- | --- |
| `PERSONAL_MAX_DIM` | `4096` | Max width/height for photos (no resize below this). |
| `PERSONAL_JPEG_QUALITY` | `90` | JPEG/HEIC quality. |
| `PERSONAL_WEBP_QUALITY` | `88` | WEBP quality. |
| `PERSONAL_PNG_COMPRESSION` | `6` | PNG compression level (lossless). |
| `PERSONAL_VIDEO_MAX_WIDTH` | `3840` | Max video width (keeps 4K). |
| `PERSONAL_VIDEO_MAX_HEIGHT` | `2160` | Max video height. |
| `PERSONAL_VIDEO_CRF` | `20` | libx264 CRF (lower = better). |
| `PERSONAL_VIDEO_PRESET` | `slow` | libx264 preset for better compression. |
| `PERSONAL_VIDEO_AUDIO_BITRATE` | `192k` | AAC bitrate. |

Example (leave resolution untouched but squeeze JPEGs a bit more):

```
PERSONAL_MAX_DIM=6000 PERSONAL_JPEG_QUALITY=88 \
  ./tools/personal_media_optimize.sh /mnt/usb/Photos
```

## Workflow Tips

1. Run from a machine with enough free space—the copy can match the size of the source before optimization saves space.
2. Keep the `_safe` copy as your working version; once you trust the output you can replace the original manually.
3. Test on a small subfolder first to validate quality (e.g., `/Photos/Trips/2023`).
4. Use the built-in summary (counts, sizes, top-savings list) plus the printed `du -sh` output to quantify reclaimed space.

## Safety

- The script never overwrites existing destinations.
- If no supported media files are found the copy stays untouched.
- Failures while processing a file leave the original in place and log a warning.
