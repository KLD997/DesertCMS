package DesertCMS::Membership;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use DesertCMS::Docs;
use DesertCMS::Media;
use DesertCMS::Modules;
use DesertCMS::Password;
use DesertCMS::Settings;
use DesertCMS::Util qw(now random_hex sha256_hexstr hmac_sha256_hex constant_time_eq slugify);

my %RESOURCE_STATUS = map { $_ => 1 } qw(draft published archived);
my %RESOURCE_ACCESS = map { $_ => 1 } qw(members group private);
my %MEMBER_STATUS = map { $_ => 1 } qw(pending invited active disabled);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
        media  => $args{media} || DesertCMS::Media->new(config => $args{config}, db => $args{db}),
    }, $class;
}

sub clear_settings_cache {
    my ($self) = @_;
    delete $self->{_settings};
}

sub enabled {
    my ($self) = @_;
    return DesertCMS::Modules::enabled(_settings($self), 'membership');
}

sub membership_payments_allowed_by_plan {
    my ($self) = @_;
    return 0 unless $self->enabled;
    return _plan_feature_enabled(_settings($self), 'membership_payments', 1);
}

sub checkout_ready {
    my ($self) = @_;
    return $self->payment_readiness->{checkout_enabled} ? 1 : 0;
}

sub payment_readiness {
    my ($self) = @_;
    my $settings = _settings($self);
    my $enabled = $self->enabled;
    my $allowed = $self->membership_payments_allowed_by_plan;
    my $model = lc($settings->{commerce_model} || '');
    $model =~ s/[-\s]+/_/g;
    my $model_allows = $model =~ /\A(?:master_owned|contributor_owned|platform_marketplace)\z/ ? 1 : 0;
    my $stripe_key = length($settings->{stripe_secret_key} || '') ? 1 : 0;
    my $webhook = length($settings->{stripe_webhook_secret} || '') ? 1 : 0;
    my $marketplace = $model eq 'platform_marketplace' ? 1 : 0;
    my $connect = $marketplace
        ? (($settings->{stripe_connect_account_id} || '')
            && ($settings->{stripe_connect_charges_enabled} || 0)
            && ($settings->{stripe_connect_payouts_enabled} || 0) ? 1 : 0)
        : 1;

    my ($state, $label, $summary);
    if (!$enabled) {
        ($state, $label, $summary) = ('neutral', 'Membership disabled', 'Enable Membership before configuring paid member access.');
    } elsif (!$allowed) {
        ($state, $label, $summary) = ('warn', 'Payments locked', 'Member accounts and gated resources are available; paid access requires Membership Payments.');
    } elsif (!$model_allows) {
        ($state, $label, $summary) = ('warn', 'Payments disabled', 'Choose a Stripe commerce model before paid member access can be used.');
    } elsif (!$stripe_key || !$webhook) {
        ($state, $label, $summary) = ('warn', 'Stripe not ready', 'Configure Stripe key and webhook secret before paid member access can be used.');
    } elsif (!$connect) {
        ($state, $label, $summary) = ('warn', 'Payouts not ready', 'Contributor marketplace paid access needs an active Stripe connected account.');
    } else {
        ($state, $label, $summary) = ('ok', 'Ready', 'Membership Payments can create paid member-resource or subscription records.');
    }

    return {
        state => $state,
        label => $label,
        summary => $summary,
        checkout_enabled => ($enabled && $allowed && $model_allows && $stripe_key && $webhook && $connect) ? 1 : 0,
        payment_model => $model || 'disabled',
        allowed_by_plan => $allowed ? 1 : 0,
    };
}

sub groups {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT g.*, COUNT(m.member_id) AS member_count
            FROM member_groups g
            LEFT JOIN member_group_members m ON m.group_id = g.id
            GROUP BY g.id
            ORDER BY lower(g.name), g.id
        },
        { Slice => {} }
    );
}

sub group_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM member_groups WHERE id = ?', undef, int($id));
}

