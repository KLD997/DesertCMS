package DesertCMS::Commerce;

use strict;
use warnings;
use Exporter 'import';
use JSON::PP qw(decode_json);
use DesertCMS::Modules;

our @EXPORT_OK = qw(
    catalog_enabled checkout_allowed_by_plan checkout_enabled checkout_ready
    default_model is_contributor_instance label model model_allows_checkout
    model_options normalize_model payment_allowed_by_plan payment_hub_readiness
    payment_model payment_readiness readiness shop_config_enabled
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

my %WORKFLOWS = (
    shop => {
        label => 'Shop / Catalog',
        module_key => 'shop',
        payment_key => 'shop_payments',
        disabled_label => 'Shop disabled',
        disabled_summary => 'Enable Shop before selling catalog listings.',
        locked_label => 'Payments locked',
        locked_summary => 'Catalog listings are available; Stripe checkout requires a plan with Shop Payments.',
        model_disabled_label => 'Payments disabled',
        model_disabled_summary => 'Select a checkout-capable commerce model before taking catalog payments.',
        stripe_summary => 'Direct Stripe Checkout needs both a secret key and webhook secret.',
        marketplace_stripe_summary => 'Marketplace checkout needs inherited master Stripe credentials and webhook secret.',
        connect_summary => 'Connect a Stripe payout account before this contributor shop can take payments.',
        ready_summary => 'Shop checkout is ready.',
        ready_marketplace_summary => 'Shop checkout is ready for platform marketplace payouts.',
    },
    events => {
        label => 'Events',
        module_key => 'events',
        payment_key => 'event_payments',
        disabled_label => 'Events disabled',
        disabled_summary => 'Enable Events before taking RSVPs or tickets.',
        locked_label => 'Payments locked',
        locked_summary => 'Calendar pages and RSVP are available; paid tickets require Event Payments.',
        model_disabled_label => 'Payments disabled',
        model_disabled_summary => 'Select a checkout-capable commerce model before selling tickets.',
        stripe_summary => 'Paid tickets need both a Stripe secret key and webhook secret.',
        marketplace_stripe_summary => 'Marketplace ticketing needs inherited master Stripe credentials and webhook secret.',
        connect_summary => 'Connect a Stripe payout account before this site can sell tickets.',
        ready_summary => 'Event ticket checkout is ready.',
        ready_marketplace_summary => 'Event ticket checkout is ready for platform marketplace payouts.',
    },
    bookings => {
        label => 'Bookings / Appointments',
        module_key => 'bookings',
        payment_key => 'booking_payments',
        disabled_label => 'Bookings disabled',
        disabled_summary => 'Enable Bookings before accepting appointment requests or deposits.',
        locked_label => 'Deposits locked',
        locked_summary => 'Booking requests are available; Stripe deposits require Booking Deposits.',
        model_disabled_label => 'Deposits disabled',
        model_disabled_summary => 'Select a checkout-capable commerce model before taking deposits.',
        stripe_summary => 'Booking deposits need both a Stripe secret key and webhook secret.',
        marketplace_stripe_summary => 'Marketplace booking deposits need inherited master Stripe credentials and webhook secret.',
        connect_summary => 'Connect a Stripe payout account before this site can take booking deposits.',
        ready_summary => 'Booking deposit checkout is ready.',
        ready_marketplace_summary => 'Booking deposit checkout is ready for platform marketplace payouts.',
    },
    membership => {
        label => 'Membership / Gated Content',
        module_key => 'membership',
        payment_key => 'membership_payments',
        disabled_label => 'Membership disabled',
        disabled_summary => 'Enable Membership before configuring paid member access.',
        locked_label => 'Payments locked',
        locked_summary => 'Member accounts and gated resources are available; paid access requires Membership Payments.',
        model_disabled_label => 'Payments disabled',
        model_disabled_summary => 'Choose a Stripe commerce model before paid member access can be used.',
        stripe_summary => 'Configure Stripe key and webhook secret before paid member access can be used.',
        marketplace_stripe_summary => 'Marketplace paid member access needs inherited master Stripe credentials and webhook secret.',
        connect_summary => 'Contributor marketplace paid access needs an active Stripe connected account.',
        ready_summary => 'Membership Payments can create paid member-resource or subscription records.',
        ready_marketplace_summary => 'Membership Payments are ready for platform marketplace payouts.',
    },
    donations => {
        label => 'Donations / Fundraising',
        module_key => 'donations',
        payment_key => 'donation_payments',
        disabled_label => 'Donations disabled',
        disabled_summary => 'Enable Donations before accepting public contributions.',
        locked_label => 'Payments locked',
        locked_summary => 'Campaign pages are available; Stripe donation checkout requires Donation Payments.',
        model_disabled_label => 'Payments disabled',
        model_disabled_summary => 'Choose a checkout-capable commerce model before taking donations.',
        stripe_summary => 'Donations need both a Stripe secret key and webhook secret.',
        marketplace_stripe_summary => 'Marketplace donations need inherited master Stripe credentials and webhook secret.',
        connect_summary => 'Connect a Stripe payout account before this site can take donations.',
        ready_summary => 'Donation checkout is ready.',
        ready_marketplace_summary => 'Donation checkout is ready for platform marketplace payouts.',
    },
);

my @WORKFLOW_ORDER = qw(shop events bookings membership donations);

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
    return payment_allowed_by_plan($settings || {}, 'shop') ? 1 : 0;
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

    my $base = payment_readiness($config, $settings, workflow => 'shop');
    my $selected = $base->{model};
    my $model_label = label($selected);
    my $shop_enabled = shop_config_enabled($settings);
    my $catalog_enabled = catalog_enabled($settings);

    my @checks = (
        {
            key    => 'model',
            title  => 'Commerce model',
            state  => $base->{state},
            label  => $base->{label},
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
            state  => $base->{checkout_allowed} ? ($base->{model_allows_checkout} ? 'ok' : 'neutral') : 'warn',
            label  => $base->{checkout_allowed} ? ($base->{model_allows_checkout} ? 'Allowed' : 'Not selected') : 'Locked',
            detail => $base->{checkout_allowed}
                ? ($base->{model_allows_checkout} ? 'This plan can show Stripe checkout when payment settings are ready.' : 'Select a checkout-capable commerce model before taking payments.')
                : 'Upgrade the plan before showing buy buttons or creating Checkout Sessions.',
        },
        {
            key    => 'stripe_key',
            title  => 'Stripe API',
            state  => $base->{allows_checkout} ? ($base->{stripe_key} ? 'ok' : 'warn') : 'neutral',
            label  => $base->{stripe_key} ? 'Configured' : 'Missing',
            detail => $base->{allows_checkout}
                ? ($base->{marketplace} ? 'Inherited from the master CMS for platform Checkout.' : 'Required for creating Checkout Sessions.')
                : 'Not used unless checkout is selected.',
        },
        {
            key    => 'stripe_webhook',
            title  => 'Stripe webhook',
            state  => $base->{allows_checkout} ? ($base->{webhook} ? 'ok' : 'warn') : 'neutral',
            label  => $base->{webhook} ? 'Configured' : 'Missing',
            detail => $base->{allows_checkout}
                ? ($base->{marketplace} ? 'Inherited from the master CMS for payment fulfillment.' : 'Required for reliable payment fulfillment.')
                : 'Not used unless checkout is selected.',
        },
        {
            key    => 'stripe_connect',
            title  => 'Marketplace payouts',
            state  => $base->{marketplace} ? ($base->{connect_account} ? 'ok' : 'warn') : 'neutral',
            label  => $base->{marketplace} ? ($base->{connect_account} ? 'Connected' : 'Needs onboarding') : 'Not used',
            detail => $base->{marketplace}
                ? 'Destination charges transfer proceeds to this contributor account while the platform keeps its fee.'
                : 'The selected model uses one direct Stripe account for the site.',
        },
    );

    return {
        %{$base},
        model_label      => $model_label,
        shop_enabled     => $shop_enabled,
        catalog_enabled  => $catalog_enabled,
        checks           => \@checks,
    };
}

