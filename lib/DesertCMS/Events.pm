package DesertCMS::Events;

use strict;
use warnings;
use DesertCMS::DateTimeLite;
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

my %LOCATION_KINDS = map { $_ => 1 } qw(
    store venue project historical_site event_location service_area other
);
my %WEEKDAY = (
    MO => 1,
    TU => 2,
    WE => 3,
    TH => 4,
    FR => 5,
    SA => 6,
    SU => 7,
);

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
    return DesertCMS::Modules::enabled(_settings($self), 'events');
}

sub event_payments_allowed_by_plan {
    my ($self) = @_;
    return _plan_feature_enabled(_settings($self), 'event_payments', 1);
}

sub payment_model {
    my ($self) = @_;
    my $settings = _settings($self);
    my $explicit = DesertCMS::Commerce::normalize_model($settings->{commerce_model} || $self->{config}->get('commerce_model') || '');
    return $explicit if length $explicit;
    return 'disabled' unless $self->event_payments_allowed_by_plan;
    if (DesertCMS::Commerce::is_contributor_instance($self->{config})) {
        return _truthy($settings->{contributor_allow_stripe_connect}) ? 'platform_marketplace' : 'disabled';
    }
    return 'master_owned';
}

sub checkout_ready {
    my ($self) = @_;
    my $state = $self->payment_readiness;
    return $state->{checkout_enabled} ? 1 : 0;
}

sub payment_readiness {
    my ($self) = @_;
    my $settings = _settings($self);
    my $events_enabled = $self->enabled;
    my $allowed = $self->event_payments_allowed_by_plan;
    my $model = $self->payment_model;
    my $model_allows = DesertCMS::Commerce::model_allows_checkout($model);
    my $marketplace = $model eq 'platform_marketplace' ? 1 : 0;
    my $stripe_key = length($settings->{stripe_secret_key} || '') ? 1 : 0;
    my $webhook = length($settings->{stripe_webhook_secret} || '') ? 1 : 0;
    my $connect_account = length($settings->{stripe_connect_account_id} || '') ? 1 : 0;
    my $connect_allowed = $allowed && _truthy($settings->{contributor_allow_stripe_connect}) ? 1 : 0;

    my ($state, $label, $summary) = ('neutral', 'Disabled', 'Paid tickets are disabled.');
    if (!$events_enabled) {
        ($state, $label, $summary) = ('neutral', 'Events disabled', 'Enable Events before taking RSVPs or tickets.');
    } elsif (!$allowed) {
        ($state, $label, $summary) = ('warn', 'Payments locked', 'Calendar pages and RSVP are available; paid tickets require Event Payments.');
    } elsif (!$model_allows || $model eq 'disabled') {
        ($state, $label, $summary) = ('neutral', 'Payments disabled', 'Select a checkout-capable commerce model before selling tickets.');
    } elsif ($marketplace && !$connect_allowed) {
        ($state, $label, $summary) = ('warn', 'Plan locked', 'This plan does not include contributor payout setup.');
    } elsif (!$stripe_key || !$webhook) {
        ($state, $label, $summary) = ('warn', 'Needs Stripe', $marketplace ? 'Marketplace ticketing needs inherited master Stripe credentials and webhook secret.' : 'Paid tickets need both a Stripe secret key and webhook secret.');
    } elsif ($marketplace && !$connect_account) {
        ($state, $label, $summary) = ('warn', 'Connect payouts', 'Connect a Stripe payout account before this site can sell tickets.');
    } else {
        ($state, $label, $summary) = ('ok', 'Ready', $marketplace ? 'Event ticket checkout is ready for platform marketplace payouts.' : 'Event ticket checkout is ready.');
    }

    return {
        state            => $state,
        label            => $label,
        summary          => $summary,
        model            => $model,
        checkout_allowed => $allowed ? 1 : 0,
        checkout_enabled => ($events_enabled && $allowed && $model_allows && $stripe_key && $webhook && (!$marketplace || $connect_account)) ? 1 : 0,
        marketplace      => $marketplace,
        stripe_ready     => ($stripe_key && $webhook) ? 1 : 0,
        connect_account  => $connect_account,
    };
}

sub list_admin {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT e.*,
                   MIN(CASE WHEN o.active = 1 THEN o.starts_at END) AS next_occurrence_at,
                   COUNT(DISTINCT CASE WHEN o.active = 1 THEN o.id END) AS occurrence_count
            FROM events e
            LEFT JOIN event_occurrences o ON o.event_id = e.id
            WHERE e.deleted_at IS NULL
            GROUP BY e.id
            ORDER BY COALESCE(next_occurrence_at, e.starts_at) DESC, e.updated_at DESC, e.id DESC
        },
        { Slice => {} }
    );
}

sub published_events {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM events
            WHERE status = 'published'
              AND deleted_at IS NULL
            ORDER BY starts_at ASC, id ASC
        },
        { Slice => {} }
    );
}

sub get {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM events WHERE id = ? AND deleted_at IS NULL',
        undef,
        $id
    );
}

sub by_slug {
    my ($self, $slug) = @_;
    $slug = _slug($slug);
    return undef unless length $slug;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM events WHERE slug = ? AND status = ? AND deleted_at IS NULL',
        undef,
        $slug,
        'published'
    );
}

sub occurrence {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT o.*, e.title, e.slug, e.timezone, e.all_day, e.location_label
            FROM event_occurrences o
            JOIN events e ON e.id = o.event_id
            WHERE o.id = ?
        },
        undef,
        $id
    );
}

sub occurrence_for_slug_date {
    my ($self, $slug, $date) = @_;
    my $event = $self->by_slug($slug) or return;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM event_occurrences
            WHERE event_id = ?
              AND active = 1
              AND occurrence_key = ?
            ORDER BY starts_at ASC
            LIMIT 1
        },
        undef,
        $event->{id},
        _clean_date_key($date)
    );
}

sub occurrences_for_event {
    my ($self, $event_id, %args) = @_;
    $event_id = int($event_id || 0);
    return [] unless $event_id > 0;
    my @where = ('event_id = ?', 'active = 1');
    my @bind = ($event_id);
    if ($args{from}) {
        push @where, 'starts_at >= ?';
        push @bind, int($args{from});
    }
    my $limit = int($args{limit} || 100);
    $limit = 100 if $limit < 1 || $limit > 500;
    return $self->{db}->dbh->selectall_arrayref(
        'SELECT * FROM event_occurrences WHERE ' . join(' AND ', @where) . " ORDER BY starts_at ASC LIMIT $limit",
        { Slice => {} },
        @bind
    );
}

sub upcoming_occurrences {
    my ($self, %args) = @_;
    my $from = int($args{from} || now() - 86400);
    my $limit = int($args{limit} || 100);
    $limit = 100 if $limit < 1 || $limit > 500;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT o.*, e.title, e.slug, e.summary, e.body, e.feature_image_path, e.timezone, e.all_day,
                   e.updated_at AS event_updated_at,
                   e.location_enabled, e.location_lat, e.location_lng, e.location_label, e.location_kind,
                   e.rsvp_enabled, e.rsvp_capacity, e.ticketing_enabled, e.waitlist_enabled
            FROM event_occurrences o
            JOIN events e ON e.id = o.event_id
            WHERE e.status = 'published'
              AND e.deleted_at IS NULL
              AND o.active = 1
              AND o.starts_at >= ?
            ORDER BY o.starts_at ASC, o.id ASC
            LIMIT $limit
        },
        { Slice => {} },
        $from
    );
}

