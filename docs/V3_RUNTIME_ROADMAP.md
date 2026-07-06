---
title: DesertCMS v3 Runtime Roadmap
summary: Local development roadmap for the remaining v3 runtime work across Accounts/SSO, Live Streaming, Forums, Social, Notifications/Realtime, and OpenBSD host integration.
audience: Technical
resource_type: Planning
tags: v3, runtime, OpenBSD, security, modules
updated: 2026-07-06
access: Internal
order: 190
---

# DesertCMS v3 Runtime Roadmap

This roadmap covers the remaining runtime behavior needed before DesertCMS v3 can be treated as feature-complete in local development. It does not authorize a push, deploy, live OpenBSD update, release artifact rebuild, or production migration.

v3 stays Perl-based, OpenBSD-specific, and centered on `httpd`, `slowcgi`/CGI, `pf`, `acme-client`, SQLite, and conservative security defaults.

## Execution Order

1. Finish Accounts/SSO runtime hardening.
2. Complete Notifications/Realtime as the shared event bus and delivery layer.
3. Complete Forums and Social permissions, feeds, reports, moderation, and notifications.
4. Complete Live Streaming worker integration, HLS lifecycle, chat, and moderation.
5. Expand OpenBSD host integration tests for staging-only validation.
6. Finish migration and regression coverage for v2 content and module state.

This order keeps identity, permissions, and event delivery stable before features depend on them.

## Planning Rules

- Keep all work on `codex/v3-development` until v3 is complete, verified, and a separate push/deploy approval exists.
- When v3 completion is verified and deployment is explicitly started, target `desertarchives.com` only; do not publish this v3 branch to `desertcms.com` or broader live targets.
- Treat OpenBSD as the production contract even when running mocked Windows/local tests.
- Prefer read-only checks and dry-run command plans until an admin explicitly approves a privileged worker action.
- Keep feature modules optional except where a dependency is explicit, such as Social requiring Accounts.
- Add test coverage with each runtime slice, not as a cleanup phase after all features land.
- Use module manifests as the source of truth for routes, permissions, notification topics, widgets, settings, migrations, and SubCMS gates.

## Dependency Gates

| Gate | Must be true before depending work starts |
| --- | --- |
| Identity gate | Accounts has active/disabled/moderated account states, actor-aware audit events, login throttles, and SSO conflict handling. |
| Event gate | Notifications accepts only manifest-declared topics and can deliver to admin inbox, account inbox, and realtime adapter. |
| Permission gate | Forums, Social, and Live Streaming use the same active-account, moderator, admin-user, and system-action actor patterns. |
| Realtime gate | SSE/WebSocket delivery uses allowed origins, channel filtering, replayable events, and recorded adapter failures. |
| OpenBSD gate | The staging harness validates generated `httpd`, `pf`, `acme-client`, `slowcgi`, schema, package, and Security Center checks without touching live paths. |

## Remaining Runtime Execution Plan

The remaining v3 work should be delivered as runtime slices that each include schema, manifest contract, Perl module behavior, admin/public route integration, notification hooks, and tests. The slices below are ordered by dependency, but each feature area should keep moving with clear integration boundaries.

| Slice | Primary output | Why it comes here |
| --- | --- | --- |
| R1 Identity runtime | Accounts, local auth, SSO, linking, conflict handling, throttles, audit events | Forums, Social, Live Streaming chat, carts, and public notifications need a trustworthy actor model. |
| R2 Event runtime | Notifications bus, topic registry, inboxes, realtime adapter, preferences, retries | Runtime modules should emit events through one path instead of direct feature-specific delivery code. |
| R3 Community runtime | Forums and Social permissions, feeds, reports, moderation, anti-abuse, notification hooks | These modules share account state, moderation queues, report workflows, and public notification rules. |
| R4 Streaming runtime | OBS ingest contract, stream keys, HLS lifecycle, live chat, presence, stream moderation | Streaming depends on identity, event delivery, realtime fanout, SubCMS gates, and OpenBSD path validation. |
| R5 Host runtime | OpenBSD staging harness, generated config validation, Security Center read-only checks | Host guarantees must be proven before any live deploy or release artifact work is allowed. |
| R6 Migration runtime | v2-to-v3 fixtures, Posts module conversion, module state preservation, regression suite | Migration needs the final schema and manifest contracts from the runtime slices. |

