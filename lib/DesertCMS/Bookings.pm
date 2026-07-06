package DesertCMS::Bookings;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(encode_base64);
use DesertCMS::Commerce;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Email qw(send_postmark);
use DesertCMS::HTTP ();
use DesertCMS::Media;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Util qw(
    constant_time_eq escape_html hmac_sha256_hex now slugify
);

my %SERVICE_KIND = map { $_ => 1 } qw(
    appointment consultation project rental venue creative_session other
);

my %LOCATION_KIND = map { $_ => 1 } qw(
    store venue project historical_site event_location service_area other
);

my %SERVICE_STATUS = map { $_ => 1 } qw(draft published archived);
my %REQUEST_STATUS = map { $_ => 1 } qw(new reviewing accepted declined canceled completed);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
        http   => $args{http} || HTTP::Tiny->new(timeout => 15, verify_SSL => 1),
    }, $class;
}

sub enabled {
    my ($self) = @_;
    return DesertCMS::Modules::enabled(_settings($self), 'bookings');
}

sub booking_payments_allowed_by_plan {
    my ($self) = @_;
    return _plan_feature_enabled(_settings($self), 'booking_payments', 1);
}

sub payment_model {
    my ($self) = @_;
    my $settings = _settings($self);
    my $explicit = DesertCMS::Commerce::normalize_model($settings->{commerce_model} || $self->{config}->get('commerce_model') || '');
    return $explicit if length $explicit;
    return 'disabled' unless $self->booking_payments_allowed_by_plan;
    if (DesertCMS::Commerce::is_contributor_instance($self->{config})) {
        return _truthy($settings->{contributor_allow_stripe_connect}) ? 'platform_marketplace' : 'disabled';
    }
    return 'master_owned';
}

sub checkout_ready {
    my ($self) = @_;
    return $self->payment_readiness->{checkout_enabled} ? 1 : 0;
}

sub payment_readiness {
    my ($self) = @_;
    my $settings = _settings($self);
    my $bookings_enabled = $self->enabled;
    my $allowed = $self->booking_payments_allowed_by_plan;
    my $model = $self->payment_model;
    my $model_allows = DesertCMS::Commerce::model_allows_checkout($model);
    my $marketplace = $model eq 'platform_marketplace' ? 1 : 0;
    my $stripe_key = length($settings->{stripe_secret_key} || '') ? 1 : 0;
    my $webhook = length($settings->{stripe_webhook_secret} || '') ? 1 : 0;
    my $connect_account = length($settings->{stripe_connect_account_id} || '') ? 1 : 0;
    my $connect_allowed = $allowed && _truthy($settings->{contributor_allow_stripe_connect}) ? 1 : 0;

    my ($state, $label, $summary) = ('neutral', 'Disabled', 'Booking deposits are disabled.');
    if (!$bookings_enabled) {
        ($state, $label, $summary) = ('neutral', 'Bookings disabled', 'Enable Bookings before accepting appointment requests or deposits.');
    } elsif (!$allowed) {
        ($state, $label, $summary) = ('warn', 'Deposits locked', 'Booking requests are available; Stripe deposits require Booking Deposits.');
    } elsif (!$model_allows || $model eq 'disabled') {
        ($state, $label, $summary) = ('neutral', 'Deposits disabled', 'Select a checkout-capable commerce model before taking deposits.');
    } elsif ($marketplace && !$connect_allowed) {
        ($state, $label, $summary) = ('warn', 'Plan locked', 'This plan does not include contributor payout setup.');
    } elsif (!$stripe_key || !$webhook) {
        ($state, $label, $summary) = ('warn', 'Needs Stripe', $marketplace ? 'Marketplace booking deposits need inherited master Stripe credentials and webhook secret.' : 'Booking deposits need both a Stripe secret key and webhook secret.');
    } elsif ($marketplace && !$connect_account) {
        ($state, $label, $summary) = ('warn', 'Connect payouts', 'Connect a Stripe payout account before this site can take booking deposits.');
    } else {
        ($state, $label, $summary) = ('ok', 'Ready', $marketplace ? 'Booking deposit checkout is ready for platform marketplace payouts.' : 'Booking deposit checkout is ready.');
    }

    return {
        state            => $state,
        label            => $label,
        summary          => $summary,
        model            => $model,
        checkout_allowed => $allowed ? 1 : 0,
        checkout_enabled => ($bookings_enabled && $allowed && $model_allows && $stripe_key && $webhook && (!$marketplace || $connect_account)) ? 1 : 0,
        marketplace      => $marketplace,
        stripe_ready     => ($stripe_key && $webhook) ? 1 : 0,
        connect_account  => $connect_account,
    };
}

sub list_admin {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT s.*,
                   COUNT(r.id) AS request_count,
                   MAX(r.created_at) AS latest_request_at
            FROM booking_services s
            LEFT JOIN booking_requests r ON r.service_id = s.id
            WHERE s.deleted_at IS NULL
            GROUP BY s.id
            ORDER BY
                CASE s.status WHEN 'published' THEN 0 WHEN 'draft' THEN 1 ELSE 2 END,
                s.featured DESC,
                s.sort_order ASC,
                s.updated_at DESC,
                s.id DESC
        },
        { Slice => {} }
    );
}

