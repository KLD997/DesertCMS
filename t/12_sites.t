use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Blueprints;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Modules;
use DesertCMS::ServicePlans;
use DesertCMS::Settings;
use DesertCMS::Sites;

{
    package Local::StripeConnectHTTP;

    sub new {
        my ($class) = @_;
        return bless { posts => [], gets => [] }, $class;
    }

    sub post {
        my ($self, $url, $args) = @_;
        push @{$self->{posts}}, { url => $url, args => $args };
        if ($url =~ m{/v1/accounts\z}) {
            return {
                success => 1,
                content => JSON::PP::encode_json({
                    id => 'acct_kaleb123',
                    charges_enabled => 0,
                    payouts_enabled => 0,
                }),
            };
        }
        if ($url =~ m{/v1/account_links\z}) {
            return {
                success => 1,
                content => JSON::PP::encode_json({
                    url => 'https://connect.stripe.com/setup/c/acct_kaleb123/link',
                }),
            };
        }
        die "unexpected Stripe URL $url";
    }

    sub get {
        my ($self, $url, $args) = @_;
        push @{$self->{gets}}, { url => $url, args => $args };
        if ($url =~ m{/v1/accounts/acct_kaleb123\z}) {
            return {
                success => 1,
                content => JSON::PP::encode_json({
                    id => 'acct_kaleb123',
                    charges_enabled => 1,
                    payouts_enabled => 1,
                    details_submitted => 1,
                    requirements => {},
                }),
            };
        }
        die "unexpected Stripe GET URL $url";
    }
}

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/themes", "$root/admin-assets", "$root/data");
make_path("$root/kaleb-data/backups", "$root/kaleb-public", "$root/kaleb-originals", "$root/kaleb-themes", "$root/kaleb-admin-assets");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Contributor Test
site_url = https://desertarchives.com
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $root/themes
admin_asset_dir = $root/admin-assets
secure_cookies = 0
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

DesertCMS::Settings::set_many($config, $db, {
    contributor_domain_root => 'desertarchives.com',
    contributor_request_recipient_email => 'support@desertarchives.com',
    stripe_secret_key => 'sk_test_platform',
    stripe_webhook_secret => 'whsec_platform',
});