### R1 Accounts/SSO Tasks

- Finalize account states: active, disabled, moderated, pending, deleted, and recovery-limited.
- Finish local login, logout, session rotation, password reset, login throttling, and audit events.
- Finish OIDC provider discovery, JWKS cache refresh, RSA JWK and `x5c` validation, nonce, issuer, audience, expiry, and clock-skew checks.
- Add account linking and unlinking for logged-in users, including provider identity reuse protection and last-login-provider safety.
- Add admin controls for provider enablement, hosted-domain allowlists, callback validation, secret rotation, and explicit secret clearing.
- Add SSO conflict policy for existing email, unverified email, disabled accounts, moderated accounts, and existing provider identities.

R1 is done when a user can authenticate locally or through mocked Google/OIDC, link or unlink providers safely, and every failure path records a useful audit event without exposing provider secrets.

### R2 Notifications/Realtime Tasks

- Treat module manifests as the registry for notification topics, audiences, realtime channels, and admin/public inbox routing.
- Reject undeclared topics and cross-channel realtime events before persistence.
- Store canonical events once, then create delivery rows for admin inbox, public account inbox, realtime, and future email adapters.
- Add per-account preferences with topic-level opt-outs and module defaults.
- Persist delivery failures, retry counts, next retry time, and last error for admin visibility.
- Keep the realtime process narrow: origin checks, channel filters, SSE replay, WebSocket handshakes, fanout, and health output.

R2 is done when a forum, social, streaming, or security event can be emitted once, filtered by preferences, stored in inboxes, sent to realtime, retried after failure, and rejected if the manifest contract does not allow it.

### R3 Forums/Social Tasks

- Finish Forums category visibility for public, account-only, moderator-only, hidden, and locked spaces.
- Enforce forum actions for view, create topic, reply, edit, lock, hide, pin, report, soft delete, and moderate.
- Add forum edit windows, minimum account age, per-account/IP rate limits, duplicate suppression, moderator notes, and report queue status transitions.
- Finish Social dependency enforcement so Social cannot activate or run without Accounts.
- Finish Social global feed, following feed, and profile feed with pagination, stable ordering, disabled-account filtering, hidden/deleted filtering, and profile moderation.
- Add Social follows, unfollows, reactions, replies, mentions, reports, duplicate prevention, report queues, and actor-aware moderation transitions.

R3 is done when public users cannot bypass visibility or lock rules, moderators retain review access to hidden states, reports are actionable, anti-abuse controls apply consistently, and all replies, mentions, reports, reactions, follows, and moderation actions emit Notifications events.

### R4 Live Streaming Tasks

- Define the OpenBSD worker contract for OBS ingest auth, heartbeat, HLS output path, health checks, structured logs, and rejected ingest telemetry.
- Keep media processing out of CMS Perl; CMS owns channels, sessions, keys, chat, moderation, schedules, plan gates, and notifications.
- Add stream keys with hashed storage, one-time display, rotation, revoke, per-channel ingest policy, and wrong-key audit trails.
- Add session states for scheduled, live, stale, ended, failed, and terminal protection.
- Add HLS path validation so generated paths stay inside the configured staging/live HLS root.
- Add chat with account-only mode, slow mode, presence, message fanout, blocked terms, hide/delete, report queue, and moderator notes.
- Add SubCMS plan gates for enabled streaming, channel limits, chat availability, storage/HLS root, and public playback.

