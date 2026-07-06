package DesertCMS::LiveStreaming;

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use DesertCMS::Util qw(now random_hex sha256_hexstr constant_time_eq slugify url_decode);

my %CHANNEL_STATUS = map { $_ => 1 } qw(offline scheduled live disabled);
my %SESSION_STATUS = map { $_ => 1 } qw(scheduled live ended failed);
my %CHAT_STATUS = map { $_ => 1 } qw(visible hidden deleted reported);
my %PRESENCE_STATUS = map { $_ => 1 } qw(present idle left);
my %REPORT_STATUS = map { $_ => 1 } qw(open reviewed dismissed actioned);
my %BLOCKED_TERM_ACTION = map { $_ => 1 } qw(report hide reject);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config        => $args{config},
        db            => $args{db},
        notifications => $args{notifications} || $args{notification_bus},
    }, $class;
}

sub worker_contract {
    my ($self) = @_;
    my $host = _clean_text($self->{config}->get('live_ingest_host'), 255)
        || _url_host($self->{config}->get('site_url'))
        || 'localhost';
    my $protocol = _ingest_protocol($self->{config}->get('live_ingest_protocol'));
    my $app = _ingest_app($self->{config}->get('live_ingest_app'));
    my $prefix = _hls_prefix($self->{config}->get('live_hls_public_prefix'));
    my $health_path = _clean_path($self->{config}->get('live_worker_health_path') || '/live/worker/health') || '/live/worker/health';
    my $endpoint = _clean_text($self->{config}->get('live_ingest_endpoint'), 500);
    $endpoint =~ s{/+\z}{};
    $endpoint ||= "$protocol://$host/$app";
    return {
        service_name => 'desertcms-stream-worker',
        runtime      => 'perl',
        obs_ingest   => {
            endpoint    => $endpoint,
            auth        => 'per-channel stream key',
            key_display => 'one-time at channel creation or rotation',
        },
        hls          => {
            public_prefix => $prefix,
            output_dir    => $self->{config}->get('live_hls_output_dir') || '/var/www/htdocs/desertcms-site/streams',
            served_by     => 'httpd',
            required_path => "$prefix/<channel>/index.m3u8",
        },
        health       => {
            method => 'GET',
            path   => $health_path,
            body   => 'json: worker_id, status, channels, sessions, generated_at',
        },
        logs         => {
            format => 'ts worker_id channel_id session_id status viewer_count hls_output_path message',
        },
        openbsd      => {
            required_base => [qw(pf httpd acme-client)],
            network_gate  => 'pf',
            hls_server    => 'httpd',
            cms_runtime   => 'perl CGI/slowcgi',
        },
        cms_scope    => 'channel/session/chat/admin state only; media ingest and HLS segmenting stay in the worker',
    };
}

sub ingest_endpoint {
    my ($self, $channel) = @_;
    $channel = $self->channel_by_id($channel) unless ref($channel) eq 'HASH';
    return '' unless $channel;
    my $base = _clean_text($self->{config}->get('live_ingest_endpoint'), 500);
    if (length $base) {
        $base =~ s{/+\z}{};
        return $base . '/' . ($channel->{slug} || 'stream');
    }
    my $host = _clean_text($self->{config}->get('live_ingest_host'), 255)
        || _url_host($self->{config}->get('site_url'))
        || 'localhost';
    my $protocol = _ingest_protocol($self->{config}->get('live_ingest_protocol'));
    my $app = _ingest_app($self->{config}->get('live_ingest_app'));
    return "$protocol://$host/$app/" . ($channel->{slug} || 'stream');
}

sub validate_hls_path {
    my ($self, $path) = @_;
    return _valid_hls_path($path, _hls_prefix($self->{config}->get('live_hls_public_prefix'))) ? 1 : 0;
}

sub create_channel {
    my ($self, %args) = @_;
    my $title = _clean_text($args{title}, 180);
    die "channel title is required" unless length $title;
    my $slug = slugify($args{slug} || $title);
    my $description = _clean_text($args{description}, 1000);
    my $account_id = int($args{account_id} || 0) || undef;
    my $status = _channel_status($args{status} || 'offline');
    my $hls_prefix = _hls_prefix($self->{config}->get('live_hls_public_prefix'));
    my $hls_path = _hls_path_or_die($args{hls_path} || "$hls_prefix/$slug/index.m3u8", $hls_prefix);
    my $chat_enabled = defined($args{chat_enabled}) ? ($args{chat_enabled} ? 1 : 0) : 1;
    my $stream_key = random_hex(24);
    my $ts = now();
    my $policy = ref($args{ingest_policy}) eq 'HASH' ? { %{ $args{ingest_policy} } } : {};
    $policy->{auth} ||= 'stream_key';
    $policy->{hls_path} = $hls_path;
    $policy->{chat_enabled} = $chat_enabled ? 1 : 0;
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        q{
            INSERT INTO live_stream_channels
                (slug, title, description, account_id, stream_key_hash, stream_key_rotated_at, ingest_policy_json, status, hls_path, chat_enabled, created_at, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $slug,
        $title,
        $description,
        $account_id,
        sha256_hexstr($stream_key),
        $ts,
        encode_json($policy),
        $status,
        $hls_path,
        $chat_enabled,
        $ts,
        $ts
    );
    my $id = int($dbh->sqlite_last_insert_rowid);
    my $channel = $self->channel_by_id($id);
    $channel->{stream_key} = $stream_key;
    $channel->{ingest_endpoint} = $self->ingest_endpoint($channel);
    return $channel;
}

sub rotate_stream_key {
    my ($self, $id) = @_;
    $id = int($id || 0);
    die "channel id is required" unless $id > 0;
    my $stream_key = random_hex(24);
    my $ts = now();
    my $rows = $self->{db}->dbh->do(
        q{
            UPDATE live_stream_channels
            SET stream_key_hash = ?, stream_key_rotated_at = ?, stream_key_revoked_at = NULL, updated_at = ?
            WHERE id = ?
        },
        undef,
        sha256_hexstr($stream_key),
        $ts,
        $ts,
        $id
    );
    die "live channel was not found" unless defined($rows) && $rows > 0;
    my $channel = $self->channel_by_id($id);
    $channel->{stream_key} = $stream_key if $channel;
    $channel->{ingest_endpoint} = $self->ingest_endpoint($channel) if $channel;
    return $channel;
}

sub revoke_stream_key {
    my ($self, $id) = @_;
    $id = int($id || 0);
    die "channel id is required" unless $id > 0;
    my $ts = now();
    my $rows = $self->{db}->dbh->do(
        q{
            UPDATE live_stream_channels
            SET stream_key_hash = '', stream_key_revoked_at = ?, updated_at = ?
            WHERE id = ?
        },
        undef,
        $ts,
        $ts,
        $id
    );
    die "live channel was not found" unless defined($rows) && $rows > 0;
    return $self->channel_by_id($id);
}

sub verify_stream_key {
    my ($self, $id, $stream_key) = @_;
    my $channel = $self->channel_by_id($id);
    return _stream_key_rejection($channel, $stream_key) ? 0 : 1;
}

sub ingest_authorized {
    my ($self, %args) = @_;
    my $channel_id = int($args{channel_id} || 0);
    my $channel = $self->channel_by_id($channel_id) or return undef;
    return undef if _stream_key_rejection($channel, $args{stream_key});
    my $policy = ref($channel->{ingest_policy}) eq 'HASH' ? $channel->{ingest_policy} : _decode($channel->{ingest_policy_json});
    return undef if _ingest_policy_rejection($channel, $policy);
    return {
        channel_id      => int($channel->{id}),
        slug            => $channel->{slug},
        status          => $channel->{status},
        hls_path        => $channel->{hls_path},
        ingest_endpoint => $self->ingest_endpoint($channel),
        ingest_policy   => $policy,
    };
}

sub worker_ingest_auth {
    my ($self, %args) = @_;
    %args = _normalize_worker_args(%args);
    my $channel = eval { $self->_worker_channel(%args) };
    if (!$channel) {
        my $error = _clean_text($@ || 'live channel was not found', 300);
        return $self->_reject_worker_auth(
            $error,
            %args,
            channel => undef,
            session => undef,
            details => {
                reason                 => 'channel_lookup_failed',
                attempted_channel_id   => int($args{channel_id} || 0),
                attempted_channel_slug => _clean_text($args{channel_slug} || $args{slug} || $args{name} || $args{stream} || '', 120),
            },
        );
    }
    if (my $key_rejection = _stream_key_rejection($channel, $args{stream_key} || $args{key})) {
        return $self->_reject_worker_auth(
            $key_rejection->{message},
            %args,
            channel => $channel,
            session => undef,
            details => $key_rejection->{details},
        );
    }
    my $policy = ref($channel->{ingest_policy}) eq 'HASH' ? $channel->{ingest_policy} : _decode($channel->{ingest_policy_json});
    if (my $policy_rejection = _ingest_policy_rejection($channel, $policy)) {
        return $self->_reject_worker_auth(
            $policy_rejection->{message},
            %args,
            channel => $channel,
            session => undef,
            details => $policy_rejection->{details},
        );
    }
    my $session = eval { $self->_worker_session($channel, %args, create => 0) };
    if ($@) {
        my $error = _clean_text($@ || 'live session was not accepted', 300);
        return $self->_reject_worker_auth(
            $error,
            %args,
            channel => $channel,
            session => undef,
            details => { reason => 'session_lookup_failed' },
        );
    }
    my $event = $self->_record_worker_event(
        %args,
        channel    => $channel,
        session    => $session,
        event_type => 'auth',
        status     => 'authorized',
    );
    $session->{last_worker_event_id} = $event->{id} if $session && $event;
    return $self->_worker_payload(
        $channel,
        $session,
        authorized      => 1,
        worker_event_id => $event ? int($event->{id} || 0) : 0,
    );
}

sub record_worker_ingest_heartbeat {
    my ($self, %args) = @_;
    %args = _normalize_worker_args(%args);
    my $auth = $self->worker_ingest_auth(%args);
    my $channel = $self->channel_by_id($auth->{channel}{id}) or die "live channel was not found";
    my $session = $self->_worker_session($channel, %args, create => 1);
    die "live session was not found" unless $session;
    my $hls_output_path = $args{hls_output_path} || $args{hls_path} || $channel->{hls_path};
    my $updated = $self->record_worker_heartbeat(
        session_id        => $session->{id},
        worker_id         => $args{worker_id},
        heartbeat_status  => $args{heartbeat_status} || $args{worker_status} || $args{status} || 'healthy',
        session_status    => $args{session_status} || _session_status_or_undef($args{status}) || ($session->{status} eq 'scheduled' ? 'live' : $session->{status}),
        hls_output_path   => $hls_output_path,
        viewer_count      => $args{viewer_count},
        message           => $args{message},
        details           => {
            ingest_source => _clean_text($args{ingest_source} || 'worker', 120),
            log_line      => $self->worker_log_line(%args, channel => $channel, session => $session),
        },
    );
    return $self->_worker_payload($channel, $updated, authorized => 1);
}

sub worker_health {
    my ($self, %args) = @_;
    my $max_age = _positive_int($args{max_age} || $self->{config}->get('live_worker_stale_seconds'), 90);
    my $event_window = _positive_int(
        $args{event_window_seconds} || $self->{config}->get('live_worker_event_window_seconds'),
        900
    );
    my $channels = $self->channels;
    my $live_count = 0;
    $live_count++ for grep { ($_->{status} || '') eq 'live' } @{$channels};
    my $worker_events = $self->worker_event_summary(window_seconds => $event_window);
    return {
        service_name   => 'desertcms-stream-worker',
        status         => 'ok',
        generated_at   => now(),
        channels       => scalar(@{$channels}),
        live_channels  => $live_count,
        stale_sessions => scalar(@{ $self->stale_live_sessions(max_age => $max_age) }),
        worker_events  => $worker_events,
        contract       => $self->worker_contract,
    };
}

sub worker_log_line {
    my ($self, %args) = @_;
    my $channel = ref($args{channel}) eq 'HASH'
        ? $args{channel}
        : (exists $args{channel} ? undef : $self->_worker_channel(%args));
    my $session = ref($args{session}) eq 'HASH' ? $args{session} : undef;
    my @parts = (
        now(),
        _clean_text($args{worker_id} || '', 120) || '-',
        int($channel ? ($channel->{id} || 0) : ($args{channel_id} || 0)),
        int($session ? ($session->{id} || 0) : ($args{session_id} || 0)),
        _clean_text($args{session_status} || $args{status} || 'heartbeat', 80),
        _nonnegative_int($args{viewer_count}, 0),
        _clean_text($args{hls_output_path} || $args{hls_path} || ($channel ? $channel->{hls_path} : ''), 500) || '-',
        _clean_text($args{message} || '', 300) || '-',
    );
    s/\s+/ /g for @parts;
    return join ' ', @parts;
}

sub channels {
    my ($self, %args) = @_;
    my $include_disabled = $args{include_disabled} ? 1 : 0;
    my $where = $include_disabled ? '' : "WHERE c.status <> 'disabled'";
    my $rows = $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT c.*, a.display_name, a.username,
                   COUNT(s.id) AS session_count,
                   MAX(s.started_at) AS last_started_at
            FROM live_stream_channels c
            LEFT JOIN user_accounts a ON a.id = c.account_id
            LEFT JOIN live_stream_sessions s ON s.channel_id = c.id
            $where
            GROUP BY c.id
            ORDER BY CASE c.status WHEN 'live' THEN 0 WHEN 'scheduled' THEN 1 WHEN 'offline' THEN 2 ELSE 3 END,
                     lower(c.title)
        },
        { Slice => {} }
    );
    $_->{ingest_policy} = _decode($_->{ingest_policy_json}) for @{$rows};
    return $rows;
}

