#!/usr/bin/env bash
# Daily security update: composer update for Drupal packages, then run
# pending database updates and rebuild caches. Meant to be run from cron
# on the host (see `crontab -l`); logs everything to security-update.log.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

trap 'echo "!!!!! SECURITY UPDATE FAILED at $(date -Iseconds) !!!!!"' ERR

echo "=== $(date -Iseconds) ==="

if [ -z "$(docker compose ps --status running -q web)" ]; then
    echo "web container is not running, skipping."
    exit 0
fi

docker compose exec -T web composer update "drupal/*" --with-all-dependencies --no-interaction

# composer.json pins twig/twig ~3.29.0 (issue #5). If a newer core still shows
# as outdated right after the update, the pin is likely what's holding it back.
if grep -q '"twig/twig"' composer.json \
    && ! docker compose exec -T web composer outdated "drupal/core*" --direct --strict --no-interaction; then
    echo "WARNING: Drupal core update held back, likely by the Twig pin (issue #5)."
fi
docker compose exec -T --user www-data web drush updatedb -y
docker compose exec -T --user www-data web drush cache:rebuild

echo "Done."