sub payment_allowed_by_plan {
    my ($settings, $workflow) = @_;
    my $def = _workflow_def($workflow);
    return _plan_feature_enabled($settings || {}, $def->{payment_key}, 1) ? 1 : 0;
}

sub payment_model {
    my ($config, $settings, %args) = @_;
    $settings ||= {};
    my $def = _workflow_def($args{workflow});
    my $explicit = normalize_model(_setting($settings, 'commerce_model', $config ? $config->get('commerce_model') : ''));
    return $explicit if length $explicit;
    return 'disabled' unless payment_allowed_by_plan($settings, $def->{key});
    if (is_contributor_instance($config)) {
        return _truthy(_setting($settings, 'contributor_allow_stripe_connect', 0))
            ? 'platform_marketplace'
            : 'disabled';
    }
    return 'master_owned';
}

sub payment_readiness {
    my ($config, $settings, %args) = @_;
    $settings ||= {};
    my $def = _workflow_def($args{workflow});
    my $workflow = $def->{key};
    my $module_enabled = $workflow eq 'shop'
        ? shop_config_enabled($settings)
        : (DesertCMS::Modules::enabled($settings, $def->{module_key}) ? 1 : 0);
    my $allowed = payment_allowed_by_plan($settings, $workflow);
    my $selected = payment_model($config, $settings, workflow => $workflow);
    my $model_allows = model_allows_checkout($selected);
    my $marketplace = $selected eq 'platform_marketplace' ? 1 : 0;
    my $stripe_key = length(_setting($settings, 'stripe_secret_key', '') || '') ? 1 : 0;
    my $webhook = length(_setting($settings, 'stripe_webhook_secret', '') || '') ? 1 : 0;
    my $connect_account = length(_setting($settings, 'stripe_connect_account_id', '') || '') ? 1 : 0;
    my $connect_allowed = $allowed && _truthy(_setting($settings, 'contributor_allow_stripe_connect', 0)) ? 1 : 0;
    my $stripe_ready = $stripe_key && $webhook ? 1 : 0;
    my $allows_checkout = $allowed && $model_allows ? 1 : 0;

    my ($state, $status, $summary) = ('neutral', 'Disabled', $def->{model_disabled_summary});
    if (!$module_enabled) {
        ($state, $status, $summary) = ('neutral', $def->{disabled_label}, $def->{disabled_summary});
    } elsif (!$allowed) {
        ($state, $status, $summary) = ('warn', $def->{locked_label}, $def->{locked_summary});
    } elsif ($selected eq 'marketplace_pending') {
        ($state, $status, $summary) = ('warn', 'Connect needed', 'Marketplace commission payouts need Stripe Connect before checkout should be enabled.');
    } elsif (!$model_allows || $selected eq 'disabled') {
        ($state, $status, $summary) = ('neutral', $def->{model_disabled_label}, $def->{model_disabled_summary});
    } elsif ($marketplace && !$connect_allowed) {
        ($state, $status, $summary) = ('warn', 'Plan locked', 'This plan does not include contributor payout setup.');
    } elsif (!$stripe_ready) {
        ($state, $status, $summary) = ('warn', 'Needs Stripe', $marketplace ? $def->{marketplace_stripe_summary} : $def->{stripe_summary});
    } elsif ($marketplace && !$connect_account) {
        ($state, $status, $summary) = ('warn', 'Connect payouts', $def->{connect_summary});
    } else {
        ($state, $status, $summary) = ('ok', 'Ready', $marketplace ? $def->{ready_marketplace_summary} : $def->{ready_summary});
    }

    return {
        workflow              => $workflow,
        workflow_label        => $def->{label},
        state                 => $state,
        label                 => $status,
        summary               => $summary,
        model                 => $selected,
        model_label           => label($selected),
        payment_model         => $selected,
        module_enabled        => $module_enabled ? 1 : 0,
        checkout_allowed      => $allowed ? 1 : 0,
        allowed_by_plan       => $allowed ? 1 : 0,
        model_allows_checkout => $model_allows ? 1 : 0,
        allows_checkout       => $allows_checkout ? 1 : 0,
        checkout_enabled      => ($module_enabled && $allows_checkout && $stripe_ready && (!$marketplace || $connect_account)) ? 1 : 0,
        stripe_ready          => $stripe_ready ? 1 : 0,
        stripe_key            => $stripe_key ? 1 : 0,
        webhook               => $webhook ? 1 : 0,
        marketplace           => $marketplace ? 1 : 0,
        connect_account       => $connect_account ? 1 : 0,
        connect_allowed       => $connect_allowed ? 1 : 0,
        actions               => [
            { label => 'Payment settings', href => '/admin/settings/payments' },
            { label => $def->{label} . ' setup', href => '/admin/settings/modules/' . ($def->{module_key} eq 'shop' ? 'shop' : $def->{module_key}) },
        ],
    };
}

