package DesertCMS::Sites;

use strict;
use warnings;
use File::Find qw(find);
use File::Spec;
use JSON::PP qw(encode_json);
use Socket qw(inet_ntoa);
use DesertCMS::Auth;
use DesertCMS::Blueprints;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Email qw(send_postmark);
use DesertCMS::ServicePlans;
use DesertCMS::Settings;
use DesertCMS::Util qw(now random_hex sha256_hexstr slugify);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub list_sites {
    my ($self) = @_;
    my $rows = $self->list_all_sites;
    my $root = _domain_root($self);
    $rows = [
        grep { ($_->{status} || '') ne 'destroyed' && ($_->{status} || '') ne 'destroy_pending' } @{$rows}
    ];
    return $rows unless length $root;
    return [
        grep { _domain_is_subdomain($_->{domain}, $root) } @{$rows}
    ];
}

sub list_all_sites {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        'SELECT * FROM contributor_sites ORDER BY created_at DESC, id DESC',
        { Slice => {} }
    );
}

sub list_archived_sites {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 100);
    $limit = 100 if $limit < 1 || $limit > 500;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT *
            FROM archived_sites
            ORDER BY archived_at DESC, id DESC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub list_invites {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT i.*, b.name AS blueprint_name
            FROM contributor_invites i
            LEFT JOIN contributor_blueprints b ON b.id = i.blueprint_id
            ORDER BY i.created_at DESC, i.id DESC
            LIMIT 25
        },
        { Slice => {} }
    );
}

sub queue_rows {
    my ($self) = @_;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT q.*,
                   (
                       SELECT e.step_label
                       FROM site_provisioning_events e
                       WHERE e.queue_id = q.id
                       ORDER BY e.id DESC
                       LIMIT 1
                   ) AS last_step_label,
                   (
                       SELECT e.status
                       FROM site_provisioning_events e
                       WHERE e.queue_id = q.id
                       ORDER BY e.id DESC
                       LIMIT 1
                   ) AS last_step_status
            FROM site_provisioning_queue q
            ORDER BY q.created_at DESC, q.id DESC
            LIMIT 25
        },
        { Slice => {} }
    );
    my $root = _domain_root($self);
    return $rows unless length $root;
    my %visible_site = map { ($_->{site_id} || '') => 1 } @{$self->list_sites};
    return [
        grep { $visible_site{$_->{site_id} || ''} } @{$rows}
    ];
}

sub queue_job {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    my $job = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM site_provisioning_queue WHERE id = ?',
        undef,
        $id
    );
    return undef unless $job;
    return undef unless $self->_queue_job_is_visible($job);
    return $job;
}

sub queue_events {
    my ($self, $queue_id) = @_;
    my $job = $self->queue_job($queue_id) or return [];
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM site_provisioning_events
            WHERE queue_id = ?
            ORDER BY id ASC
        },
        { Slice => {} },
        $job->{id}
    );
}

