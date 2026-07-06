---
title: Integrations And Commerce
summary: Technical reference for Postmark, Stripe service billing, Stripe site payments, Stripe Connect, checkout readiness, provider inheritance, Search Console, IndexNow, GeoIP, webhooks, and provider validation.
audience: Technical
resource_type: Reference
tags: Postmark, Stripe, indexing
updated: 2026-07-05
access: Public
order: 150
---

# Integrations And Commerce

DesertCMS keeps provider configuration in the master/operator layer by default. Contributor sites inherit platform services unless a plan explicitly allows a controlled override.

OpenBSD installation and provider activation are separate milestones. A valid server install can still report Postmark or Stripe setup warnings until the operator finishes provider configuration in MasterCMS.

## Provider Inheritance

Contributor sites inherit:

- Postmark delivery.
- Stripe service billing.
- Stripe site payment settings when marketplace checkout uses the master account.
- Search indexing defaults.
- Operations.
- Backups.
- Upgrades.

Plan options can allow:

- Custom Postmark sender signatures.
- Stripe Connect payout setup.
- Indexing override controls.

Contributor-facing screens should summarize inherited state and plan-controlled options without exposing platform internals or raw provider tokens.

## Postmark

Postmark settings include:

```text
postmark_sender_mode =
postmark_from_email =
postmark_server_token =
postmark_webhook_token =
```

Default contributor behavior is platform-managed email delivery.

A service plan can allow a custom sender signature through `allow_postmark_sender_override`. When enabled, the contributor site can use its own approved sender identity while platform support still owns delivery readiness.

Postmark can be used by:

- Contributor request notifications.
- Forms notifications.
- Event RSVP or ticket notifications.
- Booking request notifications.
- Membership notifications.
- Newsletter sends.
- Provider bounce/spam webhooks.

Forms uses `forms_notification_email` first and can fall back to the contributor request recipient. Uploaded files are not attached to notification email; the email should link staff back to the authenticated inbox where private uploads can be downloaded.

## Stripe Service Billing

Service billing is the hosted-site subscription or plan payment.

Service plan fields include:

- `monthly_price_cents`
- `currency`
- `stripe_price_id`
- `stripe_checkout_session_id`
- `stripe_customer_id`
- `stripe_subscription_id`
- `billing_status`
- `billing_current_period_end`

The master platform account owns service billing. Service billing webhooks route through `/billing/stripe/webhook`.

## Stripe Site Payments

Site payments are visitor purchases or contributions on a site.

For direct sales, the CMS uses Stripe Checkout with a configured secret key and webhook secret.

For contributor marketplace sales, the intended model is:

- Checkout uses the master Stripe account.
- The contributor connects a Stripe payout account.
- Proceeds transfer to the contributor connected account.
- The platform keeps the configured fee.

Relevant fields include:

- `allow_stripe_connect`
- `stripe_connect_account_id`
- `stripe_connect_onboarding_status`
- `stripe_connect_charges_enabled`
- `stripe_connect_payouts_enabled`
- `stripe_platform_fee_bps`

## Commerce Models

`DesertCMS::Commerce` supports:

| Mode | Checkout behavior |
| --- | --- |
| `disabled` | No checkout. |
| `master_owned` | Direct Stripe Checkout for the master instance. |
| `contributor_owned` | Direct Stripe Checkout for a contributor instance. |
| `platform_marketplace` | Master Stripe account with contributor connected account and platform fee. |
| `marketplace_pending` | Planning state, not ready for live checkout. |

Readiness checks look at the selected model, Stripe key, webhook secret, Connect account, plan allowance, and feature-specific state.

The admin `Settings > Payments` page is the shared Stripe readiness hub for Shop / Catalog, Events, Bookings, Membership, and Donations. Module setup pages keep their module-specific pricing or content controls, but they should delegate Stripe readiness and checkout guards to `DesertCMS::Commerce`.

## Checkout Readiness

Checkout should be enabled only when all required conditions are true.

Common requirements:

