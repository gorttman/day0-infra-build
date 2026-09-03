#!/usr/bin/env python3
"""
Auto-tags Immich assets with Year and Location, derived from Immich's own
already-extracted EXIF data (exifInfo.dateTimeOriginal / exifInfo.city) - no
separate EXIF parsing needed, Immich already did that on import. Falls back
to Untagged/Date or Untagged/Location when the source data isn't there, so
nothing silently has no year/location tag without at least being flagged for
a manual look.

Needs: IMMICH_API_KEY, IMMICH_BASE_URL (e.g. https://immich.i3sec.com.au/api)
env vars. Generate the API key from the web UI - Account Settings > API Keys.

NOT YET LIVE-TESTED against a real Immich instance - verify against a small
batch before trusting it on anything real, same as everything else in this
project. Run with --dry-run first to see what it would do without applying
anything.
"""
import os
import sys
import argparse
import requests

BASE_URL = os.environ.get("IMMICH_BASE_URL", "").rstrip("/")
API_KEY = os.environ.get("IMMICH_API_KEY", "")

if not BASE_URL or not API_KEY:
    sys.exit("Set IMMICH_BASE_URL and IMMICH_API_KEY environment variables first.")

HEADERS = {"x-api-key": API_KEY, "Accept": "application/json"}


def get_all_assets():
    # There is no plain GET /assets listing endpoint in this deployed
    # version (v3.1.0, confirmed against the live server's own tagged
    # OpenAPI spec, not the GitHub main branch which is ahead of what's
    # actually running) - POST /search/metadata with an empty filter and
    # manual pagination is the real way to enumerate everything.
    results = []
    page = 1
    while True:
        resp = requests.post(
            f"{BASE_URL}/search/metadata",
            headers=HEADERS,
            json={"page": page},
            timeout=30,
        )
        resp.raise_for_status()
        body = resp.json()["assets"]
        results.extend(body["items"])
        if not body.get("nextPage"):
            break
        page = int(body["nextPage"])
    return results


def get_asset_detail(asset_id):
    resp = requests.get(f"{BASE_URL}/assets/{asset_id}", headers=HEADERS, timeout=30)
    resp.raise_for_status()
    return resp.json()


def list_tags():
    resp = requests.get(f"{BASE_URL}/tags", headers=HEADERS, timeout=30)
    resp.raise_for_status()
    return {t["name"]: t["id"] for t in resp.json()}


def create_tag(name):
    resp = requests.post(f"{BASE_URL}/tags", headers=HEADERS, json={"name": name}, timeout=30)
    resp.raise_for_status()
    return resp.json()["id"]


def get_or_create_tag_id(name, tag_cache):
    if name not in tag_cache:
        tag_cache[name] = create_tag(name)
    return tag_cache[name]


def already_has_prefix(asset_tags, prefix):
    return any(t["name"].startswith(prefix) for t in asset_tags)


def derive_year_tag(exif):
    dt = exif.get("dateTimeOriginal")
    if not dt:
        return "Untagged-Date"
    try:
        year = int(dt[:4])
        if 1900 <= year <= 2100:
            return str(year)
    except (ValueError, TypeError):
        pass
    return "Untagged-Date"


def derive_location_tag(exif):
    # Flat tag names only for now - the real API creates hierarchical tags
    # via a parentId reference (TagCreateDto), not by putting a "/" in the
    # name the way the web UI's own input box appears to parse it. Proper
    # parent/child chaining can be added later if wanted; not doing it here
    # to keep this first working version simple.
    city = exif.get("city")
    return city if city else "Untagged-Location"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Show what would be tagged without applying")
    parser.add_argument("--asset-ids", nargs="*", help="Specific asset IDs to process (default: all assets)")
    args = parser.parse_args()

    tag_cache = list_tags()
    assets = args.asset_ids if args.asset_ids else [a["id"] for a in get_all_assets()]

    print(f"Processing {len(assets)} asset(s){' (dry run)' if args.dry_run else ''}")

    pending_by_tag = {}  # tag_name -> [asset_id, ...]

    for asset_id in assets:
        detail = get_asset_detail(asset_id)
        existing_tags = detail.get("tags", [])
        exif = detail.get("exifInfo") or {}

        if not already_has_prefix(existing_tags, ("Untagged-Date", "19", "20")):
            year_tag = derive_year_tag(exif)
            pending_by_tag.setdefault(year_tag, []).append(asset_id)

        if not already_has_prefix(existing_tags, ("Untagged-Location",)) and not any(
            t["name"] == derive_location_tag(exif) for t in existing_tags
        ):
            loc_tag = derive_location_tag(exif)
            pending_by_tag.setdefault(loc_tag, []).append(asset_id)

    for tag_name, asset_ids in pending_by_tag.items():
        print(f"  {tag_name}: {len(asset_ids)} asset(s)")
        if not args.dry_run:
            tag_id = get_or_create_tag_id(tag_name, tag_cache)
            requests.put(
                f"{BASE_URL}/tags/assets",
                headers=HEADERS,
                json={"assetIds": asset_ids, "tagIds": [tag_id]},
                timeout=60,
            ).raise_for_status()

    print("Done." if not args.dry_run else "Dry run complete - nothing applied.")


if __name__ == "__main__":
    main()
