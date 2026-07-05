package DesertCMS::Auth;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use DesertCMS::Governance;
use DesertCMS::Password;
use DesertCMS::Util qw(now random_hex sha256_hexstr hmac_sha256_hex constant_time_eq);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub create_admin {
    my ($self, %args) = @_;
    my $username = _normalize_username($args{username});
    my $email = _normalize_email($args{email});
    my $password = $args{password};
    my $role = DesertCMS::Governance::normalize_role($args{role}, DesertCMS::Governance::scope($self->{config}));
    die "username is required" unless length $username;
    die "email is invalid" if length $email && !_valid_email($email);
    die "password is required" unless defined $password && length $password >= 12;

    my $ts = now();
    my $hash = DesertCMS::Password::hash_password($password);

    my $dbh = $self->{db}->dbh;
    my ($active_admins) = $dbh->selectrow_array('SELECT COUNT(*) FROM admin_users WHERE disabled_at IS NULL');
    die "an active CMS admin already exists; use Governance to add scoped users or reset-admin for recovery"
        if ($active_admins || 0) > 0;

    $dbh->do(
        q{
            INSERT INTO admin_users
                (username, email, role, password_hash, password_algo, created_at, updated_at, force_password_change)
            VALUES
                (?, ?, ?, ?, 'pbkdf2-sha256', ?, ?, ?)
        },
        undef,
        $username,
        $email,
        $role,
        $hash,
        $ts,
        $ts,
        $args{force_password_change} ? 1 : 0
    );

    my $id = $dbh->sqlite_last_insert_rowid;
    $self->_audit(
        action => 'admin_user.created',
        subject_type => 'admin_user',
        subject_id => $id,
        details => { username => $username, role => $role },
    );

    return $id;
}

sub grant_admin_access {
    my ($self, %args) = @_;
    my $username = _normalize_username($args{username});
    my $email = _normalize_email($args{email});
    my $password = $args{password};
    my $role = DesertCMS::Governance::normalize_role($args{role}, DesertCMS::Governance::scope($self->{config}));
    die "username must be 3 to 64 letters, numbers, dots, underscores, or hyphens"
        unless $username =~ /\A[a-z0-9][a-z0-9._-]{2,63}\z/;
    die "email is invalid" unless _valid_email($email);
    die "password must be at least 12 characters" unless defined $password && length $password >= 12;

    my $hash = DesertCMS::Password::hash_password($password);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $id;

    $dbh->begin_work;
    eval {
        my $existing = $dbh->selectrow_hashref(
            'SELECT id FROM admin_users WHERE email = ? OR username = ? ORDER BY CASE WHEN disabled_at IS NULL THEN 0 ELSE 1 END ASC, id ASC LIMIT 1',
            undef,
            $email,
            $username
        );
        if ($existing) {
            $id = $existing->{id};
            $dbh->do(
                q{
                    UPDATE admin_users
                    SET username = ?,
                        email = ?,
                        role = ?,
                        password_hash = ?,
                        password_algo = 'pbkdf2-sha256',
                        updated_at = ?,
                        force_password_change = 1,
                        disabled_at = NULL
                    WHERE id = ?
                },
                undef,
                $username,
                $email,
                $role,
                $hash,
                $ts,
                $id
            );
        } else {
            $dbh->do(
                q{
                    INSERT INTO admin_users
                        (username, email, role, password_hash, password_algo, created_at, updated_at, force_password_change)
                    VALUES
                        (?, ?, ?, ?, 'pbkdf2-sha256', ?, ?, 1)
                },
                undef,
                $username,
                $email,
                $role,
                $hash,
                $ts,
                $ts
            );
            $id = $dbh->sqlite_last_insert_rowid;
        }
        $self->_audit(
            actor_user_id => $args{actor_user_id},
            action        => 'admin_user.access_granted',
            subject_type  => 'admin_user',
            subject_id    => $id,
            details       => { username => $username, email => $email, role => $role },
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown access grant failure';
        eval { $dbh->rollback };
        die "username is already in use" if $err =~ /unique/i;
        die $err;
    };

    return $id;
}

sub list_admin_users {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT id, username, email, role, created_at, updated_at, force_password_change, disabled_at
            FROM admin_users
            ORDER BY CASE WHEN disabled_at IS NULL THEN 0 ELSE 1 END,
                     lower(username),
                     id
        },
        { Slice => {} }
    );
}

