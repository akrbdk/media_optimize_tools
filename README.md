# Copy & Optimize Media Scripts

## What's in this repository

| Command    | Script                       | What it does                                                                                       |
|------------|------------------------------|----------------------------------------------------------------------------------------------------|
| `optimize` | `personal/media_optimize.sh` | Copies a folder and optimizes the copy. Levels: `archive` / `moderate` / `aggressive` / `maximum` |
| `stats`    | `statistics/folder_stats.sh` | Disk statistics: folder sizes, largest files, and files that need compression                      |

All commands are run via `./run.sh <command>`.

---

## `optimize` — media archive optimization

Makes an rsync copy of SOURCE_DIR and optimizes it. The original is never touched.
The destination folder is named automatically: `SOURCE_DIR_<level>` (e.g. `Photos_aggressive`).

**Formats processed:**

- MOV, VOB → MP4 H.264 + AAC (always — plays everywhere)
- JPEG, WEBP → recompressed, EXIF preserved (date, GPS, camera)
- PNG → converted to JPEG, EXIF preserved (much smaller than lossless PNG)
- MP4/MKV/AVI → re-encoded at `moderate`, `aggressive`, `maximum`

After optimization finishes, folder statistics are automatically printed for both the original and the optimized copy so you can compare them without running `stats` manually.

### Levels

|                | `archive`       | `moderate` (default) | `aggressive`            | `maximum`              |
|----------------|-----------------|----------------------|-------------------------|------------------------|
| JPEG/PNG quality | 95            | 88                   | 80                      | 70                     |
| Max photo size | no limit        | 8000px               | 3840px                  | 2560px                 |
| MOV/VOB → MP4  | CRF 20, 4K slow | CRF 25, 4K           | CRF 28, 1080p           | CRF 32, 720p           |
| MP4/MKV/AVI    | skip            | re-encode CRF 25, 4K | re-encode CRF 28, 1080p | re-encode CRF 32, 720p |

### Examples

```bash
# Default (moderate): good quality, all video re-encoded
./run.sh optimize /media/usb/Photos

# Aggressive: maximum savings, quality still fine for personal archive
./run.sh optimize --level aggressive /media/usb/Photos

# Specify destination manually
./run.sh optimize --level aggressive /media/usb/Photos /media/usb/Photos_backup

# Preview estimated savings without making changes
./run.sh optimize --dry-run --level aggressive /media/usb/Photos

# Resume an interrupted optimization (skip already-processed files)
./run.sh optimize --resume --level aggressive /media/usb/Photos_aggressive

# Skip rsync and re-optimize an already-copied directory from scratch
./run.sh optimize --skip-copy --level aggressive /media/usb/Photos_aggressive

# Process only specific formats
./run.sh optimize --only-exts mov /media/usb/Photos
./run.sh optimize --only-exts jpg,jpeg,png --level aggressive /media/usb/Photos

# Skip specific formats (e.g. don't re-encode existing MP4/MKV)
./run.sh optimize --skip-exts mp4,mkv /media/usb/Photos
./run.sh optimize --level aggressive --skip-exts mp4,mkv,avi /media/usb/Photos

# Re-compress only large files (skip files that are already small enough)
./run.sh optimize --skip-copy --level aggressive \
    --min-photo-mb 4 --min-video-mb 80 /media/usb/Photos_aggressive

# Fine-tune quality on top of a level
./run.sh optimize --level moderate --crf 22 --preset slow /media/usb/Photos
./run.sh optimize --level aggressive --jpeg-quality 85 /media/usb/Photos

# Parallel processing + log to file
./run.sh optimize --log ~/opt.log --jobs 4 /media/usb/Photos
```

### All options

```
--level LEVEL                  Optimization preset (default: moderate)
                               archive | moderate | aggressive | maximum
--only-exts EXT[,EXT,...]      Process only these extensions, e.g. mov,jpg,png
--skip-exts EXT[,EXT,...]      Skip these extensions, e.g. mp4,mkv,avi
--dry-run                      Show estimated savings per type, make no changes
--skip-copy                    Skip rsync; optimize an already-copied directory
--resume                       Resume an interrupted optimization of DEST_DIR
                               (implies --skip-copy; use the same --level as the original run)
--log FILE                     Write output to file + terminal
--jobs N                       Parallel workers for photo/video (default: 1)

Quality overrides (applied on top of --level):
--jpeg-quality N      JPEG/PNG quality (1-100, PNG is converted to JPEG)
--max-image-dim N     Resize photo if longest side > N pixels
--crf N               Video CRF 0-51 (lower = better quality)
--preset NAME         ffmpeg preset: ultrafast fast medium slow veryslow
--max-width N         Downscale video if wider than N pixels
--max-height N        Downscale video if taller than N pixels
--audio-bitrate VAL   AAC bitrate, e.g. 128k 192k 256k

Size filters (skip files already small enough):
--min-photo-mb N      Skip photos smaller than N MB
--min-video-mb N      Skip videos/MOV/VOB smaller than N MB
```