- Base feature is enabled.
- Payment entitlement is included.
- Commerce model allows checkout.
- Stripe secret key is configured.
- Stripe webhook secret is configured.
- Marketplace mode has a connected account when needed.
- Contributor plan allows Connect when marketplace payouts are involved.
- The public item has a payable amount or product state.

If readiness fails, public checkout POSTs should be rejected and buy controls should be hidden.

Public module routes should still render through the normal public shell when checkout is unavailable. A disabled payment state should never fall back to admin layout assets or bare HTML.

## Shop / Catalog

Shop / Catalog separates listings from checkout:

- `shop` enables the public `/shop` catalog route.
- `shop_payments` enables Stripe Checkout, marketplace payouts, platform fees, paid orders, and rights-purchase controls.
- Catalog records remain tied to media assets in this pass.
- Listings can be products, services, digital items, portfolio items, inquiry-only items, or other catalog entries.
- Catalog-only listings can be active without prices and show an inquiry CTA instead of buy controls.
- Payment-enabled listings can use personal, commercial, and full-rights prices when checkout readiness passes.
- Checkout POSTs are rejected when Shop Payments is locked or checkout is not ready.

Private source files remain private. Public shop cards use optimized image derivatives with responsive `srcset`, dimensions, and transparent PNG or WebP output preserved when the source format supports it.

Full-rights fulfillment can remove an item from sale after purchase.

## Event Payments

Events separates calendar participation from paid ticket checkout:

- `events` enables `/events/`, event pages, RSVP, free tickets, recurrence, locations, and `/events.ics`.
- `event_payments` enables paid tickets, Stripe Checkout, marketplace payouts, platform fees, and paid event orders.
- Shop Payments does not unlock paid event tickets.
- Event Payments does not unlock Shop / Catalog checkout.

Free RSVP and free ticket records can be created without Stripe. Paid ticket POSTs are rejected unless Event Payments is included and checkout readiness passes.

Public Events listings and details should continue using the public shell even when payment readiness fails. Event card images should use responsive public media derivatives instead of hand-built image URLs.

For contributor marketplace ticketing, checkout uses the master Stripe account, transfers proceeds to the contributor connected account, and retains the configured platform fee. Event ticket orders, RSVP records, and webhook idempotency records are separate from Shop / Catalog orders.

## Booking Deposits

Bookings separates service requests from deposit checkout:

- `bookings` enables `/bookings/` service listings, availability text, request forms, request review, CSV export, and Postmark notifications.
- `booking_payments` enables Stripe Checkout deposits, marketplace payouts, platform fees, and booking payment records.
- Shop Payments does not unlock booking deposits.
- Event Payments does not unlock booking deposits.

Booking requests can be submitted without Stripe. Deposit checkout is shown only when Booking Deposits is included, the service has a positive deposit amount, and checkout readiness passes.

Public Bookings cards and detail pages should use the media derivative helpers so transparent service art stays intact and stale image references do not render broken URLs.

Booking requests, booking payments, and booking webhook idempotency records are separate from Shop / Catalog and Event payment tables.

## Membership Payments

Membership separates gated access from paid access:

- `membership` enables `/members/` login, signup or invites, member groups, member dashboards, gated pages/posts, member-only docs, and authenticated private downloads.
- `membership_payments` enables paid member resources, subscription records, Stripe Checkout, marketplace payouts, platform fees, and membership payment records.
- Shop Payments does not unlock paid membership resources.
- Event Payments does not unlock paid membership resources.
- Booking Deposits do not unlock paid membership resources.

Member accounts and private downloads can work without Stripe. Paid membership controls are rejected unless Membership Payments is included and checkout readiness passes.

Membership payment records and webhook idempotency records are separate from Shop / Catalog, Event, Booking, Donation, and service billing records.

## Donation Payments

Donations separates fundraising campaigns from donation checkout:

- `donations` enables `/donate/` campaign pages, suggested and custom amounts, donor messages, goal progress, and donor CSV export.
- `donation_payments` enables Stripe Checkout donations, marketplace payouts, platform fees, webhook fulfillment, and paid donation records.
- Shop Payments does not unlock donations.
- Event Payments, Booking Deposits, and Membership Payments do not unlock donations.

