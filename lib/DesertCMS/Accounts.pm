package DesertCMS::Accounts;

use strict;
use warnings;
use Digest::SHA qw(sha256);
use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Tiny;
use IPC::Open3;
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(decode_base64 encode_base64);
use Symbol qw(gensym);
use DesertCMS::Password;
use DesertCMS::Util qw(now random_hex sha256_hexstr hmac_sha256_hex constant_time_eq slugify);

my %STATUS = map { $_ => 1 } qw(active pending disabled moderated);
my $GOOGLE_AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
my $GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
my $GOOGLE_USERINFO_URL = 'https://openidconnect.googleapis.com/v1/userinfo';
my $GOOGLE_JWKS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
my $OAUTH_SCOPE = 'openid email profile';
my $OIDC_CLOCK_SKEW = 300;

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config     => $args{config},
        db         => $args{db},
        jwks_cache => {},
    }, $class;
}

sub create_account {
    my ($self, %args) = @_;
    my $email = _email($args{email});
    die "account email is invalid" unless _valid_email($email);
    my $username = _username($args{username} || _username_from_email($email));
    my $display = _clean_text($args{display_name} || $username, 140);
    my $password = $args{password};
    die "password must be at least 10 characters" unless defined($password) && length($password) >= 10;
    my $status = _status($args{status} || 'active');
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $id;
    eval {
        $dbh->do(
            q{
                INSERT INTO user_accounts
                    (email, username, display_name, password_hash, status, profile_json, moderation_note, created_at, updated_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $email,
            $username,
            $display,
            DesertCMS::Password::hash_password($password),
            $status,
            _json($args{profile} || {}),
            _clean_text($args{moderation_note}, 500),
            $ts,
            $ts
        );
        $id = int($dbh->sqlite_last_insert_rowid);
        1;
    } or do {
        my $err = $@ || 'account create failed';
        die "account email or username is already in use" if $err =~ /unique/i;
        die $err;
    };
    return $self->account_by_id($id);
}

sub account_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    my $row = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM user_accounts WHERE id = ?',
        undef,
        int($id)
    );
    _inflate_account($row) if $row;
    return $row;
}

sub account_by_email {
    my ($self, $email) = @_;
    $email = _email($email);
    return undef unless length $email;
    my $row = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM user_accounts WHERE lower(email) = ?',
        undef,
        $email
    );
    _inflate_account($row) if $row;
    return $row;
}

sub account_by_login {
    my ($self, $login) = @_;
    $login = lc _clean_text($login, 190);
    return undef unless length $login;
    my $row = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM user_accounts
            WHERE lower(email) = ? OR lower(username) = ?
            LIMIT 1
        },
        undef,
        $login,
        $login
    );
    _inflate_account($row) if $row;
    return $row;
}

sub list_accounts {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 250, 1, 1000);
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT a.*,
                   GROUP_CONCAT(g.name, ', ') AS group_names,
                   COUNT(DISTINCT i.id) AS identity_count
            FROM user_accounts a
            LEFT JOIN user_group_members gm ON gm.account_id = a.id
            LEFT JOIN user_groups g ON g.id = gm.group_id
            LEFT JOIN user_identities i ON i.account_id = a.id
            GROUP BY a.id
            ORDER BY CASE a.status WHEN 'active' THEN 0 WHEN 'pending' THEN 1 WHEN 'moderated' THEN 2 ELSE 3 END,
                     a.created_at DESC,
                     lower(a.email)
            LIMIT ?
        },
        { Slice => {} },
        $limit
    );
    _inflate_account($_) for @{$rows};
    return $rows;
}

sub authenticate {
    my ($self, %args) = @_;
    my $login = _clean_text($args{login} || $args{email}, 190);
    my $ip_address = _clean_text($args{ip_address}, 120);
    if ($self->login_throttled(scope => 'local', subject => lc($login), ip_address => $ip_address)) {
        $self->record_login_attempt(scope => 'local', subject => lc($login), ip_address => $ip_address, success => 0, reason => 'throttled');
        $self->record_audit_event(
            event_type => 'account.login_failed',
            ip_address => $ip_address,
            user_agent => $args{user_agent},
            details    => { reason => 'throttled', login => $login },
        );
        return (undef, 'throttled');
    }

    my $account = $self->account_by_login($login);
    my $reason;
    $reason = 'invalid' unless $account;
    $reason = 'disabled' if $account && ($account->{status} || '') eq 'disabled';
    $reason = 'moderated' if $account && ($account->{status} || '') eq 'moderated';
    $reason = 'pending' if $account && !$reason && ($account->{status} || '') ne 'active';
    $reason = 'invalid'
        if $account && !$reason && !DesertCMS::Password::verify_password($args{password} || '', $account->{password_hash});
    if ($reason) {
        $self->record_login_attempt(scope => 'local', subject => lc($login), ip_address => $ip_address, success => 0, reason => $reason);
        $self->record_audit_event(
            account_id => $account ? $account->{id} : undef,
            event_type => 'account.login_failed',
            ip_address => $ip_address,
            user_agent => $args{user_agent},
            details    => { reason => $reason, login => $login },
        );
        return (undef, $reason);
    }

    my $ts = now();
    $self->{db}->dbh->do(
        'UPDATE user_accounts SET last_login_at = ?, updated_at = ? WHERE id = ?',
        undef,
        $ts,
        $ts,
        $account->{id}
    );
    $self->record_login_attempt(scope => 'local', subject => lc($login), ip_address => $ip_address, success => 1, reason => 'success');
    $self->record_audit_event(
        account_id => $account->{id},
        event_type => 'account.login',
        ip_address => $ip_address,
        user_agent => $args{user_agent},
    );
    return ($self->account_by_id($account->{id}), undef);
}

sub create_session {
    my ($self, %args) = @_;
    my $account = $args{account} || $self->account_by_id($args{account_id});
    die "account is required" unless $account && int($account->{id} || 0) > 0;
    die "account is not active" unless ($account->{status} || '') eq 'active';
    my $token = random_hex(32);
    my $ts = now();
    my $ttl = int($self->{config}->get('account_session_ttl_seconds') || 30 * 24 * 60 * 60);
    my $expires = $ts + $ttl;
    $self->{db}->dbh->do(
        q{
            INSERT INTO user_account_sessions
                (account_id, token_hash, ip_address, user_agent, created_at, expires_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        int($account->{id}),
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
            SELECT s.id AS session_id, s.account_id, s.created_at AS session_created_at,
                   s.expires_at, s.last_seen_at, a.*
            FROM user_account_sessions s
            JOIN user_accounts a ON a.id = s.account_id
            WHERE s.token_hash = ?
              AND s.revoked_at IS NULL
              AND s.expires_at > ?
              AND a.status = 'active'
        },
        undef,
        sha256_hexstr(lc $token),
        $ts
    );
    if ($row) {
        $self->{db}->dbh->do('UPDATE user_account_sessions SET last_seen_at = ? WHERE id = ?', undef, $ts, $row->{session_id});
        _inflate_account($row);
    }
    return $row;
}

sub revoke_session {
    my ($self, $token, %args) = @_;
    return 0 unless defined $token && $token =~ /\A[0-9a-fA-F]{64}\z/;
    my $hash = sha256_hexstr(lc $token);
    my $session = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT id, account_id, ip_address, user_agent
            FROM user_account_sessions
            WHERE token_hash = ?
              AND revoked_at IS NULL
            LIMIT 1
        },
        undef,
        $hash
    );
    return 0 unless $session;
    my $ts = now();
    $self->{db}->dbh->do(
        'UPDATE user_account_sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL',
        undef,
        $ts,
        int($session->{id} || 0)
    );
    $self->record_audit_event(
        account_id => int($session->{account_id} || 0),
        event_type => 'account.logout',
        ip_address => exists($args{ip_address}) ? $args{ip_address} : ($session->{ip_address} || ''),
        user_agent => exists($args{user_agent}) ? $args{user_agent} : ($session->{user_agent} || ''),
        details    => { session_id => int($session->{id} || 0) },
    );
    return 1;
}

