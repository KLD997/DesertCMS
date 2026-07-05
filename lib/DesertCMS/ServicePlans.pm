package DesertCMS::ServicePlans;

use strict;
use warnings;
use File::Spec;
use HTTP::Tiny;
use JSON::PP qw(decode_json);
use MIME::Base64 qw(encode_base64);
use DesertCMS::Blueprints;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Util qw(now slugify hmac_sha256_hex constant_time_eq);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config    => $args{config},
        db        => $args{db},
        http      => $args{http} || HTTP::Tiny->new,
        read_only => $args{read_only} ? 1 : 0,
    }, $class;
}

sub ensure_default {
    my ($self) = @_;
    return if $self->{read_only};
    my $dbh = $self->{db}->dbh;
    my ($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM service_plans');
    my $ts = now();
    if (!$count) {
        my $blueprints = DesertCMS::Blueprints->new(config => $self->{config}, db => $self->{db});
        my $blueprint = $blueprints->default_blueprint;
        $dbh->do(
            q{
                INSERT INTO service_plans
                    (name, slug, description, blueprint_id, monthly_price_cents, currency, stripe_price_id,
                     media_quota_mb, media_upload_limit_mb, post_quota, page_quota, features_json, allow_master_gallery, allow_master_posts,
                     allow_postmark_sender_override, allow_stripe_connect, allow_indexing_override, stripe_platform_fee_bps,
                     is_default, created_at, updated_at)
                VALUES
                    (?, ?, ?, ?, 0, 'usd', '', ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 1, ?, ?)
            },
            undef,
            'Free Tier',
            'free-tier',
            'Default free DesertCMS contributor service plan.',
            $blueprint->{id},
            int($blueprint->{media_quota_mb} || 512),
            64,
            int($blueprint->{post_quota} || 100),
            int($blueprint->{page_quota} || 20),
            DesertCMS::Modules::features_json(DesertCMS::Modules::feature_map_from_values({}, $blueprint)),
            _bool($blueprint->{allow_master_gallery}),
            _bool($blueprint->{allow_master_posts}),
            $ts,
            $ts
        );
        return;
    }

    my ($legacy_id) = $dbh->selectrow_array(
        q{
            SELECT id
            FROM service_plans
            WHERE is_default = 1
              AND name = 'Standard Service'
              AND slug = 'standard-service'
              AND monthly_price_cents = 0
              AND NOT EXISTS (SELECT 1 FROM service_plans WHERE slug = 'free-tier')
            LIMIT 1
        }
    );
    if ($legacy_id) {
        $dbh->do(
            q{
                UPDATE service_plans
                SET name = 'Free Tier',
                    slug = 'free-tier',
                    description = 'Default free DesertCMS contributor service plan.',
                    updated_at = ?
                WHERE id = ?
            },
            undef,
            $ts,
            $legacy_id
        );
    }

    my ($default_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM service_plans WHERE is_default = 1');
    return if $default_count;

    my ($id) = $dbh->selectrow_array('SELECT id FROM service_plans ORDER BY id ASC LIMIT 1');
    $dbh->do('UPDATE service_plans SET is_default = 1, updated_at = ? WHERE id = ?', undef, $ts, $id)
        if $id;
}

sub list {
    my ($self) = @_;
    $self->ensure_default unless $self->{read_only};
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT p.*, b.name AS blueprint_name, b.category AS blueprint_category
            FROM service_plans p
            LEFT JOIN contributor_blueprints b ON b.id = p.blueprint_id
            ORDER BY p.is_default DESC, p.monthly_price_cents ASC, p.name ASC, p.id ASC
        },
        { Slice => {} }
    );
}

sub get {
    my ($self, $id) = @_;
    $self->ensure_default unless $self->{read_only};
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT p.*, b.name AS blueprint_name, b.category AS blueprint_category
            FROM service_plans p
            LEFT JOIN contributor_blueprints b ON b.id = p.blueprint_id
            WHERE p.id = ?
        },
        undef,
        $id
    );
}

sub default_plan {
    my ($self) = @_;
    $self->ensure_default unless $self->{read_only};
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT p.*, b.name AS blueprint_name, b.category AS blueprint_category
            FROM service_plans p
            LEFT JOIN contributor_blueprints b ON b.id = p.blueprint_id
            ORDER BY p.is_default DESC, p.id ASC
            LIMIT 1
        }
    );
}

sub select_plan {
    my ($self, $id) = @_;
    my $plan = $self->get($id);
    return $plan if $plan;
    return $self->default_plan;
}

sub snapshot {
    my ($self, $plan) = @_;
    $plan ||= $self->default_plan;
    return {} unless $plan && $plan->{id};
    return {
        schema_version       => 1,
        id                   => int($plan->{id} || 0),
        name                 => $plan->{name} || '',
        slug                 => $plan->{slug} || '',
        monthly_price_cents  => int($plan->{monthly_price_cents} || 0),
        currency             => _currency($plan->{currency}),
        stripe_price_id      => $plan->{stripe_price_id} || '',
        media_quota_mb       => int($plan->{media_quota_mb} || 0),
        media_upload_limit_mb => int($plan->{media_upload_limit_mb} || 0),
        post_quota           => int($plan->{post_quota} || 0),
        page_quota           => int($plan->{page_quota} || 0),
        features             => DesertCMS::Modules::feature_map_for_plan($plan),
        features_json        => DesertCMS::Modules::features_json(DesertCMS::Modules::feature_map_for_plan($plan)),
        allow_master_gallery => _bool($plan->{allow_master_gallery}),
        allow_master_posts   => _bool($plan->{allow_master_posts}),
        allow_postmark_sender_override => _bool($plan->{allow_postmark_sender_override}),
        allow_stripe_connect => _bool($plan->{allow_stripe_connect}),
        allow_indexing_override => _bool($plan->{allow_indexing_override}),
        stripe_platform_fee_bps => int($plan->{stripe_platform_fee_bps} || 0),
    };
}

