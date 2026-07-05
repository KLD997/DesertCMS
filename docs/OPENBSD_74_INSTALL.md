---
title: OpenBSD 7.4 Installation
summary: The supported OpenBSD 7.4 install path for DesertCMS, including plan-only review, dry-run output, packages, filesystem layout, httpd, desertcms_slowcgi, pf, TLS, GeoIP, workers, provider hooks, and validation.
audience: Technical
resource_type: Guide
tags: OpenBSD, install, operations
updated: 2026-07-05
access: Public
order: 120
---

# OpenBSD 7.4 Installation

OpenBSD 7.4 is the supported production target for DesertCMS.

The maintained installer handles the server-side setup work for the supported single-install model. It checks packages, creates accounts and directories, writes config, configures `pf`, `httpd`, the DesertCMS-owned `desertcms_slowcgi` service, TLS, provider routes, root workers, optional GeoIP import, database initialization, temporary admin creation, public rebuild, and production validation.

Do not use old provider-specific installation notes. The maintained installer is the source of truth for production setup.

## Before Installing

You need:

- OpenBSD 7.4 installed.
- A domain pointed at the server.
- `doas` access as an administrative user.
- The DesertCMS runtime bundle or source tree on the server.
- A planned public root name such as `example-site`.
- A decision about whether the installer should attempt DB-IP City Lite GeoIP refresh.

Provider secrets are not required for the base install. Configure Postmark, Stripe, service plans, blueprints, and contributor sites from MasterCMS after the server foundation is validated.

## Plan-Only Review

Use plan-only first when you want a non-mutating install report:

```sh
perl install/openbsd-install.pl --plan-only --domain example.com --public-root-name example-site
```

Plan-only prints the intended account, package, firewall, webserver, filesystem, route, worker, GeoIP, and validation work. When run off OpenBSD, it labels the current OS truthfully and leaves OpenBSD release detection for the target server.

## Dry Run On The Server

For command-level dry-run output on OpenBSD:

```sh
perl install/openbsd-install.pl --dry-run --domain example.com --public-root-name example-site
```

Dry-run prints commands without mutating the server. Review DNS, TLS, package, firewall, filesystem, provider route, and CMS initialization output before applying.

## Apply Install

After reviewing plan-only and dry-run output:

```sh
doas perl install/openbsd-install.pl --domain example.com --public-root-name example-site
```

The installer walks through:

- Server-admin setup.
- Package checks.
- Local asset checks.
- OpenBSD account and filesystem layout.
- `desertcms_slowcgi`, `httpd`, `pf`, and `acme-client`.
- Root worker cron entries.
- Config writing.
- Database initialization.
- Optional DB-IP City Lite GeoIP refresh.
- Temporary CMS admin creation.
- Public-site rebuild.
- Production validation.

The first CMS login is forced to choose a permanent username and password.

## Single-Install Coverage

A normal run configures:

- OpenBSD packages for Perl, SQLite, HTTPS email delivery, libvips media processing, local validation, and supporting tools.
- Application code, private data, private source assets, generated public files, backups, themes, upgrades, and font jobs.
- `desertcms_slowcgi`, `httpd`, `pf`, `acme-client`, `doas`, and root worker cron entries.
- Firewall rules with default deny, outbound state, SSH restricted to the admin allowlist, and public HTTP/HTTPS.
- Dynamic routing for Admin, Analytics, Forms, Shop / Catalog, Events, Directory, Bookings, Membership, Newsletter, Donations, Testimonials, comments, ratings, and checkout dispatch.
- Static generated output for pages, posts, media derivatives, Map / Locations, Showcase, Docs / Resource Hub, Resource Downloads, sitemap, robots, redirects, and navigation.
- Provider hook routes for Shop `/stripe/webhook`, hosted service billing `/billing/stripe/webhook`, Events `/events/stripe/webhook`, Bookings `/bookings/stripe/webhook`, Donations `/donate/stripe/webhook`, and tokenized Postmark bounce/spam hooks.
- Hosted SubCMS foundation: contributor site queue worker, generated per-site `httpd` routing, inherited master-provider config conventions, public-root ownership repair, and validator checks for hosted-site files, routes, and queue health.

## Required Packages

The installer checks packages such as:

```text
p5-DBI
p5-DBD-SQLite
p5-IO-Socket-SSL
p5-Net-SSLeay
libvips
p5-HTTP-Daemon
```

`libvips` is used for image derivative generation when available.

