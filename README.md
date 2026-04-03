# Copy & Optimize Media Scripts

## What's in this repository

| Command | Script | What it does |
|---|---|---|
| `optimize` | `personal/media_optimize.sh` | Copies a folder and optimizes the copy. Levels: `archive` / `moderate` / `aggressive` / `maximum` |
| `stats` | `statistics/folder_stats.sh` | Disk statistics: folder sizes and largest files |

All commands are run via `./run.sh <command>`.

---

## `optimize` — media archive optimization

Makes an rsync copy of SOURCE_DIR and optimizes it. The original is never touched.

**Formats:**
- HEIC/HEIF → JPEG (always — ~50–70% savings, opens everywhere)
- MOV → MP4 H.264 + AAC (always — plays everywhere)
- JPEG, WEBP → recompressed (strip EXIF, slight quality reduction)
- PNG → lossless recompression (strip EXIF)
- MP4/MKV/AVI → only at `--level aggressive` and `--level maximum`

### Levels

| | `archive` | `moderate` (default) | `aggressive` | `maximum` |
|---|---|---|---|---|
| JPEG quality | 95 | 88 | 80 | 70 |
| Max photo size | no limit | 8000px | 3840px | 2560px |
| MOV → MP4 | CRF 18, 4K slow | CRF 23, 4K | CRF 26, 1080p | CRF 28, 720p |
| MP4/MKV/AVI | skip | skip | re-encode CRF 26, 1080p | re-encode CRF 28, 720p |

### Examples

```bash
# Default (moderate) optimization
./run.sh optimize /media/usb/Photos

# Aggressive — maximum savings
./run.sh optimize --level aggressive /media/usb/Photos /media/usb/Photos_opt

# Preview without making changes
./run.sh optimize --dry-run --level aggressive /media/usb/Photos

# Fine-tune on top of a level
./run.sh optimize --level moderate --crf 20 --preset slow /media/usb/Photos
./run.sh optimize --jpeg-quality 92 --max-image-dim 6000 /media/usb/Photos

# Save log + parallel photo processing
./run.sh optimize --log ~/opt.log --jobs 4 /media/usb/Photos

# Process only specific extensions
./run.sh optimize --only-exts heic,mov /media/usb/Photos
./run.sh optimize --only-exts jpg,jpeg,png --level aggressive /media/usb/Photos

# Skip rsync, optimize an already-copied directory (e.g. after interrupted run)
./run.sh optimize --skip-copy --level aggressive /media/usb/Photos_opt
```

### All options

```
--level LEVEL                  Optimization preset (default: moderate)
                               archive | moderate | aggressive | maximum
--only-exts EXT[,EXT,...]      Process only these extensions, e.g. heic,mov,jpg
--dry-run                      Show estimated savings per type, make no changes
--skip-copy                    Skip rsync; optimize an already-copied directory
--log FILE                     Write output to file + terminal
--jobs N                       Parallel workers for photo/HEIC/video (default: 1)

Quality overrides (applied on top of --level):
--jpeg-quality N      JPEG/WEBP quality (1-100)
--png-compression N   PNG compression level 0-9 (lossless)
--max-image-dim N     Resize photo if longest side > N pixels
--crf N               Video CRF 0-51 (lower = better quality)
--preset NAME         ffmpeg preset: ultrafast fast medium slow veryslow
--max-width N         Downscale video if wider than N pixels
--max-height N        Downscale video if taller than N pixels
--audio-bitrate VAL   AAC bitrate, e.g. 128k 192k 256k
```

---

## `stats` — disk statistics

Shows folder sizes and largest files. Makes no changes.
Useful to run before `optimize` to understand what's taking up space.

```bash
./run.sh stats /media/usb
./run.sh stats --depth 3 --top-files 100 /media/usb
./run.sh stats --log ~/stats.log /media/usb
```

| Option | Default | Env override |
|---|---|---|
| `--depth N` | `2` | `FOLDER_STATS_DEPTH` |
| `--top-files K` | `50` | `FOLDER_STATS_TOP_FILES` |
| `--log FILE` | off | — |

---

## Dependencies

```bash
sudo apt install rsync python3 imagemagick libheif-examples ffmpeg
```

All scripts print elapsed time in the final report.
