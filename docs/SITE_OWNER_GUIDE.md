---
title: Site Owner Guide
summary: A non-technical starting point for using DesertCMS, choosing the right admin area, publishing content, managing media, and understanding hosted contributor sites.
audience: Site Management
resource_type: Guide
tags: site builder, contributor sites, editing
updated: 2026-07-05
access: Public
order: 10
---

# Site Owner Guide

Start here when you need to run a DesertCMS site without thinking about server internals.

DesertCMS has two product experiences that use the same engine.

| Experience | Who uses it | What it is for |
| --- | --- | --- |
| MasterCMS | Platform owner, operator, reviewer, support staff | The main control plane for the primary site, hosted contributor sites, plans, provisioning, governance, operations, upgrades, and provider settings. |
| SubCMS | Contributor site owner, editor, contributor support user | A hosted site builder for one contributor or customer site. It focuses on that site's content, media, design, features, usage, billing, and help. |

If you are signed into a hosted contributor site, the admin should feel like a site builder. It should not ask you to manage platform upgrades, provider secrets, server services, fleet health, or contributor lifecycle jobs.

## First Things To Check

After signing in, confirm:

- You are in the right site or hosted contributor site.
- Your account setup is complete.
- The Home page shows the expected site status and plan state.
- The public site URL opens.
- Your enabled features match what you expect to use.
- Media quota and upload limits are not blocking current work.

If you are on a contributor site and need a feature that is locked, open Billing or Account / Help instead of looking for server settings.

## Main Workflow

A normal update uses this path:

1. Open Site Builder, Pages, or Posts.
2. Edit structured blocks, metadata, access, and optional media.
3. Save as draft or publish.
4. Rebuild when the admin asks for it or when shared site structure changed.
5. Review the public page.

The public site is static-first. Publishing writes generated files into the public webroot. The admin remains dynamic, but public visitors normally receive static pages and assets.

## Contributor Product Mode

A DesertCMS instance becomes a hosted contributor product when its config has `contributor_site_id` or `contributor_domain` set.

Contributor product mode changes:

- Admin shell and navigation.
- Dashboard copy.
- Route access.
- Feature labels.
- Billing and usage surfaces.
- Plan-locked feature messaging.
- Provider inheritance summaries.

The contributor navigation is:

- Home.
- Site Builder.
- Pages.
- Posts.
- Media.
- Design.
- Features.
- Billing.
- Account.
- Help.

The master navigation stays separate and includes platform surfaces such as Master Control, Operations, Contributor Sites, Blueprints, Service Plans, Governance, Federated Review, Provider Readiness, and Upgrade.

## Site Builder

Site Builder is the visual editing center for pages, reusable sections, and content structure.

Current visual block types include:

| Block | Use it for |
| --- | --- |
| Text and Heading | Normal copy, headings, aligned text, and styled body sections. |
| Image and Image + Text | Public image derivatives from Media, with caption and layout controls. |
| Video | External video embeds or video links. |
| Link | A callout to an internal or external page. |
| Resource | A public Resource Download that was intentionally published from Media. |
| Content reference | A card or feature link to an existing published page or post. |
| Quote | Pull quotes, testimonials, or short cited text. |
| Code and Divider | Technical snippets or spacing breaks. |
| Social link | Social profile or contact links. |
| Contributor request | A public contributor application form when the Contributor Requests feature is available. |

Generated module pages, such as Events or Directory, are not inserted as arbitrary page-builder blocks. They are enabled in Features and rendered at their public module paths.

## Pages And Posts

Use Pages for stable site sections such as About, Services, Portfolio, Contact, Resource Hub, or a custom landing page.

Use Posts for dated updates, articles, notes, announcements, stories, or changelog-style entries.

Pages and posts can include:

- Title, slug, excerpt, meta title, and meta description.
- Structured visual blocks.
- Feature image.
- Tags and collections.
- Public, members-only, group-only, or private access when Membership is enabled.
- Location data when Map / Locations is enabled.
- Comments and ratings when those features are enabled.

Public pages and posts are generated as static files. Members-only and group-only content is served through the member portal after access checks. Private content is not exposed publicly.

## Media

Media is private-first.

Uploaded source files are stored outside the public webroot. Public output is deliberate:

