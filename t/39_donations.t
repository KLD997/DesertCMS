use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP qw(encode_json);
use MIME::Base64 qw(encode_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::Donations;
use DesertCMS::HTTP;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Util qw(hmac_sha256_hex now);

{
    package Local::DonationStripe;
    sub new {
        my ($class, %args) = @_;
        return bless {
            id    => $args{id}  || 'cs_test_donation',
            url   => $args{url} || 'https://stripe.example.test/checkout/donation',
            posts => [],
        }, $class;
    }
    sub post {
        my ($self, $url, $args) = @_;
        push @{ $self->{posts} }, { url => $url, args => $args };
        return {
            success => 1,
            status  => 200,
            content => '{"id":"' . $self->{id} . '","url":"' . $self->{url} . '"}',
        };
    }
}

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public/assets/media", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Donations Test
site_url = https://donations.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
secure_cookies = 0
CONF

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
my $content = DesertCMS::Content->new(config => $config, db => $db);

my $home = $content->save(
    type      => 'page',
    title     => 'Home',
    slug      => 'home',
    body_text => 'Donations home.',
);
$content->publish(id => $home->{id});

DesertCMS::Settings::set_many($config, $db, {
    module_donations_enabled => 1,
    donations_title          => 'Support Us',
    donations_intro          => 'Fund archives, events, artists, and public resources.',
    commerce_model           => 'disabled',
});

my $settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'donations'), 'donations feature can be enabled independently');
my $catalog = DesertCMS::Modules::catalog($settings, config => $config);
like(_module_catalog_text($catalog), qr/Donations \/ Fundraising.*fundraising campaigns, suggested and custom amounts, donor messages, goal progress/s, 'feature catalog describes Donations / Fundraising');
like(_module_catalog_text($catalog), qr/Donation Payments.*Stripe Checkout donations, marketplace payouts, platform fees/s, 'feature catalog describes separate Donation Payments entitlement');

my $donations = DesertCMS::Donations->new(config => $config, db => $db);
my $campaign = $donations->save_campaign(
    title                 => 'Archive Fund',
    slug                  => 'archive-fund',
    status                => 'published',
    summary               => 'Help preserve community materials.',
    body                  => "Funds support scanning and description.\nDonor notes are welcome.",
    goal_amount           => '5000.00',
    currency              => 'usd',
    suggested_amounts     => '25.00, 50.00, 100.00',
    allow_custom_amount   => 1,
    donor_message_enabled => 1,
    show_goal             => 1,
    featured              => 1,
);
ok($campaign->{id}, 'donation campaign is saved');
is($campaign->{goal_amount_cents}, 500000, 'donation campaign stores goal amount in cents');
is($campaign->{suggested_amounts_text}, '25.00, 50.00, 100.00', 'donation campaign stores normalized suggested amounts');

$content->rebuild_all;
ok(-f File::Spec->catfile($root, 'public', 'donate', 'index.html'), 'donations index is generated');
ok(-f File::Spec->catfile($root, 'public', 'donate', 'archive-fund', 'index.html'), 'donation campaign detail page is generated');

my $home_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($home_html, qr{href="/donate/"}, 'enabled Donations appears in public navigation');
like($home_html, qr{Support Us}, 'public navigation uses configured Donations title');

my $donate_html = _read(File::Spec->catfile($root, 'public', 'donate', 'index.html'));
like($donate_html, qr{Archive Fund}, 'donations index renders published campaign');
like($donate_html, qr{Help preserve community materials}, 'donations index renders campaign summary');

my $detail_html = _read(File::Spec->catfile($root, 'public', 'donate', 'archive-fund', 'index.html'));
like($detail_html, qr{Funds support scanning}, 'donation detail renders campaign body');
like($detail_html, qr{USD 0\.00 raised of USD 5000\.00}, 'donation detail renders goal progress');
like($detail_html, qr{Online donations are not available}, 'donation detail hides checkout when payments are not ready');
unlike($detail_html, qr{Donate with Stripe}, 'donation detail omits Stripe button when checkout is unavailable');

