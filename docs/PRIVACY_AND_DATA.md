---
title: Privacy And Data
summary: A site-management guide to private source assets, public output, member-gated content, analytics retention, contributor data, backups, and support boundaries.
audience: Site Management
resource_type: Guide
tags: privacy, data, media
updated: 2026-07-05
access: Public
order: 50
---

# Privacy And Data

DesertCMS is designed around a simple rule: private source data and public output are separate.

## Private Source Assets

Uploaded source files are stored outside the public webroot.

This includes:

- Original images.
- Documents.
- Data files.
- Audio.
- Video.
- Private preview artifacts.
- Form upload attachments.
- Member-only resource source files.

Public pages should reference optimized image derivatives or explicit Resource Download copies. Uploading a file does not automatically make the source public.

## Public Output

The public site is generated as static files.

Public output can include:

- Pages and posts.
- Index pages.
- Module pages.
- Sitemap.
- Robots file.
- Redirect artifacts.
- Public image derivatives.
- Public Resource Downloads.
- Public map pin data.
- Public member portal landing.
- Public newsletter signup.
- Public donation campaign pages.
- Public testimonials pages.

If a file is not deliberately written to the public webroot, visitors should not be able to fetch it directly.

## Member-Gated Output

Membership / Gated Content uses dynamic member routes.

Members-only and group-only pages and posts are not generated as public static files. They are served through `/members/content/<slug>` only after member session and group checks.

Member resources can stream private source files after authorization. That does not move the source file into the public webroot.

Private content stays hidden from both public output and member dashboards.

## Resource Hub Access

Docs / Resource Hub Markdown files can carry an access policy.

| Access | Public behavior |
| --- | --- |
| Public | Generated into `/docs/` and included in public sitemap output. |
| Members only | Held out of public docs output and available to members when Membership is enabled. |
| Staff only or Private | Held out of public output. |

Access is a publication boundary, not just a label.

## Data By Feature

DesertCMS stores feature data locally in SQLite and private data directories.

| Area | Stored data |
| --- | --- |
| Content | Pages, posts, revisions, access policy, tags, collections, redirects, navigation, templates, and reusable sections. |
| Media | Source paths, public derivative paths, metadata, previews, resource publishing state, quotas, and cleanup state. |
| Forms | Submission type, contact details, structured fields, message text, upload metadata, hashed request metadata, and notification status. |
| Members | Accounts, groups, invites, sessions, password resets, private resources, and payment scaffolding. |
| Newsletter | Subscribers, tags, segments, consent text, unsubscribe tokens, drafts, generated digests, send history, and exportable status. |
| Donations | Campaigns, donor contact fields, donor messages, anonymous display flags, amounts, Stripe session/payment IDs, platform fees, and exportable records. |
| Testimonials | Display names, roles, organizations, quotes, ratings, source labels, related links, public-submission notes, hashed request metadata, and moderation status. |
| Analytics | First-party events, optional raw IP storage, GeoIP enrichment, and retention-controlled history. |
| Contributor sites | Site records, plan snapshots, billing identifiers, provisioning events, provider inheritance, and federated review state. |

Public submissions generally enter as pending or reviewable records before they become public.

## Analytics

DesertCMS stores first-party analytics locally.

Settings can control:

- Whether analytics are enabled.
- How long analytics are retained.
- Whether raw IP values are stored.
- Whether local GeoIP data is imported and backfilled.

GeoIP lookup uses local imported data. It does not call an external lookup API at request time. DB-IP Lite attribution is displayed when that data source is used.

## Contributor Data

Contributor sites have separate config, database, public root, and data directories.

MasterCMS may store:

- Contributor request records.
- Site records.
- Blueprint and plan assignments.
- Billing identifiers.
- Provisioning events.
- Federated review state.
- Delivery logs.

Contributor SubCMS should expose only what the contributor needs for their site, billing, usage, and support.

## Backups

Backups are stored under the configured private backup directory.

A backup can include:

- SQLite database.
- Private source assets.
- Theme state.
- Public output when needed for recovery.
- Config snapshots where supported.

Backups are operator-owned. Contributor site managers should not need to handle raw backup archives.

## Support Boundaries

Support can inspect operational state from MasterCMS when needed, but contributor-facing screens should avoid exposing platform internals.

Good support surfaces include:

- Plan and usage.
- Provider status summary.
- Email support contact.
- Billing help.
- Docs links.
- Recent site status.

Avoid exposing:

- Provider tokens.
- Root-worker commands.
- Queue internals.
- Server filesystem paths unless needed for operator support.
- Raw private source download links to users without the required capability.
- Unredacted support bundles.

Support bundles should redact secrets and avoid private source assets unless a specific support case requires tighter handling.