sub published_services {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 500);
    $limit = 500 if $limit < 1 || $limit > 2000;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT *
            FROM booking_services
            WHERE status = 'published'
              AND deleted_at IS NULL
            ORDER BY featured DESC, sort_order ASC, title ASC, id ASC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub get_service {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM booking_services WHERE id = ? AND deleted_at IS NULL',
        undef,
        $id
    );
}

sub service_by_slug {
    my ($self, $slug) = @_;
    $slug = _slug($slug);
    return undef unless length $slug;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM booking_services
            WHERE slug = ?
              AND status = 'published'
              AND deleted_at IS NULL
            LIMIT 1
        },
        undef,
        $slug
    );
}

sub save_service {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $title = _text($args{title}, 180);
    die "booking service title is required" unless length $title;
    my $slug = _unique_service_slug($self->{db}->dbh, _slug($args{slug}) || slugify($title), $id);
    my $status = _service_status($args{status});
    my $now = now();
    my %row = (
        service_kind         => _service_kind($args{service_kind}),
        title                => $title,
        slug                 => $slug,
        status               => $status,
        summary              => _text($args{summary}, 500),
        body                 => _body($args{body}, 8000),
        image_path           => _image_path($args{image_path}),
        availability_text    => _body($args{availability_text}, 2000),
        duration_minutes     => _int($args{duration_minutes}, 0, 0, 10080),
        price_note           => _text($args{price_note}, 300),
        deposit_enabled      => _bool($args{deposit_enabled}),
        deposit_label        => _text($args{deposit_label}, 80) || 'Deposit',
        deposit_amount_cents => _price_cents($args{deposit_amount} || $args{deposit_amount_cents}),
        deposit_currency     => _currency($args{deposit_currency}),
        featured             => _bool($args{featured}),
        sort_order           => _int($args{sort_order}, 100, 0, 100000),
        location_enabled     => _bool($args{location_enabled}),
        location_lat         => _coordinate($args{location_lat}, -90, 90),
        location_lng         => _coordinate($args{location_lng}, -180, 180),
        location_label       => _text($args{location_label}, 300),
        location_kind        => _location_kind($args{location_kind} || 'service_area'),
    );
    $row{location_enabled} = 0 unless defined $row{location_lat} && defined $row{location_lng};
    $row{deposit_enabled} = 0 unless $row{deposit_amount_cents} > 0;
    my $published_at = $status eq 'published'
        ? (int($args{published_at} || 0) || $now)
        : undef;

    my $dbh = $self->{db}->dbh;
    if ($id > 0 && $self->get_service($id)) {
        $dbh->do(
            q{
                UPDATE booking_services
                SET service_kind = ?, title = ?, slug = ?, status = ?, summary = ?, body = ?,
                    image_path = ?, availability_text = ?, duration_minutes = ?, price_note = ?,
                    deposit_enabled = ?, deposit_label = ?, deposit_amount_cents = ?, deposit_currency = ?,
                    featured = ?, sort_order = ?, location_enabled = ?, location_lat = ?, location_lng = ?,
                    location_label = ?, location_kind = ?, updated_at = ?,
                    published_at = CASE WHEN ? = 'published' AND published_at IS NULL THEN ? ELSE published_at END
                WHERE id = ?
            },
            undef,
            @row{qw(
                service_kind title slug status summary body image_path availability_text duration_minutes price_note
                deposit_enabled deposit_label deposit_amount_cents deposit_currency featured sort_order
                location_enabled location_lat location_lng location_label location_kind
            )},
            $now,
            $status,
            $now,
            $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO booking_services
                    (service_kind, title, slug, status, summary, body, image_path,
                     availability_text, duration_minutes, price_note, deposit_enabled,
                     deposit_label, deposit_amount_cents, deposit_currency, featured, sort_order,
                     location_enabled, location_lat, location_lng, location_label, location_kind,
                     created_at, updated_at, published_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            @row{qw(
                service_kind title slug status summary body image_path availability_text duration_minutes price_note
                deposit_enabled deposit_label deposit_amount_cents deposit_currency featured sort_order
                location_enabled location_lat location_lng location_label location_kind
            )},
            $now,
            $now,
            $published_at
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->get_service($id);
}

sub publish_service {
    my ($self, $id) = @_;
    my $service = $self->get_service($id) or die "booking service not found";
    $self->{db}->dbh->do(
        q{
            UPDATE booking_services
            SET status = 'published',
                published_at = COALESCE(published_at, ?),
                updated_at = ?
            WHERE id = ?
        },
        undef,
        now(),
        now(),
        int($id || 0)
    );
    return $self->get_service($id);
}

sub archive_service {
    my ($self, $id) = @_;
    my $service = $self->get_service($id) or die "booking service not found";
    $self->{db}->dbh->do(
        q{
            UPDATE booking_services
            SET status = 'archived',
                deleted_at = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        now(),
        now(),
        int($id || 0)
    );
    return $service;
}

sub requests {
    my ($self, %args) = @_;
    my @where = ('1 = 1');
    my @bind;
    if ($args{service_id}) {
        push @where, 'r.service_id = ?';
        push @bind, int($args{service_id});
    }
    my $limit = int($args{limit} || 200);
    $limit = 200 if $limit < 1 || $limit > 1000;
    return $self->{db}->dbh->selectall_arrayref(
        'SELECT r.*, s.title AS service_title, s.slug AS service_slug '
            . 'FROM booking_requests r JOIN booking_services s ON s.id = r.service_id '
            . 'WHERE ' . join(' AND ', @where)
            . " ORDER BY r.created_at DESC, r.id DESC LIMIT $limit",
        { Slice => {} },
        @bind
    );
}

sub request_by_id {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT r.*, s.title AS service_title, s.slug AS service_slug
            FROM booking_requests r
            JOIN booking_services s ON s.id = r.service_id
            WHERE r.id = ?
        },
        undef,
        $id
    );
}

sub submit_request {
    my ($self, %args) = @_;
    die "form rejected" if _text($args{website}, 100) ne '';
    my $settings = _settings($self);
    die "booking requests are not enabled" unless _truthy($settings->{bookings_requests_enabled});
    my $service = $self->get_service($args{service_id}) or die "booking service not found";
    die "booking service is not published" unless ($service->{status} || '') eq 'published';

    my $name = _text($args{name}, 120);
    my $email = _email($args{email});
    my $phone = _text($args{phone}, 80);
    my $organization = _text($args{organization}, 160);
    my $requested_date = _date_text($args{requested_date});
    my $requested_time = _time_text($args{requested_time});
    my $preferred_window = _text($args{preferred_window}, 120);
    my $party_size = _optional_int($args{party_size}, 1, 100000);
    my $budget = _text($args{budget}, 80);
    my $notes = _body($args{notes}, 3000);

    die "Please enter your name." unless length $name;
    die "Please enter a valid email address." unless length $email;
    die "Please choose a requested date." unless length $requested_date;
    die "Please add booking notes." unless length $notes;

    my $ip = $args{ip_address} || ($args{request} ? DesertCMS::HTTP::client_ip($args{request}, $self->{config}) : '');
    my $ua = $args{user_agent} || ($args{request} ? ($args{request}->{user_agent} || '') : '');
    my $ip_hash = length($ip || '') ? hmac_sha256_hex('booking-request:ip:' . $ip, $self->{config}->app_secret) : '';
    $self->_rate_limit($ip_hash) if length $ip_hash;
    my $ua_hash = length($ua || '') ? hmac_sha256_hex('booking-request:ua:' . substr($ua, 0, 300), $self->{config}->app_secret) : '';
    my $deposit_required = $service->{deposit_enabled} && int($service->{deposit_amount_cents} || 0) > 0 ? 1 : 0;
    my $deposit_status = $deposit_required ? 'pending' : 'none';
    my $ts = now();

    $self->{db}->dbh->do(
        q{
            INSERT INTO booking_requests
                (service_id, status, name, email, phone, organization, requested_date,
                 requested_time, preferred_window, party_size, budget, notes,
                 deposit_required, deposit_status, ip_hash, user_agent_hash,
                 notification_status, notification_error, created_at, updated_at)
            VALUES (?, 'new', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', '', ?, ?)
        },
        undef,
        int($service->{id}),
        $name,
        $email,
        $phone,
        $organization,
        $requested_date,
        $requested_time,
        $preferred_window,
        $party_size,
        $budget,
        $notes,
        $deposit_required,
        $deposit_status,
        $ip_hash,
        $ua_hash,
        $ts,
        $ts
    );
    my $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    $self->_send_request_notification($id, $service);
    return $self->request_by_id($id);
}

sub update_request_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $status = _request_status($args{status});
    die "booking request id is required" unless $id > 0;
    $self->{db}->dbh->do(
        'UPDATE booking_requests SET status = ?, updated_at = ? WHERE id = ?',
        undef,
        $status,
        now(),
        $id
    );
    return $self->request_by_id($id);
}

sub create_deposit_checkout {
    my ($self, %args) = @_;
    die "Booking Deposits are not available on this plan or checkout is not ready"
        unless $self->checkout_ready;
    my $request = $self->request_by_id($args{request_id}) or die "booking request not found";
    my $service = $self->get_service($request->{service_id}) or die "booking service not found";
    die "booking service is not published" unless ($service->{status} || '') eq 'published';
    die "booking deposit is not enabled for this service"
        unless $service->{deposit_enabled} && int($service->{deposit_amount_cents} || 0) > 0;
    die "booking request cannot take a deposit in this status"
        if ($request->{status} || '') =~ /\A(?:declined|canceled|completed)\z/;

    my $settings = _settings($self);
    my $key = $settings->{stripe_secret_key} || '';
    die "Stripe secret key is not configured" unless length $key;
    my $model = $self->payment_model;
    my $amount = int($service->{deposit_amount_cents} || 0);
    my $currency = _currency($service->{deposit_currency});
    my $ts = now();
    my $dbh = $self->{db}->dbh;

    $dbh->do(
        q{
            INSERT INTO booking_payments
                (service_id, request_id, status, currency, amount_cents,
                 customer_email, customer_name, created_at, updated_at)
            VALUES (?, ?, 'pending', ?, ?, ?, ?, ?, ?)
        },
        undef,
        int($service->{id}),
        int($request->{id}),
        $currency,
        $amount,
        $request->{email} || '',
        $request->{name} || '',
        $ts,
        $ts
    );
    my $payment_id = int($dbh->sqlite_last_insert_rowid);
    $dbh->do(
        'UPDATE booking_requests SET deposit_payment_id = ?, deposit_status = ?, updated_at = ? WHERE id = ?',
        undef,
        $payment_id,
        'pending',
        now(),
        int($request->{id})
    );

    my $success_url = booking_url($self->{config}, $service, '/request/' . $payment_id . '/success?session_id={CHECKOUT_SESSION_ID}');
    my $cancel_url = booking_url($self->{config}, $service, '/request/' . $payment_id . '/cancel');
    my %form = (
        mode => 'payment',
        success_url => $success_url,
        cancel_url  => $cancel_url,
        'line_items[0][quantity]' => 1,
        'line_items[0][price_data][currency]' => $currency,
        'line_items[0][price_data][unit_amount]' => $amount,
        'line_items[0][price_data][product_data][name]' => ($service->{title} || 'Booking') . ' - ' . ($service->{deposit_label} || 'Deposit'),
        'line_items[0][price_data][product_data][description]' => _deposit_checkout_description($service, $request),
        'metadata[booking_payment_id]' => $payment_id,
        'metadata[booking_request_id]' => int($request->{id}),
        'metadata[booking_service_id]' => int($service->{id}),
        'metadata[desertcms_payment]' => 'booking_deposit',
    );
    $form{customer_email} = $request->{email} if length($request->{email} || '');
    if ($model eq 'platform_marketplace') {
        my $account_id = _stripe_connect_account_id($settings->{stripe_connect_account_id} || '');
        die "Stripe connected payout account is not configured" unless length $account_id;
        my $fee_cents = _platform_fee_cents($amount, $settings->{contributor_platform_fee_bps});
        $form{'payment_intent_data[transfer_data][destination]'} = $account_id;
        $form{'payment_intent_data[application_fee_amount]'} = $fee_cents if $fee_cents > 0;
        $form{'payment_intent_data[metadata][stripe_connect_account_id]'} = $account_id;
        $form{'metadata[stripe_connect_account_id]'} = $account_id;
    }

    my $response = $self->{http}->post(
        _stripe_api_base($settings),
        {
            headers => {
                Authorization  => 'Basic ' . encode_base64($key . ':', ''),
                'Content-Type' => 'application/x-www-form-urlencoded',
            },
            content => _form_encode(\%form),
        }
    );
    my $body = eval { decode_json($response->{content} || '{}') } || {};
    if (!$response->{success} || !$body->{id} || !$body->{url}) {
        $dbh->do('UPDATE booking_payments SET status = ?, updated_at = ? WHERE id = ?', undef, 'failed', now(), $payment_id);
        $dbh->do('UPDATE booking_requests SET deposit_status = ?, updated_at = ? WHERE id = ?', undef, 'failed', now(), int($request->{id}));
        die _stripe_error($body, $response, 'Stripe Checkout session could not be created');
    }
    $dbh->do(
        'UPDATE booking_payments SET stripe_checkout_session_id = ?, updated_at = ? WHERE id = ?',
        undef,
        $body->{id},
        now(),
        $payment_id
    );
    return {
        payment_id => $payment_id,
        session_id => $body->{id},
        url        => $body->{url},
    };
}

sub handle_webhook {
    my ($self, %args) = @_;
    my $payload = defined $args{payload} ? $args{payload} : '';
    my $signature = $args{signature} || '';
    my $secret = _settings($self)->{stripe_webhook_secret} || '';
    die "Stripe webhook secret is not configured" unless length $secret;
    _verify_signature(
        payload   => $payload,
        header    => $signature,
        secret    => $secret,
        tolerance => int(_settings($self)->{stripe_webhook_tolerance_seconds} || 300),
    );
    my $event = eval { decode_json($payload) };
    die "invalid Stripe webhook JSON" if $@ || ref $event ne 'HASH';
    my $event_id = $event->{id} || '';
    my $event_type = $event->{type} || '';
    die "Stripe event is missing an id" unless length $event_id;
    my ($seen) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM booking_stripe_events WHERE stripe_event_id = ?',
        undef,
        $event_id
    );
    return { ok => 1, duplicate => 1 } if $seen;
    my $object = $event->{data} && ref $event->{data} eq 'HASH' && $event->{data}{object} && ref $event->{data}{object} eq 'HASH'
        ? $event->{data}{object}
        : {};
    if ($event_type eq 'checkout.session.completed'
        || $event_type eq 'checkout.session.async_payment_succeeded') {
        $self->_mark_payment_paid($object, $event_id);
    } elsif ($event_type eq 'checkout.session.expired') {
        $self->_mark_payment_status($object, 'canceled', $event_id);
    } elsif ($event_type eq 'checkout.session.async_payment_failed') {
        $self->_mark_payment_status($object, 'failed', $event_id);
    }
    return { ok => 1, duplicate => 1 } unless $self->_record_stripe_event($event_id, $event_type);
    return { ok => 1, duplicate => 0, type => $event_type };
}

sub recent_payments {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 25);
    $limit = 25 if $limit < 1 || $limit > 200;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT p.*, s.title AS service_title, r.requested_date, r.requested_time
            FROM booking_payments p
            JOIN booking_services s ON s.id = p.service_id
            LEFT JOIN booking_requests r ON r.id = p.request_id
            ORDER BY p.created_at DESC, p.id DESC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub payment_by_id {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT p.*, s.title AS service_title, s.slug AS service_slug
            FROM booking_payments p
            JOIN booking_services s ON s.id = p.service_id
            WHERE p.id = ?
        },
        undef,
        $id
    );
}