my $sites = DesertCMS::Sites->new(config => $config, db => $db);
my $blueprints = DesertCMS::Blueprints->new(config => $config, db => $db);
my $service_plans = DesertCMS::ServicePlans->new(config => $config, db => $db);
my $default_blueprint = $blueprints->default_blueprint;
ok($default_blueprint->{id}, 'default contributor blueprint is created on demand');
is($default_blueprint->{is_default}, 1, 'default contributor blueprint is marked default');
is($default_blueprint->{category}, 'photographer', 'default contributor blueprint uses photographer vertical');
is($default_blueprint->{name}, 'Photographer Portfolio', 'default contributor blueprint uses vertical product language');
my %seeded_verticals = map { ($_->{category} || '') => 1 } @{$blueprints->list};
for my $vertical (qw(photographer artist-portfolio writer-blog small-business local-archive event-community-site shop-catalog documentation-resource-hub)) {
    ok($seeded_verticals{$vertical}, "seeded blueprint catalog includes $vertical vertical");
}
is(DesertCMS::Blueprints::vertical_label('documentation-resource-hub'), 'Docs / Resource Hub', 'blueprint vertical labels are available to admin UI');
make_path("$root/legacy-data", "$root/legacy-public", "$root/legacy-originals", "$root/legacy-backups", "$root/legacy-themes", "$root/legacy-admin-assets");
_write("$root/legacy.conf", <<"CONF");
site_name = Legacy Blueprint Test
site_url = https://legacy.desertarchives.com
data_dir = $root/legacy-data
db_path = $root/legacy-data/desertcms.sqlite
app_secret_file = $root/legacy-data/app_secret
public_root = $root/legacy-public
originals_dir = $root/legacy-originals
backup_dir = $root/legacy-backups
theme_dir = $root/legacy-themes
admin_asset_dir = $root/legacy-admin-assets
secure_cookies = 0
CONF
my $legacy_config = DesertCMS::Config->load("$root/legacy.conf");
my $legacy_db = DesertCMS::DB->new(config => $legacy_config);
$legacy_db->migrate;
my $legacy_ts = time;
$legacy_db->dbh->do(
    q{
        INSERT INTO contributor_blueprints
            (name, slug, description, category,
             module_map_enabled, module_shop_enabled, module_gallery_enabled,
             module_forms_enabled, module_contributor_requests_enabled, module_docs_enabled,
             theme_default_mode, theme_light_preset, theme_dark_preset,
             shop_enabled, media_quota_mb, post_quota, page_quota, features_json,
             allow_master_gallery, allow_master_posts,
             site_meta_title, site_meta_description, default_pages_json,
             is_default, created_at, updated_at)
        VALUES
            ('Standard Contributor', 'standard-contributor',
             'Default contributor subCMS profile with gallery and master surfacing enabled.',
             'photographer', 1, 0, 1, 0, 0, 0, 'light', 'light-archive', 'dark-archive',
             0, 512, 100, 20, '{}', 1, 1, '', '',
             '[{"title":"About","slug":"about","show_in_nav":1},{"title":"Contact","slug":"contact","show_in_nav":1}]',
             1, ?, ?)
    },
    undef,
    $legacy_ts,
    $legacy_ts
);
my $legacy_blueprints = DesertCMS::Blueprints->new(config => $legacy_config, db => $legacy_db);
my $legacy_default = $legacy_blueprints->default_blueprint;
is($legacy_default->{slug}, 'photographer-portfolio', 'legacy Standard Contributor seed migrates to photographer blueprint slug');
is($legacy_default->{name}, 'Photographer Portfolio', 'legacy Standard Contributor seed migrates to vertical product name');
my @legacy_photographer_rows = grep { ($_->{slug} || '') eq 'photographer-portfolio' } @{$legacy_blueprints->list};
is(scalar @legacy_photographer_rows, 1, 'legacy migration does not duplicate photographer blueprint');
my $default_plan = $service_plans->default_plan;
ok($default_plan->{id}, 'default service plan is created on demand');
is($default_plan->{is_default}, 1, 'default service plan is marked default');
is($default_plan->{name}, 'Free Tier', 'default service plan uses free-tier product language');
my $limited_blueprint = $blueprints->save(
    name => 'Limited Showcase Contributor',
    slug => 'limited-showcase-contributor',
    category => 'local-archive',
    description => 'Tighter contributor profile for invite tests.',
    module_map_enabled => 1,
    module_gallery_enabled => 1,
    module_shop_enabled => 0,
    media_quota_mb => 128,
    post_quota => 12,
    page_quota => 4,
    allow_master_gallery => 0,
    allow_master_posts => 1,
    theme_default_mode => 'dark',
    theme_light_preset => 'light-coast',
    theme_dark_preset => 'dark-forest',
    site_meta_title => 'Contributor Default',
    site_meta_description => 'Contributor default SEO description.',
    default_pages_text => "Portfolio|portfolio|nav\nContact|contact|hidden",
);
is($limited_blueprint->{media_quota_mb}, 128, 'custom blueprint saves media quota');
is($limited_blueprint->{category}, 'local-archive', 'custom blueprint saves vertical category');
my $limited_plan = $service_plans->save(
    name => 'Studio Plan',
    slug => 'studio-plan',
    description => 'Paid studio contributor service plan.',
    blueprint_id => $limited_blueprint->{id},
    monthly_price_dollars => '29.00',
    currency => 'usd',
    stripe_price_id => 'price_studio123',
    media_quota_mb => 256,
    media_upload_limit_mb => 96,
    post_quota => 24,
    page_quota => 8,
    feature_shop_included => 1,
    feature_shop_payments_included => 1,
    feature_forms_included => 1,
    feature_docs_included => 0,
    feature_resource_publishing_included => 1,
    allow_master_gallery => 1,
    allow_master_posts => 1,
    allow_postmark_sender_override => 1,
    allow_stripe_connect => 1,
    allow_indexing_override => 1,
    stripe_platform_fee_percent => '12.50',
);
is($limited_plan->{monthly_price_cents}, 2900, 'custom service plan saves monthly price');
is($limited_plan->{stripe_price_id}, 'price_studio123', 'custom service plan saves Stripe Price ID');
is($limited_plan->{media_upload_limit_mb}, 96, 'custom service plan saves media upload limit');
is($limited_plan->{allow_postmark_sender_override}, 1, 'custom service plan saves Postmark sender override entitlement');
is($limited_plan->{allow_stripe_connect}, 1, 'custom service plan saves Stripe Connect entitlement');
is($limited_plan->{allow_indexing_override}, 1, 'custom service plan saves indexing override entitlement');
is($limited_plan->{stripe_platform_fee_bps}, 1250, 'custom service plan saves platform fee basis points');
my $limited_plan_features = DesertCMS::Modules::feature_map_for_plan($limited_plan);
ok($limited_plan_features->{forms}, 'custom service plan saves included feature entitlement');
ok($limited_plan_features->{shop}, 'custom service plan saves Shop / Catalog entitlement');
ok($limited_plan_features->{shop_payments}, 'custom service plan saves Shop Payments entitlement');
ok(!$limited_plan_features->{docs}, 'custom service plan saves locked feature entitlement');
ok($limited_plan_features->{resource_publishing}, 'custom service plan saves Resource Downloads entitlement');
_write("$root/kaleb.conf", <<"CONF");
site_name = Kaleb
site_url = https://kaleb.desertarchives.com
data_dir = $root/kaleb-data
db_path = $root/kaleb-data/desertcms.sqlite
app_secret_file = $root/kaleb-data/app_secret
public_root = $root/kaleb-public
originals_dir = $root/kaleb-originals
backup_dir = $root/kaleb-data/backups
theme_dir = $root/kaleb-themes
admin_asset_dir = $root/kaleb-admin-assets
secure_cookies = 0
contributor_site_id = kaleb
contributor_domain = kaleb.desertarchives.com
master_config_path = $config_path
CONF
my $kaleb_config = DesertCMS::Config->load("$root/kaleb.conf");
my $kaleb_db = DesertCMS::DB->new(config => $kaleb_config);
$kaleb_db->migrate;
my $usage_ts = time;
$kaleb_db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, mime_type, width, height, bytes, checksum_sha256, created_at)
        VALUES
            ('usage.jpg', ?, '/assets/media/usage.jpg', 'image/jpeg', 100, 100, 1048576, ?, ?)
    },
    undef,
    "$root/kaleb-originals/usage.jpg",
    'a' x 64,
    $usage_ts
);
$kaleb_db->dbh->do(
    q{
        INSERT INTO content_items
            (type, title, slug, status, body_json, published_html, created_at, updated_at, published_at)
        VALUES
            ('post', 'Usage Post', 'usage-post', 'published', '[]', '<p>Post</p>', ?, ?, ?),
            ('page', 'Usage Page', 'usage-page', 'published', '[]', '<p>Page</p>', ?, ?, ?)
    },
    undef,
    ($usage_ts) x 6
);
_write("$root/kaleb-public/index.html", "<!doctype html><title>Kaleb</title>\n");
_write("$root/kaleb-data/backups/desertcms-20260629.tar.gz", "backup\n");
$sites->register_existing_site(
    site_id      => 'kaleb',
    domain       => 'kaleb.desertarchives.com',
    display_name => 'Kaleb Desert Archives',
    config_path  => "$root/kaleb.conf",
    data_dir     => "$root/kaleb-data",
    public_root  => "$root/kaleb-public",
);
my $assigned_kaleb = $service_plans->assign_site(
    site_id => 'kaleb',
    plan_id => $limited_plan->{id},
    billing_status => 'active',
    billing_email => 'billing@example.com',
    stripe_customer_id => 'cus_test123',
    stripe_subscription_id => 'sub_test123',
);
is($assigned_kaleb->{service_plan_id}, $limited_plan->{id}, 'service plan can be assigned to contributor site');
is($assigned_kaleb->{billing_status}, 'active', 'assigned service plan stores billing status');
is($assigned_kaleb->{media_quota_mb}, 256, 'assigned service plan copies media quota to site');
is($assigned_kaleb->{media_upload_limit_mb}, 96, 'assigned service plan copies upload limit to site');
is($assigned_kaleb->{allow_master_gallery}, 1, 'assigned service plan copies platform Showcase eligibility');
is($assigned_kaleb->{plan_sync}{synced}, 1, 'service plan assignment syncs contributor settings');
my $kaleb_settings = DesertCMS::Settings::all($kaleb_config, $kaleb_db);
is($kaleb_settings->{contributor_media_quota_mb}, 256, 'service plan sync writes contributor media quota');
is($kaleb_settings->{contributor_media_upload_limit_mb}, 96, 'service plan sync writes contributor upload limit');
is($kaleb_settings->{contributor_post_quota}, 24, 'service plan sync writes contributor post quota');
is($kaleb_settings->{contributor_page_quota}, 8, 'service plan sync writes contributor page quota');
is($kaleb_settings->{contributor_allow_postmark_sender_override}, 1, 'service plan sync writes Postmark override entitlement');
is($kaleb_settings->{contributor_allow_stripe_connect}, 1, 'service plan sync writes Stripe Connect entitlement');
is($kaleb_settings->{contributor_allow_indexing_override}, 1, 'service plan sync writes indexing override entitlement');
is($kaleb_settings->{contributor_platform_fee_bps}, 1250, 'service plan sync writes platform fee entitlement');
is($kaleb_settings->{commerce_model}, 'platform_marketplace', 'service plan sync sets contributor marketplace commerce model');
my $kaleb_features = DesertCMS::Modules::feature_map_for_plan({ features_json => $kaleb_settings->{contributor_plan_features_json} });
ok($kaleb_features->{forms}, 'service plan sync writes included feature entitlement');
ok($kaleb_features->{shop}, 'service plan sync writes Shop / Catalog entitlement');
ok($kaleb_features->{shop_payments}, 'service plan sync writes Shop Payments entitlement');
ok(!$kaleb_features->{docs}, 'service plan sync writes locked feature entitlement');
ok($kaleb_features->{resource_publishing}, 'service plan sync writes Resource Downloads entitlement');
_write("$root/catalog-only.conf", <<"CONF");
site_name = Catalog Only
site_url = https://catalog-only.desertarchives.com
data_dir = $root/catalog-only-data
db_path = $root/catalog-only-data/desertcms.sqlite
app_secret_file = $root/catalog-only-data/app_secret
public_root = $root/catalog-only-public
originals_dir = $root/catalog-only-originals
backup_dir = $root/catalog-only-data/backups
theme_dir = $root/catalog-only-themes
admin_asset_dir = $root/catalog-only-admin-assets
secure_cookies = 0
contributor_site_id = catalogonly
contributor_domain = catalog-only.desertarchives.com
master_config_path = $config_path
CONF
my $catalog_config = DesertCMS::Config->load("$root/catalog-only.conf");
my $catalog_db = DesertCMS::DB->new(config => $catalog_config);
$catalog_db->migrate;
DesertCMS::Settings::set_many($catalog_config, $catalog_db, {
    module_shop_enabled => 1,
    shop_enabled => 1,
    commerce_model => 'platform_marketplace',
    contributor_allow_stripe_connect => 1,
});
$sites->register_existing_site(
    site_id      => 'catalogonly',
    domain       => 'catalog-only.desertarchives.com',
    display_name => 'Catalog Only',
    config_path  => "$root/catalog-only.conf",
    data_dir     => "$root/catalog-only-data",
    public_root  => "$root/catalog-only-public",
);
my $catalog_only_plan = $service_plans->save(
    name => 'Catalog Only Plan',
    slug => 'catalog-only-plan',
    description => 'Catalog listings without checkout.',
    monthly_price_dollars => '9.00',
    currency => 'usd',
    media_quota_mb => 128,
    media_upload_limit_mb => 32,
    post_quota => 12,
    page_quota => 6,
    feature_shop_included => 1,
    feature_shop_payments_included => 0,
    allow_stripe_connect => 1,
);
$service_plans->assign_site(
    site_id => 'catalogonly',
    plan_id => $catalog_only_plan->{id},
    billing_status => 'active',
);
my $catalog_settings = DesertCMS::Settings::all($catalog_config, $catalog_db);
is($catalog_settings->{module_shop_enabled}, 1, 'catalog-only plan preserves enabled Shop / Catalog setting');
is($catalog_settings->{shop_enabled}, 1, 'catalog-only plan preserves public catalog setting');
is($catalog_settings->{contributor_allow_stripe_connect}, 0, 'catalog-only plan disables Stripe Connect entitlement');
is($catalog_settings->{commerce_model}, 'disabled', 'catalog-only plan disables checkout commerce model');
my $catalog_features = DesertCMS::Modules::feature_map_for_plan({ features_json => $catalog_settings->{contributor_plan_features_json} });
ok($catalog_features->{shop}, 'catalog-only plan syncs Shop / Catalog entitlement');
ok(!$catalog_features->{shop_payments}, 'catalog-only plan keeps Shop Payments locked');
$db->dbh->do(
    "UPDATE contributor_sites SET status = 'destroyed', billing_status = 'canceled', destroyed_at = ? WHERE site_id = 'catalogonly'",
    undef,
    time
);
my $kaleb_usage = $service_plans->site_usage($assigned_kaleb);
is($kaleb_usage->{available}, 1, 'service plan usage reads contributor database');
is($kaleb_usage->{media_bytes}, 1048576, 'service plan usage counts contributor media bytes');
is($kaleb_usage->{media_upload_limit_mb}, 96, 'service plan usage reports contributor upload limit');
ok($kaleb_usage->{resource_publishing_included}, 'service plan usage reports Resource Downloads entitlement');
is($kaleb_usage->{post_count}, 1, 'service plan usage counts contributor posts');
is($kaleb_usage->{page_count}, 1, 'service plan usage counts contributor pages');
my $connect_http = Local::StripeConnectHTTP->new;
my $connect_plans = DesertCMS::ServicePlans->new(config => $config, db => $db, http => $connect_http);
my $connect = $connect_plans->create_connect_onboarding_link(
    site_id => 'kaleb',
    refresh_url => 'https://kaleb.desertarchives.com/admin/billing/stripe/connect/refresh',
    return_url => 'https://kaleb.desertarchives.com/admin/billing?stripe_connect=return',
);
is($connect->{url}, 'https://connect.stripe.com/setup/c/acct_kaleb123/link', 'Stripe Connect onboarding returns hosted account link');
is(scalar @{$connect_http->{posts}}, 2, 'Stripe Connect onboarding creates account and account link');
like($connect_http->{posts}[0]{url}, qr{/v1/accounts\z}, 'Stripe Connect onboarding creates connected account through platform');
like($connect_http->{posts}[0]{args}{content}, qr/type=express/, 'Stripe Connect onboarding requests an Express account');
like($connect_http->{posts}[0]{args}{content}, qr/capabilities%5Bcard_payments%5D%5Brequested%5D=true/, 'Stripe Connect onboarding requests card payments capability');
like($connect_http->{posts}[1]{args}{content}, qr/account=acct_kaleb123/, 'Stripe Connect onboarding creates account link for connected account');
my $connected_kaleb = $connect_plans->site_with_plan('kaleb');
is($connected_kaleb->{stripe_connect_account_id}, 'acct_kaleb123', 'master stores contributor connected account id');
$kaleb_settings = DesertCMS::Settings::all($kaleb_config, $kaleb_db);
is($kaleb_settings->{stripe_connect_account_id}, 'acct_kaleb123', 'Stripe Connect onboarding syncs account id to contributor settings');
is($kaleb_settings->{stripe_connect_charges_enabled}, 0, 'Stripe Connect onboarding syncs initial charges disabled state');
my $connect_refresh = $connect_plans->refresh_connect_account_status(site_id => 'kaleb');
is($connect_refresh->{onboarding_status}, 'ready', 'Stripe Connect refresh marks ready account status');
is($connect_refresh->{charges_enabled}, 1, 'Stripe Connect refresh reads charges enabled');
is($connect_refresh->{payouts_enabled}, 1, 'Stripe Connect refresh reads payouts enabled');
is($connect_http->{gets}[0]{url}, 'https://api.stripe.com/v1/accounts/acct_kaleb123', 'Stripe Connect refresh retrieves the connected account');
$connected_kaleb = $connect_plans->site_with_plan('kaleb');
is($connected_kaleb->{stripe_connect_onboarding_status}, 'ready', 'master stores refreshed Stripe Connect status');
is($connected_kaleb->{stripe_connect_charges_enabled}, 1, 'master stores refreshed charges state');
$kaleb_settings = DesertCMS::Settings::all($kaleb_config, $kaleb_db);
is($kaleb_settings->{stripe_connect_onboarding_status}, 'ready', 'Stripe Connect refresh syncs ready status to contributor settings');
is($kaleb_settings->{stripe_connect_payouts_enabled}, 1, 'Stripe Connect refresh syncs payouts state to contributor settings');
{
    local $ENV{DESERTCMS_CONFIG} = "$root/kaleb.conf";
    my $contrib_app = DesertCMS::App->new;
    my $contrib_session = {
        username => 'kaleb',
        role     => 'owner',
        email    => 'kaleb-owner@example.com',
    };
    my $help_html = _capture_response(sub {
        $contrib_app->_help_page(_request(), $contrib_session, 'contrib-help-session');
    });
    like($help_html, qr/Account and Help/, 'contributor help renders real account/help surface');
    like($help_html, qr/Studio Plan/, 'contributor help shows current plan');
    like($help_html, qr/support\@desertarchives\.com/, 'contributor help shows platform support contact');
    like($help_html, qr/Site Owner Guide/, 'contributor help links to site owner documentation');
    like($help_html, qr/Content and Design Help/, 'contributor help links to content and design documentation');
    like($help_html, qr/Billing Help/, 'contributor help includes billing help section');
    like($help_html, qr/Platform Status/, 'contributor help includes platform status section');
    like($help_html, qr/Platform-managed/, 'contributor help explains platform-managed services');
    unlike($help_html, qr/Master-managed|master CMS|master platform|contributor CMS/, 'contributor help avoids master/control-plane language');

    my $account_html = _capture_response(sub {
        $contrib_app->_settings_account_page(_request(), $contrib_session, 'contrib-account-session');
    });
    like($account_html, qr/<h1>Account<\/h1>/, 'contributor account page uses product account heading');
    like($account_html, qr/Save account/, 'contributor account page uses product save label');
    like($account_html, qr/Current Plan.*Studio Plan/s, 'contributor account embeds plan summary');
    like($account_html, qr/Contact Support/, 'contributor account embeds support link');
    like($account_html, qr/Platform Status/, 'contributor account embeds platform status summary');
    unlike($account_html, qr/<h1>Admin Account<\/h1>/, 'contributor account page does not use generic admin heading');

    my $billing_html = _capture_response(sub {
        $contrib_app->_billing_page(_request(), $contrib_session, 'contrib-billing-session');
    });
    like($billing_html, qr/<h2>Provider Readiness<\/h2>/, 'contributor billing exposes provider readiness strip');
    like($billing_html, qr/Plan Billing.*<span class="status-pill ok">Active<\/span>/s, 'provider readiness shows active platform plan billing');
    like($billing_html, qr/Postmark Sender.*Custom available/s, 'provider readiness shows custom Postmark sender entitlement');
    like($billing_html, qr/Stripe Payouts.*<span class="status-pill ok">Ready<\/span>/s, 'provider readiness shows ready Stripe payout status');
    like($billing_html, qr/Platform Fee.*12\.50%/s, 'provider readiness shows platform fee');
    like($billing_html, qr/Platform Services.*Stripe service billing/s, 'billing page still shows inherited platform services detail');
}
my $usage_sites = $service_plans->fleet_usage;
my ($kaleb_usage_site) = grep { $_->{site_id} eq 'kaleb' } @{$usage_sites};
is($kaleb_usage_site->{service_plan_name}, 'Studio Plan', 'fleet usage joins assigned service plan');
my $usage_summary = $service_plans->usage_summary($usage_sites);
is($usage_summary->{active_billing}, 1, 'usage summary counts active billing sites');
is($usage_summary->{monthly_cents}, 2900, 'usage summary totals active monthly plan value');
eval {
    $sites->register_existing_site(
        site_id      => 'desertcms',
        domain       => 'desertcms.com',
        display_name => 'DesertCMS',
    );
};
like($@, qr/contributor site domain must be a subdomain/, 'standalone master domains cannot be registered as contributor sites');
$db->dbh->do(
    q{
        INSERT INTO contributor_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             status, created_at, updated_at)
        VALUES
            ('desertcms', 'desertcms.com', 'DesertCMS', '', '', '', 'active', ?, ?)
    },
    undef,
    time,
    time
);

