package DesertCMS::Modules;

use strict;
use warnings;
use Exporter 'import';
use JSON::PP qw(decode_json encode_json);

our @EXPORT_OK = qw(
    definitions enabled catalog feature_keys feature_map_for_plan
    feature_map_from_values features_json setting_key
);

my @MODULE_DEFINITIONS = (
    {
        key                  => 'map',
        label                => 'Map / Locations',
        description          => 'Adds the public /map/ locations page for stores, venues, project locations, historical sites, event locations, service areas, and other mapped content.',
        public_path          => '/map/',
        settings_path        => '/admin/settings/modules/map',
        setting_key          => 'module_map_enabled',
        default_plan_enabled => 1,
    },
    {
        key                  => 'shop',
        label                => 'Shop / Catalog',
        description          => 'Adds the public /shop catalog for products, services, digital items, portfolio samples, and inquiry listings.',
        public_path          => '/shop',
        settings_path        => '/admin/settings/modules/shop',
        setting_key          => 'module_shop_enabled',
        default_plan_enabled => 0,
    },
    {
        key                  => 'shop_payments',
        label                => 'Shop Payments',
        description          => 'Unlocks Stripe checkout, marketplace payouts, platform fees, paid orders, and rights-purchase controls for Shop / Catalog listings.',
        public_path          => '/shop',
        settings_path        => '/admin/settings/modules/shop',
        default_plan_enabled => 0,
    },
    {
        key                  => 'events',
        label                => 'Events',
        description          => 'Adds a public /events calendar, event pages, RSVP, free tickets, recurring events, locations, and calendar export.',
        public_path          => '/events/',
        settings_path        => '/admin/settings/modules/events',
        setting_key          => 'module_events_enabled',
        default_plan_enabled => 0,
    },
    {
        key                  => 'event_payments',
        label                => 'Event Payments',
        description          => 'Unlocks paid event tickets, Stripe Checkout, marketplace payouts, and platform fees for Events.',
        public_path          => '/events/',
        settings_path        => '/admin/settings/modules/events',
        default_plan_enabled => 0,
    },
    {
        key                  => 'directory',
        label                => 'Directory',
        description          => 'Adds a public /directory for people, businesses, artists, contributors, vendors, members, places, organizations, and resources.',
        public_path          => '/directory/',
        settings_path        => '/admin/settings/modules/directory',
        setting_key          => 'module_directory_enabled',
        default_plan_enabled => 0,
    },
    {
        key                  => 'bookings',
        label                => 'Bookings / Appointments',
        description          => 'Adds public /bookings service listings, availability details, appointment request forms, review workflow, and request export.',
        public_path          => '/bookings/',
        settings_path        => '/admin/settings/modules/bookings',
        setting_key          => 'module_bookings_enabled',
        default_plan_enabled => 0,
    },
    {
        key                  => 'booking_payments',
        label                => 'Booking Deposits',
        description          => 'Unlocks Stripe Checkout deposits, marketplace payouts, platform fees, and payment records for booking requests.',
        public_path          => '/bookings/',
        settings_path        => '/admin/settings/modules/bookings',
        default_plan_enabled => 0,
    },
    {
        key                  => 'membership',
        label                => 'Membership / Gated Content',
        description          => 'Adds public /members signup, member login, groups, member dashboards, gated pages, and authenticated private resource downloads.',
        public_path          => '/members/',
        settings_path        => '/admin/settings/modules/membership',
        setting_key          => 'module_membership_enabled',
        default_plan_enabled => 0,
    },
    {
        key                  => 'membership_payments',
        label                => 'Membership Payments',
        description          => 'Unlocks paid member resources, subscription records, Stripe Checkout, marketplace payouts, and platform fees for Membership.',
        public_path          => '/members/',
        settings_path        => '/admin/settings/modules/membership',
        default_plan_enabled => 0,
    },
    {
        key                  => 'newsletter',
        label                => 'Newsletter',
        description          => 'Adds public /newsletter signup, subscriber records, tags and segments, announcement drafts, digest generation, Postmark delivery, unsubscribe links, send history, and subscriber export.',
        public_path          => '/newsletter/',
        settings_path        => '/admin/settings/modules/newsletter',
        setting_key          => 'module_newsletter_enabled',
        default_plan_enabled => 0,
    },
    {
        key                  => 'donations',
        label                => 'Donations / Fundraising',
        description          => 'Adds public /donate fundraising campaigns, suggested and custom amounts, donor messages, goal progress, donor export, and campaign pages.',
        public_path          => '/donate/',
        settings_path        => '/admin/settings/modules/donations',
        setting_key          => 'module_donations_enabled',
        default_plan_enabled => 0,
    },
    {
        key                  => 'donation_payments',
        label                => 'Donation Payments',
        description          => 'Unlocks Stripe Checkout donations, marketplace payouts, platform fees, receipts, webhook fulfillment, and campaign totals for Donations.',
        public_path          => '/donate/',
        settings_path        => '/admin/settings/modules/donations',
        default_plan_enabled => 0,
    },
    {
        key                  => 'testimonials',
        label                => 'Testimonials / Reviews',
        description          => 'Adds public /testimonials approved testimonials, optional ratings, related services or directory entries, moderated public submissions, and CSV export.',
        public_path          => '/testimonials/',
        settings_path        => '/admin/settings/modules/testimonials',
        setting_key          => 'module_testimonials_enabled',
        default_plan_enabled => 0,
    },
    {
        key                  => 'gallery',
        label                => 'Showcase',
        description          => 'Adds a public /showcase/ page for portfolios, case studies, collections, products, archives, artwork, venues, and samples.',
        public_path          => '/showcase/',
        settings_path        => '/admin/settings/modules/showcase',
        setting_key          => 'module_gallery_enabled',
        default_plan_enabled => 1,
    },
    {
        key                  => 'forms',
        label                => 'Forms',
        description          => 'Adds public contact, quote, application, intake, RSVP, upload, and Postmark-notified form workflows.',
        public_path          => '/forms/',
        settings_path        => '/admin/settings/modules/forms',
        setting_key          => 'module_forms_enabled',
        default_plan_enabled => 0,
    },
    {
        key                           => 'contributor_requests',
        label                         => 'Contributor Requests',
        description                   => 'Adds a page block and review queue for public contributor applications.',
        public_path                   => '/contributors/',
        settings_path                 => '/admin/settings/contributors',
        setting_key                   => 'module_contributor_requests_enabled',
        default_plan_enabled          => 0,
        managed_by_master_contributor => 1,
    },
    {
        key                  => 'docs',
        label                => 'Docs / Resource Hub',
        description          => 'Adds a public /docs/ hub for documentation sites, guides, local archives, member resources, FAQs, and help-center articles generated from Markdown files.',
        public_path          => '/docs/',
        settings_path        => '/admin/settings/modules/docs',
        setting_key          => 'module_docs_enabled',
        default_plan_enabled => 0,
    },
    {
        key                  => 'resource_publishing',
        label                => 'Resource Downloads',
        description          => 'Allows private source files to be published as public Resource-block downloads.',
        public_path          => '/assets/resources/',
        settings_path        => '/admin/media?filter=resources',
        setting_key          => 'module_resource_publishing_enabled',
        default_plan_enabled => 0,
    },
);