sub save {
    my ($self, %args) = @_;
    die "service plans are read-only in this context" if $self->{read_only};
    my $id = int($args{id} || 0);
    my $name = _clean_text($args{name}, 120);
    die "service plan name is required" unless length $name;
    my $slug = slugify(_clean_text($args{slug}, 120) || $name);
    my $description = _clean_text($args{description}, 500);
    my $blueprints = DesertCMS::Blueprints->new(config => $self->{config}, db => $self->{db});
    my $blueprint = $blueprints->select_blueprint($args{blueprint_id});
    my $ts = now();
    my %values = (
        name                => $name,
        slug                => $slug,
        description         => $description,
        blueprint_id        => $blueprint->{id},
        monthly_price_cents => _price_cents(\%args),
        currency            => _currency($args{currency}),
        stripe_price_id     => _stripe_price_id($args{stripe_price_id}),
        media_quota_mb      => _quota($args{media_quota_mb}, int($blueprint->{media_quota_mb} || 512), 1, 102400),
        media_upload_limit_mb => _quota($args{media_upload_limit_mb}, 64, 1, 1024),
        post_quota          => _quota($args{post_quota}, int($blueprint->{post_quota} || 100), 0, 100000),
        page_quota          => _quota($args{page_quota}, int($blueprint->{page_quota} || 20), 0, 100000),
        features_json       => DesertCMS::Modules::features_json(
            DesertCMS::Modules::feature_map_from_values(\%args, $blueprint)
        ),
        allow_master_gallery => _bool($args{allow_master_gallery}),
        allow_master_posts   => _bool($args{allow_master_posts}),
        allow_postmark_sender_override => _bool($args{allow_postmark_sender_override}),
        allow_stripe_connect => _bool($args{allow_stripe_connect}),
        allow_indexing_override => _bool($args{allow_indexing_override}),
        stripe_platform_fee_bps => _basis_points(
            defined $args{stripe_platform_fee_percent}
                ? $args{stripe_platform_fee_percent}
                : $args{stripe_platform_fee_bps}
        ),
    );

    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        if ($id > 0 && $self->get($id)) {
            $dbh->do(
                q{
                    UPDATE service_plans
                    SET name = ?, slug = ?, description = ?, blueprint_id = ?,
                        monthly_price_cents = ?, currency = ?, stripe_price_id = ?,
                        media_quota_mb = ?, media_upload_limit_mb = ?, post_quota = ?, page_quota = ?, features_json = ?,
                        allow_master_gallery = ?, allow_master_posts = ?,
                        allow_postmark_sender_override = ?, allow_stripe_connect = ?, allow_indexing_override = ?, stripe_platform_fee_bps = ?,
                        updated_at = ?
                    WHERE id = ?
                },
                undef,
                @values{qw(
                    name slug description blueprint_id monthly_price_cents currency stripe_price_id
                    media_quota_mb media_upload_limit_mb post_quota page_quota features_json allow_master_gallery allow_master_posts
                    allow_postmark_sender_override allow_stripe_connect allow_indexing_override stripe_platform_fee_bps
                )},
                $ts,
                $id
            );
        } else {
            $dbh->do(
                q{
                    INSERT INTO service_plans
                        (name, slug, description, blueprint_id, monthly_price_cents, currency, stripe_price_id,
                         media_quota_mb, media_upload_limit_mb, post_quota, page_quota, features_json, allow_master_gallery, allow_master_posts,
                         allow_postmark_sender_override, allow_stripe_connect, allow_indexing_override, stripe_platform_fee_bps,
                         is_default, created_at, updated_at)
                    VALUES
                        (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                },
                undef,
                @values{qw(
                    name slug description blueprint_id monthly_price_cents currency stripe_price_id
                    media_quota_mb media_upload_limit_mb post_quota page_quota features_json allow_master_gallery allow_master_posts
                    allow_postmark_sender_override allow_stripe_connect allow_indexing_override stripe_platform_fee_bps
                )},
                $ts,
                $ts
            );
            $id = int($dbh->sqlite_last_insert_rowid);
        }
        $self->_set_default_locked($id) if _bool($args{is_default});
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown service plan save failure';
        eval { $dbh->rollback };
        die $err;
    };

    $self->ensure_default;
    return $self->get($id);
}

sub set_default {
    my ($self, $id) = @_;
    die "service plans are read-only in this context" if $self->{read_only};
    $id = int($id || 0);
    die "service plan id is required" unless $id > 0;
    die "service plan not found" unless $self->get($id);
    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        $self->_set_default_locked($id);
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown default service plan failure';
        eval { $dbh->rollback };
        die $err;
    };
    return $self->get($id);
}

sub assign_site {
    my ($self, %args) = @_;
    die "service plans are read-only in this context" if $self->{read_only};
    my $site_id = _clean_site_id($args{site_id});
    die "site id is required" unless length $site_id;
    my $plan = $self->select_plan($args{plan_id});
    die "service plan is required" unless $plan && $plan->{id};

    my $site = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM contributor_sites WHERE site_id = ?',
        undef,
        $site_id
    ) or die "contributor site not found";
    my $root = _domain_root($self);
    die "site domain is not under the contributor root"
        if length $root && !_domain_is_subdomain($site->{domain}, $root);

    my $status = _billing_status($args{billing_status});
    my $email = _normalize_email($args{billing_email} || $site->{owner_email});
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            UPDATE contributor_sites
            SET service_plan_id = ?,
                billing_status = ?,
                billing_email = ?,
                stripe_customer_id = ?,
                stripe_subscription_id = ?,
                billing_started_at = COALESCE(billing_started_at, ?),
                billing_current_period_end = ?,
                media_quota_mb = ?,
                media_upload_limit_mb = ?,
                post_quota = ?,
                page_quota = ?,
                allow_master_gallery = ?,
                allow_master_posts = ?,
                updated_at = ?
            WHERE site_id = ?
        },
        undef,
        int($plan->{id}),
        $status,
        $email,
        _stripe_customer_id($args{stripe_customer_id}),
        _stripe_subscription_id($args{stripe_subscription_id}),
        $ts,
        _optional_epoch($args{billing_current_period_end}),
        int($plan->{media_quota_mb} || 0),
        int($plan->{media_upload_limit_mb} || 0),
        int($plan->{post_quota} || 0),
        int($plan->{page_quota} || 0),
        _bool($plan->{allow_master_gallery}),
        _bool($plan->{allow_master_posts}),
        $ts,
        $site_id
    );
    my $updated = $self->site_with_plan($site_id);
    $updated->{plan_sync} = $self->_sync_site_settings($updated, $plan);
    return $updated;
}

sub site_with_plan {
    my ($self, $site_id) = @_;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT s.*, p.name AS service_plan_name, p.slug AS service_plan_slug,
                   p.monthly_price_cents, p.currency, p.stripe_price_id,
                   p.features_json AS service_plan_features_json,
                   p.allow_postmark_sender_override, p.allow_stripe_connect,
                   p.allow_indexing_override, p.stripe_platform_fee_bps
            FROM contributor_sites s
            LEFT JOIN service_plans p ON p.id = s.service_plan_id
            WHERE s.site_id = ?
        },
        undef,
        $site_id
    );
}

sub fleet_usage {
    my ($self) = @_;
    $self->ensure_default;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT s.*, p.name AS service_plan_name, p.slug AS service_plan_slug,
                   p.monthly_price_cents, p.currency, p.stripe_price_id,
                   p.features_json AS service_plan_features_json,
                   p.allow_postmark_sender_override, p.allow_stripe_connect,
                   p.allow_indexing_override, p.stripe_platform_fee_bps
            FROM contributor_sites s
            LEFT JOIN service_plans p ON p.id = s.service_plan_id
            ORDER BY s.created_at DESC, s.id DESC
        },
        { Slice => {} }
    );
    my $root = _domain_root($self);
    my @sites = length $root
        ? grep { _domain_is_subdomain($_->{domain}, $root) } @{$rows}
        : @{$rows};
    for my $site (@sites) {
        $site->{usage} = $self->site_usage($site);
    }
    return \@sites;
}