sub retry_failed_queue_job {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "provisioning job id is required" unless $id > 0;
    my $job = $self->queue_job($id) or die "provisioning job not found";
    die "only failed provisioning jobs can be retried" unless ($job->{status} || '') eq 'failed';

    my $dbh = $self->{db}->dbh;
    my $ts = now();
    my $new_id;
    $dbh->begin_work;
    eval {
        $dbh->do(
            q{
                INSERT INTO site_provisioning_queue
                    (site_id, action, status, details_json, created_by_user_id, created_at, updated_at)
                VALUES
                    (?, ?, 'queued', ?, ?, ?, ?)
            },
            undef,
            $job->{site_id},
            $job->{action},
            $job->{details_json} || '{}',
            defined $args{created_by_user_id} ? $args{created_by_user_id} : $job->{created_by_user_id},
            $ts,
            $ts
        );
        $new_id = $dbh->sqlite_last_insert_rowid;
        $self->record_queue_event(
            queue_id   => $new_id,
            site_id    => $job->{site_id},
            action     => $job->{action},
            step_key   => 'retry_queued',
            step_label => 'Retry queued',
            status     => 'info',
            message    => "Queued as retry of failed job #$id.",
            ts         => $ts,
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown retry failure';
        eval { $dbh->rollback };
        die $err;
    };

    return $self->queue_job($new_id);
}

sub record_queue_event {
    my ($self, %args) = @_;
    my $queue_id = int($args{queue_id} || 0);
    die "queue id is required" unless $queue_id > 0;
    my $site_id = _clean_site_id($args{site_id});
    die "site id is required" unless length $site_id;
    my $action = $args{action} || '';
    die "unsupported site action" unless $action =~ /\A(?:create|enable|disable|destroy)\z/;
    my $status = $args{status} || 'info';
    die "unsupported event status" unless $status =~ /\A(?:running|done|failed|info)\z/;
    my $step_key = lc($args{step_key} || 'event');
    $step_key =~ s/[^a-z0-9_:-]+/_/g;
    $step_key = substr($step_key || 'event', 0, 80);
    my $step_label = $args{step_label} || $step_key;
    my $message = $args{message} || '';
    $self->{db}->dbh->do(
        q{
            INSERT INTO site_provisioning_events
                (queue_id, site_id, action, step_key, step_label, status, message, created_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $queue_id,
        $site_id,
        $action,
        $step_key,
        substr($step_label, 0, 160),
        $status,
        substr($message, 0, 2000),
        $args{ts} || now()
    );
}

sub repair_openbsd_paths {
    my ($self, %args) = @_;
    my $config_base = $args{config_base} || '/etc';
    my $data_base = $args{data_base} || '/var/desertcms-sites';
    my $public_base = $args{public_base} || '/var/www/htdocs';
    my $ts = now();
    my @updated;

    for my $site (@{$self->list_sites}) {
        my $site_id = _clean_site_id($site->{site_id});
        next unless length $site_id && $site_id eq ($site->{site_id} || '');
        next if ($site->{status} || '') eq 'destroyed' || ($site->{status} || '') eq 'destroy_pending';

        my %repair;
        $repair{config_path} = _slash_path(File::Spec->catfile($config_base, "desertcms-$site_id.conf"))
            unless length($site->{config_path} || '');
        $repair{data_dir} = _slash_path(File::Spec->catdir($data_base, $site_id))
            unless length($site->{data_dir} || '');
        $repair{public_root} = _slash_path(File::Spec->catdir($public_base, "desertcms-$site_id"))
            unless length($site->{public_root} || '');
        next unless %repair;

        my @sets = map { "$_ = ?" } sort keys %repair;
        push @sets, 'updated_at = ?';
        my @values = map { $repair{$_} } sort keys %repair;
        push @values, $ts, $site_id;
        $self->{db}->dbh->do(
            'UPDATE contributor_sites SET ' . join(', ', @sets) . ' WHERE site_id = ?',
            undef,
            @values
        );
        push @updated, $site_id;
    }

    return {
        updated => scalar @updated,
        sites   => \@updated,
    };
}

sub fleet_status {
    my ($self, %args) = @_;
    my $sites = $self->list_sites;
    my $dbh = $self->{db}->dbh;
    my %visible_site = map { ($_->{site_id} || '') => 1 } @{$sites};
    my ($queue_open, $queue_failed) = (0, 0);
    my $queue_states = $dbh->selectall_arrayref(
        q{SELECT site_id, status FROM site_provisioning_queue WHERE status IN ('queued', 'running', 'failed')},
        { Slice => {} }
    );
    for my $queue (@{$queue_states}) {
        next unless $visible_site{$queue->{site_id} || ''};
        $queue_open++ if ($queue->{status} || '') eq 'queued' || ($queue->{status} || '') eq 'running';
        $queue_failed++ if ($queue->{status} || '') eq 'failed';
    }

    my %summary = (
        total        => scalar @{$sites},
        active       => 0,
        pending      => 0,
        disabled     => 0,
        destroyed    => 0,
        queue_open   => int($queue_open || 0),
        queue_failed => int($queue_failed || 0),
        alerts       => 0,
    );

    my @rows;
    for my $site (@{$sites}) {
        my $row = $self->_fleet_site_status($site, %args);
        push @rows, $row;

        my $status = $site->{status} || '';
        if ($status eq 'active') {
            $summary{active}++;
        } elsif ($status eq 'pending_provision') {
            $summary{pending}++;
        } elsif ($status eq 'disabled') {
            $summary{disabled}++;
        } elsif ($status eq 'destroyed' || $status eq 'destroy_pending') {
            $summary{destroyed}++;
        }
        $summary{alerts} += scalar @{$row->{alerts} || []};
    }

    return {
        %summary,
        sites => \@rows,
    };
}

sub create_invite {
    my ($self, %args) = @_;
    my $email = _normalize_email($args{email});
    die "valid email is required" unless _valid_email($email);

    my $token = random_hex(32);
    my $ts = now();
    my $expires = $ts + int($args{ttl_seconds} || 14 * 24 * 60 * 60);
    my $message = _clean_message($args{message});
    my $blueprints = DesertCMS::Blueprints->new(config => $self->{config}, db => $self->{db});
    my $blueprint = $blueprints->select_blueprint($args{blueprint_id});

    my $dbh = $self->{db}->dbh;
    $dbh->do(
        q{
            INSERT INTO contributor_invites
                (email, token_hash, status, message, blueprint_id, created_by_user_id, created_at, expires_at)
            VALUES
                (?, ?, 'pending', ?, ?, ?, ?, ?)
        },
        undef,
        $email,
        sha256_hexstr($token),
        $message,
        $blueprint->{id},
        $args{created_by_user_id},
        $ts,
        $expires
    );

    my $invite = $dbh->selectrow_hashref(
        'SELECT * FROM contributor_invites WHERE id = ?',
        undef,
        $dbh->sqlite_last_insert_rowid
    );
    $invite->{token} = $token;
    $invite->{invite_url} = $self->invite_url($token);
    return $invite;
}

sub send_invite_email {
    my ($self, $invite) = @_;
    die "invite is required" unless $invite && $invite->{email};

    my $url = $invite->{invite_url} || $self->invite_url($invite->{token});
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $site_name = $settings->{site_name} || $self->{config}->get('site_name') || 'DesertCMS';
    my $subject = "Invitation to create your $site_name site";
    my $text = join "\n\n",
        "You have been invited to create a contributor site on $site_name.",
        "Accept the invite here:",
        $url;

    return send_postmark(
        $self->{config},
        $self->{db},
        to         => $invite->{email},
        email_type => 'contributor_invite',
        subject    => $subject,
        text_body  => $text,
        html_body  => '<p>You have been invited to create a contributor site on '
            . _html($site_name)
            . '.</p><p><a href="'
            . _html($url)
            . '">Accept the invite</a></p>',
    );
}

sub invite_url {
    my ($self, $token) = @_;
    my $base = $self->{config}->get('site_url') || 'http://localhost';
    $base =~ s{/+\z}{};
    return "$base/admin/invite/$token";
}

sub invite_by_token {
    my ($self, $token) = @_;
    return undef unless defined $token && $token =~ /\A[0-9a-f]{64}\z/i;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM contributor_invites WHERE token_hash = ?',
        undef,
        sha256_hexstr(lc $token)
    );
}

sub accept_invite {
    my ($self, %args) = @_;
    my $token = lc($args{token} || '');
    my $invite = $self->invite_by_token($token) or die "invite not found";
    die "invite is no longer available" unless $invite->{status} eq 'pending';

    my $ts = now();
    if ($invite->{expires_at} <= $ts) {
        $self->{db}->dbh->do(
            "UPDATE contributor_invites SET status = 'expired' WHERE id = ?",
            undef,
            $invite->{id}
        );
        die "invite has expired";
    }

    my $first = _clean_name($args{first_name});
    my $last_initial = uc substr(_clean_name($args{last_initial}), 0, 1);
    die "first name is required" unless length $first;
    die "last initial is required" unless $last_initial =~ /\A[A-Z]\z/;

    my $root = _domain_root($self);
    die "contributor domain root is not configured" unless length $root;

    my $site_id = $self->_available_site_id($first, $last_initial);
    my $domain = "$site_id.$root";
    my $display_name = "$first $last_initial.";
    my $blueprints = DesertCMS::Blueprints->new(config => $self->{config}, db => $self->{db});
    my $blueprint = $blueprints->select_blueprint($invite->{blueprint_id});
    my $snapshot = $blueprints->snapshot($blueprint);
    my ($service_plan, $service_snapshot) = $self->_default_service_plan_snapshot;
    my $details = {
        domain           => $domain,
        display_name     => $display_name,
        owner_email      => $invite->{email},
        owner_first_name => $first,
        owner_last_initial => $last_initial,
        blueprint        => $snapshot,
        service_plan     => $service_snapshot,
    };

    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        $dbh->do(
            q{
                INSERT INTO contributor_sites
                    (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
                     blueprint_id, blueprint_snapshot_json, media_quota_mb, media_upload_limit_mb, post_quota, page_quota,
                     allow_master_gallery, allow_master_posts,
                     service_plan_id, billing_status, billing_email,
                     status, created_at, updated_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'comped', ?, 'pending_provision', ?, ?)
            },
            undef,
            $site_id,
            $domain,
            $display_name,
            $first,
            $last_initial,
            $invite->{email},
            $blueprint->{id},
            encode_json($snapshot),
            $service_snapshot->{media_quota_mb},
            $service_snapshot->{media_upload_limit_mb} || 64,
            $service_snapshot->{post_quota},
            $service_snapshot->{page_quota},
            $service_snapshot->{allow_master_gallery},
            $service_snapshot->{allow_master_posts},
            $service_plan->{id},
            $invite->{email},
            $ts,
            $ts
        );
        $dbh->do(
            q{
                UPDATE contributor_invites
                SET status = 'accepted',
                    site_id = ?,
                    domain = ?,
                    accepted_at = ?
                WHERE id = ?
            },
            undef,
            $site_id,
            $domain,
            $ts,
            $invite->{id}
        );
        $self->_enqueue_locked(
            site_id            => $site_id,
            action             => 'create',
            details            => $details,
            created_by_user_id => $invite->{created_by_user_id},
            ts                 => $ts,
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown site acceptance failure';
        eval { $dbh->rollback };
        die $err;
    };

    return $self->site_by_id($site_id);
}

sub site_by_id {
    my ($self, $site_id) = @_;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM contributor_sites WHERE site_id = ?',
        undef,
        $site_id
    );
}

sub register_existing_site {
    my ($self, %args) = @_;
    my $site_id = _clean_site_id($args{site_id});
    my $domain = _clean_domain($args{domain});
    die "site id is required" unless length $site_id;
    die "domain is required" unless length $domain;
    my $root = _domain_root($self);
    die "contributor site domain must be a subdomain of $root"
        if length $root && !_domain_is_subdomain($domain, $root);

    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO contributor_sites
                (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
                 status, config_path, data_dir, public_root, created_at, updated_at, provisioned_at)
            VALUES
                (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)
            ON CONFLICT(site_id) DO UPDATE SET
                domain = excluded.domain,
                display_name = excluded.display_name,
                status = 'active',
                config_path = excluded.config_path,
                data_dir = excluded.data_dir,
                public_root = excluded.public_root,
                updated_at = excluded.updated_at,
                provisioned_at = COALESCE(contributor_sites.provisioned_at, excluded.provisioned_at)
        },
        undef,
        $site_id,
        $domain,
        $args{display_name} || $domain,
        $args{owner_first_name} || '',
        $args{owner_last_initial} || '',
        _normalize_email($args{owner_email} || ''),
        $args{config_path} || "/etc/desertcms-$site_id.conf",
        $args{data_dir} || "/var/desertcms-sites/$site_id",
        $args{public_root} || "/var/www/htdocs/desertcms-$site_id",
        $ts,
        $ts,
        $ts
    );
}

