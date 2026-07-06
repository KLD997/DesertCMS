package DesertCMS::Settings;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP qw(decode_json encode_json);
use DesertCMS::Commerce;
use DesertCMS::Util qw(now);

our $SETTINGS_GENERATION = 0;

sub all {
    my ($config, $db) = @_;
    my $config_cache_key = defined $config ? "$config" : '';
    if ($db
        && $db->{_settings_cache}
        && defined $db->{_settings_cache_generation}
        && $db->{_settings_cache_generation} == $SETTINGS_GENERATION
        && defined $db->{_settings_cache_config_key}
        && $db->{_settings_cache_config_key} eq $config_cache_key) {
        return { %{ $db->{_settings_cache} } };
    }

    my $shop_enabled = _default_shop_enabled($config);
    my $module_shop_enabled = $config->get('module_shop_enabled');
    $module_shop_enabled = defined($module_shop_enabled) && length($module_shop_enabled)
        ? (_truthy($module_shop_enabled) ? 1 : 0)
        : $shop_enabled;
    my %settings = (
        site_name             => $config->get('site_name') || 'DesertCMS',
        site_description      => '',
        site_meta_title       => '',
        site_meta_description => '',
        favicon_path          => '',
        site_logo_path        => '',
        site_logo_nav_path    => '',
        site_logo_admin_path  => '',
        site_logo_fit         => 'contain',
        site_logo_focal_x     => '50',
        site_logo_focal_y     => '50',
        site_logo_max_width_px => '',
        site_logo_max_height_px => '',
        social_image_path     => '',
        site_background_image_path => '',
        homepage_content_id   => '',
        contributor_domain_root => '',
        contributor_media_quota_mb => '',
        contributor_media_upload_limit_mb => '',
        contributor_post_quota  => '',
        contributor_page_quota  => '',
        contributor_plan_features_json => '',
        contributor_blueprint_name => '',
        contributor_blueprint_category => '',
        contributor_blueprint_label => '',
        contributor_allow_postmark_sender_override => 0,
        contributor_allow_stripe_connect => 0,
        contributor_allow_indexing_override => 0,
        contributor_platform_fee_bps => 0,
        postmark_sender_mode  => _default_postmark_sender_mode($config),
        postmark_from_email   => $config->get('postmark_from_email') || '',
        postmark_server_token => $config->get('postmark_server_token') || '',
        postmark_webhook_token => $config->get('postmark_webhook_token') || '',
        contributor_request_recipient_email => '',
        theme_preset          => 'light-archive',
        theme_light_preset    => '',
        theme_dark_preset     => '',
        theme_default_mode    => '',
        theme_custom_name     => 'Custom Theme',
        theme_custom_mode     => 'light',
        theme_custom_ink      => '#102033',
        theme_custom_muted    => '#617284',
        theme_custom_paper    => '#eef3f6',
        theme_custom_panel    => '#ffffff',
        theme_custom_field    => '#f8fafc',
        theme_custom_line     => '#d9e3ea',
        theme_custom_accent   => '#b7791f',
        theme_custom_accent_dark => '#8b5e16',
        theme_custom_support  => '#0e7490',
        theme_custom_button_ink => '#ffffff',
        theme_heading_font    => 'serif',
        theme_body_font       => 'serif',
        theme_ui_font         => 'sans',
        theme_heading_scale   => 'standard',
        theme_body_scale      => 'standard',
        theme_button_style    => 'solid',
        theme_button_radius   => 'soft',
        theme_card_style      => 'outlined',
        theme_card_radius     => 'soft',
        font_package_repo     => $config->get('font_package_repo') || '',
        site_header_layout    => 'split',
        site_brand_display    => 'auto',
        site_logo_size        => 'medium',
        site_nav_style        => 'plain',
        site_homepage_layout  => 'standard',
        site_content_width    => 'standard',
        site_spacing_scale    => 'comfortable',
        site_footer_layout    => 'standard',
        site_footer_order     => 'brand-nav-credit',
        site_footer_nav_enabled => 1,
        site_footer_description_enabled => 1,
        site_footer_credit    => '',
        map_street_tile_url   => 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        map_street_attribution => '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a>',
        map_satellite_tile_url => 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        map_satellite_attribution => 'Imagery &copy; Esri and its data providers',
        map_default_layer     => 'satellite',
        map_default_lat       => '34.500000',
        map_default_lng       => '-112.000000',
        map_default_zoom      => '5',
        module_posts_enabled  => _config_truthy($config, 'module_posts_enabled', 1),
        module_map_enabled    => _config_truthy($config, 'module_map_enabled', 1),
        module_shop_enabled   => $module_shop_enabled,
        module_gallery_enabled => _config_truthy($config, 'module_gallery_enabled', 0),
        module_forms_enabled  => _config_truthy($config, 'module_forms_enabled', 0),
        module_contributor_requests_enabled => _config_truthy($config, 'module_contributor_requests_enabled', 1),
        module_docs_enabled   => _config_truthy($config, 'module_docs_enabled', 0),
        module_events_enabled => _config_truthy($config, 'module_events_enabled', 0),
        module_directory_enabled => _config_truthy($config, 'module_directory_enabled', 0),
        module_bookings_enabled => _config_truthy($config, 'module_bookings_enabled', 0),
        module_membership_enabled => _config_truthy($config, 'module_membership_enabled', 0),
        module_newsletter_enabled => _config_truthy($config, 'module_newsletter_enabled', 0),
        module_donations_enabled => _config_truthy($config, 'module_donations_enabled', 0),
        module_testimonials_enabled => _config_truthy($config, 'module_testimonials_enabled', 0),
        module_accounts_enabled => _config_truthy($config, 'module_accounts_enabled', 0),
        module_live_streaming_enabled => _config_truthy($config, 'module_live_streaming_enabled', 0),
        module_forums_enabled => _config_truthy($config, 'module_forums_enabled', 0),
        module_social_enabled => _config_truthy($config, 'module_social_enabled', 0),
        module_notifications_enabled => _config_truthy($config, 'module_notifications_enabled', 1),
        module_security_center_enabled => _config_truthy($config, 'module_security_center_enabled', 1),
        social_delete_window_seconds => $config->get('social_delete_window_seconds') || 900,
        accounts_google_client_id => $config->get('accounts_google_client_id') || '',
        accounts_google_client_secret => $config->get('accounts_google_client_secret') || '',
        accounts_google_enabled => _config_truthy($config, 'accounts_google_enabled', 1),
        accounts_oidc_discovery_url => $config->get('accounts_oidc_discovery_url') || '',
        accounts_oidc_client_id => $config->get('accounts_oidc_client_id') || '',
        accounts_oidc_client_secret => $config->get('accounts_oidc_client_secret') || '',
        accounts_oidc_enabled => _config_truthy($config, 'accounts_oidc_enabled', 1),
        accounts_allowed_domains => $config->get('accounts_allowed_domains') || '',
        realtime_enabled      => _config_truthy($config, 'realtime_enabled', 0),
        realtime_bind_host    => $config->get('realtime_bind_host') || '127.0.0.1',
        realtime_port         => $config->get('realtime_port') || 8787,
        realtime_public_url   => $config->get('realtime_public_url') || '',
        realtime_allowed_origins => $config->get('realtime_allowed_origins') || '',
        live_chat_account_only => _config_truthy($config, 'live_chat_account_only', 0),
        live_chat_slow_mode_seconds => $config->get('live_chat_slow_mode_seconds') || 0,
        live_chat_delete_window_seconds => $config->get('live_chat_delete_window_seconds') || 900,
        live_chat_presence_stale_seconds => $config->get('live_chat_presence_stale_seconds') || 120,
        theme_unsplash_enabled => _config_truthy($config, 'theme_unsplash_enabled', 0),
        unsplash_access_key   => $config->get('unsplash_access_key') || '',
        theme_background_effect => $config->get('theme_background_effect') || 'none',
        theme_motion_effect   => $config->get('theme_motion_effect') || 'none',
        theme_lighting_effect => $config->get('theme_lighting_effect') || 'none',
        theme_box_transparency => $config->get('theme_box_transparency') || '0',
        theme_outline_transparency => $config->get('theme_outline_transparency') || '0',
        theme_box_shape       => $config->get('theme_box_shape') || 'soft',
        theme_gradient_style  => $config->get('theme_gradient_style') || 'none',
        gallery_title         => 'Showcase',
        gallery_intro         => 'A curated showcase of published assets, collections, products, archives, artwork, venues, and samples.',
        forms_title           => 'Contact',
        forms_intro           => 'Send a message, request a quote, apply, complete an intake, or RSVP.',
        forms_button_label    => 'Send message',
        forms_success_message => 'Thanks. Your message has been received.',
        forms_enabled_types   => 'contact,quote,application,intake,rsvp',
        forms_uploads_enabled => 1,
        forms_max_upload_mb   => 10,
        forms_notify_postmark_enabled => 1,
        forms_notification_email => '',
        docs_title            => 'Resource Hub',
        docs_intro            => 'Guides, documentation, local archive resources, FAQs, and help-center articles.',
        docs_source_dir       => $config->get('docs_source_dir') || '',
        events_title          => 'Events',
        events_intro          => 'Upcoming events, calendars, RSVP opportunities, tickets, and location details.',
        events_notify_postmark_enabled => 0,
        events_notification_email => '',
        directory_title       => 'Directory',
        directory_intro       => 'People, businesses, artists, contributors, vendors, members, places, organizations, and resources.',
        directory_submissions_enabled => 0,
        bookings_title        => 'Bookings',
        bookings_intro        => 'Request appointments, consultations, service sessions, venue time, or project meetings.',
        bookings_requests_enabled => 1,
        bookings_notify_postmark_enabled => 0,
        bookings_notification_email => '',
        membership_title      => 'Members',
        membership_intro      => 'Sign in for private pages, member resources, gated downloads, and client portal collections.',
        membership_signup_enabled => 0,
        membership_notify_postmark_enabled => 0,
        membership_notification_email => '',
        newsletter_title      => 'Newsletter',
        newsletter_intro      => 'Subscribe for announcements, recent posts, events, resources, and site updates.',
        newsletter_consent_text => 'I agree to receive email updates from this site. I can unsubscribe at any time.',
        newsletter_signup_enabled => 1,
        newsletter_default_tags => '',
        donations_title       => 'Donate',
        donations_intro       => 'Support current campaigns, community projects, events, archives, artists, and public work.',
        testimonials_title    => 'Testimonials',
        testimonials_intro    => 'Reviews, recommendations, client stories, customer feedback, and community praise.',
        testimonials_submissions_enabled => 0,
        shop_domain           => $config->get('shop_domain') || '',
        shop_url              => $config->get('shop_url') || '',
        commerce_model        => $config->get('commerce_model') || '',
        shop_enabled          => $shop_enabled,
        shop_require_purchase_token => $config->get('shop_require_purchase_token') ? 1 : 0,
        stripe_secret_key     => $config->get('stripe_secret_key') || '',
        stripe_webhook_secret => $config->get('stripe_webhook_secret') || '',
        stripe_webhook_tolerance_seconds => $config->get('stripe_webhook_tolerance_seconds') || 300,
        stripe_api_base       => $config->get('stripe_api_base') || 'https://api.stripe.com/v1/checkout/sessions',
        stripe_connect_account_id => '',
        stripe_connect_onboarding_status => '',
        stripe_connect_charges_enabled => 0,
        stripe_connect_payouts_enabled => 0,
        google_oauth_client_id => $config->get('google_oauth_client_id') || '',
        google_oauth_client_secret => $config->get('google_oauth_client_secret') || '',
        google_search_console_property => $config->get('google_search_console_property') || $config->get('site_url') || 'http://localhost',
        google_oauth_access_token => '',
        google_oauth_refresh_token => '',
        google_oauth_expires_at => '',
        google_oauth_connected_at => '',
        google_oauth_scope => '',
        google_oauth_last_error => '',
        google_sitemap_last_submitted_at => '',
        google_sitemap_last_status => '',
        google_sitemap_last_error => '',
        indexnow_enabled      => $config->get('indexnow_enabled') ? 1 : 0,
        indexnow_key          => $config->get('indexnow_key') || '',
        indexnow_last_submitted_at => '',
        indexnow_last_url_count => '',
        indexnow_last_status  => '',
        indexnow_last_error   => '',
        operations_backup_schedule_enabled => $config->get('operations_backup_schedule_enabled') ? 1 : 0,
        operations_backup_interval_hours   => $config->get('operations_backup_interval_hours') || 24,
        operations_backup_last_run_at      => '',
        operations_offsite_hook_url        => $config->get('operations_offsite_hook_url') || '',
        operations_offsite_hook_token      => $config->get('operations_offsite_hook_token') || '',
        operations_upgrade_channel         => $config->get('operations_upgrade_channel') || 'stable',
    );

    $settings{commerce_model} = DesertCMS::Commerce::model($config, \%settings);
    return \%settings unless $db;

    my $rows = $db->dbh->selectall_arrayref('SELECT key, value FROM settings', { Slice => {} });
    my %seen;
    for my $row (@{$rows}) {
        if (exists $settings{$row->{key}}) {
            $settings{$row->{key}} = $row->{value};
            $seen{$row->{key}} = 1;
        }
    }
    $settings{module_shop_enabled} = $settings{shop_enabled} if !$seen{module_shop_enabled} && $seen{shop_enabled};
    $settings{module_accounts_enabled} = 1 if _truthy($settings{module_social_enabled});
    $settings{commerce_model} = DesertCMS::Commerce::model($config, \%settings);

    $db->{_settings_cache} = { %settings };
    $db->{_settings_cache_generation} = $SETTINGS_GENERATION;
    $db->{_settings_cache_config_key} = $config_cache_key;
    return { %settings };
}