sub save_group {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $name = _clean_text($args{name}, 120);
    die "group name is required" unless length $name;
    my $slug = slugify(_clean_text($args{slug}, 120) || $name);
    my $description = _clean_text($args{description}, 500);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    if ($id && $self->group_by_id($id)) {
        $dbh->do(
            q{
                UPDATE member_groups
                SET name = ?, slug = ?, description = ?, updated_at = ?
                WHERE id = ?
            },
            undef,
            $name, $slug, $description, $ts, $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO member_groups (name, slug, description, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
            },
            undef,
            $name, $slug, $description, $ts, $ts
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->group_by_id($id);
}

sub members {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 250, 1, 1000);
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT m.*,
                   GROUP_CONCAT(g.name, ', ') AS group_names
            FROM member_accounts m
            LEFT JOIN member_group_members mg ON mg.member_id = m.id
            LEFT JOIN member_groups g ON g.id = mg.group_id
            GROUP BY m.id
            ORDER BY CASE m.status WHEN 'active' THEN 0 WHEN 'pending' THEN 1 WHEN 'invited' THEN 2 ELSE 3 END,
                     lower(m.email)
            LIMIT ?
        },
        { Slice => {} },
        $limit
    );
    return $rows;
}

sub member_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    my $row = $self->{db}->dbh->selectrow_hashref('SELECT * FROM member_accounts WHERE id = ?', undef, int($id));
    $self->_attach_group_ids($row) if $row;
    return $row;
}

sub member_by_email {
    my ($self, $email) = @_;
    $email = _email($email);
    return undef unless length $email;
    my $row = $self->{db}->dbh->selectrow_hashref('SELECT * FROM member_accounts WHERE lower(email) = ?', undef, $email);
    $self->_attach_group_ids($row) if $row;
    return $row;
}

sub save_member {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $email = _email($args{email});
    die "member email is invalid" unless _valid_email($email);
    my $display = _clean_text($args{display_name}, 140);
    my $status = _member_status($args{status});
    my $password = $args{password};
    my @group_ids = _group_ids($args{group_ids});
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $hash = defined($password) && length($password)
        ? _password_hash($password)
        : undef;

    $dbh->begin_work;
    eval {
        if ($id && $self->member_by_id($id)) {
            if (defined $hash) {
                $dbh->do(
                    q{
                        UPDATE member_accounts
                        SET email = ?, display_name = ?, password_hash = ?, password_algo = 'pbkdf2-sha256',
                            status = ?, updated_at = ?, disabled_at = CASE WHEN ? = 'disabled' THEN COALESCE(disabled_at, ?) ELSE NULL END
                        WHERE id = ?
                    },
                    undef,
                    $email, $display, $hash, $status, $ts, $status, $ts, $id
                );
            } else {
                $dbh->do(
                    q{
                        UPDATE member_accounts
                        SET email = ?, display_name = ?, status = ?, updated_at = ?,
                            disabled_at = CASE WHEN ? = 'disabled' THEN COALESCE(disabled_at, ?) ELSE NULL END
                        WHERE id = ?
                    },
                    undef,
                    $email, $display, $status, $ts, $status, $ts, $id
                );
            }
        } else {
            die "password must be at least 10 characters" unless defined($password) && length($password) >= 10;
            $hash ||= _password_hash($password);
            $dbh->do(
                q{
                    INSERT INTO member_accounts
                        (email, display_name, password_hash, password_algo, status, signup_source, created_at, updated_at, confirmed_at, disabled_at)
                    VALUES
                        (?, ?, ?, 'pbkdf2-sha256', ?, ?, ?, ?, ?, ?)
                },
                undef,
                $email, $display, $hash, $status, _clean_text($args{signup_source}, 80),
                $ts, $ts, $status eq 'active' ? $ts : undef, $status eq 'disabled' ? $ts : undef
            );
            $id = int($dbh->sqlite_last_insert_rowid);
        }
        $self->_replace_member_groups($id, \@group_ids);
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'member save failed';
        eval { $dbh->rollback };
        die "member email is already in use" if $err =~ /unique/i;
        die $err;
    };

    return $self->member_by_id($id);
}

