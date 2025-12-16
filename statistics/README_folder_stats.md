# Folder Stats Helper

`folder_stats.sh` is a minimal inspection tool: it walks a target directory, prints cumulative sizes for each subdirectory, and lists the largest files so you know where space is going before running any optimizers.

```
./tools/folder_stats.sh /mnt/usb/Photos --depth 3 --top-files 100
```

## What it shows

1. `du -h` output sorted by size up to the requested depth (default depth 2). Useful to spot which subfolders deserve attention.
2. The largest files (default top 50) with human‑readable sizes, letting you quickly identify outliers.

No files are modified; the script only reads metadata.

## Options

- `--depth N` or `FOLDER_STATS_DEPTH=N` — limit how deep the directory summary goes.
- `--top-files K` or `FOLDER_STATS_TOP_FILES=K` — how many of the biggest files to display.
- `-h/--help` — usage info.

## Requirements

The script relies on core utilities available on any Linux distro (`du`, `find`, `sort`, `awk`). No extra packages needed.

## Suggested Workflow

1. Run `folder_stats.sh` on your external drive to understand which folders consume the most space.
2. Use that insight to decide where to run `personal_media_optimize.sh` or other scripts.
3. Re-run later to verify the biggest folders/files changed as expected.
