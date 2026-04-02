# Copy & Optimize Media Scripts

todo

- logging process
- statistics logs

## Scripts

### Google Notes workflow

```bash
./google_notes/copy_optimize_media_with_report.sh ~/Downloads/IMAGES/COVERS
```

### Personal archive optimizer (copy + optimize in one step)

Copies a folder and gently optimizes photos/videos in the copy. Handles JPEG, PNG, WEBP, HEIC, MP4, MOV and more.

```bash
./personal/personal_media_optimize.sh ~/Downloads/IMAGES/COVERS
```

See `personal/README_personal_media_optimize.md` for full docs.

### Convert HEIC/HEIF → JPEG

For iPhone photos stored on an external drive that don't open on other devices.

```bash
# Convert next to originals (keep .heic files)
./personal/convert_heic_to_jpeg.sh /media/external/Photos

# Convert into a separate folder
./personal/convert_heic_to_jpeg.sh /media/external/Photos /media/external/Photos_jpeg

# Delete originals after successful conversion
./personal/convert_heic_to_jpeg.sh --replace /media/external/Photos

# Custom quality (default 90)
./personal/convert_heic_to_jpeg.sh --quality 85 /media/external/Photos
```

Environment override: `HEIC_JPEG_QUALITY` (default `90`).

Requirements: ImageMagick with HEIC support or `heif-convert`.

```bash
sudo apt install imagemagick libheif-examples
```

### Convert MOV → MP4

For iPhone videos that won't play on Windows, Android, TVs, or browsers.
Output is H.264 + AAC inside MP4 with `faststart` — plays everywhere.

```bash
# Convert next to originals (keep .mov files)
./personal/convert_mov_to_mp4.sh /media/external/Videos

# Convert into a separate folder, delete originals
./personal/convert_mov_to_mp4.sh --replace /media/external/Videos /media/external/Videos_mp4

# Better quality, smaller file (slower)
./personal/convert_mov_to_mp4.sh --crf 18 --preset slow /media/external/Videos
```

| Option            | Default  | Env override        |
|-------------------|----------|---------------------|
| `--crf N`         | `23`     | `MOV_VIDEO_CRF`     |
| `--preset NAME`   | `medium` | `MOV_VIDEO_PRESET`  |
| `--audio-bitrate` | `192k`   | `MOV_AUDIO_BITRATE` |
| `--max-width`     | `3840`   | `MOV_MAX_WIDTH`     |
| `--max-height`    | `2160`   | `MOV_MAX_HEIGHT`    |

Requirements: `ffmpeg`.

```bash
sudo apt install ffmpeg
```

### Statistics

```bash
./statistics/folder_stats.sh ~/Downloads/IMAGES/COVERS
```