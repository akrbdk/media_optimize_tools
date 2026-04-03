# Copy & Optimize Media Scripts

## Что есть в репозитории

| Команда           | Скрипт                                            | Что делает                                                                          |
|-------------------|---------------------------------------------------|-------------------------------------------------------------------------------------|
| `optimize-backup` | `personal/optimize_backup.sh`                     | **Главный.** Копирует папку и оптимизирует копию. Уровни: `moderate` / `aggressive` |
| `convert-heic`    | `iphone/convert_heic_to_jpeg.sh`                  | HEIC/HEIF → JPEG (фото с iPhone)                                                    |
| `convert-mov`     | `iphone/convert_mov_to_mp4.sh`                    | MOV → MP4 (видео с iPhone, воспроизводится везде)                                   |
| `optimize`        | `personal/personal_media_optimize.sh`             | Копирует + оптимизирует с мягкими настройками (без выбора уровня)                   |
| `optimize-notes`  | `google_notes/copy_optimize_media_with_report.sh` | Копирует + сжимает для импорта в Google Notes/Keep                                  |
| `stats`           | `statistics/folder_stats.sh`                      | Статистика диска: размеры папок и самые большие файлы                               |

Все скрипты запускаются через единую точку входа `./run.sh <команда>`.

---

## Quick start — `run.sh`

Single entry point for all commands:

```bash
./run.sh <command> [options] SOURCE_DIR

# Оптимизировать бэкап (главный сценарий)
./run.sh optimize-backup /media/usb/Photos
./run.sh optimize-backup --level aggressive /media/usb/Photos

# Конвертация форматов iPhone
./run.sh convert-heic /media/usb/Photos
./run.sh convert-mov  /media/usb/Videos

# Статистика
./run.sh stats        /media/usb
```

Pass `--help` after any command for full options.

---

## Commands

### `optimize-backup` — Оптимизация бэкапа с уровнем сжатия

Главный скрипт для оптимизации архивов фото/видео. Делает копию, оригинал не трогает.
Обрабатывает все форматы: JPEG, PNG, WEBP, HEIC→JPEG, MOV→MP4, и при `aggressive` — MP4/MKV/AVI.

```bash
# Умеренная оптимизация (по умолчанию) — безопасно, почти незаметная потеря качества
./run.sh optimize-backup /media/usb/Photos

# Агрессивная оптимизация — максимальная экономия, видео в 1080p
./run.sh optimize-backup --level aggressive /media/usb/Photos /media/usb/Photos_opt

# Предпросмотр без изменений
./run.sh optimize-backup --dry-run --level aggressive /media/usb/Photos
```

| Параметр          | moderate       | aggressive              |
|-------------------|----------------|-------------------------|
| JPEG качество     | 88             | 80                      |
| Макс. размер фото | 8000px         | 3840px                  |
| HEIC → JPEG       | quality 88     | quality 80              |
| MOV → MP4         | CRF 23, 4K max | CRF 26, 1080p max       |
| MP4/MKV/AVI       | **не трогать** | re-encode CRF 26, 1080p |

Поддерживает `--log FILE`, `--jobs N`, `--dry-run`.

---

### `convert-heic` — HEIC/HEIF → JPEG

For iPhone photos that don't open on other devices.

```bash
# Convert next to originals (keep .heic files)
./run.sh convert-heic /media/usb/Photos

# Convert into a separate folder
./run.sh convert-heic /media/usb/Photos /media/usb/Photos_jpeg

# Delete originals after conversion, run 4 files in parallel
./run.sh convert-heic --replace --jobs 4 /media/usb/Photos

# Preview without doing anything
./run.sh convert-heic --dry-run /media/usb/Photos

# Save log to file
./run.sh convert-heic --log ~/heic.log /media/usb/Photos
```

| Option        | Default | Env override        |
|---------------|---------|---------------------|
| `--quality N` | `90`    | `HEIC_JPEG_QUALITY` |
| `--jobs N`    | `1`     | `HEIC_JOBS`         |
| `--replace`   | off     | —                   |
| `--dry-run`   | off     | —                   |
| `--log FILE`  | off     | —                   |

Requirements: ImageMagick (with HEIC support) or `heif-convert`.

```bash
sudo apt install imagemagick libheif-examples
```

---

### `convert-mov` — MOV → MP4

For iPhone videos that won't play on Windows, Android, TVs or browsers.
Output: H.264 + AAC, `yuv420p`, `faststart` — plays everywhere.

```bash
# Convert next to originals
./run.sh convert-mov /media/usb/Videos

# Delete originals, convert 2 at a time
./run.sh convert-mov --replace --jobs 2 /media/usb/Videos

# Preview without doing anything
./run.sh convert-mov --dry-run /media/usb/Videos

# Better quality (slower encoding, smaller file)
./run.sh convert-mov --crf 18 --preset slow /media/usb/Videos
```

| Option            | Default  | Env override        |
|-------------------|----------|---------------------|
| `--crf N`         | `23`     | `MOV_VIDEO_CRF`     |
| `--preset NAME`   | `medium` | `MOV_VIDEO_PRESET`  |
| `--audio-bitrate` | `192k`   | `MOV_AUDIO_BITRATE` |
| `--max-width N`   | `3840`   | `MOV_MAX_WIDTH`     |
| `--max-height N`  | `2160`   | `MOV_MAX_HEIGHT`    |
| `--jobs N`        | `1`      | `MOV_JOBS`          |
| `--replace`       | off      | —                   |
| `--dry-run`       | off      | —                   |
| `--log FILE`      | off      | —                   |

Requirements: `ffmpeg`.

```bash
sudo apt install ffmpeg
```

---

### `optimize` — Personal archive optimizer

Copies a folder and gently optimizes all photos and videos in the copy.
Handles JPEG, PNG, WEBP, HEIC, MP4, MOV and more. Source is never touched.

```bash
./run.sh optimize /media/usb/Photos
./run.sh optimize /media/usb/Photos /media/usb/Photos_safe
./run.sh optimize --log ~/optimize.log /media/usb/Photos
```

Checks free disk space before starting and warns if it may be insufficient.
See `personal/README_personal_media_optimize.md` for full docs and env overrides.

---

### `optimize-notes` — Google Notes optimizer

Same as `optimize` but with more aggressive compression (1080p video cap, lower JPEG quality)
suitable for importing into Google Notes/Keep.

```bash
./run.sh optimize-notes ~/Downloads/IMAGES/COVERS
```

---

### `stats` — Disk usage report

Shows folder sizes and the largest files. No files are modified.
Useful for deciding what to optimize first.

```bash
./run.sh stats /media/usb
./run.sh stats --depth 3 --top-files 100 /media/usb
./run.sh stats --log ~/stats.log /media/usb
```

| Option          | Default | Env override             |
|-----------------|---------|--------------------------|
| `--depth N`     | `2`     | `FOLDER_STATS_DEPTH`     |
| `--top-files K` | `50`    | `FOLDER_STATS_TOP_FILES` |
| `--log FILE`    | off     | —                        |

---

## Common options (all scripts)

| Option        | Effect                                                         |
|---------------|----------------------------------------------------------------|
| `--dry-run`   | Show what would happen, make no changes (convert scripts only) |
| `--log FILE`  | Append all output to FILE in addition to the terminal          |
| `--jobs N`    | Convert N files in parallel (convert scripts only)             |
| `-h / --help` | Show full usage for that script                                |

All scripts print elapsed time in the final summary.