## Filesystem Layout

The normal layout is:

```text
/usr/local/www/desertcms/          application code
/etc/desertcms.conf                primary config
/var/desertcms/                    private data root
/var/desertcms/originals/          private source assets
/var/desertcms/backups/            backup archives
/var/desertcms/themes/             editable theme state
/var/desertcms/upgrades/           upgrade staging
/var/desertcms/font-packages/      OpenBSD font package worker state
/var/www/htdocs/example-site/      public static output
/var/www/acme/                     ACME challenge root
/var/www/run/desertcms.sock        slowcgi socket
```

The public webroot and private data directories must stay separate.

## httpd And desertcms_slowcgi

The supported deployment uses OpenBSD `httpd` with FastCGI forwarding to the DesertCMS-owned `desertcms_slowcgi` rc service. Manage `desertcms_slowcgi`, not the base `slowcgi` service.

The generated `httpd` configuration forwards Admin, Analytics, Comments, Ratings, Forms, Shop / Catalog, Stripe, Billing, Postmark, Events, Directory, Bookings, Members, Newsletter, Donations, Testimonials, provider hooks, and public dynamic routes through `desertcms_slowcgi`.

The installer writes FastCGI route blocks for:

```text
admin
analytics
comments
ratings
forms
shop
stripe
billing
postmark
events
directory
bookings
members
newsletter
donate
testimonials
```

It also sets request body limits for admin uploads:

```text
connection max request body 67108864
```

This supports uploads up to 64 MB unless a smaller plan upload limit applies.

After any `httpd` config change:

```sh
doas httpd -n
doas rcctl reload httpd
```

## TLS

The installer uses OpenBSD `acme-client` for certificates when requested and reuses existing certificates when present.

If DNS is not ready and TLS cannot be issued during the first run, the installer writes an HTTP-only DesertCMS `httpd` config that still forwards Admin, module, webhook, and public dynamic routes. Validation can warn that TLS is pending instead of failing the whole install for missing certificate files.

## GeoIP

The installer can import DB-IP City Lite data during the run. This gives Analytics local city-level enrichment without runtime external lookup calls.

To skip install-time network refresh:

```sh
doas perl install/openbsd-install.pl --domain example.com --public-root-name example-site --no-geoip-refresh
```

If install-time refresh fails because of network availability or upstream timing, the install continues. Refresh later:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl geoip-refresh-dbip-lite'
```

## First Login

The installer can create a temporary setup admin.

For a manual setup admin:

```sh
DESERTCMS_CONFIG=/etc/desertcms.conf perl bin/desertcms-maint.pl create-admin setup-admin
```

For a production handoff or lost first-login password:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl reset-admin setup-admin'
```

## Validation

The installer runs validation automatically after webserver config is in place. To run it manually:

```sh
doas perl /usr/local/www/desertcms/tools/openbsd-validate.pl --domain example.com
```

For an initial HTTP-only install while DNS or certificates are pending:

```sh
doas perl /usr/local/www/desertcms/tools/openbsd-validate.pl --domain example.com --allow-pending-tls
```

Validation checks:

- App root and executable files.
- Config and required directories.
- Database schema derived from the installed schema.
- Public root and generated public files.
- Local admin and theme assets.
- OpenBSD config syntax.
- `desertcms_slowcgi` and worker state.
- Dynamic module route forwarding.
- Provider webhook routing.
- Root worker cron entries.
- GeoIP import state.
- Reachable public/admin routes where possible.
- Hosted contributor site paths, routes, and queue health.

OpenBSD installation and provider activation are separate milestones. Missing Postmark sender/token/webhook token or Stripe webhook secrets are provider setup warnings, not proof that the base install failed. Those provider warnings mean the operator still needs to finish MasterCMS provider setup before enabling email sends, billing checkout, or site payments.

## Local Asset Audit

Before deployment or release packaging:

```sh
perl tools/check-local-assets.pl
```

Runtime admin and theme assets must be local. Core admin behavior should not depend on remote asset CDNs.

## Manual Recovery Commands

Useful service checks:

```sh
doas rcctl restart desertcms_slowcgi
doas httpd -n
doas rcctl reload httpd
```

Useful CMS commands:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl init-db'
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl rebuild'
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl backup'
```

To skip automatic validation during emergency recovery:

```sh
doas perl install/openbsd-install.pl --domain example.com --public-root-name example-site --no-post-install-validate
```

Run validation before treating the server as production-ready again.