my %MODULE_BY_KEY = map { $_->{key} => $_ } @MODULE_DEFINITIONS;

sub definitions {
    return catalog(@_);
}

sub catalog {
    my ($settings, %options) = @_;
    $settings ||= {};
    my $config = $options{config};
    my $contributor = _contributor_product_mode($config);
    my ($plan_features, $has_plan_features) = _settings_plan_features($settings);

    my @modules;
    for my $definition (@MODULE_DEFINITIONS) {
        my $key = $definition->{key};
        my $configured_enabled = _configured_enabled($settings, $key);
        my $managed_by_master = $contributor && $definition->{managed_by_master_contributor} ? 1 : 0;
        my $locked_by_plan = $contributor
            && !$managed_by_master
            && $has_plan_features
            && !$plan_features->{$key}
            ? 1
            : 0;
        my $available = !$managed_by_master && !$locked_by_plan ? 1 : 0;
        my $effective_enabled = $available && $configured_enabled ? 1 : 0;
        push @modules, {
            %{$definition},
            available          => $available,
            enabled            => $effective_enabled,
            configured_enabled => $configured_enabled,
            locked_by_plan     => $locked_by_plan,
            requires_upgrade   => $locked_by_plan,
            managed_by_master  => $managed_by_master,
            form_field         => $definition->{setting_key} ? 'module_' . $key . '_enabled' : '',
        };
    }
    return \@modules;
}

sub enabled {
    my ($settings, $key) = @_;
    return 0 if _locked_by_plan($settings, $key);
    return _configured_enabled($settings, $key);
}

