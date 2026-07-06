---
title: Creating Modules
summary: Technical guidance for adding first-party DesertCMS modules with definitions, settings, plan gates, capability policy, admin UI, renderer output, dynamic routes, schema, media policy, and tests.
audience: Technical
resource_type: Reference
tags: modules, developer, tests
updated: 2026-07-05
access: Public
order: 140
---

# Creating Modules

DesertCMS modules are first-party feature surfaces, not external plugins. A module usually has a definition, settings, admin UI, optional public output, route policy, plan gates, renderer behavior, and tests.

Use the existing local patterns before adding a new abstraction.

## Module Checklist

For a new module, decide:

- Is it a public generated page, a dynamic CGI route, or both?
- Is it master-only, contributor-available, or master-managed on contributor sites?
- Does it need a database table?
- Does it need private media or public resource files?
- Does it need Postmark, Stripe, Search Console, IndexNow, or GeoIP?
- Does it need a separate payment entitlement?
- How does it behave when disabled?
- What gets cleaned up or hidden during rebuild?
- What tests prove enabled, disabled, locked, and contributor states?

## Module Definition

Add the module to `lib/DesertCMS/Modules.pm`.

A definition should include:

```perl
{
    key                  => 'example',
    label                => 'Example',
    description          => 'Adds the public /example/ page and example settings.',
    public_path          => '/example/',
    settings_path        => '/admin/settings/modules/example',
    setting_key          => 'module_example_enabled',
    default_plan_enabled => 0,
}
```

If the module is master-managed on contributor sites, add:

```perl
managed_by_master_contributor => 1
```

`gallery` is the legacy storage key for the Showcase feature. Avoid renaming existing feature keys unless migration and compatibility behavior are clear.

## Settings

Add a config default in `DesertCMS::Config`:

```perl
module_example_enabled => 0,
```

Add runtime defaults and persistence in `DesertCMS::Settings` when the module has editable settings.

Settings work usually includes:

- Config fallback.
- SQLite settings default.
- Save-list entry.
- Admin form fields.
- Sanitization.
- Contributor plan override behavior where relevant.

Do not store provider secrets in contributor-facing settings unless the product intentionally supports a controlled override.

## Plan Gates

Contributor plans use the module feature map.

The module catalog computes:

- `available`
- `enabled`
- `configured_enabled`
- `locked_by_plan`
- `requires_upgrade`
- `managed_by_master`

Do not hide a feature only by removing a link. The module state should explain whether it is available, disabled, locked by plan, or managed by the platform.

Payment features should be separate from base participation features. For example, Events can exist without Event Payments, and Bookings can exist without Booking Deposits.

## Capability Policy

Map admin routes in `DesertCMS::CapabilityPolicy`.

Use read/write capability pairs when possible:

```perl
return _read_or_write($method, 'view_features', 'enable_allowed_modules') if _matches(
    $path,
    qr{\A/admin/settings/modules/example(?:/|\z)}
);
```

Use existing capabilities when they fit:

- Content editing: `view_content`, `edit_content`.
- Media: `view_media`, `upload_media`, `download_media_sources`, `publish_media_resources`, `delete_media_assets`, `bulk_manage_media`.
- Design: `view_design`, `customize_theme`.
- Features: `view_features`, `enable_allowed_modules`.
- Billing and usage: `view_usage`, `manage_billing`.
- Provider settings: `manage_provider_settings`.
- Operations: `view_operations`, `run_operations`, `run_upgrades`.
- Platform management: contributor, blueprint, service plan, governance, federated, and lifecycle capabilities.

Contributor mode should block master-managed routes in `_contributor_master_managed_route`.

## Admin UI

Use the existing admin shell and product split:

- Master-only modules can appear under MasterCMS settings or operations.
- Contributor-available modules should appear under Features.
- Contributor content tools should use site-builder language.
- Platform-managed options should say they are managed by the platform.
- Plan-locked options should point to Billing or upgrade.
- Dense module editors should use local section navigation and stable anchors.

