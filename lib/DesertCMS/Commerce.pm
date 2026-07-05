package DesertCMS::Commerce;

use strict;
use warnings;
use Exporter 'import';
use JSON::PP qw(decode_json);

our @EXPORT_OK = qw(
    catalog_enabled checkout_allowed_by_plan checkout_enabled checkout_ready
    default_model is_contributor_instance label model model_allows_checkout
    model_options normalize_model readiness shop_config_enabled
);

my %MODELS = (
    disabled => {
        label       => 'Disabled',
        summary     => 'No public checkout is available.',
        direct      => 0,
        marketplace => 0,
    },
    master_owned => {
        label       => 'Master-owned sales',
        summary     => 'This CMS instance receives direct Stripe Checkout sales into its configured Stripe account.',
        direct      => 1,
        marketplace => 0,
    },
    contributor_owned => {
        label       => 'Contributor-owned sales',
        summary     => 'This contributor CMS receives direct Stripe Checkout sales into its own configured Stripe account.',
        direct      => 1,
        marketplace => 0,
    },
    platform_marketplace => {
        label       => 'Platform marketplace payouts',
        summary     => 'Checkout uses the master Stripe account, transfers proceeds to the contributor connected account, and keeps the plan platform fee.',
        direct      => 0,
        marketplace => 1,
    },
    marketplace_pending => {
        label       => 'Marketplace planning',
        summary     => 'Commission payouts need Stripe Connect and are not enabled in this release.',
        direct      => 0,
        marketplace => 1,
    },
);

my @MODEL_ORDER = qw(disabled master_owned contributor_owned platform_marketplace marketplace_pending);

sub model_options {
    return [
        map {
            {
                value   => $_,
                label   => $MODELS{$_}{label},
                summary => $MODELS{$_}{summary},
            }
        } @MODEL_ORDER
    ];
}

sub normalize_model {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    $value = lc $value;
    $value =~ s/[-\s]+/_/g;
    return $MODELS{$value} ? $value : '';
}

sub default_model {
    my ($config, $settings) = @_;
    return 'disabled' unless shop_config_enabled($settings);
    return 'disabled' unless checkout_allowed_by_plan($settings);
    if (is_contributor_instance($config)) {
        return _truthy(_setting($settings, 'contributor_allow_stripe_connect', 0))
            ? 'platform_marketplace'
            : 'disabled';
    }
    return 'master_owned';
}

sub model {
    my ($config, $settings) = @_;
    $settings ||= {};
    my $explicit = normalize_model(_setting($settings, 'commerce_model', $config ? $config->get('commerce_model') : ''));
    return $explicit if length $explicit;
    return default_model($config, $settings);
}

sub label {
    my ($value) = @_;
    my $normalized = normalize_model($value) || 'disabled';
    return $MODELS{$normalized}{label};
}

sub model_allows_checkout {
    my ($value) = @_;
    my $normalized = normalize_model($value) || 'disabled';
    return 1 if $MODELS{$normalized}{direct};
    return 1 if $normalized eq 'platform_marketplace';
    return 0;
}

sub checkout_enabled {
    my ($config, $settings) = @_;
    $settings ||= {};
    my $selected = model($config, $settings);
    return 0 unless checkout_allowed_by_plan($settings);
    return 0 unless model_allows_checkout($selected);
    return shop_config_enabled($settings) ? 1 : 0;
}

sub catalog_enabled {
    my ($settings) = @_;
    $settings ||= {};
    return 0 unless shop_config_enabled($settings);
    return _plan_feature_enabled($settings, 'shop', 1) ? 1 : 0;
}

sub checkout_allowed_by_plan {
    my ($settings) = @_;
    return _plan_feature_enabled($settings || {}, 'shop_payments', 1) ? 1 : 0;
}

sub checkout_ready {
    my ($config, $settings) = @_;
    return readiness($config, $settings)->{checkout_enabled} ? 1 : 0;
}

sub shop_config_enabled {
    my ($settings) = @_;
    $settings ||= {};
    my $module = _setting($settings, 'module_shop_enabled', undef);
    return 0 if defined $module && length "$module" && !_truthy($module);
    return _truthy(_setting($settings, 'shop_enabled', 0)) ? 1 : 0;
}

