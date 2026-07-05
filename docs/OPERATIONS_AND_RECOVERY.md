---
title: Operations And Recovery
summary: Technical operating guidance for rebuilds, backups, restore tests, root workers, upgrades, rollbacks, validation, media maintenance, GeoIP refresh, support bundles, and contributor-site recovery.
audience: Technical
resource_type: Reference
tags: operations, recovery, upgrades
updated: 2026-07-05
access: Public
order: 130
---

# Operations And Recovery

Operations are master-side responsibilities. Contributor SubCMS users should see site status and support guidance, not root-worker commands.

## Operating Rules

Use these rules before touching production:

- Keep private data directories separate from public roots.
- Run app maintenance as `_desertcms` unless a tool explicitly requires root.
- Run root workers through `doas`.
- Validate `httpd` syntax before reloads.
- Rebuild public output after docs, theme, content, module, or plan changes that affect generated pages.
- Pair local tests with live HTTP checks after deployment.
- Do not expose provider secrets or private source assets in support output.

## Rebuilds

A rebuild regenerates public artifacts from the database and settings.

It can write:

- Pages and posts.
- Indexes.
- Module pages.
- Docs pages.
- Sitemap.
- Robots.
- Redirect artifacts.
- Public theme assets.
- Public media manifests.

Run manually:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl rebuild'
```

For the live marketing instance, use its configured `DESERTCMS_CONFIG` path rather than assuming `/etc/desertcms.conf`.

## Backups

Backups are timestamped private archives under `backup_dir`.

Run:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl backup'
```

Backups should include the SQLite database, private source assets, theme state, and other required private state for recovery.

## Restore Testing

Restore tests verify that a backup can be unpacked and inspected without damaging the live instance.

Use restore testing before relying on backup automation. A backup that has never been tested is only a guess.

The admin Operations page can queue or run restore tests through the operations workflow. The backup module also exposes restore-test behavior for operator-controlled checks.

## Operations Worker

The OpenBSD operations worker handles scheduled operational work such as backups and support bundle tasks.

Install cron:

```sh
doas perl /usr/local/www/desertcms/tools/openbsd-operations-worker.pl --install-cron
```

The worker should run quietly from cron and record useful admin-facing status.

## Upgrade Worker

Owner accounts can stage a runtime archive from Admin Settings > Upgrade DesertCMS.

The root upgrade worker applies the staged archive:

```sh
doas perl /usr/local/www/desertcms/tools/openbsd-apply-upgrade.pl --install-cron
```

The worker backs up the current app, validates the archive, applies the staged runtime bundle, restores CGI executable mode, migrates databases, repairs public-root ownership, rebuilds configured instances, and can process rollback jobs.

If signed release enforcement is enabled, configure `upgrade_signify_public_key` and keep release manifests available.

## Rollbacks

Rollback jobs are staged through the admin and applied by the root upgrade worker.

A rollback should:

- Select a known app backup.
- Create a fresh safety backup of the current app.
- Restore the selected app tree.
- Preserve executable mode for CGI and maintenance scripts.
- Run migrations and rebuilds as needed.
- Record job status for the admin.

Do not delete rollback backups during an incident unless storage pressure has already been handled another way.

## Contributor Queue Worker

Contributor provisioning and lifecycle actions are root-owned operations.

The queue worker can:

- Provision a site.
- Enable a site.
- Disable a site.
- Destroy a site with path binding checks.
- Repair generated paths.
- Retry failed jobs.
- Rewrite and validate webserver config.
- Rebuild contributor public output.

Install cron:

```sh
doas perl /usr/local/www/desertcms/tools/openbsd-apply-site-queue.pl --install-cron
```

Contributor users should not see these operations as normal settings.

## Font Package Worker

The font package worker applies queued OpenBSD font package installs for selected site typography.

Install cron:

```sh
doas perl /usr/local/www/desertcms/tools/openbsd-apply-font-packages.pl --install-cron
```

The admin app queues intent. The root worker performs package-level changes.

## Media Maintenance

Media lifecycle tools help detect and clean:

- Missing private source paths.
- Private source paths outside the configured source store.
- Missing private source files.
- Orphaned public resources.
- Stale generated derivatives.
- Large unused assets.
- Old unused private sources eligible for archive-first retention cleanup.
- Private preview jobs that need retry.

Run preview jobs from maintenance when needed:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl media-preview-jobs'
```

Cleanup should preserve referenced public resources and avoid deleting private sources merely because a plan changed.

## GeoIP Refresh

GeoIP is local. It does not call an external lookup API at request time.

Refresh DB-IP City Lite data:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl geoip-refresh-dbip-lite'
```

Import a licensed file:

```sh
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl geoip-import /var/desertcms/geoip.tsv'
doas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl geoip-backfill'
```

If refresh fails because of network or upstream availability, keep the install or operation moving and retry later.

## Validation

Run validation after install, deploy, upgrade, route changes, or significant config changes:

```sh
doas perl /usr/local/www/desertcms/tools/openbsd-validate.pl --config /etc/desertcms.conf --app-root /usr/local/www/desertcms --domain example.com
```

Validation checks OpenBSD services, route forwarding, database schema, local assets, generated public output, workers, provider readiness, and hosted site state.

Validation should be paired with real HTTP checks for:

- `/`
- `/admin`
- `/docs/`
- `/download/`
- Any touched module route.
- Any touched webhook route where safe to check routing.

## Provider Warnings

Provider readiness is not the same as server readiness.

Missing Postmark sender/token/webhook token or Stripe webhook secrets are provider setup warnings. They become production blockers only for workflows that need them:

- Email sends.
- Service billing checkout.
- Shop Payments.
- Event Payments.
- Booking Deposits.
- Membership Payments.
- Donation Payments.

Fix route, file, package, worker, firewall, TLS, and database failures before treating the server as installed. Finish provider setup before enabling provider-dependent product workflows.

## Support Bundles

Support bundles should include enough state for diagnosis without casually exposing private source assets or provider secrets.

Prefer:

- Version.
- Config shape without secrets.
- Service state.
- Recent operations history.
- Queue events.
- Upgrade job summaries.
- Public route checks.
- Local asset audit result.
- Relevant logs.

Avoid:

- Provider tokens.
- Raw private source files.
- Unredacted config.
- Unnecessary customer data.
- Public links to private source downloads.

Support bundles are stored below `backup_dir/support-bundles`.

## Emergency Checklist

For a production incident:

1. Identify the affected instance config.
2. Check `desertcms_slowcgi` and `httpd`.
3. Run `httpd -n`.
4. Check recent operations, queue, upgrade, and provider status.
5. Confirm public root ownership.
6. Rebuild if generated output is stale or missing.
7. Validate with `openbsd-validate.pl`.
8. Check public HTTP routes.
9. Create a support bundle if the issue is not obvious.
10. Avoid destructive cleanup until backup state is known.