sub signup_member {
    my ($self, %args) = @_;
    my $settings = _settings($self);
    die "member signup is not enabled" unless $settings->{membership_signup_enabled};
    return $self->save_member(
        email => $args{email},
        display_name => $args{display_name},
        password => $args{password},
        status => 'active',
        signup_source => 'public_signup',
    );
}

sub create_invite {
    my ($self, %args) = @_;
    my $email = _email($args{email});
    die "member email is invalid" unless _valid_email($email);
    my $group_id = int($args{group_id} || 0);
    $group_id = undef unless $group_id && $self->group_by_id($group_id);
    my $token = random_hex(32);
    my $ts = now();
    my $expires = $ts + int($args{ttl_seconds} || 7 * 24 * 60 * 60);
    $self->{db}->dbh->do(
        q{
            INSERT INTO member_invites
                (email, display_name, group_id, token_hash, status, created_at, expires_at, ip_address)
            VALUES
                (?, ?, ?, ?, 'pending', ?, ?, ?)
        },
        undef,
        $email,
        _clean_text($args{display_name}, 140),
        $group_id,
        sha256_hexstr($token),
        $ts,
        $expires,
        $args{ip_address} || ''
    );
    return {
        token => $token,
        email => $email,
        expires_at => $expires,
        group_id => $group_id,
    };
}

sub invite_from_token {
    my ($self, $token) = @_;
    $token = lc($token || '');
    return undef unless $token =~ /\A[0-9a-f]{64}\z/;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT i.*, g.name AS group_name
            FROM member_invites i
            LEFT JOIN member_groups g ON g.id = i.group_id
            WHERE i.token_hash = ?
              AND i.status = 'pending'
              AND i.expires_at > ?
        },
        undef,
        sha256_hexstr($token),
        now()
    );
}

sub accept_invite {
    my ($self, %args) = @_;
    my $token = lc($args{token} || '');
    die "invite token is invalid or expired" unless $token =~ /\A[0-9a-f]{64}\z/;
    my $password = $args{password} || '';
    die "password must be at least 10 characters" unless length($password) >= 10;
    my $ts = now();
    my $invite = $self->invite_from_token($token) or die "invite token is invalid or expired";
    my $member = $self->member_by_email($invite->{email});
    if ($member) {
        $member = $self->save_member(
            id => $member->{id},
            email => $invite->{email},
            display_name => $args{display_name} || $invite->{display_name} || $member->{display_name},
            password => $password,
            status => 'active',
            group_ids => $invite->{group_id} ? [ $invite->{group_id} ] : $member->{group_ids},
        );
    } else {
        $member = $self->save_member(
            email => $invite->{email},
            display_name => $args{display_name} || $invite->{display_name},
            password => $password,
            status => 'active',
            signup_source => 'invite',
            group_ids => $invite->{group_id} ? [ $invite->{group_id} ] : [],
        );
    }
    $self->{db}->dbh->do(
        'UPDATE member_invites SET status = ?, accepted_at = ? WHERE token_hash = ?',
        undef,
        'accepted',
        $ts,
        sha256_hexstr($token)
    );
    return $member;
}

sub authenticate {
    my ($self, %args) = @_;
    my $email = _email($args{email});
    my $password = $args{password} || '';
    my $member = $self->member_by_email($email);
    return (undef, 'invalid') unless $member && ($member->{status} || '') eq 'active' && !$member->{disabled_at};
    return (undef, 'invalid') unless DesertCMS::Password::verify_password($password, $member->{password_hash});
    $self->{db}->dbh->do('UPDATE member_accounts SET last_login_at = ?, updated_at = ? WHERE id = ?', undef, now(), now(), $member->{id});
    $member = $self->member_by_id($member->{id});
    return ($member, undef);
}