---

## `stats` — disk statistics

Shows folder sizes, largest files, and a list of files that would benefit most from
aggressive-level optimization. Makes no changes.

Run this before `optimize` to understand what's taking up space and what needs compression.

```bash
# Basic stats
./run.sh stats /media/usb/Photos

# Deeper folder breakdown + more files
./run.sh stats --depth 3 --top-files 100 /media/usb/Photos

# Custom thresholds for problematic files
./run.sh stats --photo-mb 2 --video-mb 50 /media/usb/Photos

# Per-subdirectory summary: size and file count, sorted alphabetically
./run.sh stats --subdirs /media/usb/Photos

# Save output to file
./run.sh stats --log ~/stats.log /media/usb/Photos
```

### All options

| Option            | Default | Description                                              |
|-------------------|---------|----------------------------------------------------------|
| `--depth N`       | `2`     | Subdirectory depth for du breakdown                      |
| `--top-files K`   | `50`    | Number of largest files to list                          |
| `--photo-mb N`    | `4`     | Flag photos larger than N MB as needing compression      |
| `--video-mb N`    | `80`    | Flag videos larger than N MB as needing compression      |
| `--dupes`         | off     | Find duplicate files by content hash (requires python3)  |
| `--subdirs`       | off     | Per-subdirectory summary: size and file count            |
| `--log FILE`      | off     | Append all output to FILE in addition to the terminal    |

Environment overrides: `FOLDER_STATS_DEPTH`, `FOLDER_STATS_TOP_FILES`, `FOLDER_STATS_PHOTO_MB`, `FOLDER_STATS_VIDEO_MB`.

### Example output (problematic files section)

```
Files that need aggressive compression:
  Photos > 4 MB | Videos/MOV > 80 MB | All MOV (need conversion)

  [photo   8.3 MB]  TANYA/3 лето/IMG_5466.jpg
  [photo   6.1 MB]  TANYA/2 весна/IMG_3842.jpg
  [MOV   312.4 MB]  TANYA/1 зима/IMG_0877.MOV
  [video  145.1 MB]  TANYA/2 весна/long_video.mp4

  Large photos :  2 files   14.4 MB
  MOV files    :  1 files  312.4 MB
  Large videos :  1 files  145.1 MB
  Total        :  4 files  471.9 MB
```

---

## Typical workflow

```bash
# 1. Check what's taking space and what needs compression
./run.sh stats /media/usb/Photos

# 2. Preview savings before running
./run.sh optimize --dry-run --level aggressive /media/usb/Photos

# 3. Run optimization (stats comparison printed automatically at the end)
./run.sh optimize --level aggressive /media/usb/Photos

# 4. If some files are still too large, re-compress only those
./run.sh optimize --skip-copy --level aggressive \
    --min-photo-mb 4 --min-video-mb 80 /media/usb/Photos_aggressive
```

---

## Real-world scenarios

### Scenario 1 — iPhone photo backup, first-time archive

iPhone exports a mix of JPEG, PNG (screenshots), and MOV (videos).
Goal: shrink to 40–60% of original size while keeping quality for a personal archive.

```bash
# Check what you have
./run.sh stats --depth 2 /media/usb/iPhone_2024

# Preview savings
./run.sh optimize --dry-run --level aggressive /media/usb/iPhone_2024

# Run optimization
# MOV → MP4, PNG → JPEG, all JPEG recompressed, stats printed at the end
./run.sh optimize --level aggressive /media/usb/iPhone_2024
```

---

### Scenario 2 — Re-optimize an existing archive (already optimized before)

You already have `Photos_aggressive` but some large files were missed or added later.