sub feature_keys {
    return [ map { $_->{key} } @MODULE_DEFINITIONS ];
}

sub setting_key {
    my ($key) = @_;
    return $MODULE_BY_KEY{$key} ? $MODULE_BY_KEY{$key}{setting_key} : '';
}

sub feature_map_for_plan {
    my ($plan) = @_;
    my ($features, $has_features) = _json_feature_map($plan ? $plan->{features_json} : undef);
    return $features if $has_features;

    my %all_available = map { $_->{key} => $_->{managed_by_master_contributor} ? 0 : 1 } @MODULE_DEFINITIONS;
    return \%all_available;
}

sub feature_map_from_values {
    my ($values, $fallback) = @_;
    $values ||= {};
    my %features = %{ _feature_map_from_module_fields($fallback) || _default_plan_feature_map() };
    if ($values->{feature_map} && ref $values->{feature_map} eq 'HASH') {
        for my $key (@{ feature_keys() }) {
            $features{$key} = _truthy($values->{feature_map}{$key}) ? 1 : 0
                if exists $values->{feature_map}{$key};
        }
    }
    for my $key (@{ feature_keys() }) {
        my $param = 'feature_' . $key . '_included';
        $features{$key} = _truthy($values->{$param}) ? 1 : 0
            if exists $values->{$param};
    }
    $features{contributor_requests} = 0;
    return \%features;
}

sub features_json {
    my ($features) = @_;
    $features ||= {};
    my %clean;
    for my $key (@{ feature_keys() }) {
        $clean{$key} = _truthy($features->{$key}) ? 1 : 0;
    }
    return encode_json(\%clean);
}

sub _configured_enabled {
    my ($settings, $key) = @_;
    $settings ||= {};
    if (($key || '') eq 'map') {
        return _truthy(_setting($settings, 'module_map_enabled', 1));
    }
    if (($key || '') eq 'shop') {
        my $module_value = _setting($settings, 'module_shop_enabled', undef);
        return _truthy($module_value) if defined $module_value && length "$module_value";
        return _truthy(_setting($settings, 'shop_enabled', 0));
    }
    if (($key || '') eq 'shop_payments') {
        return 0 unless _configured_enabled($settings, 'shop');
        my $model = lc(_setting($settings, 'commerce_model', '') || '');
        $model =~ s/[-\s]+/_/g;
        return 1 if $model eq 'master_owned' || $model eq 'contributor_owned' || $model eq 'platform_marketplace';
        return _truthy(_setting($settings, 'contributor_allow_stripe_connect', 0));
    }
    if (($key || '') eq 'events') {
        return _truthy(_setting($settings, 'module_events_enabled', 0));
    }
    if (($key || '') eq 'event_payments') {
        return 0 unless _configured_enabled($settings, 'events');
        my $model = lc(_setting($settings, 'commerce_model', '') || '');
        $model =~ s/[-\s]+/_/g;
        return 1 if $model eq 'master_owned' || $model eq 'contributor_owned' || $model eq 'platform_marketplace';
        return _truthy(_setting($settings, 'contributor_allow_stripe_connect', 0));
    }
    if (($key || '') eq 'directory') {
        return _truthy(_setting($settings, 'module_directory_enabled', 0));
    }
    if (($key || '') eq 'bookings') {
        return _truthy(_setting($settings, 'module_bookings_enabled', 0));
    }
    if (($key || '') eq 'booking_payments') {
        return 0 unless _configured_enabled($settings, 'bookings');
        my $model = lc(_setting($settings, 'commerce_model', '') || '');
        $model =~ s/[-\s]+/_/g;
        return 1 if $model eq 'master_owned' || $model eq 'contributor_owned' || $model eq 'platform_marketplace';
        return _truthy(_setting($settings, 'contributor_allow_stripe_connect', 0));
    }
    if (($key || '') eq 'membership') {
        return _truthy(_setting($settings, 'module_membership_enabled', 0));
    }
    if (($key || '') eq 'membership_payments') {
        return 0 unless _configured_enabled($settings, 'membership');
        my $model = lc(_setting($settings, 'commerce_model', '') || '');
        $model =~ s/[-\s]+/_/g;
        return 1 if $model eq 'master_owned' || $model eq 'contributor_owned' || $model eq 'platform_marketplace';
        return _truthy(_setting($settings, 'contributor_allow_stripe_connect', 0));
    }
    if (($key || '') eq 'newsletter') {
        return _truthy(_setting($settings, 'module_newsletter_enabled', 0));
    }
    if (($key || '') eq 'donations') {
        return _truthy(_setting($settings, 'module_donations_enabled', 0));
    }
    if (($key || '') eq 'donation_payments') {
        return 0 unless _configured_enabled($settings, 'donations');
        my $model = lc(_setting($settings, 'commerce_model', '') || '');
        $model =~ s/[-\s]+/_/g;
        return 1 if $model eq 'master_owned' || $model eq 'contributor_owned' || $model eq 'platform_marketplace';
        return _truthy(_setting($settings, 'contributor_allow_stripe_connect', 0));
    }
    if (($key || '') eq 'testimonials') {
        return _truthy(_setting($settings, 'module_testimonials_enabled', 0));
    }
    if (($key || '') eq 'gallery') {
        return _truthy(_setting($settings, 'module_gallery_enabled', 0));
    }
    if (($key || '') eq 'forms') {
        return _truthy(_setting($settings, 'module_forms_enabled', 0));
    }
    if (($key || '') eq 'contributor_requests') {
        return _truthy(_setting($settings, 'module_contributor_requests_enabled', 1));
    }
    if (($key || '') eq 'docs') {
        return _truthy(_setting($settings, 'module_docs_enabled', 0));
    }
    if (($key || '') eq 'resource_publishing') {
        return _truthy(_setting($settings, 'module_resource_publishing_enabled', 1));
    }
    return 0;
}