R4 is done when a mocked worker can authenticate with a valid key, fail with a wrong key, update heartbeats, move sessions through the lifecycle, serve validated HLS paths through `httpd`, and publish chat, presence, and stream-state events through Realtime.

### R5 OpenBSD Host Integration Tasks

- Build a staging tree under `/tmp/desertcms-v3-test` with isolated config, SQLite DB, public root, HLS root, logs, and generated OpenBSD configs.
- Run Perl syntax checks for CGI entry points, modules, realtime service, Security Center, and OpenBSD tools.
- Run local and OpenBSD-gated tests without requiring live deploy scripts or production paths.
- Run schema creation and migration against temporary SQLite databases only.
- Validate generated `httpd` config with `httpd -n -f` and generated packet filter rules with `pfctl -nf`.
- Validate `slowcgi`, `acme-client`, `syspatch -c`, `pkg_add -n -u`, package/CVE inputs, Security Center checks, and root-worker queue dry-runs.
- Refuse real OpenBSD integration runs unless `DESERTCMS_OPENBSD_INTEGRATION=1` is set and the target paths are staging-only.

R5 is done when Windows/local mocked tests prove the command plan and guardrails, and a real OpenBSD staging host can run the env-gated harness without touching `/etc`, `/var/www`, release artifacts, production databases, or live DesertCMS instances.

### R6 Migration/Regression Tasks

- Convert Posts to a first-party optional module while preserving imported post data and old route compatibility where needed.
- Add v2 fixtures for pages, posts, media, analytics, settings, module enablement, contributor sites, service plans, and navigation.
- Prove v3 migrations are idempotent across fresh install, clean v2 upgrade, and partially upgraded repair paths.
- Add regression coverage for module activation/deactivation, dependency gates, manifest validation, notification topics, and SubCMS plan gates.
- Add admin/public smoke coverage for account dashboard, provider settings, forums, social feeds, live channels, stream chat, Security Center, dashboard widgets, and module catalog.

R6 is done when a fresh v3 install and a migrated v2 fixture both pass schema, runtime, module, migration, and UI smoke tests without requiring external services.

## Parallel Work Rules

- Accounts and Notifications can be developed in parallel only when their shared actor and topic contracts are explicit in the manifest.
- Forums and Social can share helper patterns for permissions, reports, mentions, moderation queues, and anti-abuse controls, but they should keep separate module manifests and settings.
- Live Streaming can define schemas and OpenBSD config generation early, but chat fanout and presence should wait until Realtime channel filtering and delivery failure recording are stable.
- OpenBSD host integration should grow with every slice so staging failures are caught before the final migration pass.
- Migration tests should be updated whenever a runtime slice adds tables, settings, module state, or manifest contract fields.

## Runtime Review Checklist

Every runtime slice must answer these before it is considered complete:

- Which module manifest entries were added or changed?
- Which actors can perform the action: anonymous visitor, active account, moderator, admin user, root worker, or system task?
- Which audit, notification, or realtime events are emitted?
- Which settings are tenant-wide, SubCMS-scoped, account-scoped, or module-scoped?
- Which failure states are visible to admins?
- Which OpenBSD paths, commands, ports, sockets, or config files are read-only checked?
- Which tests prove disabled modules, disabled accounts, and staging-only host guardrails cannot be bypassed?

## Accounts And SSO

Goal: Accounts becomes the unified public identity layer for optional account-backed carts, Forums, Social, Live Streaming chat, notifications, and future public modules.

Required runtime behavior:

- OAuth/OIDC hardening: JWKS fetch/cache, ID-token signature validation, issuer, audience, nonce, expiry, and provider clock-skew checks.
- Server-side OAuth state storage with expiry, one-time use, PKCE verifier handling, and failed-state audit events.
- Local login and SSO throttling by account, email, provider, and IP.
- SSO conflict policy for existing emails, disabled accounts, moderated accounts, unverified email, and provider identity reuse.
- Account linking and unlinking from logged-in profiles, with provider-specific safety checks.
- Admin provider controls for enable/disable, callback validation, hosted-domain allowlists, and secret rotation or explicit secret clearing.
- Account moderation audit trails with actor context for admin users, public moderators, and system actions.

