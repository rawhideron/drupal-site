#!/usr/bin/env bash
# Copy photo folders from the Samsung USB drive into ONE Drupal public files
# folder: web/sites/default/files/photos/
#
# Folders are processed in the order given. The first folder keeps its file
# names; in later folders, any file whose name is already taken (case-
# insensitive) by an earlier file is renamed by adding the folder's label
# before the extension, e.g. Disk2Pictures/DSC00003.JPG -> DSC00003_Disk2.JPG.
# Renaming depends only on the drive's contents, never on what is already in
# Drupal, so the mapping is the same on every run.
#
# Safe to re-run: files already present at the destination are skipped, and
# nothing is ever deleted. Files are written inside the web container as
# www-data, since the files directory is owned by that user.
#
# Usage: scripts/import-images.sh [SOURCE_ROOT] [FOLDER...]
#   SOURCE_ROOT  default: "/media/$USER/Samsung USB"
#   FOLDER...    default: Disk1Pictures Disk2Pictures
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SRC_ROOT="${1:-/media/$USER/Samsung USB}"
shift || true
FOLDERS=("$@")
[ ${#FOLDERS[@]} -gt 0 ] || FOLDERS=(Disk1Pictures Disk2Pictures)

DEST="/opt/drupal/web/sites/default/files/photos"

if [ -z "$(docker compose ps --status running -q web)" ]; then
    echo "web container is not running." >&2
    exit 1
fi

# Stage symlinks named with their final file names, then tar them
# (dereferencing) so no photo data is copied twice on the host.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

declare -A taken   # lowercased final name -> 1
total=0
renamed=0

for folder in "${FOLDERS[@]}"; do
    src="$SRC_ROOT/$folder"
    if [ ! -d "$src" ]; then
        echo "Missing source folder: $src" >&2
        exit 1
    fi
    label="${folder%Pictures}"

    # Image files only, top level of the folder; skips Thumbs.db and stray
    # subfolders (Disk1Pictures contains an empty "Disk3Video" directory).
    while IFS= read -r -d '' path; do
        name="${path##*/}"
        final="$name"
        if [ -n "${taken[${final,,}]:-}" ]; then
            base="${name%.*}"
            ext="${name##*.}"
            final="${base}_${label}.${ext}"
            n=2
            while [ -n "${taken[${final,,}]:-}" ]; do
                final="${base}_${label}_${n}.${ext}"
                n=$((n + 1))
            done
            echo "renamed: $folder/$name -> $final"
            renamed=$((renamed + 1))
        fi
        taken[${final,,}]=1
        ln -s "$path" "$STAGE/$final"
        total=$((total + 1))
    done < <(find "$src" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' \) \
        -print0 | sort -z)
done

docker compose exec -T --user www-data web mkdir -p "$DEST"

tar -C "$STAGE" -hcf - . \
  | docker compose exec -T --user www-data web tar -C "$DEST" --skip-old-files -xf -

dest_count=$(docker compose exec -T web sh -c "find '$DEST' -maxdepth 1 -type f | wc -l")
echo "$total photos on drive ($renamed renamed), $dest_count files in Drupal photos/"
echo "Done. Files are at /sites/default/files/photos/ on the site."
