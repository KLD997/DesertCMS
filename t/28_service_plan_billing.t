use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Modules;
use DesertCMS::ServicePlans;
use DesertCMS::Settings;
use DesertCMS::Shop;
use DesertCMS::Sites;

{
    package Local::StripeHTTP;

    sub new {
        return bless { posts => [] }, shift;
    }

    sub post {
        my ($self, $url, $args) = @_;
        push @{$self->{posts}}, { url => $url, args => $args };
        my $portal = $url =~ m{/billing_portal/sessions\z} ? 1 : 0;
        my %body = (
            id  => $portal ? 'bps_test_desert' : 'cs_test_service_plan',
            url => $portal
                ? 'https://billing.stripe.com/p/session/bps_test_desert'
                : 'https://checkout.stripe.com/c/pay/cs_test_service_plan',
        );
        @body{qw(amount_total currency)} = (1900, 'usd') unless $portal;
        return { success => 1, content => JSON::PP::encode_json(\%body) };
    }
}

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path(
    "$root/master/public",
    "$root/master/originals",
    "$root/master/backups",
    "$root/master/themes",
    "$root/master/admin-assets",
    "$root/master/data",
    "$root/dakota/data/backups",
    "$root/dakota/public",
    "$root/dakota/originals",
    "$root/dakota/themes",
    "$root/dakota/admin-assets",
);

my $master_config_path = "$root/master/desertcms.conf";
_write($master_config_path, <<"CONF");
site_name = DesertCMS Billing Test
site_url = https://desertarchives.com
data_dir = $root/master/data
db_path = $root/master/data/desertcms.sqlite
app_secret_file = $root/master/data/app_secret
public_root = $root/master/public
originals_dir = $root/master/originals
backup_dir = $root/master/backups
theme_dir = $root/master/themes
admin_asset_dir = $root/master/admin-assets
secure_cookies = 0
stripe_secret_key = sk_test_desert
stripe_webhook_secret = whsec_desert
CONF

my $dakota_config_path = "$root/dakota/desertcms.conf";
_write($dakota_config_path, <<"CONF");
site_name = Dakota
site_url = https://dakota.desertarchives.com
data_dir = $root/dakota/data
db_path = $root/dakota/data/desertcms.sqlite
app_secret_file = $root/dakota/data/app_secret
public_root = $root/dakota/public
originals_dir = $root/dakota/originals
backup_dir = $root/dakota/data/backups
theme_dir = $root/dakota/themes
admin_asset_dir = $root/dakota/admin-assets
secure_cookies = 0
contributor_site_id = dakota
contributor_domain = dakota.desertarchives.com
master_config_path = $master_config_path
CONF

my $config = DesertCMS::Config->load($master_config_path);
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
DesertCMS::Settings::set_many($config, $db, {
    contributor_domain_root => 'desertarchives.com',
    stripe_secret_key       => 'sk_test_desert',
    stripe_webhook_secret   => 'whsec_desert',
});

my $dakota_config = DesertCMS::Config->load($dakota_config_path);
my $dakota_db = DesertCMS::DB->new(config => $dakota_config);
$dakota_db->migrate;

my $sites = DesertCMS::Sites->new(config => $config, db => $db);
my $http = Local::StripeHTTP->new;
my $plans = DesertCMS::ServicePlans->new(config => $config, db => $db, http => $http);
my $default = $plans->default_plan;
my $paid = $plans->save(
    name => 'Studio Plan',
    slug => 'studio-plan',
    description => 'Paid contributor service plan.',
    blueprint_id => $default->{blueprint_id},
    monthly_price_dollars => '19.00',
    currency => 'usd',
    stripe_price_id => 'price_studio123',
    media_quota_mb => 2048,
    media_upload_limit_mb => 128,
    post_quota => 500,
    page_quota => 50,
    feature_resource_publishing_included => 1,
    allow_master_gallery => 1,
    allow_master_posts => 1,
);
is($paid->{media_upload_limit_mb}, 128, 'custom service plan saves per-file media upload limit');
my $paid_features = DesertCMS::Modules::feature_map_for_plan($paid);
ok($paid_features->{resource_publishing}, 'custom service plan saves Resource Downloads entitlement');