sub create_session {
    my ($self, %args) = @_;
    my $member = $args{member} or die "member is required";
    my $token = random_hex(32);
    my $ts = now();
    my $ttl = int($self->{config}->get('member_session_ttl_seconds') || 30 * 24 * 60 * 60);
    my $expires = $ts + $ttl;
    $self->{db}->dbh->do(
        q{
            INSERT INTO member_sessions
                (member_id, token_hash, ip_address, user_agent, created_at, expires_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        int($member->{id}),
        sha256_hexstr($token),
        $args{ip_address} || '',
        substr($args{user_agent} || '', 0, 500),
        $ts,
        $expires,
        $ts
    );
    return ($token, $expires);
}

sub session_from_token {
    my ($self, $token) = @_;
    return undef unless defined $token && $token =~ /\A[0-9a-fA-F]{64}\z/;
    my $ts = now();
    my $row = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT s.*, m.email, m.display_name, m.status, m.disabled_at
            FROM member_sessions s
            JOIN member_accounts m ON m.id = s.member_id
            WHERE s.token_hash = ?
              AND s.revoked_at IS NULL
              AND s.expires_at > ?
              AND m.status = 'active'
              AND m.disabled_at IS NULL
        },
        undef,
        sha256_hexstr(lc $token),
        $ts
    );
    if ($row) {
        $self->{db}->dbh->do('UPDATE member_sessions SET last_seen_at = ? WHERE id = ?', undef, $ts, $row->{id});
        $row->{id} = $row->{member_id};
        $self->_attach_group_ids($row);
    }
    return $row;
}

sub revoke_session {
    my ($self, $token) = @_;
    return unless defined $token;
    $self->{db}->dbh->do(
        'UPDATE member_sessions SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL',
        undef,
        now(),
        sha256_hexstr(lc $token)
    );
}

sub csrf_token {
    my ($self, $session_token) = @_;
    return hmac_sha256_hex('member:' . ($session_token || ''), $self->{config}->app_secret);
}

sub verify_csrf {
    my ($self, $session_token, $submitted) = @_;
    return 0 unless defined $submitted;
    return constant_time_eq($self->csrf_token($session_token), $submitted);
}

sub create_password_reset_token_for_email {
    my ($self, %args) = @_;
    my $email = _email($args{email});
    return undef unless _valid_email($email);
    my $member = $self->member_by_email($email);
    return undef unless $member && ($member->{status} || '') eq 'active' && !$member->{disabled_at};
    my $token = random_hex(32);
    my $ts = now();
    my $expires = $ts + int($args{ttl_seconds} || 60 * 60);
    my $dbh = $self->{db}->dbh;
    $dbh->do("UPDATE member_password_reset_tokens SET status = 'revoked' WHERE member_id = ? AND status = 'pending'", undef, $member->{id});
    $dbh->do(
        q{
            INSERT INTO member_password_reset_tokens
                (member_id, email, token_hash, status, created_at, expires_at, ip_address)
            VALUES
                (?, ?, ?, 'pending', ?, ?, ?)
        },
        undef,
        $member->{id},
        $email,
        sha256_hexstr($token),
        $ts,
        $expires,
        $args{ip_address} || ''
    );
    return {
        token => $token,
        email => $email,
        member_id => $member->{id},
        expires_at => $expires,
    };
}

sub password_reset_from_token {
    my ($self, $token) = @_;
    $token = lc($token || '');
    return undef unless $token =~ /\A[0-9a-f]{64}\z/;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT r.*, m.display_name, m.email AS member_email
            FROM member_password_reset_tokens r
            JOIN member_accounts m ON m.id = r.member_id
            WHERE r.token_hash = ?
              AND r.status = 'pending'
              AND r.expires_at > ?
              AND m.status = 'active'
              AND m.disabled_at IS NULL
        },
        undef,
        sha256_hexstr($token),
        now()
    );
}

sub consume_password_reset_token {
    my ($self, %args) = @_;
    my $token = lc($args{token} || '');
    die "reset token is invalid or expired" unless $token =~ /\A[0-9a-f]{64}\z/;
    my $password = $args{password} || '';
    die "password must be at least 10 characters" unless length($password) >= 10;
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $member_id;
    $dbh->begin_work;
    eval {
        my $reset = $self->password_reset_from_token($token) or die "reset token is invalid or expired";
        $member_id = int($reset->{member_id});
        $dbh->do(
            q{
                UPDATE member_accounts
                SET password_hash = ?, password_algo = 'pbkdf2-sha256', updated_at = ?
                WHERE id = ? AND status = 'active' AND disabled_at IS NULL
            },
            undef,
            _password_hash($password),
            $ts,
            $member_id
        );
        $dbh->do('UPDATE member_password_reset_tokens SET status = ?, used_at = ? WHERE id = ?', undef, 'used', $ts, $reset->{id});
        $dbh->do('UPDATE member_sessions SET revoked_at = ? WHERE member_id = ? AND revoked_at IS NULL', undef, $ts, $member_id);
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'password reset failed';
        eval { $dbh->rollback };
        die $err;
    };
    return $self->member_by_id($member_id);
}