sub readiness {
    my ($config, $settings) = @_;
    $settings ||= {};

    my $selected = model($config, $settings);
    my $model_label = label($selected);
    my $shop_enabled = shop_config_enabled($settings);
    my $catalog_enabled = catalog_enabled($settings);
    my $checkout_allowed = checkout_allowed_by_plan($settings);
    my $model_allows_checkout = model_allows_checkout($selected);
    my $allows_checkout = $checkout_allowed && $model_allows_checkout ? 1 : 0;
    my $marketplace = $MODELS{$selected}{marketplace} ? 1 : 0;
    my $stripe_key = length(_setting($settings, 'stripe_secret_key', '') || '') ? 1 : 0;
    my $webhook = length(_setting($settings, 'stripe_webhook_secret', '') || '') ? 1 : 0;
    my $connect_account = length(_setting($settings, 'stripe_connect_account_id', '') || '') ? 1 : 0;
    my $connect_allowed = $checkout_allowed && _truthy(_setting($settings, 'contributor_allow_stripe_connect', 0)) ? 1 : 0;
    my $stripe_ready = $stripe_key && $webhook ? 1 : 0;

    my ($state, $status, $summary);
    if ($shop_enabled && !$checkout_allowed) {
        ($state, $status, $summary) = (
            'neutral',
            'Payments locked',
            'Catalog listings are available; Stripe checkout requires a plan with Shop Payments.',
        );
    } elsif ($selected eq 'disabled') {
        ($state, $status, $summary) = (
            'neutral',
            'Disabled',
            'Commerce is off for this CMS instance.',
        );
    } elsif ($selected eq 'marketplace_pending') {
        ($state, $status, $summary) = (
            'warn',
            'Connect needed',
            'Marketplace commission payouts need Stripe Connect before checkout should be enabled.',
        );
    } elsif ($selected eq 'platform_marketplace' && !$connect_allowed) {
        ($state, $status, $summary) = (
            'warn',
            'Plan locked',
            'This plan does not include contributor Stripe payouts.',
        );
    } elsif (!$shop_enabled) {
        ($state, $status, $summary) = (
            'warn',
            'Shop disabled',
            'The selected commerce model needs the Shop module enabled before checkout can run.',
        );
    } elsif (!$stripe_ready) {
        ($state, $status, $summary) = (
            'warn',
            'Needs Stripe',
            $marketplace
                ? 'Marketplace checkout needs inherited master Stripe credentials and webhook secret.'
                : 'Direct Stripe Checkout needs both a secret key and webhook secret.',
        );
    } elsif ($selected eq 'platform_marketplace' && !$connect_account) {
        ($state, $status, $summary) = (
            'warn',
            'Connect payouts',
            'Connect a Stripe payout account before this contributor shop can take payments.',
        );
    } else {
        ($state, $status, $summary) = (
            'ok',
            'Ready',
            $marketplace
                ? "$model_label is ready for destination-charge Checkout."
                : "$model_label is ready for direct Stripe Checkout.",
        );
    }

    my @checks = (
        {
            key    => 'model',
            title  => 'Commerce model',
            state  => $state,
            label  => $status,
            detail => $MODELS{$selected}{summary},
        },
        {
            key    => 'shop',
            title  => 'Catalog',
            state  => $catalog_enabled ? 'ok' : 'neutral',
            label  => $catalog_enabled ? 'Enabled' : 'Disabled',
            detail => $catalog_enabled
                ? 'The public /shop route can serve catalog listings.'
                : 'The public catalog route is disabled.',
        },
        {
            key    => 'shop_payments',
            title  => 'Shop Payments',
            state  => $checkout_allowed ? ($model_allows_checkout ? 'ok' : 'neutral') : 'warn',
            label  => $checkout_allowed ? ($model_allows_checkout ? 'Allowed' : 'Not selected') : 'Locked',
            detail => $checkout_allowed
                ? ($model_allows_checkout ? 'This plan can show Stripe checkout when payment settings are ready.' : 'Select a checkout-capable commerce model before taking payments.')
                : 'Upgrade the plan before showing buy buttons or creating Checkout Sessions.',
        },
        {
            key    => 'stripe_key',
            title  => 'Stripe API',
            state  => $allows_checkout ? ($stripe_key ? 'ok' : 'warn') : 'neutral',
            label  => $stripe_key ? 'Configured' : 'Missing',
            detail => $allows_checkout
                ? ($marketplace ? 'Inherited from the master CMS for platform Checkout.' : 'Required for creating Checkout Sessions.')
                : 'Not used unless checkout is selected.',
        },
        {
            key    => 'stripe_webhook',
            title  => 'Stripe webhook',
            state  => $allows_checkout ? ($webhook ? 'ok' : 'warn') : 'neutral',
            label  => $webhook ? 'Configured' : 'Missing',
            detail => $allows_checkout
                ? ($marketplace ? 'Inherited from the master CMS for payment fulfillment.' : 'Required for reliable payment fulfillment.')
                : 'Not used unless checkout is selected.',
        },
        {
            key    => 'stripe_connect',
            title  => 'Marketplace payouts',
            state  => $marketplace ? ($connect_account ? 'ok' : 'warn') : 'neutral',
            label  => $marketplace ? ($connect_account ? 'Connected' : 'Needs onboarding') : 'Not used',
            detail => $marketplace
                ? 'Destination charges transfer proceeds to this contributor account while the platform keeps its fee.'
                : 'The selected model uses one direct Stripe account for the site.',
        },
    );

    return {
        model            => $selected,
        model_label      => $model_label,
        state            => $state,
        label            => $status,
        summary          => $summary,
        shop_enabled     => $shop_enabled,
        catalog_enabled  => $catalog_enabled,
        checkout_allowed => $checkout_allowed,
        stripe_ready     => $stripe_ready,
        marketplace      => $marketplace,
        connect_account  => $connect_account,
        checkout_enabled => ($allows_checkout && $shop_enabled && $stripe_ready && (!$marketplace || $connect_account)) ? 1 : 0,
        checks           => \@checks,
    };
}

sub is_contributor_instance {
    my ($config) = @_;
    return 0 unless $config;
    return 1 if length($config->get('contributor_site_id') || '');
    return 1 if length($config->get('contributor_domain') || '');
    return 0;
}

sub _plan_feature_enabled {
    my ($settings, $key, $default_without_plan) = @_;
    my $json = _setting($settings, 'contributor_plan_features_json', '');
    return $default_without_plan ? 1 : 0 unless defined $json && length $json;
    my $decoded = eval { decode_json($json) };
    return $default_without_plan ? 1 : 0 unless $decoded && ref $decoded eq 'HASH';
    return _truthy($decoded->{$key}) ? 1 : 0 if exists $decoded->{$key};
    return _truthy($decoded->{shop}) ? 1 : 0 if $key eq 'shop_payments' && exists $decoded->{shop};
    return 0;
}

sub _setting {
    my ($settings, $key, $default) = @_;
    return $settings->{$key} if $settings && exists $settings->{$key} && defined $settings->{$key};
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