sub create_password_reset_token_for_email {
    my ($self, %args) = @_;
    my $email = _email($args{email});
    return undef unless _valid_email($email);
    my $ip_address = _clean_text($args{ip_address}, 120);
    my $user_agent = _clean_text($args{user_agent}, 500);
    my $account = $self->account_by_email($email);
    return undef unless $account;
    if (($account->{status} || '') ne 'active') {
        $self->record_audit_event(
            account_id => $account->{id},
            event_type => 'account.password_reset_rejected',
            ip_address => $ip_address,
            user_agent => $user_agent,
            details    => { reason => $account->{status} || 'inactive' },
        );
        return undef;
    }
    my $max = _positive_int($args{max_requests} || $self->{config}->get('account_password_reset_max_requests') || 3, 3);
    my $window = _positive_int($args{lockout_seconds} || $self->{config}->get('account_password_reset_lockout_seconds') || 3600, 3600);
    if ($self->login_throttled(scope => 'password_reset', subject => $email, ip_address => $ip_address, max_failures => $max, lockout_seconds => $window)) {
        $self->record_audit_event(
            account_id => $account->{id},
            event_type => 'account.password_reset_rejected',
            ip_address => $ip_address,
            user_agent => $user_agent,
            details    => { reason => 'throttled' },
        );
        return undef;
    }

    my $token = random_hex(32);
    my $ts = now();
    my $expires = $ts + int($args{ttl_seconds} || $self->{config}->get('account_password_reset_ttl_seconds') || 60 * 60);
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        "UPDATE user_account_password_reset_tokens SET status = 'revoked' WHERE account_id = ? AND status = 'pending'",
        undef,
        $account->{id}
    );
    $dbh->do(
        q{
            INSERT INTO user_account_password_reset_tokens
                (account_id, email, token_hash, status, created_at, expires_at, ip_address)
            VALUES
                (?, ?, ?, 'pending', ?, ?, ?)
        },
        undef,
        $account->{id},
        $email,
        sha256_hexstr($token),
        $ts,
        $expires,
        $ip_address
    );
    $self->record_login_attempt(scope => 'password_reset', subject => $email, ip_address => $ip_address, success => 0, reason => 'requested');
    $self->record_audit_event(
        account_id => $account->{id},
        event_type => 'account.password_reset_requested',
        ip_address => $ip_address,
        user_agent => $user_agent,
        details    => { email => $email, expires_at => $expires },
    );
    return {
        token      => $token,
        email      => $email,
        account_id => $account->{id},
        username   => $account->{username},
        expires_at => $expires,
    };
}

sub password_reset_from_token {
    my ($self, $token) = @_;
    $token = lc($token || '');
    return undef unless $token =~ /\A[0-9a-f]{64}\z/;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT r.*, a.email AS account_email, a.username, a.display_name
            FROM user_account_password_reset_tokens r
            JOIN user_accounts a ON a.id = r.account_id
            WHERE r.token_hash = ?
              AND r.status = 'pending'
              AND r.expires_at > ?
              AND a.status = 'active'
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
    my $account_id;
    my $email = '';
    $dbh->begin_work;
    eval {
        my $reset = $self->password_reset_from_token($token) or die "reset token is invalid or expired";
        $account_id = int($reset->{account_id});
        $email = $reset->{email} || $reset->{account_email} || '';
        my $changed = $dbh->do(
            q{
                UPDATE user_accounts
                SET password_hash = ?, updated_at = ?
                WHERE id = ? AND status = 'active'
            },
            undef,
            DesertCMS::Password::hash_password($password),
            $ts,
            $account_id
        );
        die "reset token is invalid or expired" unless defined($changed) && $changed > 0;
        $changed = $dbh->do(
            "UPDATE user_account_password_reset_tokens SET status = 'used', used_at = ? WHERE id = ? AND status = 'pending'",
            undef,
            $ts,
            int($reset->{id})
        );
        die "reset token is invalid or expired" unless defined($changed) && $changed > 0;
        $dbh->do(
            "UPDATE user_account_password_reset_tokens SET status = 'revoked' WHERE account_id = ? AND status = 'pending'",
            undef,
            $account_id
        );
        $dbh->do(
            'UPDATE user_account_sessions SET revoked_at = ? WHERE account_id = ? AND revoked_at IS NULL',
            undef,
            $ts,
            $account_id
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'password reset failed';
        eval { $dbh->rollback };
        die $err;
    };
    $self->record_login_attempt(scope => 'password_reset', subject => $email, ip_address => $args{ip_address}, success => 1, reason => 'used');
    $self->record_audit_event(
        account_id => $account_id,
        event_type => 'account.password_reset_used',
        ip_address => $args{ip_address},
        user_agent => $args{user_agent},
    );
    return $self->account_by_id($account_id);
}

sub csrf_token {
    my ($self, $session_token) = @_;
    return hmac_sha256_hex('account:' . ($session_token || ''), $self->{config}->app_secret);
}

sub verify_csrf {
    my ($self, $session_token, $submitted) = @_;
    return 0 unless defined $submitted;
    return constant_time_eq($self->csrf_token($session_token), $submitted);
}

sub login_throttled {
    my ($self, %args) = @_;
    my $scope = _clean_text($args{scope} || 'local', 80);
    my $subject_hash = _attempt_subject_hash($self, $scope, $args{subject});
    my $ip_hash = _attempt_ip_hash($self, $args{ip_address});
    my $max = _positive_int(
        $args{max_failures}
            || $self->{config}->get('account_login_max_failures')
            || $self->{config}->get('login_max_failures')
            || 5,
        5
    );
    return 0 if $max <= 0;
    my $window = _positive_int(
        $args{lockout_seconds}
            || $self->{config}->get('account_login_lockout_seconds')
            || $self->{config}->get('login_lockout_seconds')
            || 900,
        900
    );
    my @clauses;
    my @bind = ($scope, now() - $window);
    if (length $subject_hash) {
        push @clauses, 'subject_hash = ?';
        push @bind, $subject_hash;
    }
    if (length $ip_hash) {
        push @clauses, 'ip_hash = ?';
        push @bind, $ip_hash;
    }
    return 0 unless @clauses;
    my ($count) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM user_account_login_attempts WHERE scope = ? AND success = 0 AND created_at >= ? AND (' . join(' OR ', @clauses) . ')',
        undef,
        @bind
    );
    return int($count || 0) >= $max ? 1 : 0;
}

sub record_login_attempt {
    my ($self, %args) = @_;
    my $scope = _clean_text($args{scope} || 'local', 80);
    my $subject_hash = _attempt_subject_hash($self, $scope, $args{subject});
    my $ip_hash = _attempt_ip_hash($self, $args{ip_address});
    return 0 unless length($subject_hash) || length($ip_hash);
    $self->{db}->dbh->do(
        q{
            INSERT INTO user_account_login_attempts
                (scope, subject_hash, ip_hash, success, reason, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        },
        undef,
        $scope,
        $subject_hash,
        $ip_hash,
        $args{success} ? 1 : 0,
        _clean_text($args{reason}, 120),
        now()
    );
    return 1;
}

sub record_audit_event {
    my ($self, %args) = @_;
    my $event_type = _clean_text($args{event_type}, 120);
    die "account audit event type is required" unless length $event_type;
    $self->{db}->dbh->do(
        q{
            INSERT INTO user_account_audit_events
                (account_id, actor_account_id, actor_user_id, event_type, provider, ip_address, user_agent, details_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        _optional_id($args{account_id}),
        _optional_id($args{actor_account_id}),
        _optional_id($args{actor_user_id} || $args{admin_user_id}),
        $event_type,
        _provider_or_blank($args{provider}),
        _clean_text($args{ip_address}, 120),
        _clean_text($args{user_agent}, 500),
        _json($args{details} || {}),
        now()
    );
    return 1;
}

sub audit_events {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 100, 1, 1000);
    my @where;
    my @bind;
    if (int($args{account_id} || 0) > 0) {
        push @where, 'account_id = ?';
        push @bind, int($args{account_id});
    }
    if (length($args{event_type} || '')) {
        push @where, 'event_type = ?';
        push @bind, _clean_text($args{event_type}, 120);
    }
    my $sql = 'SELECT * FROM user_account_audit_events';
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY created_at DESC, id DESC LIMIT ?';
    push @bind, $limit;
    my $rows = $self->{db}->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    $_->{details} = _decode($_->{details_json}) for @{$rows};
    return $rows;
}

sub set_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || $args{account_id} || 0);
    die "account id is required" unless $id > 0;
    my $status = _status($args{status});
    my %actor = $self->_status_actor(%args);
    my $ts = now();
    $self->{db}->dbh->do(
        'UPDATE user_accounts SET status = ?, moderation_note = ?, updated_at = ? WHERE id = ?',
        undef,
        $status,
        _clean_text($args{moderation_note}, 500),
        $ts,
        $id
    );
    if ($status ne 'active') {
        $self->{db}->dbh->do(
            'UPDATE user_account_sessions SET revoked_at = ? WHERE account_id = ? AND revoked_at IS NULL',
            undef,
            $ts,
            $id
        );
    }
    $self->record_audit_event(
        account_id       => $id,
        actor_account_id => $actor{actor_account_id},
        actor_user_id    => $actor{actor_user_id},
        event_type       => 'account.moderation',
        details          => _moderation_details(
            status          => $status,
            moderation_note => _clean_text($args{moderation_note}, 500),
            system_action   => $actor{system_action},
        ),
    );
    return $self->account_by_id($id);
}

