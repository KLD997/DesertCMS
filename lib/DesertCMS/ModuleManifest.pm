package DesertCMS::ModuleManifest;

use strict;
use warnings;
use Exporter 'import';
use JSON::PP qw(decode_json encode_json);
use DesertCMS::Modules;

our @EXPORT_OK = qw(
    manifests manifest validate_manifest content_types dashboard_widgets
    analytics_panels notification_topics security_checks permissions routes
    subcms_plan_gates
);

my @REQUIRED_KEYS = qw(
    key label type routes settings renderer_hooks content_types widgets
    analytics_panels notifications security_checks migrations permissions
    subcms_plan_gates
);

my %CORE_MANIFESTS = (
    pages => {
        key                => 'pages',
        label              => 'Pages',
        type               => 'core',
        description        => 'Permanent public site structure, visual page builder output, navigation, redirects, and renderer integration.',
        dependencies       => [],
        routes             => [
            { scope => 'admin', method => 'GET',  path => '/admin/pages' },
            { scope => 'admin', method => 'GET',  path => '/admin/pages/new' },
            { scope => 'admin', method => 'POST', path => '/admin/content/create' },
            { scope => 'admin', method => 'POST', path => '/admin/content/:id/update' },
            { scope => 'public', method => 'GET', path => '/:page_path' },
        ],
        settings           => [],
        renderer_hooks     => [qw(content.resolve renderer.page navigation.render sitemap.render)],
        content_types      => [
            { key => 'page', label => 'Page', table => 'content_items', discriminator => 'type=page' },
        ],
        widgets            => [
            { key => 'pages_status', label => 'Published Pages', size => 'small', capability => 'view_content' },
        ],
        analytics_panels   => [
            { key => 'page_traffic', label => 'Page Traffic', source => 'analytics_events.path' },
        ],
        notifications      => [qw(content.page_published content.page_deleted content.render_failed)],
        security_checks    => [qw(public_path_canonicalization draft_preview_noindex content_access_policy)],
        migrations         => [qw(content_items content_revisions redirects navigation_items page_templates builder_sections)],
        permissions        => [qw(view_content edit_content)],
        subcms_plan_gates  => [qw(page_quota allow_indexing_override)],
    },
    analytics => {
        key                => 'analytics',
        label              => 'Analytics',
        type               => 'core',
        description        => 'First-party traffic analytics with IP, page, referrer, time range, and location detail panels.',
        dependencies       => [],
        routes             => [
            { scope => 'admin', method => 'GET',  path => '/admin' },
            { scope => 'public', method => 'POST', path => '/analytics/collect' },
        ],
        settings           => [qw(analytics_enabled analytics_retention_days analytics_store_raw_ip trusted_proxy_cidrs)],
        renderer_hooks     => [qw(renderer.analytics_pixel dashboard.analytics)],
        content_types      => [],
        widgets            => [
            { key => 'analytics_overview', label => 'Traffic Overview', size => 'large', capability => 'view_home' },
            { key => 'top_pages', label => 'Popular Pages', size => 'medium', capability => 'view_home' },
            { key => 'top_ips', label => 'Visits Per IP', size => 'medium', capability => 'view_home' },
        ],
        analytics_panels   => [
            { key => 'time_series', label => 'Time Series', views => [qw(bar line table)], ranges => [qw(24h 7d 30d 90d 365d)] },
            { key => 'unique_ips', label => 'Unique IPs', views => [qw(table rank)], ranges => [qw(24h 7d 30d 90d)] },
            { key => 'pages', label => 'Pages', views => [qw(rank table)], ranges => [qw(7d 30d 90d 365d)] },
            { key => 'locations', label => 'Visitor Locations', views => [qw(donut table)], ranges => [qw(7d 30d 90d)] },
        ],
        notifications      => [qw(analytics.geoip_stale analytics.retention_failed)],
        security_checks    => [qw(raw_ip_retention trusted_proxy_header_handling analytics_admin_only)],
        migrations         => [qw(analytics_events analytics_geoip_ranges analytics_geoip_meta)],
        permissions        => [qw(view_home)],
        subcms_plan_gates  => [qw(analytics_retention_days)],
    },
    dashboard => {
        key                => 'dashboard',
        label              => 'Custom Dashboard',
        type               => 'core',
        description        => 'Admin dashboard layout, widget registry, quick peeks, and per-role dashboard preferences.',
        dependencies       => [qw(analytics notifications)],
        routes             => [
            { scope => 'admin', method => 'GET', path => '/admin' },
        ],
        settings           => [],
        renderer_hooks     => [qw(dashboard.widget_registry dashboard.realtime_updates)],
        content_types      => [],
        widgets            => [
            { key => 'security_summary', label => 'Security Summary', size => 'medium', capability => 'view_security_center' },
            { key => 'notifications', label => 'Notifications', size => 'small', capability => 'view_notifications' },
            { key => 'module_status', label => 'Enabled Modules', size => 'small', capability => 'view_features' },
            { key => 'billing_usage', label => 'Billing and Usage', size => 'small', capability => 'view_usage' },
        ],
        analytics_panels   => [],
        notifications      => [qw(dashboard.widget_failed dashboard.layout_saved)],
        security_checks    => [qw(widget_permission_filter dashboard_csrf)],
        migrations         => [qw(admin_dashboard_widgets)],
        permissions        => [qw(view_home)],
        subcms_plan_gates  => [qw(available_widgets)],
    },
    theme_engine => {
        key                => 'theme_engine',
        label              => 'Theme Engine',
        type               => 'core',
        description        => 'Fonts, image sourcing, backgrounds, motion, lighting, transparency, shapes, gradients, and preview-safe theme output.',
        dependencies       => [],
        routes             => [
            { scope => 'admin', method => 'GET',  path => '/admin/site-settings?section=theme' },
            { scope => 'admin', method => 'POST', path => '/admin/site-settings/save' },
        ],
        settings           => [qw(theme_preset theme_heading_font theme_body_font theme_ui_font font_package_repo theme_unsplash_enabled unsplash_access_key theme_background_effect theme_motion_effect theme_lighting_effect theme_box_transparency theme_outline_transparency theme_box_shape theme_gradient_style)],
        renderer_hooks     => [qw(theme.resolve theme.assets renderer.theme_tokens)],
        content_types      => [],
        widgets            => [
            { key => 'theme_preview', label => 'Theme Preview', size => 'medium', capability => 'view_design' },
        ],
        analytics_panels   => [],
        notifications      => [qw(theme.unsplash_failed theme.font_install_failed theme.preview_failed)],
        security_checks    => [qw(external_image_origin_csp font_package_source theme_file_permissions)],
        migrations         => [qw(themes theme_files theme_image_sources)],
        permissions        => [qw(view_design customize_theme)],
        subcms_plan_gates  => [qw(custom_theme_files font_packages unsplash_images motion_effects)],
    },
    realtime => {
        key                => 'realtime',
        label              => 'Realtime Service',
        type               => 'service',
        description        => 'Small Perl WebSocket/SSE service for notifications, live chat, stream presence, and dashboard updates.',
        dependencies       => [qw(notifications)],
        routes             => [
            { scope => 'admin', method => 'GET',  path => '/admin/settings/realtime' },
            { scope => 'admin', method => 'POST', path => '/admin/settings/realtime' },
            { scope => 'service', method => 'GET', path => '/events' },
            { scope => 'service', method => 'GET', path => '/ws' },
            { scope => 'service', method => 'GET', path => '/health' },
        ],
        settings           => [qw(realtime_enabled realtime_bind_host realtime_port realtime_public_url realtime_allowed_origins)],
        renderer_hooks     => [qw(realtime.admin_events realtime.public_events)],
        content_types      => [],
        widgets            => [
            { key => 'realtime_status', label => 'Realtime Status', size => 'small', capability => 'view_realtime' },
        ],
        analytics_panels   => [],
        notifications      => [qw(realtime.service_down realtime.client_backpressure)],
        security_checks    => [qw(realtime_loopback_bind realtime_pf_anchor realtime_origin_filter)],
        migrations         => [qw(realtime_sessions)],
        permissions        => [qw(view_realtime manage_realtime)],
        subcms_plan_gates  => [qw(realtime_notifications live_chat stream_presence)],
    },
);