sub channel_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    my $row = $self->{db}->dbh->selectrow_hashref('SELECT * FROM live_stream_channels WHERE id = ?', undef, int($id));
    $row->{ingest_policy} = _decode($row->{ingest_policy_json}) if $row;
    return $row;
}

sub channel_by_slug {
    my ($self, $slug) = @_;
    $slug = slugify($slug || '');
    my $row = $self->{db}->dbh->selectrow_hashref('SELECT * FROM live_stream_channels WHERE slug = ?', undef, $slug);
    $row->{ingest_policy} = _decode($row->{ingest_policy_json}) if $row;
    return $row;
}

sub save_session {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $channel_id = int($args{channel_id} || 0);
    die "channel id is required" unless $channel_id > 0 || $id > 0;
    my $title = _clean_text($args{title}, 180);
    my $status = _session_status($args{status} || 'scheduled');
    my $scheduled_at = _maybe_int($args{scheduled_at});
    my $details = ref($args{ingest_detail}) eq 'HASH' ? $args{ingest_detail} : {};
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    if ($id) {
        $dbh->do(
            q{
                UPDATE live_stream_sessions
                SET title = ?, status = ?, scheduled_at = ?, ingest_detail_json = ?, updated_at = ?
                WHERE id = ?
            },
            undef,
            $title,
            $status,
            $scheduled_at,
            encode_json($details),
            $ts,
            $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO live_stream_sessions
                    (channel_id, title, status, scheduled_at, ingest_detail_json, created_at, updated_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $channel_id,
            $title,
            $status,
            $scheduled_at,
            encode_json($details),
            $ts,
            $ts
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->session_by_id($id);
}

sub session_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    my $row = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT s.*, c.slug AS channel_slug, c.title AS channel_title, c.hls_path, c.chat_enabled
            FROM live_stream_sessions s
            JOIN live_stream_channels c ON c.id = s.channel_id
            WHERE s.id = ?
        },
        undef,
        int($id)
    );
    $row->{ingest_detail} = _decode($row->{ingest_detail_json}) if $row;
    return $row;
}

sub sessions_for_channel {
    my ($self, $channel_id, %args) = @_;
    return [] unless int($channel_id || 0) > 0;
    my $limit = _limit($args{limit}, 20, 1, 100);
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT *
            FROM live_stream_sessions
            WHERE channel_id = ?
            ORDER BY COALESCE(started_at, scheduled_at, created_at) DESC, id DESC
            LIMIT $limit
        },
        { Slice => {} },
        int($channel_id)
    );
}

sub active_session_for_channel {
    my ($self, $channel_id) = @_;
    return undef unless int($channel_id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM live_stream_sessions
            WHERE channel_id = ? AND status = 'live'
            ORDER BY started_at DESC, id DESC
            LIMIT 1
        },
        undef,
        int($channel_id)
    );
}

sub set_session_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "session id is required" unless $id > 0;
    my $existing = $self->session_by_id($id) or die "live session was not found";
    my $status = _session_status($args{status});
    my %actor = $self->_session_lifecycle_actor(%args);
    return $existing
        if ($existing->{status} || '') eq $status
        && ($status ne 'live' || int($existing->{started_at} || 0) > 0)
        && ($status !~ /\A(?:ended|failed)\z/ || int($existing->{ended_at} || 0) > 0);
    my $ts = now();
    my $started = $status eq 'live' ? $ts : undef;
    my $ended = $status eq 'ended' || $status eq 'failed' ? $ts : undef;
    $self->{db}->dbh->do(
        q{
            UPDATE live_stream_sessions
            SET status = ?,
                started_at = COALESCE(started_at, ?),
                ended_at = COALESCE(ended_at, ?),
                updated_at = ?
            WHERE id = ?
        },
        undef,
        $status,
        $started,
        $ended,
        $ts,
        $id
    );
    my $session = $self->session_by_id($id);
    $self->_sync_channel_status($session) if $session;
    $self->_emit_stream_status_notification($session, $status, %actor) if $session;
    $self->_publish_realtime($args{realtime_publish}, $self->presence_event($session), $session)
        if $session;
    return $session;
}

