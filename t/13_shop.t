use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use MIME::Base64 qw(encode_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::HTTP;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Shop;

{
    package Local::StripeHTTP;

    sub new {
        my ($class, %args) = @_;
        return bless {
            posts => [],
            id    => $args{id} || 'cs_test_desert',
            url   => $args{url} || 'https://checkout.stripe.com/c/pay/cs_test_desert',
        }, $class;
    }

    sub post {
        my ($self, $url, $args) = @_;
        push @{$self->{posts}}, { url => $url, args => $args };
        return {
            success => 1,
            content => JSON::PP::encode_json({
                id  => $self->{id},
                url => $self->{url},
            }),
        };
    }
}

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public/assets/media", "$root/originals", "$root/backups", "$root/themes", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Shop Test
site_url = https://desertarchives.com
shop_domain = shop.desertarchives.com
shop_url = https://shop.desertarchives.com
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $root/themes
admin_asset_dir = $root/admin-assets
secure_cookies = 0
stripe_secret_key = sk_test_desert
stripe_webhook_secret = whsec_desert
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
DesertCMS::Settings::set_many($config, $db, {
    module_shop_enabled => 1,
    shop_enabled => 1,
});

my $dbh = $db->dbh;
$dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, mime_type, width, height, bytes, checksum_sha256, created_at)
        VALUES
            ('mesquite.jpg', ?, '/assets/media/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg',
             'Mesquite in late light', 'image/jpeg', 1200, 800, 12345,
             'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ?)
    },
    undef,
    "$root/originals/mesquite.jpg",
    time
);
my $media_id = $dbh->sqlite_last_insert_rowid;

my $http = Local::StripeHTTP->new;
my $shop = DesertCMS::Shop->new(config => $config, db => $db, http => $http);
$config->app_secret;

my $listing = $shop->save_listing(
    media_asset_id      => $media_id,
    title               => 'Mesquite Study',
    description         => 'Evening photograph from the archive.',
    active              => 1,
    currency            => 'usd',
    personal_enabled    => 1,
    personal_price      => '75.00',
    commercial_enabled  => 1,
    commercial_price    => '350.00',
    full_rights_enabled => 1,
    full_rights_price   => '2500.00',
);
ok($listing->{id}, 'creates shop listing for an uploaded media asset');

my $catalog = $shop->catalog_items;
is(@{$catalog}, 1, 'active priced listing appears in the catalog');
is($catalog->[0]{title}, 'Mesquite Study', 'catalog uses listing title');