my $sitemap = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
like($sitemap, qr{https://donations\.example\.test/donate/</loc>}, 'sitemap includes donations index');
like($sitemap, qr{https://donations\.example\.test/donate/archive-fund/</loc>}, 'sitemap includes donation campaign detail');

my $app = DesertCMS::App->new;
my $public_index = _capture_response(sub {
    $app->_dispatch_donations(_donation_request('/donate'));
});
like($public_index, qr{Support Us}, 'dynamic /donate route renders donation index');
my $public_detail = _capture_response(sub {
    $app->_dispatch_donations(_donation_request('/donate/archive-fund'));
});
like($public_detail, qr{Donor notes are welcome}, 'dynamic donation detail route renders campaign body');

my $admin_html = _capture_response(sub {
    $app->_module_donations_settings_page(undef, { username => 'admin', role => 'owner' }, 'donations-session');
});
like($admin_html, qr/<h1>Donations \/ Fundraising<\/h1>/, 'admin Donations surface renders');
like($admin_html, qr/module-section-nav" aria-label="Donations setup sections".*href="\#module-settings">Settings<\/a>.*href="\#module-campaigns">Campaigns<\/a>.*href="\#module-records">Donation Records<\/a>/s, 'admin Donations surface exposes local section navigation');
like($admin_html, qr{<code>/donate/</code>}, 'admin Donations surface shows public path');
like($admin_html, qr{Archive Fund}, 'admin Donations surface lists campaigns');
like($admin_html, qr{Export CSV}, 'admin Donations surface exposes donor CSV export');
like($admin_html, qr/content-table compact-table admin-card-table/, 'admin Donations tables use responsive card markup');
like($admin_html, qr/data-label="Campaign".*data-label="Actions"/s, 'admin Donations populated rows expose mobile card labels');
like($admin_html, qr/<th>Stripe Session<\/th>/, 'admin Donations payment table keeps responsive payment headers for empty states');
my $campaign_form_html = _capture_response(sub {
    $app->_donation_campaign_form(undef, { username => 'admin', role => 'owner' }, 'donations-session', $campaign->{id});
});
like($campaign_form_html, qr/module-section-nav" aria-label="Donation campaign editor sections".*href="\#donation-campaign">Campaign<\/a>.*href="\#donation-fundraising">Fundraising<\/a>.*href="\#donation-display">Display<\/a>/s, 'admin Donation campaign editor exposes local section navigation');
like($campaign_form_html, qr/id="donation-campaign".*id="donation-fundraising".*id="donation-display"/s, 'admin Donation campaign editor section navigation targets stable form anchors');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        donations         => 1,
        donation_payments => 0,
    }),
    module_donations_enabled        => 1,
    commerce_model                  => 'platform_marketplace',
    contributor_allow_stripe_connect => 1,
    stripe_secret_key               => 'sk_test_donation',
    stripe_webhook_secret           => 'whsec_donation',
});
my $contrib_config_path = "$root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Donations
site_url = https://donation-site.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
contributor_site_id = donation-site
contributor_domain = donation-site.example.test
secure_cookies = 0
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
my $feature_catalog = DesertCMS::Modules::catalog(DesertCMS::Settings::all($config, $db), config => $contrib_config);
my %feature_by_key = map { $_->{key} => $_ } @{$feature_catalog};
ok($feature_by_key{donation_payments}{locked_by_plan}, 'contributor feature catalog can lock Donation Payments by plan');
ok(!$feature_by_key{donation_payments}{enabled}, 'locked Donation Payments is not effectively enabled');
my $locked_donations = DesertCMS::Donations->new(config => $contrib_config, db => $db, http => Local::DonationStripe->new);
like($locked_donations->payment_readiness->{summary}, qr/requires Donation Payments/, 'payment readiness explains locked donation payments');
my $locked_error = eval { $locked_donations->create_checkout(campaign_id => $campaign->{id}, amount => '25.00'); 1 } ? '' : $@;
like($locked_error, qr/Donation Payments/, 'donation checkout is rejected when donation_payments is locked');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        donations         => 1,
        donation_payments => 1,
    }),
    commerce_model        => 'master_owned',
    stripe_secret_key     => 'sk_test_donation',
    stripe_webhook_secret => 'whsec_donation',
});
my $stripe = Local::DonationStripe->new;
$donations = DesertCMS::Donations->new(config => $config, db => $db, http => $stripe);
ok($donations->checkout_ready, 'donation checkout is ready when plan and Stripe settings allow it');
my $checkout = $donations->create_checkout(
    campaign_id    => $campaign->{id},
    amount         => '50.00',
    donor_email    => 'donor@example.test',
    donor_name     => 'Dana Donor',
    donor_message  => 'Keep going.',
);
is($checkout->{url}, 'https://stripe.example.test/checkout/donation', 'donation checkout returns Stripe URL');
is(scalar @{ $stripe->{posts} }, 1, 'donation checkout posts one Stripe request');
is($stripe->{posts}[0]{args}{headers}{Authorization}, 'Basic ' . encode_base64('sk_test_donation:', ''), 'donation checkout uses configured Stripe key');
like($stripe->{posts}[0]{args}{content}, qr/metadata%5Bdesertcms_payment%5D=donation/, 'donation checkout records donation payment metadata');