sub disable_admin_user {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $actor_user_id = int($args{actor_user_id} || 0) || undef;
    die "user is required" unless $id > 0;
    die "you cannot disable your own account" if $actor_user_id && $actor_user_id == $id;

    my $dbh = $self->{db}->dbh;
    my $ts = now();
    my $row = $dbh->selectrow_hashref('SELECT * FROM admin_users WHERE id = ?', undef, $id)
        or die "admin user not found";
    return 1 if defined $row->{disabled_at};

    my $scope = DesertCMS::Governance::scope($self->{config});
    my $role = DesertCMS::Governance::normalize_role($row->{role}, $scope);
    if ($role eq 'owner') {
        my ($owners) = $dbh->selectrow_array(
            q{
                SELECT COUNT(*)
                FROM admin_users
                WHERE disabled_at IS NULL
                  AND COALESCE(role, 'owner') = 'owner'
            }
        );
        die "at least one active owner is required" if int($owners || 0) <= 1;
    }

    $dbh->begin_work;
    eval {
        $dbh->do(
            'UPDATE admin_users SET disabled_at = ?, updated_at = ? WHERE id = ? AND disabled_at IS NULL',
            undef,
            $ts,
            $ts,
            $id
        );
        $dbh->do(
            'UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL',
            undef,
            $ts,
            $id
        );
        $self->_audit(
            actor_user_id => $actor_user_id,
            action        => 'admin_user.disabled',
            subject_type  => 'admin_user',
            subject_id    => $id,
            details       => { username => $row->{username}, email => $row->{email}, role => $role },
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown disable user failure';
        eval { $dbh->rollback };
        die $err;
    };

    return 1;
}

sub reset_single_admin {
    my ($self, %args) = @_;
    my $username = _normalize_username($args{username});
    my $email = _normalize_email($args{email});
    my $password = $args{password};
    my $role = DesertCMS::Governance::normalize_role('owner', DesertCMS::Governance::scope($self->{config}));
    die "username must be 3 to 64 letters, numbers, dots, underscores, or hyphens"
        unless $username =~ /\A[a-z0-9][a-z0-9._-]{2,63}\z/;
    die "email is invalid" if length $email && !_valid_email($email);
    die "password must be at least 12 characters" unless defined $password && length $password >= 12;

    my $hash = DesertCMS::Password::hash_password($password);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $id;

    $dbh->begin_work;
    eval {
        $dbh->do(
            'UPDATE admin_users SET disabled_at = ?, updated_at = ? WHERE disabled_at IS NULL AND username <> ?',
            undef,
            $ts,
            $ts,
            $username
        );

        my $existing = $dbh->selectrow_hashref(
            'SELECT id FROM admin_users WHERE username = ?',
            undef,
            $username
        );

        if ($existing) {
            $id = $existing->{id};
            $dbh->do(
                q{
                    UPDATE admin_users
                    SET password_hash = ?,
                        email = ?,
                        role = ?,
                        password_algo = 'pbkdf2-sha256',
                        updated_at = ?,
                        force_password_change = 1,
                        disabled_at = NULL
                    WHERE id = ?
                },
                undef,
                $hash,
                $email,
                $role,
                $ts,
                $id
            );
        } else {
            $dbh->do(
                q{
                    INSERT INTO admin_users
                        (username, email, role, password_hash, password_algo, created_at, updated_at, force_password_change)
                    VALUES
                        (?, ?, ?, ?, 'pbkdf2-sha256', ?, ?, 1)
                },
                undef,
                $username,
                $email,
                $role,
                $hash,
                $ts,
                $ts
            );
            $id = $dbh->sqlite_last_insert_rowid;
        }

        $dbh->do(
            'UPDATE sessions SET revoked_at = ? WHERE revoked_at IS NULL',
            undef,
            $ts
        );

        $self->_audit(
            action       => 'admin_user.recovery_owner_reset',
            subject_type => 'admin_user',
            subject_id   => $id,
        details      => { username => $username },
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown admin reset failure';
        eval { $dbh->rollback };
        die $err;
    };

    return $id;
}

sub update_admin_credentials {
    my ($self, %args) = @_;
    my $user_id = int($args{user_id} || 0);
    my $username = _normalize_username($args{username});
    my $email = _normalize_email($args{email});
    my $password = $args{password};
    die "user is required" unless $user_id > 0;
    die "username must be 3 to 64 letters, numbers, dots, underscores, or hyphens"
        unless $username =~ /\A[a-z0-9][a-z0-9._-]{2,63}\z/;
    die "email is invalid" if length $email && !_valid_email($email);
    die "password must be at least 12 characters" unless defined $password && length $password >= 12;

    my $hash = DesertCMS::Password::hash_password($password);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $ok = eval {
        $dbh->do(
            q{
                UPDATE admin_users
                SET username = ?,
                    email = ?,
                    password_hash = ?,
                    password_algo = 'pbkdf2-sha256',
                    updated_at = ?,
                    force_password_change = 0
                WHERE id = ?
                  AND disabled_at IS NULL
            },
            undef,
            $username,
            $email,
            $hash,
            $ts,
            $user_id
        );
        1;
    };
    if (!$ok) {
        my $err = $@ || 'unknown credential update failure';
        die "username is already in use" if $err =~ /unique/i;
        die $err;
    }

    $self->_audit(
        actor_user_id => $user_id,
        action        => 'admin_user.credentials_updated',
        subject_type  => 'admin_user',
        subject_id    => $user_id,
        details       => { username => $username },
    );
    return 1;
}

sub update_admin_account {
    my ($self, %args) = @_;
    my $user_id = int($args{user_id} || 0);
    my $username = _normalize_username($args{username});
    my $email = _normalize_email($args{email});
    my $password = $args{password};
    die "user is required" unless $user_id > 0;
    die "username must be 3 to 64 letters, numbers, dots, underscores, or hyphens"
        unless $username =~ /\A[a-z0-9][a-z0-9._-]{2,63}\z/;
    die "email is invalid" if length $email && !_valid_email($email);
    die "password must be at least 12 characters"
        if defined $password && length $password && length $password < 12;

    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $ok = eval {
        if (defined $password && length $password) {
            my $hash = DesertCMS::Password::hash_password($password);
            $dbh->do(
                q{
                    UPDATE admin_users
                    SET username = ?,
                        email = ?,
                        password_hash = ?,
                        password_algo = 'pbkdf2-sha256',
                        updated_at = ?,
                        force_password_change = 0
                    WHERE id = ?
                      AND disabled_at IS NULL
                },
                undef,
                $username,
                $email,
                $hash,
                $ts,
                $user_id
            );
        } else {
            $dbh->do(
                q{
                    UPDATE admin_users
                    SET username = ?,
                        email = ?,
                        updated_at = ?
                    WHERE id = ?
                      AND disabled_at IS NULL
                },
                undef,
                $username,
                $email,
                $ts,
                $user_id
            );
        }
        1;
    };
    if (!$ok) {
        my $err = $@ || 'unknown account update failure';
        die "username is already in use" if $err =~ /unique/i;
        die $err;
    }

    $self->_audit(
        actor_user_id => $user_id,
        action        => 'admin_user.account_updated',
        subject_type  => 'admin_user',
        subject_id    => $user_id,
        details       => { username => $username, email_set => length($email) ? 1 : 0 },
    );
    return 1;
}

sub create_password_reset_token_for_email {
    my ($self, %args) = @_;
    my $email = _normalize_email($args{email});
    return undef unless _valid_email($email);

    my $dbh = $self->{db}->dbh;
    my $user = $dbh->selectrow_hashref(
        'SELECT * FROM admin_users WHERE lower(email) = ? AND disabled_at IS NULL ORDER BY id ASC LIMIT 1',
        undef,
        $email
    );
    return undef unless $user;

    my $token = random_hex(32);
    my $ts = now();
    my $expires = $ts + int($args{ttl_seconds} || 60 * 60);
    $dbh->do(
        "UPDATE password_reset_tokens SET status = 'revoked' WHERE user_id = ? AND status = 'pending'",
        undef,
        $user->{id}
    );
    $dbh->do(
        q{
            INSERT INTO password_reset_tokens
                (user_id, email, token_hash, status, created_at, expires_at, ip_address)
            VALUES
                (?, ?, ?, 'pending', ?, ?, ?)
        },
        undef,
        $user->{id},
        $email,
        sha256_hexstr($token),
        $ts,
        $expires,
        $args{ip_address} || ''
    );

    $self->_audit(
        actor_user_id => $user->{id},
        action        => 'admin_user.password_reset_requested',
        subject_type  => 'admin_user',
        subject_id    => $user->{id},
        ip_address    => $args{ip_address} || '',
        details       => { email => $email },
    );

    return {
        token      => $token,
        email      => $email,
        user_id    => $user->{id},
        username   => $user->{username},
        expires_at => $expires,
    };
}

sub password_reset_from_token {
    my ($self, $token) = @_;
    return undef unless defined $token && $token =~ /\A[0-9a-fA-F]{64}\z/;
    my $ts = now();
    my $row = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT r.*, u.username
            FROM password_reset_tokens r
            JOIN admin_users u ON u.id = r.user_id
            WHERE r.token_hash = ?
              AND r.status = 'pending'
              AND r.expires_at > ?
              AND u.disabled_at IS NULL
        },
        undef,
        sha256_hexstr(lc $token),
        $ts
    );
    return $row;
}