sub save_profile {
    my ($self, %args) = @_;
    my $id = int($args{id} || $args{account_id} || 0);
    die "account id is required" unless $id > 0;
    my $account = $self->account_by_id($id) or die "account was not found";
    my $display = _clean_text($args{display_name} || $account->{display_name}, 140);
    my $username = _username($args{username} || $account->{username});
    my $profile = $args{profile} || $account->{profile} || {};
    my $ts = now();
    eval {
        $self->{db}->dbh->do(
            q{
                UPDATE user_accounts
                SET username = ?, display_name = ?, profile_json = ?, updated_at = ?
                WHERE id = ?
            },
            undef,
            $username,
            $display,
            _json($profile),
            $ts,
            $id
        );
        1;
    } or do {
        my $err = $@ || 'profile save failed';
        die "account username is already in use" if $err =~ /unique/i;
        die $err;
    };
    return $self->account_by_id($id);
}

sub upsert_identity {
    my ($self, %args) = @_;
    my $provider = _provider($args{provider});
    my $subject = _clean_text($args{provider_subject}, 190);
    die "identity subject is required" unless length $subject;
    my $email = _email($args{email});
    my $target_account = $args{account} || $self->account_by_id($args{account_id});
    my $existing_identity = $self->identity($provider, $subject);
    if ($target_account && $existing_identity && int($existing_identity->{account_id} || 0) != int($target_account->{id} || 0)) {
        die "SSO identity is already linked to another account";
    }
    if ($target_account && _valid_email($email)) {
        my $email_owner = $self->account_by_email($email);
        if ($email_owner && int($email_owner->{id} || 0) != int($target_account->{id} || 0)) {
            die "SSO email is already associated with another account";
        }
    }
    my $account = $target_account
        || ($existing_identity ? $self->account_by_id($existing_identity->{account_id}) : undef)
        || $self->account_by_email($email);
    if ($account && ($account->{status} || '') ne 'active') {
        die "SSO identity cannot be linked to a " . ($account->{status} || 'inactive') . " account";
    }
    if (!$account) {
        die "identity email is invalid" unless _valid_email($email);
        my $password = $args{password};
        $password = random_hex(32) if (!defined($password) || length($password) < 10) && $args{allow_passwordless};
        die "account password is required for new SSO identity" unless defined($password) && length($password) >= 10;
        my $username = $args{allow_passwordless}
            ? $self->_available_username($args{username} || _username_from_email($email))
            : $args{username};
        $account = $self->create_account(
            email        => $email,
            username     => $username,
            display_name => $args{display_name},
            password     => $password,
            status       => $args{status} || 'active',
            profile      => $args{profile} || {},
        );
    }
    my $new_identity = $existing_identity ? 0 : 1;
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO user_identities
                (account_id, provider, provider_subject, email, profile_json, created_at, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, provider_subject) DO UPDATE SET
                account_id = excluded.account_id,
                email = excluded.email,
                profile_json = excluded.profile_json,
                updated_at = excluded.updated_at
        },
        undef,
        int($account->{id}),
        $provider,
        $subject,
        $email,
        _json($args{profile} || {}),
        $ts,
        $ts
    );
    if ($new_identity && !$args{suppress_link_audit}) {
        $self->record_audit_event(
            account_id       => int($account->{id}),
            actor_account_id => _optional_id($args{actor_account_id}),
            event_type       => 'account.identity_linked',
            provider         => $provider,
            ip_address       => $args{ip_address},
            user_agent       => $args{user_agent},
            details          => {
                provider_subject => $subject,
                email            => $email,
                link_mode        => _clean_text($args{link_mode} || 'direct_upsert', 80),
            },
        );
    }
    return $self->identity($provider, $subject);
}

sub linked_identities {
    my ($self, $account_id) = @_;
    return [] unless int($account_id || 0) > 0;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM user_identities
            WHERE account_id = ?
            ORDER BY provider, updated_at DESC, id DESC
        },
        { Slice => {} },
        int($account_id)
    );
    $_->{profile} = _decode($_->{profile_json}) for @{$rows};
    return $rows;
}

sub unlink_identity {
    my ($self, %args) = @_;
    my $account_id = int($args{account_id} || 0);
    die "account id is required" unless $account_id > 0;
    my $account = $self->account_by_id($account_id) or die "account was not found";
    die "account is not active" unless ($account->{status} || '') eq 'active';
    my %actor = $self->_identity_unlink_actor(%args, account_id => $account_id);
    my $provider = _oauth_provider($args{provider});
    my $subject = _clean_text($args{provider_subject}, 190);
    die "identity subject is required" unless length $subject;
    my $identity = $self->identity($provider, $subject) or die "SSO identity was not found";
    die "SSO identity does not belong to this account"
        unless int($identity->{account_id} || 0) == $account_id;
    my $changed = $self->{db}->dbh->do(
        'DELETE FROM user_identities WHERE account_id = ? AND provider = ? AND provider_subject = ?',
        undef,
        $account_id,
        $provider,
        $subject
    );
    $self->record_audit_event(
        account_id       => $account_id,
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        event_type       => 'account.identity_unlinked',
        provider         => $provider,
        ip_address       => $args{ip_address},
        user_agent       => $args{user_agent},
        details          => { provider_subject => $subject, email => $identity->{email} || '' },
    );
    return $changed || 0;
}

sub _identity_unlink_actor {
    my ($self, %args) = @_;
    my $account_id = int($args{account_id} || 0);
    my $actor_account_id = int($args{actor_account_id} || 0);
    if ($actor_account_id > 0) {
        my $actor = $self->account_by_id($actor_account_id) or die "identity unlink actor account was not found";
        die "identity unlink actor account is not active" unless ($actor->{status} || '') eq 'active';
        die "identity unlink actor cannot modify this account"
            unless $actor_account_id == $account_id || $self->_is_moderator($actor_account_id);
        return (actor_account_id => $actor_account_id);
    }
    my $actor_user_id = int($args{actor_user_id} || $args{admin_user_id} || 0);
    if ($actor_user_id > 0) {
        die "identity unlink admin user is not active" unless $self->_admin_user_active($actor_user_id);
        return (actor_user_id => $actor_user_id);
    }
    die "identity unlink actor account or active admin user is required";
}