my $pending = $donations->donation_by_id($checkout->{donation_id});
is($pending->{status}, 'pending', 'donation record starts pending');
is($pending->{amount_cents}, 5000, 'donation record stores selected amount');
is($pending->{donor_email}, 'donor@example.test', 'donation record stores donor email');

my $payload = encode_json({
    id   => 'evt_donation_paid',
    type => 'checkout.session.completed',
    data => {
        object => {
            id             => $checkout->{session_id},
            payment_status => 'paid',
            amount_total   => 5000,
            currency       => 'usd',
            payment_intent => 'pi_donation_paid',
            customer_details => {
                email => 'donor@example.test',
                name  => 'Dana Donor',
            },
            metadata => {
                donation_id          => $checkout->{donation_id},
                donation_campaign_id => $campaign->{id},
                desertcms_payment    => 'donation',
            },
        },
    },
});
my $ts = now();
my $sig = hmac_sha256_hex($ts . '.' . $payload, 'whsec_donation');
my $webhook = $donations->handle_webhook(payload => $payload, signature => "t=$ts,v1=$sig");
ok($webhook->{ok}, 'donation webhook accepts valid signed Stripe payload');
my $paid = $donations->donation_by_id($checkout->{donation_id});
is($paid->{status}, 'paid', 'donation webhook marks donation paid');
is($paid->{stripe_payment_intent_id}, 'pi_donation_paid', 'donation webhook stores payment intent');
my $duplicate = $donations->handle_webhook(payload => $payload, signature => "t=$ts,v1=$sig");
ok($duplicate->{duplicate}, 'duplicate donation webhook is idempotent');

my $updated_campaign = $donations->get_campaign($campaign->{id});
is($updated_campaign->{raised_cents}, 5000, 'paid donations contribute to campaign totals');
my $csv = $donations->csv_export;
like($csv, qr/Dana Donor/, 'donor CSV export includes donor');
like($csv, qr/Archive Fund/, 'donor CSV export includes campaign');