sub record_worker_heartbeat {
    my ($self, %args) = @_;
    my $id = int($args{session_id} || $args{id} || 0);
    die "session id is required" unless $id > 0;
    my $session = $self->session_by_id($id) or die "live session was not found";
    my $worker_id = _clean_text($args{worker_id}, 120);
    die "worker id is required" unless length $worker_id;
    my $heartbeat_status = _clean_text($args{heartbeat_status} || $args{status} || 'healthy', 80);
    my $session_status = _session_status_or_undef($args{session_status} || $args{status}) || $session->{status};
    my $hls_prefix = _hls_prefix($self->{config}->get('live_hls_public_prefix'));
    my $hls_output_path = exists($args{hls_output_path})
        ? _hls_path_or_die($args{hls_output_path}, $hls_prefix)
        : ($session->{hls_output_path} || $session->{hls_path} || '');
    my $viewer_count = _nonnegative_int($args{viewer_count}, 0);
    my $viewer_peak = $viewer_count > int($session->{viewer_peak} || 0) ? $viewer_count : int($session->{viewer_peak} || 0);
    my $old_status = $session->{status} || '';
    my $details = ref($session->{ingest_detail}) eq 'HASH' ? { %{ $session->{ingest_detail} } } : {};
    if (ref($args{details}) eq 'HASH') {
        $details->{$_} = $args{details}{$_} for keys %{ $args{details} };
    }
    my $ts = now();
    my $channel = $self->channel_by_id($session->{channel_id});
    $details->{log_line} = $self->worker_log_line(
        %args,
        channel         => $channel,
        session         => $session,
        worker_id       => $worker_id,
        status          => $heartbeat_status,
        viewer_count    => $viewer_count,
        hls_output_path => $hls_output_path,
        message         => $args{message} || 'heartbeat',
    );
    my $event = $self->_record_worker_event(
        %args,
        channel    => $channel,
        session    => $session,
        event_type => 'heartbeat',
        worker_id        => $worker_id,
        status           => $heartbeat_status,
        viewer_count     => $viewer_count,
        hls_output_path  => $hls_output_path,
        details          => $details,
        recorded_at      => $ts,
    );
    $details->{last_heartbeat} = {
        worker_id       => $worker_id,
        status          => $heartbeat_status,
        viewer_count    => $viewer_count,
        hls_output_path => $hls_output_path,
        recorded_at     => $ts,
        worker_event_id => $event ? int($event->{id} || 0) : 0,
    };
    my $started = $session_status eq 'live' ? $ts : undef;
    my $ended = ($session_status eq 'ended' || $session_status eq 'failed') ? $ts : undef;
    $self->{db}->dbh->do(
        q{
            UPDATE live_stream_sessions
            SET status = ?,
                viewer_peak = ?,
                worker_id = ?,
                last_heartbeat_at = ?,
                heartbeat_status = ?,
                hls_output_path = ?,
                ingest_detail_json = ?,
                started_at = COALESCE(started_at, ?),
                ended_at = COALESCE(ended_at, ?),
                updated_at = ?
            WHERE id = ?
        },
        undef,
        $session_status,
        $viewer_peak,
        $worker_id,
        $ts,
        $heartbeat_status,
        $hls_output_path,
        encode_json($details),
        $started,
        $ended,
        $ts,
        $id
    );
    $session = $self->session_by_id($id);
    $self->_sync_channel_status($session) if $session;
    $self->_emit_stream_status_notification($session, $session_status, system_action => 'stream_worker_heartbeat')
        if $session && $session_status ne $old_status && ($session_status eq 'live' || $session_status eq 'ended' || $session_status eq 'failed');
    $self->_emit_notification(
        audience    => 'admin',
        topic       => 'stream.ingest_failed',
        module_key  => 'live_streaming',
        severity    => 'critical',
        title       => 'Stream worker reported a problem',
        body        => $heartbeat_status,
        entity_type => 'live_stream_session',
        entity_id   => $session->{id},
        url         => '/admin/live',
        details     => { worker_id => $worker_id, hls_output_path => $hls_output_path },
    ) if $session && $heartbeat_status =~ /\A(?:failed|error|unhealthy)\z/i;
    $self->_publish_realtime($args{realtime_publish}, $self->presence_event($session), $session)
        if $session;
    return $session;
}

sub worker_events {
    my ($self, %args) = @_;
    my @where;
    my @bind;
    if (int($args{session_id} || 0) > 0) {
        push @where, 'e.session_id = ?';
        push @bind, int($args{session_id});
    }
    if (int($args{channel_id} || 0) > 0) {
        push @where, 'e.channel_id = ?';
        push @bind, int($args{channel_id});
    }
    if (defined($args{worker_id}) && length($args{worker_id})) {
        push @where, 'e.worker_id = ?';
        push @bind, _clean_text($args{worker_id}, 120);
    }
    my $where = @where ? 'WHERE ' . join(' AND ', @where) : '';
    my $limit = _limit($args{limit}, 50, 1, 500);
    my $rows = $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT e.*, c.slug AS channel_slug, c.title AS channel_title, s.title AS session_title
            FROM live_stream_worker_events e
            LEFT JOIN live_stream_channels c ON c.id = e.channel_id
            LEFT JOIN live_stream_sessions s ON s.id = e.session_id
            $where
            ORDER BY e.created_at DESC, e.id DESC
            LIMIT $limit
        },
        { Slice => {} },
        @bind
    );
    $_->{details} = _decode($_->{details_json}) for @{$rows};
    return $rows;
}

sub worker_event_summary {
    my ($self, %args) = @_;
    my $window = _positive_int($args{window_seconds} || $args{max_age}, 900);
    my $cutoff = now() - $window;
    my @where = ('e.created_at >= ?');
    my @bind = ($cutoff);
    if (int($args{session_id} || 0) > 0) {
        push @where, 'e.session_id = ?';
        push @bind, int($args{session_id});
    }
    if (int($args{channel_id} || 0) > 0) {
        push @where, 'e.channel_id = ?';
        push @bind, int($args{channel_id});
    }
    if (defined($args{worker_id}) && length($args{worker_id})) {
        push @where, 'e.worker_id = ?';
        push @bind, _clean_text($args{worker_id}, 120);
    }
    my $where = 'WHERE ' . join(' AND ', @where);
    my %summary = (
        available       => 0,
        window_seconds  => $window,
        cutoff          => $cutoff,
        total_events    => 0,
        auth_authorized => 0,
        auth_rejected   => 0,
        heartbeat_events => 0,
        unhealthy_events => 0,
        latest_event_id => 0,
        latest_event_at => 0,
        latest_event_type => '',
        latest_status   => '',
        latest_worker_id => '',
        error           => '',
    );
    my $dbh = $self->{db}->dbh;
    my $row = eval {
        $dbh->selectrow_hashref(
            qq{
                SELECT
                    COUNT(*) AS total_events,
                    COALESCE(SUM(CASE WHEN e.event_type = 'auth' AND e.status = 'authorized' THEN 1 ELSE 0 END), 0) AS auth_authorized,
                    COALESCE(SUM(CASE WHEN e.event_type = 'auth' AND e.status = 'rejected' THEN 1 ELSE 0 END), 0) AS auth_rejected,
                    COALESCE(SUM(CASE WHEN e.event_type = 'heartbeat' THEN 1 ELSE 0 END), 0) AS heartbeat_events,
                    COALESCE(SUM(CASE WHEN LOWER(e.status) IN ('failed', 'error', 'unhealthy') THEN 1 ELSE 0 END), 0) AS unhealthy_events,
                    COALESCE(MAX(e.created_at), 0) AS latest_event_at
                FROM live_stream_worker_events e
                $where
            },
            undef,
            @bind
        );
    };
    if ($@) {
        $summary{error} = _clean_text($@, 300);
        return \%summary;
    }
    for my $key (qw(total_events auth_authorized auth_rejected heartbeat_events unhealthy_events latest_event_at)) {
        $summary{$key} = int(($row && defined $row->{$key}) ? $row->{$key} : 0);
    }
    my $latest = eval {
        $dbh->selectrow_hashref(
            qq{
                SELECT e.id, e.event_type, e.status, e.worker_id, e.created_at
                FROM live_stream_worker_events e
                $where
                ORDER BY e.created_at DESC, e.id DESC
                LIMIT 1
            },
            undef,
            @bind
        );
    };
    if ($@) {
        $summary{error} = _clean_text($@, 300);
        return \%summary;
    }
    $summary{available} = 1;
    if ($latest) {
        $summary{latest_event_id} = int($latest->{id} || 0);
        $summary{latest_event_type} = $latest->{event_type} || '';
        $summary{latest_status} = $latest->{status} || '';
        $summary{latest_worker_id} = $latest->{worker_id} || '';
        $summary{latest_event_at} = int($latest->{created_at} || $summary{latest_event_at} || 0);
    }
    return \%summary;
}

