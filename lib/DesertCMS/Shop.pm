package DesertCMS::Shop;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(encode_base64);
use DesertCMS::Commerce;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Media;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Util qw(
    constant_time_eq escape_html hmac_sha256_hex now
);

my %RIGHTS = (
    personal => {
        label       => 'Personal use',
        price_field => 'personal_price_cents',
        flag_field  => 'personal_enabled',
        description => 'For personal display, reference, and non-commercial use.',
    },
    commercial => {
        label       => 'Commercial use',
        price_field => 'commercial_price_cents',
        flag_field  => 'commercial_enabled',
        description => 'For business, editorial, campaign, and commercial publication use.',
    },
    full => {
        label       => 'Full rights',
        price_field => 'full_rights_price_cents',
        flag_field  => 'full_rights_enabled',
        description => 'A full-rights purchase removes this item from public sale.',
    },
);

my %LISTING_KINDS = (
    product        => 'Product',
    service        => 'Service',
    digital        => 'Digital item',
    portfolio_item => 'Portfolio item',
    inquiry_only   => 'Inquiry only',
    other          => 'Other',
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

sub admin_media_rows {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT
                m.*,
                l.id AS listing_id,
                l.title AS listing_title,
                l.description AS listing_description,
                l.listing_kind,
                l.cta_label,
                l.cta_url,
                l.active AS listing_active,
                l.currency AS listing_currency,
                l.personal_enabled,
                l.personal_price_cents,
                l.commercial_enabled,
                l.commercial_price_cents,
                l.full_rights_enabled,
                l.full_rights_price_cents,
                l.full_rights_sold_at,
                l.full_rights_order_id
            FROM media_assets m
            LEFT JOIN shop_listings l ON l.media_asset_id = m.id
            WHERE m.deleted_at IS NULL
              AND m.public_path LIKE '/assets/media/%'
            ORDER BY m.created_at DESC, m.id DESC
        },
        { Slice => {} }
    );
}

sub admin_contributor_data {
    my ($self, $row) = @_;
    $row ||= {};
    my $site_id = _trim($row->{owner_site_id} || $self->{config}->get('contributor_site_id') || '');
    $site_id = 'main' unless length $site_id;

    my $name = _trim(
        $row->{owner_display_name}
        || $self->{config}->get('contributor_owner_name')
        || ''
    );
    $name = _trim($self->{config}->get('site_name') || 'Main deployment')
        if !length($name) && $site_id eq 'main';
    $name = $site_id unless length $name;

    my $domain = _trim(
        $row->{owner_domain}
        || $self->{config}->get('contributor_domain')
        || ''
    );
    my $email = _email($row->{owner_email} || $self->{config}->get('contributor_owner_email') || '');
    my $uploader = _trim($row->{uploaded_by_username} || '');

    return {
        label  => $name,
        site_id => $site_id,
        domain => $domain,
        email  => $email,
        search => join(' ', grep { length } ($name, $site_id, $domain, $email, $uploader)),
    };
}

sub admin_contributor_filters {
    my ($self, $rows) = @_;
    $rows ||= $self->admin_media_rows;
    my %filters;
    for my $row (@{$rows}) {
        my $data = $self->admin_contributor_data($row);
        my $key = lc($data->{label} || '');
        $key =~ s/\s+/ /g;
        next unless length $key;
        $filters{$key} ||= {
            label  => $data->{label},
            search => $data->{search},
            count  => 0,
        };
        $filters{$key}{count}++;
    }
    return [
        sort { lc($a->{label}) cmp lc($b->{label}) }
        values %filters
    ];
}

sub catalog_items {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT
                l.*,
                m.original_name,
                m.public_path,
                m.alt_text,
                m.width,
                m.height
            FROM shop_listings l
            JOIN media_assets m ON m.id = l.media_asset_id
            WHERE m.deleted_at IS NULL
              AND m.public_path LIKE '/assets/media/%'
              AND l.active = 1
            ORDER BY l.updated_at DESC, l.id DESC
        },
        { Slice => {} }
    );
}