sub csv_export {
    my ($self) = @_;
    my @headers = qw(id status service_title name email phone organization requested_date requested_time preferred_window party_size budget deposit_status created_at);
    my $csv = join(',', map { _csv($_) } @headers) . "\n";
    for my $row (@{ $self->requests(limit => 1000) }) {
        $csv .= join(',', map { _csv($row->{$_}) } @headers) . "\n";
    }
    return $csv;
}

sub service_kind_label {
    my ($kind) = @_;
    my %labels = (
        appointment      => 'Appointment',
        consultation     => 'Consultation',
        project          => 'Project',
        rental           => 'Rental',
        venue            => 'Venue',
        creative_session => 'Creative session',
        other            => 'Other',
    );
    return $labels{_service_kind($kind)} || 'Appointment';
}

sub service_kinds {
    return [ qw(appointment consultation project rental venue creative_session other) ];
}

sub request_status_label {
    my ($status) = @_;
    my %labels = (
        new       => 'New',
        reviewing => 'Reviewing',
        accepted  => 'Accepted',
        declined  => 'Declined',
        canceled  => 'Canceled',
        completed => 'Completed',
    );
    return $labels{_request_status($status)} || 'New';
}

sub request_statuses {
    return [ qw(new reviewing accepted declined canceled completed) ];
}