sub due_scheduled_sessions {
    my ($self, %args) = @_;
    my $current = _maybe_int($args{now});
    $current = now() unless defined $current;
    my $lookahead = _positive_int($args{lookahead_seconds}, 0);
    my $include_notified = $args{include_notified} ? 1 : 0;
    my $limit = _limit($args{limit}, 50, 1, 500);
    my $rows = $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT s.*, c.slug AS channel_slug, c.title AS channel_title, c.status AS channel_status
            FROM live_stream_sessions s
            JOIN live_stream_channels c ON c.id = s.channel_id
            WHERE s.status = 'scheduled'
              AND s.scheduled_at IS NOT NULL
              AND s.scheduled_at <= ?
              AND c.status <> 'disabled'
            ORDER BY s.scheduled_at, s.id
            LIMIT $limit
        },
        { Slice => {} },
        $current + $lookahead
    );
    my @due;
    for my $session (@{$rows}) {
        $session->{ingest_detail} = _decode($session->{ingest_detail_json});
        next if !$include_notified && int($session->{ingest_detail}{schedule_due_notified_at} || 0) > 0;
        push @due, $session;
    }
    return \@due;
}

sub emit_schedule_due_notifications {
    my ($self, %args) = @_;
    my $current = _maybe_int($args{now});
    $current = now() unless defined $current;
    my @emitted;
    for my $session (@{ $self->due_scheduled_sessions(%args, now => $current) }) {
        my $notice = $self->_emit_notification(
            audience    => 'admin',
            topic       => 'stream.schedule_due',
            module_key  => 'live_streaming',
            severity    => 'warning',
            title       => 'Scheduled stream is due',
            body        => $session->{channel_title} || $session->{title} || 'A scheduled live stream is due.',
            entity_type => 'live_stream_session',
            entity_id   => $session->{id},
            url         => '/admin/live',
            details     => {
                channel_id   => int($session->{channel_id} || 0),
                scheduled_at => int($session->{scheduled_at} || 0),
            },
        );
        next unless $notice;
        my $marked = $self->_mark_schedule_due_notified($session, $current);
        push @emitted, $marked if $marked;
    }
    return \@emitted;
}

sub stale_live_sessions {
    my ($self, %args) = @_;
    my $max_age = _positive_int($args{max_age}, 90);
    my $cutoff = now() - $max_age;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT s.*, c.slug AS channel_slug, c.title AS channel_title
            FROM live_stream_sessions s
            JOIN live_stream_channels c ON c.id = s.channel_id
            WHERE s.status = 'live' AND (s.last_heartbeat_at IS NULL OR s.last_heartbeat_at < ?)
            ORDER BY COALESCE(s.last_heartbeat_at, s.started_at, s.created_at), s.id
        },
        { Slice => {} },
        $cutoff
    );
}

sub _worker_channel {
    my ($self, %args) = @_;
    my $channel_id = int($args{channel_id} || 0);
    my $channel = $channel_id > 0 ? $self->channel_by_id($channel_id) : undef;
    if (!$channel) {
        my $slug = $args{channel_slug} || $args{slug} || $args{name} || $args{stream};
        $channel = $self->channel_by_slug($slug) if defined($slug) && length($slug);
    }
    die "live channel was not found" unless $channel;
    die "live channel is disabled" if ($channel->{status} || '') eq 'disabled';
    return $channel;
}

sub _normalize_worker_args {
    my (%args) = @_;
    $args{stream_key} = $args{key} if !defined($args{stream_key}) && defined($args{key});
    $args{stream_key} = $args{token} if !defined($args{stream_key}) && defined($args{token});

    my $raw_stream = '';
    for my $key (qw(stream_name name stream)) {
        if (defined($args{$key}) && length($args{$key})) {
            $raw_stream = $args{$key};
            last;
        }
    }
    return %args unless length $raw_stream;

    my $had_channel = int($args{channel_id} || 0) > 0
        || length($args{channel_slug} || '')
        || length($args{slug} || '');
    my $stream = _clean_text($raw_stream, 500);
    $stream =~ s/\A\s+|\s+\z//g;
    return %args unless length $stream;

    if ($stream =~ /\A([^?]+)\?(.+)\z/) {
        my ($path, $query) = ($1, $2);
        $args{channel_slug} = _stream_name_slug($path)
            if !$had_channel && !length($args{channel_slug} || '');
        my $params = _stream_query_params($query);
        for my $key (qw(stream_key key token)) {
            if (!defined($args{stream_key}) && defined($params->{$key}) && length($params->{$key})) {
                $args{stream_key} = $params->{$key};
                last;
            }
        }
        return %args;
    }

    if ($stream =~ m{\A(.+?)(?:/|:)([^/:?]{16,})\z}) {
        my ($slug_part, $key_part) = ($1, $2);
        $args{channel_slug} = _stream_name_slug($slug_part)
            if !$had_channel && !length($args{channel_slug} || '');
        $args{stream_key} = $key_part if !defined($args{stream_key}) || !length($args{stream_key});
        return %args;
    }

    if ($had_channel) {
        my $known_slug = $args{channel_slug} || $args{slug} || '';
        $args{stream_key} = $stream
            if (!defined($args{stream_key}) || !length($args{stream_key}))
            && (!length($known_slug) || $stream ne $known_slug);
    } elsif (!length($args{channel_slug} || '')) {
        $args{channel_slug} = _stream_name_slug($stream);
    }

    return %args;
}

sub _stream_query_params {
    my ($query) = @_;
    my %params;
    for my $pair (split /&/, $query || '') {
        my ($key, $value) = split /=/, $pair, 2;
        next unless defined $key;
        $key = lc(url_decode($key));
        next unless length $key;
        $params{$key} = url_decode(defined $value ? $value : '');
    }
    return \%params;
}

sub _stream_name_slug {
    my ($value) = @_;
    $value = url_decode($value || '');
    $value =~ s{\A/+}{};
    $value =~ s{/+\z}{};
    my @parts = grep { length } split m{/+}, $value;
    return slugify(@parts ? $parts[-1] : $value);
}

sub _ingest_policy_rejection {
    my ($channel, $policy) = @_;
    $policy = {} unless ref($policy) eq 'HASH';
    if (exists($policy->{enabled}) && !_truthy($policy->{enabled})) {
        return {
            message => 'ingest is disabled for this channel',
            details => { reason => 'ingest_policy_disabled' },
        };
    }
    if (ref($policy->{allowed_statuses}) eq 'ARRAY' && @{ $policy->{allowed_statuses} }) {
        my %allowed = map { lc($_ || '') => 1 } @{ $policy->{allowed_statuses} };
        return undef if $allowed{lc($channel->{status} || '')};
        return {
            message => 'channel status is not allowed for ingest',
            details => { reason => 'channel_status_rejected', channel_status => $channel->{status} || '' },
        };
    }
    return undef;
}

sub _stream_key_rejection {
    my ($channel, $stream_key) = @_;
    return {
        message => 'live channel was not found',
        details => { reason => 'channel_lookup_failed' },
    } unless ref($channel) eq 'HASH';
    if (($channel->{status} || '') eq 'disabled') {
        return {
            message => 'live channel is disabled',
            details => { reason => 'channel_disabled' },
        };
    }
    if ($channel->{stream_key_revoked_at}) {
        return {
            message => 'stream key was revoked',
            details => { reason => 'stream_key_revoked', stream_key_revoked_at => int($channel->{stream_key_revoked_at} || 0) },
        };
    }
    unless (length($channel->{stream_key_hash} || '')) {
        return {
            message => 'stream key is not configured',
            details => { reason => 'stream_key_missing' },
        };
    }
    unless (defined $stream_key && length $stream_key && constant_time_eq(sha256_hexstr($stream_key), $channel->{stream_key_hash} || '')) {
        return {
            message => 'stream key was not accepted',
            details => { reason => 'stream_key_rejected' },
        };
    }
    return undef;
}

sub _worker_session {
    my ($self, $channel, %args) = @_;
    my $session_id = int($args{session_id} || 0);
    if ($session_id > 0) {
        my $session = $self->session_by_id($session_id) or die "live session was not found";
        die "live session does not belong to this channel" unless int($session->{channel_id} || 0) == int($channel->{id} || 0);
        die "live session is terminal and cannot accept worker heartbeats"
            if ($session->{status} || '') =~ /\A(?:ended|failed)\z/;
        return $session;
    }
    my $active = $self->active_session_for_channel($channel->{id});
    return $active if $active;
    my ($scheduled) = @{ $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM live_stream_sessions
            WHERE channel_id = ? AND status = 'scheduled'
            ORDER BY COALESCE(scheduled_at, created_at), id
            LIMIT 1
        },
        { Slice => {} },
        int($channel->{id})
    ) };
    return $scheduled if $scheduled;
    return undef unless $args{create};
    return $self->save_session(
        channel_id => $channel->{id},
        title      => _clean_text($args{session_title} || $channel->{title} || 'Live stream', 180),
        status     => 'scheduled',
        ingest_detail => {
            created_by    => 'worker_heartbeat',
            worker_id     => _clean_text($args{worker_id}, 120),
            hls_path      => $channel->{hls_path},
            ingest_source => _clean_text($args{ingest_source} || 'worker', 120),
        },
    );
}

