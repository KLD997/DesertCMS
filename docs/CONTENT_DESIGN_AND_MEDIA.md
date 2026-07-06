---
title: Content, Design, And Media
summary: A practical guide to editing pages and posts, using the visual block builder, changing public design, organizing media, and publishing resource downloads safely.
audience: Site Management
resource_type: Guide
tags: editing, design, media
updated: 2026-07-05
access: Public
order: 20
---

# Content, Design, And Media

This guide is for the day-to-day work of keeping a DesertCMS site useful, current, and safe to publish.

## Editing Workflow

A normal content pass looks like this:

1. Open Site Builder, Pages, or Posts.
2. Pick an existing item or create a new one.
3. Edit title, slug, excerpt, body blocks, SEO fields, access, and optional media.
4. Save as draft or publish.
5. Rebuild public output when prompted.
6. Visit the public URL and review the page.

Public output is generated. Drafts and private content remain in the database and admin until published or served through an authenticated feature such as Membership.

## Pages, Posts, Templates, And Sections

Use Pages for durable site structure:

- Home alternatives.
- About.
- Services.
- Portfolio.
- Contact.
- Resource Hub.
- Custom landing pages.

Use Posts for dated material:

- News.
- Articles.
- Notes.
- Announcements.
- Stories.
- Release updates.

Templates and reusable sections help start new pages with consistent visual blocks. Editing a reusable section changes the section for future use. Pages that already copied the section keep their saved blocks.

## Visual Block Builder

DesertCMS stores page bodies as structured JSON blocks. Editors do not need Markdown for normal site pages.

| Block | Notes |
| --- | --- |
| Text | Rich text with alignment, font, size, and spacing controls. |
| Heading | Level 2 or level 3 headings for page structure. |
| Image | A public optimized image derivative selected from Media. |
| Image + Text | Side-by-side image and copy, with mobile-safe stacking. |
| Video | External embed or link card, depending on the URL. |
| Link | A card-style callout to a page, post, document, or external URL. |
| Resource | A public Resource Download selected from Media. |
| Content reference | A card or feature card pointing at a published public page or post. |
| Quote | Pull quote with optional citation. |
| Code | Escaped code block with optional language label. |
| Divider | Visual break between sections. |
| Social link | Website, email, Instagram, X, Facebook, YouTube, Vimeo, or similar profile link. |
| Contributor request | A contributor application block when Contributor Requests is available. |

Generated module pages, such as `/events/`, `/directory/`, `/bookings/`, and `/docs/`, are managed from Features and module settings. They are not the same thing as visual page blocks.

## Access Choices

Content access controls publication:

| Access | Public output |
| --- | --- |
| Public | Generated into the public static site. |
| Members only | Not written as a public static page. Served through `/members/content/<slug>` after member login. |
| Group only | Served through the member portal after member login and group check. |
| Private | Hidden from public output and member dashboards. |

Keep private content private until you are ready to publish it. Changing a page from public to members-only or private should be followed by a rebuild so old public output is removed or replaced by the current generated state.

## Navigation And Redirects

Navigation controls public menu links. Keep labels short enough to work on phones.

Redirects are useful when:

- A page slug changes.
- An old campaign URL still receives traffic.
- A retired URL should point to a newer page.
- A public module route was replaced by a curated page.

Redirect artifacts are generated during rebuild. They do not replace good internal links, but they make old URLs safer.

## Map, Comments, And Ratings

When Map / Locations is enabled, pages and posts can carry public map data:

- Latitude and longitude.
- Location label.
- Location type.
- Optional map inclusion.

Location types include store, venue, project location, historical site, event location, service area, and other. Service areas are currently point-based with label/type text, not polygons or radii.

Comments and ratings are optional public engagement features. Moderation stays inside the admin. Review pending comments before they become public.

## Design Basics

Design controls public identity and presentation.

Common design settings include:

- Site name.
- Public description.
- Logo, fit, focal point, and header behavior.
- Footer content.
- Theme color presets.
- Light and dark mode defaults.
- Typography.
- Button and card styles.
- Public-shell preview for desktop, tablet, and mobile.

Use the preview before saving. Check light and dark mode, long labels, images, buttons, and cards.

## Search And Discovery

Discovery settings include:

- Meta title and description defaults.
- Sitemap output.
- Robots output.
- Search Console submission.
- IndexNow submission.

Contributor sites inherit indexing defaults from the master platform unless their plan allows indexing override controls.

## Media Pipeline

Every upload starts as a private source asset.

| Asset type | Private source | Public output |
| --- | --- | --- |
| Images | Original upload stays outside the public webroot. | Optimized public image derivative, responsive sizes, dimensions, public image metadata, and preserved PNG or WebP transparency when the source format supports it. |
| Documents and data files | PDF, TXT, Markdown, CSV, TSV, JSON, DOCX, XLSX, and PPTX stay private. | Public Resource Download only when intentionally published. |
| Audio | MP3, M4A, WAV, OGG, WebM audio, and FLAC stay private. | Public Resource Download only when intentionally published. |
| Video | MP4, M4V, MOV, WebM, and OGV stay private. | Public Resource Download only when intentionally published. |

Public pages should reference optimized image derivatives or public resource copies, not private source paths.

Module pages should use the same derivative pipeline as pages and posts. Campaign art, service art, logos, and other transparent graphics should stay transparent, and stale media references should disappear instead of rendering a broken image.

## Media Metadata

Use metadata so the library remains searchable:

- Title.
- Description.
- Alt text for images.
- Source notes.
- Category.
- Tags.
- Collections.

Search covers names, titles, descriptions, snippets, file type labels, tags, categories, collections, and public paths.

## Private Previews

Some non-image files can have private previews:

- PDF page thumbnail.
- Video poster frame.
- Audio metadata preview.
- Text snippet from PDF or Office files.

Private previews are authenticated admin artifacts. They are not public downloads.

## Resource Downloads

Resource Downloads are controlled public copies of private source files.

Use Resource Downloads when visitors should be able to download a document, data file, audio file, video file, catalog sample, portfolio packet, local archive packet, or help resource.

The workflow is:

1. Upload the source file to Media.
2. Add useful metadata.
3. Publish it as a Resource Download when the feature is available.
4. Add it to a page with a Resource block or let Showcase display it.
5. Unpublish it when public access should stop.

Unpublishing removes the public copy. The private source remains in Media until cleanup or deletion.

## Storage And Quotas

Hosted contributor sites can have:

- Total media storage quota.
- Per-file upload limit.
- Page quota.
- Post quota.
- Plan-gated Resource Downloads.
- Storage pressure warnings in Media and Billing.

The OpenBSD request-body limit also caps upload size. A plan can allow a larger upload limit only if the deployment allows requests that large.

## Lifecycle And Cleanup

Media lifecycle tools help find:

- Missing private source paths.
- Private source paths outside the configured source store.
- Missing private source files.
- Orphaned public resources.
- Stale image derivatives.
- Large unused assets.
- Old unused private source assets.
- Private preview jobs that need retry.

Retention cleanup is conservative. Referenced public resources are kept during downgrade-safe cleanup, and old unused private sources are handled through archive-first retention behavior.