sub usage_summary {
    my ($self, $sites) = @_;
    $sites ||= $self->fleet_usage;
    my %summary = (
        sites             => scalar @{$sites},
        assigned          => 0,
        unassigned        => 0,
        active_billing    => 0,
        past_due          => 0,
        monthly_cents     => 0,
        quota_warnings    => 0,
        unavailable_usage => 0,
    );
    for my $site (@{$sites}) {
        if ($site->{service_plan_id}) {
            $summary{assigned}++;
        } else {
            $summary{unassigned}++;
        }
        my $billing = $site->{billing_status} || 'comped';
        $summary{active_billing}++ if $billing eq 'active' || $billing eq 'trialing';
        $summary{past_due}++ if $billing eq 'past_due';
        $summary{monthly_cents} += int($site->{monthly_price_cents} || 0)
            if ($site->{status} || '') eq 'active' && ($billing eq 'active' || $billing eq 'trialing');
        my $usage = $site->{usage} || {};
        $summary{unavailable_usage}++ unless $usage->{available};
        $summary{quota_warnings}++ if ($usage->{state} || '') eq 'warn';
    }
    return \%summary;
}

sub billing_readiness {
    my ($self, $settings, $plans) = @_;
    $settings ||= DesertCMS::Settings::all($self->{config}, $self->{db});
    $plans ||= $self->list;
    my $stripe_ready = ($settings->{stripe_secret_key} || '') && ($settings->{stripe_webhook_secret} || '') ? 1 : 0;
    my ($priced, $priced_with_stripe) = (0, 0);
    for my $plan (@{$plans}) {
        next unless int($plan->{monthly_price_cents} || 0) > 0;
        $priced++;
        $priced_with_stripe++ if length($plan->{stripe_price_id} || '');
    }
    return {
        stripe_ready       => $stripe_ready,
        priced_plans       => $priced,
        priced_with_stripe => $priced_with_stripe,
        ready              => $stripe_ready && (!$priced || $priced == $priced_with_stripe) ? 1 : 0,
    };
}

sub create_subscription_checkout {
    my ($self, %args) = @_;
    my $site_id = _clean_site_id($args{site_id});
    die "site id is required" unless length $site_id;
    my $site = $self->_billable_site($site_id);
    my $plan = $self->get($args{plan_id}) or die "service plan not found";
    die "free plans do not need checkout" unless int($plan->{monthly_price_cents} || 0) > 0;
    die "Stripe Price ID is required for paid plans" unless length($plan->{stripe_price_id} || '');

    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $key = $settings->{stripe_secret_key} || '';
    die "Stripe secret key is not configured" unless length $key;

    my $success_url = _absolute_url($args{success_url});
    my $cancel_url = _absolute_url($args{cancel_url});
    die "success URL is required" unless length $success_url;
    die "cancel URL is required" unless length $cancel_url;

    my %form = (
        mode                         => 'subscription',
        success_url                  => $success_url,
        cancel_url                   => $cancel_url,
        client_reference_id          => $site_id,
        'line_items[0][price]'       => $plan->{stripe_price_id},
        'line_items[0][quantity]'    => 1,
        'metadata[desertcms_billing]' => 'service_plan',
        'metadata[site_id]'          => $site_id,
        'metadata[plan_id]'          => int($plan->{id} || 0),
        'subscription_data[metadata][desertcms_billing]' => 'service_plan',
        'subscription_data[metadata][site_id]'           => $site_id,
        'subscription_data[metadata][plan_id]'           => int($plan->{id} || 0),
    );
    if (length($site->{stripe_customer_id} || '')) {
        $form{customer} = $site->{stripe_customer_id};
    } elsif (_normalize_email($site->{billing_email} || $site->{owner_email})) {
        $form{customer_email} = _normalize_email($site->{billing_email} || $site->{owner_email});
    }

    my $response = $self->{http}->post(
        $settings->{stripe_api_base} || 'https://api.stripe.com/v1/checkout/sessions',
        {
            headers => _stripe_headers($key),
            content => _form_encode(\%form),
        }
    );
    my $body = eval { decode_json($response->{content} || '{}') } || {};
    if (!$response->{success} || !$body->{id} || !$body->{url}) {
        die _stripe_error($body, $response, 'Stripe subscription Checkout session could not be created');
    }
    $self->_record_checkout_session($body, $site, $plan);

    return {
        session_id => $body->{id},
        url        => $body->{url},
        site_id    => $site_id,
        plan_id    => int($plan->{id} || 0),
    };
}

sub create_portal_session {
    my ($self, %args) = @_;
    my $site_id = _clean_site_id($args{site_id});
    die "site id is required" unless length $site_id;
    my $site = $self->_billable_site($site_id);
    die "Stripe customer ID is not available yet" unless length($site->{stripe_customer_id} || '');

    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $key = $settings->{stripe_secret_key} || '';
    die "Stripe secret key is not configured" unless length $key;
    my $return_url = _absolute_url($args{return_url});
    die "return URL is required" unless length $return_url;

    my %form = (
        customer   => $site->{stripe_customer_id},
        return_url => $return_url,
    );
    my $response = $self->{http}->post(
        _stripe_api_url($settings, '/v1/billing_portal/sessions'),
        {
            headers => _stripe_headers($key),
            content => _form_encode(\%form),
        }
    );
    my $body = eval { decode_json($response->{content} || '{}') } || {};
    if (!$response->{success} || !$body->{id} || !$body->{url}) {
        die _stripe_error($body, $response, 'Stripe billing portal session could not be created');
    }

    return {
        session_id => $body->{id},
        url        => $body->{url},
        site_id    => $site_id,
    };
}