sub all_published_occurrences {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 2000);
    $limit = 2000 if $limit < 1 || $limit > 5000;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT o.*, e.title, e.slug, e.summary, e.body, e.feature_image_path, e.timezone, e.all_day,
                   e.updated_at AS event_updated_at,
                   e.location_enabled, e.location_lat, e.location_lng, e.location_label, e.location_kind,
                   e.rsvp_enabled, e.rsvp_capacity, e.ticketing_enabled, e.waitlist_enabled
            FROM event_occurrences o
            JOIN events e ON e.id = o.event_id
            WHERE e.status = 'published'
              AND e.deleted_at IS NULL
              AND o.active = 1
            ORDER BY o.starts_at ASC, o.id ASC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub save_event {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $existing = $id ? $self->get($id) : undef;
    die "event not found" if $id && !$existing;

    my $title = _trim($args{title}, 180);
    die "event title is required" unless length $title;
    my $slug = _unique_slug($self->{db}->dbh, _slug($args{slug}) || slugify($title), $id);
    my $summary = _trim_long($args{summary}, 500);
    my $body = _clean_body($args{body});
    my $status = _event_status($args{status} || ($existing ? $existing->{status} : 'draft'));
    my $timezone = _timezone($args{timezone} || ($existing ? $existing->{timezone} : '') || 'UTC');
    my $starts_at = _parse_datetime($args{starts_at}, $timezone);
    die "event start time is required" unless defined $starts_at;
    my $ends_at = _parse_datetime($args{ends_at}, $timezone);
    $ends_at = $starts_at + 3600 unless defined $ends_at;
    die "event end must be after the start" if $ends_at <= $starts_at;
    my $feature_image_path = _feature_image($args{feature_image_path});
    my $location_lat = _coordinate($args{location_lat}, -90, 90);
    my $location_lng = _coordinate($args{location_lng}, -180, 180);
    my $location_enabled = $args{location_enabled} && defined $location_lat && defined $location_lng ? 1 : 0;
    my $location_label = _trim($args{location_label}, 160);
    my $location_kind = _location_kind($args{location_kind} || 'event_location');
    my $rsvp_enabled = $args{rsvp_enabled} ? 1 : 0;
    my $rsvp_capacity = _nonnegative_int($args{rsvp_capacity}, 0, 100000);
    my $waitlist_enabled = exists $args{waitlist_enabled} ? ($args{waitlist_enabled} ? 1 : 0) : 1;
    my $ticketing_enabled = $args{ticketing_enabled} ? 1 : 0;
    my $rrule = _clean_rrule($args{rrule});
    my $rdate_text = _clean_date_list($args{rdate_text});
    my $exdate_text = _clean_date_list($args{exdate_text});
    my $all_day = $args{all_day} ? 1 : 0;
    my $ts = now();

    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        if ($existing) {
            $dbh->do(
                q{
                    UPDATE events
                    SET title = ?, slug = ?, summary = ?, body = ?, status = ?, feature_image_path = ?,
                        timezone = ?, all_day = ?, starts_at = ?, ends_at = ?, rrule = ?, rdate_text = ?, exdate_text = ?,
                        location_enabled = ?, location_lat = ?, location_lng = ?, location_label = ?, location_kind = ?,
                        rsvp_enabled = ?, rsvp_capacity = ?, waitlist_enabled = ?, ticketing_enabled = ?,
                        updated_at = ?
                    WHERE id = ?
                },
                undef,
                $title, $slug, $summary, $body, $status, $feature_image_path,
                $timezone, $all_day, $starts_at, $ends_at, $rrule, $rdate_text, $exdate_text,
                $location_enabled, $location_lat, $location_lng, $location_label, $location_kind,
                $rsvp_enabled, $rsvp_capacity, $waitlist_enabled, $ticketing_enabled,
                $ts, $id
            );
        } else {
            $dbh->do(
                q{
                    INSERT INTO events
                        (title, slug, summary, body, status, feature_image_path, timezone, all_day,
                         starts_at, ends_at, rrule, rdate_text, exdate_text,
                         location_enabled, location_lat, location_lng, location_label, location_kind,
                         rsvp_enabled, rsvp_capacity, waitlist_enabled, ticketing_enabled,
                         created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                },
                undef,
                $title, $slug, $summary, $body, $status, $feature_image_path, $timezone, $all_day,
                $starts_at, $ends_at, $rrule, $rdate_text, $exdate_text,
                $location_enabled, $location_lat, $location_lng, $location_label, $location_kind,
                $rsvp_enabled, $rsvp_capacity, $waitlist_enabled, $ticketing_enabled,
                $ts, $ts
            );
            $id = int($dbh->sqlite_last_insert_rowid);
        }
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'event save failed';
        eval { $dbh->rollback };
        die $err;
    };

    my $event = $self->get($id);
    $self->materialize_event($event);
    return $event;
}

sub publish_event {
    my ($self, $id) = @_;
    my $event = $self->get($id) or die "event not found";
    my $ts = now();
    $self->{db}->dbh->do(
        'UPDATE events SET status = ?, published_at = COALESCE(published_at, ?), updated_at = ? WHERE id = ?',
        undef,
        'published',
        $ts,
        $ts,
        int($id)
    );
    $event = $self->get($id);
    $self->materialize_event($event);
    return $event;
}

sub delete_event {
    my ($self, $id) = @_;
    my $event = $self->get($id) or die "event not found";
    my $ts = now();
    $self->{db}->dbh->do(
        'UPDATE events SET deleted_at = ?, status = ?, updated_at = ? WHERE id = ?',
        undef,
        $ts,
        'archived',
        $ts,
        int($id)
    );
    $self->{db}->dbh->do(
        'UPDATE event_occurrences SET active = 0, updated_at = ? WHERE event_id = ?',
        undef,
        $ts,
        int($id)
    );
    return $event;
}

sub materialize_event {
    my ($self, $event) = @_;
    return 0 unless $event && $event->{id};
    my $dbh = $self->{db}->dbh;
    my $ts = now();
    my @starts = @{ _occurrence_epochs($event) };
    my $duration = int(($event->{ends_at} || $event->{starts_at} || 0) - ($event->{starts_at} || 0));
    $duration = 3600 if $duration <= 0;

    $dbh->begin_work;
    eval {
        $dbh->do(
            'UPDATE event_occurrences SET active = 0, updated_at = ? WHERE event_id = ?',
            undef,
            $ts,
            int($event->{id})
        );
        for my $start (@starts) {
            my $key = occurrence_key($event, $start);
            my $end = $start + $duration;
            $dbh->do(
                q{
                    INSERT INTO event_occurrences
                        (event_id, occurrence_key, starts_at, ends_at, active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 1, ?, ?)
                    ON CONFLICT(event_id, occurrence_key) DO UPDATE SET
                        starts_at = excluded.starts_at,
                        ends_at = excluded.ends_at,
                        active = 1,
                        updated_at = excluded.updated_at
                },
                undef,
                int($event->{id}),
                $key,
                int($start),
                int($end),
                $ts,
                $ts
            );
        }
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'event occurrence materialization failed';
        eval { $dbh->rollback };
        die $err;
    };
    return scalar @starts;
}

