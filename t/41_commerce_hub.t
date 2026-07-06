use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Commerce qw(payment_hub_readiness payment_readiness);

{
    package Local::CommerceConfig;

    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }

    sub get {
        my ($self, $key) = @_;
        return $self->{$key};
    }
}

my $master_config = Local::CommerceConfig->new();
my $contributor_config = Local::CommerceConfig->new(
    contributor_site_id => 'desert-tenant',
    contributor_domain  => 'desert-tenant.example.test',
);

my %workflow_defs = (
    shop => {
        module_settings => {
            module_shop_enabled => 1,
            shop_enabled        => 1,
        },
        module_feature  => 'shop',
        payment_feature => 'shop_payments',
        disabled_label  => 'Shop disabled',
        locked_label    => 'Payments locked',
        model_label     => 'Payments disabled',
    },
    events => {
        module_settings => { module_events_enabled => 1 },
        module_feature  => 'events',
        payment_feature => 'event_payments',
        disabled_label  => 'Events disabled',
        locked_label    => 'Payments locked',
        model_label     => 'Payments disabled',
    },
    bookings => {
        module_settings => { module_bookings_enabled => 1 },
        module_feature  => 'bookings',
        payment_feature => 'booking_payments',
        disabled_label  => 'Bookings disabled',
        locked_label    => 'Deposits locked',
        model_label     => 'Deposits disabled',
    },
    membership => {
        module_settings => { module_membership_enabled => 1 },
        module_feature  => 'membership',
        payment_feature => 'membership_payments',
        disabled_label  => 'Membership disabled',
        locked_label    => 'Payments locked',
        model_label     => 'Payments disabled',
    },
    donations => {
        module_settings => { module_donations_enabled => 1 },
        module_feature  => 'donations',
        payment_feature => 'donation_payments',
        disabled_label  => 'Donations disabled',
        locked_label    => 'Payments locked',
        model_label     => 'Payments disabled',
    },
);