sub set_many {
    my ($config, $db, $values) = @_;
    delete $db->{_settings_cache} if $db;
    delete $db->{_settings_cache_generation} if $db;
    delete $db->{_settings_cache_config_key} if $db;
    if ($values && _social_requires_accounts($db, $values)) {
        $values->{module_accounts_enabled} = 1;
    }
    my $ts = now();
    my %allowed = map { $_ => 1 } qw(
        site_name site_description site_meta_title site_meta_description
        favicon_path site_logo_path site_logo_nav_path site_logo_admin_path
        site_logo_fit site_logo_focal_x site_logo_focal_y site_logo_max_width_px site_logo_max_height_px
        social_image_path site_background_image_path homepage_content_id
        contributor_domain_root contributor_media_quota_mb contributor_media_upload_limit_mb contributor_post_quota contributor_page_quota contributor_plan_features_json
        contributor_blueprint_name contributor_blueprint_category contributor_blueprint_label
        contributor_allow_postmark_sender_override contributor_allow_stripe_connect contributor_allow_indexing_override contributor_platform_fee_bps
        postmark_sender_mode postmark_from_email postmark_server_token postmark_webhook_token contributor_request_recipient_email
        theme_preset theme_light_preset theme_dark_preset theme_default_mode
        theme_custom_name theme_custom_mode
        theme_custom_ink theme_custom_muted theme_custom_paper theme_custom_panel
        theme_custom_field theme_custom_line theme_custom_accent theme_custom_accent_dark
        theme_custom_support theme_custom_button_ink
        theme_heading_font theme_body_font theme_ui_font theme_heading_scale theme_body_scale
        theme_button_style theme_button_radius theme_card_style theme_card_radius
        font_package_repo
        site_header_layout site_brand_display site_logo_size site_nav_style
        site_homepage_layout site_content_width site_spacing_scale
        site_footer_layout site_footer_order site_footer_nav_enabled site_footer_description_enabled site_footer_credit
        module_posts_enabled module_map_enabled module_shop_enabled module_gallery_enabled module_forms_enabled module_contributor_requests_enabled module_docs_enabled module_events_enabled module_directory_enabled module_bookings_enabled module_membership_enabled module_newsletter_enabled module_donations_enabled module_testimonials_enabled
        module_accounts_enabled module_live_streaming_enabled module_forums_enabled module_social_enabled module_notifications_enabled module_security_center_enabled
        social_delete_window_seconds
        accounts_google_client_id accounts_google_client_secret accounts_google_enabled
        accounts_oidc_discovery_url accounts_oidc_client_id accounts_oidc_client_secret accounts_oidc_enabled accounts_allowed_domains
        realtime_enabled realtime_bind_host realtime_port realtime_public_url realtime_allowed_origins
        live_chat_account_only live_chat_slow_mode_seconds live_chat_delete_window_seconds live_chat_presence_stale_seconds
        theme_unsplash_enabled unsplash_access_key theme_background_effect theme_motion_effect theme_lighting_effect theme_box_transparency theme_outline_transparency theme_box_shape theme_gradient_style
        gallery_title gallery_intro forms_title forms_intro forms_button_label forms_success_message
        forms_enabled_types forms_uploads_enabled forms_max_upload_mb forms_notify_postmark_enabled forms_notification_email
        docs_title docs_intro docs_source_dir
        events_title events_intro events_notify_postmark_enabled events_notification_email
        directory_title directory_intro directory_submissions_enabled
        bookings_title bookings_intro bookings_requests_enabled bookings_notify_postmark_enabled bookings_notification_email
        membership_title membership_intro membership_signup_enabled membership_notify_postmark_enabled membership_notification_email
        newsletter_title newsletter_intro newsletter_consent_text newsletter_signup_enabled newsletter_default_tags
        donations_title donations_intro testimonials_title testimonials_intro testimonials_submissions_enabled
        map_street_tile_url map_street_attribution map_satellite_tile_url map_satellite_attribution
        map_default_layer map_default_lat map_default_lng map_default_zoom
        shop_domain shop_url commerce_model shop_enabled shop_require_purchase_token
        stripe_secret_key stripe_webhook_secret stripe_webhook_tolerance_seconds stripe_api_base
        stripe_connect_account_id stripe_connect_onboarding_status stripe_connect_charges_enabled stripe_connect_payouts_enabled
        google_oauth_client_id google_oauth_client_secret google_search_console_property
        google_oauth_access_token google_oauth_refresh_token google_oauth_expires_at
        google_oauth_connected_at google_oauth_scope google_oauth_last_error
        google_sitemap_last_submitted_at google_sitemap_last_status google_sitemap_last_error
        indexnow_enabled indexnow_key indexnow_last_submitted_at indexnow_last_url_count
        indexnow_last_status indexnow_last_error
        operations_backup_schedule_enabled operations_backup_interval_hours operations_backup_last_run_at
        operations_offsite_hook_url operations_offsite_hook_token operations_upgrade_channel
    );

    for my $key (sort keys %{$values}) {
        next unless $allowed{$key};
        my $value = defined $values->{$key} ? "$values->{$key}" : '';
        $db->dbh->do(
            q{
                INSERT INTO settings (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            },
            undef,
            $key,
            $value,
            $ts
        );
    }
    $SETTINGS_GENERATION++;
    delete $db->{_settings_cache} if $db;
    delete $db->{_settings_cache_generation} if $db;
    delete $db->{_settings_cache_config_key} if $db;
}

sub _config_truthy {
    my ($config, $key, $default) = @_;
    my $value = $config->get($key);
    return $default unless defined $value && length $value;
    return _truthy($value) ? 1 : 0;
}

sub _default_shop_enabled {
    my ($config) = @_;
    return 0 if DesertCMS::Commerce::is_contributor_instance($config)
        && $config->can('has')
        && !$config->has('shop_enabled')
        && !$config->has('module_shop_enabled')
        && !$config->has('commerce_model');
    return $config->get('shop_enabled') ? 1 : 0;
}

sub _default_postmark_sender_mode {
    my ($config) = @_;
    my $value = $config->get('postmark_sender_mode') || '';
    return lc($value) if $value =~ /\A(?:site|inherit)\z/i;
    return 'inherit' if length($config->get('contributor_site_id') || '');
    return 'inherit' if length($config->get('contributor_domain') || '');
    return 'site';
}

sub _social_requires_accounts {
    my ($db, $values) = @_;
    return 0 unless $values && ref($values) eq 'HASH';
    return _truthy($values->{module_social_enabled}) if exists $values->{module_social_enabled};
    return 0 unless $db && $db->can('dbh');
    my ($social_enabled) = $db->dbh->selectrow_array(
        'SELECT value FROM settings WHERE key = ?',
        undef,
        'module_social_enabled'
    );
    return _truthy($social_enabled);
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub store_site_image {
    my ($config, %args) = @_;
    my $kind = $args{kind} || '';
    die "unsupported site image kind"
        unless $kind eq 'favicon' || $kind eq 'social_image' || $kind eq 'site_logo' || $kind eq 'site_background';

    my $mime_type = lc($args{mime_type} || 'application/octet-stream');
    die "unsupported image type" unless $mime_type =~ /\Aimage\/(?:jpeg|png|webp)\z/;
    my $content = $args{content};
    die "image upload content is required" unless defined $content && length $content;

    my $checksum = sha256_hex($content);
    my $tmp_dir = File::Spec->catdir($config->get('data_dir'), 'tmp');
    my $site_dir = File::Spec->catdir($config->get('public_root'), 'assets', 'site');
    make_path($tmp_dir) unless -d $tmp_dir;
    make_path($site_dir) unless -d $site_dir;

    my $source = File::Spec->catfile($tmp_dir, "$kind-$checksum.upload");
    open my $fh, '>:raw', $source or die "cannot write uploaded image: $!";
    print {$fh} $content;
    close $fh;

    my $tool = $config->get('image_tool') || 'magick';
    my ($dest, $rel, @args, @jobs);
    if ($kind eq 'favicon') {
        $dest = File::Spec->catfile($site_dir, 'favicon.png');
        $rel = '/assets/site/favicon.png';
        @args = _uses_vips($tool)
            ? _vips_thumbnail_cmd($tool, $source, $dest, size => '512x512', smartcrop => 'centre')
            : _image_tool_cmd(
                $tool, 'convert', $source,
                '-auto-orient',
                '-resize', '512x512^',
                '-gravity', 'center',
                '-extent', '512x512',
                '-strip',
                $dest,
            );
        push @jobs, [ $dest, \@args, $rel, 'favicon' ];
    } elsif ($kind eq 'social_image') {
        $dest = File::Spec->catfile($site_dir, 'social.jpg');
        $rel = '/assets/site/social.jpg';
        @args = _uses_vips($tool)
            ? _vips_thumbnail_cmd(
                $tool,
                $source,
                $dest,
                size      => '1200x630',
                smartcrop => 'centre',
                quality   => int($config->get('image_public_quality') || 82),
            )
            : _image_tool_cmd(
                $tool, 'convert', $source,
                '-auto-orient',
                '-resize', '1200x630^',
                '-gravity', 'center',
                '-extent', '1200x630',
                '-strip',
                '-colorspace', 'sRGB',
                '-quality', int($config->get('image_public_quality') || 82),
                $dest,
            );
        push @jobs, [ $dest, \@args, $rel, 'social' ];
    } elsif ($kind eq 'site_logo') {
        my @derivatives = (
            [ 'logo.png',       '/assets/site/logo.png',       '640x240', 'default' ],
            [ 'logo-nav.png',   '/assets/site/logo-nav.png',   '360x120', 'nav'     ],
            [ 'logo-admin.png', '/assets/site/logo-admin.png', '260x80',  'admin'   ],
        );
        $rel = $derivatives[0][1];
        for my $derivative (@derivatives) {
            my ($filename, $derivative_rel, $size, $label) = @{$derivative};
            my $target = File::Spec->catfile($site_dir, $filename);
            my @cmd = _uses_vips($tool)
                ? _vips_thumbnail_cmd($tool, $source, $target, size => $size)
                : _image_tool_cmd(
                    $tool, 'convert', $source,
                    '-auto-orient',
                    '-resize', "$size>",
                    '-strip',
                    $target,
                );
            push @jobs, [ $target, \@cmd, $derivative_rel, $label ];
        }
    } else {
        $dest = File::Spec->catfile($site_dir, 'background.jpg');
        $rel = '/assets/site/background.jpg';
        @args = _uses_vips($tool)
            ? _vips_thumbnail_cmd(
                $tool,
                $source,
                $dest,
                size    => '2200x1600',
                quality => int($config->get('image_public_quality') || 82),
            )
            : _image_tool_cmd(
                $tool, 'convert', $source,
                '-auto-orient',
                '-resize', '2200x1600>',
                '-strip',
                '-colorspace', 'sRGB',
                '-quality', int($config->get('image_public_quality') || 82),
                $dest,
            );
        push @jobs, [ $dest, \@args, $rel, 'background' ];
    }

    for my $job (@jobs) {
        my ($target, $cmd) = @{$job};
        system @{$cmd};
        my $status = $?;
        if ($status != 0 || !-f $target) {
            unlink $source;
            my $program = $cmd->[0] || 'image tool';
            my $reason = $status == -1
                ? "could not execute $program: $!"
                : "status $status";
            die "site image processing failed ($reason)";
        }
    }
    _write_site_image_manifest($config, $kind, $tool, \@jobs);
    unlink $source;
    return $rel;
}

sub site_image_manifest {
    my ($config) = @_;
    my $path = File::Spec->catfile($config->get('public_root'), 'assets', 'site', 'site-images.json');
    return {} unless -f $path;
    open my $fh, '<', $path or return {};
    local $/;
    my $body = <$fh>;
    close $fh;
    my $decoded = eval { decode_json($body || '{}') };
    return ref $decoded eq 'HASH' ? $decoded : {};
}

sub site_logo_derivative_paths {
    return (
        site_logo_path       => '/assets/site/logo.png',
        site_logo_nav_path   => '/assets/site/logo-nav.png',
        site_logo_admin_path => '/assets/site/logo-admin.png',
    );
}

sub _write_site_image_manifest {
    my ($config, $kind, $tool, $jobs) = @_;
    my $manifest = site_image_manifest($config);
    $manifest->{$kind} = {};
    for my $job (@{$jobs || []}) {
        my ($target, undef, $rel, $label) = @{$job};
        next unless defined $rel && length $rel && -f $target;
        my ($width, $height) = eval { _identify($tool, $target) };
        next unless int($width || 0) > 0 && int($height || 0) > 0;
        $manifest->{$kind}{$label || 'default'} = {
            path   => $rel,
            width  => int($width),
            height => int($height),
        };
    }
    my $site_dir = File::Spec->catdir($config->get('public_root'), 'assets', 'site');
    make_path($site_dir) unless -d $site_dir;
    my $path = File::Spec->catfile($site_dir, 'site-images.json');
    open my $fh, '>', $path or die "cannot write site image manifest: $!";
    print {$fh} encode_json($manifest);
    close $fh;
}

sub _identify {
    my ($tool, $path) = @_;
    if (_uses_vips($tool)) {
        my @cmd = (_sibling_command($tool, 'vipsheader'), $path);
        open my $pipe, '-|', @cmd or die "cannot run vips image identify: $!";
        my $out = do { local $/; <$pipe> };
        close $pipe;
        die "vips image identify failed" if $? != 0;
        my ($width, $height) = $out =~ /:\s*([0-9]+)x([0-9]+)\b/;
        return ($width || undef, $height || undef);
    }
    my @cmd = _image_tool_cmd($tool, 'identify', '-format', '%w %h', $path);
    open my $pipe, '-|', @cmd or die "cannot run image identify: $!";
    my $out = do { local $/; <$pipe> };
    close $pipe;
    die "image identify failed" if $? != 0;
    my ($width, $height) = $out =~ /([0-9]+)\s+([0-9]+)/;
    return ($width || undef, $height || undef);
}

sub _image_tool_cmd {
    my ($tool, $operation, @args) = @_;
    my $name = $tool;
    $name =~ s{\\}{/}g;
    $name =~ s{\A.*/}{};
    my $resolved = _resolve_command($tool);
    return ($resolved, $operation, @args)
        if $name eq 'gm' || $name =~ /^gm(?:\.exe)?\z/i || $operation eq 'identify';
    return ($resolved, @args);
}

sub _vips_thumbnail_cmd {
    my ($tool, $source, $dest, %opts) = @_;
    my $output = $dest;
    if ($dest =~ /\.jpe?g\z/i) {
        my $quality = int($opts{quality} || 82);
        $quality = 82 if $quality < 1 || $quality > 100;
        $output .= "[Q=$quality,strip]";
    }
    my @cmd = (
        _sibling_command($tool, 'vipsthumbnail'),
        $source,
        '--size',
        $opts{size} || '1200x630',
    );
    push @cmd, '--smartcrop', $opts{smartcrop} if $opts{smartcrop};
    push @cmd, '-o', $output;
    return @cmd;
}

sub _uses_vips {
    my ($tool) = @_;
    my $name = $tool || '';
    $name =~ s{\\}{/}g;
    $name =~ s{\A.*/}{};
    return $name =~ /^(?:vips|vipsthumbnail|vipsheader)(?:\.exe)?\z/i;
}

sub _sibling_command {
    my ($tool, $command) = @_;
    my $name = $tool || '';
    $name =~ s{\\}{/}g;
    $name =~ s{\A.*/}{};
    my $suffix = $name =~ /\.exe\z/i ? '.exe' : '';
    return _resolve_command($command . $suffix) unless ($tool || '') =~ m{[\\/]};

    my ($volume, $dir) = File::Spec->splitpath($tool);
    return File::Spec->catpath($volume, $dir, $command . $suffix);
}

sub _resolve_command {
    my ($command) = @_;
    return $command unless defined $command && length $command;
    return $command if $command =~ m{[\\/]};

    my %seen;
    for my $dir (File::Spec->path, qw(/usr/local/bin /usr/bin /bin /usr/local/sbin /usr/sbin /sbin)) {
        next unless defined $dir && length $dir && !$seen{$dir}++;
        my $candidate = File::Spec->catfile($dir, $command);
        return $candidate if -x $candidate;
    }
    return $command;
}

1;
