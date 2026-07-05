---
title: Managing Contributor Sites
summary: A non-technical operator guide for hosted contributor sites, requests, blueprints, service plans, billing state, provisioning, support, and contributor lifecycle.
audience: Site Management
resource_type: Guide
tags: contributor sites, service plans, billing
updated: 2026-07-05
access: Public
order: 30
---

# Managing Contributor Sites

Contributor sites are hosted SubCMS instances. They use the DesertCMS engine, but the contributor experience should feel like a focused site builder, not a smaller copy of the platform backend.

The master site remains the platform operator console. Use MasterCMS to create, review, provision, support, and govern hosted sites.

## MasterCMS Responsibilities

The master operator manages:

- Contributor applications.
- Contributor site records.
- Blueprints.
- Service plans.
- Plan billing state.
- Provider readiness.
- Provisioning and lifecycle jobs.
- Federated review.
- Governance.
- Operations and support bundles.
- Upgrades and rollback jobs.

Contributor site managers handle their own content, media, design, enabled plan features, usage, billing help, and account help.

## Contributor Requests

Contributor Requests supports public applications for hosted sites.

A typical flow is:

1. Visitor submits a contributor request.
2. Master operator reviews the request.
3. Operator approves or denies the request.
4. Approval can assign a blueprint and service plan.
5. The provisioning queue creates the contributor site.
6. Email delivery records show whether the applicant was notified.

Duplicate requests are rate-limited so the review queue stays useful. Denied applicants should receive a clear outcome without exposing internal review notes.

## Contributor Site Records

Contributor Sites is the fleet list for hosted sites.

Use it to check:

- Site id.
- Domain.
- Status.
- Assigned plan.
- Billing status.
- Blueprint.
- Media quota.
- Upload limit.
- Page and post limits.
- Provisioning health.
- Last known login.
- Queue state.

Lifecycle actions such as enable, disable, destroy, repair, and retry are platform operations. They stay in MasterCMS and should not appear as normal contributor settings.

## Blueprints

Blueprints are repeatable starting points for contributor sites.

Blueprints can set:

- Vertical category.
- Default pages.
- Theme defaults.
- Enabled modules.
- SEO defaults.
- Media quota.
- Page and post quotas.
- Whether contributor Showcase assets can surface on the master site.
- Whether contributor posts can surface on the master site.

Built-in categories include:

- Photographer.
- Artist portfolio.
- Writer or blog.
- Small business.
- Local archive.
- Event or community site.
- Shop or catalog.
- Docs / Resource Hub.

Blueprints are product defaults, not only visual templates. They should help the first contributor login feel coherent.

## Service Plans

Service Plans define what a hosted contributor site can use.

Plan fields include:

- Name and slug.
- Description.
- Monthly price.
- Stripe Price ID for hosted-site billing.
- Media quota.
- Per-file upload limit.
- Page quota.
- Post quota.
- Feature map.
- Platform Showcase surfacing.
- Master post surfacing.
- Custom Postmark sender override.
- Stripe Connect payout access.
- Indexing override access.
- Stripe platform fee basis points.

The plan feature map controls whether modules are available, enabled, locked, or managed by the platform. Payment entitlements are intentionally separate from the base features they extend.

## Plan Assignment

When a plan is assigned, DesertCMS copies plan state into the contributor site settings so the SubCMS can show truthful limits and locked feature states.

Plan sync affects:

- Feature availability.
- Media quota.
- Upload limit.
- Page and post quotas.
- Postmark sender override allowance.
- Stripe Connect payment allowance.
- Indexing override allowance.
- Platform fee settings.

Plan changes should preserve data. A downgrade should lock future privileged actions before deleting or unpublishing existing work.

## Billing State

Billing state lives with the hosted site record and assigned service plan.

Contributor Billing should clearly show:

- Current plan.
- Current billing status.
- Current period end when available.
- Usage and limits.
- Locked features.
- Upgrade path.
- Cancellation or downgrade guidance.
- Stripe-hosted plan management when configured.

Service billing is the contributor paying the platform for the hosted site. Site payments are visitor payments to the contributor site. Keep those concepts separate in support and documentation.

## Provider Inheritance

Contributor sites inherit platform provider settings by default.

Inherited platform services include:

- Postmark delivery.
- Stripe service billing.
- Search indexing defaults.
- Operations.
- Backups.
- Upgrades.

Plan options can allow controlled overrides:

- Custom Postmark sender signatures for contributor email.
- Stripe Connect payout setup for contributor site payments.
- Search indexing override controls.

Even when a contributor connects Stripe payouts, marketplace checkout can still use the master Stripe account and retain the configured platform fee.

## Provisioning And Lifecycle

Provisioning is queue-driven and root-worker backed.

Lifecycle work can:

- Provision a new site.
- Enable a disabled site.
- Disable an active site.
- Destroy a site after path binding checks.
- Repair generated paths.
- Retry failed jobs.
- Rebuild contributor public output.
- Rewrite and validate webserver routing.

If a lifecycle job fails, review the queue event output before retrying. Avoid manual filesystem changes unless the support issue is clearly outside the product workflow.

## Federated Review

Federated Review decides which contributor content can surface on the master site.

Use it when the master site includes:

- Contributor Showcase assets.
- Contributor posts.
- Directory-style contributor cards.
- Public profile cards.

This is a master-side editorial review workflow. It should not appear as a normal contributor setting.

## Governance

Governance controls admin roles, access, and audit logs.

Keep governance on the master side. Contributor SubCMS users should see account settings and help, not the platform governance model.

## Support Checklist

When a contributor reports a problem, check:

- Site status.
- Billing status.
- Assigned service plan.
- Feature map and locked features.
- Media quota and storage pressure.
- Upload limit.
- Provider readiness.
- Recent provisioning or lifecycle events.
- Email delivery logs.
- Whether the issue belongs in contributor support or master operations.

Good support keeps platform internals out of the contributor UI while still giving operators enough state to diagnose the issue.