for my $workflow (qw(shop events bookings membership donations)) {
    my $def = $workflow_defs{$workflow};
    my %enabled = %{ $def->{module_settings} };

    my $disabled = payment_readiness($master_config, {}, workflow => $workflow);
    ok(!$disabled->{module_enabled}, "$workflow stays disabled until its module is enabled");
    is($disabled->{label}, $def->{disabled_label}, "$workflow reports the correct disabled label");
    ok(!$disabled->{checkout_enabled}, "$workflow disabled state keeps checkout off");

    my $locked = payment_readiness($master_config, {
        %enabled,
        contributor_plan_features_json => encode_json({
            $def->{module_feature}  => 1,
            $def->{payment_feature} => 0,
        }),
    }, workflow => $workflow);
    ok($locked->{module_enabled}, "$workflow module can be enabled independently");
    ok(!$locked->{allowed_by_plan}, "$workflow respects the plan payment entitlement");
    is($locked->{label}, $def->{locked_label}, "$workflow reports the correct locked label");
    ok(!$locked->{checkout_enabled}, "$workflow locked state keeps checkout off");

    my $model_disabled = payment_readiness($master_config, {
        %enabled,
        commerce_model => 'disabled',
    }, workflow => $workflow);
    ok($model_disabled->{allowed_by_plan}, "$workflow still allows payments by plan when checkout model is disabled");
    ok(!$model_disabled->{model_allows_checkout}, "$workflow disabled commerce model does not allow checkout");
    is($model_disabled->{label}, $def->{model_label}, "$workflow reports the correct disabled-model label");
    ok(!$model_disabled->{checkout_enabled}, "$workflow disabled model keeps checkout off");

    my $missing_key = payment_readiness($master_config, {
        %enabled,
        commerce_model         => 'master_owned',
        stripe_webhook_secret  => 'whsec_test',
    }, workflow => $workflow);
    is($missing_key->{label}, 'Needs Stripe', "$workflow requires a Stripe key before checkout is ready");
    ok(!$missing_key->{stripe_key}, "$workflow detects missing Stripe key");
    ok($missing_key->{webhook}, "$workflow sees the configured webhook secret");
    ok(!$missing_key->{checkout_enabled}, "$workflow missing Stripe key keeps checkout off");

    my $missing_webhook = payment_readiness($master_config, {
        %enabled,
        commerce_model    => 'master_owned',
        stripe_secret_key => 'sk_test_ready',
    }, workflow => $workflow);
    is($missing_webhook->{label}, 'Needs Stripe', "$workflow requires a Stripe webhook before checkout is ready");
    ok($missing_webhook->{stripe_key}, "$workflow sees the configured Stripe key");
    ok(!$missing_webhook->{webhook}, "$workflow detects missing Stripe webhook secret");
    ok(!$missing_webhook->{checkout_enabled}, "$workflow missing webhook keeps checkout off");

    my $ready_direct = payment_readiness($master_config, {
        %enabled,
        commerce_model         => 'master_owned',
        stripe_secret_key      => 'sk_test_ready',
        stripe_webhook_secret  => 'whsec_ready',
    }, workflow => $workflow);
    is($ready_direct->{label}, 'Ready', "$workflow direct checkout reaches the ready state");
    ok($ready_direct->{checkout_enabled}, "$workflow direct checkout becomes available when Stripe is ready");
    ok($ready_direct->{stripe_ready}, "$workflow direct checkout records Stripe readiness");

    my $missing_connect = payment_readiness($contributor_config, {
        %enabled,
        commerce_model                  => 'platform_marketplace',
        contributor_allow_stripe_connect => 1,
        stripe_secret_key               => 'sk_test_ready',
        stripe_webhook_secret           => 'whsec_ready',
    }, workflow => $workflow);
    is($missing_connect->{label}, 'Connect payouts', "$workflow contributor marketplace checkout requires a connected payout account");
    ok($missing_connect->{marketplace}, "$workflow marketplace state is marked as marketplace");
    ok(!$missing_connect->{connect_account}, "$workflow detects the missing connected payout account");
    ok(!$missing_connect->{checkout_enabled}, "$workflow missing connected payout account keeps checkout off");

    my $ready_marketplace = payment_readiness($contributor_config, {
        %enabled,
        commerce_model                  => 'platform_marketplace',
        contributor_allow_stripe_connect => 1,
        stripe_secret_key               => 'sk_test_ready',
        stripe_webhook_secret           => 'whsec_ready',
        stripe_connect_account_id       => 'acct_test_ready',
    }, workflow => $workflow);
    is($ready_marketplace->{label}, 'Ready', "$workflow contributor marketplace checkout reaches the ready state");
    ok($ready_marketplace->{connect_account}, "$workflow contributor marketplace checkout records the connected payout account");
    ok($ready_marketplace->{checkout_enabled}, "$workflow contributor marketplace checkout becomes available when Stripe and Connect are ready");
}

my $empty_hub = payment_hub_readiness($master_config, {});
is($empty_hub->{label}, 'No paid modules', 'payment hub stays neutral when no payment module is active');
is_deeply(
    [ map { $_->{workflow} } @{ $empty_hub->{workflows} || [] } ],
    [qw(shop events bookings membership donations)],
    'payment hub reports all tracked workflows in a stable order'
);

my $warn_hub = payment_hub_readiness($master_config, {
    module_donations_enabled => 1,
    commerce_model           => 'master_owned',
});
is($warn_hub->{label}, 'Needs setup', 'payment hub reports setup work when a module can take payments but Stripe is incomplete');
like($warn_hub->{summary}, qr/payment workflow\(s\) need Stripe, plan, or Connect setup/, 'payment hub warning summary names setup work');

my $ready_hub = payment_hub_readiness($master_config, {
    module_events_enabled    => 1,
    module_donations_enabled => 1,
    commerce_model           => 'master_owned',
    stripe_secret_key        => 'sk_test_ready',
    stripe_webhook_secret    => 'whsec_ready',
});
is($ready_hub->{label}, 'Ready', 'payment hub reports ready when active workflows have complete Stripe setup');
like($ready_hub->{summary}, qr/2 payment workflow\(s\) are ready for Stripe Checkout\./, 'payment hub summary counts ready workflows');

done_testing;