sub price_label {
    my ($cents, $currency) = @_;
    $cents = int($cents || 0);
    $currency = uc(_currency($currency));
    return 'Free' if $cents <= 0;
    return sprintf('%s %.2f', $currency, $cents / 100);
}

sub booking_url {
    my ($config, $service, $suffix) = @_;
    my $base = $config->get('site_url') || '';
    $base =~ s{/+\z}{};
    my $slug = $service && length($service->{slug} || '') ? $service->{slug} : '';
    my $path = '/bookings/' . $slug;
    $path .= '/' unless $path =~ m{/\z};
    $suffix ||= '';
    $suffix =~ s{\A/+}{};
    $path .= $suffix if length $suffix;
    return length($base) ? $base . $path : $path;
}

sub clear_settings_cache {
    my ($self) = @_;
    delete $self->{settings_cache};
    return 1;
}

sub _send_request_notification {
    my ($self, $id, $service) = @_;
    my $settings = _settings($self);
    my $ts = now();
    if (!_truthy($settings->{bookings_notify_postmark_enabled})) {
        return $self->_record_request_notification($id, 'skipped', 'Postmark notifications are disabled for Bookings', undef);
    }
    my $to = _email_optional($settings->{bookings_notification_email} || $settings->{forms_notification_email} || $settings->{contributor_request_recipient_email} || '');
    if (!length $to) {
        return $self->_record_request_notification($id, 'skipped', 'Booking notification recipient is not configured', undef);
    }
    my $row = $self->request_by_id($id) or return;
    my $site_name = $settings->{site_name} || $self->{config}->get('site_name') || 'DesertCMS';
    my $subject = 'New booking request: ' . ($service->{title} || 'Service');
    my $text = join "\n",
        "A new booking request was received on $site_name.",
        '',
        'Service: ' . ($service->{title} || ''),
        'Name: ' . ($row->{name} || ''),
        'Email: ' . ($row->{email} || ''),
        'Phone: ' . ($row->{phone} || ''),
        'Organization: ' . ($row->{organization} || ''),
        'Requested date: ' . ($row->{requested_date} || ''),
        'Requested time: ' . ($row->{requested_time} || ''),
        'Preferred window: ' . ($row->{preferred_window} || ''),
        'Party size: ' . (defined $row->{party_size} ? $row->{party_size} : ''),
        'Budget: ' . ($row->{budget} || ''),
        '',
        'Notes:',
        ($row->{notes} || '');
    my $html = '<p>A new booking request was received on ' . escape_html($site_name) . '.</p>'
        . '<ul><li><strong>Service:</strong> ' . escape_html($service->{title} || '') . '</li>'
        . '<li><strong>Name:</strong> ' . escape_html($row->{name} || '') . '</li>'
        . '<li><strong>Email:</strong> ' . escape_html($row->{email} || '') . '</li>'
        . '<li><strong>Phone:</strong> ' . escape_html($row->{phone} || '') . '</li>'
        . '<li><strong>Requested date:</strong> ' . escape_html($row->{requested_date} || '') . '</li>'
        . '<li><strong>Requested time:</strong> ' . escape_html($row->{requested_time} || '') . '</li>'
        . '<li><strong>Deposit:</strong> ' . escape_html($row->{deposit_status} || 'none') . '</li></ul>'
        . '<p>' . _html_multiline($row->{notes} || '') . '</p>';
    my ($sent, $reason) = send_postmark(
        $self->{config},
        $self->{db},
        to         => $to,
        email_type => 'booking_request',
        subject    => substr($subject, 0, 300),
        text_body  => $text,
        html_body  => $html,
    );
    my $status = $sent ? 'sent' : (($reason || '') =~ /not configured/i ? 'skipped' : 'failed');
    return $self->_record_request_notification($id, $status, $reason || '', $sent ? $ts : undef);
}