Campaign pages can render without Stripe. Donation checkout POSTs are rejected unless Donation Payments is included and checkout readiness passes.

Donation campaign images should render from active public media records with responsive derivatives and preserved transparency rather than forcing a flattened JPEG preview.

Donation records and webhook idempotency records are separate from Shop orders, Event ticket orders, Booking deposits, Membership payments, and service billing.

## Testimonials / Reviews

Testimonials / Reviews is a content and trust feature, not an integration or payment feature.

- `testimonials` enables approved public testimonials, optional ratings, moderated public submissions, related Directory or Bookings links, and CSV export.
- Testimonials do not require Stripe.
- Testimonials do not require Postmark.
- Testimonials do not unlock Shop Payments, Event Payments, Booking Deposits, Membership Payments, or Donation Payments.

If public submissions are enabled, submitted testimonials are stored as pending records until reviewed. No third-party review import or syndication is part of this pass.

## Newsletter Delivery

Newsletter uses Postmark for first-party announcement and digest sends.

- `newsletter` enables subscriber capture, tags, segments, unsubscribe links, CSV export, announcement drafts, digest generation, and send history.
- Subscriber capture and export do not require Postmark.
- Sending requires inherited or site-level Postmark readiness: HTTPS transport, verified sender address, and server token.
- Contributor sites inherit the master Postmark sender unless their plan allows a custom sender signature.
- Each sent email includes an unsubscribe URL tied to the subscriber record.
- Send history is stored in Newsletter-specific rows while Postmark attempts also use the shared delivery-log path.

Newsletter delivery is separate from Stripe, Shop orders, Event tickets, Booking deposits, Membership payments, and Donations.

## Webhooks

Provider hook routes include:

- `/stripe/webhook` for Shop / Catalog checkout.
- `/billing/stripe/webhook` for hosted service billing.
- `/events/stripe/webhook` for Events ticket checkout.
- `/bookings/stripe/webhook` for Booking Deposits.
- `/donate/stripe/webhook` for Donation Payments.
- Tokenized Postmark bounce/spam webhook routes under the Postmark route prefix.

Payment webhooks should verify signatures, tolerate duplicate event delivery, and record event IDs for idempotency.

## Search Console

Search Console settings include:

```text
google_oauth_client_id =
google_oauth_client_secret =
google_search_console_property =
```

Contributor sites inherit indexing defaults unless the plan allows indexing override.

## IndexNow

IndexNow settings include:

```text
indexnow_enabled = 0
indexnow_key =
```

Use IndexNow for sitemap or URL submission only when configured and allowed.

## GeoIP

GeoIP is local analytics enrichment.

Supported maintenance commands include:

```sh
desertcms-maint.pl geoip-import /var/desertcms/geoip.tsv
desertcms-maint.pl geoip-backfill
desertcms-maint.pl geoip-refresh-dbip-lite
```

Analytics can store raw IP values based on settings. DB-IP Lite attribution is shown when that source is imported.

## Provider Readiness

The OpenBSD validator reports provider state in three layers:

- Transport and routing: Postmark HTTPS transport, provider webhook route forwarding, and application dispatch paths.
- Configuration: Postmark sender/server token/webhook token and Stripe checkout webhook secret.
- Operational history: recent email delivery failures and stale or failed payment workflow records.

Missing Postmark sender/token/webhook token or Stripe webhook secrets are provider setup warnings, not proof that the base install failed. They become production blockers only for workflows that need them: email sends, service billing checkout, Shop Payments, Event Payments, Booking Deposits, Membership Payments, and Donation Payments.

Check:

- Postmark token and sender.
- Postmark webhook token.
- Stripe key and webhook secret.
- Stripe Connect account state.
- Search Console configuration.
- IndexNow key.
- OpenBSD TLS and HTTP readiness.
- Local assets.
- Worker state.