sub create_from_request {
    my ($self, %args) = @_;
    my $first = _clean_name($args{first_name});
    my $last = _clean_name($args{last_name});
    my $last_initial = uc substr(_clean_name($args{last_initial} || $last), 0, 1);
    my $email = _normalize_email($args{email});
    my $name = _clean_name($args{name}) || join(' ', grep { length } ($first, $last));
    die "first name is required" unless length $first;
    die "last initial is required" unless $last_initial =~ /\A[A-Z]\z/;
    die "valid email is required" unless _valid_email($email);

    my $root = _domain_root($self);
    die "contributor domain root is not configured" unless length $root;

    my $site_id = $self->_available_request_site_id($first, $last_initial);
    my $domain = "$site_id.$root";
    my $display_name = length $name ? $name : "$first $last_initial.";
    my $blueprints = DesertCMS::Blueprints->new(config => $self->{config}, db => $self->{db});
    my $blueprint = $blueprints->select_blueprint($args{blueprint_id});
    my $snapshot = $blueprints->snapshot($blueprint);
    my ($service_plan, $service_snapshot) = $self->_default_service_plan_snapshot;
    my $details = {
        domain             => $domain,
        display_name       => $display_name,
        owner_email        => $email,
        owner_first_name   => $first,
        owner_last_initial => $last_initial,
        request_id         => int($args{request_id} || 0),
        bio                => $args{bio} || '',
        blueprint          => $snapshot,
        service_plan       => $service_snapshot,
    };

    my $ts = now();
    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        $dbh->do(
            q{
                INSERT INTO contributor_sites
                    (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
                     blueprint_id, blueprint_snapshot_json, media_quota_mb, media_upload_limit_mb, post_quota, page_quota,
                     allow_master_gallery, allow_master_posts,
                     service_plan_id, billing_status, billing_email,
                     status, created_at, updated_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'comped', ?, 'pending_provision', ?, ?)
            },
            undef,
            $site_id,
            $domain,
            $display_name,
            $first,
            $last_initial,
            $email,
            $blueprint->{id},
            encode_json($snapshot),
            $service_snapshot->{media_quota_mb},
            $service_snapshot->{media_upload_limit_mb} || 64,
            $service_snapshot->{post_quota},
            $service_snapshot->{page_quota},
            $service_snapshot->{allow_master_gallery},
            $service_snapshot->{allow_master_posts},
            $service_plan->{id},
            $email,
            $ts,
            $ts
        );
        $self->_enqueue_locked(
            site_id            => $site_id,
            action             => 'create',
            details            => $details,
            created_by_user_id => $args{created_by_user_id},
            ts                 => $ts,
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown contributor request approval failure';
        eval { $dbh->rollback };
        die $err;
    };

    return $self->site_by_id($site_id);
}