sub _worker_payload {
    my ($self, $channel, $session, %extra) = @_;
    my $contract = $self->worker_contract;
    return {
        %extra,
        channel => {
            id              => int($channel->{id} || 0),
            slug            => $channel->{slug} || '',
            status          => $channel->{status} || 'offline',
            ingest_endpoint => $self->ingest_endpoint($channel),
        },
        session => $session ? {
            id                => int($session->{id} || 0),
            status            => $session->{status} || 'scheduled',
            worker_id         => $session->{worker_id} || '',
            last_heartbeat_at => int($session->{last_heartbeat_at} || 0),
            heartbeat_status  => $session->{heartbeat_status} || '',
            viewer_peak       => int($session->{viewer_peak} || 0),
            worker_event_id   => int($session->{ingest_detail}{last_heartbeat}{worker_event_id} || $session->{last_worker_event_id} || 0),
        } : undef,
        hls => {
            public_path => $channel->{hls_path} || '',
            output_path => ($session && length($session->{hls_output_path} || '')) ? $session->{hls_output_path} : ($channel->{hls_path} || ''),
            output_dir  => $contract->{hls}{output_dir},
            served_by   => 'httpd',
        },
        log_format => $contract->{logs}{format},
    };
}

sub _record_worker_event {
    my ($self, %args) = @_;
    my $channel = ref($args{channel}) eq 'HASH' ? $args{channel} : undef;
    my $session = ref($args{session}) eq 'HASH' ? $args{session} : undef;
    my $channel_id = int($channel ? ($channel->{id} || 0) : ($args{channel_id} || 0)) || undef;
    my $session_id = int($session ? ($session->{id} || 0) : ($args{session_id} || 0)) || undef;
    my $worker_id = _clean_text($args{worker_id}, 120);
    my $event_type = _worker_event_type($args{event_type});
    my $status = _clean_text($args{status} || $args{heartbeat_status} || $args{worker_status} || '', 80);
    my $viewer_count = _nonnegative_int($args{viewer_count}, 0);
    my $message = _clean_text($args{message} || '', 300);
    my $details = ref($args{details}) eq 'HASH' ? { %{ $args{details} } } : {};
    my $hls_output_path = _worker_event_hls_path(
        $details,
        %args,
        channel => $channel,
        session => $session,
        prefix  => _hls_prefix($self->{config}->get('live_hls_public_prefix')),
    );
    my $ts = int($args{recorded_at} || now());
    my $log_line = _clean_text(
        $args{log_line} || $self->worker_log_line(
            %args,
            channel         => $channel,
            session         => $session,
            worker_id       => $worker_id,
            status          => length($status) ? $status : $event_type,
            viewer_count    => $viewer_count,
            hls_output_path => $hls_output_path,
            message         => length($message) ? $message : $event_type,
        ),
        1200
    );
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        q{
            INSERT INTO live_stream_worker_events
                (channel_id, session_id, worker_id, event_type, status, viewer_count, hls_output_path, message, log_line, details_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $channel_id,
        $session_id,
        $worker_id,
        $event_type,
        $status,
        $viewer_count,
        $hls_output_path,
        $message,
        $log_line,
        encode_json($details),
        $ts
    );
    my $id = int($dbh->sqlite_last_insert_rowid);
    return $dbh->selectrow_hashref('SELECT * FROM live_stream_worker_events WHERE id = ?', undef, $id);
}

sub _reject_worker_auth {
    my ($self, $message, %args) = @_;
    $message = _clean_text($message || 'stream key was not accepted', 300);
    eval {
        $self->_record_worker_event(
            %args,
            event_type => 'auth',
            status     => 'rejected',
            message    => $message,
        );
        1;
    };
    die $message;
}

sub chat_messages {
    my ($self, $session_id, %args) = @_;
    return [] unless int($session_id || 0) > 0;
    my $include_hidden = $args{include_hidden} ? 1 : 0;
    my $where = $include_hidden ? '' : "AND m.status = 'visible' AND (m.account_id IS NULL OR a.status = 'active')";
    my $limit = _limit($args{limit}, 100, 1, 500);
    my $rows = $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT m.*, a.username, a.display_name AS account_display_name
            FROM live_chat_messages m
            LEFT JOIN user_accounts a ON a.id = m.account_id
            WHERE m.session_id = ?
            $where
            ORDER BY m.created_at DESC, m.id DESC
            LIMIT $limit
        },
        { Slice => {} },
        int($session_id)
    );
    if (!$include_hidden) {
        delete $_->{ip_address} for @{$rows};
    }
    return $rows;
}

sub add_chat_message {
    my ($self, %args) = @_;
    my $session_id = int($args{session_id} || 0);
    my $body = _clean_text($args{body}, 1000);
    my $ip_address = _clean_ip($args{ip_address});
    die "session and chat body are required" unless $session_id > 0 && length $body;
    my $session = $self->session_by_id($session_id) or die "live session was not found";
    die "live chat opens when the stream is live" unless ($session->{status} || '') eq 'live';
    die "live chat is disabled for this channel" unless int($session->{chat_enabled} || 0);
    my $account_id = int($args{account_id} || 0) || undef;
    if ($account_id) {
        $self->_active_account_or_die($account_id);
    } elsif (_truthy($args{account_only}) || _truthy($self->{config}->get('live_chat_account_only'))) {
        die "live chat requires an active account";
    }
    my $display = _clean_text($args{display_name}, 140);
    my $match = $self->_matching_blocked_term($body);
    if ($match && ($match->{action} || '') eq 'reject') {
        die "live chat message matched a blocked term";
    }
    $self->_enforce_chat_ip_rate_limit(
        session_id  => $session_id,
        ip_address  => $ip_address,
    );
    $self->_enforce_chat_slow_mode(
        session_id   => $session_id,
        account_id   => $account_id,
        display_name => $display,
        seconds      => $args{slow_mode_seconds},
    );
    my $status = $match && ($match->{action} || '') eq 'hide'
        ? 'hidden'
        : ($match && ($match->{action} || '') eq 'report' ? 'reported' : 'visible');
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO live_chat_messages (session_id, account_id, display_name, body, status, ip_address, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $session_id,
        $account_id,
        $display,
        $body,
        $status,
        $ip_address,
        $ts,
        $ts
    );
    my $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    my $message = $self->chat_message_by_id($id);
    if ($match && ($match->{action} || '') =~ /\A(?:report|hide)\z/) {
        $message->{moderation_report} = $self->report_chat_message(
            message_id          => $id,
            reporter_account_id => $account_id,
            reason              => 'Blocked term: ' . ($match->{term} || ''),
            system_action       => 'live_chat_blocked_term',
        );
    }
    $message->{blocked_term} = $match if $match;
    $self->_publish_realtime($args{realtime_publish}, $self->chat_event($message), $message)
        if ($message->{status} || '') eq 'visible';
    return $message;
}

sub chat_message_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM live_chat_messages WHERE id = ?', undef, int($id));
}

sub update_chat_presence {
    my ($self, %args) = @_;
    my $session_id = int($args{session_id} || 0);
    die "session id is required" unless $session_id > 0;
    my $session = $self->session_by_id($session_id) or die "live session was not found";
    die "live chat opens when the stream is live" unless ($session->{status} || '') eq 'live';
    die "live chat is disabled for this channel" unless int($session->{chat_enabled} || 0);

    my $account_id = int($args{account_id} || 0) || undef;
    my $account;
    if ($account_id) {
        $account = $self->_active_account_or_die($account_id);
    } elsif (_truthy($args{account_only}) || _truthy($self->{config}->get('live_chat_account_only'))) {
        die "live chat presence requires an active account";
    }

    my $display = _clean_text(
        $args{display_name}
            || ($account ? ($account->{display_name} || $account->{username}) : '')
            || 'Guest',
        140
    );
    my $presence_key = $account_id
        ? 'account:' . $account_id
        : 'guest:' . _clean_text($args{client_id} || $display, 120);
    die "presence key is required" unless length $presence_key;
    my $status = _presence_status($args{status});
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO live_chat_presence
                (session_id, account_id, presence_key, display_name, status, joined_at, last_seen_at, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, presence_key) DO UPDATE SET
                account_id = excluded.account_id,
                display_name = excluded.display_name,
                status = excluded.status,
                last_seen_at = excluded.last_seen_at,
                updated_at = excluded.updated_at
        },
        undef,
        $session_id,
        $account_id,
        $presence_key,
        $display,
        $status,
        $ts,
        $ts,
        $ts
    );
    my $presence = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM live_chat_presence WHERE session_id = ? AND presence_key = ?',
        undef,
        $session_id,
        $presence_key
    );
    $self->_publish_realtime($args{realtime_publish}, $self->live_presence_event($presence), $presence);
    return $presence;
}

