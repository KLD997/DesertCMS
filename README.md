# DesertCMS

![DesertCMS logo](public/assets/site/logo.png)

A small Perl CMS designed for OpenBSD `httpd`, `slowcgi`, SQLite, and static-first publishing.

The public site is served as generated files. The admin area is a Perl CGI app behind `httpd` FastCGI forwarding through `slowcgi`.

DesertCMS is formally hosted at [desertcms.com](https://desertcms.com/). The repository includes the same logo assets used by the hosted site under `public/assets/site/`.

## Current Status
Current local version: DesertCMS v1.17.114.

Release archives should be made available from `https://desertcms.com/download/` so the latest source and OpenBSD runtime bundle are easy to retrieve.

## Layout

```text
bin/                         executable CGI and maintenance scripts
lib/DesertCMS/               Perl modules
sql/schema.sql               SQLite schema
etc/                         OpenBSD configuration examples
docs/                        Site Management and Technical documentation
themes/default/              default public theme
admin/assets/                admin UI assets served by the CGI app
public/                      generated public site placeholder
t/                           local static checks and OpenBSD Perl tests
```

## OpenBSD Quick Start

See [docs/OPENBSD_74_INSTALL.md](docs/OPENBSD_74_INSTALL.md). For architecture, modules, operations, provider integrations, and site-management workflows, start at [docs/TECHNICAL_ARCHITECTURE.md](docs/TECHNICAL_ARCHITECTURE.md) and [docs/SITE_OWNER_GUIDE.md](docs/SITE_OWNER_GUIDE.md).

For a fresh OpenBSD 7.4 server:

```sh
perl install/openbsd-install.pl --dry-run --domain example.com --public-root-name example-site
doas perl install/openbsd-install.pl
```

Run the dry-run first. It performs read-only checks, prints the exact package, firewall, httpd, DNS, TLS, user, filesystem, and CMS initialization steps, and does not apply system changes. The real installer then walks through server-admin creation, public root naming under `/var/www/htdocs`, required packages, local asset checks, OpenBSD `pf`, `httpd`, `acme-client`, the DesertCMS `desertcms_slowcgi` service, filesystem layout, DNS verification, database initialization, public-site build, temporary CMS admin creation, and production validation. The temporary CMS login is forced to choose a permanent username and password on first use.

For manual setup, the high-level commands are:

```sh
pkg_add p5-DBI p5-DBD-SQLite p5-IO-Socket-SSL p5-Net-SSLeay libvips p5-HTTP-Daemon
install -d -o _desertcms -g _desertcms /var/desertcms /var/desertcms/backups /var/desertcms/originals /var/desertcms/themes /var/desertcms/upgrades
install -d -o _desertcms -g _desertcms /var/www/htdocs/desertcms-site
cp etc/desertcms.conf.example /etc/desertcms.conf
DESERTCMS_CONFIG=/etc/desertcms.conf perl bin/desertcms-maint.pl init-db
DESERTCMS_CONFIG=/etc/desertcms.conf perl bin/desertcms-maint.pl create-admin setup-admin
install -o root -g wheel -m 555 etc/rc.d/desertcms_slowcgi /etc/rc.d/desertcms_slowcgi
rcctl enable desertcms_slowcgi
rcctl start desertcms_slowcgi
httpd -n
rcctl reload httpd
```

For a production handoff or lost first-login password, rotate recovery owner access and force a new first-login setup:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl reset-admin setup-admin'
```

Runtime admin and theme assets are local. Verify before deployment with:

```sh
perl tools/check-local-assets.pl
```

Production `httpd` must allow large admin uploads. The installer and example config set `connection max request body 67108864`, which supports private source asset uploads up to 64 MB. Contributor service plans can set a smaller or larger per-file media upload limit, but the effective upload size is still capped by the deployment's configured request-body limit. Images publish optimized derivatives automatically; documents, data files, audio, video, and resource files stay private until an admin explicitly publishes a public resource copy. For hosted contributor sites, that Resource Downloads publishing workflow is plan-gated.

Owner accounts can upgrade an installed OpenBSD deployment from Admin Settings > Upgrade DesertCMS by uploading the latest runtime `.tar.gz` release. The admin app stages the archive, and the root upgrade worker backs up and applies it. Existing servers should install the worker once:

```sh
doas perl /usr/local/www/desertcms/tools/openbsd-apply-upgrade.pl --install-cron
```

Analytics locations are resolved from a local GeoIP database, not a runtime external API. After copying a licensed city CSV/TSV into `/var/desertcms`, import and backfill with:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl geoip-import /var/desertcms/geoip.tsv'
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl geoip-backfill'
```

Use `geoip-import --append ...` when adding a second range file, such as separate IPv6 city blocks.

For a launch-ready free city database, use the bundled DB-IP City Lite refresh command. It downloads the current monthly CSV, imports city/state/country ranges locally, and backfills existing analytics rows:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl geoip-refresh-dbip-lite'
```

DB-IP Lite data requires attribution where results are displayed; Admin > Analytics adds this attribution automatically when the DB-IP source is imported.

Shop / Catalog is a first-party feature served from the main site at `/shop`. The `shop` entitlement enables public product, service, digital, portfolio, media, and inquiry listings. The separate `shop_payments` entitlement unlocks Stripe Checkout, marketplace payouts, platform fees, and rights-purchase controls. It uses the CMS config, database, uploaded media records, and public optimized derivatives. Configure Stripe in `/etc/desertcms.conf` when checkout is enabled:

```text
module_shop_enabled = 1
commerce_model = master_owned
shop_enabled = 1
shop_require_purchase_token = 1
stripe_secret_key = <stripe secret key>
stripe_webhook_secret = <stripe webhook secret>
```

In the admin, use **Settings > Modules > Shop / Catalog** to manage catalog settings, listings, payments, and orders. `master_owned` and `contributor_owned` use direct Stripe Checkout and webhook fulfillment. `platform_marketplace` uses the master Stripe account with a contributor connected account and platform fee. `marketplace_pending` remains a disabled planning state. Full-rights webhook fulfillment removes the listing from sale. Private source files remain private.

Catalog-only plans can publish active listings without prices. Those listings show their type label and inquiry CTA instead of buy buttons. Checkout POSTs are rejected until `shop_payments` is included and checkout readiness passes.

Membership / Gated Content is a first-party dynamic portal at `/members/`. The `membership` entitlement enables member accounts, optional public signup, invites, groups, private pages/posts, member-only docs, and authenticated private source downloads. The separate `membership_payments` entitlement is reserved for paid member resources, subscription records, Stripe Checkout, marketplace payouts, and platform fees.

Newsletter is a first-party public signup and digest surface at `/newsletter/`. The `newsletter` entitlement enables subscriber capture, tags and segments, unsubscribe links, CSV export, announcement drafts, digest generation from recent posts, Events, Directory entries, and Shop / Catalog listings, plus Postmark readiness-gated sends and send history. Subscriber capture and export remain available even when Postmark is not ready.

Donations / Fundraising is a first-party campaign surface at `/donate/`. The `donations` entitlement enables public campaign pages, suggested and custom amounts, donor messages, goal progress, and donor CSV export. The separate `donation_payments` entitlement unlocks Stripe Checkout, webhook fulfillment, contributor marketplace payouts, and platform fees for donations. Donation records and Stripe webhook idempotency are separate from Shop orders, Event tickets, Booking deposits, Membership payments, and service billing.

Testimonials / Reviews is a first-party trust surface at `/testimonials/`. The `testimonials` entitlement enables approved public testimonials, optional ratings, related Directory or Bookings links, moderated public submissions, static output, sitemap entries, and CSV export. Testimonials do not have a Stripe entitlement; they are a content/review feature, not a payment surface.

Members-only and group-only content is not generated into the public static site. It is served through `/members/content/<slug>` after session and group checks. Private content remains hidden from both public output and member dashboards.

After a production install on OpenBSD, run:

```sh
doas perl /usr/local/www/desertcms/tools/openbsd-validate.pl --domain example.com
```

## Local Development Note

This repository targets OpenBSD. A Windows workstation without Perl, SQLite, and libvips can still edit the code, but runtime checks should be run with Perl, DBI, DBD::SQLite, `tar`, and a supported local image processor installed.

For this workspace, portable Strawberry Perl and ImageMagick are installed under `.tools/` for local test compatibility, which is intentionally ignored by Git. Use:

```powershell
.\tools\perl.cmd -Ilib t\01_syntax.t
```

## License

DesertCMS is released under the BSD 2-Clause License. See [LICENSE](LICENSE).