sub revoke_invite {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "invite id is required" unless $id > 0;
    $self->{db}->dbh->do(
        "UPDATE contributor_invites SET status = 'revoked', revoked_at = ? WHERE id = ? AND status = 'pending'",
        undef,
        now(),
        $id
    );
}

sub request_site_action {
    my ($self, %args) = @_;
    my $site_id = _clean_site_id($args{site_id});
    my $action = $args{action} || '';
    die "site id is required" unless length $site_id;
    die "unsupported site action" unless $action =~ /\A(?:enable|disable|destroy)\z/;

    my $site = $self->site_by_id($site_id) or die "site not found";
    my $root = _domain_root($self);
    die "site domain is not under the contributor root"
        if length $root && !_domain_is_subdomain($site->{domain}, $root);
    my $ts = now();
    my $status = $action eq 'enable' ? 'active'
        : $action eq 'disable' ? 'disabled'
        : 'destroy_pending';

    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        $dbh->do(
            q{
                UPDATE contributor_sites
                SET status = ?,
                    updated_at = ?,
                    disabled_at = CASE WHEN ? = 'disabled' THEN ? WHEN ? = 'active' THEN NULL ELSE disabled_at END,
                    destroyed_at = CASE WHEN ? = 'destroy_pending' THEN ? ELSE destroyed_at END
                WHERE site_id = ?
            },
            undef,
            $status,
            $ts,
            $status,
            $ts,
            $status,
            $status,
            $ts,
            $site_id
        );
        $self->_enqueue_locked(
            site_id            => $site_id,
            action             => $action,
            details            => { domain => $site->{domain}, display_name => $site->{display_name} },
            created_by_user_id => $args{created_by_user_id},
            ts                 => $ts,
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown site action failure';
        eval { $dbh->rollback };
        die $err;
    };
}