sub leave_chat_presence {
    my ($self, %args) = @_;
    $args{status} = 'left';
    return $self->update_chat_presence(%args);
}

sub chat_presence {
    my ($self, $session_id, %args) = @_;
    return [] unless int($session_id || 0) > 0;
    my $include_left = $args{include_left} ? 1 : 0;
    my $include_inactive = $args{include_inactive} ? 1 : 0;
    my $active_within = _positive_int(
        exists($args{active_within}) ? $args{active_within} : $self->{config}->get('live_chat_presence_stale_seconds'),
        120
    );
    my @where = ('p.session_id = ?');
    my @bind = (int($session_id));
    if (!$include_left) {
        push @where, "p.status <> 'left'";
        push @where, 'p.last_seen_at >= ?' if $active_within > 0;
        push @bind, now() - $active_within if $active_within > 0;
    }
    push @where, "(p.account_id IS NULL OR a.status = 'active')" unless $include_inactive;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT p.*, a.username, a.display_name AS account_display_name
            FROM live_chat_presence p
            LEFT JOIN user_accounts a ON a.id = p.account_id
            WHERE
        } . ' ' . join(' AND ', @where) . q{
            ORDER BY p.last_seen_at DESC, p.id DESC
        },
        { Slice => {} },
        @bind
    );
}

sub set_chat_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "chat message id is required" unless $id > 0;
    my $existing = $self->chat_message_by_id($id) or die "live chat message was not found";
    my $status = _chat_status($args{status});
    my %actor = $self->_moderation_actor(%args);
    return $existing if ($existing->{status} || '') eq $status;
    $self->{db}->dbh->do('UPDATE live_chat_messages SET status = ?, updated_at = ? WHERE id = ?', undef, $status, now(), $id);
    my $message = $self->chat_message_by_id($id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'stream.chat_moderated',
        module_key       => 'live_streaming',
        severity         => 'info',
        title            => 'Live chat moderated',
        body             => 'A live chat message was marked ' . $status . '.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'live_chat_message',
        entity_id        => $id,
        url              => '/admin/live',
        details          => _moderation_details(
            status         => $status,
            session_id     => int($message->{session_id} || 0),
            moderator_note => _clean_text($args{moderator_note}, 500),
            system_action  => $actor{system_action},
        ),
    ) if $message && $status ne 'visible';
    $self->_publish_realtime($args{realtime_publish}, $self->chat_event($message), $message)
        if $message;
    return $message;
}

sub delete_own_chat_message {
    my ($self, %args) = @_;
    my $id = int($args{id} || $args{message_id} || 0);
    my $account_id = int($args{account_id} || 0);
    die "chat message and account are required" unless $id > 0 && $account_id > 0;
    my $message = $self->chat_message_by_id($id) or die "live chat message was not found";
    if (int($args{channel_id} || 0) > 0) {
        my ($channel_id) = $self->{db}->dbh->selectrow_array(
            'SELECT channel_id FROM live_stream_sessions WHERE id = ?',
            undef,
            int($message->{session_id} || 0)
        );
        die "live chat message does not belong to this channel"
            unless int($channel_id || 0) == int($args{channel_id} || 0);
    }
    my ($allowed, $reason) = $self->can_delete_own_chat_message(message => $message, account_id => $account_id);
    die "live chat permission denied: $reason" unless $allowed;
    $self->{db}->dbh->do('UPDATE live_chat_messages SET status = ?, updated_at = ? WHERE id = ?', undef, 'deleted', now(), $id);
    my $deleted = $self->chat_message_by_id($id);
    $self->_publish_realtime($args{realtime_publish}, $self->chat_event($deleted), $deleted)
        if $deleted;
    return $deleted;
}

sub can_delete_own_chat_message {
    my ($self, %args) = @_;
    my $id = int($args{id} || $args{message_id} || 0);
    my $account_id = int($args{account_id} || 0);
    return _permission(0, 'chat message and account are required') unless ($id > 0 || ref($args{message}) eq 'HASH') && $account_id > 0;
    my $active = eval { $self->_active_account_or_die($account_id); 1 };
    return _permission(0, 'account is not active') unless $active;
    my $message = $args{message} || $self->chat_message_by_id($id);
    return _permission(0, 'live chat message was not found') unless $message;
    return _permission(0, 'live chat message belongs to another account')
        unless int($message->{account_id} || 0) == $account_id;
    return _permission(0, 'live chat message cannot be deleted')
        unless ($message->{status} || '') =~ /\A(?:visible|reported)\z/;
    my $window = _positive_int($self->{config}->get('live_chat_delete_window_seconds') || 900, 900);
    return _permission(0, 'live chat message delete window has closed')
        unless int($message->{created_at} || 0) >= now() - $window;
    return _permission(1, '');
}

sub _publish_realtime {
    my ($self, $publisher, $event, $target) = @_;
    return unless ref($publisher) eq 'CODE';
    my $ok = eval { $publisher->($event); 1 };
    $target->{realtime_delivery} = $ok ? 'delivered' : 'failed' if ref($target) eq 'HASH';
    $target->{realtime_error} = "$@" if !$ok && ref($target) eq 'HASH';
    return $ok ? 1 : 0;
}

sub hide_chat_message {
    my ($self, %args) = @_;
    return $self->set_chat_status(%args, status => 'hidden');
}

sub delete_chat_message {
    my ($self, %args) = @_;
    return $self->set_chat_status(%args, status => 'deleted');
}

sub chat_event {
    my ($self, $message) = @_;
    $message = $self->chat_message_by_id($message) unless ref($message) eq 'HASH';
    die "live chat message was not found" unless $message;
    return {
        type    => 'live.chat',
        channel => 'live.chat.' . int($message->{session_id} || 0),
        data    => {
            id           => int($message->{id} || 0),
            session_id   => int($message->{session_id} || 0),
            account_id   => int($message->{account_id} || 0),
            display_name => $message->{display_name} || '',
            body         => ($message->{status} || '') eq 'visible' ? ($message->{body} || '') : '',
            status       => $message->{status} || 'visible',
            created_at   => int($message->{created_at} || 0),
        },
    };
}

sub presence_event {
    my ($self, $session) = @_;
    $session = $self->session_by_id($session) unless ref($session) eq 'HASH';
    die "live session was not found" unless $session;
    return {
        type    => 'stream.presence',
        channel => 'stream.presence.' . int($session->{channel_id} || 0),
        data    => {
            session_id        => int($session->{id} || 0),
            channel_id        => int($session->{channel_id} || 0),
            status            => $session->{status} || 'scheduled',
            heartbeat_status  => $session->{heartbeat_status} || '',
            viewer_peak       => int($session->{viewer_peak} || 0),
            last_heartbeat_at => int($session->{last_heartbeat_at} || 0),
            hls_output_path   => $session->{hls_output_path} || '',
        },
    };
}

sub live_presence_event {
    my ($self, $presence_or_session) = @_;
    my $presence = ref($presence_or_session) eq 'HASH' ? $presence_or_session : undef;
    my $session_id = int($presence ? ($presence->{session_id} || 0) : ($presence_or_session || 0));
    my $session = $self->session_by_id($session_id) or die "live session was not found";
    my $participants = $self->chat_presence($session_id);
    return {
        type    => 'live.presence',
        channel => 'live.presence.' . $session_id,
        data    => {
            session_id     => $session_id,
            channel_id     => int($session->{channel_id} || 0),
            status         => $session->{status} || 'scheduled',
            presence_count => scalar(@{$participants}),
            participant    => $presence ? {
                id            => int($presence->{id} || 0),
                account_id    => int($presence->{account_id} || 0),
                display_name  => $presence->{display_name} || '',
                status        => $presence->{status} || 'present',
                last_seen_at  => int($presence->{last_seen_at} || 0),
            } : undef,
        },
    };
}

sub save_blocked_term {
    my ($self, %args) = @_;
    my $term = lc _clean_text($args{term}, 120);
    die "blocked term is required" unless length $term;
    my $action = _blocked_term_action($args{action});
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO live_chat_blocked_terms (term, action, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(term) DO UPDATE SET
                action = excluded.action,
                updated_at = excluded.updated_at
        },
        undef,
        $term,
        $action,
        $ts,
        $ts
    );
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM live_chat_blocked_terms WHERE term = ?', undef, $term);
}

sub blocked_term_by_id {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM live_chat_blocked_terms WHERE id = ?', undef, $id);
}

sub delete_blocked_term {
    my ($self, %args) = @_;
    my $term = $self->blocked_term_by_id($args{id});
    die "blocked term was not found" unless $term;
    $self->{db}->dbh->do('DELETE FROM live_chat_blocked_terms WHERE id = ?', undef, int($term->{id}));
    return $term;
}

sub blocked_terms {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        'SELECT * FROM live_chat_blocked_terms ORDER BY lower(term)',
        { Slice => {} }
    );
}