sub _record_request_notification {
    my ($self, $id, $status, $reason, $sent_at) = @_;
    $self->{db}->dbh->do(
        q{
            UPDATE booking_requests
            SET notification_status = ?,
                notification_error = ?,
                notification_sent_at = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        substr($status || '', 0, 40),
        substr($reason || '', 0, 1000),
        $sent_at,
        now(),
        int($id || 0)
    );
}

sub _rate_limit {
    my ($self, $ip_hash) = @_;
    my $since = now() - (10 * 60);
    my ($count) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM booking_requests
            WHERE ip_hash = ?
              AND created_at >= ?
        },
        undef,
        $ip_hash,
        $since
    );
    die "Too many booking requests were submitted recently. Please wait a few minutes and try again." if ($count || 0) >= 5;
}

sub _mark_payment_paid {
    my ($self, $session, $event_id) = @_;
    my $payment = $self->_payment_from_session($session) or die "matching booking payment not found";
    my $payment_status = $session->{payment_status} || '';
    die "Stripe Checkout session is not paid" if length $payment_status && $payment_status ne 'paid';
    _validate_paid_session($payment, $session);
    my $email = '';
    my $name = '';
    if ($session->{customer_details} && ref $session->{customer_details} eq 'HASH') {
        $email = _email_optional($session->{customer_details}{email} || '');
        $name = _text($session->{customer_details}{name}, 120);
    }
    my $payment_intent = _text($session->{payment_intent}, 160);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        $dbh->do(
            q{
                UPDATE booking_payments
                SET status = 'paid',
                    customer_email = CASE WHEN ? = '' THEN customer_email ELSE ? END,
                    customer_name = CASE WHEN ? = '' THEN customer_name ELSE ? END,
                    stripe_payment_intent_id = CASE WHEN ? = '' THEN stripe_payment_intent_id ELSE ? END,
                    stripe_event_id = ?,
                    paid_at = COALESCE(paid_at, ?),
                    updated_at = ?
                WHERE id = ?
            },
            undef,
            $email, $email,
            $name, $name,
            $payment_intent, $payment_intent,
            $event_id,
            $ts,
            $ts,
            int($payment->{id})
        );
        $dbh->do(
            q{
                UPDATE booking_requests
                SET deposit_status = 'paid',
                    deposit_payment_id = ?,
                    updated_at = ?
                WHERE id = ?
            },
            undef,
            int($payment->{id}),
            $ts,
            int($payment->{request_id} || 0)
        ) if $payment->{request_id};
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown booking payment update failure';
        eval { $dbh->rollback };
        die $err;
    };
}