sub consume_password_reset_token {
    my ($self, %args) = @_;
    my $token = lc($args{token} || '');
    my $username = _normalize_username($args{username});
    my $password = $args{password};
    die "reset token is invalid or expired" unless $token =~ /\A[0-9a-f]{64}\z/;
    die "username must be 3 to 64 letters, numbers, dots, underscores, or hyphens"
        unless $username =~ /\A[a-z0-9][a-z0-9._-]{2,63}\z/;
    die "password must be at least 12 characters" unless defined $password && length $password >= 12;

    my $hash = DesertCMS::Password::hash_password($password);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $user_id;

    $dbh->begin_work;
    eval {
        my $reset = $dbh->selectrow_hashref(
            q{
                SELECT r.*, u.disabled_at
                FROM password_reset_tokens r
                JOIN admin_users u ON u.id = r.user_id
                WHERE r.token_hash = ?
                  AND r.status = 'pending'
                  AND r.expires_at > ?
                  AND u.disabled_at IS NULL
            },
            undef,
            sha256_hexstr($token),
            $ts
        );
        die "reset token is invalid or expired" unless $reset;
        $user_id = int($reset->{user_id});

        $dbh->do(
            q{
                UPDATE admin_users
                SET username = ?,
                    password_hash = ?,
                    password_algo = 'pbkdf2-sha256',
                    updated_at = ?,
                    force_password_change = 0
                WHERE id = ?
                  AND disabled_at IS NULL
            },
            undef,
            $username,
            $hash,
            $ts,
            $user_id
        );
        $dbh->do(
            q{
                UPDATE password_reset_tokens
                SET status = 'used',
                    used_at = ?
                WHERE id = ?
            },
            undef,
            $ts,
            $reset->{id}
        );
        $dbh->do(
            'UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL',
            undef,
            $ts,
            $user_id
        );
        $self->_audit(
            actor_user_id => $user_id,
            action        => 'admin_user.password_reset_completed',
            subject_type  => 'admin_user',
            subject_id    => $user_id,
            details       => { username => $username },
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown password reset failure';
        eval { $dbh->rollback };
        die "username is already in use" if $err =~ /unique/i;
        die $err;
    };

    return $user_id;
}

sub authenticate {
    my ($self, %args) = @_;
    my $username = _normalize_username($args{username});
    my $password = $args{password} || '';
    my $ip = $args{ip_address} || '';

    if ($self->is_login_locked(username => $username, ip_address => $ip)) {
        $self->_record_login(username => $username, ip_address => $ip, success => 0);
        return (undef, 'locked');
    }

    my $dbh = $self->{db}->dbh;
    my $user = $dbh->selectrow_hashref(
        'SELECT * FROM admin_users WHERE username = ? AND disabled_at IS NULL',
        undef,
        $username
    );

    my $ok = $user && DesertCMS::Password::verify_password($password, $user->{password_hash});
    $self->_record_login(username => $username, ip_address => $ip, success => $ok ? 1 : 0);
    $self->_audit(
        actor_user_id => $ok ? $user->{id} : undef,
        action        => $ok ? 'auth.login_success' : 'auth.login_failure',
        ip_address    => $ip,
        details       => { username => $username },
    );
    return ($user, undef) if $ok;
    return (undef, 'invalid');
}

sub create_session {
    my ($self, %args) = @_;
    my $user = $args{user} or die "user is required";
    my $token = random_hex(32);
    my $token_hash = sha256_hexstr($token);
    my $ts = now();
    my $ttl = int($self->{config}->get('session_ttl_seconds') || 7200);
    my $expires = $ts + $ttl;

    $self->{db}->dbh->do(
        q{
            INSERT INTO sessions
                (user_id, token_hash, ip_address, user_agent, created_at, expires_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $user->{id},
        $token_hash,
        $args{ip_address} || '',
        $args{user_agent} || '',
        $ts,
        $expires,
        $ts
    );

    return ($token, $expires);
}

sub session_from_token {
    my ($self, $token) = @_;
    return undef unless defined $token && $token =~ /^[0-9a-fA-F]{64}$/;

    my $token_hash = sha256_hexstr(lc $token);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $session = $dbh->selectrow_hashref(
        q{
            SELECT s.*, u.username, u.email, u.role, u.force_password_change
            FROM sessions s
            JOIN admin_users u ON u.id = s.user_id
            WHERE s.token_hash = ?
              AND s.revoked_at IS NULL
              AND s.expires_at > ?
              AND u.disabled_at IS NULL
        },
        undef,
        $token_hash,
        $ts
    );

    if ($session) {
        $dbh->do('UPDATE sessions SET last_seen_at = ? WHERE id = ?', undef, $ts, $session->{id});
    }

    return $session;
}

sub record_audit {
    my ($self, %args) = @_;
    $self->_audit(%args);
}

sub audit_rows {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 100);
    $limit = 100 if $limit < 1 || $limit > 250;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT l.*, u.username AS actor_username, u.email AS actor_email
            FROM audit_log l
            LEFT JOIN admin_users u ON u.id = l.actor_user_id
            ORDER BY l.created_at DESC, l.id DESC
            LIMIT ?
        },
        { Slice => {} },
        $limit
    );
    for my $row (@{$rows}) {
        my $details = {};
        eval {
            $details = decode_json($row->{details_json} || '{}');
            1;
        } or do {
            $details = {};
        };
        $row->{details} = $details;
    }
    return $rows;
}