Test gates:

- Mocked Google/OIDC success.
- Bad state, expired state, reused state, bad issuer, bad audience, bad nonce, expired token, unverified email.
- Disabled and moderated account rejection.
- Link/unlink audit events.
- Throttled local and SSO attempts.
- Admin provider settings validation and secret-redaction checks.

## Notifications And Realtime

Goal: Notifications is the central event bus; Realtime is a delivery adapter for live browser updates.

Required runtime behavior:

- Topic registry validation against module manifests.
- Event creation API used by Accounts, Forums, Social, Live Streaming, Security Center, and admin operations.
- Delivery adapters for admin inbox, public account inbox, realtime channels, and optional email later.
- Per-user preferences that filter public notification topics before inbox or realtime delivery.
- Retry and failure state for adapters, with clean admin visibility.
- Realtime origin allowlist, channel filtering, SSE reads, WebSocket handshakes, and stored event replay.

Test gates:

- Module emits a declared event topic.
- Undeclared topics are rejected.
- Preferences suppress expected public notifications.
- Admin and public inbox delivery persists.
- Realtime adapter publishes expected payloads.
- Failed adapters record actionable failure state.

## Forums

Goal: Forums is a first-party public discussion module with strict permission boundaries and complete moderation workflows.

Required runtime behavior:

- Permission model for viewing, topic creation, replies, edit, lock, hide, pin, report, and moderation.
- Category visibility rules that support public, account-only, moderator-only, and admin-controlled spaces.
- Topic and reply edit windows.
- Soft delete, hidden state, locked topic behavior, pinned topics, and moderator notes.
- Reporting workflow with admin queue, status transitions, and actor-audited moderation actions.
- Notification hooks for replies, mentions, reports, and moderation actions.
- Anti-abuse controls for per-account/IP rate limits, minimum account age, and duplicate suppression.

Test gates:

- Category permission combinations.
- Locked and hidden topic behavior.
- Edit-window enforcement.
- Report queue and moderation status changes.
- Notification emission and preference filtering.
- Post rate limits and duplicate suppression.

## Social

Goal: Social adds public profiles, follows, feeds, reactions, mentions, reports, and moderation on top of Accounts.

Required runtime behavior:

- Dependency enforcement: Social cannot be active without Accounts, and disabling Accounts blocks Social activation.
- Global feed, following feed, and profile feed with pagination, visibility filters, hidden/deleted handling, and disabled-account filtering.
- Follow and unfollow behavior with duplicate prevention and notification hooks.
- Reactions, replies, mentions, reporting, hidden/deleted states, and profile moderation.
- Moderation queue for posts, replies, reports, and profiles.
- Account and moderator actor context on every moderation action.

Test gates:

- Feed ordering and pagination.
- Visibility filtering for disabled, hidden, deleted, and moderated accounts.
- Follow, unfollow, mention, reaction, reply, and report notifications.
- Report handling and moderation actions.
- Accounts dependency gates.

## Live Streaming

Goal: Live Streaming supports OBS-compatible ingest, OpenBSD-served HLS playback, chat, moderation, schedules, and SubCMS plan gates without making CMS Perl responsible for media transcoding.

Required runtime behavior:

- OpenBSD streaming worker contract for ingest auth, HLS output, health checks, heartbeats, and structured logs.
- `httpd` serves HLS assets; `pf` gates ingest/network access; CMS Perl owns channels, sessions, chat, admin state, and audit trails.
- Stream key generation, one-time display, rotation, revoke, per-channel ingest policy, and rejected-key telemetry.
- HLS session lifecycle: scheduled, live, ended, failed, with worker heartbeat and stale-worker detection.
- Live chat through Realtime: presence, message fanout, account-only mode, slow mode, delete/hide, reports, blocked terms, and moderator notes.
- Admin queues for chat reports, worker health events, and stream moderation.