sub _mark_payment_status {
    my ($self, $session, $status, $event_id) = @_;
    my $payment = $self->_payment_from_session($session) or return;
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            UPDATE booking_payments
            SET status = ?,
                stripe_event_id = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        $status,
        $event_id,
        $ts,
        int($payment->{id})
    );
    $self->{db}->dbh->do(
        'UPDATE booking_requests SET deposit_status = ?, updated_at = ? WHERE id = ?',
        undef,
        $status,
        $ts,
        int($payment->{request_id} || 0)
    ) if $payment->{request_id};
}

sub _payment_from_session {
    my ($self, $session) = @_;
    return undef unless $session && ref $session eq 'HASH';
    my $session_id = _text($session->{id}, 160);
    return undef unless length $session_id;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM booking_payments WHERE stripe_checkout_session_id = ?',
        undef,
        $session_id
    );
}

sub _record_stripe_event {
    my ($self, $event_id, $event_type) = @_;
    eval {
        $self->{db}->dbh->do(
            q{
                INSERT INTO booking_stripe_events (stripe_event_id, event_type, received_at)
                VALUES (?, ?, ?)
            },
            undef,
            $event_id,
            $event_type || '',
            now()
        );
        1;
    } ? 1 : 0;
}

sub _validate_paid_session {
    my ($payment, $session) = @_;
    my $session_id = _text($session->{id}, 160);
    if (length($session_id) && length($payment->{stripe_checkout_session_id} || '')) {
        die "Stripe Checkout session id does not match this booking payment"
            unless $session_id eq $payment->{stripe_checkout_session_id};
    }
    if (defined $session->{amount_total} && length "$session->{amount_total}") {
        die "Stripe amount does not match this booking payment"
            unless int($session->{amount_total}) == int($payment->{amount_cents} || 0);
    }
    if (defined $session->{currency} && length $session->{currency}) {
        die "Stripe currency does not match this booking payment"
            unless _currency($session->{currency}) eq _currency($payment->{currency});
    }
    my $metadata = $session->{metadata} && ref $session->{metadata} eq 'HASH'
        ? $session->{metadata}
        : {};
    _validate_metadata_int($metadata, 'booking_payment_id', $payment->{id});
    _validate_metadata_int($metadata, 'booking_request_id', $payment->{request_id}) if $payment->{request_id};
    _validate_metadata_int($metadata, 'booking_service_id', $payment->{service_id});
}