my $invite = $sites->create_invite(
    email              => 'Dakota@example.com',
    message            => 'Welcome',
    blueprint_id       => $limited_blueprint->{id},
    created_by_user_id => undef,
);
like($invite->{token}, qr/\A[0-9a-f]{64}\z/, 'invite returns one-time token');
like($invite->{invite_url}, qr{https://desertarchives\.com/admin/invite/[0-9a-f]{64}}, 'invite URL uses site URL');

my ($stored_token) = $db->dbh->selectrow_array('SELECT token_hash FROM contributor_invites WHERE id = ?', undef, $invite->{id});
isnt($stored_token, $invite->{token}, 'plain invite token is not stored');
my ($stored_blueprint_id) = $db->dbh->selectrow_array('SELECT blueprint_id FROM contributor_invites WHERE id = ?', undef, $invite->{id});
is($stored_blueprint_id, $limited_blueprint->{id}, 'invite stores selected blueprint');

my $site = $sites->accept_invite(
    token        => $invite->{token},
    first_name   => 'Dakota',
    last_initial => 'D',
);
is($site->{site_id}, 'dakota', 'first available subdomain uses first name');
is($site->{domain}, 'dakota.desertarchives.com', 'site domain uses contributor root');
is($site->{status}, 'pending_provision', 'accepted invite queues site for provisioning');
is($site->{blueprint_id}, $limited_blueprint->{id}, 'accepted invite stores blueprint id on site');
is($site->{service_plan_id}, $default_plan->{id}, 'accepted invite starts on default service plan');
is($site->{billing_status}, 'comped', 'accepted invite starts with comped free-tier billing');
is($site->{media_quota_mb}, $default_plan->{media_quota_mb}, 'accepted invite stores default service plan media quota');
is($site->{allow_master_gallery}, $default_plan->{allow_master_gallery}, 'accepted invite stores default service plan Showcase surfacing flag');
my $site_snapshot = decode_json($site->{blueprint_snapshot_json});
is($site_snapshot->{name}, 'Limited Showcase Contributor', 'accepted invite stores blueprint snapshot');
is($site_snapshot->{category}, 'local-archive', 'accepted invite stores blueprint vertical in snapshot');
is($site_snapshot->{category_label}, 'Local archive', 'accepted invite stores blueprint vertical label in snapshot');
is($site_snapshot->{theme_default_mode}, 'dark', 'blueprint snapshot stores theme default mode');

my ($invite_status) = $db->dbh->selectrow_array('SELECT status FROM contributor_invites WHERE id = ?', undef, $invite->{id});
is($invite_status, 'accepted', 'invite is marked accepted');

my $jobs = $sites->queue_rows;
is(@{$jobs}, 1, 'one provisioning job queued');
is($jobs->[0]{site_id}, 'dakota', 'queued job targets accepted site');
is($jobs->[0]{action}, 'create', 'queued job requests create');
my $job_details = decode_json($jobs->[0]{details_json});
is($job_details->{blueprint}{name}, 'Limited Showcase Contributor', 'queued create job includes blueprint snapshot');
is($job_details->{blueprint}{default_pages}[0]{slug}, 'portfolio', 'queued blueprint snapshot includes default pages');
is($job_details->{service_plan}{id}, $default_plan->{id}, 'queued create job includes default service plan snapshot');
is($job_details->{service_plan}{media_quota_mb}, $default_plan->{media_quota_mb}, 'queued service plan snapshot includes quota limits');

my $second = $sites->create_invite(email => 'dakota2@example.com');
my $second_site = $sites->accept_invite(
    token        => $second->{token},
    first_name   => 'Dakota',
    last_initial => 'D',
);
is($second_site->{site_id}, 'dakota-d', 'collision falls back to first name and last initial');

my $third = $sites->create_invite(email => 'third@example.com');
$sites->revoke_invite(id => $third->{id});
my ($revoked) = $db->dbh->selectrow_array('SELECT status FROM contributor_invites WHERE id = ?', undef, $third->{id});
is($revoked, 'revoked', 'can revoke pending invite');

$sites->request_site_action(site_id => 'dakota', action => 'disable');
my ($status) = $db->dbh->selectrow_array('SELECT status FROM contributor_sites WHERE site_id = ?', undef, 'dakota');
is($status, 'disabled', 'site action updates status');
$db->dbh->do(
    q{
        INSERT INTO contributor_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             status, created_at, updated_at, destroyed_at)
        VALUES
            ('destroyedtest', 'destroyedtest.desertarchives.com', 'Destroyed Test',
             'Alex', 'S', 'alex@example.com', 'destroyed', ?, ?, ?)
    },
    undef,
    time,
    time,
    time
);
$db->dbh->do(
    q{
        INSERT INTO archived_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             archive_path, archive_filename, archive_bytes, details_json, archived_at)
        VALUES
            ('destroyedtest', 'destroyedtest.desertarchives.com', 'Alex Smith',
             'Alex', 'S', 'alex@example.com', ?, 'alex-06302026.tar.gz', 4096, '{}', ?)
    },
    undef,
    "$root/archive/alex-06302026.tar.gz",
    time
);
my $visible_sites = $sites->list_sites;
ok(!(grep { ($_->{site_id} || '') eq 'destroyedtest' } @{$visible_sites}), 'destroyed sites are hidden from contributor site lists');
my $archived_sites = $sites->list_archived_sites;
is($archived_sites->[0]{archive_filename}, 'alex-06302026.tar.gz', 'archived site records are listed newest first');