sub oauth_start {
    my ($self, %args) = @_;
    my $provider = _oauth_provider($args{provider});
    my $settings = $args{settings} || {};
    _oauth_provider_enabled($provider, $settings);
    my $redirect_uri = _require_https_url($args{redirect_uri}, 'OAuth redirect URI');
    my $ip_address = _clean_text($args{ip_address}, 120);
    my $account_id = int($args{account_id} || 0);
    if ($account_id > 0) {
        my $account = $self->account_by_id($account_id) or die "account was not found";
        die "account is not active" unless ($account->{status} || '') eq 'active';
    } else {
        $account_id = undef;
    }
    if ($self->login_throttled(scope => "sso:$provider", ip_address => $ip_address)) {
        $self->_record_sso_failure(
            provider   => $provider,
            account_id => $account_id,
            ip_address => $ip_address,
            user_agent => $args{user_agent},
            error      => 'Too many SSO attempts. Try again later.',
        );
        die "Too many SSO attempts. Try again later.";
    }
    my $metadata = $self->oauth_provider_metadata(provider => $provider, settings => $settings, http => $args{http});
    my ($client_id) = _oauth_client_config($provider, $settings);
    my $state = random_hex(24);
    my $nonce = random_hex(16);
    my $code_verifier = random_hex(32);
    my $expires_at = now() + 600;
    $self->_delete_expired_oauth_states;
    $self->{db}->dbh->do(
        q{
            INSERT INTO user_account_oauth_states
                (provider, account_id, state_hash, code_verifier, nonce_hash, redirect_path, ip_address, created_at, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $provider,
        $account_id,
        $self->_oauth_state_hash($state),
        $code_verifier,
        $self->_oauth_nonce_hash($nonce),
        _safe_redirect_path($args{redirect_path}),
        $ip_address,
        now(),
        $expires_at
    );

    my %params = (
        response_type         => 'code',
        client_id             => $client_id,
        redirect_uri          => $redirect_uri,
        scope                 => $OAUTH_SCOPE,
        state                 => $state,
        nonce                 => $nonce,
        code_challenge        => _base64url(sha256($code_verifier)),
        code_challenge_method => 'S256',
    );
    $params{access_type} = 'offline' if $provider eq 'google';
    return {
        provider          => $provider,
        authorization_url => $metadata->{authorization_endpoint} . '?' . _query_string(\%params),
        state             => $state,
        expires_at        => $expires_at,
    };
}

sub oauth_complete {
    my ($self, %args) = @_;
    my $provider = _oauth_provider($args{provider});
    my $settings = $args{settings} || {};
    my $state = _clean_text($args{state}, 200);
    my $code = _clean_text($args{code}, 4000);
    my $ip_address = _clean_text($args{ip_address}, 120);
    my $failure_subject = '';
    my $state_row;
    my $result = eval {
        _oauth_provider_enabled($provider, $settings);
        die "OAuth state is missing" unless length $state;
        die "OAuth authorization code is missing" unless length $code;
        my $redirect_uri = _require_https_url($args{redirect_uri}, 'OAuth redirect URI');
        die "Too many SSO attempts. Try again later."
            if $self->login_throttled(scope => "sso:$provider", ip_address => $ip_address);
        $state_row = $self->_consume_oauth_state($provider, $state);
        $ip_address = _clean_text($args{ip_address} || $state_row->{ip_address}, 120);
        $failure_subject = int($state_row->{account_id} || 0) > 0 ? 'account:' . int($state_row->{account_id}) : '';
        die "Too many SSO attempts. Try again later."
            if $self->login_throttled(scope => "sso:$provider", subject => $failure_subject, ip_address => $ip_address);
        my $metadata = $self->oauth_provider_metadata(provider => $provider, settings => $settings, http => $args{http});
        my ($client_id, $client_secret) = _oauth_client_config($provider, $settings);
        my $http = $args{http} || HTTP::Tiny->new(timeout => 20, verify_SSL => 1);
        my $token_response = $http->post_form($metadata->{token_endpoint}, {
            grant_type    => 'authorization_code',
            code          => $code,
            client_id     => $client_id,
            client_secret => $client_secret,
            redirect_uri  => $redirect_uri,
            code_verifier => $state_row->{code_verifier},
        });
        my $token = _decode_http_json($token_response, 'OAuth token exchange failed');
        die "OAuth provider did not return an access token" unless length($token->{access_token} || '');
        die "OAuth provider did not return an ID token" unless length($token->{id_token} || '');
        my $claims = $self->_validate_id_token(
            provider    => $provider,
            metadata    => $metadata,
            settings    => $settings,
            state_row   => $state_row,
            token       => $token->{id_token},
            verifier    => $args{id_token_verifier},
            http        => $http,
            client_id   => $client_id,
        );

        my $userinfo = {};
        my $userinfo_response = $http->get($metadata->{userinfo_endpoint}, {
            headers => {
                Authorization => 'Bearer ' . $token->{access_token},
                Accept        => 'application/json',
            },
        });
        $userinfo = _decode_http_json($userinfo_response, 'OAuth userinfo fetch failed')
            if $userinfo_response && $userinfo_response->{success};
        die "OAuth userinfo subject did not match ID token"
            if length($userinfo->{sub} || '') && ($userinfo->{sub} || '') ne ($claims->{sub} || '');
        my %profile_claims = (%{$userinfo || {}}, %{$claims || {}});
        my $subject = _clean_text($claims->{sub}, 190);
        die "OAuth provider did not return a subject" unless length $subject;
        $failure_subject = $subject;
        my $email = _email($claims->{email});
        $failure_subject = $email if length $email;
        die "OAuth provider did not return an email address" unless _valid_email($email);
        die "OAuth provider returned an unverified email address"
            unless exists($claims->{email_verified}) && _truthy_claim($claims->{email_verified});
        _validate_allowed_domain($email, $settings);
        my $display_name = _display_name_from_claims(\%profile_claims, $email);
        my $link_account_id = int($state_row->{account_id} || 0);
        my $existing_identity = $self->identity($provider, $subject);
        my $email_account = (!$link_account_id && !$existing_identity) ? $self->account_by_email($email) : undef;
        my $link_mode = $link_account_id
            ? 'explicit_profile_link'
            : ($existing_identity ? 'existing_identity' : ($email_account ? 'email_merge' : 'new_account'));
        my $identity = $self->upsert_identity(
            provider           => $provider,
            provider_subject   => $subject,
            account_id         => $link_account_id || undef,
            email              => $email,
            username           => $profile_claims{preferred_username} || _username_from_email($email),
            display_name       => $display_name,
            profile            => {
                provider => $provider,
                name     => $display_name,
                issuer   => _clean_text($claims->{iss}, 500),
                picture  => _clean_text($profile_claims{picture}, 500),
                locale   => _clean_text($profile_claims{locale}, 40),
            },
            allow_passwordless => 1,
            suppress_link_audit => 1,
        );
        my $account = $self->account_by_id($identity->{account_id});
        if (!$link_account_id) {
            my $login_ts = now();
            $self->{db}->dbh->do(
                'UPDATE user_accounts SET last_login_at = ?, updated_at = ? WHERE id = ?',
                undef,
                $login_ts,
                $login_ts,
                $account->{id}
            );
            $account = $self->account_by_id($account->{id});
        }
        $self->record_login_attempt(
            scope      => "sso:$provider",
            subject    => $email || $subject,
            ip_address => $ip_address,
            success    => 1,
            reason     => $link_account_id ? 'linked' : $link_mode,
        );
        my %audit_details = (
            provider_subject => $subject,
            issuer           => _clean_text($claims->{iss}, 500),
            email            => $email,
            link_mode        => $link_mode,
        );
        my %audit_actor = $link_account_id ? (actor_account_id => $link_account_id) : ();
        $self->record_audit_event(
            account_id => $account->{id},
            %audit_actor,
            event_type => 'account.identity_linked',
            provider   => $provider,
            ip_address => $ip_address,
            user_agent => $args{user_agent},
            details    => \%audit_details,
        ) unless $existing_identity;
        $self->record_audit_event(
            account_id => $account->{id},
            event_type => 'account.sso_login',
            provider   => $provider,
            ip_address => $ip_address,
            user_agent => $args{user_agent},
            details    => \%audit_details,
        ) unless $link_account_id;
        return {
            provider      => $provider,
            account       => $account,
            identity      => $identity,
            redirect_path => $state_row->{redirect_path} || '/account',
            linked        => $link_account_id ? 1 : 0,
        };
    };
    if (!$result) {
        my $error = $@ || 'SSO sign-in failed';
        $self->_record_sso_failure(
            provider   => $provider,
            account_id => $state_row ? $state_row->{account_id} : undef,
            subject    => $failure_subject,
            ip_address => $ip_address,
            user_agent => $args{user_agent},
            error      => $error,
        );
        die $error;
    }
    return $result;
}

sub _record_sso_failure {
    my ($self, %args) = @_;
    my $provider = _provider_or_blank($args{provider}) || 'sso';
    my $error = _clean_text($args{error}, 500);
    $self->record_login_attempt(
        scope      => "sso:$provider",
        subject    => $args{subject},
        ip_address => $args{ip_address},
        success    => 0,
        reason     => $error,
    );
    $self->record_audit_event(
        account_id => $args{account_id},
        event_type => 'account.sso_failed',
        provider   => $provider,
        ip_address => $args{ip_address},
        user_agent => $args{user_agent},
        details    => { error => $error },
    );
    return 1;
}

sub record_sso_failure {
    my ($self, %args) = @_;
    return $self->_record_sso_failure(%args);
}

sub oauth_provider_metadata {
    my ($self, %args) = @_;
    my $provider = _oauth_provider($args{provider});
    my $settings = $args{settings} || {};
    _oauth_client_config($provider, $settings);
    if ($provider eq 'google') {
        return {
            authorization_endpoint => $GOOGLE_AUTH_URL,
            token_endpoint         => $GOOGLE_TOKEN_URL,
            userinfo_endpoint      => $GOOGLE_USERINFO_URL,
            jwks_uri               => $GOOGLE_JWKS_URL,
            issuer                 => 'https://accounts.google.com',
            issuer_aliases         => [ 'accounts.google.com' ],
        };
    }
    my $discovery_url = _require_https_url($settings->{accounts_oidc_discovery_url}, 'OIDC discovery URL');
    my $http = $args{http} || HTTP::Tiny->new(timeout => 20, verify_SSL => 1);
    my $response = $http->get($discovery_url, { headers => { Accept => 'application/json' } });
    my $metadata = _decode_http_json($response, 'OIDC discovery failed');
    for my $field (qw(authorization_endpoint token_endpoint userinfo_endpoint jwks_uri)) {
        $metadata->{$field} = _require_https_url($metadata->{$field}, "OIDC $field");
    }
    $metadata->{issuer} = _require_https_issuer_url($metadata->{issuer}, 'OIDC issuer');
    return {
        authorization_endpoint => $metadata->{authorization_endpoint},
        token_endpoint         => $metadata->{token_endpoint},
        userinfo_endpoint      => $metadata->{userinfo_endpoint},
        jwks_uri               => $metadata->{jwks_uri},
        issuer                 => $metadata->{issuer},
    };
}

sub normalize_allowed_domains {
    my ($raw) = @_;
    return join ', ', _allowed_domain_list($raw);
}

sub oauth_provider_readiness {
    my (%args) = @_;
    my $provider = _oauth_provider($args{provider});
    my $settings = $args{settings} || {};
    my $label = $provider eq 'google' ? 'Google' : 'OIDC';
    my $enabled_key = $provider eq 'google' ? 'accounts_google_enabled' : 'accounts_oidc_enabled';
    my $enabled = _setting_truthy($settings->{$enabled_key}) ? 1 : 0;
    my @issues;
    my ($client_id, $client_secret, $discovery_url);
    if ($provider eq 'google') {
        $client_id = _clean_text($settings->{accounts_google_client_id}, 300);
        $client_secret = _clean_text($settings->{accounts_google_client_secret}, 500);
    } else {
        $discovery_url = _clean_text($settings->{accounts_oidc_discovery_url}, 1000);
        $client_id = _clean_text($settings->{accounts_oidc_client_id}, 300);
        $client_secret = _clean_text($settings->{accounts_oidc_client_secret}, 500);
    }

    my $callback_url = _clean_text($args{redirect_uri}, 1000);
    if ($enabled) {
        push @issues, "$label client ID is required" unless length $client_id;
        push @issues, "$label client secret is required" unless length $client_secret;
        _collect_validation_issue(\@issues, sub { _require_https_url($callback_url, 'OAuth redirect URI') });
        if ($provider eq 'oidc') {
            _collect_validation_issue(\@issues, sub { _require_https_url($discovery_url, 'OIDC discovery URL') });
        }
    }
    _collect_validation_issue(\@issues, sub { normalize_allowed_domains($settings->{accounts_allowed_domains}) });

    my $ready = $enabled && !@issues ? 1 : 0;
    my $state = !$enabled ? 'neutral' : ($ready ? 'ok' : 'warn');
    my $status = !$enabled ? 'Disabled' : ($ready ? 'Ready' : 'Needs setup');
    my $summary = !$enabled
        ? "$label sign-in is disabled and will not appear on public account pages."
        : ($ready
            ? "$label sign-in has credentials and HTTPS callback validation."
            : "$label sign-in has " . scalar(@issues) . " readiness issue(s).");
    return {
        provider          => $provider,
        label             => $label,
        enabled           => $enabled,
        ready             => $ready,
        state             => $state,
        status            => $status,
        summary           => $summary,
        callback_url      => $callback_url,
        discovery_url     => $discovery_url || '',
        client_id_present => length($client_id || '') ? 1 : 0,
        secret_present    => length($client_secret || '') ? 1 : 0,
        issues            => \@issues,
    };
}

sub _validate_id_token {
    my ($self, %args) = @_;
    my $token = _clean_text($args{token}, 12000);
    die "ID token is missing" unless length $token;
    my ($header, $claims, $signing_input, $signature) = _decode_jwt($token);
    die "ID token algorithm is not supported" unless ($header->{alg} || '') eq 'RS256';

    my $metadata = $args{metadata} || {};
    my $issuer = _clean_text($metadata->{issuer}, 500);
    my @issuer_aliases = grep { length } map { _clean_text($_, 500) } @{ $metadata->{issuer_aliases} || [] };
    die "ID token issuer is missing" unless length($claims->{iss} || '');
    die "ID token issuer is not trusted"
        unless ($claims->{iss} || '') eq $issuer || grep { ($claims->{iss} || '') eq $_ } @issuer_aliases;

    my $client_id = _clean_text($args{client_id}, 300);
    die "ID token audience is not trusted" unless _audience_contains($claims->{aud}, $client_id);
    die "ID token authorized party is not trusted"
        if defined($claims->{azp}) && length($claims->{azp} || '') && ($claims->{azp} || '') ne $client_id;
    if (ref($claims->{aud}) eq 'ARRAY' && @{$claims->{aud}} > 1) {
        die "ID token authorized party is not trusted"
            unless length($claims->{azp} || '') && ($claims->{azp} || '') eq $client_id;
    }

    my $now = now();
    die "ID token expiration is missing" unless defined $claims->{exp};
    die "ID token expiration is invalid"
        unless !ref($claims->{exp}) && "$claims->{exp}" =~ /\A[0-9]+\z/;
    die "ID token has expired" if int($claims->{exp}) < $now - $OIDC_CLOCK_SKEW;
    if (defined $claims->{nbf}) {
        die "ID token not-before value is invalid"
            unless !ref($claims->{nbf}) && "$claims->{nbf}" =~ /\A[0-9]+\z/;
        die "ID token not-before value is invalid" if int($claims->{nbf}) > $now + $OIDC_CLOCK_SKEW;
    }
    if (defined $claims->{iat}) {
        die "ID token issued-at value is invalid"
            unless !ref($claims->{iat}) && "$claims->{iat}" =~ /\A[0-9]+\z/;
        die "ID token issued-at value is invalid" if int($claims->{iat}) > $now + $OIDC_CLOCK_SKEW;
    }

    my $state_row = $args{state_row} || {};
    my $nonce = _clean_text($claims->{nonce}, 200);
    die "ID token nonce is missing" unless length $nonce;
    die "ID token nonce did not match OAuth state"
        unless length($state_row->{nonce_hash} || '') && constant_time_eq($self->_oauth_nonce_hash($nonce), $state_row->{nonce_hash});

    my $jwks = $self->_jwks_for_metadata($metadata, http => $args{http});
    my $verified = eval {
        $self->_verify_id_token_signature(
            token         => $token,
            header        => $header,
            signing_input => $signing_input,
            signature     => $signature,
            jwks          => $jwks,
            verifier      => $args{verifier},
        );
        1;
    };
    if (!$verified) {
        my $error = $@ || 'ID token signature could not be verified';
        die $error unless $error =~ /signing key was not found/;
        $jwks = $self->_jwks_for_metadata($metadata, http => $args{http}, refresh => 1);
        $self->_verify_id_token_signature(
            token         => $token,
            header        => $header,
            signing_input => $signing_input,
            signature     => $signature,
            jwks          => $jwks,
            verifier      => $args{verifier},
        );
    }

    return $claims;
}

sub _jwks_for_metadata {
    my ($self, $metadata, %args) = @_;
    my $jwks_uri = _require_https_url($metadata->{jwks_uri}, 'OIDC JWKS URL');
    my $cache = $self->{jwks_cache}{$jwks_uri};
    return $cache->{jwks} if !$args{refresh} && $cache && int($cache->{expires_at} || 0) > now();

    my $http = $args{http} || HTTP::Tiny->new(timeout => 20, verify_SSL => 1);
    my $response = $http->get($jwks_uri, { headers => { Accept => 'application/json' } });
    my $jwks = _decode_http_json($response, 'OIDC JWKS fetch failed');
    die "OIDC JWKS did not include keys" unless ref($jwks->{keys}) eq 'ARRAY' && @{$jwks->{keys}};
    $self->{jwks_cache}{$jwks_uri} = {
        jwks       => $jwks,
        expires_at => now() + _cache_max_age($response->{headers}),
    };
    return $jwks;
}

sub _verify_id_token_signature {
    my ($self, %args) = @_;
    my $header = $args{header} || {};
    my $jwks = $args{jwks} || {};
    my $kid = _clean_text($header->{kid}, 300);
    my ($jwk) = grep {
        (!$kid || ($_->{kid} || '') eq $kid)
            && ($_->{kty} || '') eq 'RSA'
            && (!length($_->{alg} || '') || ($_->{alg} || '') eq 'RS256')
            && (!length($_->{use} || '') || ($_->{use} || '') eq 'sig')
    } @{ $jwks->{keys} || [] };
    die "ID token signing key was not found" unless $jwk;
    if ($args{verifier}) {
        my $ok = $args{verifier}->(
            token         => $args{token},
            header        => $header,
            jwk           => $jwk,
            signing_input => $args{signing_input},
            signature     => $args{signature},
        );
        die "ID token signature was invalid" unless $ok;
        return 1;
    }
    return _verify_rs256_with_openssl(
        jwk           => $jwk,
        signing_input => $args{signing_input},
        signature     => $args{signature},
    );
}

sub identity {
    my ($self, $provider, $subject) = @_;
    $provider = _provider($provider);
    $subject = _clean_text($subject, 190);
    return undef unless length $provider && length $subject;
    my $row = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT i.*, a.email AS account_email, a.username AS account_username, a.display_name AS account_display_name
            FROM user_identities i
            JOIN user_accounts a ON a.id = i.account_id
            WHERE i.provider = ? AND i.provider_subject = ?
        },
        undef,
        $provider,
        $subject
    );
    $row->{profile} = _decode($row->{profile_json}) if $row;
    return $row;
}