sub report_chat_message {
    my ($self, %args) = @_;
    my $message_id = int($args{message_id} || 0);
    die "chat message id is required" unless $message_id > 0;
    my $message = $self->chat_message_by_id($message_id) or die "live chat message was not found";
    my $system_action = _system_moderation_action($args{system_action});
    if (!length $system_action) {
        die "live chat message is not visible" unless ($message->{status} || '') =~ /\A(?:visible|reported)\z/;
        if (int($message->{account_id} || 0) > 0) {
            my ($author_active) = $self->{db}->dbh->selectrow_array(
                "SELECT 1 FROM user_accounts WHERE id = ? AND status = 'active'",
                undef,
                int($message->{account_id})
            );
            die "live chat message is not visible" unless $author_active;
        }
    }
    my $reporter_account_id = int($args{reporter_account_id} || 0) || undef;
    $self->_active_account_or_die($reporter_account_id) if $reporter_account_id;
    my $reason = _clean_text($args{reason}, 500);
    my @where = ('message_id = ?', "status = 'open'");
    my @bind = ($message_id);
    if (defined $reporter_account_id) {
        push @where, 'reporter_account_id = ?';
        push @bind, int($reporter_account_id);
    } else {
        push @where, 'reporter_account_id IS NULL';
    }
    my ($existing) = $self->{db}->dbh->selectrow_array(
        'SELECT id FROM live_chat_reports WHERE ' . join(' AND ', @where) . ' LIMIT 1',
        undef,
        @bind
    );
    die "duplicate live chat report suppressed" if $existing;
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO live_chat_reports
                (message_id, session_id, reporter_account_id, reason, status, moderator_note, created_at, updated_at)
            VALUES
                (?, ?, ?, ?, 'open', '', ?, ?)
        },
        undef,
        $message_id,
        int($message->{session_id} || 0),
        $reporter_account_id,
        $reason,
        $ts,
        $ts
    );
    my $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    my $message_status = ($message->{status} || '') eq 'hidden' ? 'hidden' : 'reported';
    $self->{db}->dbh->do(
        "UPDATE live_chat_messages SET status = ?, updated_at = ? WHERE id = ? AND status <> 'deleted'",
        undef,
        $message_status,
        $ts,
        $message_id
    );
    my $report = $self->{db}->dbh->selectrow_hashref('SELECT * FROM live_chat_reports WHERE id = ?', undef, $id);
    $self->_emit_notification(
        audience             => 'admin',
        topic                => 'stream.chat_reported',
        module_key           => 'live_streaming',
        severity             => 'warning',
        title                => 'Live chat reported',
        body                 => $reason || 'A live chat message was reported.',
        actor_account_id     => $reporter_account_id,
        entity_type          => 'live_chat_report',
        entity_id            => $report->{id},
        url                  => '/admin/live',
        details              => _moderation_details(message_id => $message_id, session_id => $message->{session_id}, system_action => $system_action),
    );
    return $report;
}

sub chat_reports {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 100, 1, 500);
    my @where;
    my @bind;
    if (length($args{status} || '')) {
        push @where, 'r.status = ?';
        push @bind, _report_status($args{status});
    }
    my $sql = q{
        SELECT r.*, m.body, m.display_name, m.status AS message_status, c.slug AS channel_slug, s.title AS session_title
        FROM live_chat_reports r
        LEFT JOIN live_chat_messages m ON m.id = r.message_id
        LEFT JOIN live_stream_sessions s ON s.id = r.session_id
        LEFT JOIN live_stream_channels c ON c.id = s.channel_id
    };
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY r.created_at DESC, r.id DESC LIMIT ?';
    push @bind, $limit;
    return $self->{db}->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
}

sub set_chat_report_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "chat report id is required" unless $id > 0;
    my $existing = $self->{db}->dbh->selectrow_hashref('SELECT * FROM live_chat_reports WHERE id = ?', undef, $id)
        or die "live chat report was not found";
    my $status = _report_status($args{status});
    my %actor = $self->_moderation_actor(%args);
    my $note = _clean_text($args{moderator_note}, 500);
    return $existing if ($existing->{status} || '') eq $status && ($existing->{moderator_note} || '') eq $note;
    my $resolved = $status eq 'open' ? undef : ($existing->{resolved_at} || now());
    $self->{db}->dbh->do(
        q{
            UPDATE live_chat_reports
            SET status = ?, moderator_note = ?, resolved_at = ?, updated_at = ?
            WHERE id = ?
        },
        undef,
        $status,
        $note,
        $resolved,
        now(),
        $id
    );
    my $report = $self->{db}->dbh->selectrow_hashref('SELECT * FROM live_chat_reports WHERE id = ?', undef, $id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'stream.chat_moderated',
        module_key       => 'live_streaming',
        severity         => 'info',
        title            => 'Live chat report status changed',
        body             => $note || 'A live chat report was moderated.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'live_chat_report',
        entity_id        => $id,
        url              => '/admin/live',
        details          => _moderation_details(
            status        => $status,
            message_id    => int($report->{message_id} || 0),
            session_id    => int($report->{session_id} || 0),
            system_action => $actor{system_action},
        ),
    ) if $status ne 'open';
    return $report;
}

sub _sync_channel_status {
    my ($self, $session) = @_;
    return unless $session;
    my $channel_status = ($session->{status} || '') eq 'live'
        ? 'live'
        : (($session->{status} || '') eq 'scheduled' ? 'scheduled' : 'offline');
    $self->{db}->dbh->do(
        'UPDATE live_stream_channels SET status = ?, updated_at = ? WHERE id = ?',
        undef,
        $channel_status,
        now(),
        int($session->{channel_id} || 0)
    );
}

sub _emit_stream_status_notification {
    my ($self, $session, $status, %actor) = @_;
    return unless $session;
    my %topic_for = (
        live   => 'stream.started',
        ended  => 'stream.ended',
        failed => 'stream.ingest_failed',
    );
    my $topic = $topic_for{$status || ''} or return;
    $self->_emit_notification(
        audience         => 'admin',
        topic            => $topic,
        module_key       => 'live_streaming',
        severity         => $status eq 'failed' ? 'critical' : 'info',
        title            => $status eq 'live' ? 'Stream started' : ($status eq 'ended' ? 'Stream ended' : 'Stream failed'),
        body             => $session->{channel_title} || $session->{title} || 'Live stream session update.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'live_stream_session',
        entity_id        => $session->{id},
        url              => '/admin/live',
        details          => _moderation_details(
            channel_id        => $session->{channel_id},
            status            => $status,
            worker_id         => $session->{worker_id} || '',
            last_heartbeat_at => $session->{last_heartbeat_at} || undef,
            system_action     => $actor{system_action},
        ),
    );
}

sub _emit_notification {
    my ($self, %args) = @_;
    my $bus = $self->{notifications};
    return undef unless $bus;
    my $ok = eval {
        ref($bus) eq 'CODE'
            ? $bus->(%args)
            : (ref($bus) && $bus->can('emit') ? $bus->emit(%args) : undef);
    };
    return $ok ? $ok : undef;
}

sub _mark_schedule_due_notified {
    my ($self, $session, $ts) = @_;
    return undef unless ref($session) eq 'HASH' && int($session->{id} || 0) > 0;
    $ts = _maybe_int($ts);
    $ts = now() unless defined $ts;
    my $details = ref($session->{ingest_detail}) eq 'HASH'
        ? { %{ $session->{ingest_detail} } }
        : _decode($session->{ingest_detail_json});
    $details->{schedule_due_notified_at} ||= $ts;
    $self->{db}->dbh->do(
        'UPDATE live_stream_sessions SET ingest_detail_json = ?, updated_at = ? WHERE id = ?',
        undef,
        encode_json($details),
        $ts,
        int($session->{id})
    );
    return $self->session_by_id($session->{id});
}

sub _active_account_or_die {
    my ($self, $account_id) = @_;
    my $account = $self->{db}->dbh->selectrow_hashref('SELECT id, username, display_name, status FROM user_accounts WHERE id = ?', undef, int($account_id || 0))
        or die "account was not found";
    die "account is not active" unless ($account->{status} || '') eq 'active';
    return $account;
}