sub listing {
    my ($self, $id) = @_;
    return undef unless int($id || 0);
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT
                l.*,
                m.original_name,
                m.public_path,
                m.alt_text,
                m.width,
                m.height,
                m.deleted_at AS media_deleted_at
            FROM shop_listings l
            JOIN media_assets m ON m.id = l.media_asset_id
            WHERE l.id = ?
              AND m.deleted_at IS NULL
              AND m.public_path LIKE '/assets/media/%'
        },
        undef,
        int($id)
    );
}

sub save_listing {
    my ($self, %args) = @_;
    my $media_asset_id = int($args{media_asset_id} || 0);
    die "media asset is required" unless $media_asset_id;

    my $asset = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM media_assets WHERE id = ? AND deleted_at IS NULL',
        undef,
        $media_asset_id
    ) or die "media asset not found";
    die "shop listings require an image asset with a public optimized derivative"
        unless DesertCMS::Media::is_public_image_path($asset->{public_path} || '');

    my $existing = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM shop_listings WHERE media_asset_id = ?',
        undef,
        $media_asset_id
    );

    my $title = _trim($args{title});
    $title = _trim($asset->{original_name}) unless length $title;
    my $description = _trim_long($args{description});
    my $currency = _currency($args{currency});
    my $listing_kind = _listing_kind(
        exists $args{listing_kind}
            ? $args{listing_kind}
            : ($existing ? $existing->{listing_kind} : 'product')
    );
    my $cta_label = exists $args{cta_label}
        ? _trim($args{cta_label})
        : _trim($existing ? $existing->{cta_label} : '');
    $cta_label = 'Request info' unless length $cta_label;
    my $cta_url = exists $args{cta_url}
        ? _clean_cta_url($args{cta_url})
        : _clean_cta_url($existing ? $existing->{cta_url} : '');
    my $active = $args{active} ? 1 : 0;
    my %values = (
        personal_enabled        => exists $args{personal_enabled} ? ($args{personal_enabled} ? 1 : 0) : int($existing ? $existing->{personal_enabled} || 0 : 0),
        personal_price_cents    => exists $args{personal_price} ? _price_cents($args{personal_price}) : int($existing ? $existing->{personal_price_cents} || 0 : 0),
        commercial_enabled      => exists $args{commercial_enabled} ? ($args{commercial_enabled} ? 1 : 0) : int($existing ? $existing->{commercial_enabled} || 0 : 0),
        commercial_price_cents  => exists $args{commercial_price} ? _price_cents($args{commercial_price}) : int($existing ? $existing->{commercial_price_cents} || 0 : 0),
        full_rights_enabled     => exists $args{full_rights_enabled} ? ($args{full_rights_enabled} ? 1 : 0) : int($existing ? $existing->{full_rights_enabled} || 0 : 0),
        full_rights_price_cents => exists $args{full_rights_price} ? _price_cents($args{full_rights_price}) : int($existing ? $existing->{full_rights_price_cents} || 0 : 0),
    );

    if ($existing && $existing->{full_rights_sold_at}) {
        $active = 0;
        $values{personal_enabled} = 0;
        $values{commercial_enabled} = 0;
        $values{full_rights_enabled} = 0;
    }

    my $ts = now();
    my $dbh = $self->{db}->dbh;
    if ($existing) {
        $dbh->do(
            q{
                UPDATE shop_listings
                SET title = ?,
                    description = ?,
                    listing_kind = ?,
                    cta_label = ?,
                    cta_url = ?,
                    active = ?,
                    currency = ?,
                    personal_enabled = ?,
                    personal_price_cents = ?,
                    commercial_enabled = ?,
                    commercial_price_cents = ?,
                    full_rights_enabled = ?,
                    full_rights_price_cents = ?,
                    updated_at = ?
                WHERE media_asset_id = ?
            },
            undef,
            $title,
            $description,
            $listing_kind,
            $cta_label,
            $cta_url,
            $active,
            $currency,
            $values{personal_enabled},
            $values{personal_price_cents},
            $values{commercial_enabled},
            $values{commercial_price_cents},
            $values{full_rights_enabled},
            $values{full_rights_price_cents},
            $ts,
            $media_asset_id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO shop_listings
                    (media_asset_id, title, description, listing_kind, cta_label, cta_url, active, currency,
                     personal_enabled, personal_price_cents,
                     commercial_enabled, commercial_price_cents,
                     full_rights_enabled, full_rights_price_cents,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $media_asset_id,
            $title,
            $description,
            $listing_kind,
            $cta_label,
            $cta_url,
            $active,
            $currency,
            $values{personal_enabled},
            $values{personal_price_cents},
            $values{commercial_enabled},
            $values{commercial_price_cents},
            $values{full_rights_enabled},
            $values{full_rights_price_cents},
            $ts,
            $ts
        );
    }

    return $dbh->selectrow_hashref(
        'SELECT * FROM shop_listings WHERE media_asset_id = ?',
        undef,
        $media_asset_id
    );
}