sub revoke_session {
    my ($self, $token) = @_;
    return unless defined $token;
    $self->{db}->dbh->do(
        'UPDATE sessions SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL',
        undef,
        now(),
        sha256_hexstr(lc $token)
    );
}

sub csrf_token {
    my ($self, $session_token) = @_;
    return hmac_sha256_hex($session_token || '', $self->{config}->app_secret);
}

sub verify_csrf {
    my ($self, $session_token, $submitted) = @_;
    return 0 unless defined $submitted;
    return constant_time_eq($self->csrf_token($session_token), $submitted);
}

sub is_login_locked {
    my ($self, %args) = @_;
    my $username = _normalize_username($args{username});
    my $ip = $args{ip_address} || '';
    my $window = int($self->{config}->get('login_lockout_seconds') || 900);
    my $max = int($self->{config}->get('login_max_failures') || 5);
    my $since = now() - $window;

    my ($failures) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM login_attempts
            WHERE username = ?
              AND ip_address = ?
              AND attempted_at >= ?
              AND success = 0
        },
        undef,
        $username,
        $ip,
        $since
    );

    return ($failures || 0) >= $max ? 1 : 0;
}

sub cleanup_expired_sessions {
    my ($self) = @_;
    $self->{db}->dbh->do('DELETE FROM sessions WHERE expires_at <= ? OR revoked_at IS NOT NULL', undef, now());
}

sub _record_login {
    my ($self, %args) = @_;
    $self->{db}->dbh->do(
        'INSERT INTO login_attempts (username, ip_address, attempted_at, success) VALUES (?, ?, ?, ?)',
        undef,
        _normalize_username($args{username}),
        $args{ip_address} || '',
        now(),
        $args{success} ? 1 : 0
    );
}

sub _audit {
    my ($self, %args) = @_;
    $self->{db}->dbh->do(
        q{
            INSERT INTO audit_log
                (actor_user_id, action, subject_type, subject_id, ip_address, user_agent, details_json, created_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $args{actor_user_id},
        $args{action},
        $args{subject_type},
        $args{subject_id},
        $args{ip_address} || '',
        $args{user_agent} || '',
        encode_json($args{details} || {}),
        now()
    );
}

sub _normalize_username {
    my ($username) = @_;
    $username = lc($username || '');
    $username =~ s/^\s+|\s+$//g;
    return $username;
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

1;