sub _consume_oauth_state {
    my ($self, $provider, $state) = @_;
    my $hash = $self->_oauth_state_hash($state);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $row = $dbh->selectrow_hashref(
        q{
            SELECT *
            FROM user_account_oauth_states
            WHERE provider = ? AND state_hash = ?
            LIMIT 1
        },
        undef,
        $provider,
        $hash
    );
    die "OAuth state was not found" unless $row;
    die "OAuth state has already been used" if defined $row->{consumed_at};
    die "OAuth state has expired" if int($row->{expires_at} || 0) < $ts;
    my $changed = $dbh->do(
        'UPDATE user_account_oauth_states SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL',
        undef,
        $ts,
        int($row->{id})
    );
    die "OAuth state has already been used" unless defined($changed) && $changed > 0;
    return $row;
}

sub _delete_expired_oauth_states {
    my ($self) = @_;
    $self->{db}->dbh->do(
        'DELETE FROM user_account_oauth_states WHERE expires_at < ? OR (consumed_at IS NOT NULL AND consumed_at < ?)',
        undef,
        now() - 60,
        now() - 86400
    );
}

sub _oauth_state_hash {
    my ($self, $state) = @_;
    return hmac_sha256_hex('account-oauth-state:' . ($state || ''), $self->{config}->app_secret);
}