sub create_connect_onboarding_link {
    my ($self, %args) = @_;
    die "service plans are read-only in this context" if $self->{read_only};
    my $site_id = _clean_site_id($args{site_id});
    die "site id is required" unless length $site_id;
    my $site = $self->site_with_plan($site_id) or die "contributor site not found";
    die "this service plan does not include contributor Stripe payouts"
        unless _bool($site->{allow_stripe_connect});

    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $key = $settings->{stripe_secret_key} || '';
    die "Stripe secret key is not configured" unless length $key;
    my $return_url = _absolute_url($args{return_url});
    my $refresh_url = _absolute_url($args{refresh_url});
    die "return URL is required" unless length $return_url;
    die "refresh URL is required" unless length $refresh_url;

    my $account_id = _stripe_connect_account_id($site->{stripe_connect_account_id});
    if (!length $account_id) {
        my $site_url = _absolute_url('https://' . ($site->{domain} || ''));
        my %account_form = (
            type => 'express',
            email => _normalize_email($site->{billing_email} || $site->{owner_email}),
            'business_profile[url]' => $site_url,
            'capabilities[card_payments][requested]' => 'true',
            'capabilities[transfers][requested]' => 'true',
            'metadata[desertcms_site_id]' => $site_id,
        );
        delete $account_form{email} unless length($account_form{email} || '');
        delete $account_form{'business_profile[url]'} unless length($account_form{'business_profile[url]'} || '');
        my $account_response = $self->{http}->post(
            _stripe_api_url($settings, '/v1/accounts'),
            {
                headers => _stripe_headers($key),
                content => _form_encode(\%account_form),
            }
        );
        my $account_body = eval { decode_json($account_response->{content} || '{}') } || {};
        if (!$account_response->{success} || !$account_body->{id}) {
            die _stripe_error($account_body, $account_response, 'Stripe connected account could not be created');
        }
        $account_id = _stripe_connect_account_id($account_body->{id});
        $self->_update_connect_account(
            site_id => $site_id,
            account_id => $account_id,
            onboarding_status => 'account_created',
            charges_enabled => $account_body->{charges_enabled} ? 1 : 0,
            payouts_enabled => $account_body->{payouts_enabled} ? 1 : 0,
        );
    }

    my %link_form = (
        account => $account_id,
        refresh_url => $refresh_url,
        return_url => $return_url,
        type => 'account_onboarding',
        'collection_options[fields]' => 'eventually_due',
    );
    my $link_response = $self->{http}->post(
        _stripe_api_url($settings, '/v1/account_links'),
        {
            headers => _stripe_headers($key),
            content => _form_encode(\%link_form),
        }
    );
    my $link_body = eval { decode_json($link_response->{content} || '{}') } || {};
    if (!$link_response->{success} || !$link_body->{url}) {
        die _stripe_error($link_body, $link_response, 'Stripe onboarding link could not be created');
    }
    $self->_update_connect_account(
        site_id => $site_id,
        account_id => $account_id,
        onboarding_status => 'onboarding_started',
    );
    my $updated = $self->site_with_plan($site_id);
    my $plan = $updated->{service_plan_id} ? $self->get($updated->{service_plan_id}) : undef;
    $self->_sync_site_settings($updated, $plan) if $plan;

    return {
        account_id => $account_id,
        url        => $link_body->{url},
        site_id    => $site_id,
    };
}

sub refresh_connect_account_status {
    my ($self, %args) = @_;
    die "service plans are read-only in this context" if $self->{read_only};
    my $site_id = _clean_site_id($args{site_id});
    die "site id is required" unless length $site_id;
    my $site = $self->site_with_plan($site_id) or die "contributor site not found";
    die "this service plan does not include contributor Stripe payouts"
        unless _bool($site->{allow_stripe_connect});
    my $account_id = _stripe_connect_account_id($site->{stripe_connect_account_id});
    die "Stripe connected account is not available yet" unless length $account_id;

    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $key = $settings->{stripe_secret_key} || '';
    die "Stripe secret key is not configured" unless length $key;
    my $response = $self->{http}->get(
        _stripe_api_url($settings, '/v1/accounts/' . $account_id),
        { headers => _stripe_headers($key) }
    );
    my $body = eval { decode_json($response->{content} || '{}') } || {};
    if (!$response->{success} || !$body->{id}) {
        die _stripe_error($body, $response, 'Stripe connected account status could not be refreshed');
    }
    my $status = _connect_status_from_account($body);
    $self->_update_connect_account(
        site_id => $site_id,
        account_id => $account_id,
        onboarding_status => $status,
        charges_enabled => $body->{charges_enabled} ? 1 : 0,
        payouts_enabled => $body->{payouts_enabled} ? 1 : 0,
    );
    my $updated = $self->site_with_plan($site_id);
    my $plan = $updated->{service_plan_id} ? $self->get($updated->{service_plan_id}) : undef;
    $self->_sync_site_settings($updated, $plan) if $plan;
    return {
        site_id => $site_id,
        account_id => $account_id,
        onboarding_status => $status,
        charges_enabled => $body->{charges_enabled} ? 1 : 0,
        payouts_enabled => $body->{payouts_enabled} ? 1 : 0,
    };
}

sub handle_subscription_webhook {
    my ($self, %args) = @_;
    die "service plans are read-only in this context" if $self->{read_only};
    my $payload = defined $args{payload} ? $args{payload} : '';
    my $signature = $args{signature} || '';
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $secret = $settings->{stripe_webhook_secret} || '';
    die "Stripe webhook secret is not configured" unless length $secret;
    _verify_signature(
        payload   => $payload,
        header    => $signature,
        secret    => $secret,
        tolerance => int($settings->{stripe_webhook_tolerance_seconds} || 300),
    );

    my $event = eval { decode_json($payload) };
    die "invalid Stripe webhook JSON" if $@ || ref $event ne 'HASH';
    my $event_id = $event->{id} || '';
    my $event_type = $event->{type} || '';
    die "Stripe event is missing an id" unless length $event_id;

    my $event_key = 'service_plan:' . $event_id;
    my ($seen) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM shop_stripe_events WHERE stripe_event_id = ?',
        undef,
        $event_key
    );
    return { ok => 1, duplicate => 1 } if $seen;

    my $object = $event->{data} && $event->{data}{object} && ref $event->{data}{object} eq 'HASH'
        ? $event->{data}{object}
        : {};
    my $handled = 0;
    if ($event_type eq 'checkout.session.completed') {
        $handled = $self->_handle_checkout_session_completed($object);
    } elsif ($event_type eq 'customer.subscription.updated') {
        $handled = $self->_handle_subscription_updated($object);
    } elsif ($event_type eq 'customer.subscription.deleted') {
        $handled = $self->_handle_subscription_deleted($object);
    } elsif ($event_type eq 'invoice.payment_failed') {
        $handled = $self->_handle_invoice_payment_failed($object);
    }

    return { ok => 1, duplicate => 1 } unless $self->_record_billing_stripe_event($event_key, $event_type);
    return { ok => 1, duplicate => 0, type => $event_type, handled => $handled ? 1 : 0 };
}