sub rights_options {
    my ($class, $listing) = @_;
    my @types = qw(personal commercial full);
    my @options;
    for my $type (@types) {
        my $meta = $RIGHTS{$type};
        my $price = int($listing->{$meta->{price_field}} || 0);
        my $enabled = $listing->{$meta->{flag_field}} ? 1 : 0;
        my $sold = $type eq 'full' && $listing->{full_rights_sold_at} ? 1 : 0;
        push @options, {
            type        => $type,
            label       => $meta->{label},
            description => $meta->{description},
            price_cents => $price,
            price_label => price_label($price, $listing->{currency}),
            enabled     => ($enabled && $price > 0 && !$sold) ? 1 : 0,
            sold        => $sold,
        };
    }
    return \@options;
}

sub purchase_token {
    my ($self, $listing, $rights_type) = @_;
    return '' unless $listing && $RIGHTS{$rights_type || ''};
    my $option = _option_for($listing, $rights_type) or return '';
    return '' unless $option->{enabled};

    my $data = join ':',
        int($listing->{id} || 0),
        int($listing->{media_asset_id} || 0),
        $rights_type,
        int($option->{price_cents} || 0),
        _currency($listing->{currency});
    my $mac = hmac_sha256_hex($data, $self->{config}->app_secret);
    return "$data:$mac";
}

sub verify_purchase_token {
    my ($self, $listing, $rights_type, $token) = @_;
    return 0 unless $listing && $RIGHTS{$rights_type || ''};
    return 0 unless defined $token && length $token;

    my @parts = split /:/, $token;
    return 0 unless @parts == 6;
    my ($listing_id, $media_asset_id, $token_rights, $price_cents, $currency, $mac) = @parts;
    return 0 unless $listing_id =~ /\A[0-9]+\z/ && $media_asset_id =~ /\A[0-9]+\z/ && $price_cents =~ /\A[0-9]+\z/;
    return 0 unless $token_rights eq $rights_type;
    return 0 unless int($listing_id) == int($listing->{id} || 0);
    return 0 unless int($media_asset_id) == int($listing->{media_asset_id} || 0);

    my $option = _option_for($listing, $rights_type) or return 0;
    return 0 unless $option->{enabled};
    return 0 unless int($price_cents) == int($option->{price_cents} || 0);
    return 0 unless _currency($currency) eq _currency($listing->{currency});

    my $data = join ':',
        int($listing->{id} || 0),
        int($listing->{media_asset_id} || 0),
        $rights_type,
        int($option->{price_cents} || 0),
        _currency($listing->{currency});
    my $expected = hmac_sha256_hex($data, $self->{config}->app_secret);
    return constant_time_eq(lc($mac), $expected);
}