sub _validate_metadata_int {
    my ($metadata, $key, $expected) = @_;
    return unless defined $metadata->{$key} && length $metadata->{$key};
    die "Stripe metadata $key does not match this booking payment"
        unless int($metadata->{$key}) == int($expected || 0);
}

sub _settings {
    my ($self) = @_;
    if (!$self->{settings_cache}) {
        my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
        if (DesertCMS::Commerce::is_contributor_instance($self->{config})
            && ($settings->{commerce_model} || '') eq 'platform_marketplace') {
            my $master = _master_stripe_settings($self);
            for my $key (qw(stripe_secret_key stripe_webhook_secret stripe_api_base)) {
                $settings->{$key} = $master->{$key}
                    if $master && length($master->{$key} || '');
            }
        }
        $self->{settings_cache} = $settings;
    }
    return $self->{settings_cache};
}

sub _master_stripe_settings {
    my ($self) = @_;
    my $config = $self->{config};
    my $current = $config->get('path') || '';
    my $path = $config->get('master_config_path') || '';
    return undef unless length $path && (!$current || $path ne $current) && -f $path;
    return eval {
        my $master_config = DesertCMS::Config->load($path);
        my $master_db = DesertCMS::DB->new(config => $master_config);
        my $settings = DesertCMS::Settings::all($master_config, $master_db);
        {
            stripe_secret_key     => $settings->{stripe_secret_key} || $master_config->get('stripe_secret_key') || '',
            stripe_webhook_secret => $settings->{stripe_webhook_secret} || $master_config->get('stripe_webhook_secret') || '',
            stripe_api_base       => $settings->{stripe_api_base} || $master_config->get('stripe_api_base') || 'https://api.stripe.com/v1/checkout/sessions',
        };
    };
}

sub _unique_service_slug {
    my ($dbh, $base, $id) = @_;
    $base = _slug($base) || 'booking-service';
    my $slug = $base;
    my $i = 2;
    while (1) {
        my ($existing) = $dbh->selectrow_array(
            'SELECT id FROM booking_services WHERE slug = ? AND deleted_at IS NULL AND (? = 0 OR id <> ?) LIMIT 1',
            undef,
            $slug,
            int($id || 0),
            int($id || 0)
        );
        return $slug unless $existing;
        $slug = "$base-$i";
        $i++;
    }
}

sub _service_kind {
    my ($value) = @_;
    $value = lc($value || 'appointment');
    $value =~ s/[-\s]+/_/g;
    return $SERVICE_KIND{$value} ? $value : 'appointment';
}

sub _location_kind {
    my ($value) = @_;
    $value = lc($value || 'service_area');
    $value =~ s/[-\s]+/_/g;
    return $LOCATION_KIND{$value} ? $value : 'service_area';
}

sub _service_status {
    my ($value) = @_;
    $value = lc($value || 'draft');
    return $SERVICE_STATUS{$value} ? $value : 'draft';
}

sub _request_status {
    my ($value) = @_;
    $value = lc($value || 'new');
    return $REQUEST_STATUS{$value} ? $value : 'new';
}

sub _slug {
    my ($value) = @_;
    return slugify(_text($value, 160));
}

sub _text {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
    $value =~ s/^\s+|\s+\z//g;
    $max ||= 255;
    return substr($value, 0, $max);
}

sub _body {
    my ($value, $max) = @_;
    $value = _text($value, $max || 8000);
    return $value;
}

sub _email {
    my ($value) = @_;
    $value = lc _text($value, 180);
    return '' unless length $value;
    die "email address is invalid" unless $value =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/;
    return $value;
}

sub _email_optional {
    my ($value) = @_;
    $value = lc _text($value, 180);
    return '' unless length $value;
    return $value =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/ ? $value : '';
}

sub _image_path {
    my ($value) = @_;
    $value = _text($value, 300);
    return $value if DesertCMS::Media::is_public_image_path($value);
    return '';
}

