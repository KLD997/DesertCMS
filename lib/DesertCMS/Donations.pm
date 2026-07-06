package DesertCMS::Donations;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(decode_json);
use MIME::Base64 qw(encode_base64);
use DesertCMS::Commerce;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Media;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Util qw(
    constant_time_eq escape_html hmac_sha256_hex now slugify
);

my %CAMPAIGN_STATUS = map { $_ => 1 } qw(draft published archived);
my %DONATION_STATUS = map { $_ => 1 } qw(pending paid failed canceled refunded);

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

sub clear_settings_cache {
    my ($self) = @_;
    delete $self->{settings_cache};
}

sub enabled {
    my ($self) = @_;
    return DesertCMS::Modules::enabled(_settings($self), 'donations');
}

sub donation_payments_allowed_by_plan {
    my ($self) = @_;
    return _plan_feature_enabled(_settings($self), 'donation_payments', 1);
}

sub payment_model {
    my ($self) = @_;
    my $settings = _settings($self);
    my $explicit = DesertCMS::Commerce::normalize_model($settings->{commerce_model} || $self->{config}->get('commerce_model') || '');
    return $explicit if length $explicit;
    return 'disabled' unless $self->donation_payments_allowed_by_plan;
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
    my $enabled = $self->enabled;
    my $allowed = $self->donation_payments_allowed_by_plan;
    my $model = $self->payment_model;
    my $model_allows = DesertCMS::Commerce::model_allows_checkout($model);
    my $marketplace = $model eq 'platform_marketplace' ? 1 : 0;
    my $stripe_key = length($settings->{stripe_secret_key} || '') ? 1 : 0;
    my $webhook = length($settings->{stripe_webhook_secret} || '') ? 1 : 0;
    my $connect_account = length($settings->{stripe_connect_account_id} || '') ? 1 : 0;
    my $connect_allowed = $allowed && _truthy($settings->{contributor_allow_stripe_connect}) ? 1 : 0;

    my ($state, $label, $summary) = ('neutral', 'Disabled', 'Donation payments are disabled.');
    if (!$enabled) {
        ($state, $label, $summary) = ('neutral', 'Donations disabled', 'Enable Donations before accepting public contributions.');
    } elsif (!$allowed) {
        ($state, $label, $summary) = ('warn', 'Payments locked', 'Campaign pages are available; Stripe donation checkout requires Donation Payments.');
    } elsif (!$model_allows || $model eq 'disabled') {
        ($state, $label, $summary) = ('neutral', 'Payments disabled', 'Choose a checkout-capable commerce model before taking donations.');
    } elsif ($marketplace && !$connect_allowed) {
        ($state, $label, $summary) = ('warn', 'Plan locked', 'This plan does not include contributor payout setup.');
    } elsif (!$stripe_key || !$webhook) {
        ($state, $label, $summary) = ('warn', 'Needs Stripe', $marketplace ? 'Marketplace donations need inherited master Stripe credentials and webhook secret.' : 'Donations need both a Stripe secret key and webhook secret.');
    } elsif ($marketplace && !$connect_account) {
        ($state, $label, $summary) = ('warn', 'Connect payouts', 'Connect a Stripe payout account before this site can take donations.');
    } else {
        ($state, $label, $summary) = ('ok', 'Ready', $marketplace ? 'Donation checkout is ready for platform marketplace payouts.' : 'Donation checkout is ready.');
    }

    return {
        state            => $state,
        label            => $label,
        summary          => $summary,
        model            => $model,
        checkout_allowed => $allowed ? 1 : 0,
        checkout_enabled => ($enabled && $allowed && $model_allows && $stripe_key && $webhook && (!$marketplace || $connect_account)) ? 1 : 0,
        marketplace      => $marketplace,
        stripe_ready     => ($stripe_key && $webhook) ? 1 : 0,
        connect_account  => $connect_account,
    };
}

sub campaigns_admin {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT c.*,
                   COUNT(d.id) AS donation_count,
                   COALESCE(SUM(CASE WHEN d.status = 'paid' THEN d.amount_cents ELSE 0 END), 0) AS raised_cents
            FROM donation_campaigns c
            LEFT JOIN donations d ON d.campaign_id = c.id
            GROUP BY c.id
            ORDER BY
                CASE c.status WHEN 'published' THEN 0 WHEN 'draft' THEN 1 ELSE 2 END,
                c.featured DESC,
                c.sort_order ASC,
                c.updated_at DESC,
                c.id DESC
        },
        { Slice => {} }
    );
}