sub save_ticket_type {
    my ($self, %args) = @_;
    my $event = $self->get($args{event_id}) or die "event not found";
    my $id = int($args{id} || 0);
    my $existing = $id ? $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM event_ticket_types WHERE id = ? AND event_id = ?',
        undef,
        $id,
        $event->{id}
    ) : undef;
    die "ticket type not found" if $id && !$existing;
    my $name = _trim($args{name}, 120) || 'General admission';
    my $description = _trim_long($args{description}, 500);
    my $currency = _currency($args{currency});
    my $price = _price_cents($args{price});
    my $capacity = _nonnegative_int($args{capacity}, 0, 100000);
    my $active = exists $args{active} ? ($args{active} ? 1 : 0) : 1;
    my $sort_order = _signed_int($args{sort_order}, 100);
    my $ts = now();
    if ($existing) {
        $self->{db}->dbh->do(
            q{
                UPDATE event_ticket_types
                SET name = ?, description = ?, currency = ?, price_cents = ?, capacity = ?,
                    active = ?, sort_order = ?, updated_at = ?
                WHERE id = ?
            },
            undef,
            $name, $description, $currency, $price, $capacity, $active, $sort_order, $ts, $id
        );
    } else {
        $self->{db}->dbh->do(
            q{
                INSERT INTO event_ticket_types
                    (event_id, name, description, currency, price_cents, capacity, active, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $event->{id}, $name, $description, $currency, $price, $capacity, $active, $sort_order, $ts, $ts
        );
        $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    }
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM event_ticket_types WHERE id = ?', undef, $id);
}

sub ticket_types {
    my ($self, $event_id, %args) = @_;
    $event_id = int($event_id || 0);
    return [] unless $event_id > 0;
    my @where = ('event_id = ?');
    my @bind = ($event_id);
    if ($args{active_only}) {
        push @where, 'active = 1';
    }
    return $self->{db}->dbh->selectall_arrayref(
        'SELECT * FROM event_ticket_types WHERE ' . join(' AND ', @where) . ' ORDER BY sort_order ASC, id ASC',
        { Slice => {} },
        @bind
    );
}

sub recent_orders {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 25);
    $limit = 25 if $limit < 1 || $limit > 100;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT o.*, e.title AS event_title, t.name AS ticket_name
            FROM event_ticket_orders o
            JOIN events e ON e.id = o.event_id
            JOIN event_ticket_types t ON t.id = o.ticket_type_id
            ORDER BY o.created_at DESC, o.id DESC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub rsvps {
    my ($self, $event_id) = @_;
    $event_id = int($event_id || 0);
    return [] unless $event_id > 0;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT r.*, o.occurrence_key, o.starts_at AS occurrence_starts_at
            FROM event_rsvps r
            LEFT JOIN event_occurrences o ON o.id = r.occurrence_id
            WHERE r.event_id = ?
            ORDER BY r.created_at DESC, r.id DESC
        },
        { Slice => {} },
        $event_id
    );
}

sub rsvp_counts {
    my ($self, $event_id, $occurrence_id) = @_;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT status, SUM(guest_count) AS guests, COUNT(*) AS rows
            FROM event_rsvps
            WHERE event_id = ?
              AND (occurrence_id = ? OR (? IS NULL AND occurrence_id IS NULL))
            GROUP BY status
        },
        { Slice => {} },
        int($event_id || 0),
        defined $occurrence_id ? int($occurrence_id) : undef,
        defined $occurrence_id ? int($occurrence_id) : undef
    );
    my %counts = (
        confirmed => 0,
        waitlist  => 0,
        canceled  => 0,
    );
    for my $row (@{$rows}) {
        $counts{$row->{status}} = int($row->{guests} || 0) if exists $counts{$row->{status}};
    }
    return \%counts;
}

sub submit_rsvp {
    my ($self, %args) = @_;
    die "form rejected" if _trim($args{website}, 100) ne '';
    my $event = $self->get($args{event_id}) or die "event not found";
    die "RSVP is not enabled for this event" unless $event->{rsvp_enabled};
    my $occurrence = $args{occurrence_id} ? $self->occurrence($args{occurrence_id}) : undef;
    die "event occurrence not found" if $args{occurrence_id} && (!$occurrence || int($occurrence->{event_id}) != int($event->{id}));
    my $name = _trim($args{name}, 100);
    my $email = _email($args{email});
    my $guest_count = _nonnegative_int($args{guest_count}, 1, 100);
    $guest_count = 1 if $guest_count < 1;
    my $notes = _trim_long($args{notes}, 1000);
    die "Please enter your name." unless length $name;
    die "Please enter a valid email address." unless length $email;
    my $counts = $self->rsvp_counts($event->{id}, $occurrence ? $occurrence->{id} : undef);
    my $capacity = int($event->{rsvp_capacity} || 0);
    my $status = 'confirmed';
    if ($capacity > 0 && ($counts->{confirmed} + $guest_count) > $capacity) {
        die "This event is full." unless $event->{waitlist_enabled};
        $status = 'waitlist';
    }
    my $ip = DesertCMS::HTTP::client_ip($args{request}, $self->{config});
    my $ua = $args{request} ? ($args{request}->{user_agent} || '') : '';
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO event_rsvps
                (event_id, occurrence_id, name, email, guest_count, notes, status,
                 ip_hash, user_agent_hash, notification_status, notification_error,
                 created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', '', ?, ?)
        },
        undef,
        int($event->{id}),
        $occurrence ? int($occurrence->{id}) : undef,
        $name,
        $email,
        $guest_count,
        $notes,
        $status,
        length($ip) ? hmac_sha256_hex('event-rsvp:ip:' . $ip, $self->{config}->app_secret) : '',
        length($ua) ? hmac_sha256_hex('event-rsvp:ua:' . substr($ua, 0, 300), $self->{config}->app_secret) : '',
        $ts,
        $ts
    );
    my $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    $self->_send_rsvp_notification($id, $event, $occurrence);
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM event_rsvps WHERE id = ?', undef, $id);
}

sub update_rsvp_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $status = _rsvp_status($args{status});
    die "RSVP id is required" unless $id > 0;
    my $ts = now();
    $self->{db}->dbh->do(
        'UPDATE event_rsvps SET status = ?, updated_at = ? WHERE id = ?',
        undef,
        $status,
        $ts,
        $id
    );
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM event_rsvps WHERE id = ?', undef, $id);
}