my %MODULE_OVERLAYS = (
    posts => {
        routes            => [
            { scope => 'admin', method => 'GET',  path => '/admin/settings/modules/posts' },
            { scope => 'admin', method => 'POST', path => '/admin/settings/modules/posts/save' },
            { scope => 'admin', method => 'GET',  path => '/admin/posts' },
            { scope => 'admin', method => 'GET',  path => '/admin/posts/new' },
            { scope => 'public', method => 'GET',  path => '/posts/' },
            { scope => 'public', method => 'GET',  path => '/posts/:slug' },
        ],
        content_types     => [
            { key => 'post', label => 'Post', table => 'content_items', discriminator => 'type=post' },
        ],
        widgets           => [
            { key => 'recent_posts', label => 'Recent Posts', size => 'medium', capability => 'view_content' },
            { key => 'post_comments', label => 'Post Comments', size => 'small', capability => 'view_content' },
        ],
        analytics_panels  => [
            { key => 'post_traffic', label => 'Post Traffic', source => 'analytics_events.path' },
        ],
        notifications     => [qw(content.post_published content.post_commented content.post_rating content.render_failed)],
        security_checks   => [qw(comment_moderation_status rating_spam_threshold post_archive_canonicalization)],
        migrations        => [qw(content_items content_revisions comments post_ratings)],
        renderer_hooks    => [qw(renderer.post renderer.post_archive sitemap.render rss.render)],
        permissions       => [qw(view_content edit_content)],
        subcms_plan_gates => [qw(post_quota allow_master_posts)],
    },
    accounts => {
        routes            => [
            { scope => 'admin', method => 'GET',  path => '/admin/settings/modules/accounts' },
            { scope => 'admin', method => 'POST', path => '/admin/settings/modules/accounts/save' },
            { scope => 'admin', method => 'GET',  path => '/admin/accounts' },
            { scope => 'admin', method => 'POST', path => '/admin/accounts/create' },
            { scope => 'admin', method => 'POST', path => '/admin/accounts/status' },
            { scope => 'admin', method => 'POST', path => '/admin/accounts/groups/create' },
            { scope => 'public', method => 'GET',  path => '/account' },
            { scope => 'public', method => 'GET',  path => '/account/login' },
            { scope => 'public', method => 'POST', path => '/account/login' },
            { scope => 'public', method => 'GET',  path => '/account/password/forgot' },
            { scope => 'public', method => 'POST', path => '/account/password/forgot' },
            { scope => 'public', method => 'GET',  path => '/account/password/reset/:token' },
            { scope => 'public', method => 'POST', path => '/account/password/reset/:token' },
            { scope => 'public', method => 'GET',  path => '/account/sso/google/start' },
            { scope => 'public', method => 'GET',  path => '/account/sso/google/callback' },
            { scope => 'public', method => 'GET',  path => '/account/sso/oidc/start' },
            { scope => 'public', method => 'GET',  path => '/account/sso/oidc/callback' },
            { scope => 'public', method => 'GET',  path => '/account/register' },
            { scope => 'public', method => 'POST', path => '/account/register' },
            { scope => 'public', method => 'GET',  path => '/account/profile' },
            { scope => 'public', method => 'POST', path => '/account/profile' },
            { scope => 'public', method => 'GET',  path => '/account/identity/google/start' },
            { scope => 'public', method => 'GET',  path => '/account/identity/oidc/start' },
            { scope => 'public', method => 'POST', path => '/account/identity/unlink' },
            { scope => 'public', method => 'POST', path => '/account/logout' },
        ],
        settings          => [qw(module_accounts_enabled accounts_google_enabled accounts_google_client_id accounts_google_client_secret accounts_oidc_enabled accounts_oidc_discovery_url accounts_oidc_client_id accounts_oidc_client_secret accounts_allowed_domains)],
        content_types     => [
            { key => 'user_account', label => 'User Account', table => 'user_accounts' },
            { key => 'user_identity', label => 'SSO Identity', table => 'user_identities' },
            { key => 'user_account_oauth_state', label => 'OAuth State', table => 'user_account_oauth_states' },
            { key => 'user_account_password_reset', label => 'Account Password Reset', table => 'user_account_password_reset_tokens' },
        ],
        widgets           => [
            { key => 'account_signups', label => 'Account Signups', size => 'small', capability => 'view_features' },
        ],
        analytics_panels  => [
            { key => 'account_activity', label => 'Account Activity', source => 'user_accounts' },
        ],
        notifications     => [qw(accounts.login_failed accounts.sso_failed accounts.password_reset_requested accounts.password_reset_failed accounts.moderation_needed accounts.profile_reported)],
        security_checks   => [qw(oidc_redirect_origin session_cookie_flags password_reset_expiry account_rate_limits)],
        migrations        => [qw(user_accounts user_account_sessions user_account_password_reset_tokens user_account_oauth_states user_identities user_groups user_group_members shop_carts shop_cart_items)],
        renderer_hooks    => [qw(auth.public_identity shop.account_adapter member.unified_identity)],
        permissions       => [qw(view_features enable_allowed_modules manage_accounts manage_account_groups manage_sso_providers)],
        subcms_plan_gates => [qw(public_accounts sso_providers account_moderation)],
    },
    live_streaming => {
        routes            => [
            { scope => 'admin', method => 'GET',  path => '/admin/settings/modules/live-streaming' },
            { scope => 'admin', method => 'POST', path => '/admin/settings/modules/live-streaming/save' },
            { scope => 'admin', method => 'GET',  path => '/admin/live' },
            { scope => 'admin', method => 'POST', path => '/admin/live/channels/create' },
            { scope => 'admin', method => 'POST', path => '/admin/live/channels/key/rotate' },
            { scope => 'admin', method => 'POST', path => '/admin/live/channels/key/revoke' },
            { scope => 'admin', method => 'POST', path => '/admin/live/sessions/create' },
            { scope => 'admin', method => 'POST', path => '/admin/live/sessions/status' },
            { scope => 'admin', method => 'POST', path => '/admin/live/sessions/due' },
            { scope => 'admin', method => 'POST', path => '/admin/live/chat/status' },
            { scope => 'admin', method => 'POST', path => '/admin/live/chat/reports/status' },
            { scope => 'admin', method => 'POST', path => '/admin/live/blocked-terms/save' },
            { scope => 'admin', method => 'POST', path => '/admin/live/blocked-terms/delete' },
            { scope => 'public', method => 'GET',  path => '/live' },
            { scope => 'public', method => 'GET',  path => '/live/:slug' },
            { scope => 'public', method => 'POST', path => '/live/:slug/chat' },
            { scope => 'public', method => 'POST', path => '/live/:slug/chat/delete' },
            { scope => 'public', method => 'POST', path => '/live/:slug/chat/report' },
            { scope => 'public', method => 'POST', path => '/live/:slug/presence' },
            { scope => 'public', method => 'POST', path => '/live/:slug/presence/leave' },
            { scope => 'worker', method => 'GET',  path => '/live/worker/health' },
            { scope => 'worker', method => 'POST', path => '/live/worker/auth' },
            { scope => 'worker', method => 'POST', path => '/live/worker/heartbeat' },
        ],
        settings          => [qw(module_live_streaming_enabled realtime_enabled realtime_bind_host realtime_port realtime_public_url realtime_allowed_origins live_chat_account_only live_chat_slow_mode_seconds live_chat_delete_window_seconds live_chat_presence_stale_seconds)],
        content_types     => [
            { key => 'live_stream_channel', label => 'Live Stream Channel', table => 'live_stream_channels' },
            { key => 'live_stream_session', label => 'Live Stream Session', table => 'live_stream_sessions' },
            { key => 'live_stream_worker_event', label => 'Live Stream Worker Event', table => 'live_stream_worker_events' },
            { key => 'live_chat_message', label => 'Live Chat Message', table => 'live_chat_messages' },
            { key => 'live_chat_presence', label => 'Live Chat Presence', table => 'live_chat_presence' },
            { key => 'live_chat_report', label => 'Live Chat Report', table => 'live_chat_reports' },
            { key => 'live_chat_blocked_term', label => 'Live Chat Blocked Term', table => 'live_chat_blocked_terms' },
        ],
        widgets           => [
            { key => 'stream_presence', label => 'Stream Presence', size => 'medium', capability => 'view_features' },
        ],
        analytics_panels  => [
            { key => 'stream_viewers', label => 'Stream Viewers', source => 'live_stream_sessions' },
        ],
        notifications     => [qw(stream.started stream.ended stream.ingest_failed stream.chat_reported stream.chat_moderated stream.schedule_due)],
        security_checks   => [qw(stream_key_entropy hls_public_path streaming_pf_ports chat_rate_limits obs_ingest_tls)],
        migrations        => [qw(live_stream_channels live_stream_sessions live_stream_worker_events live_chat_messages live_chat_presence live_chat_reports live_chat_blocked_terms)],
        renderer_hooks    => [qw(realtime.stream_presence renderer.live_stream notifications.live_chat)],
        permissions       => [qw(view_features enable_allowed_modules view_realtime manage_realtime live_chat moderate_live_chat)],
        subcms_plan_gates => [qw(live_streaming live_chat streaming_storage streaming_ports)],
    },
    forums => {
        routes            => [
            { scope => 'admin', method => 'GET',  path => '/admin/settings/modules/forums' },
            { scope => 'admin', method => 'POST', path => '/admin/settings/modules/forums/save' },
            { scope => 'admin', method => 'GET',  path => '/admin/forums' },
            { scope => 'admin', method => 'POST', path => '/admin/forums/categories/create' },
            { scope => 'admin', method => 'POST', path => '/admin/forums/categories/update' },
            { scope => 'admin', method => 'POST', path => '/admin/forums/topics/status' },
            { scope => 'admin', method => 'POST', path => '/admin/forums/topics/pin' },
            { scope => 'admin', method => 'POST', path => '/admin/forums/posts/status' },
            { scope => 'admin', method => 'POST', path => '/admin/forums/reports/status' },
            { scope => 'public', method => 'GET',  path => '/forums' },
            { scope => 'public', method => 'GET',  path => '/forums/category/:category_slug' },
            { scope => 'public', method => 'POST', path => '/forums/category/:category_slug/topics' },
            { scope => 'public', method => 'GET',  path => '/forums/category/:category_slug/:topic_slug' },
            { scope => 'public', method => 'POST', path => '/forums/topics/:id/reply' },
            { scope => 'public', method => 'POST', path => '/forums/posts/:id/edit' },
            { scope => 'public', method => 'POST', path => '/forums/posts/:id/delete' },
            { scope => 'public', method => 'POST', path => '/forums/report' },
        ],
        settings          => [qw(module_forums_enabled)],
        content_types     => [
            { key => 'forum_category', label => 'Forum Category', table => 'forum_categories' },
            { key => 'forum_topic', label => 'Forum Topic', table => 'forum_topics' },
            { key => 'forum_post', label => 'Forum Reply', table => 'forum_posts' },
            { key => 'forum_report', label => 'Forum Report', table => 'forum_reports' },
        ],
        widgets           => [
            { key => 'forum_queue', label => 'Forum Moderation', size => 'medium', capability => 'view_features' },
        ],
        analytics_panels  => [
            { key => 'forum_activity', label => 'Forum Activity', source => 'forum_topics' },
        ],
        notifications     => [qw(forums.topic_created forums.reply_created forums.mention forums.reported forums.moderation_needed forums.moderation_action)],
        security_checks   => [qw(forum_csrf forum_rate_limits forum_upload_policy moderation_queue)],
        migrations        => [qw(forum_categories forum_topics forum_posts forum_reports)],
        renderer_hooks    => [qw(renderer.forums notifications.forums auth.account_required)],
        permissions       => [qw(view_features enable_allowed_modules forum.view forum.create_topic forum.reply forum.edit forum.lock forum.hide forum.pin forum.report forum.moderate forum.delete)],
        subcms_plan_gates => [qw(forums forum_moderators forum_uploads)],
    },
    social => {
        dependencies      => [qw(accounts)],
        routes            => [
            { scope => 'admin', method => 'GET',  path => '/admin/settings/modules/social' },
            { scope => 'admin', method => 'POST', path => '/admin/settings/modules/social/save' },
            { scope => 'admin', method => 'GET',  path => '/admin/social' },
            { scope => 'admin', method => 'POST', path => '/admin/social/posts/status' },
            { scope => 'admin', method => 'POST', path => '/admin/social/replies/status' },
            { scope => 'admin', method => 'POST', path => '/admin/social/profiles/status' },
            { scope => 'admin', method => 'POST', path => '/admin/social/reports/status' },
            { scope => 'public', method => 'GET',  path => '/social' },
            { scope => 'public', method => 'POST', path => '/social/posts/create' },
            { scope => 'public', method => 'POST', path => '/social/posts/delete' },
            { scope => 'public', method => 'POST', path => '/social/replies/create' },
            { scope => 'public', method => 'POST', path => '/social/replies/delete' },
            { scope => 'public', method => 'POST', path => '/social/follow' },
            { scope => 'public', method => 'POST', path => '/social/unfollow' },
            { scope => 'public', method => 'POST', path => '/social/block' },
            { scope => 'public', method => 'POST', path => '/social/unblock' },
            { scope => 'public', method => 'POST', path => '/social/react' },
            { scope => 'public', method => 'POST', path => '/social/report' },
            { scope => 'public', method => 'GET',  path => '/social/@:handle' },
        ],
        settings          => [qw(module_social_enabled module_accounts_enabled social_delete_window_seconds)],
        content_types     => [
            { key => 'social_profile', label => 'Social Profile', table => 'social_profiles' },
            { key => 'social_post', label => 'Social Post', table => 'social_posts' },
            { key => 'social_reply', label => 'Social Reply', table => 'social_replies' },
            { key => 'social_reaction', label => 'Social Reaction', table => 'social_reactions' },
            { key => 'social_report', label => 'Social Report', table => 'social_reports' },
        ],
        widgets           => [
            { key => 'social_reports', label => 'Social Reports', size => 'medium', capability => 'view_features' },
        ],
        analytics_panels  => [
            { key => 'social_engagement', label => 'Social Engagement', source => 'social_posts' },
        ],
        notifications     => [qw(social.post_created social.reply_created social.follow social.mention social.reaction social.reported social.moderation_needed)],
        security_checks   => [qw(social_account_dependency social_rate_limits social_report_queue profile_visibility)],
        migrations        => [qw(social_profiles social_follows social_posts social_replies social_reactions social_reports)],
        renderer_hooks    => [qw(renderer.social_feed notifications.social auth.account_required)],
        permissions       => [qw(view_features enable_allowed_modules social.view social.create_post social.reply social.delete social.follow social.block social.react social.report social.moderate)],
        subcms_plan_gates => [qw(social_profiles social_feed moderation_tools)],
    },
    notifications => {
        routes            => [
            { scope => 'admin', method => 'GET',  path => '/admin/notifications' },
            { scope => 'admin', method => 'POST', path => '/admin/notifications/mark-read' },
            { scope => 'admin', method => 'POST', path => '/admin/notifications/retry-due' },
            { scope => 'admin', method => 'GET',  path => '/admin/settings/modules/notifications' },
            { scope => 'admin', method => 'POST', path => '/admin/settings/modules/notifications/save' },
            { scope => 'public', method => 'GET',  path => '/account/notifications' },
            { scope => 'public', method => 'POST', path => '/account/notifications/mark-read' },
            { scope => 'public', method => 'POST', path => '/account/notifications/preferences' },
        ],
        content_types     => [
            { key => 'notification', label => 'Notification', table => 'notifications' },
            { key => 'notification_preference', label => 'Notification Preference', table => 'notification_preferences' },
            { key => 'notification_delivery', label => 'Notification Delivery', table => 'notification_deliveries' },
        ],
        widgets           => [
            { key => 'notification_inbox', label => 'Notification Inbox', size => 'small', capability => 'view_notifications' },
        ],
        analytics_panels  => [],
        notifications     => [qw(system.notice notifications.delivery_failed notifications.digest_failed notifications.topic_muted)],
        security_checks   => [qw(notification_audience_filter notification_topic_permissions notification_event_sanitization)],
        migrations        => [qw(notifications notification_preferences notification_deliveries)],
        renderer_hooks    => [qw(notifications.emit notifications.admin_inbox notifications.public_inbox realtime.notifications)],
        permissions       => [qw(view_notifications manage_notifications)],
        subcms_plan_gates => [qw(admin_notifications public_notifications realtime_notifications)],
    },
    security_center => {
        routes            => [
            { scope => 'admin', method => 'GET',  path => '/admin/settings/security' },
            { scope => 'admin', method => 'POST', path => '/admin/settings/security/queue' },
            { scope => 'admin', method => 'GET',  path => '/admin/settings/modules/security-center' },
            { scope => 'admin', method => 'POST', path => '/admin/settings/modules/security-center/save' },
        ],
        content_types     => [
            { key => 'security_finding', label => 'Security Finding', table => 'security_findings' },
            { key => 'security_remediation', label => 'Security Remediation', table => 'security_remediation_queue' },
        ],
        widgets           => [
            { key => 'security_center', label => 'Security Center', size => 'large', capability => 'view_security_center' },
        ],
        analytics_panels  => [],
        notifications     => [qw(security.check_failed security.fix_queued security.package_update security.tls_expiring security.worker_down)],
        security_checks   => [qw(dns tls httpd pf acme_client csp_headers file_permissions worker_health backups tenant_isolation packages syspatch pkg_add package_updates cve_matching provider_webhooks streaming_ports)],
        migrations        => [qw(security_findings security_remediation_queue)],
        renderer_hooks    => [qw(security.check_registry notifications.security operations.root_worker_queue)],
        permissions       => [qw(view_security_center queue_security_fixes)],
        subcms_plan_gates => [qw(security_center tenant_security_checks)],
    },
);

