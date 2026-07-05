# DesertCMS

![DesertCMS logo](public/assets/site/logo.png)

A small Perl CMS designed for OpenBSD `httpd`, `slowcgi`, SQLite, and static-first publishing.

The public site is served as generated files. The admin area is a Perl CGI app behind `httpd` FastCGI forwarding through `slowcgi`.

DesertCMS is formally hosted at [desertcms.com](https://desertcms.com/). The repository includes the same logo assets used by the hosted site under `public/assets/site/`.

## Current Status

- Phase 1: project scaffold, config, SQLite schema, OpenBSD service examples.
- Phase 2: admin authentication, sessions, CSRF, login hardening.
- Phase 3: pages/posts, revisions, static rendering.
- Phase 4: private source assets and optimized public image derivatives.
- Phase 5: timestamped backup/restore archives.
- Phase 6: responsive text/image block editor.
- Phase 7: editable default theme.
- Phase 8: sitemap/robots publishing, redirects, navigation, preview, media alt text, tags, and collections.
- Phase 9: first-party analytics collection and a dashboard for traffic and site health.
- Phase 10: OpenBSD interactive installer, local asset audit, and first-login CMS credential reset.
- Phase 11: first-party catalog/rights shop module at `/shop` with Stripe Checkout.
- Phase 12: contributor provisioning, owner-aware media records, and root queue workers.
- Phase 13: comments, post ratings, media deletion, and admin moderation tools.
- Phase 14: Showcase, Forms, and Markdown Documentation modules.
- Phase 15: local GeoIP import/backfill with DB-IP City Lite support.
- Phase 16: admin-staged release upgrades through a root worker.
- Phase 17: Search & Discovery settings, Google Search Console sitemap submission, IndexNow submission, media search overrides, and dashboard analytics cleanup.
- Phase 18: Site Settings section navigation with Identity, Search & Discovery, Indexing, and Themes.
- Phase 19: contributor request forms, review queue, approval/denial email flow, contributor profile directory, access grants, and master-site contributor media/post surfacing.
- Phase 20: Master Control dashboard for contributor subCMS fleet health, provider readiness, queue state, paths, backups, DNS, TLS, and shared version visibility.
- Phase 21: provisioning health event logs, per-job review pages, and failed-job retries from Master Control.
- Phase 22: Contributor Blueprints for repeatable subCMS module, theme, SEO, quota, default-page, and master-surfacing defaults.
- Phase 23: Governance roles, scoped contributor subCMS access, owner-preserving access grants, and master action audit logs.
- Phase 24: Federated Content Review for approving contributor images and posts before master-site surfacing.
- Phase 25: Service Plans for hosted contributor subCMS pricing metadata, Stripe Price IDs, quota assignment, billing status, and usage tracking.
- Phase 26: Tenant-isolation audit, Master Control isolation checks, last-login visibility, and stricter OpenBSD sandbox path filtering.
- Phase 27: Commerce model selection for disabled, master-owned, contributor-owned, and marketplace-planning Stripe workflows.
- Phase 28: Builder sections, reusable block insertion, block spacing controls, responsive editor previews, and module-page overrides.
- Phase 29: Theme System tokens for admin-editable typography, button styles, card styles, and public theme CSS variables.
- Phase 30: OpenBSD font package catalog, queued font-package installs, and local web-font publishing for selected site typography.
- Phase 31: dead legacy cleanup for old domains, dated OpenBSD validation wording, upgrade examples, and dashboard-to-Analytics wording.
- Phase 32: OpenBSD font package command-path hardening, sandbox allowlisting, and automatic package-repository fallback for admin catalog refreshes and root worker installs.
- Phase 33: centralized DesertCMS version utility for admin, operations, support, and download release surfaces.
- Phase 34: responsive asset pipeline with public media srcsets, generated dimensions, site-image manifests, and Media Library readiness checks.
- Phase 35: admin polish for Master Control, Operations, Contributor Requests, and Provider Readiness with mobile card tables and clearer empty states.
- Phase 36: Postmark HTTPS transport readiness checks, clearer missing-module delivery logs, and OpenBSD email dependency guidance.
- Phase 37: admin CGI executable-mode release guard to prevent post-deploy `/admin` 500 errors.
- Phase 38: Postmark HTTPS transport check hardening for the live OpenBSD CGI request path.
- Phase 39: defensive Postmark HTTPS module loading with CGI path diagnostics.
- Phase 40: OpenBSD sandbox visibility for Perl `libdata` modules used by Postmark HTTPS.
- Phase 41: OpenBSD pledge permissions for dynamic TLS modules and DNS during Postmark HTTPS sends.
- Phase 42: OpenBSD sandbox file-attribute permission for media storage after pledge hardening.
- Phase 43: idempotent OpenBSD sandbox activation for repeated in-process admin runs and tests.
- Phase 44: repository-wide security hardening for upgrade trust, tenant-owner seeding, trusted proxy identity, request body caps, contributor portrait derivatives, billing webhook bindings, destroy path binding, and tenant root nesting checks.
- Phase 45: Analytics dashboard polish with cleaner metric cards, chart panels, empty states, and mobile labeled table cards.
- Phase 46: Analytics Site Health strip layout and full DB-IP City Lite GeoIP coverage refresh.
- Phase 47: Settings page polish with shared status summaries, clearer module state, mobile-friendly settings navigation, and sticky save actions.
- Phase 48: Analytics dashboard object sizing with compact/standard/wide health items and standard dashboard widget spans.
- Phase 49: Analytics dashboard band layout polish with overflow-safe health items and a two-stack content flow to remove tall-card gaps.
- Phase 50: mobile admin table cards for fleet, contributor requests, logs, operations, billing, and provider checks with collapsed action menus.
- Phase 51: Analytics dashboard polish with aligned metric states, clearer alert treatment, stronger chart scaling, and richer empty states.
- Phase 52: public form polish with grouped fields, friendlier validation, character counters, upload previews, and mobile contributor application/profile layouts.
- Phase 53: contributor request lifecycle cleanup for destroyed/archived sites and a 30-day duplicate email request cooldown.
- Phase 54: Contributors delivery log scroll cap so the latest events stay available without stretching the page.
- Phase 55: provisioning queue command-output capture and contributor public-root ownership repair for reliable retries.
- Phase 56: contributor directory route cleanup so `/contributors/` is owned by the Contributor Requests module.
- Phase 57: Master Control polish with a fleet summary, Healthy / Needs Attention / Failed grouping, and quieter repair/retry actions.
- Phase 58: contributor onboarding polish with guided request/review/profile/provisioning/billing progress and visible email delivery failures.
- Phase 59: contributor Billing polish with comparable service-plan cards, unmistakable current-plan state, and safe Stripe-hosted upgrade/cancel management.
- Phase 60: public site polish for mobile header/footer behavior, generated module pages, contributor cards, showcase cards, public forms, and the shared Shop shell.
- Phase 61: Theme Builder live preview with visual desktop/mobile header and footer variants, logo fit, typography samples, and component token previews.
- Phase 62: admin microcopy and empty-state polish with clear setup guidance, action-specific failure notices, and friendlier provider/operations wording.
- Phase 63: admin interaction polish with shared loading states, double-submit protection, closeable notices, and modal confirmations for destructive actions.
- Phase 64: responsive QA and visual design polish for public/admin nav, cards, forms, badges, focus states, mobile table cards, and shared spacing.
- Phase 65: master settings grouping, contributor settings consolidation, Theme/Layout tab panels, preview-side color controls, and public theme mode persistence cleanup.
- Phase 66: Theme/Layout Preview & Colors layout repair so the live preview gets a full-width row and Site & SEO section navigation stays in normal page flow.
- Phase 67: Media pipeline terminology and editor cleanup around private source assets, optimized public derivatives, Image block labels, and media search readiness.
- Phase 68: Non-image media assets with private document/resource uploads, admin-only source downloads, document cards, and image-only public/shop picker safeguards.
- Phase 69: Explicit public resource publishing for selected documents/resources with `/assets/resources/` copies, Resource blocks, publish/unpublish controls, and private-source preservation.
- Phase 70: Media Library organization with filter tabs for Images, Documents, Resources, Unused, Published, and Private Source Only assets.
- Phase 71: Richer document/resource metadata with file family labels, byte labels, safe text snippets, and clearer admin/editor/public resource previews.
- Phase 72: Media Library bulk actions for publishing resources, unpublishing resources, deleting selected unused assets, and applying shared metadata without clearing blank fields.
- Phase 73: Contributor Billing media usage breakdown with plan storage remaining, image/document/public-resource/private-source counts, and quota-aware storage totals.
- Phase 74: Plan-gated Resource Downloads and per-plan media upload limits for hosted contributor sites.
- Phase 75: Media lifecycle audit and cleanup tools for missing private sources, orphaned public resources, stale public derivatives, and large unused media.
- Phase 76: Media search and discovery across titles, descriptions, filenames, snippets, file type metadata, and editor image/resource pickers.
- Phase 77: Best-effort PDF and Office document preview extraction with extracted headings, snippets, and metadata-only fallbacks.
- Phase 78: Media retention policies for old unused source assets with archive-first cleanup, private retention manifests, and downgrade-safe public resource handling.
- Phase 79: Contributor media storage pressure indicators in Media and Billing, with quota warnings before uploads fail.
- Phase 80: Audio and video private source assets with Media Library filters, metadata labels, search support, and explicit Resource publishing.
- Phase 81: Media Library category, tag, and collection organization with searchable metadata, organization filters, chip summaries, and bulk metadata support.
- Phase 82: Private generated preview artifacts for non-image assets, including best-effort PDF thumbnails, optional video posters, audio metadata previews, authenticated admin preview delivery, and cleanup/retention handling.
- Phase 83: Media action capability hardening for private source downloads, public resource publishing, bulk actions, metadata edits, and cleanup/delete controls.
- Phase 84: Queued private preview jobs for retrying PDF thumbnails and video posters from Media Lifecycle or maintenance commands.
- Phase 85: Documentation rebuild with separate Site Management and Technical tracks, audience-grouped `/docs/`, OpenBSD 7.4 install guidance, and removal of provider-specific docs.
- Phase 86: Generated documentation cleanup so removed Markdown files do not leave stale public `/docs/` routes after rebuild.
- Phase 87: Documentation page navigation reflow so grouped docs links render as a full-width nav area instead of a cramped sidebar.
- Phase 88: Showcase module polish with `/showcase/` output, legacy `/gallery/` redirect compatibility, resource-download cards, Showcase feature labels, and docs/tests aligned to the broader portfolio/catalog/archive use case.
- Phase 89: Documentation page nav comfort hotfix with a full-width grouped link grid, larger tap targets, and upgrade CSS for existing live themes.
- Phase 90: Forms module upgrade with contact, quote request, application, intake, RSVP, private upload, and Postmark notification workflows.
- Phase 91: Docs / Resource Hub polish with resource-type metadata, tags, updated/access labels, broader guide/archive/FAQ/help-center framing, public hub cards, and theme upgrade CSS.
- Phase 92: Docs / Resource Hub access policy so only public resources generate static `/docs/` pages and sitemaps while member/staff/private resources stay in the admin catalog.
- Phase 93: Map / Locations generalization with content-attached location types, broader store/venue/project/historical/event/service-area copy, generalized map output, and upgrade-safe theme script/CSS handling.
- Phase 94: Shop / Catalog split with catalog-only listings, listing types, inquiry CTAs, separate `shop_payments` plan gating, checkout readiness checks, and preserved marketplace fee checkout.
- Phase 95: Events module with standalone event records, public calendar/event pages, RSVP, recurrence, event locations, ICS export, plan-gated paid tickets, and Stripe marketplace ticket checkout.
- Phase 96: Events runtime compatibility with bundled DateTimeLite recurrence/date handling for OpenBSD installs without extra CPAN calendar dependencies.
- Phase 97: Directory module with standalone profiles/listings, public `/directory/` output, optional moderated listing suggestions, blueprint/plan integration, sitemap entries, and Map / Locations pins.
- Phase 98: Bookings / Appointments module with standalone service listings, public `/bookings/` pages, request intake, review/export workflow, Postmark notifications, map pins, and plan-gated Stripe deposits.
- Phase 99: Membership / Gated Content module with member accounts, groups, invites, `/members/` portal, gated pages/posts, member-only docs, authenticated private downloads, and separate Membership Payments entitlement.
- Phase 100: Newsletter module with public signup, subscriber tags/segments, unsubscribe links, CSV export, announcement drafts, cross-module digest generation, Postmark readiness gating, and send history.
- Phase 101: Donations / Fundraising module with public `/donate/` campaigns, goals, suggested/custom amounts, donor messages, CSV export, separate Donation Payments entitlement, Stripe checkout, webhook fulfillment, and marketplace platform fees.
- Phase 102: Testimonials / Reviews module with approved public testimonials, optional ratings, related directory/booking links, moderated public submissions, contributor feature catalog integration, static output, sitemap entries, and CSV export.
- Phase 103: Admin navigation cleanup so feature-specific setup pages live under Modules/Features instead of crowding the general Editor and contributor product nav.
- Phase 104: OpenBSD installer route completeness for first-party dynamic modules plus admin wrapping polish for long buttons, settings nav lists, sticky actions, and module catalog cards.
- Phase 105: First-party module admin tables now use the responsive card-table pattern with mobile labels across Events, Directory, Bookings, Membership, Newsletter, Donations, Testimonials, and Docs / Resource Hub.
- Phase 106: Older admin management tables now use responsive card-table markup and mobile labels across content lists, templates, sections, Shop orders, backups, Governance, Federated Review, Contributor Blueprints, Forms submissions, and OpenBSD font package jobs.
- Phase 107: OpenBSD single-install hardening with GeoIP refresh during install, schema-derived database validation, root-worker cron validation, compressed GeoIP support checks, and a legacy Vultr installer wrapper that delegates to the maintained installer.
- Phase 108: Module navigation now treats first-party feature setup pages as module/feature surfaces: master gets a primary Modules section, SubCMS keeps Features active, and module setup pages no longer borrow the Editor/Site Builder secondary nav.
- Phase 109: Long module setup pages now include local section navigation with stable anchors across Shop / Catalog, Directory, Bookings, Events, Newsletter, Donations, Testimonials, and Membership so settings, records, requests, payments, and resources are easier to scan.
- Phase 110: Shared admin wrapping polish for dense cards and controls so split headers, button rows, row actions, status pills, health cards, metric cards, workflow cards, billing price rows, and contributor feature cards shrink and wrap more predictably.
- Phase 111: OpenBSD installer now runs production validation by default and writes a usable HTTP-only DesertCMS config with dynamic module routes when TLS is still pending.
- Phase 112: Dense admin form/list wrapping polish so settings labels, helper text, provider status cards, checkbox grids, and long inline values shrink instead of forcing overflow.
- Phase 113: OpenBSD provider-hook readiness with a first-class `/stripe/webhook` FastCGI route, aligned Shop / Catalog webhook URLs, and Postmark/Stripe readiness checks in production validation.
- Phase 114: OpenBSD upgrade worker now repairs configured public-root ownership before each instance rebuild so root-owned generated files cannot block upgrades or marketing-site reseeds.
- Phase 115: OpenBSD production validation now detects nested public-root ownership drift so stale root-owned generated files are caught before upgrades or reseeds attempt a rebuild.
- Phase 116: Dense admin surface wrapping for table cell children, empty states, notices, details/definition lists, and code/preformatted blocks.
- Phase 117: OpenBSD installer plan-only review mode for non-mutating DNS and install-plan checks before running a full server install.
- Phase 118: Master Control provider-readiness detail panels for Postmark, Stripe, webhook endpoints, and setup links.
- Phase 119: Module setup pages now render a dedicated Modules/Features setup nav so Events, Directory, Bookings, Membership, Newsletter, Donations, Testimonials, and other feature modules sit visibly under the module catalog instead of appearing as orphan setup pages.
- Phase 120: OpenBSD production validation now proves the firewall runtime state, boot enablement, SSH admin allowlist, and loaded HTTP/HTTPS public-port rules instead of only syntax-checking pf.conf.
- Phase 121: OpenBSD production validation now audits hosted contributor site readiness, including registry records, expected OpenBSD paths, inherited contributor config fields, SQLite/public/data presence, and httpd routing for active or disabled SubCMS domains.
- Phase 122: OpenBSD production validation now audits provider webhook endpoint routing for Shop / Catalog checkout, hosted service billing, Events tickets, Bookings deposits, Donations, and tokenized Postmark bounce/spam hooks.
- Phase 123: Module setup navigation now explicitly groups first-party feature modules under Modules/Features, with Events, Directory, Bookings, Membership, Newsletter, Donations, and Testimonials leading the setup nav plus tighter wrapping for dense admin labels.
- Phase 124: OpenBSD fresh-install configs now explicitly document every current first-party module flag, including Events, Directory, Bookings, Membership, Newsletter, Donations, and Testimonials, so the single-install path stays aligned with the module catalog.
- Phase 125: Service Plan feature entitlements are now grouped into public site features, payments/deposits, and publishing utilities so long plan setup lists are easier to scan and wrap cleanly.
- Phase 126: Operations and Recovery now has a local section nav for bulk actions, backup schedule, restore testing, rollback, support bundles, and recent jobs, plus stable anchors for upgrade and operations job panels.
- Phase 127: The desertcms.com marketing seeder now repairs generated public-root ownership when run as root so release download reseeds do not leave root-owned public files.
- Phase 128: Master Control now has local section navigation with stable anchors for overview, maintenance, fleet health groups, provider readiness, tenant isolation, disabled/archived sites, and provisioning queue panels.
- Phase 129: The OpenBSD installer now prints a single-install coverage checklist for packages, filesystem, services, firewall, routing, CMS initialization, GeoIP, TLS, and validation so plan-only and final handoff output prove the fast deployment path.
- Phase 130: Hosted SubCMS Billing now starts with a provider-readiness strip for platform plan billing, Postmark sender mode, Stripe payout onboarding, and platform fee state before the detailed service controls.
- Phase 131: Modules/Features setup navigation now labels the parent catalog clearly, keeps first-party feature setup pages visually under Modules or Features, and wraps long module labels more comfortably.
- Phase 132: Dense Media Library and Shop / Catalog filter toolbars now use flexible grid tracks, wrapped count pills, and shrink-safe controls so search, organization filters, bulk actions, and catalog filters do not crowd narrow admin layouts.
- Phase 133: Visual editor preview bars, block toolbars, reusable-section controls, and inline block settings now have shrink-safe widths and wrapping labels/buttons so editor tools stay usable across tablet and split-screen admin layouts.
- Phase 134: OpenBSD production validation now reports hosted SubCMS provisioning queue health, including failed jobs that need retry and stale queued/running jobs that may indicate a stopped worker.
- Phase 135: Hosted SubCMS provisioning validation now treats old failed jobs as historical once the current site state proves the action was superseded, keeping production checks focused on unresolved deployment blockers.
- Phase 136: OpenBSD production validation now includes recent email delivery health, surfacing failed, bounced, spam, and complaint Postmark events from the delivery log during install/deploy checks.
- Phase 137: OpenBSD production validation now includes Stripe/payment workflow health across hosted service billing, Shop, Events, Bookings, Membership, and Donations, warning on stale pending checkouts and recent failed/canceled/refunded/ignored payment records.
- Phase 138: Contributor product navigation now collapses into the menu at tablet and narrow-laptop widths so the hosted site-builder shell does not crowd long Home / Site Builder / Features / Billing labels.
- Phase 139: OpenBSD quick-start and manual recovery guidance now consistently uses the DesertCMS-owned `desertcms_slowcgi` rc.d service instead of the disabled base `slowcgi` service.
- Phase 140: Public Events ticket and module action controls now wrap long labels and stack before narrow tablet layouts crowd payment forms.
- Phase 141: Service Plans now has local section navigation with stable anchors for overview, billing readiness, plans, edit fields, feature entitlements, provider overrides, assignment, and fleet usage.
- Phase 142: Contributor Blueprints now has local section navigation with stable anchors for blueprint lists, editor fields, module defaults, theme/SEO, limits, surfacing, and default pages.
- Phase 143: Modules/Features setup navigation now separates the catalog link, first-party feature modules, and supporting site tools into grouped responsive bands so Events, Directory, Bookings, Membership, Newsletter, Donations, and Testimonials clearly live under Modules/Features without crowding the shell.
- Phase 144: OpenBSD installer handoff now names the concrete dynamic module routes, static generated module output, provider webhook paths, and hosted SubCMS foundation so plan-only and final install output prove the single-install path without overstating provider-secret or tenant setup.
- Phase 145: OpenBSD installer plan-only output now labels non-OpenBSD reviews as the current OS instead of misreporting workstation `uname` output as an OpenBSD release, and the final handoff names the exact reusable install options.
- Phase 146: Admin Account child pages now add local section navigation and stable anchors for Governance roles/users/grants/audit and Federated Review summary/pending/approved/rejected panels so long operator account surfaces are easier to scan.
- Phase 147: OpenBSD production validation now reports current DesertCMS Postmark HTTPS transport readiness separately from historical delivery-log failures, so email health checks distinguish stale send errors from the server's present TLS module state.
- Phase 148: Admin nav and workflow-card grids now use shrink-safe wrapping, and contributor billing plan feature rows stack on phones so account/help/settings cards avoid cramped text boxes.
- Phase 149: The Events create/edit form now has a local section nav and stable anchors for details, dates, map/location, RSVP, and tickets so the long event editor is easier to scan without changing event data behavior.
- Phase 150: Directory entry and Booking service editors now include local section navs with stable anchors so profile/contact/category/location and service/location/deposit forms are easier to scan.
- Phase 151: Modules/Features setup navigation now labels Events, Directory, Bookings, Membership, Newsletter, Donations, and Testimonials as the core Modules group, with supporting site tools separated below it.
- Phase 152: Donations campaign and Testimonials editor forms now include local section navigation with stable anchors for their campaign/fundraising/display and testimonial/review/related/display panels.
- Phase 153: Membership portal/resource and Newsletter settings/announcement forms now split dense inline editors into anchored subpanels with local form navigation.
- Phase 154: OpenBSD installer output and install docs now consistently name the managed `desertcms_slowcgi` service in the single-install handoff instead of the base slowcgi service.
- Phase 155: Provider setup documentation now distinguishes a valid OpenBSD install from Postmark/Stripe activation, with validation warnings tied to the workflows they block.
- Phase 156: Modules/Features setup navigation now uses a distinct clickable catalog parent with nested Core/Product Modules and Site Tool Modules groups so first-party feature pages read as children of Modules instead of peer admin sections.
- Phase 157: Site-tool module settings pages now expose local section navigation and stable anchors for Map / Locations, Showcase, Forms, and Docs / Resource Hub so long settings and inbox/catalog pages scan cleanly.

Current local version: DesertCMS v1.17.114.

## Versioning

DesertCMS uses simple product versions:

- `v1.0`: initial local baseline.
- `v1.2`: Search & Discovery, SEO, and analytics cleanup iteration.
- `v1.2.1`: current Site Settings navigation cleanup after v1.2.
- `v1.3`: contributor request/onboarding workflow and master-site contributor surfacing.
- `v1.3.1`: expanded contributor-site documentation.
- `v1.3.2`: reusable install defaults, provider integration guide, and DesertCMS placeholder cleanup.
- `v1.3.3`: installer public-root-name setting for generated webroot selection.
- `v1.4`: Master Control dashboard for the contributor subCMS fleet.
- `v1.4.1`: Master Control admin repair actions, strict contributor-subdomain filtering, and standalone master config preservation.
- `v1.5`: provisioning health event logs, job detail review, and admin retry controls for contributor subCMS actions.
- `v1.5.1`: admin CGI response-header hardening for OpenBSD `httpd`/`slowcgi`.
- `v1.6`: Contributor Blueprints for selecting subCMS defaults before invite acceptance or request approval.
- `v1.7`: Governance roles and audit logs for master CMS and contributor subCMS oversight.
- `v1.8`: Federated Content Review queue for master-approved contributor media and posts.
- `v1.9`: Service Plans for hosted subCMS plan assignment, billing metadata, and fleet usage oversight.
- `v1.9.1`: Service Plan assignment syncs quota settings into contributor subCMS databases.
- `v1.10`: Security hardening as a product feature: tenant-isolation audit, last-login fleet visibility, and stricter contributor path sandboxing.
- `v1.11`: Commerce model decision controls for direct Stripe Checkout versus disabled or marketplace-planning modes.
- `v1.14.3`: logo/media fit controls, generated logo derivatives, admin previews, and bounded header/admin logo display.
- `v1.15`: builder sections, reusable block insertion, block spacing controls, responsive editor previews, and module-page overrides.
- `v1.16`: Theme System tokens for typography, body scale, interface font, button style/radius, card style/radius, and default public theme consumption.
- `v1.16.1`: OpenBSD font package catalog, root-worker package installs, package-backed typography choices, and local `/assets/fonts/` publishing.
- `v1.16.2`: dead legacy cleanup for old production domains, dated OpenBSD validation wording, upgrade examples, and Analytics naming.
- `v1.16.3`: OpenBSD font package refresh/install command-path hardening and package-repository fallback for `httpd`/`slowcgi` and cron environments.
- `v1.16.4`: OpenBSD sandbox allowlisting for font package catalog refreshes inside the admin CGI.
- `v1.16.5`: centralized version reading through `DesertCMS::Version` for admin, operations, support bundles, and release downloads.
- `v1.16.6`: responsive media derivatives, rendered image dimensions/srcsets, generated site-image manifests, and Media Library readiness checks.
- `v1.16.7`: mobile-friendly admin card tables and clearer empty states across Master Control, Operations, Contributor Requests, and Provider Readiness surfaces.
- `v1.16.8`: Postmark HTTPS transport readiness checks, actionable OpenBSD SSL module errors, and safer test/contributor email sending.
- `v1.16.9`: release safety guard for restoring `bin/desertcms.cgi` executable mode after deploys and upgrades.
- `v1.16.10`: hardened Postmark HTTPS transport loading in the live admin CGI request path.
- `v1.16.11`: defensive Postmark HTTPS module loading with CGI-visible path diagnostics for OpenBSD package visibility.
- `v1.16.12`: OpenBSD sandbox fix so CGI requests can read Perl `libdata` modules required for Postmark HTTPS.
- `v1.16.13`: OpenBSD pledge fix allowing Perl TLS XS modules and DNS lookups for Postmark HTTPS sends.
- `v1.16.14`: OpenBSD pledge fix allowing file mode updates during sandboxed media storage.
- `v1.16.15`: idempotent OpenBSD sandbox activation so repeated admin requests and in-process test runs do not reapply `unveil`.
- `v1.17`: security hardening sweep for owner-only/signed upgrade controls, owner-only tenant seeding, trusted proxy handling, global CGI body limits, generated contributor portraits, bound service-plan Stripe webhooks, exact destroy archive paths, and nested tenant-root audits.
- `v1.17.1`: Analytics dashboard polish with clearer metric cards, chart panels, dashboard empty states, and mobile labeled table cards.
- `v1.17.2`: Analytics Site Health strip layout and full DB-IP City Lite GeoIP range refresh for stronger worldwide location coverage.
- `v1.17.3`: settings page polish with shared status summaries across Settings, Site & SEO, Modules, Contributors, Master Control, and Operations, plus sticky save actions for long settings forms.
- `v1.17.4`: Analytics dashboard object sizing so operational health items and chart panels use standard compact, medium, large, wide, and full-width layouts instead of forced equal boxes.
- `v1.17.5`: Analytics dashboard polish with overflow-safe health items and a two-stack content flow that lets Popular Pages lead directly into Visits Per IP beside Visitor Locations.
- `v1.17.6`: mobile admin table cards for fleet, requests, delivery logs, operations, billing/service plans, and provider checks, with multi-action rows collapsed into a simple Actions menu on narrow screens.
- `v1.17.7`: Analytics dashboard polish with aligned metric card states, a distinct alert strip, explicit chart fill scaling, and clearer empty states.
- `v1.17.8`: public form polish with grouped contact/media sections, character counters, image upload previews, preserved contributor request errors, and clearer validation messages.
- `v1.17.9`: contributor request lifecycle cleanup so approved requests tied to destroyed/archived sites no longer appear active, plus a 30-day duplicate email request cooldown.
- `v1.17.10`: Contributors delivery log scroll cap with a sticky header and roughly ten visible desktop rows before scrolling.
- `v1.17.11`: provisioning queue command-output capture and contributor public-root ownership repair so failed site creates can be diagnosed and retried cleanly.
- `v1.17.12`: contributor directory route cleanup so `/contributors/` is served by the Contributor Requests module instead of stale custom content pages.
- `v1.17.13`: Master Control polish with a top fleet summary, Healthy / Needs Attention / Failed sections, compact storage/operations cells, and quieter repair/retry actions.
- `v1.17.14`: contributor onboarding polish with guided progress on Contributors, request review, profile completion, and contributor Billing, plus prominent email delivery failure warnings.
- `v1.17.15`: contributor Billing polish with plan comparison cards, current-tier emphasis, safe Stripe-hosted management/cancellation messaging, and clearer missing Stripe Price ID states.
- `v1.17.16`: public site polish with stronger mobile header/footer behavior, shared module-page spacing, contributor placeholders, card-based Showcase/Contributors layouts, improved public forms, and Shop pages rendered through the shared public shell.
- `v1.17.17`: Theme Builder live preview with desktop and mobile public-shell samples for header/footer variants, logo sizing/fit/focal point, typography, buttons, and cards before saving.
- `v1.17.18`: admin microcopy and empty-state polish with clearer setup actions for empty lists, action-specific recovery guidance for failures, and friendlier provider, operations, contributor, billing, and editor notices.
- `v1.17.19`: admin interaction polish with inferred loading labels on submit/rebuild/queue actions, submit-button disabling while work is running, closeable notices, and shared confirmation modals for destructive actions.
- `v1.17.20`: responsive QA and visual design polish with clearer phone/tablet nav states, consistent focus rings, standardized card/button/badge surfaces, safer mobile action controls, and better public form/docs/shop/contributor spacing.
- `v1.17.21`: contributor product-mode polish with hosted-site terminology, feature-catalog language, platform-managed provider/font controls, and route policy coverage for contributor-facing surfaces.
- `v1.17.22`: master settings grouping with Admin Account and Contributor subnavs, tabbed Theme/Layout controls, preview-side color theme controls, and public theme mode persistence cleanup.
- `v1.17.23`: Theme/Layout Preview & Colors layout fix with full-width preview flow, non-sticky Site & SEO section nav, and regression coverage for both behaviors.
- `v1.17.24`: Media pipeline terminology pass with private source asset wording, optimized public derivative copy, Image block labels, and media search readiness checks.
- `v1.17.25`: Non-image media asset support with private document/resource uploads, authenticated source downloads, document cards, and image-only public/shop picker safeguards.
- `v1.17.26`: Public resource publishing workflow for selected non-image assets, Resource page-builder blocks, `/assets/resources/` delivery, and unpublish safeguards for in-use resources.
- `v1.17.27`: Media Library filter tabs and counts for Images, Documents, Resources, Unused, Published, and Private Source Only assets.
- `v1.17.28`: Enriched document/resource metadata and previews with type labels, byte labels, safe text snippets, and clearer Resource-card metadata.
- `v1.17.29`: Media Library bulk actions for selected resources, unused-asset cleanup, and shared metadata updates with per-asset safety skips.
- `v1.17.30`: Contributor Billing usage breakdown for media storage, remaining plan storage, images, documents, public resources, and private-source-only files.
- `v1.17.31`: Plan-gated Resource Downloads with locked upgrade states plus per-plan source asset upload limits shown in Media and Billing.
- `v1.17.32`: Media Lifecycle audit with safe cleanup for orphaned resource files, stale generated derivatives, and large unused media while reporting missing private sources for manual review.
- `v1.17.33`: Media Library and editor picker search across titles, descriptions, filenames, snippets, type metadata, alt/source notes, and public paths.
- `v1.17.34`: Best-effort PDF, DOCX, XLSX, and PPTX preview extraction for admin/editor snippets, headings, search metadata, and metadata-only fallback states.
- `v1.17.35`: Media retention candidates for old unused private source assets, archive-first cleanup under `backup_dir/media-retention/`, and lifecycle safeguards that keep referenced public resources during cleanup.
- `v1.17.36`: Contributor Media and Billing storage pressure indicators with remaining-plan storage, per-file upload headroom, and warnings before quota-blocked uploads.
- `v1.17.37`: Audio/video private source support for MP3, M4A, WAV, OGG, WebM audio, FLAC, MP4, M4V, MOV, WebM video, and OGV, including filters, labels, search metadata, and resource publishing.
- `v1.17.38`: Media Library organization metadata with categories, tags, collections, organization filters, searchable editor picker metadata, and bulk metadata application.
- `v1.17.39`: Private generated previews for non-image assets with PDF thumbnail attempts, optional video posters, audio metadata previews, authenticated admin preview serving, and preview artifact cleanup/retention.
- `v1.17.40`: Media action capability hardening with separate private source download, public resource publishing, bulk management, metadata edit, and cleanup/delete permissions.
- `v1.17.41`: Queued private preview jobs for retrying unavailable PDF thumbnails and video poster frames from Media Lifecycle or `desertcms-maint.pl media-preview-jobs`.
- `v1.17.42`: Documentation rebuild with separate Site Management and Technical guides, audience-grouped generated docs, OpenBSD 7.4 install guidance, current media/provider/contributor coverage, and removal of legacy provider-specific docs.
- `v1.17.43`: Generated documentation cleanup so deleted Markdown docs remove stale public docs pages on rebuild.
- `v1.17.44`: Documentation page navigation reflow so grouped docs links use a full-width, two-column nav area on desktop and a single column on mobile.
- `v1.17.45`: Showcase module polish with `/showcase/` generated output, legacy `/gallery/` redirect compatibility, public resource-download cards, Showcase feature/settings copy, docs, and regression coverage.
- `v1.17.46`: Documentation page navigation comfort hotfix with a full-width grouped link grid, larger docs nav tap targets, and theme upgrade CSS for existing installations.
- `v1.17.47`: Forms module upgrade with public contact, quote request, application, intake, RSVP, private supporting uploads, configurable Postmark notifications, richer admin inbox rows, docs, and regression coverage.
- `v1.17.48`: Docs / Resource Hub polish with Markdown resource metadata for guides, references, local archives, member resources, FAQs, help centers, public hub cards, article metadata strips, and theme upgrade CSS.
- `v1.17.49`: Docs / Resource Hub access policy that holds member, staff, private, restricted, and draft resources in the admin catalog instead of generating public static pages or sitemap URLs.
- `v1.17.50`: Map / Locations generalization with `location_kind`, generalized admin/public copy, `kind` and `kind_label` map pin data, and point-based service-area wording.
- `v1.17.51`: Shop / Catalog split with catalog-only listings, listing types, inquiry CTAs, separate `shop_payments` plan gating, checkout readiness checks, and preserved marketplace fee checkout.
- `v1.17.52`: Events module with standalone event records, public `/events/` calendar and detail pages, RSVP, recurrence, event locations, ICS export, and separate Event Payments entitlement.
- `v1.17.53`: Events runtime compatibility for OpenBSD deployments using in-tree DateTimeLite support instead of unavailable calendar/date CPAN dependencies.
- `v1.17.54`: Directory module with standalone public profiles/listings, moderated listing suggestions, contributor feature catalog integration, blueprint defaults, sitemap entries, and Map / Locations pins.
- `v1.17.55`: Bookings / Appointments module with standalone service listings, request forms, admin review/export, optional Postmark notifications, map pin integration, and separate Booking Deposits checkout entitlement.
- `v1.17.56`: Membership / Gated Content module with member accounts, groups, invites, `/members/` portal, gated pages/posts, member-only docs, authenticated private downloads, and separate Membership Payments entitlement.
- `v1.17.57`: Newsletter module with public `/newsletter/` signup, subscriber tags and segments, unsubscribe links, CSV export, announcement drafts, digest generation from posts/events/directory/catalog, Postmark readiness gating, and send history.
- `v1.17.58`: Donations / Fundraising module with public `/donate/` campaigns, goals, suggested/custom amounts, donor messages, CSV export, separate Donation Payments entitlement, Stripe checkout, webhook fulfillment, and marketplace platform fees.
- `v1.17.59`: Testimonials / Reviews module with public `/testimonials/` approved praise, optional ratings, moderated public submissions, related directory/booking links, CSV export, navigation, sitemap, and feature catalog support.
- `v1.17.60`: Admin navigation cleanup that keeps Events, Directory, Bookings, Membership, Newsletter, Donations, and Testimonials setup pages under the Modules/Features catalog instead of the general Editor nav.
- `v1.17.61`: OpenBSD install/validation now forwards all first-party dynamic module routes, with admin UI wrapping polish for long labels in buttons, settings section navs, sticky actions, and module cards.
- `v1.17.62`: Events, Directory, Bookings, Membership, Newsletter, Donations, Testimonials, and Docs / Resource Hub admin tables now use responsive card-table markup with mobile row labels.
- `v1.17.63`: Older admin management tables now use responsive card-table markup and mobile row labels for content lists, templates, sections, Shop orders, backups, Governance, Federated Review, Contributor Blueprints, Forms submissions, and OpenBSD font package jobs.
- `v1.17.64`: OpenBSD installs now use one maintained installer path with optional DB-IP City Lite GeoIP refresh, schema-derived database validation, root-worker cron checks, compressed GeoIP dependency checks, and a legacy Vultr wrapper that delegates to the supported installer.
- `v1.17.65`: Module setup pages now stay under Modules/Features navigation: master shows a primary Modules section, contributor sites keep Features active, and Events, Directory, Bookings, Membership, Newsletter, Donations, Testimonials, and related module setup pages no longer appear as Editor/Site Builder peer navigation.
- `v1.17.66`: Long module setup pages now have in-page section navigation and stable anchors across Shop / Catalog, Directory, Bookings, Events, Newsletter, Donations, Testimonials, and Membership, improving scanability without changing module data or routing.
- `v1.17.67`: Shared admin CSS now wraps dense UI text more reliably across split headers, grouped actions, status pills, health cards, metric cards, workflow cards, billing price rows, contributor feature cards, compact buttons, and table action cells.
- `v1.17.68`: OpenBSD installs now run the production validator by default, support a `--no-post-install-validate` escape hatch, and keep Admin/module routes live through a generated HTTP-only config when TLS is still pending.
- `v1.17.69`: Dense admin setting forms now apply shared shrink/wrap behavior to labels, helper text, inline links/code, provider status cards, checkbox cards, and long checkbox grids across module, plan, account, and Site & SEO surfaces.
- `v1.17.70`: OpenBSD provider-hook readiness now forwards the main-domain `/stripe/webhook` route, keeps Shop / Catalog Stripe webhook URLs outside the `/shop` path prefix, and reports Postmark sender/webhook plus Stripe webhook readiness in production validation.
- `v1.17.71`: OpenBSD upgrade worker now normalizes each configured `/var/www/htdocs/<site>` public root to the app user before rebuilds, preventing stale root-owned generated docs or assets from blocking upgrades and reseeds.
- `v1.17.72`: OpenBSD production validation now scans generated public roots for nested owner/group drift and reports bounded examples when files or directories are not owned by `_desertcms:_desertcms`.
- `v1.17.73`: Dense admin surfaces now apply shared shrink/wrap behavior to table cell children, empty states, notices, details/definition lists, and code/preformatted blocks so long operational or module text does not break narrow layouts.
- `v1.17.74`: OpenBSD installs now support `--plan-only`, a non-mutating review mode that validates supplied settings, prints DNS guidance and the install plan, skips password collection, and exits before packages, users, files, firewall, services, GeoIP import, or validation are changed.
- `v1.17.75`: Master Control now expands Provider Readiness with detailed Email / Postmark and Payments / Stripe panels, setup links, readiness check rows, and webhook endpoint guidance for checkout and hosted service billing.
- `v1.17.76`: Module setup pages now render a dedicated Modules/Features setup nav, with MasterCMS showing full module setup links and SubCMS showing plan-available feature setup links while payment entitlements stay inside their parent module pages.
- `v1.17.77`: OpenBSD production validation now verifies pf is enabled at boot, currently active, configured with the SSH admin allowlist, and running loaded rules for public HTTP and HTTPS traffic.
- `v1.17.78`: OpenBSD production validation now audits hosted contributor site readiness, including expected config/data/public paths, inherited SubCMS config values, SQLite presence, and httpd routing for active or disabled contributor domains.
- `v1.17.79`: OpenBSD production validation now audits provider webhook endpoint routing for checkout, service billing, event tickets, booking deposits, donations, and tokenized Postmark bounce/spam hooks.
- `v1.17.80`: Module setup pages now show a labeled Modules/Features setup nav, group Events, Directory, Bookings, Membership, Newsletter, Donations, and Testimonials together, and wrap dense nav/status text without truncating important labels.
- `v1.17.81`: OpenBSD generated and example configs now list the full first-party module default set, including newer Events, Directory, Bookings, Membership, Newsletter, Donations, and Testimonials flags, with installer safety coverage to keep fresh installs aligned.
- `v1.17.82`: Service Plans now group feature entitlements into public site features, payments/deposits, and publishing utilities with responsive cards so long plan setup lists no longer appear as one dense checkbox wall.
- `v1.17.83`: Operations and Recovery now exposes a local section nav with stable anchors for bulk maintenance, backup schedule, restore testing, rollback, support bundles, recent jobs, and the Upgrade jobs panel.
- `v1.17.84`: The marketing-site seeder now restores generated public files to the configured public-root owner/group when a release reseed is run as root, keeping OpenBSD validation clean after downloads are refreshed.
- `v1.17.85`: Master Control now exposes a local section nav with stable anchors for overview, fleet maintenance, health groups, provider readiness, tenant isolation, disabled/archived sites, and provisioning queue panels.
- `v1.17.86`: The OpenBSD installer now prints a single-install coverage checklist and final installed-coverage handoff for packages, filesystem, services, firewall, routing, CMS initialization, GeoIP, TLS, and validation.
- `v1.17.87`: Hosted SubCMS Billing now includes a compact provider-readiness strip for plan billing, Postmark sender inheritance/customization, Stripe payout readiness, and platform fee state.
- `v1.17.88`: Modules/Features setup navigation now uses explicit Module Catalog and Feature Catalog parent links, labels setup pages as child navigation, and improves wrapping for long first-party feature names.
- `v1.17.89`: Media Library search, organization filters, bulk actions, and Shop / Catalog contributor filters now use flexible toolbar grids and wrapped count text to avoid cramped admin controls.
- `v1.17.90`: Visual editor preview bars, block-add toolbar, reusable section insertion, rich text tools, and inline block settings now shrink and wrap more safely in compact admin layouts.
- `v1.17.91`: OpenBSD production validation now reports hosted SubCMS provisioning queue health, including failed provisioning jobs, stale queued/running jobs, and recent open jobs.
- `v1.17.92`: Hosted SubCMS provisioning validation now filters historical failed jobs that no longer block the current site state, while still warning on unresolved failed actions and stale open jobs.
- `v1.17.93`: OpenBSD production validation now reports recent email delivery health from `email_delivery_logs`, warning on failed sends, bounces, spam events, or complaints from the last seven days.
- `v1.17.94`: OpenBSD production validation now reports payment workflow health across service billing, Shop, Events, Bookings, Membership, and Donations, warning on stale pending records and recent failed, canceled, refunded, or ignored payment records.
- `v1.17.95`: Contributor product navigation now switches to the menu at narrower desktop widths and keeps the resize behavior aligned with that contributor-specific breakpoint.
- `v1.17.96`: OpenBSD setup guidance now installs and starts `desertcms_slowcgi`, matching the maintained installer, validator, and upgrade worker service path.
- `v1.17.97`: Public Events ticket controls, Shop buttons, and module action links wrap long labels and stack payment forms before narrow tablet layouts crowd.
- `v1.17.98`: Service Plans gets a local section nav and stable anchors so plan lists, entitlement groups, provider overrides, assignment, and usage are easier to scan.
- `v1.17.99`: Contributor Blueprints gets local section navigation and stable anchors so module defaults, theme/SEO, limits, surfacing, and default pages are easier to scan.
- `v1.17.100`: Modules/Features setup navigation now groups the catalog, first-party feature modules, and supporting site tools so long module lists are easier to scan and clearly remain under the module surface.
- `v1.17.101`: OpenBSD installer plan and completion reports now explicitly list dynamic module routing, static generated module output, provider webhook paths, and the hosted SubCMS foundation while leaving provider secrets and tenant creation as MasterCMS setup.
- `v1.17.102`: OpenBSD installer plan-only reviews now avoid false OpenBSD release labels off-server and give a more exact rerun handoff for TLS, GeoIP, validation, dynamic module routes, provider hooks, and SubCMS foundation checks.
- `v1.17.103`: Admin Account Governance and Federated Review pages now include local section navs with stable anchors so account access, audit, and contributor review panels stay scannable without becoming top-level settings clutter.
- `v1.17.104`: OpenBSD validation now uses DesertCMS's email transport helper to report current Postmark HTTPS readiness separately from historical delivery-log warnings.
- `v1.17.105`: Admin editor/account nav links and workflow-card grids now wrap within their boxes, and contributor billing feature rows stack label/value text on phone widths.
- `v1.17.106`: Events create/edit forms now expose a local section nav with stable anchors for details, recurrence, map/location, RSVP, and tickets.
- `v1.17.107`: Directory entry and Booking service editors now expose local section navs with stable anchors for their profile/contact/category/location and service/location/deposit panels.
- `v1.17.108`: Modules/Features setup navigation now makes the seven first-party product modules a clearly named Modules group while keeping site tools and payment entitlements out of primary navigation.
- `v1.17.109`: Donations campaign and Testimonials editor forms now expose local section navs with stable anchors so those long module editors are easier to scan.
- `v1.17.110`: Membership portal/resource and Newsletter settings/announcement forms now expose local form navs and smaller anchored panels for better scanning on dense admin pages.
- `v1.17.111`: OpenBSD installer plan/final output and install guide now consistently point operators at the managed `desertcms_slowcgi` service for the single-install path.
- `v1.17.112`: Provider readiness docs now make clear that Postmark and Stripe setup warnings can remain after a valid base install until the operator finishes MasterCMS provider configuration.
- `v1.17.113`: Modules/Features setup navigation now presents the module catalog as the parent and nests Core/Product Modules plus Site Tool Modules underneath, making Events, Directory, Bookings, Membership, Newsletter, Donations, and Testimonials clearly live under Modules.
- `v1.17.114`: Map / Locations, Showcase, Forms, and Docs / Resource Hub settings now include local section navigation with stable anchors for status, copy, delivery, submissions, and catalog panels.

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