sub create_checkout {
    my ($self, %args) = @_;
    my $listing = $self->listing($args{listing_id}) or die "listing not found";
    die "listing is not active" unless $listing->{active};

    my $rights_type = $args{rights_type} || '';
    die "unsupported rights type" unless $RIGHTS{$rights_type};
    my $option = _option_for($listing, $rights_type);
    die "selected rights are not available" unless $option->{enabled};
    if (_truthy($self->_setting('shop_require_purchase_token'))) {
        die "purchase token is invalid or expired"
            unless $self->verify_purchase_token($listing, $rights_type, $args{purchase_token});
    }

    my $settings = _settings($self);
    die "Shop payments are not available on this plan or checkout is not ready"
        unless $self->checkout_ready;
    my $key = $self->_setting('stripe_secret_key') || '';
    die "Stripe secret key is not configured" unless length $key;
    my $commerce_model = DesertCMS::Commerce::model($self->{config}, $settings);

    my $dbh = $self->{db}->dbh;
    my $ts = now();
    $dbh->do(
        q{
            INSERT INTO shop_orders
                (listing_id, media_asset_id, rights_type, status, currency, amount_cents,
                 customer_email, created_at, updated_at)
            VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?)
        },
        undef,
        $listing->{id},
        $listing->{media_asset_id},
        $rights_type,
        _currency($listing->{currency}),
        $option->{price_cents},
        _email($args{customer_email}),
        $ts,
        $ts
    );
    my $order_id = $dbh->sqlite_last_insert_rowid;

    my $success_url = $self->shop_url('/success?order=' . $order_id);
    my $cancel_url = $self->shop_url('/cancel?order=' . $order_id);
    my $name = ($listing->{title} || $listing->{original_name} || 'Catalog item')
        . ' - '
        . $option->{label};
    my $description = $option->{description};
    my $image = $listing->{public_path}
        ? $self->shop_url($listing->{public_path})
        : '';

    my %form = (
        mode => 'payment',
        success_url => $success_url,
        cancel_url => $cancel_url,
        client_reference_id => $order_id,
        'line_items[0][quantity]' => 1,
        'line_items[0][price_data][currency]' => _currency($listing->{currency}),
        'line_items[0][price_data][unit_amount]' => $option->{price_cents},
        'line_items[0][price_data][product_data][name]' => $name,
        'line_items[0][price_data][product_data][description]' => $description,
        'metadata[order_id]' => $order_id,
        'metadata[listing_id]' => $listing->{id},
        'metadata[media_asset_id]' => $listing->{media_asset_id},
        'metadata[rights_type]' => $rights_type,
        'payment_intent_data[metadata][order_id]' => $order_id,
        'payment_intent_data[metadata][listing_id]' => $listing->{id},
        'payment_intent_data[metadata][media_asset_id]' => $listing->{media_asset_id},
        'payment_intent_data[metadata][rights_type]' => $rights_type,
    );
    if ($commerce_model eq 'platform_marketplace') {
        my $account_id = _stripe_connect_account_id($settings->{stripe_connect_account_id} || '');
        die "Stripe connected payout account is not configured" unless length $account_id;
        my $fee_cents = _platform_fee_cents($option->{price_cents}, $settings->{contributor_platform_fee_bps});
        $form{'payment_intent_data[transfer_data][destination]'} = $account_id;
        $form{'payment_intent_data[application_fee_amount]'} = $fee_cents if $fee_cents > 0;
        $form{'payment_intent_data[metadata][stripe_connect_account_id]'} = $account_id;
        $form{'metadata[stripe_connect_account_id]'} = $account_id;
    }
    $form{'customer_email'} = _email($args{customer_email}) if _email($args{customer_email});
    $form{'line_items[0][price_data][product_data][images][0]'} = $image if length $image;

    my $response = $self->{http}->post(
        $self->_setting('stripe_api_base') || 'https://api.stripe.com/v1/checkout/sessions',
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
        $dbh->do(
            'UPDATE shop_orders SET status = ?, updated_at = ? WHERE id = ?',
            undef,
            'failed',
            now(),
            $order_id
        );
        my $message = $body->{error} && $body->{error}{message}
            ? $body->{error}{message}
            : ($response->{reason} || 'Stripe Checkout session could not be created');
        die $message;
    }

    $dbh->do(
        'UPDATE shop_orders SET stripe_checkout_session_id = ?, updated_at = ? WHERE id = ?',
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
    return undef unless int($id || 0);
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT
                o.*,
                l.title AS listing_title,
                l.description AS listing_description,
                m.original_name,
                m.public_path,
                m.alt_text
            FROM shop_orders o
            JOIN shop_listings l ON l.id = o.listing_id
            JOIN media_assets m ON m.id = o.media_asset_id
            WHERE o.id = ?
        },
        undef,
        int($id)
    );
}

