---
title: Billing And Provider Options
summary: A non-technical guide to hosted-site plans, limits, locked features, service billing, site payments, custom Postmark senders, Stripe Connect, and platform-managed providers.
audience: Site Management
resource_type: Guide
tags: billing, providers, payments
updated: 2026-07-05
access: Public
order: 40
---

# Billing And Provider Options

Billing explains what a hosted contributor site can use, what is locked, what the current limits are, and where to upgrade or get help.

## Two Kinds Of Billing

DesertCMS separates hosted-site billing from visitor payments.

| Concept | Purpose | Owner |
| --- | --- | --- |
| Service billing | The contributor pays the platform for the hosted site plan. | Master platform account. |
| Site payments | Visitors pay a site for catalog items, event tickets, booking deposits, member access, or donations. | Contributor or master site, depending on the commerce model. |

Do not troubleshoot a failed plan subscription as if it were a shop order. Do not troubleshoot a failed visitor checkout as if it were hosted-site billing.

## What Contributor Billing Shows

Contributor Billing should show:

- Current plan.
- Billing status.
- Current period end when available.
- Media storage used and remaining.
- Counts for images, documents, audio, video, public resources, and private-source-only files.
- Per-file upload limit.
- Page and post limits.
- Available features.
- Locked features.
- Upgrade and cancellation path.
- Stripe-hosted billing actions when configured.
- Provider inheritance summary.

## Plans And Limits

Service Plans can define:

- Media quota.
- Per-file upload limit.
- Page quota.
- Post quota.
- Feature availability.
- Platform Showcase surfacing.
- Master post surfacing.
- Custom email sender support.
- Site payment support.
- Stripe payout support.
- Search indexing override support.
- Platform fee for marketplace payments.

When a plan is assigned, a snapshot is copied into the contributor site so the SubCMS can show truthful limits and locked states.

## Locked Features

A locked feature is not an error. It means the current plan does not include it or the required payment/support setting is not ready.

Examples include:

- Shop / Catalog.
- Shop Payments.
- Events.
- Event Payments.
- Directory.
- Bookings / Appointments.
- Booking Deposits.
- Membership / Gated Content.
- Membership Payments.
- Newsletter.
- Donations / Fundraising.
- Donation Payments.
- Testimonials / Reviews.
- Resource Downloads.
- Docs / Resource Hub.
- Forms.
- Custom Postmark sender.
- Stripe Connect payouts.
- Higher media quota.
- Higher upload limit.
- Indexing override controls.

The Features page should explain what is included and what requires an upgrade.

## Payment Feature Pairs

Several public features separate participation from checkout.

| Base feature | Payment feature | What works without the payment feature |
| --- | --- | --- |
| Shop / Catalog | Shop Payments | Catalog and inquiry listings without buy controls. |
| Events | Event Payments | Calendar pages, RSVP, free tickets, recurrence, locations, and calendar export. |
| Bookings / Appointments | Booking Deposits | Service listings, request forms, admin review, export, and notifications. |
| Membership / Gated Content | Membership Payments | Member accounts, groups, private pages, member docs, and authenticated private downloads. |
| Donations / Fundraising | Donation Payments | Campaign pages, suggested amounts, donor intent, goal progress, and donor export. |

Testimonials / Reviews is a content feature and does not require Stripe. Newsletter subscriber capture and export can work without Postmark readiness, but sending requires Postmark.

## Checkout Readiness

Payment-enabled controls appear only when readiness passes.

Readiness can depend on:

- The base feature being enabled.
- The matching payment entitlement being included.
- The selected commerce model allowing checkout.
- Stripe secret key.
- Stripe webhook secret.
- Stripe Connect account for marketplace payouts.
- Plan allowance for Connect payouts.
- Feature-specific record state, such as an active listing, paid ticket, deposit amount, paid member resource, or donation campaign.

If checkout is not ready, the public surface should still render the non-payment part of the feature when possible.

`Settings > Payments` is the shared readiness screen for Shop / Catalog, Events, Bookings / Appointments, Membership / Gated Content, and Donations / Fundraising. Module setup screens should point operators back to that page for Stripe keys, webhook secrets, commerce model, and payout-state issues instead of duplicating provider setup.

## Custom Postmark Sender

By default, contributor sites inherit the master platform Postmark configuration.

A plan can allow a custom sender signature. This lets a contributor site send email as its own approved sender while platform support still owns the readiness boundary.

Common uses include:

- Contact form replies.
- Booking request notifications.
- Event RSVP or ticket notifications.
- Newsletter sends.
- Contributor-branded request messages.

Contributors should not see raw platform provider tokens unless the product intentionally exposes a controlled override.

## Stripe Connect Payouts

For marketplace site payments, a paid plan can allow Stripe Connect.

The intended model is:

- Checkout uses the master Stripe account.
- The contributor connects a payout account.
- Proceeds transfer to the contributor connected account.
- The platform keeps the configured fee.

Connect status should summarize whether charges and payouts are enabled. It should not expose platform credentials.

## Commerce Models

DesertCMS supports these commerce models:

| Mode | Meaning |
| --- | --- |
| Disabled | No public checkout. |
| Master-owned sales | Direct Stripe Checkout for the master instance. |
| Contributor-owned sales | Direct Stripe Checkout for a contributor instance. |
| Platform marketplace payouts | Master Stripe account with contributor connected account and platform fee. |
| Marketplace planning | Planning state that should not accept live checkout. |

For hosted contributor sites, the product goal is platform marketplace payouts when the plan allows Stripe Connect.

## Downgrade And Cancel Expectations

Downgrade behavior should be conservative.

When a contributor downgrades or cancels:

- Existing private source assets remain protected.
- Existing content remains in the database.
- Locked feature controls become unavailable.
- New privileged actions stop before existing data is removed.
- Referenced public resources should not be removed without a clear cleanup action.
- Billing should explain what will stop working before confirmation.
- Platform support can run lifecycle checks if cleanup is needed.

It is better to preserve data and disable new privileged actions than to delete content automatically.

## Account And Help

Account / Help should include:

- Current plan summary.
- Support email.
- Billing help link.
- Docs / Resource Hub links.
- Platform status.
- Provider inheritance summary.

This keeps contributor support inside the product instead of pushing site managers into operator settings.