my $fleet = $sites->fleet_status(check_dns => 0, check_tls => 0, app_version => 'test-build');
is($fleet->{total}, 3, 'fleet status counts only valid contributor subdomains');
is($fleet->{active}, 1, 'fleet status counts active sites');
is($fleet->{pending}, 1, 'fleet status counts pending sites');
is($fleet->{disabled}, 1, 'fleet status counts disabled sites');
is($fleet->{queue_open}, 3, 'fleet status counts queued provisioning work');

my ($kaleb_fleet) = grep { $_->{site_id} eq 'kaleb' } @{$fleet->{sites}};
is($kaleb_fleet->{paths}{config}{state}, 'ok', 'fleet status sees contributor config file');
is($kaleb_fleet->{paths}{data}{state}, 'ok', 'fleet status sees contributor data directory');
is($kaleb_fleet->{paths}{public}{state}, 'ok', 'fleet status sees contributor public root');
is($kaleb_fleet->{paths}{db}{state}, 'ok', 'fleet status sees contributor database file');
is($kaleb_fleet->{backups}{count}, 1, 'fleet status counts contributor backups');
ok($kaleb_fleet->{last_rebuild}, 'fleet status reports last public rebuild timestamp from generated files');
is($kaleb_fleet->{version}, 'test-build', 'fleet status carries shared app version');