sub create_checkout {
    my ($self, %args) = @_;
    my $event = $self->get($args{event_id}) or die "event not found";
    die "event is not published" unless ($event->{status} || '') eq 'published';
    die "ticketing is not enabled for this event" unless $event->{ticketing_enabled};
    die "Event Payments are not available on this plan or checkout is not ready"
        unless $self->checkout_ready;
    my $occurrence = $self->occurrence($args{occurrence_id}) or die "event occurrence not found";
    die "event occurrence does not belong to this event" unless int($occurrence->{event_id}) == int($event->{id});
    my $ticket = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM event_ticket_types WHERE id = ? AND event_id = ? AND active = 1',
        undef,
        int($args{ticket_type_id} || 0),
        int($event->{id})
    ) or die "ticket type is not available";
    die "paid ticket checkout requires a positive price" unless int($ticket->{price_cents} || 0) > 0;
    my $quantity = _nonnegative_int($args{quantity}, 1, 100);
    $quantity = 1 if $quantity < 1;
    my $email = _email_optional($args{customer_email});
    my $name = _trim($args{customer_name}, 120);
    _ensure_ticket_capacity($self, $ticket, $quantity);

    my $settings = _settings($self);
    my $key = $settings->{stripe_secret_key} || '';
    die "Stripe secret key is not configured" unless length $key;
    my $model = $self->payment_model;
    my $amount = int($ticket->{price_cents}) * $quantity;
    my $currency = _currency($ticket->{currency});
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        q{
            INSERT INTO event_ticket_orders
                (event_id, occurrence_id, ticket_type_id, status, currency, amount_cents,
                 quantity, customer_email, customer_name, created_at, updated_at)
            VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        int($event->{id}),
        int($occurrence->{id}),
        int($ticket->{id}),
        $currency,
        $amount,
        $quantity,
        $email,
        $name,
        $ts,
        $ts
    );
    my $order_id = int($dbh->sqlite_last_insert_rowid);

    my $success_url = $self->event_url($event, $occurrence, '/success?order=' . $order_id);
    my $cancel_url = $self->event_url($event, $occurrence, '/cancel?order=' . $order_id);
    my %form = (
        mode => 'payment',
        success_url => $success_url,
        cancel_url => $cancel_url,
        client_reference_id => $order_id,
        'line_items[0][quantity]' => 1,
        'line_items[0][price_data][currency]' => $currency,
        'line_items[0][price_data][unit_amount]' => $amount,
        'line_items[0][price_data][product_data][name]' => ($event->{title} || 'Event') . ' - ' . ($ticket->{name} || 'Ticket'),
        'line_items[0][price_data][product_data][description]' => _ticket_checkout_description($event, $occurrence, $quantity),
        'metadata[event_order_id]' => $order_id,
        'metadata[event_id]' => int($event->{id}),
        'metadata[occurrence_id]' => int($occurrence->{id}),
        'metadata[ticket_type_id]' => int($ticket->{id}),
        'metadata[quantity]' => $quantity,
        'payment_intent_data[metadata][event_order_id]' => $order_id,
        'payment_intent_data[metadata][event_id]' => int($event->{id}),
        'payment_intent_data[metadata][occurrence_id]' => int($occurrence->{id}),
        'payment_intent_data[metadata][ticket_type_id]' => int($ticket->{id}),
        'payment_intent_data[metadata][quantity]' => $quantity,
    );
    if ($model eq 'platform_marketplace') {
        my $account_id = _stripe_connect_account_id($settings->{stripe_connect_account_id} || '');
        die "Stripe connected payout account is not configured" unless length $account_id;
        my $fee_cents = _platform_fee_cents($amount, $settings->{contributor_platform_fee_bps});
        $form{'payment_intent_data[transfer_data][destination]'} = $account_id;
        $form{'payment_intent_data[application_fee_amount]'} = $fee_cents if $fee_cents > 0;
        $form{'payment_intent_data[metadata][stripe_connect_account_id]'} = $account_id;
        $form{'metadata[stripe_connect_account_id]'} = $account_id;
    }
    $form{customer_email} = $email if length $email;

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
        $dbh->do('UPDATE event_ticket_orders SET status = ?, updated_at = ? WHERE id = ?', undef, 'failed', now(), $order_id);
        die _stripe_error($body, $response, 'Stripe Checkout session could not be created');
    }
    $dbh->do(
        'UPDATE event_ticket_orders SET stripe_checkout_session_id = ?, updated_at = ? WHERE id = ?',
        undef,
        $body->{id},
        now(),
        $order_id
    );
    return {
        order_id => $order_id,
        session_id => $body->{id},
        url => $body->{url},
    };
}

sub order {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT o.*, e.title AS event_title, e.slug AS event_slug, e.timezone, e.all_day,
                   t.name AS ticket_name, t.price_cents AS ticket_price_cents,
                   occ.occurrence_key, occ.starts_at AS occurrence_starts_at, occ.ends_at AS occurrence_ends_at
            FROM event_ticket_orders o
            JOIN events e ON e.id = o.event_id
            JOIN event_ticket_types t ON t.id = o.ticket_type_id
            LEFT JOIN event_occurrences occ ON occ.id = o.occurrence_id
            WHERE o.id = ?
        },
        undef,
        $id
    );
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
        'SELECT COUNT(*) FROM event_stripe_events WHERE stripe_event_id = ?',
        undef,
        $event_id
    );
    return { ok => 1, duplicate => 1 } if $seen;
    my $object = $event->{data} && $event->{data}{object} && ref $event->{data}{object} eq 'HASH'
        ? $event->{data}{object}
        : {};
    if ($event_type eq 'checkout.session.completed'
        || $event_type eq 'checkout.session.async_payment_succeeded') {
        $self->_mark_order_paid($object, $event_id);
    } elsif ($event_type eq 'checkout.session.expired') {
        $self->_mark_order_status($object, 'canceled', $event_id);
    } elsif ($event_type eq 'checkout.session.async_payment_failed') {
        $self->_mark_order_status($object, 'failed', $event_id);
    }
    return { ok => 1, duplicate => 1 } unless $self->_record_stripe_event($event_id, $event_type);
    return { ok => 1, duplicate => 0, type => $event_type };
}