sub _date_text {
    my ($value) = @_;
    $value = _text($value, 40);
    return '' unless length $value;
    die "requested date is invalid" unless $value =~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/;
    return $value;
}

sub _time_text {
    my ($value) = @_;
    $value = _text($value, 20);
    return '' unless length $value;
    die "requested time is invalid" unless $value =~ /\A[0-9]{2}:[0-9]{2}\z/;
    return $value;
}

sub _coordinate {
    my ($value, $min, $max) = @_;
    return undef unless defined $value && "$value" =~ /\S/;
    die "coordinate is invalid" unless "$value" =~ /\A-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/;
    my $n = 0 + $value;
    die "coordinate is out of range" if $n < $min || $n > $max;
    return $n;
}

sub _price_cents {
    my ($value) = @_;
    return 0 unless defined $value && "$value" =~ /\S/;
    return int($value) if "$value" =~ /\A[0-9]+\z/ && int($value) > 999;
    die "deposit amount is invalid" unless "$value" =~ /\A[0-9]+(?:\.[0-9]{1,2})?\z/;
    return int((0 + $value) * 100 + 0.5);
}

sub _currency {
    my ($value) = @_;
    $value = lc _text($value, 3);
    return $value =~ /\A[a-z]{3}\z/ ? $value : 'usd';
}

sub _optional_int {
    my ($value, $min, $max) = @_;
    return undef unless defined $value && "$value" =~ /\S/;
    return undef unless "$value" =~ /\A[0-9]+\z/;
    my $n = int($value);
    $n = $min if defined $min && $n < $min;
    $n = $max if defined $max && $n > $max;
    return $n;
}

sub _int {
    my ($value, $default, $min, $max) = @_;
    $value = defined $value && "$value" =~ /\A-?[0-9]+\z/ ? int($value) : $default;
    $value = $min if defined $min && $value < $min;
    $value = $max if defined $max && $value > $max;
    return $value;
}

sub _bool {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _truthy {
    return _bool(@_);
}

sub _plan_feature_enabled {
    my ($settings, $key, $default) = @_;
    my $json = $settings->{contributor_plan_features_json} || '';
    return $default ? 1 : 0 unless length $json;
    my $decoded = eval { decode_json($json) };
    return $default ? 1 : 0 unless $decoded && ref $decoded eq 'HASH';
    return _truthy($decoded->{$key}) ? 1 : 0;
}

sub _platform_fee_cents {
    my ($amount, $bps) = @_;
    $amount = int($amount || 0);
    $bps = int($bps || 0);
    return 0 if $amount <= 0 || $bps <= 0;
    $bps = 5000 if $bps > 5000;
    return int(($amount * $bps) / 10000);
}

sub _stripe_connect_account_id {
    my ($value) = @_;
    $value = _text($value, 120);
    return $value =~ /\Aacct_[A-Za-z0-9_]+\z/ ? $value : '';
}

sub _stripe_api_base {
    my ($settings) = @_;
    return $settings->{stripe_api_base} || 'https://api.stripe.com/v1/checkout/sessions';
}

sub _stripe_error {
    my ($body, $response, $fallback) = @_;
    return $body->{error}{message}
        if $body && ref $body eq 'HASH' && $body->{error} && ref $body->{error} eq 'HASH' && $body->{error}{message};
    return $response->{reason} if $response && $response->{reason};
    return $fallback || 'Stripe request failed';
}

sub _deposit_checkout_description {
    my ($service, $request) = @_;
    my @parts = (
        'Booking request #' . int($request->{id} || 0),
        $request->{requested_date} || '',
        $request->{requested_time} || '',
    );
    return join ' ', grep { length } @parts;
}

sub _form_encode {
    my ($values) = @_;
    return join '&', map {
        _url_encode($_) . '=' . _url_encode($values->{$_})
    } sort keys %{$values || {}};
}

sub _url_encode {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/eg;
    return $value;
}

sub _verify_signature {
    my (%args) = @_;
    my $payload = $args{payload} || '';
    my $header = $args{header} || '';
    my $secret = $args{secret} || '';
    my $tolerance = int($args{tolerance} || 300);
    my ($timestamp) = $header =~ /(?:\A|,)t=([0-9]+)/;
    my @signatures = $header =~ /(?:\A|,)v1=([0-9a-f]+)/ig;
    die "Stripe-Signature header is missing required values"
        unless $timestamp && @signatures;
    die "Stripe webhook timestamp is outside the tolerance window"
        if $tolerance > 0 && abs(now() - $timestamp) > $tolerance;
    my $expected = hmac_sha256_hex($timestamp . '.' . $payload, $secret);
    for my $signature (@signatures) {
        return 1 if constant_time_eq(lc($signature), $expected);
    }
    die "Stripe webhook signature verification failed";
}

sub _html_multiline {
    my ($value) = @_;
    my $safe = escape_html($value || '');
    $safe =~ s/\n/<br>/g;
    return $safe;
}

sub _csv {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

1;