```bash
# See what's still large
./run.sh stats --photo-mb 3 --video-mb 50 /media/usb/Photos_aggressive

# Re-compress only the files above the threshold, skip everything else
./run.sh optimize --skip-copy --level aggressive \
    --min-photo-mb 3 --min-video-mb 50 /media/usb/Photos_aggressive
```

---

### Scenario 3 — Only compress videos, keep photos untouched

You already have good photos but want to shrink bulky MOV files.

```bash
./run.sh optimize --only-exts mov --level aggressive /media/usb/Photos
```

---

### Scenario 4 — Keep original MP4/MKV, only convert MOV

Your MP4/MKV files are already compressed. Only convert raw MOV files from iPhone.

```bash
./run.sh optimize --skip-exts mp4,mkv,avi --level aggressive /media/usb/Photos
```

---

### Scenario 5 — Max quality, just convert MOV to MP4

Archive-level: near-lossless quality, just get rid of MOV format for compatibility.

```bash
./run.sh optimize --level archive --only-exts mov /media/usb/Photos
```

---

### Scenario 5a — Convert DVD VOB files to MP4

VOB files from DVD rips are always converted to MP4 (same as MOV).

```bash
# Convert VOB files at archive quality (near-lossless)
./run.sh optimize --level archive --only-exts vob /media/usb/DVD_backup

# Or together with MOV in one pass
./run.sh optimize --level moderate --only-exts mov,vob /media/usb/HomeVideos
```

---

### Scenario 6 — Optimization was interrupted, continue from where it stopped

The copy is already there but optimization was cut short (Ctrl+C, power loss, disk full, etc.).

```bash
# Check what's already been processed
cat /media/usb/Photos_aggressive/.optimize_progress | wc -l

# Resume — already-processed files are skipped, the rest continue
./run.sh optimize --resume --level aggressive /media/usb/Photos_aggressive
```

> `.optimize_progress` is deleted automatically when optimization finishes successfully.
> If you restart without `--resume` the script will warn you that the file exists.

---

### Scenario 7 — Large family archive, process folder by folder

The archive is huge. Process one year at a time to be safe.

```bash
for year in /media/usb/Archive/20*/; do
    ./run.sh optimize --level aggressive --log ~/opt.log "$year"
done
```

> If a yearly run gets interrupted, resume it with `--resume` before moving to the next folder.

---

## How to compress your archive and delete originals

### Step 1 — check what you have

```bash
./run.sh stats --depth 2 /path/to/archive
```

### Step 2 — preview savings

```bash
./run.sh optimize --dry-run --level aggressive /path/to/archive
```

### Step 3 — create optimized copy

```bash
./run.sh optimize --level aggressive /path/to/archive
# Creates /path/to/archive_aggressive. Original is not modified.
# Folder stats are printed at the end — no need to run stats manually.
```

### Step 4 — verify the copy

```bash
# Compare file counts — must match (PNG files will show as JPEG now)
find /path/to/archive -type f | wc -l
find /path/to/archive_aggressive -type f | wc -l

# Open a few photos and videos manually and check quality
```

Checklist before deleting originals:

- [ ] Several photos opened normally
- [ ] Videos play correctly
- [ ] File counts match (PNG → JPEG conversion changes the count if there were PNGs)
- [ ] Photo dates are preserved (check EXIF in file properties)
- [ ] The copy is on a **different drive** or backed up to cloud

### Step 5 — delete originals

```bash
rm -rf /path/to/archive
```

> **Important:** do not delete originals while the copy is on the same drive.
> If the drive fails you lose everything. Copy to an external drive or cloud first,
> confirm it reads correctly, then delete.

If your archive is large — process it folder by folder, not all at once.

---

## Dependencies

```bash
sudo apt install rsync python3 imagemagick ffmpeg
```

| Tool          | Used for                              |
|---------------|---------------------------------------|
| `rsync`       | Copying source → destination          |
| `python3`     | Dry-run size estimates                |
| `imagemagick` | JPEG/PNG/WEBP photo optimization      |
| `ffmpeg`      | MOV/VOB→MP4 conversion, video re-encoding |

**Note:** `ffmpeg` is only needed if your archive contains video files (MOV, VOB, MP4, MKV, etc.).
If you only have photos, skip it and use `--skip-exts mov,vob` or `--only-exts jpg,jpeg,png`:

```bash
./run.sh optimize --only-exts jpg,jpeg,png /media/usb/Photos
```

All scripts print elapsed time in the final report.