sub site_usage {
    my ($self, $site) = @_;
    return _usage_unavailable('site is missing') unless $site;
    my $config_path = $site->{config_path} || '';
    return _usage_unavailable('config path is not set') unless length $config_path && -f $config_path;

    my $site_config = eval { DesertCMS::Config->load($config_path) };
    return _usage_unavailable('config cannot be loaded') unless $site_config;
    my $site_db = eval { DesertCMS::DB->new(config => $site_config) };
    return _usage_unavailable('database cannot be opened') unless $site_db;

    my ($media_bytes, $media_count, $post_count, $page_count);
    my ($image_count, $image_bytes, $document_count, $document_bytes, $resource_count, $resource_bytes, $private_count, $private_bytes);
    my $ok = eval {
        ($media_bytes, $media_count) = $site_db->dbh->selectrow_array(
            q{
                SELECT COALESCE(SUM(bytes), 0), COUNT(*)
                FROM media_assets
                WHERE deleted_at IS NULL
            }
        );
        ($image_count, $image_bytes) = $site_db->dbh->selectrow_array(
            q{
                SELECT COUNT(*), COALESCE(SUM(bytes), 0)
                FROM media_assets
                WHERE deleted_at IS NULL
                  AND mime_type LIKE 'image/%'
            }
        );
        ($document_count, $document_bytes) = $site_db->dbh->selectrow_array(
            q{
                SELECT COUNT(*), COALESCE(SUM(bytes), 0)
                FROM media_assets
                WHERE deleted_at IS NULL
                  AND mime_type NOT LIKE 'image/%'
            }
        );
        ($resource_count, $resource_bytes) = $site_db->dbh->selectrow_array(
            q{
                SELECT COUNT(*), COALESCE(SUM(bytes), 0)
                FROM media_assets
                WHERE deleted_at IS NULL
                  AND public_path LIKE '/assets/resources/%'
            }
        );
        ($private_count, $private_bytes) = $site_db->dbh->selectrow_array(
            q{
                SELECT COUNT(*), COALESCE(SUM(bytes), 0)
                FROM media_assets
                WHERE deleted_at IS NULL
                  AND COALESCE(public_path, '') = ''
            }
        );
        ($post_count) = $site_db->dbh->selectrow_array(
            q{
                SELECT COUNT(*)
                FROM content_items
                WHERE type = 'post'
                  AND deleted_at IS NULL
            }
        );
        ($page_count) = $site_db->dbh->selectrow_array(
            q{
                SELECT COUNT(*)
                FROM content_items
                WHERE type = 'page'
                  AND deleted_at IS NULL
            }
        );
        1;
    };
    return _usage_unavailable('usage query failed') unless $ok;

    my $media_quota_mb = int($site->{media_quota_mb} || 0);
    my $media_upload_limit_mb = int($site->{media_upload_limit_mb} || 0);
    my $post_quota = int($site->{post_quota} || 0);
    my $page_quota = int($site->{page_quota} || 0);
    my $features = DesertCMS::Modules::feature_map_for_plan({ features_json => $site->{service_plan_features_json} || '' });
    my $media_quota_bytes = $media_quota_mb > 0 ? $media_quota_mb * 1024 * 1024 : 0;
    my $media_upload_limit_bytes = $media_upload_limit_mb > 0 ? $media_upload_limit_mb * 1024 * 1024 : 0;
    my $media_pct = _percent($media_bytes, $media_quota_bytes);
    my $post_pct = _percent($post_count, $post_quota);
    my $page_pct = _percent($page_count, $page_quota);
    my $state = ($media_pct >= 90 || $post_pct >= 90 || $page_pct >= 90) ? 'warn' : 'ok';

    return {
        available         => 1,
        state             => $state,
        media_bytes       => int($media_bytes || 0),
        media_count       => int($media_count || 0),
        media_quota_mb    => $media_quota_mb,
        media_quota_bytes => $media_quota_bytes,
        media_upload_limit_mb => $media_upload_limit_mb,
        media_upload_limit_bytes => $media_upload_limit_bytes,
        resource_publishing_included => $features->{resource_publishing} ? 1 : 0,
        media_remaining_bytes => $media_quota_bytes > 0 ? _max(0, $media_quota_bytes - int($media_bytes || 0)) : 0,
        media_percent     => $media_pct,
        media_image_count => int($image_count || 0),
        media_image_bytes => int($image_bytes || 0),
        media_document_count => int($document_count || 0),
        media_document_bytes => int($document_bytes || 0),
        media_resource_count => int($resource_count || 0),
        media_resource_bytes => int($resource_bytes || 0),
        media_private_count => int($private_count || 0),
        media_private_bytes => int($private_bytes || 0),
        post_count        => int($post_count || 0),
        post_quota        => $post_quota,
        post_percent      => $post_pct,
        page_count        => int($page_count || 0),
        page_quota        => $page_quota,
        page_percent      => $page_pct,
    };
}

sub _billable_site {
    my ($self, $site_id) = @_;
    my $site = $self->site_with_plan($site_id) or die "contributor site not found";
    my $root = _domain_root($self);
    die "site domain is not under the contributor root"
        if length $root && !_domain_is_subdomain($site->{domain}, $root);
    die "contributor site is destroyed" if ($site->{status} || '') eq 'destroyed';
    return $site;
}

sub _handle_checkout_session_completed {
    my ($self, $object) = @_;
    return 0 unless ref $object eq 'HASH';
    my $session_id = _object_id($object->{id});
    return 0 unless length $session_id;
    my $binding = $self->_checkout_session_binding($session_id) or return 0;
    return 0 unless ($binding->{status} || '') eq 'pending';

    my $metadata = _metadata($object);
    return 0 unless ($metadata->{desertcms_billing} || '') eq 'service_plan';
    return 0 unless ($object->{mode} || '') eq 'subscription';
    my $site_id = _clean_site_id($metadata->{site_id} || $object->{client_reference_id});
    my $plan_id = int($metadata->{plan_id} || 0);
    return 0 unless length $site_id && $plan_id > 0;
    return 0 unless $site_id eq ($binding->{site_id} || '');
    return 0 unless $plan_id == int($binding->{plan_id} || 0);
    my $site = $self->site_with_plan($site_id) or return 0;
    my $plan = $self->get($plan_id) or return 0;
    return 0 unless ($plan->{stripe_price_id} || '') eq ($binding->{stripe_price_id} || '');
    return 0 if defined $object->{amount_total}
        && $object->{amount_total} =~ /\A[0-9]+\z/
        && int($object->{amount_total}) != int($binding->{amount_cents} || 0);
    return 0 if length($object->{currency} || '')
        && _currency($object->{currency}) ne ($binding->{currency} || 'usd');
    my $email = _normalize_email(
        ($object->{customer_details} && ref $object->{customer_details} eq 'HASH'
            ? $object->{customer_details}{email}
            : '')
        || $object->{customer_email}
        || $site->{billing_email}
        || $site->{owner_email}
    );
    my $customer = _object_id($object->{customer}) || $site->{stripe_customer_id} || '';
    my $subscription = _object_id($object->{subscription}) || $site->{stripe_subscription_id} || '';
    return 0 if length($binding->{stripe_customer_id} || '')
        && length($customer)
        && $customer ne $binding->{stripe_customer_id};
    return 0 unless length $subscription;
    $self->assign_site(
        site_id                => $site_id,
        plan_id                => $plan_id,
        billing_status         => 'active',
        billing_email          => $email,
        stripe_customer_id     => $customer,
        stripe_subscription_id => $subscription,
    );
    $self->_complete_checkout_session($session_id);
    return 1;
}