$sites->register_existing_site(
    site_id => 'dakota',
    domain => 'dakota.desertarchives.com',
    display_name => 'Dakota',
    owner_email => 'dakota@example.com',
    config_path => $dakota_config_path,
    data_dir => "$root/dakota/data",
    public_root => "$root/dakota/public",
);
my $free_site = $plans->assign_site(
    site_id => 'dakota',
    plan_id => $default->{id},
    billing_status => 'comped',
    billing_email => 'dakota@example.com',
);
is($free_site->{service_plan_id}, $default->{id}, 'site starts on the default free service plan');
my $usage_ts = time;
$dakota_db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
        VALUES
            ('desert.jpg', ?, ?, 'Desert', 'Desert', 'Image source',
             'image/jpeg', 800, 600, 1048576, ?, '{}', ?),
            ('private-guide.pdf', ?, '', '', 'Private Guide', 'Private source document',
             'application/pdf', NULL, NULL, 2048, ?, '{}', ?),
            ('public-resource.md', ?, ?, '', 'Public Resource', 'Published resource file',
             'text/markdown', NULL, NULL, 4096, ?, '{}', ?)
    },
    undef,
    "$root/dakota/originals/desert.jpg",
    '/assets/media/' . ('a' x 64) . '.jpg',
    'a' x 64,
    $usage_ts,
    "$root/dakota/originals/private-guide.pdf",
    'b' x 64,
    $usage_ts,
    "$root/dakota/originals/public-resource.md",
    '/assets/resources/' . ('c' x 64) . '.md',
    'c' x 64,
    $usage_ts
);
my $usage_site = $plans->site_with_plan('dakota');
my $usage = $plans->site_usage($usage_site);
ok($usage->{available}, 'service plan usage can read contributor database');
is($usage->{media_count}, 3, 'usage counts all active media assets');
is($usage->{media_bytes}, 1054720, 'usage sums all active media bytes');
is($usage->{media_image_count}, 1, 'usage counts image assets');
is($usage->{media_image_bytes}, 1048576, 'usage sums image bytes');
is($usage->{media_document_count}, 2, 'usage counts document/resource assets');
is($usage->{media_document_bytes}, 6144, 'usage sums document/resource bytes');
is($usage->{media_resource_count}, 1, 'usage counts public resources');
is($usage->{media_resource_bytes}, 4096, 'usage sums public resource bytes');
is($usage->{media_private_count}, 1, 'usage counts private-source-only assets');
is($usage->{media_private_bytes}, 2048, 'usage sums private-source-only bytes');
ok($usage->{media_remaining_bytes} > 0, 'usage reports remaining media storage');
is($usage->{media_upload_limit_mb}, $default->{media_upload_limit_mb}, 'usage reports current plan upload limit');
ok(!$usage->{resource_publishing_included}, 'usage reports default plan Resource Downloads lock');

my $checkout = $plans->create_subscription_checkout(
    site_id => 'dakota',
    plan_id => $paid->{id},
    success_url => 'https://dakota.desertarchives.com/admin/billing?checkout=success',
    cancel_url => 'https://dakota.desertarchives.com/admin/billing?checkout=cancel',
);
is($checkout->{url}, 'https://checkout.stripe.com/c/pay/cs_test_service_plan', 'creates a subscription Checkout Session');
is($http->{posts}[0]{url}, 'https://api.stripe.com/v1/checkout/sessions', 'subscription checkout uses Stripe Checkout Sessions endpoint');
like($http->{posts}[0]{args}{content}, qr/mode=subscription/, 'checkout request uses subscription mode');
like($http->{posts}[0]{args}{content}, qr/line_items%5B0%5D%5Bprice%5D=price_studio123/, 'checkout request uses the plan Stripe Price ID');
like($http->{posts}[0]{args}{content}, qr/metadata%5Bsite_id%5D=dakota/, 'checkout request carries the site id metadata');
like($http->{posts}[0]{args}{content}, qr/subscription_data%5Bmetadata%5D%5Bplan_id%5D=/, 'checkout request carries subscription plan metadata');
my $pending_checkout = $db->dbh->selectrow_hashref(
    'SELECT * FROM service_plan_checkout_sessions WHERE stripe_checkout_session_id = ?',
    undef,
    'cs_test_service_plan'
);
is($pending_checkout->{status}, 'pending', 'checkout creation records a pending local session binding');
is($pending_checkout->{site_id}, 'dakota', 'checkout binding stores site id');
is($pending_checkout->{plan_id}, $paid->{id}, 'checkout binding stores plan id');
is($pending_checkout->{stripe_price_id}, 'price_studio123', 'checkout binding stores Stripe Price ID');

