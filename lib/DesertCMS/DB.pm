package DesertCMS::DB;

use strict;
use warnings;
use DBI;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    return bless {
        config => $args{config},
        dbh    => undef,
    }, $class;
}

sub dbh {
    my ($self) = @_;
    return $self->{dbh} if $self->{dbh};

    my $db_path = $self->{config}->get('db_path');
    my $db_dir = dirname($db_path);
    make_path($db_dir) unless -d $db_dir;

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$db_path",
        '',
        '',
        {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            sqlite_unicode => 1,
        }
    );

    $dbh->do('PRAGMA foreign_keys = ON');
    $dbh->do('PRAGMA busy_timeout = 5000');

    $self->{dbh} = $dbh;
    return $dbh;
}

sub migrate {
    my ($self) = @_;
    my $schema = _schema_path();
    open my $fh, '<', $schema or die "cannot read schema $schema: $!";
    local $/;
    my $sql = <$fh>;
    close $fh;

    my $dbh = $self->dbh;
    $dbh->begin_work;
    eval {
        for my $statement (split /;\s*(?:\n|$)/, $sql) {
            next unless $statement =~ /\S/;
            $dbh->do($statement);
        }
        $self->_ensure_columns('content_items', {
            parent_id          => "INTEGER",
            meta_title         => "TEXT NOT NULL DEFAULT ''",
            meta_description   => "TEXT NOT NULL DEFAULT ''",
            canonical_url      => "TEXT NOT NULL DEFAULT ''",
            feature_image_path => "TEXT NOT NULL DEFAULT ''",
            location_enabled   => "INTEGER NOT NULL DEFAULT 0",
            location_lat       => "REAL",
            location_lng       => "REAL",
            location_label     => "TEXT NOT NULL DEFAULT ''",
            location_kind      => "TEXT NOT NULL DEFAULT 'other' CHECK (location_kind IN ('store', 'venue', 'project', 'historical_site', 'event_location', 'service_area', 'other'))",
            show_in_nav        => "INTEGER NOT NULL DEFAULT 0",
            nav_label          => "TEXT NOT NULL DEFAULT ''",
            nav_order          => "INTEGER NOT NULL DEFAULT 100",
            access_policy      => "TEXT NOT NULL DEFAULT 'public' CHECK (access_policy IN ('public', 'members', 'group', 'private'))",
            access_group_id    => "INTEGER",
        });
        $self->_ensure_columns('content_revisions', {
            parent_id         => "INTEGER",
            collections_text  => "TEXT NOT NULL DEFAULT ''",
            meta_title         => "TEXT NOT NULL DEFAULT ''",
            meta_description   => "TEXT NOT NULL DEFAULT ''",
            canonical_url      => "TEXT NOT NULL DEFAULT ''",
            feature_image_path => "TEXT NOT NULL DEFAULT ''",
            location_enabled   => "INTEGER NOT NULL DEFAULT 0",
            location_lat       => "REAL",
            location_lng       => "REAL",
            location_label     => "TEXT NOT NULL DEFAULT ''",
            location_kind      => "TEXT NOT NULL DEFAULT 'other' CHECK (location_kind IN ('store', 'venue', 'project', 'historical_site', 'event_location', 'service_area', 'other'))",
            show_in_nav        => "INTEGER NOT NULL DEFAULT 0",
            nav_label          => "TEXT NOT NULL DEFAULT ''",
            nav_order          => "INTEGER NOT NULL DEFAULT 100",
            access_policy      => "TEXT NOT NULL DEFAULT 'public' CHECK (access_policy IN ('public', 'members', 'group', 'private'))",
            access_group_id    => "INTEGER",
            tags_text         => "TEXT NOT NULL DEFAULT ''",
        });
        $self->_ensure_columns('media_assets', {
            alt_text             => "TEXT NOT NULL DEFAULT ''",
            seo_title            => "TEXT NOT NULL DEFAULT ''",
            seo_description      => "TEXT NOT NULL DEFAULT ''",
            category_text        => "TEXT NOT NULL DEFAULT ''",
            tags_text            => "TEXT NOT NULL DEFAULT ''",
            collections_text     => "TEXT NOT NULL DEFAULT ''",
            owner_site_id        => "TEXT NOT NULL DEFAULT ''",
            owner_domain         => "TEXT NOT NULL DEFAULT ''",
            owner_display_name   => "TEXT NOT NULL DEFAULT ''",
            owner_email          => "TEXT NOT NULL DEFAULT ''",
            uploaded_by_user_id  => "INTEGER",
            uploaded_by_username => "TEXT NOT NULL DEFAULT ''",
            uploaded_by_email    => "TEXT NOT NULL DEFAULT ''",
            derivatives_json      => "TEXT NOT NULL DEFAULT '{}'",
            deleted_at           => "INTEGER",
        });
        $self->_ensure_columns('shop_listings', {
            listing_kind => "TEXT NOT NULL DEFAULT 'product' CHECK (listing_kind IN ('product', 'service', 'digital', 'portfolio_item', 'inquiry_only', 'other'))",
            cta_label    => "TEXT NOT NULL DEFAULT 'Request info'",
            cta_url      => "TEXT NOT NULL DEFAULT ''",
        });
        $self->_ensure_columns('analytics_events', {
            ip_address   => "TEXT NOT NULL DEFAULT ''",
            country_code => "TEXT NOT NULL DEFAULT ''",
            country      => "TEXT NOT NULL DEFAULT ''",
            region       => "TEXT NOT NULL DEFAULT ''",
            city         => "TEXT NOT NULL DEFAULT ''",
        });
        $self->_ensure_columns('analytics_geoip_ranges', {
            country_code => "TEXT NOT NULL DEFAULT ''",
        });
        $self->_ensure_columns('admin_users', {
            email => "TEXT NOT NULL DEFAULT ''",
            role  => "TEXT NOT NULL DEFAULT 'owner'",
        });
        $self->_ensure_columns('contributor_sites', {
            blueprint_id            => "INTEGER",
            blueprint_snapshot_json => "TEXT NOT NULL DEFAULT '{}'",
            media_quota_mb          => "INTEGER NOT NULL DEFAULT 0",
            media_upload_limit_mb    => "INTEGER NOT NULL DEFAULT 64",
            post_quota              => "INTEGER NOT NULL DEFAULT 0",
            page_quota              => "INTEGER NOT NULL DEFAULT 0",
            allow_master_gallery    => "INTEGER NOT NULL DEFAULT 1",
            allow_master_posts      => "INTEGER NOT NULL DEFAULT 1",
            service_plan_id         => "INTEGER",
            billing_status          => "TEXT NOT NULL DEFAULT 'comped'",
            billing_email           => "TEXT NOT NULL DEFAULT ''",
            stripe_customer_id      => "TEXT NOT NULL DEFAULT ''",
            stripe_subscription_id  => "TEXT NOT NULL DEFAULT ''",
            billing_started_at      => "INTEGER",
            billing_current_period_end => "INTEGER",
            stripe_connect_account_id => "TEXT NOT NULL DEFAULT ''",
            stripe_connect_onboarding_status => "TEXT NOT NULL DEFAULT ''",
            stripe_connect_charges_enabled => "INTEGER NOT NULL DEFAULT 0",
            stripe_connect_payouts_enabled => "INTEGER NOT NULL DEFAULT 0",
        });
        $self->_ensure_columns('contributor_blueprints', {
            category => "TEXT NOT NULL DEFAULT 'photographer'",
            module_directory_enabled => "INTEGER NOT NULL DEFAULT 0",
            module_bookings_enabled => "INTEGER NOT NULL DEFAULT 0",
            module_membership_enabled => "INTEGER NOT NULL DEFAULT 0",
            module_newsletter_enabled => "INTEGER NOT NULL DEFAULT 0",
            module_donations_enabled => "INTEGER NOT NULL DEFAULT 0",
            module_testimonials_enabled => "INTEGER NOT NULL DEFAULT 0",
        });
        $self->_ensure_columns('service_plans', {
            features_json => "TEXT NOT NULL DEFAULT '{}'",
            media_upload_limit_mb => "INTEGER NOT NULL DEFAULT 64",
            allow_postmark_sender_override => "INTEGER NOT NULL DEFAULT 0",
            allow_stripe_connect => "INTEGER NOT NULL DEFAULT 0",
            allow_indexing_override => "INTEGER NOT NULL DEFAULT 0",
            stripe_platform_fee_bps => "INTEGER NOT NULL DEFAULT 0",
        });
        $self->_ensure_columns('contributor_invites', {
            blueprint_id => "INTEGER",
        });
        $self->_ensure_columns('contributor_requests', {
            first_name                => "TEXT NOT NULL DEFAULT ''",
            last_name                 => "TEXT NOT NULL DEFAULT ''",
            last_initial              => "TEXT NOT NULL DEFAULT ''",
            phone                     => "TEXT NOT NULL DEFAULT ''",
            # Legacy contributor request field retained for existing databases. Current forms do not collect it.
            gender                    => "TEXT NOT NULL DEFAULT ''",
            application_text          => "TEXT NOT NULL DEFAULT ''",
            application_showcase_json => "TEXT NOT NULL DEFAULT '[]'",
            bio                       => "TEXT NOT NULL DEFAULT ''",
            profile_photo_path        => "TEXT NOT NULL DEFAULT ''",
            profile_photo_mime        => "TEXT NOT NULL DEFAULT ''",
            public_profile_image_path => "TEXT NOT NULL DEFAULT ''",
            showcase_json             => "TEXT NOT NULL DEFAULT '[]'",
            site_id                   => "TEXT NOT NULL DEFAULT ''",
            domain                    => "TEXT NOT NULL DEFAULT ''",
            blueprint_id              => "INTEGER",
            review_note               => "TEXT NOT NULL DEFAULT ''",
            profile_token_hash        => "TEXT NOT NULL DEFAULT ''",
            profile_token_expires_at  => "INTEGER",
            profile_completed_at      => "INTEGER",
            ip_hash                   => "TEXT NOT NULL DEFAULT ''",
            user_agent_hash           => "TEXT NOT NULL DEFAULT ''",
            reviewed_at               => "INTEGER",
            approved_at               => "INTEGER",
            denied_at                 => "INTEGER",
        });
        $self->_ensure_columns('form_submissions', {
            phone                  => "TEXT NOT NULL DEFAULT ''",
            organization           => "TEXT NOT NULL DEFAULT ''",
            preferred_date         => "TEXT NOT NULL DEFAULT ''",
            event_date             => "TEXT NOT NULL DEFAULT ''",
            guest_count            => "INTEGER",
            budget                 => "TEXT NOT NULL DEFAULT ''",
            attachment_json        => "TEXT NOT NULL DEFAULT '[]'",
            notification_status    => "TEXT NOT NULL DEFAULT ''",
            notification_error     => "TEXT NOT NULL DEFAULT ''",
            notification_sent_at   => "INTEGER",
        });
        $self->_ensure_columns('federated_content_reviews', {
            source_missing_at => "INTEGER",
        });
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown migration error';
        eval { $dbh->rollback };
        die $err;
    };
}

sub _ensure_columns {
    my ($self, $table, $columns) = @_;
    my $dbh = $self->dbh;
    my $rows = $dbh->selectall_arrayref("PRAGMA table_info($table)", { Slice => {} });
    my %existing = map { $_->{name} => 1 } @{$rows};

    for my $name (sort keys %{$columns}) {
        next if $existing{$name};
        die "unsafe column name: $name" unless $name =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        $dbh->do("ALTER TABLE $table ADD COLUMN $name $columns->{$name}");
    }
}

sub _schema_path {
    my $here = dirname(__FILE__);
    return File::Spec->catfile($here, '..', '..', 'sql', 'schema.sql');
}

1;