my ($dakota_fleet) = grep { $_->{site_id} eq 'dakota' } @{$fleet->{sites}};
is($dakota_fleet->{queue}{action}, 'disable', 'fleet status shows latest queued site action');
is($dakota_fleet->{dns}{label}, 'Not checked', 'fleet status can skip live DNS checks for fast local rendering');

my $app = DesertCMS::App->new;
open my $app_source_fh, '<', "$FindBin::Bin/../lib/DesertCMS/App.pm" or die "cannot read App.pm: $!";
my $app_source = do { local $/; <$app_source_fh> };
close $app_source_fh;
like($app_source, qr/table-action-menu/, 'admin assets include mobile table action menu enhancer');
my $blueprints_html = _capture_response(sub {
    $app->_settings_blueprints_page(_request(), { username => 'admin' }, 'blueprint-session');
});
like($blueprints_html, qr/Contributor Blueprints/, 'blueprints settings page renders');
like($blueprints_html, qr/Limited Showcase Contributor/, 'blueprints settings page lists custom blueprint');
like($blueprints_html, qr/Local archive/, 'blueprints settings page lists vertical category');
like($blueprints_html, qr/name="category"/, 'blueprints settings page exposes vertical selector');
like($blueprints_html, qr/name="media_quota_mb"/, 'blueprints settings page exposes quotas');
like($blueprints_html, qr/module-section-nav" aria-label="Contributor blueprint sections".*href="\#blueprint-list">Blueprints<\/a>.*href="\#blueprint-editor">Blueprint Editor<\/a>.*href="\#blueprint-modules">Module Defaults<\/a>.*href="\#blueprint-theme-seo">Theme and SEO<\/a>.*href="\#blueprint-limits">Limits and Surfacing<\/a>.*href="\#blueprint-pages">Default Pages<\/a>/s, 'blueprints settings page exposes local section navigation');
like($blueprints_html, qr/id="blueprint-list".*id="blueprint-editor".*id="blueprint-modules".*id="blueprint-theme-seo".*id="blueprint-limits".*id="blueprint-pages"/s, 'blueprints local section navigation targets stable page anchors');
like($blueprints_html, qr/name="module_shop_enabled"[\s\S]*?<span>Shop \/ Catalog<\/span>/, 'blueprints module defaults use Shop / Catalog terminology');
like($blueprints_html, qr/class="content-table compact-table admin-card-table"/, 'blueprints settings table uses responsive admin card class');
like($blueprints_html, qr/data-label="Modules".*data-label="Master Surfacing".*data-label="Actions"/s, 'blueprint rows include mobile table labels');
my $master_html = _capture_response(sub {
    $app->_settings_master_control_page(_request(dns => 0, tls => 0), { username => 'admin' }, 'master-control-session');
});
like($master_html, qr/Master Control/, 'master control page renders');
like($master_html, qr/module-section-nav" aria-label="Master Control sections".*href="\#master-control-overview">Overview<\/a>.*href="\#master-control-maintenance">Maintenance<\/a>.*href="\#master-control-provider-readiness">Provider Readiness<\/a>.*href="\#master-control-provisioning">Provisioning Queue<\/a>/s, 'master control page exposes local section navigation');
like($master_html, qr/id="master-control-overview"/, 'master control page shows anchored fleet summary');
like($master_html, qr/class="content-table compact-table fleet-table fleet-table--summary admin-card-table"/, 'master control fleet tables use responsive admin card table class');
like($master_html, qr/data-label="Operations"/, 'master control fleet rows include mobile table labels');
like($master_html, qr/Provider Readiness/, 'master control page shows provider readiness');
like($master_html, qr/id="master-control-provider-readiness"/, 'master control page anchors provider readiness');
like($master_html, qr/Commerce \/ Stripe/, 'master control page shows commerce readiness');
like($master_html, qr/Email \/ Postmark/, 'master control page shows detailed Postmark readiness panel');
like($master_html, qr/Payments \/ Stripe/, 'master control page shows detailed Stripe readiness panel');
like($master_html, qr/href="\/admin\/settings\/contributors">Email setup<\/a>/, 'master control links to Postmark setup');
like($master_html, qr/href="\/admin\/settings\/modules\/shop">Stripe settings<\/a>/, 'master control links to Stripe settings');
like($master_html, qr/href="\/admin\/settings\/plans">Service plans<\/a>/, 'master control links to service plan billing setup');
like($master_html, qr/Postmark webhook endpoint/, 'master control shows Postmark webhook endpoint guidance');
like($master_html, qr/Checkout webhook endpoint.*\/stripe\/webhook/s, 'master control shows Stripe checkout webhook endpoint');
like($master_html, qr/Service billing webhook endpoint.*\/billing\/stripe\/webhook/s, 'master control shows service billing webhook endpoint');
like($master_html, qr/Tenant Isolation/, 'master control page shows tenant isolation audit');
like($master_html, qr/id="master-control-tenant-isolation"/, 'master control page anchors tenant isolation');
like($master_html, qr/Failed.*Needs Attention.*Healthy/s, 'master control page groups contributor fleet by health');
like($master_html, qr/kaleb\.desertarchives\.com/, 'master control page includes contributor domain');
like($master_html, qr/Disabled SubCMS.*dakota\.desertarchives\.com/s, 'master control separates disabled contributor sites');
like($master_html, qr/Archived Sites.*alex-06302026\.tar\.gz/s, 'master control shows archived sites separately');
unlike($master_html, qr/Failed.*destroyedtest\.desertarchives\.com.*Provider Readiness/s, 'master control hides destroyed rows from active fleet');
unlike($master_html, qr/id="master-control-disabled"[\s\S]*destroyedtest\.desertarchives\.com[\s\S]*id="master-control-archived"/, 'master control hides destroyed rows from disabled fleet');
unlike($master_html, qr/desertcms\.com/, 'master control page excludes standalone master domains');
like($master_html, qr/Not checked/, 'master control page can render without live DNS and TLS checks');
like($master_html, qr/Last login/, 'master control page shows last login field');
like($master_html, qr/action="\/admin\/settings\/master-control\/repair-paths"/, 'master control page offers path repair');
like($master_html, qr/action="\/admin\/settings\/master-control\/create-missing-backups"/, 'master control page offers missing backup creation');
like($master_html, qr/href="\/admin\/settings\/master-control\/provisioning\/[0-9]+"/, 'master control links to provisioning job details');
my $sites_html = _capture_response(sub {
    $app->_settings_sites_page(_request(), { username => 'admin' }, 'sites-session');
});
like($sites_html, qr/Active Sites/, 'contributor sites page shows active section');
like($sites_html, qr/class="content-table compact-table admin-card-table"/, 'contributor sites tables use responsive admin card class');
like($sites_html, qr/data-label="Actions" class="table-actions"/, 'contributor sites action cells include mobile labels');
like($sites_html, qr/Disabled Sites.*dakota\.desertarchives\.com/s, 'contributor sites page moves disabled rows into disabled section');
like($sites_html, qr/Archived Sites.*alex-06302026\.tar\.gz/s, 'contributor sites page shows archived site records');
unlike($sites_html, qr/Active Sites.*destroyedtest\.desertarchives\.com.*Disabled Sites/s, 'contributor sites page hides destroyed rows from active section');
unlike($sites_html, qr/Disabled Sites.*destroyedtest\.desertarchives\.com.*Archived Sites/s, 'contributor sites page hides destroyed rows from disabled section');
$db->dbh->do(
    q{
        INSERT INTO contributor_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             status, created_at, updated_at)
        VALUES
            ('redirecttest', 'redirecttest.desertarchives.com', 'Redirect Test',
             'Redirect', 'T', 'redirect@example.com', 'active', ?, ?)
    },
    undef,
    time,
    time
);
DesertCMS::HTTP->reset_response_state;
my $site_action_response = _capture_response(sub {
    $app->_settings_site_action(_request(site_id => 'redirecttest', action => 'destroy'), { username => 'admin' }, 'sites-session');
});
like($site_action_response, qr/Status: 303 See Other/, 'site action redirects after POST');
like($site_action_response, qr{Location: /admin/settings/sites\?notice=site-action-queued}, 'site action redirect carries notice');
my $plans_html = _capture_response(sub {
    $app->_settings_plans_page(_request(dns => 0, tls => 0), { username => 'admin' }, 'service-plan-session');
});
like($plans_html, qr/Service Plans/, 'service plans settings page renders');
like($plans_html, qr/Studio Plan/, 'service plans page lists custom plan');
like($plans_html, qr/Local archive - Limited Showcase Contributor/, 'service plans page shows recommended blueprint vertical');
like($plans_html, qr/kaleb\.desertarchives\.com/, 'service plans page lists contributor usage');
like($plans_html, qr/price_studio123/, 'service plans page shows Stripe Price ID');
like($plans_html, qr/module-section-nav" aria-label="Service plan sections".*href="\#service-plans-overview">Overview<\/a>.*href="\#service-plans-readiness">Billing Readiness<\/a>.*href="\#service-plans-list">Plans<\/a>.*href="\#service-plans-edit">Plan Editor<\/a>.*href="\#service-plans-features">Plan Features<\/a>.*href="\#service-plans-providers">Provider Overrides<\/a>.*href="\#service-plans-assignment">Assign Plan<\/a>.*href="\#service-plans-usage">Fleet Usage<\/a>/s, 'service plans page exposes local section navigation');
like($plans_html, qr/id="service-plans-overview".*id="service-plans-readiness".*id="service-plans-list".*id="service-plans-edit".*id="service-plans-features".*id="service-plans-providers".*id="service-plans-assignment".*id="service-plans-usage"/s, 'service plans local section navigation targets stable page anchors');
like($plans_html, qr/Plan Features/, 'service plans page exposes plan feature controls');
like($plans_html, qr/service-plan-feature-groups/, 'service plans page groups feature entitlement controls');
like($plans_html, qr/<h3>Public site features<\/h3>.*data-plan-feature-key="shop".*data-plan-feature-key="events".*data-plan-feature-key="testimonials"/s, 'service plans page groups public site feature entitlements');
like($plans_html, qr/<h3>Payments and deposits<\/h3>.*data-plan-feature-key="shop_payments".*data-plan-feature-key="event_payments".*data-plan-feature-key="donation_payments"/s, 'service plans page groups payment entitlements separately');
like($plans_html, qr/<h3>Publishing utilities<\/h3>.*data-plan-feature-key="map".*data-plan-feature-key="resource_publishing"/s, 'service plans page groups publishing utilities separately');
like($plans_html, qr/data-label="Features"/, 'service plan rows include feature entitlement summary');
like($plans_html, qr/class="content-table compact-table admin-card-table"/, 'service plan table uses responsive admin card class');
like($plans_html, qr/class="content-table compact-table service-usage-table admin-card-table"/, 'service usage table uses responsive admin card class');
like($plans_html, qr/data-label="Billing"/, 'service usage rows include mobile labels');
like($plans_html, qr/data-label="Actions" class="table-actions"/, 'service plan action cells include mobile labels');

my ($disable_job_id) = $db->dbh->selectrow_array(
    q{SELECT id FROM site_provisioning_queue WHERE site_id = 'dakota' AND action = 'disable' ORDER BY id DESC LIMIT 1}
);
$sites->record_queue_event(
    queue_id   => $disable_job_id,
    site_id    => 'dakota',
    action     => 'disable',
    step_key   => 'validate_httpd',
    step_label => 'Validate httpd config',
    status     => 'failed',
    message    => 'httpd validation failed',
);
$db->dbh->do(
    q{UPDATE site_provisioning_queue SET status = 'failed', error_text = 'httpd validation failed', updated_at = ? WHERE id = ?},
    undef,
    time,
    $disable_job_id
);
my $failed_job = $sites->queue_job($disable_job_id);
is($failed_job->{status}, 'failed', 'can load visible failed provisioning job');
my $events = $sites->queue_events($disable_job_id);
is($events->[0]{step_label}, 'Validate httpd config', 'queue events are stored for provisioning jobs');

my $job_html = _capture_response(sub {
    $app->_settings_provisioning_job_page(_request(), { username => 'admin', user_id => 1 }, 'master-control-session', $disable_job_id);
});
like($job_html, qr/Job #$disable_job_id/, 'provisioning job detail page renders');
like($job_html, qr/Validate httpd config/, 'provisioning job detail page shows step log');
like($job_html, qr/action="\/admin\/settings\/master-control\/provisioning\/$disable_job_id\/retry"/, 'failed provisioning job offers retry action');

my $retry = $sites->retry_failed_queue_job(id => $disable_job_id);
is($retry->{status}, 'queued', 'retry creates a new queued provisioning job');
is($retry->{action}, 'disable', 'retry preserves the queued action');
my $retry_events = $sites->queue_events($retry->{id});
is($retry_events->[0]{step_key}, 'retry_queued', 'retry records its audit event');

make_path("$root/etc", "$root/sites", "$root/htdocs");
my $repair = $sites->repair_openbsd_paths(
    config_base => "$root/etc",
    data_base   => "$root/sites",
    public_base => "$root/htdocs",
);
is($repair->{updated}, 2, 'path repair fills missing OpenBSD paths only for valid contributor rows');
my $repaired_dakota = $sites->site_by_id('dakota');
is($repaired_dakota->{config_path}, "$root/etc/desertcms-dakota.conf", 'path repair stores expected config path');
is($repaired_dakota->{data_dir}, "$root/sites/dakota", 'path repair stores expected data path');
is($repaired_dakota->{public_root}, "$root/htdocs/desertcms-dakota", 'path repair stores expected public path');
my $unchanged_kaleb = $sites->site_by_id('kaleb');
is($unchanged_kaleb->{config_path}, "$root/kaleb.conf", 'path repair does not overwrite existing custom config path');
my $invalid_master = $sites->site_by_id('desertcms');
is($invalid_master->{config_path}, '', 'path repair does not populate standalone master-domain rows');

done_testing;

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _capture_response {
    my ($code) = @_;
    my $output = '';
    open my $fh, '>', \$output or die "cannot capture output: $!";
    {
        local *STDOUT = $fh;
        $code->();
    }
    close $fh;
    return $output;
}

sub _request {
    my (%params) = @_;
    return bless { params => \%params }, 'Local::Request';
}

package Local::Request;

sub param {
    my ($self, $key) = @_;
    return $self->{params}{$key};
}

package main;