sub manifests {
    my (%args) = @_;
    my $settings = $args{settings} || {};
    my $config = $args{config};
    my %items = map { $_ => _copy($CORE_MANIFESTS{$_}) } keys %CORE_MANIFESTS;

    for my $module (@{ DesertCMS::Modules::catalog($settings, config => $config) }) {
        my $key = $module->{key} || next;
        next if $key =~ /_payments\z/;
        my $base = {
            key                => $key,
            label              => $module->{label} || $key,
            type               => 'module',
            description        => $module->{description} || '',
            dependencies       => [],
            routes             => _module_routes($module),
            settings           => _module_settings($module),
            renderer_hooks     => [qw(module.enabled module.settings)],
            content_types      => [],
            widgets            => [
                { key => $key . '_status', label => ($module->{label} || $key) . ' Status', size => 'small', capability => 'view_features' },
            ],
            analytics_panels   => [],
            notifications      => [],
            security_checks    => [],
            migrations         => [],
            permissions        => [qw(view_features enable_allowed_modules)],
            subcms_plan_gates  => [ $key ],
            enabled            => $module->{enabled} ? 1 : 0,
            available          => $module->{available} ? 1 : 0,
            locked_by_plan     => $module->{locked_by_plan} ? 1 : 0,
            managed_by_master  => $module->{managed_by_master} ? 1 : 0,
            public_path        => $module->{public_path} || '',
            settings_path      => $module->{settings_path} || '',
            setting_key        => $module->{setting_key} || '',
        };
        $items{$key} = _merge_manifest($base, $MODULE_OVERLAYS{$key} || {});
    }
    return [ map { $items{$_} } sort keys %items ];
}