sub _session_lifecycle_actor {
    my ($self, %args) = @_;
    my $moderator_id = int($args{moderator_account_id} || $args{account_id} || 0);
    if ($moderator_id > 0) {
        $self->_require_moderator($moderator_id);
        return (actor_account_id => $moderator_id);
    }
    my $admin_user_id = int($args{admin_user_id} || $args{actor_user_id} || 0);
    if ($admin_user_id > 0) {
        die "live session admin user is not active" unless $self->_admin_user_active($admin_user_id);
        return (actor_user_id => $admin_user_id);
    }
    my $system_action = _system_session_action($args{system_action});
    return (system_action => $system_action) if length $system_action;
    die "live session moderator account or active admin user is required";
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

sub _require_moderator {
    my ($self, $account_id) = @_;
    die "live chat moderator account is required" unless int($account_id || 0) > 0;
    $self->_active_account_or_die($account_id);
    die "live chat moderator permission required" unless $self->_is_moderator($account_id);
    return 1;
}

sub _moderation_actor {
    my ($self, %args) = @_;
    my $moderator_id = int($args{moderator_account_id} || $args{account_id} || 0);
    if ($moderator_id > 0) {
        $self->_require_moderator($moderator_id);
        return (actor_account_id => $moderator_id);
    }
    my $admin_user_id = int($args{admin_user_id} || $args{actor_user_id} || 0);
    if ($admin_user_id > 0) {
        die "live chat admin user is not active" unless $self->_admin_user_active($admin_user_id);
        return (actor_user_id => $admin_user_id);
    }
    my $system_action = _system_moderation_action($args{system_action});
    return (system_action => $system_action) if length $system_action;
    die "live chat moderator account or active admin user is required";
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

sub _enforce_chat_slow_mode {
    my ($self, %args) = @_;
    my $seconds = defined($args{seconds})
        ? _positive_int($args{seconds}, 0)
        : _positive_int($self->{config}->get('live_chat_slow_mode_seconds'), 0);
    return 1 if $seconds <= 0;
    my $session_id = int($args{session_id} || 0);
    my @where = ('session_id = ?', 'created_at >= ?', "status <> 'deleted'");
    my @bind = ($session_id, now() - $seconds);
    if (int($args{account_id} || 0) > 0) {
        push @where, 'account_id = ?';
        push @bind, int($args{account_id});
    } else {
        push @where, 'display_name = ?';
        push @bind, _clean_text($args{display_name}, 140);
    }
    my ($count) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM live_chat_messages WHERE ' . join(' AND ', @where),
        undef,
        @bind
    );
    die "live chat slow mode is active" if int($count || 0) > 0;
    return 1;
}

sub _enforce_chat_ip_rate_limit {
    my ($self, %args) = @_;
    my $ip_address = _clean_ip($args{ip_address});
    return 1 unless length $ip_address;
    my $window = _positive_int($self->{config}->get('live_chat_rate_window_seconds') || 60, 60);
    my $max = _positive_int($self->{config}->get('live_chat_max_messages_per_ip_window') || 30, 30);
    return 1 if $window <= 0 || $max <= 0;
    my ($count) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM live_chat_messages
            WHERE session_id = ?
              AND ip_address = ?
              AND status <> 'deleted'
              AND created_at >= ?
        },
        undef,
        int($args{session_id} || 0),
        $ip_address,
        now() - $window
    );
    die "live chat ip rate limit exceeded" if int($count || 0) >= $max;
    return 1;
}

sub _matching_blocked_term {
    my ($self, $body) = @_;
    my $needle = lc($body || '');
    return undef unless length $needle;
    for my $term (@{ $self->blocked_terms }) {
        next unless length($term->{term} || '');
        return $term if index($needle, lc($term->{term})) >= 0;
    }
    return undef;
}

sub _channel_status {
    my ($value) = @_;
    $value = lc($value || 'offline');
    return $CHANNEL_STATUS{$value} ? $value : 'offline';
}

sub _session_status {
    my ($value) = @_;
    $value = lc($value || 'scheduled');
    return $SESSION_STATUS{$value} ? $value : 'scheduled';
}

sub _session_status_or_undef {
    my ($value) = @_;
    return undef unless defined $value;
    $value = lc($value);
    return $SESSION_STATUS{$value} ? $value : undef;
}

sub _chat_status {
    my ($value) = @_;
    $value = lc($value || 'visible');
    return $CHAT_STATUS{$value} ? $value : 'visible';
}

sub _presence_status {
    my ($value) = @_;
    $value = lc($value || 'present');
    return $PRESENCE_STATUS{$value} ? $value : 'present';
}

sub _report_status {
    my ($value) = @_;
    $value = lc($value || 'open');
    return $REPORT_STATUS{$value} ? $value : 'open';
}

sub _system_moderation_action {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/[^a-z0-9_]+/_/g;
    return '' unless length $value;
    return $value if $value =~ /\Alive_chat_(?:blocked_term|report|automation)\z/;
    die "live chat system moderation action is invalid";
}

sub _system_session_action {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/[^a-z0-9_]+/_/g;
    return '' unless length $value;
    return $value if $value =~ /\Astream_(?:worker_heartbeat|session_automation|migration)\z/;
    die "live session system action is invalid";
}

sub _moderation_details {
    my (%details) = @_;
    delete $details{system_action} unless length($details{system_action} || '');
    return \%details;
}

sub _blocked_term_action {
    my ($value) = @_;
    $value = lc($value || 'report');
    return $BLOCKED_TERM_ACTION{$value} ? $value : 'report';
}

sub _worker_event_type {
    my ($value) = @_;
    $value = lc _clean_text($value || 'heartbeat', 80);
    $value =~ s/[^a-z0-9_.:-]+/_/g;
    $value =~ s/\A_+|_+\z//g;
    return length($value) ? $value : 'heartbeat';
}

sub _ingest_protocol {
    my ($value) = @_;
    $value = lc _clean_text($value || 'rtmp', 20);
    return $value =~ /\A(?:rtmp|rtmps|srt)\z/ ? $value : 'rtmp';
}

sub _ingest_app {
    my ($value) = @_;
    $value = _clean_text($value || 'live', 80);
    $value =~ s{[^A-Za-z0-9._~-]+}{}g;
    return length($value) ? $value : 'live';
}

sub _hls_prefix {
    my ($value) = @_;
    $value = _clean_path($value || '/streams') || '/streams';
    $value =~ s{/+\z}{};
    return $value if $value =~ m{\A/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]+\z};
    return '/streams';
}

sub _valid_hls_path {
    my ($value, $prefix) = @_;
    $prefix = _hls_prefix($prefix || '/streams');
    return 0 unless defined $value;
    return 0 if $value =~ m{\.\.|\\|//};
    return $value =~ m{\A\Q$prefix\E/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]+\.m3u8\z} ? 1 : 0;
}

sub _hls_path_or_die {
    my ($value, $prefix) = @_;
    $prefix = _hls_prefix($prefix || '/streams');
    $value = _clean_text($value, 500);
    die "HLS path must be a local $prefix/*.m3u8 path" unless _valid_hls_path($value, $prefix);
    return $value;
}

sub _worker_event_hls_path {
    my ($details, %args) = @_;
    $details = {} unless ref($details) eq 'HASH';
    my $channel = ref($args{channel}) eq 'HASH' ? $args{channel} : undef;
    my $session = ref($args{session}) eq 'HASH' ? $args{session} : undef;
    my $prefix = _hls_prefix($args{prefix} || '/streams');
    my $raw = _clean_text($args{hls_output_path} || $args{hls_path} || '', 500);
    if (length $raw) {
        return $raw if _valid_hls_path($raw, $prefix);
        $details->{hls_output_path_rejected} = 1;
        $details->{hls_output_path_reason} = 'invalid_public_hls_path';
    }
    for my $fallback (
        $session ? ($session->{hls_output_path} || '') : '',
        $session ? ($session->{hls_path} || '') : '',
        $channel ? ($channel->{hls_path} || '') : '',
    ) {
        my $clean = _clean_text($fallback, 500);
        return $clean if length($clean) && _valid_hls_path($clean, $prefix);
    }
    return '';
}

sub _clean_path {
    my ($value) = @_;
    $value = _clean_text($value, 500);
    return '' unless length $value;
    return $value =~ m{\A/[A-Za-z0-9._~!$&'()*+,;=:@/%?-]*\z} ? $value : '';
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

sub _clean_ip {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\A\s+|\s+\z//g;
    return substr($value, 0, 80);
}

sub _maybe_int {
    my ($value) = @_;
    return undef unless defined $value && "$value" =~ /\A[0-9]+\z/;
    return int($value);
}

sub _nonnegative_int {
    my ($value, $default) = @_;
    $value = $default unless defined $value && "$value" =~ /\A[0-9]+\z/;
    return int($value || 0);
}

sub _positive_int {
    my ($value, $default) = @_;
    $value = $default unless defined $value && "$value" =~ /\A[0-9]+\z/;
    $value = int($value || 0);
    return $value < 0 ? 0 : $value;
}

sub _permission {
    my ($allowed, $reason) = @_;
    return ($allowed ? 1 : 0, $reason || '');
}

sub _limit {
    my ($value, $default, $min, $max) = @_;
    $value = $default unless defined $value && $value =~ /\A[0-9]+\z/;
    $value = int($value);
    $value = $min if $value < $min;
    $value = $max if $value > $max;
    return $value;
}

sub _decode {
    my ($value) = @_;
    my $decoded = eval { decode_json($value || '{}') };
    return $decoded && ref($decoded) eq 'HASH' ? $decoded : {};
}

sub _url_host {
    my ($url) = @_;
    $url ||= '';
    return $1 if $url =~ m{\Ahttps?://([^/:/?#]+)}i;
    return '';
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

1;