sub _handle_subscription_updated {
    my ($self, $object) = @_;
    return 0 unless ref $object eq 'HASH';
    my $subscription = _object_id($object->{id});
    my $customer = _object_id($object->{customer});
    my $metadata = _metadata($object);
    my $site_id = _clean_site_id($self->_site_id_for_subscription($subscription) || $self->_site_id_for_customer($customer));
    return 0 unless length $site_id;
    my $metadata_site_id = _clean_site_id($metadata->{site_id} || '');
    return 0 if length $metadata_site_id && $metadata_site_id ne $site_id;
    my $site = $self->site_with_plan($site_id) or return 0;
    my $plan_id = int($site->{service_plan_id} || 0);
    return 0 unless $plan_id > 0;
    $self->assign_site(
        site_id                => $site_id,
        plan_id                => $plan_id,
        billing_status         => _subscription_billing_status($object->{status}),
        billing_email          => $site->{billing_email} || $site->{owner_email},
        stripe_customer_id     => $customer || $site->{stripe_customer_id} || '',
        stripe_subscription_id => $subscription || $site->{stripe_subscription_id} || '',
        billing_current_period_end => _optional_epoch($object->{current_period_end}),
    );
    return 1;
}

sub _handle_subscription_deleted {
    my ($self, $object) = @_;
    return 0 unless ref $object eq 'HASH';
    my $subscription = _object_id($object->{id});
    my $customer = _object_id($object->{customer});
    my $metadata = _metadata($object);
    my $site_id = _clean_site_id($self->_site_id_for_subscription($subscription) || $self->_site_id_for_customer($customer));
    return 0 unless length $site_id;
    my $metadata_site_id = _clean_site_id($metadata->{site_id} || '');
    return 0 if length $metadata_site_id && $metadata_site_id ne $site_id;
    my $site = $self->site_with_plan($site_id) or return 0;
    my $default = $self->default_plan or return 0;
    $self->assign_site(
        site_id                => $site_id,
        plan_id                => $default->{id},
        billing_status         => 'comped',
        billing_email          => $site->{billing_email} || $site->{owner_email},
        stripe_customer_id     => $customer || $site->{stripe_customer_id} || '',
        stripe_subscription_id => '',
        billing_current_period_end => undef,
    );
    return 1;
}

sub _handle_invoice_payment_failed {
    my ($self, $object) = @_;
    return 0 unless ref $object eq 'HASH';
    my $subscription = _object_id($object->{subscription});
    my $customer = _object_id($object->{customer});
    my $site_id = _clean_site_id($self->_site_id_for_subscription($subscription) || $self->_site_id_for_customer($customer));
    return 0 unless length $site_id;
    my $site = $self->site_with_plan($site_id) or return 0;
    my $plan_id = int($site->{service_plan_id} || 0);
    return 0 unless $plan_id > 0;
    $self->assign_site(
        site_id                => $site_id,
        plan_id                => $plan_id,
        billing_status         => 'past_due',
        billing_email          => $site->{billing_email} || $site->{owner_email},
        stripe_customer_id     => $customer || $site->{stripe_customer_id} || '',
        stripe_subscription_id => $subscription || $site->{stripe_subscription_id} || '',
        billing_current_period_end => $site->{billing_current_period_end},
    );
    return 1;
}

sub _site_id_for_subscription {
    my ($self, $subscription_id) = @_;
    $subscription_id = _clean_token($subscription_id, 120);
    return '' unless length $subscription_id;
    my ($site_id) = $self->{db}->dbh->selectrow_array(
        'SELECT site_id FROM contributor_sites WHERE stripe_subscription_id = ? ORDER BY id DESC LIMIT 1',
        undef,
        $subscription_id
    );
    return $site_id || '';
}

sub _site_id_for_customer {
    my ($self, $customer_id) = @_;
    $customer_id = _clean_token($customer_id, 120);
    return '' unless length $customer_id;
    my ($site_id) = $self->{db}->dbh->selectrow_array(
        'SELECT site_id FROM contributor_sites WHERE stripe_customer_id = ? ORDER BY id DESC LIMIT 1',
        undef,
        $customer_id
    );
    return $site_id || '';
}

sub _record_checkout_session {
    my ($self, $session, $site, $plan) = @_;
    my $session_id = _object_id($session->{id});
    die "Stripe Checkout Session is missing an id" unless length $session_id;
    my $customer = _object_id($session->{customer}) || _stripe_customer_id($site->{stripe_customer_id} || '');
    my $amount = defined $session->{amount_total} && $session->{amount_total} =~ /\A[0-9]+\z/
        ? int($session->{amount_total})
        : int($plan->{monthly_price_cents} || 0);
    my $currency = _currency($session->{currency} || $plan->{currency});
    $self->{db}->dbh->do(
        q{
            INSERT OR REPLACE INTO service_plan_checkout_sessions
                (stripe_checkout_session_id, site_id, plan_id, stripe_price_id, stripe_customer_id,
                 amount_cents, currency, status, created_at, completed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, NULL)
        },
        undef,
        $session_id,
        $site->{site_id} || '',
        int($plan->{id} || 0),
        $plan->{stripe_price_id} || '',
        $customer,
        $amount,
        $currency,
        now()
    );
}

sub _checkout_session_binding {
    my ($self, $session_id) = @_;
    $session_id = _clean_token($session_id, 160);
    return undef unless length $session_id;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM service_plan_checkout_sessions
            WHERE stripe_checkout_session_id = ?
            LIMIT 1
        },
        undef,
        $session_id
    );
}

sub _complete_checkout_session {
    my ($self, $session_id) = @_;
    $session_id = _clean_token($session_id, 160);
    return unless length $session_id;
    $self->{db}->dbh->do(
        q{
            UPDATE service_plan_checkout_sessions
            SET status = 'completed',
                completed_at = ?
            WHERE stripe_checkout_session_id = ?
        },
        undef,
        now(),
        $session_id
    );
}

sub _record_billing_stripe_event {
    my ($self, $event_key, $event_type) = @_;
    my $ok = eval {
        $self->{db}->dbh->do(
            q{
                INSERT OR IGNORE INTO shop_stripe_events (stripe_event_id, event_type, received_at)
                VALUES (?, ?, ?)
            },
            undef,
            $event_key,
            $event_type || '',
            now()
        );
        1;
    };
    return $ok ? 1 : 0;
}

sub _metadata {
    my ($object) = @_;
    return {} unless $object && ref $object eq 'HASH';
    return $object->{metadata} && ref $object->{metadata} eq 'HASH' ? $object->{metadata} : {};
}

sub _object_id {
    my ($value) = @_;
    return '' unless defined $value;
    if (ref $value eq 'HASH') {
        return _clean_token($value->{id}, 120);
    }
    return _clean_token($value, 120);
}

sub _subscription_billing_status {
    my ($value) = @_;
    $value = lc($value || '');
    return 'trialing' if $value eq 'trialing';
    return 'active' if $value eq 'active';
    return 'canceled' if $value eq 'canceled' || $value eq 'incomplete_expired';
    return 'past_due' if $value eq 'past_due' || $value eq 'unpaid' || $value eq 'incomplete' || $value eq 'paused';
    return 'comped' unless length $value;
    return 'past_due';
}

sub _stripe_headers {
    my ($key) = @_;
    return {
        Authorization  => 'Basic ' . encode_base64($key . ':', ''),
        'Content-Type' => 'application/x-www-form-urlencoded',
    };
}