Test gates:

- Stream key auth and wrong-key rejection.
- Key rotation and revoke behavior.
- Worker heartbeat and stale-worker detection.
- Session lifecycle transitions with actor enforcement.
- HLS path validation.
- Chat rate limiting, blocked terms, reports, and moderation.
- Realtime fanout for chat, presence, and stream state changes.

## OpenBSD Host Integration

Goal: Provide a repeatable staging-only harness that proves v3 fits OpenBSD without touching the live site.

Required runtime behavior:

- Copy the branch to `/tmp/desertcms-v3-test` on a staging host.
- Generate isolated config, SQLite DB path, public root, HLS root, `httpd`, `pf`, and `acme-client` test config.
- Run Perl syntax checks for CGI, runtime modules, and realtime service.
- Run the local test suite where dependencies are available.
- Run schema migration on a temporary SQLite database.
- Run `httpd -n` against generated config.
- Run `pfctl -nf` against generated rules.
- Verify `slowcgi` socket shape and `acme-client` config shape.
- Run Security Center read-only checks.
- Queue root-worker fixes in dry-run mode only.

Test gates:

- Windows/local mocked tests for unavailable OpenBSD commands.
- Real OpenBSD-only tests gated by explicit environment variables.
- Harness refuses real runs outside OpenBSD.
- Harness refuses non-staging targets.
- No live deploy script, production config, or release artifact path is touched.

## Migration And Regression

Goal: v2 sites can move to v3 without losing content, module settings, media, contributor sites, or imported posts.

Required runtime behavior:

- Preserve imported post data while Posts becomes an optional first-party module.
- Migrate v2 content, pages, media, contributor sites, settings, module enablement, service plans, and analytics state.
- Add v3 tables for Accounts, Notifications, Realtime, Forums, Social, Live Streaming, Security Center, and module manifest state.
- Keep migrations idempotent and repair-friendly.

Test gates:

- Fresh v3 schema install.
- v2-to-v3 migration fixture.
- Disabled Posts module preserves imported posts.
- Contributor site migration with plan gates intact.
- Module enablement and settings survive migration.
- Security Center and notification tables migrate without requiring external services.

## Implementation Work Packages

### WP1 Accounts/SSO Runtime

Deliver first because every public runtime module depends on account state and audit trails.

- Finish OIDC provider contract: discovery document fetch, JWKS cache, key rotation handling, signature validation, issuer/audience/nonce checks, expiry, and clock skew.
- Store OAuth state server-side with expiry, one-time consumption, PKCE verifier, redirect target validation, and failed-state audit events.
- Implement provider identity linking/unlinking from the account dashboard with disabled/moderated-account rejection and provider identity reuse protection.
- Add admin provider controls for enabled state, hosted-domain allowlist, callback URL validation, client secret rotation, and secret redaction.
- Enforce login throttles for local login, SSO start, and SSO callback by IP, provider, email, and account where known.
- Emit audit events for login, logout, SSO failure, identity link/unlink, account status change, provider setting change, and throttle rejection.

Exit: mocked Google/OIDC tests pass for success and failure states, local login still works, disabled/moderated accounts cannot authenticate or link identities, and secrets never render back to admin HTML.

### WP2 Notifications/Realtime Runtime

Deliver second because Forums, Social, Live Streaming, Security Center, and admin dashboards need the same notification path.

- Define a manifest topic registry and reject undeclared topics at event creation.
- Store canonical events once, then create delivery attempts for admin inbox, public account inbox, realtime, and later email adapters.
- Add per-account preferences with module defaults and topic-level opt-outs.
- Record adapter delivery status, retry count, next retry time, and failure reason.
- Keep Realtime as an adapter: it receives already-authorized event payloads and only handles channel fanout, replay, and connection rules.
- Add SSE replay and WebSocket handshake tests against allowed origins and channel filters.

