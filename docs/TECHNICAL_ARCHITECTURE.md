---
title: Technical Architecture
summary: The DesertCMS developer map covering runtime surfaces, code organization, configuration, SQLite schema groups, static rendering, dynamic routes, modules, media, contributor mode, and security boundaries.
audience: Technical
resource_type: Reference
tags: architecture, OpenBSD, static publishing
updated: 2026-07-05
access: Public
order: 110
---

# Technical Architecture

DesertCMS is a Perl CGI, SQLite, static-first CMS designed for OpenBSD 7.4 with `httpd`, `slowcgi`, `pf`, `acme-client`, local filesystem operations, and root-owned worker scripts.

The core design is simple:

- Public output is generated into a public webroot.
- Admin, member, checkout, form, and webhook routes are dynamic CGI routes.
- Private source assets stay outside the public webroot.
- Contributor sites use separate config, database, public root, and data roots.
- Master-only operations stay in MasterCMS, not SubCMS.

## Runtime Surfaces

| Surface | Runtime | Primary code |
| --- | --- | --- |
| Public static site | Generated files under `public_root`, served directly by OpenBSD `httpd`. | `DesertCMS::Renderer`, `DesertCMS::Content`, theme templates and CSS. |
| Admin app | Perl CGI behind `desertcms_slowcgi`. | `bin/desertcms.cgi`, `DesertCMS::App`, `DesertCMS::Auth`, `DesertCMS::CapabilityPolicy`. |
| Dynamic public routes | CGI routes for forms, checkout, members, comments, ratings, and webhooks. | `DesertCMS::App` plus feature modules. |
| Maintenance CLI | App-user maintenance commands. | `bin/desertcms-maint.pl`. |
| Root workers | Privileged OpenBSD tasks for provisioning, upgrades, operations, and packages. | `tools/openbsd-apply-site-queue.pl`, `tools/openbsd-apply-upgrade.pl`, `tools/openbsd-operations-worker.pl`, `tools/openbsd-apply-font-packages.pl`. |

## Main Paths

Default production paths are:

```text
/usr/local/www/desertcms/          application code
/etc/desertcms.conf                main instance config
/var/desertcms/desertcms.sqlite    SQLite database
/var/desertcms/originals/          private source assets
/var/desertcms/backups/            backup archives
/var/desertcms/themes/             editable theme state
/var/desertcms/upgrades/           staged upgrade archives
/var/desertcms/font-packages/      font package worker state
/var/www/htdocs/desertcms-site/    generated public site
/var/www/run/desertcms.sock        slowcgi socket
```

Contributor sites normally use `/etc/desertcms-<site_id>.conf`, `/var/desertcms/sites/<site_id>/`, and `/var/www/htdocs/desertcms-<site_id>/`.

## Configuration

`DesertCMS::Config` loads key-value config from `DESERTCMS_CONFIG` or `/etc/desertcms.conf`.

Important config groups include:

- Identity and public URL: `site_name`, `site_url`.
- Private paths: `data_dir`, `db_path`, `originals_dir`, `backup_dir`, `theme_dir`.
- Public paths: `public_root`, `admin_asset_dir`.
- Security: `app_secret_file`, session cookie names, session TTL, lockout settings, trusted proxy CIDRs, secure cookies.
- Upload and media: `max_request_body_bytes`, `image_public_max_width`, `image_public_quality`, `image_tool`.
- Contributor mode: `contributor_site_id`, `contributor_domain`, `master_config_path`, `standalone_master_configs`.
- Modules: `module_*_enabled` plus module-specific settings persisted by `DesertCMS::Settings`.
- Docs: `module_docs_enabled`, `docs_source_dir`.
- Commerce: `commerce_model`, `shop_enabled`, `stripe_*`.
- Email and provider hooks: `postmark_*`.
- Search indexing: `google_*`, `indexnow_*`.
- Operations and upgrades: `operations_*`, `upgrade_*`, `font_package_repo`.

Admin settings can override or persist many runtime settings in SQLite. `DesertCMS::Settings` merges config defaults, database settings, and contributor plan snapshots.

## Code Map