sub _oauth_nonce_hash {
    my ($self, $nonce) = @_;
    return hmac_sha256_hex('account-oauth-nonce:' . ($nonce || ''), $self->{config}->app_secret);
}

sub groups {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT g.*, COUNT(m.account_id) AS account_count
            FROM user_groups g
            LEFT JOIN user_group_members m ON m.group_id = g.id
            GROUP BY g.id
            ORDER BY lower(g.name), g.id
        },
        { Slice => {} }
    );
}

sub save_group {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $name = _clean_text($args{name}, 120);
    die "group name is required" unless length $name;
    my $slug = slugify($args{slug} || $name);
    my $description = _clean_text($args{description}, 500);
    my $ts = now();
    if ($id) {
        $self->{db}->dbh->do(
            'UPDATE user_groups SET name = ?, slug = ?, description = ?, updated_at = ? WHERE id = ?',
            undef,
            $name,
            $slug,
            $description,
            $ts,
            $id
        );
    } else {
        $self->{db}->dbh->do(
            'INSERT INTO user_groups (name, slug, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
            undef,
            $name,
            $slug,
            $description,
            $ts,
            $ts
        );
        $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    }
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM user_groups WHERE id = ?', undef, $id);
}

sub set_group_member {
    my ($self, %args) = @_;
    my $group_id = int($args{group_id} || 0);
    my $account_id = int($args{account_id} || 0);
    die "group and account are required" unless $group_id > 0 && $account_id > 0;
    my $role = ($args{role} || 'member') =~ /\A(?:member|moderator|owner)\z/ ? $args{role} : 'member';
    $self->{db}->dbh->do(
        q{
            INSERT INTO user_group_members (group_id, account_id, role, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(group_id, account_id) DO UPDATE SET role = excluded.role
        },
        undef,
        $group_id,
        $account_id,
        $role,
        now()
    );
    return 1;
}

sub groups_for_account {
    my ($self, $account_id) = @_;
    return [] unless int($account_id || 0) > 0;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT g.*, gm.role AS account_role
            FROM user_group_members gm
            JOIN user_groups g ON g.id = gm.group_id
            WHERE gm.account_id = ?
            ORDER BY lower(g.name), g.id
        },
        { Slice => {} },
        int($account_id)
    );
}

sub attach_cart {
    my ($self, %args) = @_;
    my $account_id = int($args{account_id} || 0);
    my $cart_id = int($args{cart_id} || 0);
    die "account id is required" unless $account_id > 0;
    if ($cart_id > 0) {
        $self->{db}->dbh->do(
            'UPDATE shop_carts SET account_id = ?, updated_at = ? WHERE id = ?',
            undef,
            $account_id,
            now(),
            $cart_id
        );
        return $cart_id;
    }
    my $token = $args{session_token};
    return 0 unless defined $token && length $token;
    my $changed = $self->{db}->dbh->do(
        q{
            UPDATE shop_carts
            SET account_id = ?, updated_at = ?
            WHERE session_token_hash = ? AND account_id IS NULL AND status = 'open'
        },
        undef,
        $account_id,
        now(),
        sha256_hexstr(lc $token)
    );
    return $changed || 0;
}

sub _available_username {
    my ($self, $base) = @_;
    $base = _username($base);
    my $dbh = $self->{db}->dbh;
    for my $suffix ('', 2 .. 50) {
        my $candidate = $suffix eq '' ? $base : $base . '-' . $suffix;
        my ($exists) = $dbh->selectrow_array(
            'SELECT 1 FROM user_accounts WHERE lower(username) = ? LIMIT 1',
            undef,
            lc $candidate
        );
        return $candidate unless $exists;
    }
    return _username($base . '-' . random_hex(3));
}

sub _inflate_account {
    my ($row) = @_;
    return unless $row;
    $row->{profile} = _decode($row->{profile_json});
}

sub _email {
    my ($value) = @_;
    $value = lc _clean_text($value, 190);
    return $value;
}

sub _valid_email {
    my ($value) = @_;
    return defined($value) && $value =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/;
}

