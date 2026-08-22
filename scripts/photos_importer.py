#!/usr/bin/env python3
"""
Consolidates a staged batch of photos/videos into the Immich-watched
/photos library, sorted into <EXIF-year>/ folders, deduped by content
hash against everything already in the library.

This is the reusable tool described (but never previously committed as
code) in project_immich_photo_workflow_design.md's "consolidation
method" - proven by hand once against the 2012 backlog folder:
  1917 source -> 1525 survivors -> 1520 in Immich (5 .AVI Immich skips)

Usage:
  python3 photos_importer.py --staging /staging --library /library [--dry-run]

Requires exiftool on PATH - it handles JPEG/RAW (CR2, DNG)/TIFF/HEIC/
MP4/MOV metadata consistently. No single Python library covers all of
those formats reliably, which is why this shells out rather than using
Pillow/exifread.

Method (order matters - do not reorder without rereading the memory
doc this implements):
  1. Hash every file in staging (SHA-256).
  2. Build a hash index of everything already under --library, so a
     re-run (or a file that snuck in some other way) is never
     re-imported as a second copy.
  3. For each staging file NOT already present by hash:
     a. Read EXIF DateTimeOriginal (photos) / CreateDate /
        MediaCreateDate (video) via `exiftool -j`.
     b. Fall back to file mtime if no EXIF date is found - flagged in
        the manifest as year_source=mtime_fallback, since folder names
        and mtimes are both known-unreliable signals on this backlog
        (an iPhone-6 photo was found filed under a "2012" folder).
     c. Move (not copy) into <library>/<year>/<original filename>,
        resolving a same-name collision by appending the content
        hash's first 8 hex chars rather than skipping or overwriting.
  4. For each staging file that IS a duplicate of something already in
     the library: delete it from staging. Staging is meant to be
     transient, never a second permanent copy - the real survivor
     already exists in the library.
  5. Write a manifest (JSON) to <library>/.consolidation/<run-id>.json
     recording every decision, so nothing here is a silent guess.

Deliberately makes no Immich API calls - foldering must happen BEFORE
tagging (moving/re-filing an asset already tagged in Immich orphans
the tag, since Immich tracks external-library assets by path). Run
order is: this script -> library scan -> immich_auto_tag.py.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

CHUNK = 1024 * 1024
IGNORED_LIBRARY_DIRS = {".consolidation"}


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def build_hash_index(root):
    index = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_LIBRARY_DIRS]
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            index[sha256_of(fpath)] = fpath
    return index


def exif_year(path):
    try:
        out = subprocess.run(
            ["exiftool", "-j", "-DateTimeOriginal", "-CreateDate", "-MediaCreateDate", path],
            capture_output=True, text=True, timeout=60, check=True,
        ).stdout
        data = json.loads(out)[0]
    except (subprocess.SubprocessError, json.JSONDecodeError, IndexError, OSError):
        return None
    this_year = time.localtime().tm_year
    for key in ("DateTimeOriginal", "CreateDate", "MediaCreateDate"):
        val = data.get(key)
        if val and len(val) >= 4 and val[:4].isdigit():
            year = int(val[:4])
            if 1990 <= year <= this_year:
                return year
    return None


def mtime_year(path):
    return time.localtime(os.path.getmtime(path)).tm_year


def unique_dest(dest_dir, fname, content_hash):
    dest = os.path.join(dest_dir, fname)
    if not os.path.exists(dest):
        return dest
    stem, ext = os.path.splitext(fname)
    return os.path.join(dest_dir, f"{stem}-{content_hash[:8]}{ext}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--staging", required=True)
    ap.add_argument("--library", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if shutil.which("exiftool") is None:
        sys.exit("exiftool not found on PATH - install libimage-exiftool-perl first")

    run_id = time.strftime("%Y%m%dT%H%M%S")
    manifest = {
        "run_id": run_id,
        "staging": args.staging,
        "library": args.library,
        "dry_run": args.dry_run,
        "entries": [],
    }

    staging_files = []
    for dirpath, _dirnames, filenames in os.walk(args.staging):
        for fname in filenames:
            staging_files.append(os.path.join(dirpath, fname))

    print(f"[{run_id}] {len(staging_files)} files in staging, building library hash index...", flush=True)
    existing = build_hash_index(args.library)
    print(f"[{run_id}] {len(existing)} unique files already in library", flush=True)

    moved = 0
    skipped_dupe = 0
    for src in staging_files:
        h = sha256_of(src)
        fname = os.path.basename(src)

        if h in existing:
            manifest["entries"].append({
                "source": src, "sha256": h, "action": "skipped_duplicate",
                "duplicate_of": existing[h],
            })
            skipped_dupe += 1
            if not args.dry_run:
                os.remove(src)
            continue

        year = exif_year(src)
        year_source = "exif"
        if year is None:
            year = mtime_year(src)
            year_source = "mtime_fallback"

        dest_dir = os.path.join(args.library, str(year))
        dest = unique_dest(dest_dir, fname, h)

        manifest["entries"].append({
            "source": src, "sha256": h, "action": "moved",
            "dest": dest, "year": year, "year_source": year_source,
        })
        moved += 1

        if not args.dry_run:
            os.makedirs(dest_dir, exist_ok=True)
            shutil.move(src, dest)

        # Register in the in-memory index too, in case staging itself
        # has internal duplicates beyond what inbox-router already
        # caught (belt and suspenders, cheap to check).
        existing[h] = dest

    if not args.dry_run:
        manifest_dir = os.path.join(args.library, ".consolidation")
        os.makedirs(manifest_dir, exist_ok=True)
        with open(os.path.join(manifest_dir, f"{run_id}.json"), "w") as f:
            json.dump(manifest, f, indent=2)

    print(
        f"[{run_id}] done: {moved} moved, {skipped_dupe} duplicates skipped"
        + (" (dry-run, nothing written)" if args.dry_run else ""),
        flush=True,
    )


if __name__ == "__main__":
    main()
