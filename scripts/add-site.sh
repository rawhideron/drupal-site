#!/usr/bin/env bash
# Add a new site to the Drupal multisite install.
#
# Usage: scripts/add-site.sh <name> <domain>
#   name    directory name under web/sites/ (letters, digits, underscores)
#   domain  hostname visitors will use to reach this site, e.g. blog.example.com
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <name> <domain>" >&2
    exit 1
fi

NAME="$1"
DOMAIN="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ ! -f .env ]; then
    echo ".env not found. Copy .env.example to .env first." >&2
    exit 1
fi
# shellcheck disable=SC1091
source .env

if [ -e "web/sites/${NAME}" ]; then
    echo "web/sites/${NAME} already exists, aborting." >&2
    exit 1
fi

if [ ! -f "web/sites/default/default.settings.php" ]; then
    echo "web/sites/default/default.settings.php not found." >&2
    echo "Run 'docker compose up -d' first so Composer can scaffold Drupal core." >&2
    exit 1
fi

DB_NAME_NEW="drupal_${NAME}"
DB_USER_NEW="drupal_${NAME}"
DB_PASS_NEW="$(openssl rand -hex 16)"
HASH_SALT_NEW="$(openssl rand -hex 32)"

echo "Creating web/sites/${NAME}..."
mkdir -p "web/sites/${NAME}/files" "web/sites/${NAME}/private"
cp "web/sites/default/default.settings.php" "web/sites/${NAME}/settings.php"

cat >> "web/sites/${NAME}/settings.php" <<PHP

\$databases['default']['default'] = [
  'database' => '${DB_NAME_NEW}',
  'username' => '${DB_USER_NEW}',
  'password' => '${DB_PASS_NEW}',
  'host' => 'db',
  'port' => '3306',
  'driver' => 'mysql',
  'prefix' => '',
];
\$settings['hash_salt'] = '${HASH_SALT_NEW}';
\$settings['file_private_path'] = 'sites/${NAME}/private';
PHP

docker compose exec -T --user root web chown www-data:www-data \
    "web/sites/${NAME}/files" "web/sites/${NAME}/private" "web/sites/${NAME}/settings.php" \
    || echo "Warning: could not chown web/sites/${NAME}/{files,private,settings.php} inside the web container; run it manually before installing (see README)." >&2

echo "Creating database ${DB_NAME_NEW}..."
docker compose exec -T db mariadb -uroot -p"${DB_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME_NEW}\`;
CREATE USER IF NOT EXISTS '${DB_USER_NEW}'@'%' IDENTIFIED BY '${DB_PASS_NEW}';
GRANT ALL PRIVILEGES ON \`${DB_NAME_NEW}\`.* TO '${DB_USER_NEW}'@'%';
FLUSH PRIVILEGES;
SQL

echo "Registering ${DOMAIN} -> ${NAME} in web/sites/sites.php..."
sed -i "/MULTISITE_MAP_START/a\\  '${DOMAIN}' => '${NAME}'," web/sites/sites.php

echo ""
echo "Site '${NAME}' is set up for domain '${DOMAIN}'."
echo "Finish the install with:"
echo "  docker compose exec --user www-data web drush site:install --sites-subdir=${NAME} -y"
echo ""
echo "Then make sure requests for '${DOMAIN}' reach this container (e.g. an /etc/hosts entry pointing at 127.0.0.1) and are sent with that Host header."
echo ""
echo "To log in without a password, always pass --uri so Drush knows the site's real URL:"
echo "  docker compose exec --user www-data web drush uli --uri=http://${DOMAIN}:${WEB_PORT:-8080}"