sub manifest {
    my ($key, %args) = @_;
    return undef unless defined $key && length $key;
    for my $manifest (@{ manifests(%args) }) {
        return $manifest if ($manifest->{key} || '') eq $key;
    }
    return undef;
}

sub validate_manifest {
    my ($manifest) = @_;
    my @errors;
    if (!$manifest || ref $manifest ne 'HASH') {
        @errors = ('manifest must be a hash');
        return wantarray ? @errors : \@errors;
    }
    for my $key (@REQUIRED_KEYS) {
        push @errors, "missing $key" unless exists $manifest->{$key};
    }
    push @errors, 'invalid key' unless ($manifest->{key} || '') =~ /\A[a-z][a-z0-9_]*\z/;
    push @errors, 'routes must be an array' unless ref($manifest->{routes}) eq 'ARRAY';
    push @errors, 'settings must be an array' unless ref($manifest->{settings}) eq 'ARRAY';
    push @errors, 'renderer_hooks must be an array' unless ref($manifest->{renderer_hooks}) eq 'ARRAY';
    push @errors, 'content_types must be an array' unless ref($manifest->{content_types}) eq 'ARRAY';
    push @errors, 'widgets must be an array' unless ref($manifest->{widgets}) eq 'ARRAY';
    push @errors, 'analytics_panels must be an array' unless ref($manifest->{analytics_panels}) eq 'ARRAY';
    push @errors, 'notifications must be an array' unless ref($manifest->{notifications}) eq 'ARRAY';
    push @errors, 'security_checks must be an array' unless ref($manifest->{security_checks}) eq 'ARRAY';
    push @errors, 'permissions must be an array' unless ref($manifest->{permissions}) eq 'ARRAY';
    push @errors, 'subcms_plan_gates must be an array' unless ref($manifest->{subcms_plan_gates}) eq 'ARRAY';
    return wantarray ? @errors : \@errors;
}