my $unbound_checkout_payload = encode_json({
    id   => 'evt_service_checkout_unbound',
    type => 'checkout.session.completed',
    data => {
        object => {
            id => 'cs_test_attacker_supplied',
            mode => 'subscription',
            client_reference_id => 'dakota',
            customer => 'cus_service123',
            subscription => 'sub_service123',
            amount_total => 1900,
            currency => 'usd',
            metadata => {
                desertcms_billing => 'service_plan',
                site_id => 'dakota',
                plan_id => $paid->{id},
            },
        },
    },
});
my $unbound_signature = DesertCMS::Shop->webhook_signature_header(
    payload => $unbound_checkout_payload,
    secret  => 'whsec_desert',
);
my $unbound_event = $plans->handle_subscription_webhook(payload => $unbound_checkout_payload, signature => $unbound_signature);
ok(!$unbound_event->{handled}, 'unbound checkout session webhook is ignored');
is($plans->site_with_plan('dakota')->{service_plan_id}, $default->{id}, 'unbound checkout does not change the site plan');

my $checkout_payload = encode_json({
    id   => 'evt_service_checkout',
    type => 'checkout.session.completed',
    data => {
        object => {
            id => 'cs_test_service_plan',
            mode => 'subscription',
            client_reference_id => 'dakota',
            customer => 'cus_service123',
            subscription => 'sub_service123',
            amount_total => 1900,
            currency => 'usd',
            metadata => {
                desertcms_billing => 'service_plan',
                site_id => 'dakota',
                plan_id => $paid->{id},
            },
            customer_details => {
                email => 'dakota-billing@example.com',
            },
        },
    },
});
my $checkout_signature = DesertCMS::Shop->webhook_signature_header(
    payload => $checkout_payload,
    secret  => 'whsec_desert',
);
my $checkout_event = $plans->handle_subscription_webhook(payload => $checkout_payload, signature => $checkout_signature);
ok($checkout_event->{handled}, 'checkout completed webhook is handled');
my $paid_site = $plans->site_with_plan('dakota');
is($paid_site->{service_plan_id}, $paid->{id}, 'checkout webhook assigns the paid plan');
is($paid_site->{billing_status}, 'active', 'checkout webhook marks billing active');
is($paid_site->{billing_email}, 'dakota-billing@example.com', 'checkout webhook stores billing email');
is($paid_site->{stripe_customer_id}, 'cus_service123', 'checkout webhook stores Stripe customer id');
is($paid_site->{stripe_subscription_id}, 'sub_service123', 'checkout webhook stores Stripe subscription id');
is($paid_site->{media_quota_mb}, 2048, 'checkout webhook copies paid media quota');
is($paid_site->{media_upload_limit_mb}, 128, 'checkout webhook copies paid upload limit');
my ($completed_checkout_status) = $db->dbh->selectrow_array(
    'SELECT status FROM service_plan_checkout_sessions WHERE stripe_checkout_session_id = ?',
    undef,
    'cs_test_service_plan'
);
is($completed_checkout_status, 'completed', 'checkout webhook marks local session binding completed');
my $dakota_settings = DesertCMS::Settings::all($dakota_config, $dakota_db);
is($dakota_settings->{contributor_media_quota_mb}, 2048, 'checkout webhook syncs contributor media quota');
is($dakota_settings->{contributor_media_upload_limit_mb}, 128, 'checkout webhook syncs contributor upload limit');
my $dakota_features = DesertCMS::Modules::feature_map_for_plan({ features_json => $dakota_settings->{contributor_plan_features_json} });
ok($dakota_features->{resource_publishing}, 'checkout webhook syncs Resource Downloads entitlement');