sub payment_hub_readiness {
    my ($config, $settings) = @_;
    $settings ||= {};
    my @flows = map { payment_readiness($config, $settings, workflow => $_) } @WORKFLOW_ORDER;
    my @active = grep { $_->{module_enabled} } @flows;
    my @warn = grep { ($_->{state} || '') eq 'warn' } @active;
    my @ready = grep { $_->{checkout_enabled} } @active;
    my ($state, $label, $summary);
    if (@warn) {
        ($state, $label, $summary) = ('warn', 'Needs setup', scalar(@warn) . ' payment workflow(s) need Stripe, plan, or Connect setup.');
    } elsif (@ready) {
        ($state, $label, $summary) = ('ok', 'Ready', scalar(@ready) . ' payment workflow(s) are ready for Stripe Checkout.');
    } elsif (@active) {
        ($state, $label, $summary) = ('neutral', 'No checkout ready', 'Paid module workflows are enabled, but checkout is disabled or not selected.');
    } else {
        ($state, $label, $summary) = ('neutral', 'No paid modules', 'No Stripe-powered module workflow is currently active.');
    }
    return {
        state   => $state,
        label   => $label,
        summary => $summary,
        checks  => [
            map {
                {
                    key    => $_->{workflow},
                    title  => $_->{workflow_label},
                    state  => $_->{state},
                    label  => $_->{label},
                    detail => $_->{summary},
                }
            } @flows
        ],
        workflows => \@flows,
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

sub _workflow_def {
    my ($workflow) = @_;
    $workflow = lc($workflow || 'shop');
    $workflow =~ s/[-\s]+/_/g;
    $workflow = 'events' if $workflow eq 'event';
    $workflow = 'bookings' if $workflow eq 'booking';
    $workflow = 'donations' if $workflow eq 'donation';
    my $def = $WORKFLOWS{$workflow} || $WORKFLOWS{shop};
    return { %{$def}, key => $workflow };
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
