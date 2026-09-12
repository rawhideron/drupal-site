# drupal-site

Dockerized Drupal 11 with multisite support: one codebase/container stack, and
the ability to add more sites (each with its own database) without spinning
up new containers.

## Prerequisites

- Docker
- `docker-compose` (the standalone binary) or the `docker compose` plugin

## First run

```bash
cp .env.example .env
# edit .env: set real passwords and a HASH_SALT (openssl rand -hex 32)

docker-compose up -d --build
```

On first start, the `web` container waits for the database, runs
`composer install` inside itself to scaffold Drupal core into `web/` on your
host (the code lands on your host filesystem via the bind mount, so it
survives rebuilds and is editable locally), and seeds
`web/sites/default/settings.php` from `docker/settings.default.php.tpl`. This
can take a few minutes the first time.

Once it's up, install the default site (run as `www-data`, not root, so
Drupal — and any files it creates — don't end up root-owned on your host):

```bash
docker-compose exec --user www-data web drush site:install --account-pass=admin -y
```

`settings.php` is gitignored: Drupal's installer requires it to be writable
and rewrites it with the resolved (literal) DB credentials during install,
so it can't stay a clean, secret-free file once a site is actually installed.
The committed template is what's used to (re)create it.

Then visit http://localhost:8080 (or whatever `WEB_PORT` you set).

## Adding another site

Each additional site gets its own directory under `web/sites/` and its own
database in the same `db` container, sharing Drupal core and modules with
the default site.

```bash
scripts/add-site.sh blog blog.example.com
docker-compose exec --user www-data web drush site:install --sites-subdir=blog -y
```

The script prints the generated DB credentials and finishes by registering
`blog.example.com -> web/sites/blog` in `web/sites/sites.php`.

To reach the new site locally, point the domain at this machine (e.g. add
`127.0.0.1 blog.example.com` to `/etc/hosts`) and browse to
`http://blog.example.com:8080`.

## Useful commands

```bash
docker-compose exec --user www-data web drush status          # check bootstrap for the default site
docker-compose exec --user www-data web drush --uri=blog.example.com status
docker-compose logs -f web
docker-compose down                                            # stop (add -v to also wipe the DB volume)
```

## Layout

- `Dockerfile` / `docker/entrypoint.sh` — PHP 8.3 + Apache image, runs Composer
  install and waits for the DB on container start
- `docker-compose.yml` — `web` (app) + `db` (MariaDB) services
- `composer.json` — Drupal 11 project definition (`drupal/recommended-project`
  equivalent); `web/core`, `vendor/`, and contrib modules are Composer-managed
  and gitignored
- `docker/settings.default.php.tpl` — template for the default site's
  `settings.php`, reads DB config from environment variables; copied into
  place on first container start (the resulting `web/sites/*/settings.php`
  files are gitignored, not this template)
- `web/sites/sites.php` — hostname → site-directory map, maintained by
  `scripts/add-site.sh`
- `scripts/add-site.sh` — scaffolds a new site directory + database