sub _username {
    my ($value) = @_;
    $value = lc _clean_text($value, 80);
    $value =~ s/[^a-z0-9_.-]+/-/g;
    $value =~ s/\A[-_.]+//;
    $value =~ s/[-_.]+\z//;
    return length($value) ? $value : 'account';
}

sub _username_from_email {
    my ($email) = @_;
    my ($local) = split /\@/, $email || '', 2;
    return $local || 'account';
}

sub _provider {
    my ($value) = @_;
    $value = lc _clean_text($value, 80);
    $value =~ s/[^a-z0-9_.-]+/-/g;
    return length($value) ? $value : 'oidc';
}

sub _status {
    my ($value) = @_;
    $value = lc($value || 'active');
    return $STATUS{$value} ? $value : 'active';
}

sub _status_actor {
    my ($self, %args) = @_;
    my $actor_account_id = int($args{actor_account_id} || 0);
    if ($actor_account_id > 0) {
        my $actor = $self->account_by_id($actor_account_id) or die "account moderation actor was not found";
        die "account moderation actor is not active" unless ($actor->{status} || '') eq 'active';
        die "account moderation actor permission required" unless $self->_is_moderator($actor_account_id);
        return (actor_account_id => $actor_account_id);
    }
    my $actor_user_id = int($args{actor_user_id} || $args{admin_user_id} || 0);
    if ($actor_user_id > 0) {
        die "account moderation admin user is not active" unless $self->_admin_user_active($actor_user_id);
        return (actor_user_id => $actor_user_id);
    }
    my $system_action = _system_status_action($args{system_action});
    return (system_action => $system_action) if length $system_action;
    die "account moderation actor account, active admin user, or system action is required";
}

sub _admin_user_active {
    my ($self, $user_id) = @_;
    return 0 unless int($user_id || 0) > 0;
    my ($active) = $self->{db}->dbh->selectrow_array(
        'SELECT 1 FROM admin_users WHERE id = ? AND disabled_at IS NULL',
        undef,
        int($user_id)
    );
    return $active ? 1 : 0;
}

sub _is_moderator {
    my ($self, $account_id) = @_;
    return 0 unless int($account_id || 0) > 0;
    my ($has_role) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT 1
            FROM user_group_members
            WHERE account_id = ?
              AND role IN ('moderator', 'owner')
            LIMIT 1
        },
        undef,
        int($account_id)
    );
    return $has_role ? 1 : 0;
}

sub _system_status_action {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/[^a-z0-9_]+/_/g;
    return '' unless length $value;
    return $value if $value =~ /\Aaccount_(?:test_setup|migration|sso_conflict_fixture|system_moderation)\z/;
    die "account moderation system action is invalid";
}

sub _moderation_details {
    my (%details) = @_;
    delete $details{system_action} unless length($details{system_action} || '');
    return \%details;
}

sub _clean_text {
    my ($value, $limit) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/\A\s+|\s+\z//g;
    if ($limit && length($value) > $limit) {
        $value = substr($value, 0, $limit);
    }
    return $value;
}

sub _limit {
    my ($value, $default, $min, $max) = @_;
    $value = $default unless defined $value && $value =~ /\A[0-9]+\z/;
    $value = int($value);
    $value = $min if $value < $min;
    $value = $max if $value > $max;
    return $value;
}

sub _oauth_provider {
    my ($value) = @_;
    $value = _provider($value);
    die "OAuth provider is not supported" unless $value eq 'google' || $value eq 'oidc';
    return $value;
}

sub _oauth_provider_enabled {
    my ($provider, $settings) = @_;
    $settings ||= {};
    my $key = $provider eq 'google' ? 'accounts_google_enabled' : 'accounts_oidc_enabled';
    die (($provider eq 'google' ? 'Google OAuth' : 'OIDC') . ' provider is disabled')
        unless _setting_truthy($settings->{$key});
    return 1;
}

sub _oauth_client_config {
    my ($provider, $settings) = @_;
    $settings ||= {};
    my ($client_id, $client_secret);
    if ($provider eq 'google') {
        $client_id = _clean_text($settings->{accounts_google_client_id}, 300);
        $client_secret = _clean_text($settings->{accounts_google_client_secret}, 500);
        die "Google OAuth client ID is required" unless length $client_id;
        die "Google OAuth client secret is required" unless length $client_secret;
        return ($client_id, $client_secret);
    }
    $client_id = _clean_text($settings->{accounts_oidc_client_id}, 300);
    $client_secret = _clean_text($settings->{accounts_oidc_client_secret}, 500);
    die "OIDC client ID is required" unless length $client_id;
    die "OIDC client secret is required" unless length $client_secret;
    return ($client_id, $client_secret);
}

sub _validate_allowed_domain {
    my ($email, $settings) = @_;
    $settings ||= {};
    my @allowed = _allowed_domain_list($settings->{accounts_allowed_domains});
    return 1 unless @allowed;
    my ($domain) = $email =~ /\@([^@]+)\z/;
    $domain = lc($domain || '');
    for my $allowed (@allowed) {
        return 1 if $domain eq $allowed;
        if ($allowed =~ /\A\*\.(.+)\z/) {
            my $base = $1;
            return 1 if $domain eq $base || $domain =~ /\.\Q$base\E\z/;
        }
    }
    die "SSO email domain is not allowed";
}

sub _allowed_domain_list {
    my ($raw) = @_;
    $raw = _clean_text($raw, 1000);
    return () unless length $raw;
    my @allowed;
    my %seen;
    for my $part (split /[\s,;]+/, $raw) {
        my $domain = lc _clean_text($part, 255);
        $domain =~ s/\A@//;
        $domain =~ s/\.\z//;
        next unless length $domain;
        die "Allowed email domain '$domain' is invalid" unless _valid_allowed_domain($domain);
        next if $seen{$domain}++;
        push @allowed, $domain;
    }
    return @allowed;
}

sub _valid_allowed_domain {
    my ($domain) = @_;
    return 0 unless length($domain || '');
    $domain =~ s/\A\*\.//;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/ ? 1 : 0;
}

sub _collect_validation_issue {
    my ($issues, $code) = @_;
    my $ok = eval { $code->(); 1 };
    return 1 if $ok;
    my $message = $@ || 'validation failed';
    $message =~ s/\s+\z//;
    push @{$issues}, $message;
    return 0;
}