sub event_url {
    my ($self, $event, $occurrence, $suffix) = @_;
    $suffix ||= '';
    my $date = $occurrence ? ($occurrence->{occurrence_key} || occurrence_key($event, $occurrence->{starts_at})) : '';
    my $path = '/events/' . ($event->{slug} || '') . '/';
    $path .= $date . '/' if length $date;
    $path =~ s{//+}{/}g;
    $suffix =~ s{\A/}{};
    $path .= $suffix if length $suffix;
    my $base = $self->{config}->get('site_url') || '';
    $base =~ s{/+\z}{};
    return $base ? $base . $path : $path;
}

sub occurrence_key {
    my ($event, $epoch) = @_;
    my $tz = _timezone($event->{timezone} || 'UTC');
    my $dt = DesertCMS::DateTimeLite->from_epoch(epoch => int($epoch || 0), time_zone => $tz);
    return sprintf '%04d-%02d-%02d', $dt->year, $dt->month, $dt->day;
}

sub format_time_label {
    my ($event, $start, $end) = @_;
    my $tz = _timezone($event->{timezone} || 'UTC');
    my $s = DesertCMS::DateTimeLite->from_epoch(epoch => int($start || 0), time_zone => $tz);
    my $e = DesertCMS::DateTimeLite->from_epoch(epoch => int($end || $start || 0), time_zone => $tz);
    my $date = sprintf '%04d-%02d-%02d', $s->year, $s->month, $s->day;
    return $date if $event->{all_day};
    return sprintf '%s %02d:%02d-%02d:%02d %s',
        $date,
        $s->hour,
        $s->minute,
        $e->hour,
        $e->minute,
        $tz;
}

sub price_label {
    my ($cents, $currency) = @_;
    $cents = int($cents || 0);
    my $symbol = (_currency($currency) eq 'usd') ? '$' : uc(_currency($currency)) . ' ';
    return $symbol . sprintf('%.2f', $cents / 100);
}

sub recurrence_summary {
    my ($event) = @_;
    my $rule = _parse_rrule($event->{rrule} || '');
    return 'One-time event' unless $rule->{FREQ};
    my $freq = lc($rule->{FREQ});
    my $interval = int($rule->{INTERVAL} || 1);
    my $every = $interval > 1 ? "Every $interval $freq intervals" : "Repeats $freq";
    $every =~ s/daily/day/;
    $every =~ s/weekly/week/;
    $every =~ s/monthly/month/;
    $every =~ s/yearly/year/;
    $every .= ', limited by count' if $rule->{COUNT};
    $every .= ', with an end date' if $rule->{UNTIL};
    return $every;
}

sub webhook_signature_header {
    my ($class, %args) = @_;
    my $timestamp = $args{timestamp} || now();
    my $payload = defined $args{payload} ? $args{payload} : '';
    my $secret = $args{secret} || '';
    my $digest = hmac_sha256_hex($timestamp . '.' . $payload, $secret);
    return "t=$timestamp,v1=$digest";
}

sub clear_settings_cache {
    my ($self) = @_;
    delete $self->{settings_cache};
    return 1;
}

sub settings {
    my ($self) = @_;
    return { %{ _settings($self) } };
}

sub _occurrence_epochs {
    my ($event) = @_;
    my $tz = _timezone($event->{timezone} || 'UTC');
    my $start_epoch = int($event->{starts_at} || now());
    my $start = DesertCMS::DateTimeLite->from_epoch(epoch => $start_epoch, time_zone => $tz);
    my $window_end = $start->clone->add(months => 24)->epoch;
    my $rule = _parse_rrule($event->{rrule} || '');
    my @epochs = $rule->{FREQ}
        ? @{ _rrule_occurrences($start, $rule, $window_end, $tz) }
        : ($start_epoch);
    push @epochs, @{ _date_list_epochs($event->{rdate_text}, $tz, $start) };
    my %exclude = map { $_ => 1 } @{ _date_list_epochs($event->{exdate_text}, $tz, $start) };
    my %seen;
    @epochs = sort { $a <=> $b } grep {
        $_ >= $start_epoch
            && $_ <= $window_end
            && !$exclude{$_}
            && !$seen{$_}++
    } @epochs;
    return \@epochs;
}

sub _rrule_occurrences {
    my ($start, $rule, $window_end, $tz) = @_;
    my $freq = uc($rule->{FREQ} || '');
    my $interval = int($rule->{INTERVAL} || 1);
    $interval = 1 if $interval < 1;
    my $count_limit = int($rule->{COUNT} || 0);
    my $until = _parse_until($rule->{UNTIL}, $tz);
    my @epochs;
    my $base = $start->clone;
    my $periods = 0;
    while ($periods < 5000) {
        my @candidates = _period_candidates($base, $start, $rule, $freq);
        @candidates = sort { $a->epoch <=> $b->epoch } grep {
            $_->epoch >= $start->epoch
                && $_->epoch <= $window_end
                && (!defined $until || $_->epoch <= $until)
                && _candidate_matches($_, $rule)
        } @candidates;
        @candidates = _apply_bysetpos(\@candidates, $rule->{BYSETPOS});
        for my $candidate (@candidates) {
            push @epochs, $candidate->epoch;
            return \@epochs if $count_limit && @epochs >= $count_limit;
        }
        last if $base->epoch > $window_end;
        last if defined $until && $base->epoch > $until;
        if ($freq eq 'DAILY') {
            $base->add(days => $interval);
        } elsif ($freq eq 'WEEKLY') {
            $base->add(weeks => $interval);
        } elsif ($freq eq 'MONTHLY') {
            $base->add(months => $interval);
        } elsif ($freq eq 'YEARLY') {
            $base->add(years => $interval);
        } else {
            last;
        }
        $periods++;
    }
    return \@epochs;
}

sub _period_candidates {
    my ($base, $start, $rule, $freq) = @_;
    return ($base->clone) if $freq eq 'DAILY';
    return _weekly_candidates($base, $start, $rule) if $freq eq 'WEEKLY';
    return _monthly_candidates($base, $start, $rule) if $freq eq 'MONTHLY';
    return _yearly_candidates($base, $start, $rule) if $freq eq 'YEARLY';
    return ($base->clone);
}

sub _weekly_candidates {
    my ($base, $start, $rule) = @_;
    my @days = _byday_simple($rule->{BYDAY});
    return ($base->clone) unless @days;
    my $wkst = $WEEKDAY{uc($rule->{WKST} || 'MO')} || 1;
    my $offset = ($base->day_of_week - $wkst) % 7;
    my $week_start = $base->clone->subtract(days => $offset);
    return map {
        my $d = $week_start->clone->add(days => ($_ - $wkst) % 7);
        $d->set(hour => $start->hour, minute => $start->minute, second => $start->second);
        $d;
    } @days;
}

sub _monthly_candidates {
    my ($base, $start, $rule) = @_;
    my @monthdays = _number_list($rule->{BYMONTHDAY});
    my @byday = _byday_tokens($rule->{BYDAY});
    my @candidates;
    if (@monthdays) {
        for my $day (@monthdays) {
            my $md = _monthday_to_positive($base, $day);
            next unless $md;
            push @candidates, _safe_dt($base->year, $base->month, $md, $start);
        }
    } elsif (@byday) {
        for my $token (@byday) {
            push @candidates, _weekday_dates_in_month($base, $start, $token);
        }
    } else {
        push @candidates, _safe_dt($base->year, $base->month, $start->day, $start);
    }
    return grep { $_ } @candidates;
}

sub _yearly_candidates {
    my ($base, $start, $rule) = @_;
    if (length($rule->{BYWEEKNO} || '')) {
        return _year_week_candidates($base, $start, $rule);
    }
    my @candidates;
    my @yeardays = _number_list($rule->{BYYEARDAY});
    if (@yeardays) {
        for my $day (@yeardays) {
            my $dt = _yearday_dt($base->year, $day, $start);
            push @candidates, $dt if $dt;
        }
        return @candidates;
    }
    my @months = _number_list($rule->{BYMONTH});
    @months = ($start->month) unless @months;
    my @monthdays = _number_list($rule->{BYMONTHDAY});
    for my $month (@months) {
        next if $month < 1 || $month > 12;
        if (@monthdays) {
            for my $day (@monthdays) {
                my $tmp = _safe_dt($base->year, $month, 1, $start) or next;
                my $md = _monthday_to_positive($tmp, $day);
                push @candidates, _safe_dt($base->year, $month, $md, $start) if $md;
            }
        } elsif (length($rule->{BYDAY} || '')) {
            my $tmp = _safe_dt($base->year, $month, 1, $start) or next;
            push @candidates, _monthly_candidates($tmp, $start, $rule);
        } else {
            push @candidates, _safe_dt($base->year, $month, $start->day, $start);
        }
    }
    return grep { $_ } @candidates;
}

sub _candidate_matches {
    my ($dt, $rule) = @_;
    my @months = _number_list($rule->{BYMONTH});
    return 0 if @months && !(grep { $_ == $dt->month } @months);
    my @monthdays = _number_list($rule->{BYMONTHDAY});
    if (@monthdays) {
        my $last = $dt->clone->set(day => 1)->add(months => 1)->subtract(days => 1)->day;
        return 0 unless grep { ($_ > 0 && $_ == $dt->day) || ($_ < 0 && ($last + $_ + 1) == $dt->day) } @monthdays;
    }
    my @yeardays = _number_list($rule->{BYYEARDAY});
    if (@yeardays) {
        my $last = DesertCMS::DateTimeLite->new(year => $dt->year, month => 12, day => 31, time_zone => $dt->time_zone)->day_of_year;
        return 0 unless grep { ($_ > 0 && $_ == $dt->day_of_year) || ($_ < 0 && ($last + $_ + 1) == $dt->day_of_year) } @yeardays;
    }
    my @days = _byday_simple($rule->{BYDAY});
    return 0 if @days && !(grep { $_ == $dt->day_of_week } @days);
    return 1;
}

sub _apply_bysetpos {
    my ($candidates, $raw) = @_;
    my @positions = _number_list($raw);
    return @{$candidates} unless @positions;
    my @picked;
    for my $pos (@positions) {
        next if $pos == 0;
        my $idx = $pos > 0 ? $pos - 1 : @{$candidates} + $pos;
        push @picked, $candidates->[$idx] if $idx >= 0 && $idx < @{$candidates};
    }
    return @picked;
}

sub _parse_rrule {
    my ($text) = @_;
    my %rule;
    $text = _clean_rrule($text);
    return \%rule unless length $text;
    for my $part (split /;/, $text) {
        my ($key, $value) = split /=/, $part, 2;
        next unless defined $key && defined $value;
        $key = uc $key;
        $value = uc $value;
        next unless $key =~ /\A(?:FREQ|INTERVAL|COUNT|UNTIL|BYDAY|BYMONTHDAY|BYYEARDAY|BYWEEKNO|BYMONTH|BYSETPOS|WKST)\z/;
        $rule{$key} = $value;
    }
    return \%rule;
}

sub _clean_rrule {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/\r?\n/;/g;
    $text =~ s/\s+//g;
    $text =~ s/\ARRULE://i;
    return substr(uc($text), 0, 1000);
}

sub _date_list_epochs {
    my ($text, $tz, $start) = @_;
    $text = '' unless defined $text;
    my @epochs;
    for my $part (grep { length } split /[\s,]+/, $text) {
        my $epoch = _parse_datetime($part, $tz, $start);
        push @epochs, $epoch if defined $epoch;
    }
    return \@epochs;
}

sub _parse_datetime {
    my ($value, $tz, $start) = @_;
    return undef unless defined $value && "$value" =~ /\S/;
    return int($value) if "$value" =~ /\A[0-9]{9,12}\z/;
    $tz = _timezone($tz || 'UTC');
    $value =~ s/^\s+|\s+\z//g;
    my ($year, $month, $day, $hour, $minute, $second);
    if ($value =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[T ]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?)?\z/) {
        ($year, $month, $day, $hour, $minute, $second) = ($1, $2, $3, $4 || ($start ? $start->hour : 0), $5 || ($start ? $start->minute : 0), $6 || ($start ? $start->second : 0));
    } elsif ($value =~ /\A([0-9]{4})([0-9]{2})([0-9]{2})(?:T([0-9]{2})([0-9]{2})([0-9]{2})Z?)?\z/) {
        ($year, $month, $day, $hour, $minute, $second) = ($1, $2, $3, $4 || ($start ? $start->hour : 0), $5 || ($start ? $start->minute : 0), $6 || ($start ? $start->second : 0));
        $tz = 'UTC' if $value =~ /Z\z/;
    } else {
        return undef;
    }
    my $dt = eval {
        DesertCMS::DateTimeLite->new(
            year => int($year), month => int($month), day => int($day),
            hour => int($hour || 0), minute => int($minute || 0), second => int($second || 0),
            time_zone => $tz,
        );
    };
    return $dt ? $dt->epoch : undef;
}