sub grant_access {
    my ($self, %args) = @_;
    my $site_id = _clean_site_id($args{site_id});
    my $email = _normalize_email($args{email});
    die "site id is required" unless length $site_id;
    die "valid email is required" unless _valid_email($email);

    my $site = $self->site_by_id($site_id) or die "site not found";
    my $root = _domain_root($self);
    die "site domain is not under the contributor root"
        if length $root && !_domain_is_subdomain($site->{domain}, $root);
    die "site must be active before access can be granted" unless ($site->{status} || '') eq 'active';
    my $config_path = $site->{config_path} || '';
    die "site config is missing" unless length $config_path && -f $config_path;

    my $site_config = DesertCMS::Config->load($config_path);
    my $site_db = DesertCMS::DB->new(config => $site_config);
    $site_db->migrate;
    my $username = _available_admin_username($site_db, _username_from_email($email));
    my $temporary_password = random_hex(12);
    my $auth = DesertCMS::Auth->new(config => $site_config, db => $site_db);
    $auth->grant_admin_access(
        username      => $username,
        email         => $email,
        role          => 'contributor',
        password      => $temporary_password,
        actor_user_id => $args{created_by_user_id},
    );
    my $reset = $auth->create_password_reset_token_for_email(
        email       => $email,
        ttl_seconds => 7 * 24 * 60 * 60,
    );

    my $domain = $site->{domain};
    my $admin_url = "https://$domain/admin";
    my $reset_url = $reset ? "$admin_url/password/reset/$reset->{token}" : '';
    my $subject = "Access to $domain";
    my @text = (
        "You have been granted access to the contributor CMS for $domain.",
        "Admin URL: $admin_url",
        "Username: $username",
        "Temporary password: $temporary_password",
    );
    push @text, ("Use this link to choose your permanent password:", $reset_url) if length $reset_url;
    my $html = '<p>You have been granted access to the contributor CMS for '
        . _html($domain)
        . '.</p><p><strong>Admin URL:</strong> <a href="'
        . _html($admin_url)
        . '">'
        . _html($admin_url)
        . '</a><br><strong>Username:</strong> '
        . _html($username)
        . '<br><strong>Temporary password:</strong> '
        . _html($temporary_password)
        . '</p>';
    $html .= '<p><a href="' . _html($reset_url) . '">Choose your permanent password</a></p>'
        if length $reset_url;

    my ($sent, $reason) = send_postmark(
        $self->{config},
        $self->{db},
        to         => $email,
        email_type => 'contributor_access_grant',
        subject    => $subject,
        text_body  => join("\n\n", @text),
        html_body  => $html,
    );

    return {
        site_id  => $site_id,
        domain   => $domain,
        email    => $email,
        username => $username,
        sent     => $sent ? 1 : 0,
        reason   => $reason || ($sent ? 'sent' : 'email not sent'),
    };
}