sub _stripe_api_url {
    my ($settings, $path) = @_;
    my $base = $settings->{stripe_api_base} || 'https://api.stripe.com/v1/checkout/sessions';
    $base =~ s{/v1/checkout/sessions\z}{};
    $base =~ s{/+\z}{};
    return $base . $path;
}

sub _stripe_error {
    my ($body, $response, $fallback) = @_;
    return $body->{error}{message}
        if $body && ref $body eq 'HASH' && $body->{error} && ref $body->{error} eq 'HASH' && $body->{error}{message};
    return $response->{reason} if $response && $response->{reason};
    return $fallback;
}

sub _verify_signature {
    my (%args) = @_;
    my $payload = defined $args{payload} ? $args{payload} : '';
    my $header = $args{header} || '';
    my $secret = $args{secret} || '';
    my $tolerance = int($args{tolerance} || 300);
    die "Stripe webhook signature is missing" unless length $header;

    my %parts;
    for my $piece (split /,/, $header) {
        my ($key, $value) = split /=/, $piece, 2;
        next unless defined $key && defined $value;
        push @{ $parts{$key} }, $value;
    }
    my $timestamp = $parts{t} && $parts{t}[0] ? $parts{t}[0] : '';
    die "Stripe webhook timestamp is missing" unless $timestamp =~ /\A[0-9]+\z/;
    die "Stripe webhook timestamp is outside tolerance"
        if $tolerance > 0 && abs(now() - int($timestamp)) > $tolerance;

    my $signed_payload = $timestamp . '.' . $payload;
    my $expected = hmac_sha256_hex($signed_payload, $secret);
    for my $candidate (@{ $parts{v1} || [] }) {
        return 1 if constant_time_eq(lc($candidate || ''), $expected);
    }
    die "Stripe webhook signature verification failed";
}

sub _form_encode {
    my ($values) = @_;
    return join '&', map {
        _url_encode($_) . '=' . _url_encode(defined $values->{$_} ? $values->{$_} : '')
    } sort keys %{$values || {}};
}

sub _url_encode {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/eg;
    return $value;
}

sub _absolute_url {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return $value if $value =~ m{\Ahttps?://[^\s]+\z}i;
    return '';
}

sub _set_default_locked {
    my ($self, $id) = @_;
    my $ts = now();
    $self->{db}->dbh->do('UPDATE service_plans SET is_default = 0 WHERE is_default <> 0');
    $self->{db}->dbh->do(
        'UPDATE service_plans SET is_default = 1, updated_at = ? WHERE id = ?',
        undef,
        $ts,
        $id
    );
}

sub _usage_unavailable {
    my ($reason) = @_;
    return {
        available => 0,
        state     => 'neutral',
        reason    => $reason || 'usage unavailable',
    };
}

sub _sync_site_settings {
    my ($self, $site, $plan) = @_;
    return { synced => 0, reason => 'site is missing' } unless $site;
    my $config_path = $site->{config_path} || '';
    return { synced => 0, reason => 'config path is not set' } unless length $config_path;
    return { synced => 0, reason => 'config path is missing' } unless -f $config_path;

    my $site_config = eval { DesertCMS::Config->load($config_path) };
    return { synced => 0, reason => 'config cannot be loaded' } unless $site_config;
    my $site_db = eval { DesertCMS::DB->new(config => $site_config) };
    return { synced => 0, reason => 'database cannot be opened' } unless $site_db;

    my $ok = eval {
        $site_db->migrate;
        my $features = DesertCMS::Modules::feature_map_for_plan($plan);
        my $catalog_available = _bool($features->{shop});
        my $shop_payments_available = $catalog_available
            && _bool($features->{shop_payments})
            && _bool($plan->{allow_stripe_connect})
            ? 1
            : 0;
        my $event_payments_available = _bool($features->{events})
            && _bool($features->{event_payments})
            && _bool($plan->{allow_stripe_connect})
            ? 1
            : 0;
        my $booking_payments_available = _bool($features->{bookings})
            && _bool($features->{booking_payments})
            && _bool($plan->{allow_stripe_connect})
            ? 1
            : 0;
        my $membership_payments_available = _bool($features->{membership})
            && _bool($features->{membership_payments})
            && _bool($plan->{allow_stripe_connect})
            ? 1
            : 0;
        my $donation_payments_available = _bool($features->{donations})
            && _bool($features->{donation_payments})
            && _bool($plan->{allow_stripe_connect})
            ? 1
            : 0;
        my $payments_available = $shop_payments_available || $event_payments_available || $booking_payments_available || $membership_payments_available || $donation_payments_available ? 1 : 0;
        my %settings = (
            contributor_media_quota_mb => int($plan->{media_quota_mb} || 0),
            contributor_media_upload_limit_mb => int($plan->{media_upload_limit_mb} || 0),
            contributor_post_quota     => int($plan->{post_quota} || 0),
            contributor_page_quota     => int($plan->{page_quota} || 0),
            contributor_plan_features_json => DesertCMS::Modules::features_json($features),
            contributor_allow_postmark_sender_override => _bool($plan->{allow_postmark_sender_override}),
            contributor_allow_stripe_connect => $payments_available,
            contributor_allow_indexing_override => _bool($plan->{allow_indexing_override}),
            contributor_platform_fee_bps => int($plan->{stripe_platform_fee_bps} || 0),
            stripe_connect_account_id => _stripe_connect_account_id($site->{stripe_connect_account_id} || ''),
            stripe_connect_onboarding_status => _clean_connect_status($site->{stripe_connect_onboarding_status} || ''),
            stripe_connect_charges_enabled => _bool($site->{stripe_connect_charges_enabled}),
            stripe_connect_payouts_enabled => _bool($site->{stripe_connect_payouts_enabled}),
        );
        $settings{postmark_sender_mode} = 'inherit'
            unless _bool($plan->{allow_postmark_sender_override});
        $settings{commerce_model} = $payments_available
            ? 'platform_marketplace'
            : 'disabled';
        if (!_bool($plan->{allow_indexing_override})) {
            @settings{qw(
                google_oauth_access_token google_oauth_refresh_token google_oauth_expires_at
                google_oauth_connected_at google_oauth_scope google_oauth_last_error
            )} = ('') x 6;
            $settings{indexnow_enabled} = 0;
        }
        for my $key (@{ DesertCMS::Modules::feature_keys() }) {
            next if $features->{$key};
            my $setting_key = DesertCMS::Modules::setting_key($key);
            $settings{$setting_key} = 0 if length $setting_key;
            $settings{shop_enabled} = 0 if $key eq 'shop';
        }
        DesertCMS::Settings::set_many($site_config, $site_db, \%settings);
        1;
    };
    return { synced => 0, reason => 'settings sync failed' } unless $ok;
    return { synced => 1, reason => 'quota and feature settings synced' };
}

sub _update_connect_account {
    my ($self, %args) = @_;
    my $site_id = _clean_site_id($args{site_id});
    die "site id is required" unless length $site_id;
    my $account_id = _stripe_connect_account_id($args{account_id});
    die "Stripe connected account ID is invalid" unless length $account_id;
    my $status = _clean_connect_status($args{onboarding_status});
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            UPDATE contributor_sites
            SET stripe_connect_account_id = ?,
                stripe_connect_onboarding_status = CASE WHEN ? = '' THEN stripe_connect_onboarding_status ELSE ? END,
                stripe_connect_charges_enabled = CASE WHEN ? = '' THEN stripe_connect_charges_enabled ELSE ? END,
                stripe_connect_payouts_enabled = CASE WHEN ? = '' THEN stripe_connect_payouts_enabled ELSE ? END,
                updated_at = ?
            WHERE site_id = ?
        },
        undef,
        $account_id,
        $status,
        $status,
        defined($args{charges_enabled}) ? 1 : '',
        defined($args{charges_enabled}) ? _bool($args{charges_enabled}) : '',
        defined($args{payouts_enabled}) ? 1 : '',
        defined($args{payouts_enabled}) ? _bool($args{payouts_enabled}) : '',
        $ts,
        $site_id
    );
}