sub _parse_until {
    my ($value, $tz) = @_;
    return undef unless defined $value && length $value;
    return _parse_datetime($value, $tz);
}

sub _number_list {
    my ($raw) = @_;
    return () unless defined $raw && length $raw;
    return grep { defined } map { /\A-?[0-9]+\z/ ? int($_) : undef } split /,/, $raw;
}

sub _byday_tokens {
    my ($raw) = @_;
    return () unless defined $raw && length $raw;
    my @tokens;
    for my $token (split /,/, uc($raw)) {
        next unless $token =~ /\A([+-]?[0-9]+)?(MO|TU|WE|TH|FR|SA|SU)\z/;
        push @tokens, { nth => defined $1 && length $1 ? int($1) : undef, day => $WEEKDAY{$2}, code => $2 };
    }
    return @tokens;
}

sub _byday_simple {
    my ($raw) = @_;
    return map { $_->{day} } grep { !defined $_->{nth} } _byday_tokens($raw);
}

sub _weekday_dates_in_month {
    my ($base, $start, $token) = @_;
    my @dates;
    my $last = $base->clone->set(day => 1)->add(months => 1)->subtract(days => 1)->day;
    for my $day (1 .. $last) {
        my $dt = _safe_dt($base->year, $base->month, $day, $start) or next;
        push @dates, $dt if $dt->day_of_week == $token->{day};
    }
    if (defined $token->{nth}) {
        my $idx = $token->{nth} > 0 ? $token->{nth} - 1 : @dates + $token->{nth};
        return $idx >= 0 && $idx < @dates ? ($dates[$idx]) : ();
    }
    return @dates;
}

sub _year_week_candidates {
    my ($base, $start, $rule) = @_;
    my @weeks = _number_list($rule->{BYWEEKNO});
    my @days = _byday_simple($rule->{BYDAY});
    @days = ($start->day_of_week) unless @days;
    my @candidates;
    my $dt = DesertCMS::DateTimeLite->new(year => $base->year, month => 1, day => 1, time_zone => $base->time_zone);
    my $end = DesertCMS::DateTimeLite->new(year => $base->year, month => 12, day => 31, time_zone => $base->time_zone);
    while ($dt <= $end) {
        if ((grep { $_ == $dt->week_number } @weeks) && (grep { $_ == $dt->day_of_week } @days)) {
            my $copy = $dt->clone;
            $copy->set(hour => $start->hour, minute => $start->minute, second => $start->second);
            push @candidates, $copy;
        }
        $dt->add(days => 1);
    }
    return @candidates;
}

sub _safe_dt {
    my ($year, $month, $day, $start) = @_;
    return undef unless $month >= 1 && $month <= 12 && $day >= 1;
    return eval {
        DesertCMS::DateTimeLite->new(
            year => int($year), month => int($month), day => int($day),
            hour => $start->hour, minute => $start->minute, second => $start->second,
            time_zone => $start->time_zone,
        );
    };
}

sub _monthday_to_positive {
    my ($base, $day) = @_;
    my $last = $base->clone->set(day => 1)->add(months => 1)->subtract(days => 1)->day;
    my $positive = $day > 0 ? $day : $last + $day + 1;
    return $positive >= 1 && $positive <= $last ? $positive : undef;
}

sub _yearday_dt {
    my ($year, $day, $start) = @_;
    my $first = DesertCMS::DateTimeLite->new(year => $year, month => 1, day => 1, time_zone => $start->time_zone);
    my $last = DesertCMS::DateTimeLite->new(year => $year, month => 12, day => 31, time_zone => $start->time_zone)->day_of_year;
    my $positive = $day > 0 ? $day : $last + $day + 1;
    return undef if $positive < 1 || $positive > $last;
    my $dt = $first->clone->add(days => $positive - 1);
    $dt->set(hour => $start->hour, minute => $start->minute, second => $start->second);
    return $dt;
}

sub _clean_date_list {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/\r\n?/\n/g;
    $text =~ s/[^\dT:,\n Zz-]+//g;
    $text =~ s/\n{2,}/\n/g;
    $text =~ s/^\s+|\s+\z//g;
    return substr($text, 0, 2000);
}