sub content_for_member {
    my ($self, $member) = @_;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM content_items
            WHERE status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') <> 'public'
            ORDER BY type ASC, title ASC, id ASC
        },
        { Slice => {} }
    );
    return [ grep { $self->member_can_access($member, $_->{access_policy}, $_->{access_group_id}) } @{$rows} ];
}

sub content_by_slug_for_member {
    my ($self, $slug, $member) = @_;
    $slug = slugify($slug || '');
    my $row = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM content_items
            WHERE slug = ?
              AND status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') <> 'public'
            LIMIT 1
        },
        undef,
        $slug
    );
    return undef unless $row && $self->member_can_access($member, $row->{access_policy}, $row->{access_group_id});
    return $row;
}

sub docs_for_member {
    my ($self, $member) = @_;
    return [] unless $self->enabled;
    my $settings = _settings($self);
    return [] unless DesertCMS::Modules::enabled($settings, 'docs');
    my $docs = DesertCMS::Docs->new(config => $self->{config});
    my @held = grep {
        !$_->{public_access}
            && (($_->{access} || '') eq 'Members only' || ($_->{access} || '') eq 'Private')
    } @{ $docs->documents(settings => $settings) };
    return \@held;
}

sub doc_for_member {
    my ($self, $slug, $member) = @_;
    $slug = slugify($slug || '');
    for my $doc (@{ $self->docs_for_member($member) }) {
        return $doc if ($doc->{slug} || '') eq $slug;
    }
    return undef;
}

sub resources {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 500, 1, 5000);
    my $where = '1=1';
    my @bind;
    if ($args{published}) {
        $where .= " AND r.status = 'published'";
    }
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT r.*, a.original_name, a.mime_type, a.bytes, a.storage_path, g.name AS group_name
            FROM membership_resources r
            LEFT JOIN media_assets a ON a.id = r.media_asset_id
            LEFT JOIN member_groups g ON g.id = r.access_group_id
            WHERE $where
            ORDER BY r.status = 'published' DESC, r.sort_order ASC, lower(r.title), r.id
            LIMIT ?
        },
        { Slice => {} },
        @bind,
        $limit
    );
}

sub resources_for_member {
    my ($self, $member) = @_;
    my @rows = grep {
        $self->member_can_access($member, $_->{access_policy}, $_->{access_group_id})
    } @{ $self->resources(published => 1, limit => 5000) };
    return \@rows;
}

sub resource_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT r.*, a.original_name, a.mime_type, a.bytes, a.storage_path, g.name AS group_name
            FROM membership_resources r
            LEFT JOIN media_assets a ON a.id = r.media_asset_id
            LEFT JOIN member_groups g ON g.id = r.access_group_id
            WHERE r.id = ?
        },
        undef,
        int($id)
    );
}

sub resource_by_slug {
    my ($self, $slug) = @_;
    $slug = slugify($slug || '');
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT r.*, a.original_name, a.mime_type, a.bytes, a.storage_path, g.name AS group_name
            FROM membership_resources r
            LEFT JOIN media_assets a ON a.id = r.media_asset_id
            LEFT JOIN member_groups g ON g.id = r.access_group_id
            WHERE r.slug = ?
        },
        undef,
        $slug
    );
}

