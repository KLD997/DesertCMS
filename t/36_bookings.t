use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP qw(decode_json encode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Bookings;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::HTTP;
use DesertCMS::Modules;
use DesertCMS::Renderer;
use DesertCMS::Settings;
use DesertCMS::Util qw(hmac_sha256_hex now);

{
    package Local::Stripe;
    sub new { bless {}, shift }
    sub post {
        my ($self, $url, $args) = @_;
        $self->{url} = $url;
        $self->{content} = $args->{content};
        return {
            success => 1,
            status  => 200,
            content => '{"id":"cs_test_booking","url":"https://stripe.example.test/checkout/booking"}',
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
site_name = Bookings Test
site_url = https://bookings.example.test
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
    body_text => 'Bookings home.',
);
$content->publish(id => $home->{id});

DesertCMS::Settings::set_many($config, $db, {
    module_bookings_enabled => 1,
    module_map_enabled      => 1,
    bookings_title          => 'Appointments',
    bookings_intro          => 'Consultations, sessions, service calls, and venue appointments.',
    bookings_requests_enabled => 1,
    bookings_notify_postmark_enabled => 0,
});

my $settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'bookings'), 'bookings feature can be enabled independently');
my $catalog = DesertCMS::Modules::catalog($settings, config => $config);
like(_module_catalog_text($catalog), qr/Bookings \/ Appointments.*service listings, availability details, appointment request forms/s, 'feature catalog describes Bookings / Appointments');
like(_module_catalog_text($catalog), qr/Booking Deposits.*Stripe Checkout deposits/s, 'feature catalog describes separate Booking Deposits entitlement');

my $bookings = DesertCMS::Bookings->new(config => $config, db => $db);
my $service = $bookings->save_service(
    title                => 'Discovery Consultation',
    slug                 => 'discovery-consultation',
    service_kind         => 'consultation',
    status               => 'published',
    summary              => 'A planning call for new projects.',
    body                 => "We review scope, schedule, and fit.\nFollow-up notes are included.",
    availability_text    => "Weekdays by request.\nTwo business days notice preferred.",
    duration_minutes     => 45,
    price_note           => 'Free first consultation',
    deposit_enabled      => 1,
    deposit_label        => 'Consultation deposit',
    deposit_amount       => '50.00',
    deposit_currency     => 'usd',
    featured             => 1,
    location_enabled     => 1,
    location_lat         => '34.101234',
    location_lng         => '-112.202345',
    location_label       => 'Downtown studio service area',
    location_kind        => 'service_area',
);
ok($service->{id}, 'booking service is saved');
is($service->{service_kind}, 'consultation', 'booking service stores service kind');
is($service->{deposit_amount_cents}, 5000, 'booking service stores deposit amount separately from shop/event payments');

$content->rebuild_all;
ok(-f File::Spec->catfile($root, 'public', 'bookings', 'index.html'), 'bookings index is generated');
ok(-f File::Spec->catfile($root, 'public', 'bookings', 'discovery-consultation', 'index.html'), 'booking service detail page is generated');

my $index_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($index_html, qr{href="/bookings/"}, 'enabled Bookings appears in public navigation');
like($index_html, qr{Appointments}, 'public navigation uses configured Bookings title');

my $bookings_html = _read(File::Spec->catfile($root, 'public', 'bookings', 'index.html'));
like($bookings_html, qr{Discovery Consultation}, 'bookings index renders published service');
like($bookings_html, qr{Consultation}, 'bookings index renders service type label');

my $detail_html = _read(File::Spec->catfile($root, 'public', 'bookings', 'discovery-consultation', 'index.html'));
like($detail_html, qr{Weekdays by request}, 'booking detail renders availability text');
like($detail_html, qr{Request Booking}, 'booking detail renders request form');
like($detail_html, qr{online deposits are not available}, 'booking detail hides deposit checkout when payments are not ready');
like($detail_html, qr{View location}, 'booking detail links to map when coordinates exist');

my $sitemap = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
like($sitemap, qr{https://bookings\.example\.test/bookings/</loc>}, 'sitemap includes bookings index');
like($sitemap, qr{https://bookings\.example\.test/bookings/discovery-consultation/</loc>}, 'sitemap includes booking service detail');

my $map_data = decode_json(_read(File::Spec->catfile($root, 'public', 'assets', 'map-pins.json')));
my ($booking_pin) = grep { ($_->{type} || '') eq 'booking' } @{ $map_data->{pins} || [] };
ok($booking_pin, 'booking service appears in map pin JSON');
is($booking_pin->{kind}, 'service_area', 'booking map pin keeps location kind');
is($booking_pin->{kind_label}, 'Service area', 'booking map pin includes kind label');
is($booking_pin->{url}, '/bookings/discovery-consultation/', 'booking map pin links to service URL');

my $app = DesertCMS::App->new;
my $public_bookings = _capture_response(sub {
    $app->_dispatch_bookings(_booking_request('/bookings'));
});
like($public_bookings, qr{Discovery Consultation}, 'public /bookings route renders service list');
my $public_detail = _capture_response(sub {
    $app->_dispatch_bookings(_booking_request('/bookings/discovery-consultation'));
});
like($public_detail, qr{We review scope}, 'public booking detail route renders service body');

my $submit_response = _capture_response(sub {
    $app->_dispatch_bookings(_booking_request('/bookings/discovery-consultation/request', 'POST', {
        name             => 'Casey Client',
        email            => 'casey@example.test',
        phone            => '555-0100',
        organization     => 'Client Co',
        requested_date   => '2026-08-15',
        requested_time   => '10:30',
        preferred_window => 'Morning',
        party_size       => '2',
        budget           => 'Under 500',
        notes            => 'Need a discovery call for a new project.',
    }));
});
like($submit_response, qr{booking request has been received}, 'public booking request confirms review workflow');
my ($request_count) = $db->dbh->selectrow_array(q{SELECT COUNT(*) FROM booking_requests WHERE status = 'new'});
is($request_count, 1, 'public booking request creates request row');
my $request = $bookings->requests(limit => 1)->[0];
is($request->{service_title}, 'Discovery Consultation', 'booking request joins service title');
is($request->{deposit_status}, 'pending', 'deposit-enabled service marks request deposit pending before payment');

$bookings->update_request_status(id => $request->{id}, status => 'reviewing');
my $updated_request = $bookings->request_by_id($request->{id});
is($updated_request->{status}, 'reviewing', 'admin workflow can update booking request status');

my $admin_html = _capture_response(sub {
    $app->_module_bookings_settings_page(undef, { username => 'admin', role => 'owner' }, 'bookings-session');
});
like($admin_html, qr/<h1>Bookings \/ Appointments<\/h1>/, 'admin Bookings surface renders');
like($admin_html, qr/module-section-nav" aria-label="Bookings setup sections".*href="\#module-settings">Settings<\/a>.*href="\#module-services">Services<\/a>.*href="\#module-requests">Requests<\/a>.*href="\#module-payments">Deposit Payments<\/a>/s, 'admin Bookings surface exposes local section navigation');
like($admin_html, qr{<code>/bookings/</code>}, 'admin Bookings surface shows public path');
like($admin_html, qr{Discovery Consultation}, 'admin Bookings table lists service');
like($admin_html, qr{Casey Client}, 'admin Bookings table lists request');
like($admin_html, qr{Export CSV}, 'admin Bookings surface exposes request CSV export');
like($admin_html, qr/content-table compact-table admin-card-table/, 'admin Bookings tables use responsive card markup');
like($admin_html, qr/data-label="Service".*data-label="Requester".*data-label="Actions"/s, 'admin Bookings rows expose mobile card labels');
my $service_form_html = _capture_response(sub {
    $app->_booking_service_form(undef, { username => 'admin', role => 'owner' }, 'bookings-session');
});
like($service_form_html, qr/module-section-nav" aria-label="Booking service editor sections".*href="\#booking-service">Service<\/a>.*href="\#booking-location">Map \/ Location<\/a>.*href="\#booking-deposits">Deposits<\/a>/s, 'admin Booking service editor exposes local section navigation');
like($service_form_html, qr/id="booking-service".*id="booking-location".*id="booking-deposits"/s, 'admin Booking service editor section navigation targets stable form anchors');

my $csv = $bookings->csv_export;
like($csv, qr/Casey Client/, 'booking request CSV export includes requester');
like($csv, qr/Discovery Consultation/, 'booking request CSV export includes service');

my $contrib_config_path = "$root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Bookings
site_url = https://booking-site.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
contributor_site_id = booking-site
contributor_domain = booking-site.example.test
secure_cookies = 0
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        bookings         => 1,
        booking_payments => 0,
        map              => 1,
    }),
    module_bookings_enabled => 1,
    commerce_model => 'platform_marketplace',
    contributor_allow_stripe_connect => 1,
    stripe_secret_key => 'sk_test_booking',
    stripe_webhook_secret => 'whsec_booking',
});
my $feature_catalog = DesertCMS::Modules::catalog(DesertCMS::Settings::all($config, $db), config => $contrib_config);
my %feature_by_key = map { $_->{key} => $_ } @{$feature_catalog};
ok($feature_by_key{booking_payments}{locked_by_plan}, 'contributor feature catalog can lock Booking Deposits by plan');
ok(!$feature_by_key{booking_payments}{enabled}, 'locked Booking Deposits is not effectively enabled');
my $locked_bookings = DesertCMS::Bookings->new(config => $contrib_config, db => $db, http => Local::Stripe->new);
like($locked_bookings->payment_readiness->{summary}, qr/require Booking Deposits/, 'payment readiness explains locked booking deposits');
my $locked_error = eval { $locked_bookings->create_deposit_checkout(request_id => $request->{id}); 1 } ? '' : $@;
like($locked_error, qr/Booking Deposits/, 'deposit checkout is rejected when booking_payments is locked');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        bookings         => 1,
        booking_payments => 1,
        map              => 1,
    }),
    commerce_model => 'master_owned',
    stripe_secret_key => 'sk_test_booking',
    stripe_webhook_secret => 'whsec_booking',
});
my $stripe = Local::Stripe->new;
my $paid_bookings = DesertCMS::Bookings->new(config => $config, db => $db, http => $stripe);
ok($paid_bookings->checkout_ready, 'booking deposit checkout is ready when plan and Stripe settings allow it');
my $checkout = $paid_bookings->create_deposit_checkout(request_id => $request->{id});
is($checkout->{url}, 'https://stripe.example.test/checkout/booking', 'booking deposit checkout returns Stripe URL');
my $payment = $paid_bookings->payment_by_id($checkout->{payment_id});
is($payment->{status}, 'pending', 'booking deposit payment starts pending');
is($payment->{amount_cents}, 5000, 'booking deposit payment stores amount in booking_payments');
my $request_with_payment = $paid_bookings->request_by_id($request->{id});
is($request_with_payment->{deposit_payment_id}, $checkout->{payment_id}, 'booking request links to booking payment');