Exit: a module can emit one event and have it filtered by preferences, persisted in the right inboxes, published to realtime, and marked failed if an adapter rejects it.

### WP3 Forums Runtime

Deliver after Accounts and Notifications so forum actions can use identity, audit, and topic delivery.

- Complete category states and visibility: public, account-only, moderator-only, hidden, and locked.
- Enforce permission checks for view, create topic, reply, edit, lock, hide, pin, report, delete, and moderate.
- Add edit windows, duplicate suppression, minimum account age, per-account rate limits, and per-IP rate limits.
- Keep all destructive behavior soft-state: hidden, deleted, reported, locked, pinned, and resolved.
- Add report queue views, moderator notes, actor-aware moderation transitions, and notifications for replies, mentions, reports, and moderation.

Exit: public reads hide disabled-account and hidden content, moderators can review hidden states, regular users cannot bypass locks/edit windows, and report/moderation notifications are emitted.

### WP4 Social Runtime

Deliver alongside or just after Forums because it shares account, moderation, report, and notification patterns.

- Enforce Social -> Accounts dependency at activation time and at runtime route entry points.
- Finish global, following, and profile feeds with pagination, visibility filters, disabled-account filtering, hidden/deleted states, and stable ordering.
- Add follows/unfollows, reactions, replies, mentions, reports, and profile moderation.
- Add duplicate prevention for follows, reactions, and open reports.
- Add moderation queues for posts, replies, profiles, and reports with actor-aware transitions.
- Emit notifications for follow, mention, reaction, reply, report, and moderation events.

Exit: feeds never show disabled/hidden/deleted content to public users, moderation queues preserve review access, Accounts dependency cannot be bypassed, and all social events travel through Notifications.

### WP5 Live Streaming Runtime

Deliver after the shared event/realtime path is stable because stream state, chat, and presence need live fanout.

- Define and test the OpenBSD worker API for OBS ingest auth, worker heartbeat, HLS output path validation, health, and structured logs.
- Keep media work outside CMS Perl: CMS owns channel/session/chat/admin state; worker owns ingest/transcode; `httpd` serves HLS; `pf` gates ports.
- Add stream key one-time display, hashed storage, rotation, revoke, rejected-key telemetry, and per-channel ingest policy.
- Add lifecycle states for scheduled, live, ended, failed, stale worker, and terminal session protection.
- Add live chat runtime with account-only mode, presence, fanout, slow-mode, blocked terms, report queue, hide/delete, and moderator notes.
- Add SubCMS plan gates for channel count, storage/HLS root, chat availability, and live module access.

Exit: wrong keys fail, valid keys authorize ingest, worker heartbeats update sessions, unsafe HLS paths are rejected, chat moderation works, and stream/chat/presence updates publish through Realtime.

### WP6 OpenBSD Host Integration

Deliver continuously, then run fully once the feature slices are in place.

- Generate an isolated staging tree under `/tmp/desertcms-v3-test` with config, SQLite database, public root, HLS root, logs, and generated OpenBSD config files.
- Run `perl -Ilib -c` for CGI, modules, realtime service, and OpenBSD tools.
- Run `prove -l t` where dependencies are installed; keep DB-backed tests explicit when DBI is unavailable locally.
- Run schema migration against temporary SQLite only.
- Run `httpd -n -f` against generated config and `pfctl -nf` against generated rules.
- Validate `slowcgi` rc.d shape, `acme-client` config shape, `syspatch -c`, `pkg_add -n -u`, package/CVE inputs, Security Center read-only checks, and root-worker queue dry-runs.
- Gate real OpenBSD execution behind `DESERTCMS_OPENBSD_INTEGRATION=1` and refuse non-OpenBSD real runs.

Exit: local mocked tests prove the command plan and guardrails; a staging OpenBSD host can run the real harness without touching `/etc`, `/var/www`, release artifacts, or the live DesertCMS instance.