sub save_resource {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $title = _clean_text($args{title}, 180);
    die "resource title is required" unless length $title;
    my $slug = slugify(_clean_text($args{slug}, 180) || $title);
    my $summary = _clean_text($args{summary}, 500);
    my $body = _clean_text($args{body}, 5000);
    my $media_id = int($args{media_asset_id} || 0) || undef;
    $media_id = undef unless $media_id && _media_exists($self, $media_id);
    my $collection = _clean_text($args{collection_name}, 120);
    my $access = _resource_access($args{access_policy});
    my $group_id = $access eq 'group' ? int($args{access_group_id} || 0) : undef;
    $group_id = undef unless $group_id && $self->group_by_id($group_id);
    my $status = _resource_status($args{status});
    my $direct = $args{direct_download} ? 1 : 0;
    my $sort = defined($args{sort_order}) && $args{sort_order} =~ /\A-?[0-9]+\z/ ? int($args{sort_order}) : 100;
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    if ($id && $self->resource_by_id($id)) {
        $dbh->do(
            q{
                UPDATE membership_resources
                SET title = ?, slug = ?, summary = ?, body = ?, media_asset_id = ?, collection_name = ?,
                    access_policy = ?, access_group_id = ?, status = ?, direct_download = ?, sort_order = ?,
                    updated_at = ?, published_at = CASE WHEN ? = 'published' THEN COALESCE(published_at, ?) ELSE published_at END
                WHERE id = ?
            },
            undef,
            $title, $slug, $summary, $body, $media_id, $collection, $access, $group_id, $status,
            $direct, $sort, $ts, $status, $ts, $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO membership_resources
                    (title, slug, summary, body, media_asset_id, collection_name, access_policy, access_group_id,
                     status, direct_download, sort_order, created_at, updated_at, published_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $title, $slug, $summary, $body, $media_id, $collection, $access, $group_id,
            $status, $direct, $sort, $ts, $ts, $status eq 'published' ? $ts : undef
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->resource_by_id($id);
}

sub publish_resource {
    my ($self, $id) = @_;
    my $row = $self->resource_by_id($id) or die "resource not found";
    $self->{db}->dbh->do(
        "UPDATE membership_resources SET status = 'published', published_at = COALESCE(published_at, ?), updated_at = ? WHERE id = ?",
        undef,
        now(),
        now(),
        int($id)
    );
    return $self->resource_by_id($id);
}

sub archive_resource {
    my ($self, $id) = @_;
    my $row = $self->resource_by_id($id) or die "resource not found";
    $self->{db}->dbh->do("UPDATE membership_resources SET status = 'archived', updated_at = ? WHERE id = ?", undef, now(), int($id));
    return $self->resource_by_id($id);
}

sub resource_download {
    my ($self, %args) = @_;
    my $member = $args{member} || {};
    my $resource = $args{resource} || $self->resource_by_id($args{id});
    die "resource not found" unless $resource;
    die "resource is not published" unless ($resource->{status} || '') eq 'published';
    die "member cannot access resource" unless $self->member_can_access($member, $resource->{access_policy}, $resource->{access_group_id});
    die "resource has no private file attached" unless int($resource->{media_asset_id} || 0) > 0;
    return $self->{media}->source_download(id => $resource->{media_asset_id});
}

sub create_payment_checkout {
    my ($self, %args) = @_;
    die "Membership Payments are not available on this plan or checkout is not ready"
        unless $self->checkout_ready;
    die "paid membership resource checkout is reserved for the Membership Payments expansion";
}

sub recent_payments {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 25, 1, 250);
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT p.*, m.email AS member_email, r.title AS resource_title
            FROM membership_payments p
            LEFT JOIN member_accounts m ON m.id = p.member_id
            LEFT JOIN membership_resources r ON r.id = p.resource_id
            ORDER BY p.created_at DESC, p.id DESC
            LIMIT ?
        },
        { Slice => {} },
        $limit
    );
}

sub member_can_access {
    my ($self, $member, $policy, $group_id) = @_;
    $policy = lc($policy || 'members');
    return 1 if $policy eq 'public';
    return 0 unless $member && int($member->{id} || $member->{member_id} || 0) > 0;
    return 1 if $policy eq 'members';
    return 0 if $policy eq 'private';
    if ($policy eq 'group') {
        my %groups = map { int($_) => 1 } @{ $member->{group_ids} || [] };
        return $groups{int($group_id || 0)} ? 1 : 0;
    }
    return 0;
}