my $payload = encode_json({
    id   => 'evt_booking_paid',
    type => 'checkout.session.completed',
    data => {
        object => {
            id => 'cs_test_booking',
            payment_status => 'paid',
            amount_total => 5000,
            currency => 'usd',
            payment_intent => 'pi_booking',
            customer_details => {
                email => 'casey@example.test',
                name  => 'Casey Client',
            },
            metadata => {
                booking_payment_id => $checkout->{payment_id},
                booking_request_id => $request->{id},
                booking_service_id => $service->{id},
            },
        },
    },
});
my $ts = now();
my $sig = hmac_sha256_hex($ts . '.' . $payload, 'whsec_booking');
$paid_bookings->handle_webhook(payload => $payload, signature => "t=$ts,v1=$sig");
my $paid = $paid_bookings->payment_by_id($checkout->{payment_id});
is($paid->{status}, 'paid', 'booking webhook marks deposit payment paid');
my $paid_request = $paid_bookings->request_by_id($request->{id});
is($paid_request->{deposit_status}, 'paid', 'booking webhook marks request deposit paid');

local $app->{config} = $contrib_config;
my $feature_catalog_html = _capture_response(sub {
    $app->_settings_modules_page(undef, { username => 'admin', role => 'owner' }, 'modules-session');
});
like($feature_catalog_html, qr/module-catalog-landing" id="module-catalog-workspace".*<h2>Feature setup<\/h2>/s, 'feature catalog renders one setup workspace below the grouped nav');
unlike($feature_catalog_html, qr/data-feature-key=|module-card-kicker/, 'feature catalog no longer repeats Bookings or Booking Deposits as body cards');
unlike($feature_catalog_html, qr/master CMS|contributor CMS/, 'contributor feature catalog avoids backend CMS terminology');

done_testing;

sub _booking_request {
    my ($path, $method, $form) = @_;
    return bless {
        method => $method || 'GET',
        path   => $path || '/bookings',
        host   => 'bookings.example.test',
        form   => $form || {},
        query  => $form || {},
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