sub _send_rsvp_notification {
    my ($self, $id, $event, $occurrence) = @_;
    my $settings = _settings($self);
    my $ts = now();
    if (!_truthy($settings->{events_notify_postmark_enabled})) {
        return $self->_record_rsvp_notification($id, 'skipped', 'Postmark notifications are disabled for Events', undef);
    }
    my $to = _email_optional($settings->{events_notification_email} || $settings->{forms_notification_email} || '');
    if (!length $to) {
        return $self->_record_rsvp_notification($id, 'skipped', 'Event notification recipient is not configured', undef);
    }
    my $row = $self->{db}->dbh->selectrow_hashref('SELECT * FROM event_rsvps WHERE id = ?', undef, $id) or return;
    my $site_name = $settings->{site_name} || $self->{config}->get('site_name') || 'DesertCMS';
    my $subject = 'New RSVP: ' . ($event->{title} || 'Event');
    my $time = $occurrence ? format_time_label($event, $occurrence->{starts_at}, $occurrence->{ends_at}) : format_time_label($event, $event->{starts_at}, $event->{ends_at});
    my $text = join "\n",
        "A new RSVP was received on $site_name.",
        '',
        'Event: ' . ($event->{title} || ''),
        "When: $time",
        'Name: ' . ($row->{name} || ''),
        'Email: ' . ($row->{email} || ''),
        'Guests: ' . int($row->{guest_count} || 1),
        'Status: ' . ($row->{status} || ''),
        '',
        'Notes:',
        ($row->{notes} || '');
    my $html = '<p>A new RSVP was received on ' . escape_html($site_name) . '.</p>'
        . '<ul><li><strong>Event:</strong> ' . escape_html($event->{title} || '') . '</li>'
        . '<li><strong>When:</strong> ' . escape_html($time) . '</li>'
        . '<li><strong>Name:</strong> ' . escape_html($row->{name} || '') . '</li>'
        . '<li><strong>Email:</strong> ' . escape_html($row->{email} || '') . '</li>'
        . '<li><strong>Guests:</strong> ' . int($row->{guest_count} || 1) . '</li>'
        . '<li><strong>Status:</strong> ' . escape_html($row->{status} || '') . '</li></ul>'
        . '<p>' . escape_html($row->{notes} || '') . '</p>';
    my ($sent, $reason) = send_postmark(
        $self->{config},
        $self->{db},
        to         => $to,
        email_type => 'event_rsvp',
        subject    => substr($subject, 0, 300),
        text_body  => $text,
        html_body  => $html,
    );
    my $status = $sent ? 'sent' : (($reason || '') =~ /not configured/i ? 'skipped' : 'failed');
    return $self->_record_rsvp_notification($id, $status, $reason || '', $sent ? $ts : undef);
}