sub _fleet_site_status {
    my ($self, $site, %args) = @_;
    my $status = $site->{status} || '';
    my $site_id = $site->{site_id} || '';
    my $latest_queue = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM site_provisioning_queue
            WHERE site_id = ?
            ORDER BY updated_at DESC, id DESC
            LIMIT 1
        },
        undef,
        $site_id
    );

    my $data_dir = $site->{data_dir} || '';
    my $public_root = $site->{public_root} || '';
    my $db_path = length $data_dir ? File::Spec->catfile($data_dir, 'desertcms.sqlite') : '';
    my $paths = {
        config => _path_state($site->{config_path}, 'file'),
        data   => _path_state($data_dir, 'dir'),
        public => _path_state($public_root, 'dir'),
        db     => _path_state($db_path, 'file'),
    };
    my $backups = _backup_state($data_dir);
    my $last_rebuild = _last_rebuild_time($public_root);
    my $last_login = _last_login_time($site->{config_path});
    my ($data_bytes, $data_files) = _dir_size($data_dir);
    my ($public_bytes, $public_files) = _dir_size($public_root);
    my $disk = {
        bytes => $data_bytes + $public_bytes,
        files => $data_files + $public_files,
    };
    my $dns = _dns_state($site->{domain}, exists $args{check_dns} ? $args{check_dns} : 1);
    my $tls = _tls_state($site->{domain}, exists $args{check_tls} ? $args{check_tls} : 1);
    my @alerts;

    if ($latest_queue && ($latest_queue->{status} || '') eq 'failed') {
        my $message = $latest_queue->{error_text} || 'last provisioning job failed';
        push @alerts, _trim_alert($message);
    }
    if ($status eq 'active' || $status eq 'disabled') {
        for my $key (qw(config data public db)) {
            push @alerts, "$key path missing" if ($paths->{$key}{state} || '') eq 'warn';
        }
        push @alerts, 'DNS does not resolve' if ($dns->{state} || '') eq 'warn';
        push @alerts, 'TLS certificate missing' if ($tls->{state} || '') eq 'warn';
        push @alerts, 'no backups found' if int($backups->{count} || 0) == 0;
    }
    if ($status eq 'pending_provision') {
        my $queue_status = $latest_queue ? ($latest_queue->{status} || '') : '';
        push @alerts, 'pending provisioning with no queued job'
            unless $queue_status eq 'queued' || $queue_status eq 'running';
    }

    return {
        %{$site},
        queue        => $latest_queue,
        paths        => $paths,
        dns          => $dns,
        tls          => $tls,
        backups      => $backups,
        disk         => $disk,
        last_rebuild => $last_rebuild,
        last_login   => $last_login,
        version      => $args{app_version} || '',
        alerts       => \@alerts,
    };
}

sub _path_state {
    my ($path, $kind) = @_;
    $path = '' unless defined $path;
    return { path => '', state => 'neutral', label => 'Not set' } unless length $path;
    my $present = $kind && $kind eq 'dir' ? -d $path : -f $path;
    return {
        path  => $path,
        state => $present ? 'ok' : 'warn',
        label => $present ? 'Present' : 'Missing',
    };
}

sub _backup_state {
    my ($data_dir) = @_;
    return { count => 0, latest => 0, state => 'neutral' } unless defined $data_dir && length $data_dir;
    my $backup_dir = File::Spec->catdir($data_dir, 'backups');
    return { count => 0, latest => 0, state => 'warn' } unless -d $backup_dir;

    my $count = 0;
    my $latest = 0;
    if (opendir my $dh, $backup_dir) {
        while (defined(my $entry = readdir $dh)) {
            next unless $entry =~ /\Adesertcms-.*\.tar\.gz\z/;
            my $path = File::Spec->catfile($backup_dir, $entry);
            next unless -f $path;
            $count++;
            my $mtime = (stat $path)[9] || 0;
            $latest = $mtime if $mtime > $latest;
        }
        closedir $dh;
    }
    return {
        count  => $count,
        latest => $latest,
        state  => $count ? 'ok' : 'warn',
    };
}

sub _last_rebuild_time {
    my ($public_root) = @_;
    return 0 unless defined $public_root && length $public_root && -d $public_root;
    my $latest = 0;
    for my $file (qw(index.html sitemap.xml robots.txt)) {
        my $path = File::Spec->catfile($public_root, $file);
        next unless -f $path;
        my $mtime = (stat $path)[9] || 0;
        $latest = $mtime if $mtime > $latest;
    }
    return $latest;
}