Avoid operator terms on contributor pages. The contributor `owner` role is a site manager.

## Public Rendering

If the module writes static public output, add renderer behavior in `DesertCMS::Renderer`.

The normal pattern is:

1. Check whether the module is enabled.
2. Skip generated output if published content claims the same URL where that behavior is appropriate.
3. Render through the shared public module shell.
4. Write into `public_root`.
5. Add sitemap entries when public.
6. Remove or replace generated artifacts when disabled.

Generated pages should use the same theme and layout as other public content.

## Dynamic Routes

If the module needs dynamic public behavior, route it through `DesertCMS::App`.

Dynamic routes need:

- Dispatch in `_dispatch`.
- Public responses rendered through `DesertCMS::Renderer::render_module_page` or the shared public response helper, never admin layout helpers.
- CSRF or request validation where applicable.
- Rate limiting or abuse metadata for public submissions.
- Capability checks for admin actions.
- OpenBSD `httpd` FastCGI forwarding if the route is public.
- Validator coverage if the route is required for production.

Static generated module pages do not need CGI forwarding once written to the public root. Forms, checkout, member, comment, rating, and webhook routes do.

## Schema

If the module needs database tables, add them to `sql/schema.sql` and migration or repair logic through the existing migration flow.

Keep tenant ownership explicit for contributor-facing data. Bind destructive operations to the exact owner, site record, row, and path state.

Useful schema practices:

- Add indexes for common status/time lookups.
- Store Stripe webhook event IDs for idempotency when payments are involved.
- Store moderation status for public submissions.
- Store hashed request metadata when needed for abuse review.
- Avoid storing raw secrets in module tables.

## Media

If the module uses media:

- Use `DesertCMS::Media`.
- Do not expose private source paths.
- Use public image derivatives for images, including `srcset`, width, and height metadata.
- Use Resource Downloads for public non-image files.
- Keep form uploads private.
- Respect media capabilities and plan limits.
- Preserve referenced public resources during conservative cleanup.
- Hide or replace stale media references instead of emitting a broken public `<img>` URL.

Resource paths should be under `/assets/resources/` only after intentional publishing.

## Docs / Resource Hub Pattern

Docs / Resource Hub is the reference pattern for a generated content catalog that is editable as Markdown but rendered as a product surface.

Markdown front matter can describe:

- Section through `audience` or `category`.
- Resource type through `resource_type`, `type`, or `kind`.
- Reader metadata through `tags` and `updated`.
- Publication policy through `access`.
- Sort order through `order`.

Only public resources should be written to the public webroot or sitemap. Held resources can remain visible in admin or member routes after authenticated access exists.

## Payment Modules

Payment modules should be readiness-gated.

Check:

- Base feature enabled.
- Payment entitlement included.
- Commerce model allows checkout.
- Stripe key and webhook secret are present.
- Connect account exists when marketplace payouts are required.
- Plan allows Connect when contributor marketplace payments are involved.
- Feature record has a payable item, ticket, deposit, resource, or campaign.

Use `DesertCMS::Commerce::payment_allowed_by_plan`, `payment_model`, and `payment_readiness` instead of open-coding workflow checks in each module. Do not show public checkout controls when readiness fails. Keep the non-payment feature usable when possible.

## Tests

Add or update focused tests for:

- Module definition and defaults.
- Settings save behavior.
- Enabled and disabled public output.
- Renderer cleanup when disabled.
- Sitemap behavior.
- Dynamic route dispatch.
- Capability policy.
- Contributor product mode.
- Plan-gated feature state.
- Payment readiness when applicable.
- Media privacy.
- Public submission moderation.
- Schema migration or table repair.
- Admin terminology when contributor-accessible.

For module-gated editor controls, preserve stored values when a feature is disabled. Do not clear fields just because the UI panel is hidden.

Run:

```sh
prove -l t
```

For docs or public renderer changes, also verify generated HTML and public HTTP routes after rebuild.