sub _locked_by_plan {
    my ($settings, $key) = @_;
    my ($features, $has_features) = _settings_plan_features($settings);
    return 0 unless $has_features;
    return 0 unless $MODULE_BY_KEY{$key};
    return $features->{$key} ? 0 : 1;
}

sub _settings_plan_features {
    my ($settings) = @_;
    return _json_feature_map($settings ? $settings->{contributor_plan_features_json} : undef);
}

sub _json_feature_map {
    my ($json) = @_;
    return (_default_plan_feature_map(), 0) unless defined $json && length $json;
    my $decoded = eval { decode_json($json) };
    return (_default_plan_feature_map(), 0) unless $decoded && ref $decoded eq 'HASH';
    my %features;
    my $has_known_key = 0;
    for my $key (@{ feature_keys() }) {
        if (exists $decoded->{$key}) {
            $features{$key} = _truthy($decoded->{$key}) ? 1 : 0;
            $has_known_key = 1;
        } elsif ($key eq 'shop_payments' && exists $decoded->{shop}) {
            $features{$key} = _truthy($decoded->{shop}) ? 1 : 0;
        } elsif ($key eq 'event_payments' && exists $decoded->{events}) {
            $features{$key} = _truthy($decoded->{events}) ? 1 : 0;
        } elsif ($key eq 'booking_payments' && exists $decoded->{bookings}) {
            $features{$key} = _truthy($decoded->{bookings}) ? 1 : 0;
        } elsif ($key eq 'donation_payments' && exists $decoded->{donations}) {
            $features{$key} = _truthy($decoded->{donations}) ? 1 : 0;
        } else {
            $features{$key} = 0;
        }
    }
    $features{contributor_requests} = 0;
    return (\%features, $has_known_key ? 1 : 0);
}

sub _feature_map_from_module_fields {
    my ($values) = @_;
    return undef unless $values && ref $values eq 'HASH';
    my %features;
    my $found = 0;
    for my $definition (@MODULE_DEFINITIONS) {
        my $key = $definition->{key};
        my $setting = $definition->{setting_key} || '';
        if (length($setting) && exists $values->{$setting}) {
            $features{$key} = _truthy($values->{$setting}) ? 1 : 0;
            $found = 1;
        } else {
            $features{$key} = $definition->{default_plan_enabled} ? 1 : 0;
        }
    }
    $features{contributor_requests} = 0;
    return $found ? \%features : undef;
}

sub _default_plan_feature_map {
    return {
        map {
            $_->{key} => ($_->{default_plan_enabled} ? 1 : 0)
        } @MODULE_DEFINITIONS
    };
}

sub _contributor_product_mode {
    my ($config) = @_;
    return 0 unless $config;
    return 1 if length($config->get('contributor_site_id') || '');
    return 1 if length($config->get('contributor_domain') || '');
    return 0;
}

sub _setting {
    my ($settings, $key, $default) = @_;
    return $settings->{$key} if exists $settings->{$key} && defined $settings->{$key};
    return $default;
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

1;