sub published_campaigns {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 500, 1, 5000);
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT c.*,
                   COALESCE(SUM(CASE WHEN d.status = 'paid' THEN d.amount_cents ELSE 0 END), 0) AS raised_cents,
                   COUNT(CASE WHEN d.status = 'paid' THEN 1 END) AS paid_donation_count
            FROM donation_campaigns c
            LEFT JOIN donations d ON d.campaign_id = c.id
            WHERE c.status = 'published'
            GROUP BY c.id
            ORDER BY c.featured DESC, c.sort_order ASC, lower(c.title), c.id ASC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub get_campaign {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT c.*,
                   COALESCE(SUM(CASE WHEN d.status = 'paid' THEN d.amount_cents ELSE 0 END), 0) AS raised_cents,
                   COUNT(CASE WHEN d.status = 'paid' THEN 1 END) AS paid_donation_count
            FROM donation_campaigns c
            LEFT JOIN donations d ON d.campaign_id = c.id
            WHERE c.id = ?
            GROUP BY c.id
        },
        undef,
        $id
    );
}

sub campaign_by_slug {
    my ($self, $slug) = @_;
    $slug = _slug($slug);
    return undef unless length $slug;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT c.*,
                   COALESCE(SUM(CASE WHEN d.status = 'paid' THEN d.amount_cents ELSE 0 END), 0) AS raised_cents,
                   COUNT(CASE WHEN d.status = 'paid' THEN 1 END) AS paid_donation_count
            FROM donation_campaigns c
            LEFT JOIN donations d ON d.campaign_id = c.id
            WHERE c.slug = ?
              AND c.status = 'published'
            GROUP BY c.id
            LIMIT 1
        },
        undef,
        $slug
    );
}