sub _last_login_time {
    my ($config_path) = @_;
    return 0 unless defined $config_path && length $config_path && -f $config_path;
    my $latest = 0;
    eval {
        my $site_config = DesertCMS::Config->load($config_path);
        my $site_db = DesertCMS::DB->new(config => $site_config);
        ($latest) = $site_db->dbh->selectrow_array(
            q{
                SELECT COALESCE(MAX(s.created_at), 0)
                FROM sessions s
                JOIN admin_users u ON u.id = s.user_id
                WHERE u.disabled_at IS NULL
            }
        );
        1;
    };
    return int($latest || 0);
}

sub _dir_size {
    my ($path) = @_;
    return (0, 0) unless defined $path && length $path && -d $path;
    my ($bytes, $files) = (0, 0);
    eval {
        find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return unless -f $File::Find::name;
                    $bytes += -s $File::Find::name || 0;
                    $files++;
                },
            },
            $path
        );
        1;
    };
    return ($bytes, $files);
}

sub _dns_state {
    my ($domain, $enabled) = @_;
    $domain = lc($domain || '');
    return { state => 'neutral', label => 'Not checked', detail => 'Open with DNS check when needed.' } unless $enabled;
    return { state => 'warn', label => 'Missing', detail => 'No domain is stored.' }
        unless $domain =~ /\A[a-z0-9.-]+\.[a-z]{2,}\z/;

    my @ips;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "dns timeout\n" };
        alarm 2;
        my @host = gethostbyname($domain);
        alarm 0;
        @ips = map { inet_ntoa($_) } @host[4 .. $#host] if @host > 4;
        1;
    };
    alarm 0;

    if ($ok && @ips) {
        return {
            state  => 'ok',
            label  => 'Resolves',
            detail => join(', ', @ips[0 .. (@ips > 2 ? 1 : $#ips)]),
        };
    }
    return {
        state  => 'warn',
        label  => 'Unresolved',
        detail => $ok ? 'No A record returned.' : 'DNS lookup failed or timed out.',
    };
}

sub _tls_state {
    my ($domain, $enabled) = @_;
    $domain = lc($domain || '');
    return { state => 'neutral', label => 'Not checked', detail => 'Certificate check skipped.' } unless $enabled;
    return { state => 'neutral', label => 'Unknown', detail => 'No domain is stored.' }
        unless $domain =~ /\A[a-z0-9.-]+\.[a-z]{2,}\z/;
    return { state => 'neutral', label => 'Not visible', detail => 'Certificate files are checked on OpenBSD.' }
        unless -d '/etc/ssl';

    my $cert = "/etc/ssl/$domain.fullchain.pem";
    return { state => 'ok', label => 'Present', detail => $cert } if -f $cert;
    return { state => 'warn', label => 'Missing', detail => $cert };
}

sub _trim_alert {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+\z//g;
    return substr($value || 'needs attention', 0, 140);
}

sub _slash_path {
    my ($path) = @_;
    $path = '' unless defined $path;
    $path =~ s{\\}{/}g;
    return $path;
}

sub _default_service_plan_snapshot {
    my ($self) = @_;
    my $service_plans = DesertCMS::ServicePlans->new(config => $self->{config}, db => $self->{db});
    my $plan = $service_plans->default_plan or die "default service plan is not available";
    my $snapshot = $service_plans->snapshot($plan);
    die "default service plan snapshot is invalid" unless $snapshot->{schema_version};
    return ($plan, $snapshot);
}

sub _enqueue_locked {
    my ($self, %args) = @_;
    my $ts = $args{ts} || now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO site_provisioning_queue
                (site_id, action, status, details_json, created_by_user_id, created_at, updated_at)
            VALUES
                (?, ?, 'queued', ?, ?, ?, ?)
        },
        undef,
        $args{site_id},
        $args{action},
        encode_json($args{details} || {}),
        $args{created_by_user_id},
        $ts,
        $ts
    );
}

sub _queue_job_is_visible {
    my ($self, $job) = @_;
    return 0 unless $job && length($job->{site_id} || '');
    my $root = _domain_root($self);
    return 1 unless length $root;
    my $site = $self->site_by_id($job->{site_id}) or return 0;
    return _domain_is_subdomain($site->{domain}, $root);
}

sub _available_site_id {
    my ($self, $first, $last_initial) = @_;
    my @bases = (slugify($first), slugify($first . '-' . lc($last_initial)));
    my %seen;
    my @clean_bases;

    for my $base (@bases) {
        $base =~ s/[^a-z0-9-]//g;
        $base =~ s/^-+|-+$//g;
        $base = 'site' if length($base) < 2;
        next if $seen{$base}++;
        push @clean_bases, $base;
    }

    for my $candidate (@clean_bases) {
        my ($count) = $self->{db}->dbh->selectrow_array(
            'SELECT COUNT(*) FROM contributor_sites WHERE site_id = ?',
            undef,
            $candidate
        );
        return $candidate unless $count;
    }

    for my $suffix (2 .. 99) {
        for my $base (@clean_bases) {
            my $candidate = $base . $suffix;
            next if length($candidate) > 63;
            my ($count) = $self->{db}->dbh->selectrow_array(
                'SELECT COUNT(*) FROM contributor_sites WHERE site_id = ?',
                undef,
                $candidate
            );
            return $candidate unless $count;
        }
    }
    die "could not find an available subdomain";
}