sub access_label {
    my ($policy, $group_name) = @_;
    $policy = lc($policy || 'members');
    return 'All members' if $policy eq 'members';
    return 'Private' if $policy eq 'private';
    return length($group_name || '') ? 'Group: ' . $group_name : 'Group members';
}

sub _settings {
    my ($self) = @_;
    return $self->{_settings} ||= DesertCMS::Settings::all($self->{config}, $self->{db});
}

sub _plan_feature_enabled {
    my ($settings, $key, $default) = @_;
    my $json = $settings->{contributor_plan_features_json} || '';
    return $default ? 1 : 0 unless length $json;
    my $decoded = eval { decode_json($json) };
    return $default ? 1 : 0 unless $decoded && ref $decoded eq 'HASH';
    return $decoded->{$key} ? 1 : 0 if exists $decoded->{$key};
    return 0;
}

sub _attach_group_ids {
    my ($self, $member) = @_;
    return unless $member;
    my $member_id = int($member->{member_id} || $member->{id} || 0);
    my $rows = $self->{db}->dbh->selectall_arrayref(
        'SELECT group_id FROM member_group_members WHERE member_id = ? ORDER BY group_id',
        { Slice => {} },
        $member_id
    );
    $member->{group_ids} = [ map { int($_->{group_id}) } @{$rows} ];
}

sub _replace_member_groups {
    my ($self, $member_id, $group_ids) = @_;
    my $dbh = $self->{db}->dbh;
    $dbh->do('DELETE FROM member_group_members WHERE member_id = ?', undef, int($member_id));
    my %seen;
    for my $group_id (@{$group_ids || []}) {
        $group_id = int($group_id || 0);
        next unless $group_id && !$seen{$group_id}++ && $self->group_by_id($group_id);
        $dbh->do(
            'INSERT OR IGNORE INTO member_group_members (member_id, group_id, created_at) VALUES (?, ?, ?)',
            undef,
            int($member_id),
            $group_id,
            now()
        );
    }
}

sub _media_exists {
    my ($self, $id) = @_;
    my ($exists) = $self->{db}->dbh->selectrow_array(
        'SELECT id FROM media_assets WHERE id = ? AND deleted_at IS NULL',
        undef,
        int($id)
    );
    return $exists ? 1 : 0;
}

sub _password_hash {
    my ($password) = @_;
    die "password must be at least 10 characters" unless defined($password) && length($password) >= 10;
    return DesertCMS::Password::hash_password($password);
}

sub _group_ids {
    my ($value) = @_;
    my @raw = ref $value eq 'ARRAY' ? @{$value} : split /,/, ($value || '');
    my %seen;
    return grep { $_ > 0 && !$seen{$_}++ } map { int($_ || 0) } @raw;
}

sub _member_status {
    my ($status) = @_;
    $status = lc(_clean_text($status, 20));
    return $MEMBER_STATUS{$status} ? $status : 'active';
}

sub _resource_status {
    my ($status) = @_;
    $status = lc(_clean_text($status, 20));
    return $RESOURCE_STATUS{$status} ? $status : 'draft';
}

sub _resource_access {
    my ($access) = @_;
    $access = lc(_clean_text($access, 20));
    return $RESOURCE_ACCESS{$access} ? $access : 'members';
}

sub _clean_text {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/^\s+|\s+\z//g;
    $value =~ s/[ \t]+/ /g;
    $max ||= 255;
    return substr($value, 0, $max);
}

sub _email {
    my ($value) = @_;
    $value = lc(_clean_text($value, 254));
    $value =~ s/\s+//g;
    return $value;
}

sub _valid_email {
    my ($email) = @_;
    return defined($email) && $email =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/ ? 1 : 0;
}

sub _limit {
    my ($value, $default, $min, $max) = @_;
    $value = $default unless defined $value && "$value" =~ /\A[0-9]+\z/;
    $value = int($value);
    $value = $min if $value < $min;
    $value = $max if $value > $max;
    return $value;
}

1;