sub content_types {
    return _collect_array('content_types', @_);
}

sub dashboard_widgets {
    return _collect_array('widgets', @_);
}

sub analytics_panels {
    return _collect_array('analytics_panels', @_);
}

sub notification_topics {
    return _collect_array('notifications', @_);
}

sub security_checks {
    return _collect_array('security_checks', @_);
}

sub permissions {
    return _collect_array('permissions', @_);
}

sub routes {
    return _collect_array('routes', @_);
}

sub subcms_plan_gates {
    return _collect_array('subcms_plan_gates', @_);
}

sub _collect_array {
    my ($field, %args) = @_;
    my @items;
    for my $manifest (@{ manifests(%args) }) {
        next unless ref($manifest->{$field}) eq 'ARRAY';
        push @items, @{ $manifest->{$field} };
    }
    return \@items;
}

sub _module_routes {
    my ($module) = @_;
    my @routes;
    push @routes, { scope => 'admin', method => 'GET', path => $module->{settings_path} }
        if length($module->{settings_path} || '');
    push @routes, { scope => 'public', method => 'GET', path => $module->{public_path} }
        if length($module->{public_path} || '');
    return \@routes;
}

sub _module_settings {
    my ($module) = @_;
    my @settings;
    push @settings, $module->{setting_key} if length($module->{setting_key} || '');
    return \@settings;
}

sub _merge_manifest {
    my ($base, $overlay) = @_;
    my %merged = %{ _copy($base) };
    for my $key (keys %{ $overlay || {} }) {
        if ($key eq 'dependencies') {
            my %seen;
            $merged{$key} = [
                grep { !$seen{$_}++ } @{ $base->{$key} || [] }, @{ $overlay->{$key} || [] }
            ];
        } else {
            $merged{$key} = _copy($overlay->{$key});
        }
    }
    return \%merged;
}

sub _copy {
    my ($value) = @_;
    return undef unless defined $value;
    return decode_json(encode_json($value));
}

1;
