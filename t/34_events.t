use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(encode_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DateTimeLite;
use DesertCMS::DB;
use DesertCMS::Events;
use DesertCMS::HTTP;
use DesertCMS::Modules;
use DesertCMS::Renderer;
use DesertCMS::Settings;

{
    package Local::StripeHTTP;

    sub new {
        my ($class, %args) = @_;
        return bless {
            posts => [],
            id    => $args{id} || 'cs_test_events',
            url   => $args{url} || 'https://checkout.stripe.com/c/pay/cs_test_events',
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

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public/assets/media", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Events Test
site_url = https://events.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
secure_cookies = 0
stripe_secret_key = sk_test_config_events
stripe_webhook_secret = whsec_config_events
CONF

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
my $content = DesertCMS::Content->new(config => $config, db => $db);

DesertCMS::Settings::set_many($config, $db, {
    module_events_enabled => 1,
    module_map_enabled    => 1,
    events_title          => 'Community Calendar',
    events_intro          => 'Workshops, open houses, talks, and ticketed programs.',
    commerce_model        => 'master_owned',
});

my $settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'events'), 'events module can be enabled independently');
ok(DesertCMS::Modules::enabled($settings, 'event_payments'), 'master event payments are available without contributor plan JSON');
my $catalog = DesertCMS::Modules::catalog($settings, config => $config);
like(_module_catalog_text($catalog), qr/Events.*calendar, event pages, RSVP, free tickets/s, 'module catalog describes Events');
like(_module_catalog_text($catalog), qr/Event Payments.*paid event tickets, Stripe Checkout, marketplace payouts, and platform fees/s, 'module catalog exposes separate Event Payments entitlement');

my $start = DesertCMS::DateTimeLite->now(time_zone => 'UTC')->add(days => 14)->set(hour => 18, minute => 0, second => 0, nanosecond => 0);
my $end = $start->clone->add(hours => 2);
my $events = DesertCMS::Events->new(config => $config, db => $db);
my $event = $events->save_event(
    title            => 'Community Workshop',
    slug             => 'community-workshop',
    summary          => 'A public workshop with RSVP and ticket options.',
    body             => "Bring questions.\nDoors open early.",
    status           => 'published',
    timezone         => 'UTC',
    starts_at        => $start->epoch,
    ends_at          => $end->epoch,
    location_enabled => 1,
    location_lat     => '34.101234',
    location_lng     => '-112.202345',
    location_label   => 'Civic Hall',
    location_kind    => 'venue',
    rsvp_enabled     => 1,
    rsvp_capacity    => 2,
    waitlist_enabled => 1,
    ticketing_enabled => 1,
);
$event = $events->publish_event($event->{id});
my $occurrence = $events->occurrences_for_event($event->{id}, limit => 5)->[0];
ok($occurrence->{id}, 'one-time event materializes an occurrence');
my $event_key = $occurrence->{occurrence_key};

my $free_ticket = $events->save_ticket_type(
    event_id    => $event->{id},
    name        => 'Free RSVP',
    description => 'Use RSVP for free admission.',
    price       => '0.00',
    capacity    => 2,
    active      => 1,
);
is($free_ticket->{price_cents}, 0, 'free ticket type is allowed');

my $paid_ticket = $events->save_ticket_type(
    event_id    => $event->{id},
    name        => 'General admission',
    description => 'Paid ticket for the workshop.',
    price       => '25.00',
    capacity    => 20,
    active      => 1,
    sort_order  => 20,
);
is($paid_ticket->{price_cents}, 2500, 'paid ticket type is stored in cents');

$content->rebuild_all;
ok(-f File::Spec->catfile($root, 'public', 'events', 'index.html'), 'events index is generated');
ok(-f File::Spec->catfile($root, 'public', 'events', 'community-workshop', 'index.html'), 'event landing page is generated');
ok(-f File::Spec->catfile($root, 'public', 'events', 'community-workshop', $event_key, 'index.html'), 'event occurrence URL is generated');
ok(-f File::Spec->catfile($root, 'public', 'events.ics'), 'events ICS feed is generated');

my $index_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($index_html, qr{href="/events/"}, 'enabled Events appears in public navigation');
like($index_html, qr{Community Calendar}, 'public navigation uses configured Events title');
my $events_html = _read(File::Spec->catfile($root, 'public', 'events', 'index.html'));
like($events_html, qr{Community Workshop}, 'events index renders event title');
like($events_html, qr{Subscribe with calendar}, 'events index links ICS feed');
my $detail_html = _read(File::Spec->catfile($root, 'public', 'events', 'community-workshop', $event_key, 'index.html'));
like($detail_html, qr{application/ld\+json}, 'event occurrence renders schema.org Event JSON');
like($detail_html, qr{Civic Hall}, 'event occurrence renders location label');
like($detail_html, qr{Send RSVP}, 'event occurrence renders RSVP form');
like($detail_html, qr{Buy ticket}, 'event occurrence renders paid ticket button when checkout is ready');
my $ics = _read(File::Spec->catfile($root, 'public', 'events.ics'));
like($ics, qr/BEGIN:VEVENT/, 'ICS feed contains an event');
like($ics, qr/SUMMARY:Community Workshop/, 'ICS feed includes event summary');
my $sitemap = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
like($sitemap, qr{https://events\.example\.test/events/</loc>}, 'sitemap includes events index');
like($sitemap, qr{https://events\.example\.test/events/community-workshop/</loc>}, 'sitemap includes event page');
like($sitemap, qr{https://events\.example\.test/events/community-workshop/\Q$event_key\E/</loc>}, 'sitemap includes occurrence URL');
my $map_data = decode_json(_read(File::Spec->catfile($root, 'public', 'assets', 'map-pins.json')));
my ($event_pin) = grep { ($_->{type} || '') eq 'event' } @{ $map_data->{pins} || [] };
ok($event_pin, 'event occurrence appears in map pin JSON');
is($event_pin->{kind}, 'venue', 'event map pin keeps location kind');
is($event_pin->{kind_label}, 'Venue', 'event map pin includes kind label');
is($event_pin->{url}, "/events/community-workshop/$event_key/", 'event map pin links to occurrence URL');

my $app = DesertCMS::App->new;
my $public_events = _capture_response(sub {
    $app->_dispatch_events(_event_request('/events'));
});
like($public_events, qr{Community Workshop}, 'public /events route renders event list');
my $public_detail = _capture_response(sub {
    $app->_dispatch_events(_event_request("/events/community-workshop/$event_key"));
});
like($public_detail, qr{class="event-action-panel"}, 'public event detail route renders action panels');

my $admin_html = _capture_response(sub {
    $app->_module_events_settings_page(undef, { username => 'admin', role => 'owner' }, 'events-session');
});
like($admin_html, qr/<h1>Events<\/h1>/, 'admin Events surface renders');
like($admin_html, qr/module-section-nav" aria-label="Events setup sections".*href="\#module-settings">Calendar Settings<\/a>.*href="\#module-events">Events<\/a>.*href="\#module-rsvps">RSVPs<\/a>.*href="\#module-orders">Ticket Orders<\/a>/s, 'admin Events surface exposes local section navigation');
like($admin_html, qr/content-table compact-table admin-card-table/, 'admin Events tables use responsive card table markup');
like($admin_html, qr/data-label="Event".*data-label="Actions"/s, 'admin Events rows expose mobile card labels');
my $event_form_html = _capture_response(sub {
    $app->_event_form(undef, { username => 'admin', role => 'owner' }, 'events-session');
});
like($event_form_html, qr/module-section-nav" aria-label="Event editor sections".*href="\#event-details">Details<\/a>.*href="\#event-dates">Date and Recurrence<\/a>.*href="\#event-location">Map \/ Location<\/a>.*href="\#event-rsvp">RSVP<\/a>.*href="\#event-tickets">Tickets<\/a>/s, 'admin Event editor exposes local section navigation');
like($event_form_html, qr/id="event-details".*id="event-dates".*id="event-location".*id="event-rsvp".*id="event-tickets"/s, 'admin Event editor section navigation targets stable form anchors');

my $rsvp = $events->submit_rsvp(
    event_id      => $event->{id},
    occurrence_id => $occurrence->{id},
    name          => 'First Guest',
    email         => 'first@example.test',
    guest_count   => 2,
);
is($rsvp->{status}, 'confirmed', 'RSVP confirms guests within capacity');
is($rsvp->{notification_status}, 'skipped', 'RSVP records skipped notification when Postmark notifications are disabled');
my $waitlist = $events->submit_rsvp(
    event_id      => $event->{id},
    occurrence_id => $occurrence->{id},
    name          => 'Overflow Guest',
    email         => 'overflow@example.test',
    guest_count   => 1,
);
is($waitlist->{status}, 'waitlist', 'RSVP waitlists guests over capacity');
my $bad_rsvp = eval {
    $events->submit_rsvp(
        event_id      => $event->{id},
        occurrence_id => $occurrence->{id},
        name          => 'Bad Email',
        email         => 'not-an-email',
        guest_count   => 1,
    );
    1;
};
ok(!$bad_rsvp, 'RSVP rejects invalid email');

my $daily_start = $start->clone->add(days => 30)->set(hour => 10);
my $daily = $events->save_event(
    title       => 'Daily Pop-up',
    summary     => 'Daily recurrence.',
    status      => 'published',
    timezone    => 'UTC',
    starts_at   => $daily_start->epoch,
    ends_at     => $daily_start->clone->add(hours => 1)->epoch,
    rrule       => 'FREQ=DAILY;COUNT=3',
    rdate_text  => $daily_start->clone->add(days => 5)->epoch,
    exdate_text => $daily_start->clone->add(days => 1)->epoch,
);
my @daily_keys = map { $_->{occurrence_key} } @{ $events->occurrences_for_event($daily->{id}, limit => 10) };
is_deeply(\@daily_keys, [
    _key($daily_start),
    _key($daily_start->clone->add(days => 2)),
    _key($daily_start->clone->add(days => 5)),
], 'daily RRULE respects COUNT, RDATE, and EXDATE');

my $weekly = $events->save_event(
    title     => 'Weekly Meetup',
    summary   => 'Weekly recurrence.',
    status    => 'published',
    timezone  => 'UTC',
    starts_at => $daily_start->clone->add(days => 10)->epoch,
    ends_at   => $daily_start->clone->add(days => 10, hours => 1)->epoch,
    rrule     => 'FREQ=WEEKLY;COUNT=2;BYDAY=' . _weekday_code($daily_start->clone->add(days => 10)),
);
is(scalar @{ $events->occurrences_for_event($weekly->{id}, limit => 10) }, 2, 'weekly RRULE materializes expected occurrence count');

my $monthly = $events->save_event(
    title     => 'Monthly Open Studio',
    summary   => 'Monthly recurrence.',
    status    => 'published',
    timezone  => 'UTC',
    starts_at => $daily_start->clone->add(days => 20)->epoch,
    ends_at   => $daily_start->clone->add(days => 20, hours => 1)->epoch,
    rrule     => 'FREQ=MONTHLY;COUNT=2',
);
is(scalar @{ $events->occurrences_for_event($monthly->{id}, limit => 10) }, 2, 'monthly RRULE materializes expected occurrence count');

my $yearly = $events->save_event(
    title     => 'Annual Festival',
    summary   => 'Yearly recurrence.',
    status    => 'published',
    timezone  => 'UTC',
    starts_at => $daily_start->clone->add(days => 40)->epoch,
    ends_at   => $daily_start->clone->add(days => 40, hours => 2)->epoch,
    rrule     => 'FREQ=YEARLY;COUNT=2',
);
is(scalar @{ $events->occurrences_for_event($yearly->{id}, limit => 10) }, 2, 'yearly RRULE materializes expected occurrence count');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        events => 1,
        event_payments => 0,
    }),
    commerce_model => 'disabled',
});
$events = DesertCMS::Events->new(config => $config, db => $db);
ok($events->enabled, 'catalog/calendar stays enabled when Event Payments is locked');
ok(!$events->event_payments_allowed_by_plan, 'event_payments can be locked independently');
ok(!$events->checkout_ready, 'locked Event Payments keeps checkout unavailable');
my $locked_checkout = eval {
    $events->create_checkout(
        event_id       => $event->{id},
        occurrence_id  => $occurrence->{id},
        ticket_type_id => $paid_ticket->{id},
        quantity       => 1,
    );
    1;
};
ok(!$locked_checkout, 'locked Event Payments rejects direct checkout');
like($@, qr/Event Payments/, 'locked Event Payments error is explicit');
my $locked_detail = _capture_response(sub {
    my $locked_app = DesertCMS::App->new;
    $locked_app->_dispatch_events(_event_request("/events/community-workshop/$event_key"));
});
like($locked_detail, qr/Paid tickets are not available on this plan or payment setup/, 'locked public event page hides checkout controls behind upgrade/readiness copy');
unlike($locked_detail, qr{<button type="submit">Buy ticket</button>}, 'locked public event page omits buy ticket button');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        events => 1,
        event_payments => 1,
    }),
    commerce_model => 'master_owned',
    stripe_secret_key => 'sk_test_events',
    stripe_webhook_secret => 'whsec_events',
});
my $http = Local::StripeHTTP->new;
$events = DesertCMS::Events->new(config => $config, db => $db, http => $http);
ok($events->checkout_ready, 'payment-enabled event checkout is ready');
my $checkout = $events->create_checkout(
    event_id       => $event->{id},
    occurrence_id  => $occurrence->{id},
    ticket_type_id => $paid_ticket->{id},
    quantity       => 2,
    customer_email => 'buyer@example.test',
);
is($checkout->{url}, 'https://checkout.stripe.com/c/pay/cs_test_events', 'paid event checkout returns Stripe Checkout URL');
is(scalar @{ $http->{posts} }, 1, 'paid event checkout posts one Stripe request');
is($http->{posts}[0]{args}{headers}{Authorization}, 'Basic ' . encode_base64('sk_test_events:', ''), 'paid event checkout uses configured Stripe key');
like($http->{posts}[0]{args}{content}, qr/metadata%5Bevent_order_id%5D=/, 'paid event checkout records event order metadata');
like($http->{posts}[0]{args}{content}, qr/success_url=https%3A%2F%2Fevents\.example\.test%2Fevents%2Fcommunity-workshop%2F\Q$event_key\E%2Fsuccess%3Forder%3D/, 'paid event checkout uses event occurrence success URL');

my $order = $events->order($checkout->{order_id});
is($order->{status}, 'pending', 'event ticket order starts pending');
my $payload = encode_json({
    id   => 'evt_event_paid',
    type => 'checkout.session.completed',
    data => {
        object => {
            id                  => 'cs_test_events',
            client_reference_id => $checkout->{order_id},
            payment_status      => 'paid',
            amount_total        => 5000,
            currency            => 'usd',
            payment_intent      => 'pi_event_paid',
            metadata            => {
                event_order_id => $checkout->{order_id},
                event_id       => $event->{id},
                occurrence_id  => $occurrence->{id},
                ticket_type_id => $paid_ticket->{id},
            },
            customer_details => {
                email => 'buyer@example.test',
                name  => 'Ticket Buyer',
            },
        },
    },
});
my $signature = DesertCMS::Events->webhook_signature_header(
    payload => $payload,
    secret  => 'whsec_events',
);
my $webhook = $events->handle_webhook(payload => $payload, signature => $signature);
ok($webhook->{ok}, 'event webhook accepts valid signed Stripe payload');
$order = $events->order($checkout->{order_id});
is($order->{status}, 'paid', 'event webhook marks ticket order paid');
is($order->{customer_email}, 'buyer@example.test', 'event webhook records buyer email');
my ($ticket_rsvp_count) = $db->dbh->selectrow_array(
    'SELECT COUNT(*) FROM event_rsvps WHERE notes LIKE ?',
    undef,
    '%ticket order #' . int($checkout->{order_id}) . '%'
);
is($ticket_rsvp_count, 1, 'paid ticket webhook creates confirmed attendee record');
my $duplicate = $events->handle_webhook(payload => $payload, signature => $signature);
ok($duplicate->{duplicate}, 'duplicate event webhook is idempotent');

my $contrib_root = tempdir(CLEANUP => 1);
$contrib_root =~ s{\\}{/}g;
make_path("$contrib_root/public", "$contrib_root/originals", "$contrib_root/backups", "$contrib_root/admin-assets", "$contrib_root/data", "$contrib_root/themes");
my $contrib_config_path = "$contrib_root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Events
site_url = https://events-seller.example.test
data_dir = $contrib_root/data
db_path = $contrib_root/data/desertcms.sqlite
app_secret_file = $contrib_root/data/app_secret
public_root = $contrib_root/public
originals_dir = $contrib_root/originals
backup_dir = $contrib_root/backups
theme_dir = $contrib_root/themes
admin_asset_dir = $contrib_root/admin-assets
secure_cookies = 0
contributor_site_id = events-seller
contributor_domain = events-seller.example.test
master_config_path = $config_path
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
my $contrib_db = DesertCMS::DB->new(config => $contrib_config);
$contrib_db->migrate;
DesertCMS::Settings::set_many($contrib_config, $contrib_db, {
    module_events_enabled => 1,
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        events => 1,
        event_payments => 1,
    }),
    commerce_model => 'platform_marketplace',
    contributor_allow_stripe_connect => 1,
    contributor_platform_fee_bps => 1250,
    stripe_connect_account_id => 'acct_events123',
});
my $seller_events = DesertCMS::Events->new(config => $contrib_config, db => $contrib_db, http => Local::StripeHTTP->new(id => 'cs_test_event_marketplace'));
my $seller_start = $start->clone->add(days => 60);
my $seller_event = $seller_events->save_event(
    title       => 'Seller Class',
    status      => 'published',
    timezone    => 'UTC',
    starts_at   => $seller_start->epoch,
    ends_at     => $seller_start->clone->add(hours => 2)->epoch,
    ticketing_enabled => 1,
);
$seller_event = $seller_events->publish_event($seller_event->{id});
my $seller_occurrence = $seller_events->occurrences_for_event($seller_event->{id}, limit => 1)->[0];
my $seller_ticket = $seller_events->save_ticket_type(
    event_id => $seller_event->{id},
    name     => 'Seat',
    price    => '75.00',
    active   => 1,
);
my $seller_checkout = $seller_events->create_checkout(
    event_id       => $seller_event->{id},
    occurrence_id  => $seller_occurrence->{id},
    ticket_type_id => $seller_ticket->{id},
    quantity       => 1,
);
ok($seller_checkout->{order_id}, 'contributor marketplace event checkout creates an order');
is($seller_events->{http}{posts}[0]{args}{headers}{Authorization}, 'Basic ' . encode_base64('sk_test_events:', ''), 'contributor marketplace event checkout uses inherited master Stripe key');
like($seller_events->{http}{posts}[0]{args}{content}, qr/payment_intent_data%5Btransfer_data%5D%5Bdestination%5D=acct_events123/, 'contributor marketplace event checkout routes proceeds to connected account');
like($seller_events->{http}{posts}[0]{args}{content}, qr/payment_intent_data%5Bapplication_fee_amount%5D=938/, 'contributor marketplace event checkout adds platform application fee');

done_testing;

sub _event_request {
    my ($path, $method, $form) = @_;
    return bless {
        method => $method || 'GET',
        path   => $path || '/events',
        host   => 'events.example.test',
        form   => $form || {},
        query  => {},
    }, 'DesertCMS::HTTP';
}

sub _key {
    my ($dt) = @_;
    return sprintf '%04d-%02d-%02d', $dt->year, $dt->month, $dt->day;
}

sub _weekday_code {
    my ($dt) = @_;
    return qw(MO TU WE TH FR SA SU)[$dt->day_of_week - 1];
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