my $contrib_root = tempdir(CLEANUP => 1);
$contrib_root =~ s{\\}{/}g;
make_path("$contrib_root/public", "$contrib_root/originals", "$contrib_root/backups", "$contrib_root/admin-assets", "$contrib_root/data", "$contrib_root/themes");
my $market_config_path = "$contrib_root/contributor.conf";
_write($market_config_path, <<"CONF");
site_name = Contributor Donation Seller
site_url = https://fundraiser.example.test
data_dir = $contrib_root/data
db_path = $contrib_root/data/desertcms.sqlite
app_secret_file = $contrib_root/data/app_secret
public_root = $contrib_root/public
originals_dir = $contrib_root/originals
backup_dir = $contrib_root/backups
theme_dir = $contrib_root/themes
admin_asset_dir = $contrib_root/admin-assets
secure_cookies = 0
contributor_site_id = fundraiser
contributor_domain = fundraiser.example.test
master_config_path = $config_path
CONF
my $market_config = DesertCMS::Config->load($market_config_path);
my $market_db = DesertCMS::DB->new(config => $market_config);
$market_db->migrate;
DesertCMS::Settings::set_many($market_config, $market_db, {
    module_donations_enabled => 1,
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        donations         => 1,
        donation_payments => 1,
    }),
    commerce_model => 'platform_marketplace',
    contributor_allow_stripe_connect => 1,
    contributor_platform_fee_bps => 1250,
    stripe_connect_account_id => 'acct_donations123',
});
my $market_donations = DesertCMS::Donations->new(config => $market_config, db => $market_db, http => Local::DonationStripe->new(id => 'cs_test_donation_marketplace'));
my $market_campaign = $market_donations->save_campaign(
    title               => 'Venue Fund',
    status              => 'published',
    summary             => 'Support the venue.',
    suggested_amounts   => '100.00',
    allow_custom_amount => 1,
);
my $market_checkout = $market_donations->create_checkout(
    campaign_id => $market_campaign->{id},
    amount      => '100.00',
);
ok($market_checkout->{donation_id}, 'contributor marketplace donation checkout creates a donation record');
is($market_donations->{http}{posts}[0]{args}{headers}{Authorization}, 'Basic ' . encode_base64('sk_test_donation:', ''), 'contributor marketplace donation checkout uses inherited master Stripe key');
like($market_donations->{http}{posts}[0]{args}{content}, qr/payment_intent_data%5Btransfer_data%5D%5Bdestination%5D=acct_donations123/, 'contributor marketplace donation checkout routes proceeds to connected account');
like($market_donations->{http}{posts}[0]{args}{content}, qr/payment_intent_data%5Bapplication_fee_amount%5D=1250/, 'contributor marketplace donation checkout adds platform application fee');

local $app->{config} = $contrib_config;
my $feature_catalog_html = _capture_response(sub {
    $app->_settings_modules_page(undef, { username => 'admin', role => 'owner' }, 'modules-session');
});
like($feature_catalog_html, qr/module-catalog-landing" id="module-catalog-workspace".*<h2>Feature setup<\/h2>/s, 'feature catalog renders one setup workspace below the grouped nav');
unlike($feature_catalog_html, qr/data-feature-key=|module-card-kicker/, 'feature catalog no longer repeats Donations or Donation Payments as body cards');
unlike($feature_catalog_html, qr/master CMS|contributor CMS/, 'contributor feature catalog avoids backend CMS terminology');

done_testing;

sub _donation_request {
    my ($path, $method, $form) = @_;
    return bless {
        method => $method || 'GET',
        path   => $path || '/donate',
        host   => 'donations.example.test',
        form   => $form || {},
        query  => $form || {},
        body   => '',
    }, 'DesertCMS::HTTP';
}

sub _module_catalog_text {
    my ($catalog) = @_;
    return join "\n", map {
        join ' ', $_->{label} || '', $_->{description} || '', $_->{public_path} || ''
    } @{$catalog || []};
}

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _capture_response {
    my ($code) = @_;
    my $output = '';
    open my $fh, '>', \$output or die "cannot capture output: $!";
    {
        local *STDOUT = $fh;
        DesertCMS::HTTP::reset_response_state();
        $code->();
    }
    return $output;
}