my $portal = $plans->create_portal_session(
    site_id => 'dakota',
    return_url => 'https://dakota.desertarchives.com/admin/billing',
);
is($portal->{url}, 'https://billing.stripe.com/p/session/bps_test_desert', 'creates a Stripe Billing Portal session');
is($http->{posts}[1]{url}, 'https://api.stripe.com/v1/billing_portal/sessions', 'portal uses Stripe Billing Portal endpoint');
like($http->{posts}[1]{args}{content}, qr/customer=cus_service123/, 'portal request uses the stored Stripe customer');

my $past_due_payload = encode_json({
    id   => 'evt_service_past_due',
    type => 'customer.subscription.updated',
    data => {
        object => {
            id => 'sub_service123',
            customer => 'cus_service123',
            status => 'past_due',
            current_period_end => 1800000000,
            metadata => {
                desertcms_billing => 'service_plan',
                site_id => 'dakota',
                plan_id => $paid->{id},
            },
        },
    },
});
my $past_due_signature = DesertCMS::Shop->webhook_signature_header(payload => $past_due_payload, secret => 'whsec_desert');
my $past_due_event = $plans->handle_subscription_webhook(payload => $past_due_payload, signature => $past_due_signature);
ok($past_due_event->{handled}, 'subscription update webhook is handled');
my $past_due_site = $plans->site_with_plan('dakota');
is($past_due_site->{billing_status}, 'past_due', 'subscription update marks the site past due');
is($past_due_site->{billing_current_period_end}, 1800000000, 'subscription update stores the current period end');

my $deleted_payload = encode_json({
    id   => 'evt_service_deleted',
    type => 'customer.subscription.deleted',
    data => {
        object => {
            id => 'sub_service123',
            customer => 'cus_service123',
            status => 'canceled',
            metadata => {
                desertcms_billing => 'service_plan',
                site_id => 'dakota',
                plan_id => $paid->{id},
            },
        },
    },
});
my $deleted_signature = DesertCMS::Shop->webhook_signature_header(payload => $deleted_payload, secret => 'whsec_desert');
my $deleted_event = $plans->handle_subscription_webhook(payload => $deleted_payload, signature => $deleted_signature);
ok($deleted_event->{handled}, 'subscription deleted webhook is handled');
my $downgraded_site = $plans->site_with_plan('dakota');
is($downgraded_site->{service_plan_id}, $default->{id}, 'deleted subscription downgrades to the default plan');
is($downgraded_site->{billing_status}, 'comped', 'deleted subscription returns billing to comped');
is($downgraded_site->{stripe_customer_id}, 'cus_service123', 'deleted subscription preserves the customer id for future checkout');
is($downgraded_site->{stripe_subscription_id}, '', 'deleted subscription clears the subscription id');
is($downgraded_site->{media_quota_mb}, $default->{media_quota_mb}, 'deleted subscription restores free-tier quota');
is($downgraded_site->{media_upload_limit_mb}, $default->{media_upload_limit_mb}, 'deleted subscription restores free-tier upload limit');
my $downgraded_settings = DesertCMS::Settings::all($dakota_config, $dakota_db);
is($downgraded_settings->{contributor_media_quota_mb}, $default->{media_quota_mb}, 'deleted subscription syncs free-tier media quota');
is($downgraded_settings->{contributor_media_upload_limit_mb}, $default->{media_upload_limit_mb}, 'deleted subscription syncs free-tier upload limit');

my $duplicate = $plans->handle_subscription_webhook(payload => $deleted_payload, signature => $deleted_signature);
ok($duplicate->{duplicate}, 'subscription webhooks are idempotent');

done_testing;

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}
