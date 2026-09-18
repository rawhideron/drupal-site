#!/bin/sh
set -e

echo "Waiting for database at ${DB_HOST:-db}:${DB_PORT:-3306}..."
until php -r "new PDO('mysql:host=${DB_HOST:-db};port=${DB_PORT:-3306}', getenv('DB_USER'), getenv('DB_PASSWORD'));" 2>/dev/null; do
    sleep 2
done
echo "Database is up."

# The bind-mounted /opt/drupal is owned by the host user, not root (who runs
# this entrypoint and, by default, composer exec'd into the container), so
# git refuses to touch it as an "unsafe" repo without this.
git config --global --get-all safe.directory 2>/dev/null | grep -qx /opt/drupal \
    || git config --global --add safe.directory /opt/drupal

if [ ! -d /opt/drupal/vendor ]; then
    echo "Installing Drupal via Composer (first run, this can take a few minutes)..."
    composer install --no-interaction --no-progress
fi

# settings.php is gitignored (it ends up holding resolved DB credentials
# once Drupal's installer runs, since site:install requires it to be
# writable). Seed it from the committed template on first run only.
if [ ! -f /opt/drupal/web/sites/default/settings.php ]; then
    cp /opt/drupal/docker/settings.default.php.tpl /opt/drupal/web/sites/default/settings.php
fi

# Only the things Drupal itself needs to write need to be owned by the
# web server user (files/private dirs, and settings.php during install);
# the rest of the bind-mounted tree stays owned by whoever owns it on
# the host so it's still editable there.
for site_dir in /opt/drupal/web/sites/*/; do
    mkdir -p "${site_dir}files" "${site_dir}private"
    chown www-data:www-data "${site_dir}files" "${site_dir}private"
    [ -f "${site_dir}settings.php" ] && chown www-data:www-data "${site_dir}settings.php"
done

exec "$@"