### WP7 Migration And Regression

Deliver last because it must cover the final v3 schema and module contracts.

- Build v2 fixture coverage for pages, posts, media, analytics, settings, module enablement, contributor sites, service plans, and navigation.
- Preserve imported posts even when the Posts module is disabled after migration.
- Prove v3 migrations are idempotent and repair-friendly against partially upgraded databases.
- Add regression tests for module enable/disable transitions and dependency gates.
- Add responsive/admin smoke coverage for dashboard widgets, module catalog, SubCMS shell, theme preview, account dashboard, forums, social, live channel page, and Security Center.

Exit: a fresh v3 install and a migrated v2 fixture both pass the runtime and UI smoke suites without external services.

## Validation Ladder

Run validation in this order so failures stay local and cheap:

1. Static checks: Perl syntax for touched modules, CGI entry points, realtime service, and OpenBSD tools.
2. Contract checks: module manifest validation, declared notification topics, declared routes, permissions, migrations, and widgets.
3. Mocked runtime checks: Accounts/SSO, Notifications, Forums, Social, Live Streaming, Security Center, and OpenBSD command-plan tests on local development machines.
4. DB-backed checks: fresh schema and migration fixtures against temporary SQLite.
5. UI smoke checks: admin sidebar, dashboard widgets, module catalog, account dashboard, public forum/social/live pages, and responsive behavior.
6. OpenBSD staging checks: env-gated harness on a staging host with `httpd`, `pf`, `slowcgi`, `acme-client`, package checks, and root-worker dry-runs.

## Security Controls

- Every public action must reject disabled or moderated accounts unless the flow is explicitly designed for appeal/recovery.
- Every moderator/admin mutation must carry an actor account, admin user, or narrowly named system action.
- Every SSO, streaming ingest, chat, forum, social, notification, and root-worker failure should produce an audit or reviewable event.
- Every route that accepts external input must validate redirect targets, HLS paths, provider callbacks, origins, hosted domains, stream slugs, and entity ownership.
- Every privileged host action stays read-only or queued by default; applying a root-worker fix is outside this roadmap until separately approved.

## Deferred Work

- Email notification delivery is adapter-shaped now, but production email sending can wait until inbox and realtime delivery are stable.
- Production live-stream transcoding service management is outside CMS Perl; v3 only needs the worker contract, state model, and OpenBSD integration hooks.
- Billing-specific account workflows should integrate with Accounts and Shop after identity, carts, and order history are stable.
- Release artifacts, live publish scripts, production migrations, GitHub pushes, and PR creation remain blocked until separately approved; the only approved future v3 deployment target is `desertarchives.com` after completion.

## Milestones

| Milestone | Exit criteria |
| --- | --- |
| M1 Accounts/SSO | Local and SSO login, linking, throttling, provider settings, conflict policy, audit trails, and tests are complete. |
| M2 Notifications/Realtime | Manifest topic validation, inboxes, preferences, retries, SSE/WebSocket delivery, and failure visibility are complete. |
| M3 Forums/Social | Permissions, feeds, reports, moderation, notifications, dependency gates, and anti-abuse controls are complete. |
| M4 Live Streaming | Worker contract, stream keys, HLS lifecycle, chat, moderation, and realtime updates are complete. |
| M5 OpenBSD Integration | Staging-only harness passes on OpenBSD with `httpd`, `pf`, `slowcgi`, `acme-client`, and Security Center checks. |
| M6 Migration | v2 fixtures migrate into v3 with content, media, posts, modules, settings, and contributor sites preserved. |

## Definition Of Done

The remaining v3 runtime work is complete when a fresh local install can migrate a v2 fixture, enable or disable first-party modules, exercise account login and mocked SSO, create forum, social, and live-stream activity, emit and deliver notifications, run Security Center checks, and pass the OpenBSD staging integration suite without touching the live site.