sub _percent {
    my ($used, $quota) = @_;
    $used = int($used || 0);
    $quota = int($quota || 0);
    return 0 unless $quota > 0;
    my $pct = int(($used / $quota) * 100 + 0.5);
    return 100 if $pct > 100;
    return $pct;
}

sub _max {
    my ($left, $right) = @_;
    $left = int($left || 0);
    $right = int($right || 0);
    return $left > $right ? $left : $right;
}

sub _price_cents {
    my ($args) = @_;
    if (defined $args->{monthly_price_cents} && $args->{monthly_price_cents} =~ /\A[0-9]+\z/) {
        return int($args->{monthly_price_cents});
    }
    my $dollars = defined $args->{monthly_price_dollars} ? $args->{monthly_price_dollars} : 0;
    $dollars =~ s/[^0-9.]//g;
    return 0 unless length $dollars;
    my ($whole, $cents) = split /\./, $dollars, 2;
    $whole = int($whole || 0);
    $cents = defined $cents ? substr(($cents . '00'), 0, 2) : '00';
    return $whole * 100 + int($cents);
}

sub _basis_points {
    my ($value) = @_;
    $value = 0 unless defined $value && "$value" =~ /\S/;
    die "platform fee percent must be between 0 and 100"
        unless "$value" =~ /\A[0-9]+(?:\.[0-9]{1,2})?\z/;
    my ($whole, $decimal) = split /\./, "$value", 2;
    $decimal = defined $decimal ? substr(($decimal . '00'), 0, 2) : '00';
    my $bps = int($whole || 0) * 100 + int($decimal || 0);
    die "platform fee percent must be between 0 and 100"
        unless $bps >= 0 && $bps <= 10_000;
    return $bps;
}

sub _currency {
    my ($value) = @_;
    $value = lc($value || 'usd');
    $value =~ s/[^a-z]//g;
    $value = substr($value || 'usd', 0, 3);
    return length($value) == 3 ? $value : 'usd';
}

sub _quota {
    my ($value, $default, $min, $max) = @_;
    return $default unless defined $value && "$value" =~ /\A[0-9]+\z/;
    my $int = int($value);
    $int = $min if $int < $min;
    $int = $max if $int > $max;
    return $int;
}

sub _billing_status {
    my ($value) = @_;
    $value = lc($value || 'comped');
    return $value if $value =~ /\A(?:trialing|active|past_due|canceled|comped)\z/;
    return 'comped';
}

sub _stripe_price_id {
    my ($value) = @_;
    $value = _clean_token($value, 120);
    return $value if $value eq '' || $value =~ /\Aprice_[A-Za-z0-9_]+\z/;
    die "Stripe Price ID must start with price_";
}

sub _stripe_customer_id {
    my ($value) = @_;
    $value = _clean_token($value, 120);
    return $value if $value eq '' || $value =~ /\Acus_[A-Za-z0-9_]+\z/;
    die "Stripe Customer ID must start with cus_";
}

sub _stripe_subscription_id {
    my ($value) = @_;
    $value = _clean_token($value, 120);
    return $value if $value eq '' || $value =~ /\Asub_[A-Za-z0-9_]+\z/;
    die "Stripe Subscription ID must start with sub_";
}

sub _stripe_connect_account_id {
    my ($value) = @_;
    $value = _clean_token($value, 120);
    return $value if $value eq '' || $value =~ /\Aacct_[A-Za-z0-9_]+\z/;
    die "Stripe connected account ID must start with acct_";
}

sub _clean_connect_status {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value = lc $value;
    $value =~ s/[^a-z0-9_-]+/_/g;
    $value =~ s/^_+|_+\z//g;
    return substr($value, 0, 64);
}

sub _connect_status_from_account {
    my ($account) = @_;
    $account ||= {};
    return 'ready' if $account->{charges_enabled} && $account->{payouts_enabled};
    my $requirements = $account->{requirements} && ref $account->{requirements} eq 'HASH'
        ? $account->{requirements}
        : {};
    return 'restricted'
        if @{$requirements->{currently_due} || []}
        || @{$requirements->{past_due} || []}
        || length($requirements->{disabled_reason} || '');
    return 'details_submitted' if $account->{details_submitted};
    return 'onboarding_incomplete';
}

sub _clean_token {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    $value =~ s/[^A-Za-z0-9_:-]//g;
    return substr($value, 0, $max || 255);
}

sub _optional_epoch {
    my ($value) = @_;
    return undef unless defined $value && "$value" =~ /\A[0-9]+\z/;
    my $int = int($value);
    return $int > 0 ? $int : undef;
}

sub _normalize_email {
    my ($email) = @_;
    $email = lc($email || '');
    $email =~ s/^\s+|\s+\z//g;
    return '' unless $email =~ /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z/;
    return $email;
}

sub _clean_text {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+\z//g;
    return substr($value, 0, $max || 255);
}

sub _clean_site_id {
    my ($site_id) = @_;
    $site_id = lc($site_id || '');
    $site_id =~ s/[^a-z0-9-]//g;
    $site_id =~ s/^-+|-+\z//g;
    return $site_id;
}

sub _bool {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _domain_root {
    my ($self) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $root = $settings->{contributor_domain_root} || '';
    if (!length $root) {
        $root = $self->{config}->get('site_url') || '';
        $root =~ s{\Ahttps?://}{}i;
        $root =~ s{/.*\z}{};
    }
    $root = lc $root;
    $root =~ s{\Ahttps?://}{}i;
    $root =~ s{/.*\z}{};
    $root =~ s/^\.+|\.+\z//g;
    return $root =~ /\A[a-z0-9.-]+\.[a-z]{2,}\z/ ? $root : '';
}

sub _domain_is_subdomain {
    my ($domain, $root) = @_;
    $domain = lc($domain || '');
    $root = lc($root || '');
    $domain =~ s/^\.+|\.+\z//g;
    $root =~ s/^\.+|\.+\z//g;
    return 0 unless length $domain && length $root;
    return 0 if $domain eq $root;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+\Q$root\E\z/ ? 1 : 0;
}

1;