| Module | Responsibility |
| --- | --- |
| `DesertCMS::App` | Server-rendered admin UI, contributor product shell, dynamic public route dispatch, forms, member portal, checkout responses, and admin actions. |
| `DesertCMS::Renderer` | Static public output for pages, posts, indexes, modules, docs, sitemap, robots, redirects, theme CSS, and public media references. |
| `DesertCMS::DB` | SQLite connection, schema migration, table/column repair, and migration tracking. |
| `DesertCMS::Content` | Pages, posts, revisions, visual block normalization, publishing, access policy, quotas, and rebuild coordination. |
| `DesertCMS::Media` | Private source storage, optimized image derivatives, public resource publishing, metadata, preview jobs, and cleanup policy. |
| `DesertCMS::Modules` | First-party module definitions, feature keys, plan feature maps, enabled state, locked state, and master-managed contributor features. |
| `DesertCMS::CapabilityPolicy` | Role capability definitions, route-to-capability mapping, master versus contributor scopes, and master-managed route blocking. |
| `DesertCMS::Settings` | Runtime settings, module settings, provider settings, site design settings, and contributor-plan-derived settings. |
| `DesertCMS::ServicePlans` | Hosted-site plans, feature snapshots, service billing checkout, Stripe Connect onboarding, plan assignment, and contributor billing state. |
| `DesertCMS::Sites` | Contributor site records, provisioning path defaults, health checks, and site lifecycle metadata. |
| `DesertCMS::Operations` | Fleet rebuilds, backups, sitemap submission, restore testing, support bundles, and scheduled backup coordination. |
| `DesertCMS::Upgrade` | Upgrade job staging, archive validation, rollback queueing, signed release checks, and worker job metadata. |
| `DesertCMS::Docs` | Markdown Resource Hub parsing, front matter, access filtering, slugging, and safe Markdown rendering. |
| `DesertCMS::Commerce` | Commerce model normalization, shared Stripe readiness, and workflow checkout gating for Shop, Events, Bookings, Membership, and Donations. |
| Feature modules | `Shop`, `Events`, `Directory`, `Bookings`, `Membership`, `Newsletter`, `Donations`, `Testimonials`, `Forms`, `Comments`, `Ratings`, `Analytics`, `GeoIP`. |

## Database Shape

`sql/schema.sql` is the installed schema source. `DesertCMS::DB->migrate` applies schema changes and repair logic.

Major table groups include:

- Authentication: `admin_users`, `sessions`, password reset tokens, login attempts, audit log.
- Content: `content_items`, `content_revisions`, tags, collections, navigation, redirects, templates, builder sections.
- Media: `media_assets`, `media_preview_jobs`.
- Engagement: comments, ratings, analytics events, GeoIP ranges, GeoIP metadata.
- Commerce and modules: shop, events, directory, bookings, membership, newsletter, donations, testimonials, forms.
- Contributor platform: blueprints, service plans, contributor sites, archived sites, invites, requests, provisioning queue, provisioning events, federated reviews.
- Operations: backups, themes, theme files, delivery logs, checkout session bindings.

Schema ownership matters for contributor-facing data. Destructive operations should bind to exact site, owner, row, or path state rather than relying on broad IDs alone.

## Static Renderer

`DesertCMS::Renderer` writes generated public artifacts.

It generates:

- Home, pages, posts, and post indexes.
- Taxonomy indexes for tags and collections.
- Public theme CSS.
- Public image derivatives and media manifests.
- Public Resource Downloads when explicitly published.
- Map / Locations page and `assets/map-pins.json`.
- Showcase page and legacy `/gallery/` redirect.
- Contributor application pages when Contributor Requests is enabled.
- Docs / Resource Hub index and public docs pages.
- Directory index, detail pages, optional submission page, and sitemap entries.
- Bookings index, service pages, request form pages, and sitemap entries.
- Events index, event pages, occurrence pages, `/events.ics`, and sitemap entries.
- Membership public portal landing and sitemap entry.
- Newsletter signup page and sitemap entry.
- Donation campaign index and detail pages.
- Testimonials index and optional submission page.
- `sitemap.xml`, `robots.txt`, and redirect artifacts.

Generated module pages yield to a published content item that claims the same URL. That lets a site owner replace a generated landing page with a curated page where the product allows it.

Content with `access_policy` set to `members`, `group`, or `private` is not written into the public webroot during publish or rebuild.

When module media is present, static output should use active `media_assets` records, responsive derivatives, and width or height metadata. Stale media references should not emit broken public image URLs.

## Dynamic Routes

The OpenBSD installer and validator expect these FastCGI route prefixes:

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

Representative dynamic routes include:

- `/admin` and admin subroutes.
- `/analytics/collect`.
- `/comments/thread`, `/comments/create`, `/comments/notifications`.
- `/ratings/summary`, `/ratings/vote`.
- `/forms/`, `/forms/submit`, `/forms/contributor-request`.
- `/shop`, `/shop/...`, `/stripe/webhook`.
- `/billing/stripe/webhook`.
- `/events/...`, `/events/stripe/webhook`.
- `/directory/submit`.
- `/bookings/...`, `/bookings/stripe/webhook`.
- `/members/...` for login, signup, invites, member docs, member content, private resources, and membership checkout.
- `/newsletter/...` for signup and unsubscribe flows.
- `/donate/...`, `/donate/stripe/webhook`.
- `/testimonials/submit`.
- Tokenized Postmark bounce/spam webhook routes.

