# drupal-site

![Drupal](https://img.shields.io/badge/Drupal-11-0678BE?logo=drupal&logoColor=white)
![PHP](https://img.shields.io/badge/PHP-8.3-777BB4?logo=php&logoColor=white)
![MariaDB](https://img.shields.io/badge/MariaDB-11-003545?logo=mariadb&logoColor=white)
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

### Known limitation

Drupal isn't yet configured to trust the proxy, so it builds `http://` links
without the port. For example, `/user` redirects to
`http://drupal.rawhideron.duckdns.org/user/login`, so logging in through the
public URL doesn't work yet. Direct access on `WEB_PORT` is unaffected.

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
- `scripts/security-update.sh` — nightly security update run from the host's
  crontab (see [Automatic security updates](#automatic-security-updates))