sub _record_rsvp_notification {
    my ($self, $id, $status, $reason, $sent_at) = @_;
    $self->{db}->dbh->do(
        q{
            UPDATE event_rsvps
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

sub _mark_order_paid {
    my ($self, $session, $event_id) = @_;
    my $order = $self->_order_from_session($session) or die "matching event ticket order not found";
    my $payment_status = $session->{payment_status} || '';
    die "Stripe Checkout session is not paid" if length $payment_status && $payment_status ne 'paid';
    _validate_paid_session($order, $session);
    my $email = '';
    my $name = '';
    if ($session->{customer_details} && ref $session->{customer_details} eq 'HASH') {
        $email = _email_optional($session->{customer_details}{email});
        $name = _trim($session->{customer_details}{name}, 120);
    }
    my $payment_intent = _trim($session->{payment_intent}, 160);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        $dbh->do(
            q{
                UPDATE event_ticket_orders
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
            $email, $email, $name, $name, $payment_intent, $payment_intent,
            $event_id, $ts, $ts, int($order->{id})
        );
        my ($existing_rsvp) = $dbh->selectrow_array(
            q{
                SELECT COUNT(*)
                FROM event_rsvps
                WHERE event_id = ?
                  AND occurrence_id = ?
                  AND email = ?
                  AND notes LIKE ?
            },
            undef,
            int($order->{event_id}),
            int($order->{occurrence_id} || 0),
            $email || $order->{customer_email} || '',
            '%ticket order #' . int($order->{id}) . '%'
        );
        if (!$existing_rsvp) {
            $dbh->do(
                q{
                    INSERT INTO event_rsvps
                        (event_id, occurrence_id, name, email, guest_count, notes, status,
                         notification_status, notification_error, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'confirmed', 'skipped', 'Paid ticket order', ?, ?)
                },
                undef,
                int($order->{event_id}),
                int($order->{occurrence_id} || 0),
                $name || $order->{customer_name} || 'Ticket buyer',
                $email || $order->{customer_email} || '',
                int($order->{quantity} || 1),
                'Confirmed by paid ticket order #' . int($order->{id}),
                $ts,
                $ts
            );
        }
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'event order update failed';
        eval { $dbh->rollback };
        die $err;
    };
}

sub _mark_order_status {
    my ($self, $session, $status, $event_id) = @_;
    my $order = $self->_order_from_session($session) or return;
    return if ($order->{status} || '') eq 'paid';
    $self->{db}->dbh->do(
        q{
            UPDATE event_ticket_orders
            SET status = ?,
                stripe_event_id = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        $status,
        $event_id,
        now(),
        int($order->{id})
    );
}

sub _order_from_session {
    my ($self, $session) = @_;
    my $metadata = $session->{metadata} && ref $session->{metadata} eq 'HASH'
        ? $session->{metadata}
        : {};
    my $order_id = int($metadata->{event_order_id} || $session->{client_reference_id} || 0);
    return $self->order($order_id) if $order_id;
    my $session_id = _trim($session->{id}, 160);
    return undef unless length $session_id;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM event_ticket_orders WHERE stripe_checkout_session_id = ?',
        undef,
        $session_id
    );
}

sub _record_stripe_event {
    my ($self, $event_id, $event_type) = @_;
    eval {
        $self->{db}->dbh->do(
            q{
                INSERT INTO event_stripe_events (stripe_event_id, event_type, received_at)
                VALUES (?, ?, ?)
            },
            undef,
            $event_id,
            $event_type,
            now()
        );
        1;
    } or do {
        return 0 if ($@ || '') =~ /(?:UNIQUE|constraint)/i;
        die $@;
    };
    return 1;
}

sub _validate_paid_session {
    my ($order, $session) = @_;
    my $session_id = _trim($session->{id}, 160);
    if (length($session_id) && length($order->{stripe_checkout_session_id} || '')) {
        die "Stripe Checkout session id does not match this event order"
            unless $session_id eq $order->{stripe_checkout_session_id};
    }
    if (defined $session->{amount_total} && length "$session->{amount_total}") {
        die "Stripe amount does not match this event order"
            unless int($session->{amount_total}) == int($order->{amount_cents} || 0);
    }
    if (defined $session->{currency} && length $session->{currency}) {
        die "Stripe currency does not match this event order"
            unless _currency($session->{currency}) eq _currency($order->{currency});
    }
    my $metadata = $session->{metadata} && ref $session->{metadata} eq 'HASH'
        ? $session->{metadata}
        : {};
    _metadata_matches($metadata, 'event_order_id', $order->{id});
    _metadata_matches($metadata, 'event_id', $order->{event_id});
    _metadata_matches($metadata, 'occurrence_id', $order->{occurrence_id});
    _metadata_matches($metadata, 'ticket_type_id', $order->{ticket_type_id});
}

sub _metadata_matches {
    my ($metadata, $key, $expected) = @_;
    return unless defined $metadata->{$key} && length $metadata->{$key};
    die "Stripe metadata $key does not match this event order"
        unless int($metadata->{$key}) == int($expected || 0);
}

sub _ensure_ticket_capacity {
    my ($self, $ticket, $quantity) = @_;
    my $capacity = int($ticket->{capacity} || 0);
    return 1 unless $capacity > 0;
    my ($sold) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT COALESCE(SUM(quantity), 0)
            FROM event_ticket_orders
            WHERE ticket_type_id = ?
              AND status IN ('pending', 'paid')
        },
        undef,
        int($ticket->{id})
    );
    die "not enough tickets remain" if int($sold || 0) + int($quantity || 0) > $capacity;
    return 1;
}

sub _settings {
    my ($self) = @_;
    $self->{settings_cache} ||= do {
        my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
        if (DesertCMS::Commerce::is_contributor_instance($self->{config})
            && ($settings->{commerce_model} || '') eq 'platform_marketplace') {
            my $master = _master_stripe_settings($self);
            for my $key (qw(stripe_secret_key stripe_webhook_secret stripe_api_base)) {
                $settings->{$key} = $master->{$key}
                    if $master && length($master->{$key} || '');
            }
        }
        $settings;
    };
    return $self->{settings_cache};
}

sub _master_stripe_settings {
    my ($self) = @_;
    my $config = $self->{config};
    my $current = $config->get('path') || '';
    my $path = $config->get('master_config_path') || '';
    if (!length $path && $current ne '/etc/desertcms.conf' && -f '/etc/desertcms.conf') {
        $path = '/etc/desertcms.conf';
    }
    return undef unless length $path && $path ne $current && -f $path;
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

sub _verify_signature {
    my (%args) = @_;
    my $header = $args{header} || '';
    my $payload = defined $args{payload} ? $args{payload} : '';
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

sub _form_encode {
    my ($values) = @_;
    return join '&', map {
        _url_escape($_) . '=' . _url_escape($values->{$_})
    } sort keys %{$values};
}

sub _url_escape {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/eg;
    return $value;
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
    return $fallback;
}

sub _ticket_checkout_description {
    my ($event, $occurrence, $quantity) = @_;
    return 'Ticket quantity ' . int($quantity || 1) . ' for ' . format_time_label($event, $occurrence->{starts_at}, $occurrence->{ends_at});
}

sub _plan_feature_enabled {
    my ($settings, $key, $default_without_plan) = @_;
    my $json = $settings->{contributor_plan_features_json} || '';
    return $default_without_plan ? 1 : 0 unless length $json;
    my $decoded = eval { decode_json($json) };
    return $default_without_plan ? 1 : 0 unless $decoded && ref $decoded eq 'HASH';
    return _truthy($decoded->{$key}) ? 1 : 0 if exists $decoded->{$key};
    return _truthy($decoded->{events}) ? 1 : 0 if $key eq 'event_payments' && exists $decoded->{events};
    return 0;
}

sub _unique_slug {
    my ($dbh, $base, $id) = @_;
    $base = _slug($base) || 'event';
    my $slug = $base;
    my $i = 2;
    while (1) {
        my ($existing) = $dbh->selectrow_array(
            'SELECT id FROM events WHERE slug = ? AND deleted_at IS NULL AND (? = 0 OR id <> ?) LIMIT 1',
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

sub _event_status {
    my ($status) = @_;
    $status = lc($status || 'draft');
    return $status if $status =~ /\A(?:draft|published|archived)\z/;
    return 'draft';
}

sub _rsvp_status {
    my ($status) = @_;
    $status = lc($status || 'confirmed');
    return $status if $status =~ /\A(?:confirmed|waitlist|canceled)\z/;
    return 'confirmed';
}

sub _timezone {
    my ($value) = @_;
    $value = _trim($value, 80) || 'UTC';
    return DesertCMS::DateTimeLite->valid_time_zone($value) ? $value : 'UTC';
}

sub _feature_image {
    my ($value) = @_;
    $value = _trim($value, 300);
    return $value if DesertCMS::Media::is_public_image_path($value);
    return '';
}

sub _location_kind {
    my ($value) = @_;
    $value = lc($value || 'event_location');
    $value =~ s/[-\s]+/_/g;
    return $LOCATION_KINDS{$value} ? $value : 'event_location';
}

sub _coordinate {
    my ($value, $min, $max) = @_;
    return undef unless defined $value && "$value" =~ /\S/;
    return undef unless "$value" =~ /\A-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/;
    my $num = 0 + $value;
    return undef if $num < $min || $num > $max;
    return $num;
}

sub _clean_body {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
    $value =~ s/\n{4,}/\n\n\n/g;
    $value =~ s/^\s+|\s+\z//g;
    return substr($value, 0, 20000);
}

sub _price_cents {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/[\$,]//g;
    return 0 unless length $value;
    die "invalid price" unless $value =~ /\A[0-9]+(?:\.[0-9]{1,2})?\z/;
    my ($whole, $decimal) = split /\./, $value, 2;
    $decimal = defined $decimal ? $decimal : '';
    $decimal .= '0' while length($decimal) < 2;
    my $cents = int($whole) * 100 + int(substr($decimal, 0, 2) || 0);
    die "price is too high" if $cents > 99_999_999;
    return $cents;
}

sub _currency {
    my ($value) = @_;
    $value = lc($value || 'usd');
    $value =~ s/^\s+|\s+$//g;
    return $value =~ /\A[a-z]{3}\z/ ? $value : 'usd';
}

sub _nonnegative_int {
    my ($value, $default, $max) = @_;
    return int($default || 0) unless defined $value && "$value" =~ /\A\s*[0-9]+\s*\z/;
    my $int = int($value);
    $int = $max if defined $max && $int > $max;
    return $int;
}

sub _signed_int {
    my ($value, $default) = @_;
    return int($default || 0) unless defined $value && "$value" =~ /\A\s*-?[0-9]+\s*\z/;
    return int($value);
}

sub _slug {
    my ($value) = @_;
    $value = slugify(_trim($value, 160));
    return $value eq 'untitled' ? '' : $value;
}

sub _clean_date_key {
    my ($date) = @_;
    $date = '' unless defined $date;
    return $1 if $date =~ /\A([0-9]{4}-[0-9]{2}-[0-9]{2})\z/;
    return '';
}

sub _email {
    my ($value) = @_;
    my $email = _email_optional($value);
    die "Please enter a valid email address." unless length $email;
    return $email;
}

sub _email_optional {
    my ($value) = @_;
    $value = lc _trim($value, 180);
    return '' unless length $value;
    return $value =~ /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z/ ? $value : '';
}

sub _stripe_connect_account_id {
    my ($value) = @_;
    $value = _trim($value, 120);
    return $value =~ /\Aacct_[A-Za-z0-9_]+\z/ ? $value : '';
}

sub _platform_fee_cents {
    my ($amount_cents, $fee_bps) = @_;
    $amount_cents = int($amount_cents || 0);
    $fee_bps = int($fee_bps || 0);
    $fee_bps = 0 if $fee_bps < 0;
    $fee_bps = 10_000 if $fee_bps > 10_000;
    my $fee = int(($amount_cents * $fee_bps) / 10_000 + 0.5);
    return $amount_cents if $fee > $amount_cents;
    return $fee;
}

sub _trim {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\r\n\t]+/ /g;
    $value =~ s/^\s+|\s+\z//g;
    $value =~ s/\s+/ /g;
    return substr($value, 0, $max || 255);
}

sub _trim_long {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\r\t]+/ /g;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\n{3,}/\n\n/g;
    return substr($value, 0, $max || 1000);
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

1;