sub _available_request_site_id {
    my ($self, $first, $last_initial) = @_;
    my $first_slug = slugify($first);
    my $initial = lc($last_initial || '');
    $initial =~ s/[^a-z]//g;
    my @bases = ($first_slug . $initial, $first_slug . '-' . $initial, $first_slug);
    my %seen;
    my @clean_bases;
    for my $base (@bases) {
        $base =~ s/[^a-z0-9-]//g;
        $base =~ s/^-+|-+$//g;
        $base = 'site' if length($base) < 2;
        next if $seen{$base}++;
        push @clean_bases, $base;
    }

    for my $candidate (@clean_bases) {
        my ($count) = $self->{db}->dbh->selectrow_array(
            'SELECT COUNT(*) FROM contributor_sites WHERE site_id = ?',
            undef,
            $candidate
        );
        return $candidate unless $count;
    }

    for my $suffix (2 .. 99) {
        for my $base (@clean_bases) {
            my $candidate = $base . $suffix;
            next if length($candidate) > 63;
            my ($count) = $self->{db}->dbh->selectrow_array(
                'SELECT COUNT(*) FROM contributor_sites WHERE site_id = ?',
                undef,
                $candidate
            );
            return $candidate unless $count;
        }
    }
    die "could not find an available subdomain";
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
    $root =~ s/^\.+|\.+$//g;
    return $root =~ /\A[a-z0-9.-]+\.[a-z]{2,}\z/ ? $root : '';
}

sub _domain_is_subdomain {
    my ($domain, $root) = @_;
    $domain = lc($domain || '');
    $root = lc($root || '');
    $domain =~ s/^\.+|\.+$//g;
    $root =~ s/^\.+|\.+$//g;
    return 0 unless length $domain && length $root;
    return 0 if $domain eq $root;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+\Q$root\E\z/ ? 1 : 0;
}

sub _available_admin_username {
    my ($site_db, $base) = @_;
    $base = _clean_username($base);
    $base = 'admin' if length($base) < 3;
    for my $suffix ('', 2 .. 99) {
        my $candidate = substr($base, 0, $suffix ? 61 : 64) . $suffix;
        my ($count) = $site_db->dbh->selectrow_array(
            'SELECT COUNT(*) FROM admin_users WHERE username = ?',
            undef,
            $candidate
        );
        return $candidate unless $count;
    }
    die "could not find an available admin username";
}

sub _username_from_email {
    my ($email) = @_;
    my ($local) = split /@/, $email, 2;
    return _clean_username($local || 'admin');
}

sub _clean_username {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/[^a-z0-9._-]+/./g;
    $value =~ s/^[^a-z0-9]+//;
    $value =~ s/[^a-z0-9]+$//;
    $value =~ s/[._-]{2,}/./g;
    return substr($value, 0, 64);
}

sub _normalize_email {
    my ($email) = @_;
    $email = lc($email || '');
    $email =~ s/^\s+|\s+$//g;
    return $email;
}

sub _valid_email {
    my ($email) = @_;
    return $email =~ /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z/ ? 1 : 0;
}

sub _clean_message {
    my ($message) = @_;
    $message = '' unless defined $message;
    $message =~ s/\r\n?/\n/g;
    $message =~ s/^\s+|\s+$//g;
    return substr($message, 0, 1000);
}

sub _clean_name {
    my ($name) = @_;
    $name = '' unless defined $name;
    $name =~ s/^\s+|\s+$//g;
    $name =~ s/[^A-Za-z' -]//g;
    $name =~ s/\s+/ /g;
    return substr($name, 0, 80);
}

sub _clean_site_id {
    my ($site_id) = @_;
    $site_id = lc($site_id || '');
    $site_id =~ s/[^a-z0-9-]//g;
    $site_id =~ s/^-+|-+$//g;
    return $site_id;
}

sub _clean_domain {
    my ($domain) = @_;
    $domain = lc($domain || '');
    $domain =~ s/^\s+|\s+$//g;
    $domain =~ s/^\.+|\.+$//g;
    die "domain contains unsafe characters" unless $domain =~ /\A[a-z0-9.-]+\z/;
    return $domain;
}

sub _html {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

1;
