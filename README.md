# drupal-site

![Drupal](https://img.shields.io/badge/Drupal-11-0678BE?logo=drupal&logoColor=white)
![PHP](https://img.shields.io/badge/PHP-8.3-777BB4?logo=php&logoColor=white)
![Apache](https://img.shields.io/badge/Apache-2.4-D22128?logo=apache&logoColor=white)
![MariaDB](https://img.shields.io/badge/MariaDB-11-003545?logo=mariadb&logoColor=white)
![Nginx Proxy Manager](https://img.shields.io/badge/Nginx%20Proxy%20Manager-2-F15833?logo=nginxproxymanager&logoColor=white)
![License](https://img.shields.io/badge/license-GPL--2.0--or--later-blue)

Dockerized Drupal 11 with multisite support: one codebase/container stack, and
the ability to add more sites (each with its own database) without spinning
up new containers.

## Prerequisites

- Docker
- The `docker compose` CLI plugin (v2) — commands below assume `docker compose`,
  not the older standalone `docker-compose` (v1) binary, which has known bugs
  rebuilding containers

## First run

```bash
cp .env.example .env
# edit .env: set real passwords and a HASH_SALT (openssl rand -hex 32)

docker compose up -d --build
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
docker compose exec --user www-data web drush site:install -y
```

`settings.php` is gitignored: Drupal's installer requires it to be writable
and rewrites it with the resolved (literal) DB credentials during install,
so it can't stay a clean, secret-free file once a site is actually installed.
The committed template is what's used to (re)create it.

Then visit http://localhost:8080 (or whatever `WEB_PORT` you set), and log in
as the admin user with a one-time link instead of a password you'd have to
remember. Pass `--uri` (matching `WEB_PORT`) so the printed link is directly
clickable — without it, Drush doesn't know what host/port you're using and
prints a placeholder you'd have to edit by hand:

```bash
docker compose exec --user www-data web drush uli --uri=http://localhost:8080
```

## Adding another site

Each additional site gets its own directory under `web/sites/` and its own
database in the same `db` container, sharing Drupal core and modules with
the default site.

```bash
scripts/add-site.sh blog blog.example.com
docker compose exec --user www-data web drush site:install --sites-subdir=blog -y
```

The script prints the generated DB credentials and finishes by registering
`blog.example.com -> web/sites/blog` in `web/sites/sites.php`.

To reach the new site locally, point the domain at this machine (e.g. add
`127.0.0.1 blog.example.com` to `/etc/hosts`) and browse to
`http://blog.example.com:8080`.

## Public access via Nginx Proxy Manager

The `npm` service ([Nginx Proxy Manager](https://nginxproxymanager.com/))
fronts the sites with HTTPS and a Let's Encrypt certificate. Ports 80/443 on
this host belong to another service (a kind cluster), so NPM is published on
non-standard ports instead:

| Host port | Purpose                                                        |
|-----------|----------------------------------------------------------------|
| 8443      | HTTPS, forwarded from the router                               |
| 8880      | HTTP (not forwarded; only used locally)                        |
| 81        | NPM admin UI, bound to `127.0.0.1` only (`http://localhost:81`) |

The admin UI is deliberately not exposed on the LAN or the internet. If your
router has a stale forwarding rule for external port 81, it can't reach it.

Sites are reached at:

- `https://drupal.rawhideron.duckdns.org:8443` (default site)
- `https://umami.drupal.rawhideron.duckdns.org:8443` (`umami` site)

The `:8443` is required, since 443 isn't available. `umami.drupal.…` is mapped
to the `umami` site in `web/sites/sites.php`; `drupal.…` falls through to the
default site.

### Router

Add one port-forwarding rule: external **8443** → this host's **8443**
(TCP), then click *Apply Changes*. Leave the existing 80/443 rules alone.
Certificates are issued with the DuckDNS DNS challenge, so port 80 isn't
needed.

Many home routers won't loop a request for your own public IP back into the
LAN. Test the public URLs from outside your network (e.g. a phone on cellular).

### One-time NPM setup

NPM's configuration lives in the `npm_data` and `npm_letsencrypt` volumes, not
in git, so on a fresh install do this in the UI at `http://localhost:81`:

1. **Log in** with `admin@example.com` / `changeme` and change both. Use a
   real email: Let's Encrypt rejects `example.com` addresses, which shows up
   as an "Internal Error" when requesting a certificate.
2. **SSL Certificates → Add → Let's Encrypt via DNS**: domains
   `drupal.rawhideron.duckdns.org` and `*.drupal.rawhideron.duckdns.org`,
   DNS provider **DuckDNS**, credentials `dns_duckdns_token=<your token>`.
   Renewals reuse the token stored here; if you regenerate it at duckdns.org,
   update it on the certificate.
3. **Proxy Hosts → Add**: domain names `drupal.rawhideron.duckdns.org` and
   `umami.drupal.rawhideron.duckdns.org`, scheme `http`, forward host `web`,
   port `80`, *Block Common Exploits* on. On the SSL tab pick the certificate.
   Leave **Force SSL** and **HSTS** off: Force SSL redirects to port 443,
   which isn't this proxy.

If a newly saved proxy host still serves NPM's "Default Site" page, reload
nginx in the container: `docker compose exec npm nginx -s reload`.

### How Drupal knows it's behind HTTPS

NPM forwards requests to `web` over plain HTTP, so two pieces make Drupal
build `https://host:8443` URLs (otherwise a login redirects to
`http://host/user/login`, which the router sends to the other service on
80/443):

- `docker/proxy-https.settings.php` is included from every site's
  `settings.php` (the default-site template and `scripts/add-site.sh` add the
  line for new sites). It sets Drupal's `reverse_proxy` settings so requests
  from private-subnet peers (i.e. NPM) are trusted for `X-Forwarded-Proto` and
  `X-Forwarded-Port`. Requests straight to `WEB_PORT` are unaffected.
- `docker/npm/proxy.conf` is a copy of NPM's own `proxy.conf` with one added
  line, `proxy_set_header X-Forwarded-Port 8443;`, mounted over the original.
  NPM can't infer the port itself because it sees 443 inside the container.

Notes:
- The existing `settings.php` files are gitignored, so on a machine that
  already has sites add
  `include $app_root . '/../docker/proxy-https.settings.php';` to the end of
  each one (they're read-only and owned by `www-data`; edit them via
  `docker compose exec --user www-data web ...`).
- The `proxy.conf` mount must not be read-only: NPM `chown`s it at startup and
  fails to start otherwise. The file is root-owned for the same reason, so edit
  it with `sudo`, then `docker compose restart npm`.
- It's a snapshot of the upstream file. If you upgrade NPM, diff it against
  `docker run --rm --entrypoint cat jc21/nginx-proxy-manager:latest /etc/nginx/conf.d/include/proxy.conf`
  and carry over any upstream changes.
- The port is hard-coded to 8443 in both places. If you change the published
  HTTPS port, change both.

## Automatic security updates

`scripts/security-update.sh` applies security updates and is meant to run
nightly from the **host's** crontab (the schedule isn't stored in the repo):

```cron
0 3 * * * /home/rongoodman/Projects/drupal-temp/scripts/security-update.sh >> /home/rongoodman/Projects/drupal-temp/security-update.log 2>&1
```

Each run, inside the `web` container:

1. `composer update "drupal/*" --with-all-dependencies` (only Drupal packages;
   this rewrites `composer.lock`)
2. `drush updatedb -y` (pending database updates for every site)
3. `drush cache:rebuild`

If the `web` container isn't running, the script logs that and exits without
doing anything. On failure it prints `!!!!! SECURITY UPDATE FAILED … !!!!!`.
Output goes to `security-update.log` (gitignored). Check it with
`tail security-update.log`, and review any change to `composer.lock` before
committing it. To install the job on a new machine, add the line above with
`crontab -e`, adjusting the path.

## Importing photos from the USB drive

`scripts/import-images.sh` copies the JPG/PNG/GIF files from the Samsung USB
drive's `Disk1Pictures` and `Disk2Pictures` folders into a single folder,
`web/sites/default/files/photos/`, served at
`/sites/default/files/photos/<file>`:

```bash
scripts/import-images.sh                                  # both folders, drive at /media/$USER/Samsung USB
scripts/import-images.sh "/media/$USER/Samsung USB" Disk1Pictures Disk2Pictures   # other root / folders
```

- Folders are processed in the order given. The first keeps its file names; in
  later ones, a file whose name is already taken (case-insensitive) gets the
  folder label added before the extension. 37 of the `Disk2Pictures` files
  collide with `Disk1Pictures` (different photos, same camera-assigned name),
  so `Disk2Pictures/DSC00003.JPG` becomes `DSC00003_Disk2.JPG`.
- Renaming depends only on the drive's contents, so re-running is safe: files
  already copied are skipped, and it never deletes anything. Keep the folder
  order the same between runs, or names could map differently.
- Files are written inside the `web` container as `www-data` (the `files`
  directory isn't writable by the host user). The `web` container must be running.
- This only copies files. To make them show up in Drupal's Media library, run
  the next step.

### Registering the photos as Media

```bash
docker compose exec -T --user www-data web drush php:script scripts/import-media.php
```

`scripts/import-media.php` creates a File entity and an Image Media entity for
every file in `photos/`:

- **Name and alt text** are the file name without its extension (e.g.
  `DSC00003_Disk2`). The alt text is only a placeholder, since the image media
  type requires one; replace it with real descriptions in the Media library.
- **Created date** is the photo's EXIF capture date (the file dates on the
  drive are mostly the 2020-12-31 copy date). Two files with no EXIF
  (`cross_country.jpeg`, `Copy of image001.png`) fall back to the file date.
  This needs PHP's `exif` extension, which the `Dockerfile` installs.
- Re-running is safe: files that already have a Media entity are skipped. It
  never deletes anything. To undo, delete the Media entities in the admin UI
  (`/admin/content/media`).
- **Cleaning up deleted photos:** by default Drupal keeps a file after its Media
  is deleted. This site turns on `make_unused_managed_files_temporary`, so an
  unused file is marked temporary and removed from disk by cron once it is over
  6 hours old (`automated_cron` runs every 3 hours, on page visits, so expect
  6-9+ hours). Re-adding the same file before then makes it permanent again.
  The setting lives in the database, not in git, so on a fresh install run:

  ```bash
  docker compose exec -T --user www-data web drush config:set file.settings make_unused_managed_files_temporary true -y
  ```

  Don't re-run the import expecting a deleted photo to stay gone while its file
  is still on disk: it will create the Media again.

## Useful commands

```bash
docker compose exec --user www-data web drush status          # check bootstrap for the default site
docker compose exec --user www-data web drush --uri=http://blog.example.com:8080 status
docker compose exec --user www-data web drush uli --uri=http://localhost:8080            # one-time admin login link, default site
docker compose exec --user www-data web drush uli --uri=http://blog.example.com:8080     # same, for another site
docker compose exec --user www-data web drush user:password admin 'newpass' # set a real password instead, if you want one
docker compose logs -f web
docker compose down                                            # stop (add -v to also wipe the DB volume)
```

## Layout

- `Dockerfile` / `docker/entrypoint.sh` — PHP 8.3 + Apache image, runs Composer
  install and waits for the DB on container start
- `docker-compose.yml` — `web` (app), `db` (MariaDB), and `npm` (Nginx Proxy
  Manager) services
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
- `docker/proxy-https.settings.php` / `docker/npm/proxy.conf` — make Drupal
  generate `https://…:8443` URLs behind NPM (see
  [How Drupal knows it's behind HTTPS](#how-drupal-knows-its-behind-https))
- `scripts/security-update.sh` — nightly security update run from the host's
  crontab (see [Automatic security updates](#automatic-security-updates))
