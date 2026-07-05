use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Commerce;
use DesertCMS::Config;
use DesertCMS::Modules;
use DesertCMS::Settings;

my $master_config = bless {
    commerce_model       => '',
    contributor_site_id  => '',
    contributor_domain   => '',
}, 'DesertCMS::Config';

my $contributor_config = bless {
    commerce_model       => '',
    contributor_site_id  => 'alexs',
    contributor_domain   => 'alexs.example.com',
}, 'DesertCMS::Config';

is(
    DesertCMS::Commerce::model($master_config, { module_shop_enabled => 1, shop_enabled => 1 }),
    'master_owned',
    'shop-enabled master defaults to master-owned commerce'
);
is(
    DesertCMS::Commerce::model($contributor_config, { module_shop_enabled => 1, shop_enabled => 1 }),
    'disabled',
    'shop-enabled contributor defaults commerce off until the plan allows platform payouts'
);
is(
    DesertCMS::Commerce::model($contributor_config, { module_shop_enabled => 1, shop_enabled => 1, contributor_allow_stripe_connect => 1 }),
    'platform_marketplace',
    'plan-entitled contributor defaults to platform marketplace commerce'
);
is(
    DesertCMS::Commerce::model($master_config, { module_shop_enabled => 0, shop_enabled => 1 }),
    'disabled',
    'disabled Shop module defaults commerce off'
);
is(
    DesertCMS::Commerce::model($master_config, { module_shop_enabled => 1, shop_enabled => 1, commerce_model => 'marketplace-pending' }),
    'marketplace_pending',
    'model names normalize dashes to underscores'
);
is(
    DesertCMS::Commerce::model($master_config, { module_shop_enabled => 1, shop_enabled => 1, commerce_model => 'not-real' }),
    'master_owned',
    'invalid model falls back to the derived model'
);

ok(
    DesertCMS::Commerce::checkout_enabled($master_config, {
        module_shop_enabled     => 1,
        shop_enabled            => 1,
        commerce_model          => 'master_owned',
        stripe_secret_key       => 'sk_test_desert',
        stripe_webhook_secret   => 'whsec_desert',
    }),
    'master-owned direct checkout can be enabled'
);
ok(
    !DesertCMS::Commerce::checkout_enabled($master_config, {
        module_shop_enabled     => 1,
        shop_enabled            => 1,
        commerce_model          => 'marketplace_pending',
        stripe_secret_key       => 'sk_test_desert',
        stripe_webhook_secret   => 'whsec_desert',
    }),
    'marketplace planning does not allow direct checkout'
);
ok(
    DesertCMS::Commerce::checkout_enabled($contributor_config, {
        module_shop_enabled     => 1,
        shop_enabled            => 1,
        commerce_model          => 'platform_marketplace',
        contributor_allow_stripe_connect => 1,
        stripe_secret_key       => 'sk_test_desert',
        stripe_webhook_secret   => 'whsec_desert',
        stripe_connect_account_id => 'acct_seller123',
    }),
    'platform marketplace checkout can be enabled for connected contributors'
);
ok(
    !DesertCMS::Commerce::checkout_enabled($master_config, {
        module_shop_enabled     => 1,
        shop_enabled            => 1,
        commerce_model          => 'disabled',
    }),
    'disabled model does not allow direct checkout'
);
my $catalog_only_features = DesertCMS::Modules::features_json({
    shop => 1,
    shop_payments => 0,
});
ok(
    DesertCMS::Commerce::catalog_enabled({
        module_shop_enabled => 1,
        shop_enabled => 1,
        contributor_plan_features_json => $catalog_only_features,
    }),
    'catalog-only plan can enable public catalog'
);
ok(
    !DesertCMS::Commerce::checkout_allowed_by_plan({
        module_shop_enabled => 1,
        shop_enabled => 1,
        contributor_plan_features_json => $catalog_only_features,
    }),
    'catalog-only plan does not allow checkout by plan'
);
ok(
    !DesertCMS::Commerce::checkout_enabled($contributor_config, {
        module_shop_enabled => 1,
        shop_enabled => 1,
        commerce_model => 'platform_marketplace',
        contributor_allow_stripe_connect => 1,
        contributor_plan_features_json => $catalog_only_features,
    }),
    'catalog-only plan blocks checkout even when old marketplace settings remain'
);

my $ready = DesertCMS::Commerce::readiness($master_config, {
    module_shop_enabled     => 1,
    shop_enabled            => 1,
    commerce_model          => 'master_owned',
    stripe_secret_key       => 'sk_test_desert',
    stripe_webhook_secret   => 'whsec_desert',
});
is($ready->{state}, 'ok', 'complete master-owned setup is ready');
ok($ready->{checkout_enabled}, 'readiness marks direct checkout enabled');

my $marketplace = DesertCMS::Commerce::readiness($master_config, {
    module_shop_enabled     => 1,
    shop_enabled            => 1,
    commerce_model          => 'marketplace_pending',
    stripe_secret_key       => 'sk_test_desert',
    stripe_webhook_secret   => 'whsec_desert',
});
is($marketplace->{state}, 'warn', 'marketplace planning needs Stripe Connect');
ok(!$marketplace->{checkout_enabled}, 'marketplace planning keeps direct checkout off');
like($marketplace->{summary}, qr/Stripe Connect/, 'marketplace summary names Stripe Connect');

my $platform_marketplace = DesertCMS::Commerce::readiness($contributor_config, {
    module_shop_enabled     => 1,
    shop_enabled            => 1,
    commerce_model          => 'platform_marketplace',
    contributor_allow_stripe_connect => 1,
    stripe_secret_key       => 'sk_test_desert',
    stripe_webhook_secret   => 'whsec_desert',
    stripe_connect_account_id => 'acct_seller123',
});
is($platform_marketplace->{state}, 'ok', 'connected platform marketplace setup is ready');
ok($platform_marketplace->{checkout_enabled}, 'readiness marks platform marketplace checkout enabled');

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
my $legacy_contributor_conf = "$root/legacy-contributor.conf";
open my $fh, '>', $legacy_contributor_conf or die "cannot write $legacy_contributor_conf: $!";
print {$fh} <<"CONF";
site_name = Legacy Contributor
site_url = https://alexs.example.com
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $root/themes
admin_asset_dir = $root/admin-assets
contributor_site_id = alexs
contributor_domain = alexs.example.com
CONF
close $fh;
my $legacy_config = DesertCMS::Config->load($legacy_contributor_conf);
my $legacy_settings = DesertCMS::Settings::all($legacy_config, undef);
is($legacy_settings->{shop_enabled}, 0, 'legacy contributor config without shop keys defaults shop off');
is($legacy_settings->{commerce_model}, 'disabled', 'legacy contributor config without shop keys defaults commerce off');

done_testing;