sub _require_https_url {
    my ($value, $label) = @_;
    $value = _clean_text($value, 1000);
    die "$label is required" unless length $value;
    die "$label must use https" unless $value =~ m{\Ahttps://[^/\s?#]+(?:[/?#][^\s]*)?\z}i;
    die "$label must not include a fragment" if $value =~ /#/;
    my ($authority) = $value =~ m{\Ahttps://([^/\s?#]+)}i;
    die "$label must not include userinfo" if defined($authority) && $authority =~ /\@/;
    return $value;
}

sub _require_https_issuer_url {
    my ($value, $label) = @_;
    my $url = _require_https_url($value, $label);
    die "$label must not include a query" if $url =~ /\?/;
    return $url;
}

sub _safe_redirect_path {
    my ($value) = @_;
    $value = _clean_text($value, 500);
    return '/account' unless length $value;
    return '/account' unless $value =~ m{\A/[^\r\n]*\z} && $value !~ m{\A//};
    return $value;
}

sub _query_string {
    my ($params) = @_;
    return join '&', map {
        _uri_escape($_) . '=' . _uri_escape($params->{$_})
    } sort grep { defined $params->{$_} } keys %{$params || {}};
}

sub _uri_escape {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/eg;
    return $value;
}

sub _base64url {
    my ($bytes) = @_;
    my $encoded = encode_base64($bytes, '');
    $encoded =~ tr{+/}{-_};
    $encoded =~ s/=+\z//;
    return $encoded;
}

sub _base64url_decode {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ tr{-_}{+/};
    my $pad = length($value) % 4;
    $value .= '=' x (4 - $pad) if $pad;
    return decode_base64($value);
}

sub _decode_jwt {
    my ($token) = @_;
    my @parts = split /\./, $token;
    die "ID token format is invalid" unless @parts == 3 && length($parts[0]) && length($parts[1]) && length($parts[2]);
    my $header = eval { decode_json(_base64url_decode($parts[0])) };
    die "ID token header is invalid" unless $header && ref($header) eq 'HASH';
    my $claims = eval { decode_json(_base64url_decode($parts[1])) };
    die "ID token claims are invalid" unless $claims && ref($claims) eq 'HASH';
    return ($header, $claims, $parts[0] . '.' . $parts[1], _base64url_decode($parts[2]));
}

sub _audience_contains {
    my ($audience, $client_id) = @_;
    return 0 unless length($client_id || '');
    return ($audience || '') eq $client_id unless ref($audience);
    return 0 unless ref($audience) eq 'ARRAY';
    for my $aud (@{$audience}) {
        return 1 if defined($aud) && $aud eq $client_id;
    }
    return 0;
}

sub _cache_max_age {
    my ($headers) = @_;
    return 3600 unless $headers && ref($headers) eq 'HASH';
    my $cache_control = $headers->{'cache-control'} || $headers->{'Cache-Control'} || '';
    return int($1) if $cache_control =~ /max-age=([0-9]+)/i;
    return 3600;
}

sub _positive_int {
    my ($value, $default) = @_;
    return $default unless defined($value) && "$value" =~ /\A[0-9]+\z/;
    return int($value);
}

sub _optional_id {
    my ($value) = @_;
    return undef unless int($value || 0) > 0;
    return int($value);
}

sub _provider_or_blank {
    my ($value) = @_;
    return '' unless defined $value && length $value;
    return _provider($value);
}

sub _attempt_subject_hash {
    my ($self, $scope, $subject) = @_;
    $subject = lc _clean_text($subject, 300);
    return '' unless length $subject;
    return hmac_sha256_hex('account-login-subject:' . $scope . ':' . $subject, $self->{config}->app_secret);
}

sub _attempt_ip_hash {
    my ($self, $ip_address) = @_;
    $ip_address = _clean_text($ip_address, 120);
    return '' unless length $ip_address;
    return hmac_sha256_hex('account-login-ip:' . $ip_address, $self->{config}->app_secret);
}

sub _setting_truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if !ref($value) && $value =~ /\A(?:0|false|no|off)\z/i;
    return length("$value") ? 1 : 0;
}

sub _verify_rs256_with_openssl {
    my (%args) = @_;
    my $jwk = $args{jwk} || {};
    my $openssl = $ENV{DESERTCMS_OPENSSL} || 'openssl';
    my $tmp = tempdir(CLEANUP => 1);
    my $cert_path = File::Spec->catfile($tmp, 'oidc-cert.pem');
    my $pubkey_path = File::Spec->catfile($tmp, 'oidc-pubkey.pem');
    my $input_path = File::Spec->catfile($tmp, 'oidc-signing-input.txt');
    my $signature_path = File::Spec->catfile($tmp, 'oidc-signature.bin');

    my $x5c = $jwk->{x5c};
    if (ref($x5c) eq 'ARRAY' && length($x5c->[0] || '')) {
        _write_file($cert_path, _pem_certificate($x5c->[0]));
        my ($pub_status, $pub_stdout, $pub_stderr) = _run_capture($openssl, 'x509', '-in', $cert_path, '-pubkey', '-noout');
        die "ID token signing certificate could not be parsed: $pub_stderr" unless $pub_status == 0 && length $pub_stdout;
        _write_file($pubkey_path, $pub_stdout);
    } else {
        _write_file($pubkey_path, _pem_public_key_from_rsa_jwk($jwk));
    }
    _write_file($input_path, $args{signing_input});
    _write_file($signature_path, $args{signature}, raw => 1);

    my ($verify_status, $verify_stdout, $verify_stderr) = _run_capture(
        $openssl,
        'dgst',
        '-sha256',
        '-verify',
        $pubkey_path,
        '-signature',
        $signature_path,
        $input_path
    );
    die "ID token signature was invalid: " . ($verify_stderr || $verify_stdout || 'openssl verification failed')
        unless $verify_status == 0 && $verify_stdout =~ /Verified OK/i;
    return 1;
}

sub _pem_public_key_from_rsa_jwk {
    my ($jwk) = @_;
    my $n = _base64url_decode($jwk->{n});
    my $e = _base64url_decode($jwk->{e});
    die "ID token signing key does not include RSA modulus and exponent"
        unless length($n || '') && length($e || '');

    my $rsa_public_key = _asn1_tlv(
        0x30,
        _asn1_integer($n) . _asn1_integer($e)
    );
    my $algorithm = _asn1_tlv(
        0x30,
        _asn1_tlv(0x06, pack('C*', 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01))
            . _asn1_tlv(0x05, '')
    );
    my $subject_public_key = _asn1_tlv(0x03, "\x00" . $rsa_public_key);
    my $der = _asn1_tlv(0x30, $algorithm . $subject_public_key);
    my $body = encode_base64($der, '');
    $body =~ s/(.{1,64})/$1\n/g;
    return "-----BEGIN PUBLIC KEY-----\n$body-----END PUBLIC KEY-----\n";
}

sub _asn1_integer {
    my ($bytes) = @_;
    $bytes =~ s/\A\x00+//;
    $bytes = "\x00" unless length $bytes;
    $bytes = "\x00" . $bytes if (ord(substr($bytes, 0, 1)) & 0x80);
    return _asn1_tlv(0x02, $bytes);
}

sub _asn1_tlv {
    my ($tag, $value) = @_;
    $value = '' unless defined $value;
    return pack('C', $tag) . _asn1_length(length($value)) . $value;
}

sub _asn1_length {
    my ($len) = @_;
    return pack('C', $len) if $len < 0x80;
    my $bytes = '';
    while ($len > 0) {
        $bytes = pack('C', $len & 0xff) . $bytes;
        $len >>= 8;
    }
    return pack('C', 0x80 | length($bytes)) . $bytes;
}

sub _pem_certificate {
    my ($body) = @_;
    $body =~ s/\s+//g;
    $body =~ s/(.{1,64})/$1\n/g;
    return "-----BEGIN CERTIFICATE-----\n$body-----END CERTIFICATE-----\n";
}

sub _write_file {
    my ($path, $content, %args) = @_;
    open my $fh, '>' . ($args{raw} ? ':raw' : ''), $path or die "cannot write $path: $!";
    print {$fh} defined($content) ? $content : '';
    close $fh or die "cannot close $path: $!";
}

sub _run_capture {
    my (@cmd) = @_;
    my $in = gensym;
    my $out;
    my $err = gensym;
    my $pid = eval { open3($in, $out, $err, @cmd) };
    die "cannot run $cmd[0]: $@" unless $pid;
    close $in;
    local $/;
    my $stdout = <$out>;
    my $stderr = <$err>;
    waitpid($pid, 0);
    my $status = $? >> 8;
    return ($status, $stdout || '', $stderr || '');
}

sub _decode_http_json {
    my ($response, $context) = @_;
    $context ||= 'OAuth request failed';
    die "$context: no response" unless $response && ref($response) eq 'HASH';
    if (!$response->{success}) {
        my $status = int($response->{status} || 0);
        my $reason = _clean_text($response->{reason} || $response->{content} || '', 300);
        die length($reason) ? "$context: $status $reason" : "$context: HTTP $status";
    }
    my $json = eval { decode_json($response->{content} || '{}') };
    die "$context: response was not JSON" unless $json && ref($json) eq 'HASH';
    if (length($json->{error} || '')) {
        my $error = _clean_text($json->{error_description} || $json->{error}, 300);
        die "$context: $error";
    }
    return $json;
}

sub _truthy_claim {
    my ($value) = @_;
    return 0 unless defined $value;
    return "$value" eq '1' ? 1 : 0 if ref($value);
    return $value =~ /\A(?:true|1)\z/i ? 1 : 0;
}

sub _display_name_from_claims {
    my ($claims, $email) = @_;
    return _clean_text($claims->{name}, 140) if length($claims->{name} || '');
    return _clean_text($claims->{preferred_username}, 140) if length($claims->{preferred_username} || '');
    return _username_from_email($email);
}

sub _json {
    my ($value) = @_;
    $value ||= {};
    return encode_json($value);
}

sub _decode {
    my ($value) = @_;
    my $decoded = eval { decode_json($value || '{}') };
    return $decoded && ref($decoded) eq 'HASH' ? $decoded : {};
}

1;