my $app = DesertCMS::App->new;
my $shop_catalog_html = _capture_response(sub {
    $app->_dispatch_shop(_shop_request('/shop'), '/shop');
});
like($shop_catalog_html, qr{class="site-header site-header--split site-logo-size--medium"}, 'shop catalog uses shared public header shell');
like($shop_catalog_html, qr{class="site-footer site-footer--standard}, 'shop catalog uses shared public footer shell');
like($shop_catalog_html, qr{class="content module-page shop-page shop-shell"}, 'shop catalog renders as a public module page');
like($shop_catalog_html, qr{Mesquite Study}, 'shop catalog renders active listing title');
like($shop_catalog_html, qr{<h1>Catalog</h1>}, 'shop catalog uses catalog heading');
like($shop_catalog_html, qr{products, services, digital items, portfolio samples, and selected media}, 'shop catalog describes broad catalog items');
like($shop_catalog_html, qr{rights-option rights-option--personal}, 'shop catalog renders purchase options');
like($shop_catalog_html, qr{data-site-menu-toggle}, 'shop catalog includes shared mobile menu control');
like($shop_catalog_html, qr{<script src="/assets/site\.js"></script>}, 'shop catalog route uses the public shell script');
unlike($shop_catalog_html, qr{/admin/assets/admin\.css|href="/admin"}, 'shop catalog route stays on the public shell');
like($shop_catalog_html, qr{<img src="/assets/media/a{64}\.jpg" alt="Mesquite in late light" loading="lazy" decoding="async" width="1200" height="800" class="public-media-img">}, 'shop catalog renders shared public media markup for listing art');
unlike($shop_catalog_html, qr{Shop Photographic Work|Photographs available for rights purchase|selected photographs}, 'shop catalog no longer uses photography-only product copy');

my $bad_checkout = eval {
    $shop->create_checkout(
        listing_id      => $listing->{id},
        rights_type     => 'full',
        purchase_token  => 'tampered',
    );
    1;
};
ok(!$bad_checkout, 'rejects checkout without a valid purchase token');
my ($order_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM shop_orders');
is($order_count, 0, 'invalid purchase token does not create an order');

my $purchase_token = $shop->purchase_token($shop->listing($listing->{id}), 'full');
like($purchase_token, qr/\A[0-9]+:[0-9]+:full:250000:usd:[0-9a-f]{64}\z/, 'purchase token binds listing, rights, price, and currency');
my $checkout = $shop->create_checkout(
    listing_id      => $listing->{id},
    rights_type     => 'full',
    purchase_token  => $purchase_token,
);
is($checkout->{url}, 'https://checkout.stripe.com/c/pay/cs_test_desert', 'returns Stripe Checkout URL');
is(scalar @{$http->{posts}}, 1, 'posts one Checkout Session request');
like($http->{posts}[0]{args}{content}, qr/mode=payment/, 'Checkout request uses payment mode');
like($http->{posts}[0]{args}{content}, qr/metadata%5Brights_type%5D=full/, 'Checkout request records rights type metadata');
like($http->{posts}[0]{args}{content}, qr/success_url=https%3A%2F%2Fshop\.desertarchives\.com%2Fsuccess%3Forder%3D1/, 'Checkout success URL uses shop hostname');

my $fallback_config = bless {
    %{$config->all},
    site_url    => 'https://desertarchives.com',
    shop_domain => '',
    shop_url    => '',
}, 'DesertCMS::Config';
my $fallback_shop = DesertCMS::Shop->new(config => $fallback_config, db => $db, http => $http);
is($fallback_shop->shop_host, '', 'unconfigured shop does not claim the main host');
is($fallback_shop->shop_url('/'), 'https://desertarchives.com/shop', 'unconfigured shop falls back to the /shop route');
is($fallback_shop->shop_url('/success?order=1'), 'https://desertarchives.com/shop/success?order=1', 'local success URL keeps the /shop prefix');
is($fallback_shop->shop_url('/stripe/webhook'), 'https://desertarchives.com/stripe/webhook', 'main-domain Stripe webhook URL stays outside the /shop prefix');
is($fallback_shop->shop_url('/assets/media/photo.jpg'), 'https://desertarchives.com/assets/media/photo.jpg', 'public media URLs stay outside the /shop route');

DesertCMS::Settings::set_many($config, $db, {
    shop_domain => '',
    shop_url    => 'https://desertarchives.com/shop',
});
my $path_shop = DesertCMS::Shop->new(config => $config, db => $db, http => $http);
is($path_shop->shop_host, '', 'path-prefixed shop URL does not claim the main host');
is($path_shop->shop_url('/'), 'https://desertarchives.com/shop', 'path-prefixed shop URL opens the shop route');
is($path_shop->shop_url('/success?order=1'), 'https://desertarchives.com/shop/success?order=1', 'path-prefixed shop URL keeps checkout callbacks under /shop');
is($path_shop->shop_url('/stripe/webhook'), 'https://desertarchives.com/stripe/webhook', 'path-prefixed shop URL keeps Stripe webhook at the main dynamic route');
is($path_shop->shop_url('/assets/media/photo.jpg'), 'https://desertarchives.com/assets/media/photo.jpg', 'path-prefixed shop URL keeps media outside /shop');

my $order = $shop->order($checkout->{order_id});
is($order->{status}, 'pending', 'order starts pending');
is($order->{stripe_checkout_session_id}, 'cs_test_desert', 'order stores Checkout Session id');

my $payload = encode_json({
    id   => 'evt_test_desert',
    type => 'checkout.session.completed',
    data => {
        object => {
            id                  => 'cs_test_desert',
            client_reference_id => $checkout->{order_id},
            payment_status      => 'paid',
            amount_total        => 1,
            currency            => 'usd',
            payment_intent      => 'pi_test_desert',
            metadata            => {
                order_id       => $checkout->{order_id},
                listing_id     => $listing->{id},
                media_asset_id => $media_id,
                rights_type    => 'full',
            },
            customer_details => {
                email => 'buyer@example.com',
                name  => 'Rights Buyer',
            },
        },
    },
});
my $bad_signature = DesertCMS::Shop->webhook_signature_header(
    payload => $payload,
    secret  => 'whsec_desert',
);
my $bad_webhook = eval {
    $shop->handle_webhook(payload => $payload, signature => $bad_signature);
    1;
};
ok(!$bad_webhook, 'rejects paid webhook when Stripe amount does not match order');
my ($recorded_bad_events) = $dbh->selectrow_array('SELECT COUNT(*) FROM shop_stripe_events WHERE stripe_event_id = ?', undef, 'evt_test_desert');
is($recorded_bad_events, 0, 'failed webhook is not marked processed');

$payload = encode_json({
    id   => 'evt_test_desert',
    type => 'checkout.session.completed',
    data => {
        object => {
            id                  => 'cs_test_desert',
            client_reference_id => $checkout->{order_id},
            payment_status      => 'paid',
            amount_total        => 250000,
            currency            => 'usd',
            payment_intent      => 'pi_test_desert',
            metadata            => {
                order_id       => $checkout->{order_id},
                listing_id     => $listing->{id},
                media_asset_id => $media_id,
                rights_type    => 'full',
            },
            customer_details => {
                email => 'buyer@example.com',
                name  => 'Rights Buyer',
            },
        },
    },
});
my $signature = DesertCMS::Shop->webhook_signature_header(
    payload => $payload,
    secret  => 'whsec_desert',
);
my $webhook = $shop->handle_webhook(payload => $payload, signature => $signature);
ok($webhook->{ok}, 'accepts a valid signed Stripe webhook');

$order = $shop->order($checkout->{order_id});
is($order->{status}, 'paid', 'webhook marks order paid');
is($order->{customer_email}, 'buyer@example.com', 'webhook stores buyer email');
is($order->{stripe_payment_intent_id}, 'pi_test_desert', 'webhook stores payment intent');

my $sold_listing = $shop->listing($listing->{id});
is($sold_listing->{active}, 0, 'full-rights purchase removes listing from sale');
ok($sold_listing->{full_rights_sold_at}, 'full-rights sale timestamp is recorded');
is(@{$shop->catalog_items}, 0, 'sold full-rights listing disappears from catalog');

my $duplicate = $shop->handle_webhook(payload => $payload, signature => $signature);
ok($duplicate->{duplicate}, 'duplicate Stripe event is idempotent');

$dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text,
             owner_site_id, owner_domain, owner_display_name, owner_email,
             mime_type, width, height, bytes, checksum_sha256, created_at)
        VALUES
            ('ocotillo.jpg', ?, '/assets/media/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.jpg',
             'Ocotillo after rain',
             'dakota', 'dakota.desertarchives.com', 'Dakota Archive', 'dakota@example.com',
             'image/jpeg', 1000, 700, 12345,
             'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', ?)
    },
    undef,
    "$root/originals/ocotillo.jpg",
    time
);
my $settings_media_id = $dbh->sqlite_last_insert_rowid;
$dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text,
             owner_site_id, owner_domain, owner_display_name, owner_email,
             mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
        VALUES
            ('private-catalog-notes.pdf', ?, '',
             '',
             'dakota', 'dakota.desertarchives.com', 'Dakota Archive', 'dakota@example.com',
             'application/pdf', NULL, NULL, 2345,
             'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
             '{"public_policy":"private_source_only"}', ?)
    },
    undef,
    "$root/originals/private-catalog-notes.pdf",
    time
);
my $document_media_id = $dbh->sqlite_last_insert_rowid;
DesertCMS::Settings::set_many($config, $db, {
    shop_domain => 'shop.saved.example',
    shop_url => 'https://shop.saved.example',
    shop_enabled => 1,
    shop_require_purchase_token => 0,
    stripe_secret_key => 'sk_test_saved',
    stripe_webhook_secret => 'whsec_saved',
});
my $settings_http = Local::StripeHTTP->new(
    id  => 'cs_test_saved',
    url => 'https://checkout.stripe.com/c/pay/cs_test_saved',
);
my $settings_shop = DesertCMS::Shop->new(config => $config, db => $db, http => $settings_http);
is($settings_shop->shop_host, 'shop.saved.example', 'admin-saved shop host overrides config');
my $admin_media_rows = $settings_shop->admin_media_rows;
ok((grep { $_->{id} == $settings_media_id } @{$admin_media_rows}), 'shop admin media rows keep image assets with public derivatives');
ok(!(grep { $_->{id} == $document_media_id } @{$admin_media_rows}), 'shop admin media rows exclude private document assets');
my $document_listing = eval {
    $settings_shop->save_listing(
        media_asset_id   => $document_media_id,
        title            => 'Private notes',
        active           => 1,
        personal_enabled => 1,
        personal_price   => '10.00',
    );
    1;
};
ok(!$document_listing, 'shop listing rejects private document assets');
like($@, qr/public optimized derivative/, 'shop listing rejection explains image derivative requirement');
my $contributor_filters = $settings_shop->admin_contributor_filters($admin_media_rows);
my ($dakota_filter) = grep { $_->{label} eq 'Dakota Archive' } @{$contributor_filters};
ok($dakota_filter, 'shop admin contributor filter includes uploaded contributor names');
is($dakota_filter ? $dakota_filter->{count} : undef, 1, 'shop admin contributor filter counts contributor items');
like($dakota_filter ? $dakota_filter->{search} : '', qr/dakota\.desertarchives\.com/, 'shop admin contributor filter searches contributor domain');
my $shop_admin_html = _capture_response(sub {
    my $shop_admin_app = DesertCMS::App->new;
    $shop_admin_app->_module_shop_settings_page(_shop_request('/admin/settings/modules/shop'), { username => 'admin', role => 'owner' }, 'shop-admin-session');
});
like($shop_admin_html, qr{<h1>Shop / Catalog</h1>}, 'shop admin uses Shop / Catalog heading');
like($shop_admin_html, qr{module-section-nav" aria-label="Shop / Catalog setup sections".*href="\#module-settings">Catalog Settings</a>.*href="\#module-listings">Listings</a>.*href="\#module-orders">Orders</a>}s, 'shop admin exposes local section navigation');
like($shop_admin_html, qr{<h2>Listings</h2>}, 'shop admin uses listings heading');
like($shop_admin_html, qr{name="listing_kind"}, 'shop admin exposes listing type field');
like($shop_admin_html, qr{name="cta_label"}, 'shop admin exposes inquiry CTA label field');
like($shop_admin_html, qr{href="/admin/settings/payments">Settings &gt; Payments</a>}, 'shop admin points provider settings to centralized payments page');
unlike($shop_admin_html, qr{name="stripe_secret_key"}, 'shop admin no longer owns the Stripe secret key field');
unlike($shop_admin_html, qr{name="stripe_webhook_secret"}, 'shop admin no longer owns the Stripe webhook secret field');
unlike($shop_admin_html, qr{name="commerce_model"}, 'shop admin no longer owns the global commerce model field');
like($shop_admin_html, qr{data-shop-item-card}, 'shop admin uses item card selector');
like($shop_admin_html, qr{Publish product, service, digital, portfolio, media, and inquiry listings}, 'shop admin explains catalog listings');
like($shop_admin_html, qr{<table class="content-table compact-table admin-card-table">.*<th>Created</th><th>Item</th><th>Rights</th><th>Total</th><th>Status</th><th>Email</th>}s, 'shop order history uses responsive admin card table markup');
like($shop_admin_html, qr{data-label="Created".*data-label="Email"}s, 'shop order rows expose mobile table labels');
unlike($shop_admin_html, qr{Photo Pricing|Show this photograph in the shop|data-shop-photo-card}, 'shop admin no longer uses photo-only pricing labels');
my $settings_listing = $settings_shop->save_listing(
    media_asset_id     => $settings_media_id,
    title              => 'Ocotillo Study',
    active             => 1,
    currency           => 'usd',
    personal_enabled   => 1,
    personal_price     => '25.00',
);
my $settings_checkout = $settings_shop->create_checkout(
    listing_id  => $settings_listing->{id},
    rights_type => 'personal',
);
ok($settings_checkout->{order_id}, 'checkout uses admin-saved shop settings');
like($settings_http->{posts}[0]{args}{content}, qr/success_url=https%3A%2F%2Fshop\.saved\.example%2Fsuccess%3Forder%3D2/, 'admin-saved shop URL is used for Checkout URLs');
is($settings_http->{posts}[0]{args}{headers}{Authorization}, 'Basic ' . encode_base64('sk_test_saved:', ''), 'admin-saved Stripe secret key is used for Checkout');

my $contrib_root = tempdir(CLEANUP => 1);
$contrib_root =~ s{\\}{/}g;
make_path("$contrib_root/public/assets/media", "$contrib_root/originals", "$contrib_root/backups", "$contrib_root/themes", "$contrib_root/admin-assets", "$contrib_root/data");
my $contrib_config_path = "$contrib_root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Shop
site_url = https://seller.desertarchives.com
data_dir = $contrib_root/data
db_path = $contrib_root/data/desertcms.sqlite
app_secret_file = $contrib_root/data/app_secret
public_root = $contrib_root/public
originals_dir = $contrib_root/originals
backup_dir = $contrib_root/backups
theme_dir = $contrib_root/themes
admin_asset_dir = $contrib_root/admin-assets
secure_cookies = 0
contributor_site_id = seller
contributor_domain = seller.desertarchives.com
master_config_path = $config_path
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
my $contrib_db = DesertCMS::DB->new(config => $contrib_config);
$contrib_db->migrate;
DesertCMS::Settings::set_many($contrib_config, $contrib_db, {
    module_shop_enabled => 1,
    shop_enabled => 1,
    commerce_model => 'platform_marketplace',
    contributor_allow_stripe_connect => 1,
    contributor_platform_fee_bps => 1250,
    stripe_connect_account_id => 'acct_seller123',
});
my $contrib_dbh = $contrib_db->dbh;
$contrib_dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, mime_type, width, height, bytes, checksum_sha256, created_at)
        VALUES
            ('seller.jpg', ?, '/assets/media/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.jpg',
             'Seller photo', 'image/jpeg', 900, 600, 12345,
             'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', ?)
    },
    undef,
    "$contrib_root/originals/seller.jpg",
    time
);
my $contrib_media_id = $contrib_dbh->sqlite_last_insert_rowid;
my $marketplace_http = Local::StripeHTTP->new(
    id  => 'cs_test_marketplace',
    url => 'https://checkout.stripe.com/c/pay/cs_test_marketplace',
);
my $marketplace_shop = DesertCMS::Shop->new(config => $contrib_config, db => $contrib_db, http => $marketplace_http);
my $marketplace_listing = $marketplace_shop->save_listing(
    media_asset_id   => $contrib_media_id,
    title            => 'Seller Study',
    active           => 1,
    currency         => 'usd',
    personal_enabled => 1,
    personal_price   => '75.00',
);
my $marketplace_token = $marketplace_shop->purchase_token($marketplace_shop->listing($marketplace_listing->{id}), 'personal');
my $marketplace_checkout = $marketplace_shop->create_checkout(
    listing_id     => $marketplace_listing->{id},
    rights_type    => 'personal',
    purchase_token => $marketplace_token,
);
ok($marketplace_checkout->{order_id}, 'contributor marketplace checkout creates an order');
is($marketplace_http->{posts}[0]{args}{headers}{Authorization}, 'Basic ' . encode_base64('sk_test_saved:', ''), 'contributor marketplace checkout uses inherited master Stripe key');
like($marketplace_http->{posts}[0]{args}{content}, qr/payment_intent_data%5Btransfer_data%5D%5Bdestination%5D=acct_seller123/, 'contributor marketplace checkout routes proceeds to connected account');
like($marketplace_http->{posts}[0]{args}{content}, qr/payment_intent_data%5Bapplication_fee_amount%5D=938/, 'contributor marketplace checkout adds platform application fee');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        shop => 1,
        shop_payments => 0,
    }),
    commerce_model => 'disabled',
});
$dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, mime_type, width, height, bytes, checksum_sha256, created_at)
        VALUES
            ('service.jpg', ?, '/assets/media/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.jpg',
             'Service catalog preview', 'image/jpeg', 900, 600, 12345,
             'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', ?)
    },
    undef,
    "$root/originals/service.jpg",
    time
);
my $catalog_only_media_id = $dbh->sqlite_last_insert_rowid;
my $catalog_only_shop = DesertCMS::Shop->new(config => $config, db => $db, http => Local::StripeHTTP->new);
my $catalog_only_listing = $catalog_only_shop->save_listing(
    media_asset_id => $catalog_only_media_id,
    title          => 'Archive Consultation',
    description    => 'Catalog-only service listing.',
    listing_kind   => 'service',
    cta_label      => 'Request info',
    cta_url        => '/forms/',
    active         => 1,
    currency       => 'usd',
);
ok($catalog_only_listing->{id}, 'catalog-only plan can publish active listing without a price');
ok($catalog_only_shop->catalog_enabled, 'catalog-only plan keeps shop catalog enabled');
ok(!$catalog_only_shop->checkout_ready, 'catalog-only plan keeps checkout not ready');
my $catalog_only_html = _capture_response(sub {
    my $catalog_app = DesertCMS::App->new;
    $catalog_app->_dispatch_shop(_shop_request('/shop'), '/shop');
});
like($catalog_only_html, qr{Archive Consultation}, 'catalog-only public shop renders listing title');
like($catalog_only_html, qr{Service}, 'catalog-only public shop renders listing type');
like($catalog_only_html, qr{href="/forms/">Request info</a>}, 'catalog-only public shop renders inquiry CTA');
unlike($catalog_only_html, qr{rights-option|Buy personal|Payments are handled by Stripe|Checkout}, 'catalog-only public shop omits buy buttons and payment copy');
my ($orders_before_locked_post) = $dbh->selectrow_array('SELECT COUNT(*) FROM shop_orders');
my $locked_post_html = _capture_response(sub {
    my $catalog_app = DesertCMS::App->new;
    $catalog_app->_dispatch_shop(
        _shop_request('/shop/checkout', 'POST', {
            listing_id  => $settings_listing->{id},
            rights_type => 'personal',
        }),
        '/shop'
    );
});
like($locked_post_html, qr{Checkout could not be started}, 'catalog-only checkout POST is rejected');
my ($orders_after_locked_post) = $dbh->selectrow_array('SELECT COUNT(*) FROM shop_orders');
is($orders_after_locked_post, $orders_before_locked_post, 'catalog-only checkout POST does not create an order');
my $disabled_checkout = eval {
    $catalog_only_shop->create_checkout(
        listing_id  => $settings_listing->{id},
        rights_type => 'personal',
    );
    1;
};
ok(!$disabled_checkout, 'locked Shop Payments rejects direct Checkout');
like($@, qr/Shop payments/, 'locked Shop Payments error is explicit');

done_testing;

sub _shop_request {
    my ($path, $method, $form) = @_;
    return bless {
        method => $method || 'GET',
        path   => $path || '/shop',
        host   => 'desertarchives.com',
        form   => $form || {},
        query  => {},
    }, 'DesertCMS::HTTP';
}

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
        DesertCMS::HTTP::reset_response_state();
        $code->();
    }
    return $output;
}