sub save_campaign {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $title = _text($args{title}, 180);
    die "donation campaign title is required" unless length $title;
    my $raw_slug = _text($args{slug}, 160);
    my $requested_slug = length $raw_slug ? _slug($raw_slug) : '';
    my $slug = _unique_campaign_slug($self->{db}->dbh, length $requested_slug ? $requested_slug : slugify($title), $id);
    my $status = _campaign_status($args{status});
    my $currency = _currency($args{currency});
    my $goal = _price_cents($args{goal_amount} || $args{goal_amount_cents});
    my $suggested = _suggested_amounts($args{suggested_amounts_text} || $args{suggested_amounts});
    my $ts = now();
    my %row = (
        title                  => $title,
        slug                   => $slug,
        status                 => $status,
        summary                => _text($args{summary}, 500),
        body                   => _body($args{body}, 10000),
        image_path             => _image_path($args{image_path}),
        goal_amount_cents      => $goal,
        currency               => $currency,
        suggested_amounts_text => $suggested,
        allow_custom_amount    => _bool($args{allow_custom_amount}) ? 1 : 0,
        donor_message_enabled  => _bool($args{donor_message_enabled}) ? 1 : 0,
        show_goal              => _bool($args{show_goal}) ? 1 : 0,
        featured               => _bool($args{featured}) ? 1 : 0,
        sort_order             => _int($args{sort_order}, 100, 0, 100000),
    );
    $row{allow_custom_amount} = 1 unless length($row{suggested_amounts_text});

    my $dbh = $self->{db}->dbh;
    if ($id > 0 && $self->get_campaign($id)) {
        $dbh->do(
            q{
                UPDATE donation_campaigns
                SET title = ?, slug = ?, status = ?, summary = ?, body = ?, image_path = ?,
                    goal_amount_cents = ?, currency = ?, suggested_amounts_text = ?,
                    allow_custom_amount = ?, donor_message_enabled = ?, show_goal = ?,
                    featured = ?, sort_order = ?, updated_at = ?,
                    published_at = CASE WHEN ? = 'published' THEN COALESCE(published_at, ?) ELSE published_at END,
                    archived_at = CASE WHEN ? = 'archived' THEN COALESCE(archived_at, ?) ELSE archived_at END
                WHERE id = ?
            },
            undef,
            @row{qw(title slug status summary body image_path goal_amount_cents currency suggested_amounts_text allow_custom_amount donor_message_enabled show_goal featured sort_order)},
            $ts,
            $status, $ts,
            $status, $ts,
            $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO donation_campaigns
                    (title, slug, status, summary, body, image_path, goal_amount_cents, currency,
                     suggested_amounts_text, allow_custom_amount, donor_message_enabled, show_goal,
                     featured, sort_order, created_at, updated_at, published_at, archived_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            @row{qw(title slug status summary body image_path goal_amount_cents currency suggested_amounts_text allow_custom_amount donor_message_enabled show_goal featured sort_order)},
            $ts,
            $ts,
            $status eq 'published' ? $ts : undef,
            $status eq 'archived' ? $ts : undef
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->get_campaign($id);
}

sub publish_campaign {
    my ($self, $id) = @_;
    my $campaign = $self->get_campaign($id) or die "donation campaign not found";
    $self->{db}->dbh->do(
        q{
            UPDATE donation_campaigns
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
    return $self->get_campaign($id);
}

sub archive_campaign {
    my ($self, $id) = @_;
    my $campaign = $self->get_campaign($id) or die "donation campaign not found";
    $self->{db}->dbh->do(
        q{
            UPDATE donation_campaigns
            SET status = 'archived',
                archived_at = COALESCE(archived_at, ?),
                updated_at = ?
            WHERE id = ?
        },
        undef,
        now(),
        now(),
        int($id || 0)
    );
    return $campaign;
}

sub recent_donations {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 100, 1, 1000);
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT d.*, c.title AS campaign_title, c.slug AS campaign_slug
            FROM donations d
            LEFT JOIN donation_campaigns c ON c.id = d.campaign_id
            ORDER BY d.created_at DESC, d.id DESC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub donation_by_id {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT d.*, c.title AS campaign_title, c.slug AS campaign_slug
            FROM donations d
            LEFT JOIN donation_campaigns c ON c.id = d.campaign_id
            WHERE d.id = ?
        },
        undef,
        $id
    );
}

sub csv_export {
    my ($self) = @_;
    my @headers = qw(id campaign_title status amount currency donor_email donor_name anonymous donor_message stripe_checkout_session_id stripe_payment_intent_id created_at paid_at);
    my $csv = join(',', @headers) . "\n";
    for my $row (@{ $self->recent_donations(limit => 100000) }) {
        my %export = %{$row};
        $export{amount} = price_label($row->{amount_cents}, $row->{currency});
        $csv .= join(',', map { _csv($export{$_} // '') } @headers) . "\n";
    }
    return $csv;
}

sub create_checkout {
    my ($self, %args) = @_;
    die "Donation Payments are not available on this plan or checkout is not ready"
        unless $self->checkout_ready;
    my $campaign = $self->get_campaign($args{campaign_id}) or die "donation campaign not found";
    die "donation campaign is not published" unless ($campaign->{status} || '') eq 'published';
    my $settings = _settings($self);
    my $key = $settings->{stripe_secret_key} || '';
    die "Stripe secret key is not configured" unless length $key;

    my $amount = _donation_amount_cents($args{amount} || $args{amount_cents}, $campaign);
    my $currency = _currency($args{currency} || $campaign->{currency});
    my $email = _email_optional($args{donor_email} || $args{email});
    my $name = _text($args{donor_name} || $args{name}, 160);
    my $message = _body($args{donor_message} || $args{message}, 1000);
    my $anonymous = _bool($args{anonymous}) ? 1 : 0;
    my $model = $self->payment_model;
    my $fee_cents = 0;
    my $ts = now();
    my $dbh = $self->{db}->dbh;

    $dbh->do(
        q{
            INSERT INTO donations
                (campaign_id, status, amount_cents, currency, donor_email, donor_name, donor_message,
                 anonymous, platform_fee_cents, created_at, updated_at)
            VALUES (?, 'pending', ?, ?, ?, ?, ?, ?, 0, ?, ?)
        },
        undef,
        int($campaign->{id}),
        $amount,
        $currency,
        $email,
        $name,
        $message,
        $anonymous,
        $ts,
        $ts
    );
    my $donation_id = int($dbh->sqlite_last_insert_rowid);
    my $success_url = campaign_url($self->{config}, $campaign, '/thank-you?session_id={CHECKOUT_SESSION_ID}');
    my $cancel_url = campaign_url($self->{config}, $campaign, '/cancel');
    my %form = (
        mode => 'payment',
        success_url => $success_url,
        cancel_url  => $cancel_url,
        'line_items[0][quantity]' => 1,
        'line_items[0][price_data][currency]' => $currency,
        'line_items[0][price_data][unit_amount]' => $amount,
        'line_items[0][price_data][product_data][name]' => 'Donation: ' . ($campaign->{title} || 'Campaign'),
        'line_items[0][price_data][product_data][description]' => _checkout_description($campaign),
        'metadata[donation_id]' => $donation_id,
        'metadata[donation_campaign_id]' => int($campaign->{id}),
        'metadata[desertcms_payment]' => 'donation',
        'payment_intent_data[metadata][donation_id]' => $donation_id,
        'payment_intent_data[metadata][donation_campaign_id]' => int($campaign->{id}),
        'payment_intent_data[metadata][desertcms_payment]' => 'donation',
    );
    $form{customer_email} = $email if length $email;
    if ($model eq 'platform_marketplace') {
        my $account_id = _stripe_connect_account_id($settings->{stripe_connect_account_id} || '');
        die "Stripe connected payout account is not configured" unless length $account_id;
        $fee_cents = _platform_fee_cents($amount, $settings->{contributor_platform_fee_bps});
        $form{'payment_intent_data[transfer_data][destination]'} = $account_id;
        $form{'payment_intent_data[application_fee_amount]'} = $fee_cents if $fee_cents > 0;
        $form{'payment_intent_data[metadata][stripe_connect_account_id]'} = $account_id;
        $form{'metadata[stripe_connect_account_id]'} = $account_id;
    }

    my $response = $self->{http}->post(
        _stripe_api_base($settings),
        {
            headers => _stripe_headers($key),
            content => _form_encode(\%form),
        }
    );
    my $body = eval { decode_json($response->{content} || '{}') } || {};
    if (!$response->{success} || !$body->{id} || !$body->{url}) {
        $dbh->do('UPDATE donations SET status = ?, updated_at = ? WHERE id = ?', undef, 'failed', now(), $donation_id);
        die _stripe_error($body, $response, 'Stripe Checkout session could not be created');
    }
    $dbh->do(
        'UPDATE donations SET stripe_checkout_session_id = ?, platform_fee_cents = ?, updated_at = ? WHERE id = ?',
        undef,
        _text($body->{id}, 160),
        $fee_cents,
        now(),
        $donation_id
    );
    return {
        donation_id => $donation_id,
        url         => $body->{url},
        session_id  => $body->{id},
    };
}

sub handle_webhook {
    my ($self, %args) = @_;
    my $payload = defined $args{payload} ? $args{payload} : '';
    my $signature = $args{signature} || '';
    my $settings = _settings($self);
    my $secret = $settings->{stripe_webhook_secret} || '';
    die "Stripe webhook secret is not configured" unless length $secret;
    _verify_signature(
        payload   => $payload,
        header    => $signature,
        secret    => $secret,
        tolerance => int($settings->{stripe_webhook_tolerance_seconds} || 300),
    );
    my $event = decode_json($payload);
    my $event_id = _text($event->{id}, 160);
    my $event_type = _text($event->{type}, 120);
    die "Stripe event id is missing" unless length $event_id;
    die "Stripe event type is missing" unless length $event_type;
    my $object = $event->{data} && ref $event->{data} eq 'HASH' ? $event->{data}{object} : undef;
    return { ok => 1, duplicate => 1 } unless $self->_record_stripe_event($event_id, $event_type);
    if ($event_type eq 'checkout.session.completed'
        || $event_type eq 'checkout.session.async_payment_succeeded') {
        $self->_mark_donation_paid($object, $event_id);
    } elsif ($event_type eq 'checkout.session.expired') {
        $self->_mark_donation_status($object, 'canceled', $event_id);
    } elsif ($event_type eq 'checkout.session.async_payment_failed') {
        $self->_mark_donation_status($object, 'failed', $event_id);
    }
    return { ok => 1, duplicate => 0 };
}

sub campaign_url {
    my ($config, $campaign, $suffix) = @_;
    my $base = $config->get('site_url') || '';
    $base =~ s{/+\z}{};
    my $slug = $campaign && length($campaign->{slug} || '') ? $campaign->{slug} : '';
    my $path = '/donate/' . $slug;
    $path .= '/' unless $path =~ m{/\z};
    $suffix ||= '';
    $suffix =~ s{\A/+}{};
    $path .= $suffix if length $suffix;
    return length($base) ? $base . $path : $path;
}

sub price_label {
    my ($cents, $currency) = @_;
    $cents = int($cents || 0);
    $currency = uc(_currency($currency));
    return sprintf('%s %.2f', $currency, $cents / 100);
}

sub suggested_amounts {
    my ($campaign) = @_;
    my @amounts = grep { $_ > 0 } map { _price_cents($_) } split /\s*,\s*/, ($campaign->{suggested_amounts_text} || '');
    my %seen;
    @amounts = grep { !$seen{$_}++ } @amounts;
    return \@amounts;
}

sub progress_percent {
    my ($campaign) = @_;
    my $goal = int($campaign->{goal_amount_cents} || 0);
    return 0 unless $goal > 0;
    my $raised = int($campaign->{raised_cents} || 0);
    my $pct = int(($raised / $goal) * 100 + 0.5);
    return $pct > 100 ? 100 : $pct;
}

sub campaign_body_html {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s{\r\n?}{\n}g;
    my @chunks = grep { length } map { _trim($_) } split /\n{2,}/, $text;
    return '<p>Donation details will appear here.</p>' unless @chunks;

    my $html = '';
    for my $chunk (@chunks) {
        my @lines = grep { length } map { _trim($_) } split /\n/, $chunk;
        next unless @lines;
        if (@lines >= 3 && _body_lines_look_like_list(@lines)) {
            $html .= '<ul class="donation-body-list">';
            $html .= join '', map { '<li>' . escape_html($_) . '</li>' } @lines;
            $html .= '</ul>';
        } elsif (@lines == 1 && _body_line_looks_like_heading($lines[0])) {
            $html .= '<h3>' . escape_html($lines[0]) . '</h3>';
        } else {
            $html .= '<p>' . join('<br>', map { escape_html($_) } @lines) . '</p>';
        }
    }

    return length $html ? $html : '<p>Donation details will appear here.</p>';
}

sub _body_lines_look_like_list {
    my (@lines) = @_;
    return 0 unless @lines >= 3;
    for my $line (@lines) {
        return 0 if length($line) > 90;
        return 0 if $line =~ /[.!?]\z/;
    }
    return 1;
}

sub _body_line_looks_like_heading {
    my ($line) = @_;
    return 0 unless defined $line && length $line;
    return 0 if length($line) > 90;
    return 0 if $line =~ /[.:!?]\z/;
    return 0 if $line =~ m{https?://}i;
    my @words = grep { length } split /\s+/, $line;
    return 0 if @words > 10;
    return $line =~ /[A-Za-z]/ ? 1 : 0;
}

sub _trim {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\A\s+|\s+\z//g;
    return $value;
}

sub _mark_donation_paid {
    my ($self, $session, $event_id) = @_;
    my $donation = $self->_donation_from_session($session) or die "matching donation not found";
    my $payment_status = $session->{payment_status} || '';
    die "Stripe Checkout session is not paid" if length $payment_status && $payment_status ne 'paid';
    _validate_paid_session($donation, $session);
    my $email = '';
    my $name = '';
    if ($session->{customer_details} && ref $session->{customer_details} eq 'HASH') {
        $email = _email_optional($session->{customer_details}{email} || '');
        $name = _text($session->{customer_details}{name}, 160);
    }
    my $payment_intent = _text($session->{payment_intent}, 160);
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            UPDATE donations
            SET status = 'paid',
                donor_email = CASE WHEN ? = '' THEN donor_email ELSE ? END,
                donor_name = CASE WHEN ? = '' THEN donor_name ELSE ? END,
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
        int($donation->{id})
    );
}

sub _mark_donation_status {
    my ($self, $session, $status, $event_id) = @_;
    my $donation = $self->_donation_from_session($session) or return;
    $self->{db}->dbh->do(
        q{
            UPDATE donations
            SET status = ?,
                stripe_event_id = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        _donation_status($status),
        $event_id,
        now(),
        int($donation->{id})
    );
}

sub _donation_from_session {
    my ($self, $session) = @_;
    return undef unless $session && ref $session eq 'HASH';
    my $session_id = _text($session->{id}, 160);
    return undef unless length $session_id;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM donations WHERE stripe_checkout_session_id = ?',
        undef,
        $session_id
    );
}

sub _record_stripe_event {
    my ($self, $event_id, $event_type) = @_;
    eval {
        $self->{db}->dbh->do(
            q{
                INSERT INTO donation_stripe_events (stripe_event_id, event_type, received_at)
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
    my ($donation, $session) = @_;
    my $session_id = _text($session->{id}, 160);
    if (length($session_id) && length($donation->{stripe_checkout_session_id} || '')) {
        die "Stripe Checkout session id does not match this donation"
            unless $session_id eq $donation->{stripe_checkout_session_id};
    }
    if (defined $session->{amount_total} && length "$session->{amount_total}") {
        die "Stripe amount does not match this donation"
            unless int($session->{amount_total}) == int($donation->{amount_cents} || 0);
    }
    if (defined $session->{currency} && length $session->{currency}) {
        die "Stripe currency does not match this donation"
            unless _currency($session->{currency}) eq _currency($donation->{currency});
    }
    my $metadata = $session->{metadata} && ref $session->{metadata} eq 'HASH'
        ? $session->{metadata}
        : {};
    _validate_metadata_int($metadata, 'donation_id', $donation->{id});
    _validate_metadata_int($metadata, 'donation_campaign_id', $donation->{campaign_id});
}

sub _validate_metadata_int {
    my ($metadata, $key, $expected) = @_;
    return unless defined $metadata->{$key} && length $metadata->{$key};
    die "Stripe metadata $key does not match this donation"
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

sub _unique_campaign_slug {
    my ($dbh, $base, $id) = @_;
    $base = _slug($base) || 'donation-campaign';
    my $slug = $base;
    my $i = 2;
    while (1) {
        my ($existing) = $dbh->selectrow_array(
            'SELECT id FROM donation_campaigns WHERE slug = ? AND (? = 0 OR id <> ?) LIMIT 1',
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

sub _campaign_status {
    my ($status) = @_;
    $status = lc(_text($status, 20));
    return $CAMPAIGN_STATUS{$status} ? $status : 'draft';
}

sub _donation_status {
    my ($status) = @_;
    $status = lc(_text($status, 20));
    return $DONATION_STATUS{$status} ? $status : 'pending';
}

sub _donation_amount_cents {
    my ($value, $campaign) = @_;
    my $amount = _price_cents($value);
    die "donation amount must be at least 1.00" unless $amount >= 100;
    my %suggested = map { $_ => 1 } @{ suggested_amounts($campaign) };
    if (!$campaign->{allow_custom_amount} && %suggested) {
        die "donation amount is not one of the suggested amounts" unless $suggested{$amount};
    }
    return $amount;
}

sub _suggested_amounts {
    my ($value) = @_;
    my @amounts = grep { $_ > 0 } map { _price_cents($_) } split /\s*,\s*/, ($value || '');
    my %seen;
    @amounts = grep { !$seen{$_}++ } @amounts;
    @amounts = sort { $a <=> $b } @amounts;
    return join(', ', map { sprintf('%.2f', $_ / 100) } @amounts);
}

sub _price_cents {
    my ($value) = @_;
    return 0 unless defined $value && "$value" =~ /\S/;
    return int($value) if "$value" =~ /\A[0-9]+\z/ && int($value) > 999;
    die "amount is invalid" unless "$value" =~ /\A[0-9]+(?:\.[0-9]{1,2})?\z/;
    return int((0 + $value) * 100 + 0.5);
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
    $value = _text($value, $max || 10000);
    return $value;
}

sub _image_path {
    my ($value) = @_;
    $value = _text($value, 300);
    return $value if DesertCMS::Media::is_public_image_path($value);
    return '';
}

sub _email_optional {
    my ($value) = @_;
    $value = lc _text($value, 180);
    return '' unless length $value;
    return $value =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/ ? $value : '';
}

sub _currency {
    my ($value) = @_;
    $value = lc _text($value, 3);
    return $value =~ /\A[a-z]{3}\z/ ? $value : 'usd';
}

sub _int {
    my ($value, $default, $min, $max) = @_;
    $value = defined $value && "$value" =~ /\A-?[0-9]+\z/ ? int($value) : $default;
    $value = $min if defined $min && $value < $min;
    $value = $max if defined $max && $value > $max;
    return $value;
}

sub _limit {
    my ($value, $default, $min, $max) = @_;
    $value = int($value || $default || 0);
    $value = $min if $value < $min;
    $value = $max if $value > $max;
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
    return _truthy($decoded->{$key}) ? 1 : 0 if exists $decoded->{$key};
    return 0;
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

sub _stripe_headers {
    my ($key) = @_;
    return {
        Authorization  => 'Basic ' . encode_base64($key . ':', ''),
        'Content-Type' => 'application/x-www-form-urlencoded',
    };
}

sub _stripe_error {
    my ($body, $response, $fallback) = @_;
    return $body->{error}{message}
        if $body && ref $body eq 'HASH' && $body->{error} && ref $body->{error} eq 'HASH' && $body->{error}{message};
    return $response->{reason} if $response && $response->{reason};
    return $fallback || 'Stripe request failed';
}

sub _checkout_description {
    my ($campaign) = @_;
    return _text($campaign->{summary} || 'One-time donation', 500);
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

sub _csv {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

1;