Static generated module pages do not need CGI after they are written. Dynamic forms, checkout, member, and webhook flows do.

Dynamic public module routes should render through the same public shell as the generated site so they load `site.css`, `site.js`, public navigation, and the public home link instead of admin assets.

## Visual Blocks

`DesertCMS::Content` normalizes body JSON and `DesertCMS::Renderer` renders supported blocks.

Supported block types include:

- `text`
- `heading`
- `quote`
- `divider`
- `code`
- `image`
- `image_text`
- `video`
- `link`
- `resource`
- `content_ref`
- `contributor_request`
- `social`

Images must reference public optimized media derivatives. Resource blocks must reference paths under `/assets/resources/` that were intentionally published from Media.

## Docs / Resource Hub

`DesertCMS::Docs` reads Markdown from `docs_source_dir` or the bundled application `docs/` directory.

Supported front matter includes:

- `title`
- `summary` or `description`
- `audience` or `category`
- `resource_type`, `type`, or `kind`
- `tags`
- `updated`, `updated_at`, or `date`
- `access`
- `order`

Only `access: Public` resources generate public static pages and sitemap entries. Member and private docs are held out of public output. When Membership is enabled, member docs can appear through authenticated member routes.

Raw HTML in Markdown is escaped before publishing.

## Modules And Feature State

`DesertCMS::Modules` defines first-party modules. Current feature keys are:

- `map`
- `shop`
- `shop_payments`
- `events`
- `event_payments`
- `directory`
- `bookings`
- `booking_payments`
- `membership`
- `membership_payments`
- `newsletter`
- `donations`
- `donation_payments`
- `testimonials`
- `gallery`
- `forms`
- `contributor_requests`
- `docs`
- `resource_publishing`

`gallery` is the legacy storage key for the Showcase feature.

The module catalog computes:

- `available`
- `enabled`
- `configured_enabled`
- `locked_by_plan`
- `requires_upgrade`
- `managed_by_master`

Payment features are effective only when the base feature and payment conditions are ready. For example, `event_payments` is not meaningful without Events and checkout readiness.

## Contributor Product Mode

Contributor mode is detected when `contributor_site_id` or `contributor_domain` is set.

It changes:

- Admin navigation.
- Dashboard shape.
- Terminology.
- Feature catalog.
- Billing and usage surfaces.
- Provider inheritance behavior.
- Route access.

`DesertCMS::CapabilityPolicy` maps roles to capabilities and blocks master-managed routes in contributor scope. The contributor `owner` role is a site manager, not a system owner.

Master-managed contributor routes include backups, master control, contributors, sites, blueprints, plans, federation, governance, upgrades, operations, invites, and selected platform design/font actions.

## Media Pipeline

`DesertCMS::Media` implements private source storage.

Image uploads:

- Store the source under `originals_dir`.
- Generate optimized public JPEG derivatives.
- Generate responsive sizes.
- Store dimensions and derivative metadata.

Non-image uploads:

- Store the source under `originals_dir`.
- Keep `public_path` blank until explicitly published.
- Extract safe preview metadata when possible.
- Queue private preview jobs for supported PDF and video assets.
- Publish Resource Downloads only through the resource publishing workflow.

The public policy is one of:

- `optimized_public_derivative`
- `public_resource_download`
- `private_source_only`

## Provider And Commerce Boundaries

Contributor sites inherit platform providers unless a plan allows a specific override.

Provider areas include:

- Postmark delivery.
- Stripe service billing.
- Stripe site payments.
- Stripe Connect payouts.
- Search Console.
- IndexNow.
- GeoIP data import.

Provider readiness warnings do not necessarily mean the OpenBSD install failed. A server can be correctly installed before Postmark and Stripe are configured.

## Security Boundaries

Important boundaries include:

- Private sources are outside `public_root`.
- Public artifacts are generated from structured state.
- Contributor sites have separate config, database, public root, and data paths.
- Contributor route access is capability-driven.
- Master-managed operations are blocked from contributor product mode.
- Webhooks are routed through explicit FastCGI prefixes.
- Upgrade archives are staged and applied by a root worker.
- OpenBSD `httpd`, `desertcms_slowcgi`, `pf`, `doas`, cron, and filesystem ownership form the production boundary.

## Development Checks

Useful local checks include:

```sh
perl -Ilib -c bin/desertcms.cgi
perl -Ilib -c bin/desertcms-maint.pl
prove -l t
perl tools/check-local-assets.pl
```

For docs changes, keep `t/33_docs_catalog.t` passing and verify generated `/docs/` output after rebuild.