sub recent_orders {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 25);
    $limit = 25 if $limit < 1 || $limit > 100;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT
                o.*,
                l.title AS listing_title,
                m.original_name
            FROM shop_orders o
            JOIN shop_listings l ON l.id = o.listing_id
            JOIN media_assets m ON m.id = o.media_asset_id
            ORDER BY o.created_at DESC, o.id DESC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub handle_webhook {
    my ($self, %args) = @_;
    my $payload = defined $args{payload} ? $args{payload} : '';
    my $signature = $args{signature} || '';
    my $secret = $self->_setting('stripe_webhook_secret') || '';
    die "Stripe webhook secret is not configured" unless length $secret;
    _verify_signature(
        payload   => $payload,
        header    => $signature,
        secret    => $secret,
        tolerance => int($self->_setting('stripe_webhook_tolerance_seconds') || 300),
    );

    my $event = eval { decode_json($payload) };
    die "invalid Stripe webhook JSON" if $@ || ref $event ne 'HASH';
    my $event_id = $event->{id} || '';
    my $event_type = $event->{type} || '';
    die "Stripe event is missing an id" unless length $event_id;

    my ($seen) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM shop_stripe_events WHERE stripe_event_id = ?',
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

sub shop_url {
    my ($self, $path) = @_;
    $path = '/' . ($path || '') unless ($path || '') =~ m{\A/};
    my $base = $self->_setting('shop_url') || '';
    my $uses_path_prefix = 0;
    my $base_path = '';
    if (!length $base) {
        my $domain = $self->_setting('shop_domain') || '';
        if (length $domain) {
            my $site = $self->{config}->get('site_url') || '';
            my $scheme = $site =~ m{\Ahttp://}i ? 'http' : 'https';
            $base = "$scheme://$domain";
        } else {
            $base = $self->{config}->get('site_url') || '';
            $uses_path_prefix = 1;
        }
    }
    $base =~ s{/+\z}{};
    if ($base =~ m{\A(https?://[^/]+)(/.*)\z}i) {
        $base = $1;
        $base_path = $2;
        $base_path =~ s{/+\z}{};
    }
    if (_is_shop_route_path($path)) {
        my $is_stripe_webhook_path = $path =~ m{\A/stripe(?:/|\z)};
        if (!$is_stripe_webhook_path && length $base_path) {
            $path = $base_path . ($path eq '/' ? '' : $path);
        } elsif (!$is_stripe_webhook_path && $uses_path_prefix) {
            $path = '/shop' . ($path eq '/' ? '' : $path);
        }
    }
    return $base ? $base . $path : $path;
}

sub shop_host {
    my ($self) = @_;
    my $domain = lc($self->_setting('shop_domain') || '');
    return $domain if length $domain;
    my $url = $self->_setting('shop_url') || '';
    if ($url =~ m{\Ahttps?://([^/:]+)(?::[0-9]+)?(/[^?#]*)?}i) {
        my $host = lc($1);
        my $path = $2 || '';
        $path =~ s{/+\z}{};
        return length $path ? '' : $host;
    }
    return '';
}

sub enabled {
    my ($self) = @_;
    return $self->catalog_enabled;
}

sub catalog_enabled {
    my ($self) = @_;
    my $settings = _settings($self);
    return 0 unless DesertCMS::Modules::enabled($settings, 'shop');
    return DesertCMS::Commerce::catalog_enabled($settings);
}

sub checkout_enabled {
    my ($self) = @_;
    my $settings = _settings($self);
    return 0 unless $self->catalog_enabled;
    return DesertCMS::Commerce::checkout_enabled($self->{config}, $settings);
}

sub checkout_ready {
    my ($self) = @_;
    my $settings = _settings($self);
    return 0 unless $self->catalog_enabled;
    return DesertCMS::Commerce::checkout_ready($self->{config}, $settings);
}

sub settings {
    my ($self) = @_;
    return { %{_settings($self)} };
}

sub clear_settings_cache {
    my ($self) = @_;
    delete $self->{settings_cache};
    delete $self->{settings_cache_generation};
    return 1;
}

sub price_label {
    my ($cents, $currency) = @_;
    $cents = int($cents || 0);
    my $symbol = (_currency($currency) eq 'usd') ? '$' : uc(_currency($currency)) . ' ';
    return $symbol . sprintf('%.2f', $cents / 100);
}

sub rights_label {
    my ($class, $type) = @_;
    return $RIGHTS{$type || ''}{label} || 'Rights';
}

sub listing_kind_label {
    my ($class, $kind) = @_;
    return $LISTING_KINDS{_listing_kind($kind)} || $LISTING_KINDS{other};
}

sub webhook_signature_header {
    my ($class, %args) = @_;
    my $timestamp = $args{timestamp} || now();
    my $payload = defined $args{payload} ? $args{payload} : '';
    my $secret = $args{secret} || '';
    my $digest = hmac_sha256_hex($timestamp . '.' . $payload, $secret);
    return "t=$timestamp,v1=$digest";
}

sub _mark_order_paid {
    my ($self, $session, $event_id) = @_;
    my $order = $self->_order_from_session($session) or die "matching shop order not found";
    my $payment_status = $session->{payment_status} || '';
    die "Stripe Checkout session is not paid" if length $payment_status && $payment_status ne 'paid';
    _validate_paid_session($order, $session);

    my $email = '';
    my $name = '';
    if ($session->{customer_details} && ref $session->{customer_details} eq 'HASH') {
        $email = _email($session->{customer_details}{email});
        $name = _trim($session->{customer_details}{name});
    }
    my $payment_intent = _trim($session->{payment_intent});
    my $ts = now();
    my $dbh = $self->{db}->dbh;

    $dbh->begin_work;
    eval {
        $dbh->do(
            q{
                UPDATE shop_orders
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
            $email,
            $email,
            $name,
            $name,
            $payment_intent,
            $payment_intent,
            $event_id,
            $ts,
            $ts,
            $order->{id}
        );
        if (($order->{rights_type} || '') eq 'full') {
            $dbh->do(
                q{
                    UPDATE shop_listings
                    SET active = 0,
                        personal_enabled = 0,
                        commercial_enabled = 0,
                        full_rights_enabled = 0,
                        full_rights_sold_at = COALESCE(full_rights_sold_at, ?),
                        full_rights_order_id = COALESCE(full_rights_order_id, ?),
                        updated_at = ?
                    WHERE id = ?
                },
                undef,
                $ts,
                $order->{id},
                $ts,
                $order->{listing_id}
            );
        }
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'order update failed';
        eval { $dbh->rollback };
        die $err;
    };
}

sub _record_stripe_event {
    my ($self, $event_id, $event_type) = @_;
    eval {
        $self->{db}->dbh->do(
            q{
                INSERT INTO shop_stripe_events (stripe_event_id, event_type, received_at)
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
    my $session_id = _trim($session->{id});
    if (length($session_id) && length($order->{stripe_checkout_session_id} || '')) {
        die "Stripe Checkout session id does not match this order"
            unless $session_id eq $order->{stripe_checkout_session_id};
    }
    if (defined $session->{amount_total} && length "$session->{amount_total}") {
        die "Stripe amount does not match this order"
            unless int($session->{amount_total}) == int($order->{amount_cents} || 0);
    }
    if (defined $session->{currency} && length $session->{currency}) {
        die "Stripe currency does not match this order"
            unless _currency($session->{currency}) eq _currency($order->{currency});
    }

    my $metadata = $session->{metadata} && ref $session->{metadata} eq 'HASH'
        ? $session->{metadata}
        : {};
    _metadata_matches($metadata, 'order_id', $order->{id});
    _metadata_matches($metadata, 'listing_id', $order->{listing_id});
    _metadata_matches($metadata, 'media_asset_id', $order->{media_asset_id});
    if (defined $metadata->{rights_type} && length $metadata->{rights_type}) {
        die "Stripe rights type does not match this order"
            unless $metadata->{rights_type} eq ($order->{rights_type} || '');
    }
}

sub _metadata_matches {
    my ($metadata, $key, $expected) = @_;
    return unless defined $metadata->{$key} && length $metadata->{$key};
    die "Stripe metadata $key does not match this order"
        unless int($metadata->{$key}) == int($expected || 0);
}

sub _mark_order_status {
    my ($self, $session, $status, $event_id) = @_;
    my $order = $self->_order_from_session($session) or return;
    return if ($order->{status} || '') eq 'paid';
    $self->{db}->dbh->do(
        q{
            UPDATE shop_orders
            SET status = ?,
                stripe_event_id = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        $status,
        $event_id,
        now(),
        $order->{id}
    );
}

sub _order_from_session {
    my ($self, $session) = @_;
    my $metadata = $session->{metadata} && ref $session->{metadata} eq 'HASH'
        ? $session->{metadata}
        : {};
    my $order_id = int($metadata->{order_id} || $session->{client_reference_id} || 0);
    if ($order_id) {
        my $order = $self->order($order_id);
        return $order if $order;
    }
    my $session_id = _trim($session->{id});
    return undef unless length $session_id;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM shop_orders WHERE stripe_checkout_session_id = ?',
        undef,
        $session_id
    );
}

sub _option_for {
    my ($listing, $rights_type) = @_;
    for my $option (@{__PACKAGE__->rights_options($listing)}) {
        return $option if $option->{type} eq $rights_type;
    }
    return undef;
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

sub _currency {
    my ($value) = @_;
    $value = lc($value || 'usd');
    $value =~ s/^\s+|\s+$//g;
    return $value =~ /\A[a-z]{3}\z/ ? $value : 'usd';
}

sub _listing_kind {
    my ($value) = @_;
    $value = lc($value || 'product');
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/[-\s]+/_/g;
    return $LISTING_KINDS{$value} ? $value : 'other';
}

sub _clean_cta_url {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return '' unless length $value;
    return $value if $value =~ m{\A(?:https?://|mailto:|/)[^\s<>"']+\z}i;
    return '';
}

sub _is_shop_route_path {
    my ($path) = @_;
    return 1 if $path eq '/';
    return 1 if $path =~ m{\A/(?:checkout|success|cancel)(?:[/?#]|\z)};
    return 1 if $path =~ m{\A/stripe(?:/|\z)};
    return 0;
}

sub _settings {
    my ($self) = @_;
    if ($self->{settings_cache}
        && defined $self->{settings_cache_generation}
        && $self->{settings_cache_generation} == $DesertCMS::Settings::SETTINGS_GENERATION) {
        return $self->{settings_cache};
    }

    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    if (DesertCMS::Commerce::is_contributor_instance($self->{config})
        && DesertCMS::Commerce::model($self->{config}, $settings) eq 'platform_marketplace') {
        my $master = _master_stripe_settings($self);
        for my $key (qw(stripe_secret_key stripe_webhook_secret stripe_api_base)) {
            $settings->{$key} = $master->{$key}
                if $master && length($master->{$key} || '');
        }
    }
    $self->{settings_cache} = $settings;
    $self->{settings_cache_generation} = $DesertCMS::Settings::SETTINGS_GENERATION;
    return $self->{settings_cache};
}

sub _setting {
    my ($self, $key) = @_;
    my $settings = _settings($self);
    return $settings->{$key} if exists $settings->{$key};
    return $self->{config}->get($key);
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
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

sub _stripe_connect_account_id {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
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
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\r\n\t]+/ /g;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s+/ /g;
    return substr($value, 0, 160);
}

sub _trim_long {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\r\t]+/ /g;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\n{3,}/\n\n/g;
    return substr($value, 0, 1200);
}

sub _email {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/^\s+|\s+$//g;
    return $value =~ /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z/ ? $value : '';
}

1;