- Images get optimized public derivatives and responsive sizes.
- Documents, data files, audio, and video stay private until published as Resource Downloads.
- PDF thumbnails, video posters, and other private previews are authenticated admin previews.
- Public Resource Downloads can be unpublished without deleting the private source.

Use titles, descriptions, alt text, categories, tags, and collections so the Media Library remains searchable.

## Design

Design controls public presentation and discovery settings.

Use it for:

- Site name and public description.
- Logo, logo fit, header, footer, and public identity.
- Theme mode and color presets.
- Typography, buttons, cards, and layout.
- Live preview across public-shell samples.
- SEO defaults, sitemap, robots, Search Console, and IndexNow when allowed.

Contributor sites inherit platform-managed provider defaults unless their plan allows a specific override.

## Features

Features is the module catalog. A feature can be available, enabled, disabled, locked by plan, requiring upgrade, or managed by the master platform.

Current first-party features include:

| Feature | Public surface |
| --- | --- |
| Map / Locations | `/map/` and `assets/map-pins.json` for mapped pages, posts, events, directory entries, and booking services. |
| Showcase | `/showcase/` for portfolios, case studies, collections, products, archives, artwork, venues, samples, and public resource cards. |
| Forms | `/forms/` for contact, quote, application, intake, RSVP, private upload, and Postmark-notified submissions. |
| Docs / Resource Hub | `/docs/` generated from Markdown resources marked public. |
| Shop / Catalog | `/shop` listings for products, services, digital items, portfolio items, samples, and inquiry entries. |
| Events | `/events/`, event pages, occurrence pages, RSVP, free tickets, paid tickets when Event Payments is ready, and `/events.ics`. |
| Directory | `/directory/` records for people, businesses, artists, vendors, members, places, organizations, and resources. |
| Bookings / Appointments | `/bookings/` service listings, request forms, review workflow, export, and optional deposits. |
| Membership / Gated Content | `/members/` login, signup or invites, groups, private pages, member docs, and authenticated private downloads. |
| Newsletter | `/newsletter/` signup, subscribers, tags, segments, unsubscribe links, drafts, digests, sends, and export. |
| Donations / Fundraising | `/donate/` campaign pages, suggested amounts, donor messages, goal progress, export, and optional checkout. |
| Testimonials / Reviews | `/testimonials/` approved praise, optional ratings, moderated public submissions, related links, and export. |
| Resource Downloads | Public downloads for selected private source files. |
| Contributor Requests | Master-managed public applications for hosted contributor sites. |

Payment features are separate from content features. For example, Events can collect free RSVPs without Event Payments, and Bookings can collect requests without Booking Deposits.

## Billing

Billing explains what a hosted contributor site can use.

It should show:

- Current plan.
- Billing status.
- Media storage and upload limits.
- Page and post limits.
- Enabled and locked features.
- Upgrade or cancellation path.
- Stripe-hosted management actions when configured.
- Provider inheritance summary.

Locked features are not errors. They mean the current plan does not include that feature or the required payment entitlement.

## Account And Help

Account and Help should answer:

- Who is signed in?
- What site and plan is this?
- Who should the site manager contact?
- Is email, payments, indexing, or maintenance platform-managed?
- Where are the relevant docs?
- What status does the platform report for this site?

Contributor site managers should not need root-worker commands or provider secrets to solve normal product problems.

## What Contributors Do Not Manage

Hosted contributor site managers do not manage:

- Platform upgrades.
- Root workers.
- Server packages.
- OpenBSD `pf`, `httpd`, `slowcgi`, TLS, or cron.
- Platform Postmark tokens.
- Platform Stripe service billing credentials.
- Provisioning queue internals.
- Fleet health.
- Contributor lifecycle actions.
- Governance and federated review.

Those remain MasterCMS responsibilities.

## Where To Go Next

Use [Content, Design, And Media](CONTENT_DESIGN_AND_MEDIA.md) for day-to-day editing, design, and media work.

Use [Managing Contributor Sites](MANAGING_CONTRIBUTOR_SITES.md) for hosted-site operator workflows.

Use [Billing And Provider Options](BILLING_AND_PROVIDER_OPTIONS.md) for plans, limits, payment features, Postmark sender options, and Stripe Connect.

Use [Privacy And Data](PRIVACY_AND_DATA.md) for private source assets, public output, analytics retention, backups, and support boundaries.
