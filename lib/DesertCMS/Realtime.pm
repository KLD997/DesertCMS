package DesertCMS::Realtime;

use strict;
use warnings;
use Digest::SHA qw(sha1);
use Fcntl qw(:DEFAULT :flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(encode_base64);
use DesertCMS::Util qw(hmac_sha256_hex constant_time_eq);

sub manifest {
    return {
        service_name => 'desertcms-realtime',
        runtime      => 'perl',
        protocols    => [qw(sse websocket)],
        openbsd      => {
            required_base => [qw(pf httpd acme-client)],
            preferred_rc  => '/etc/rc.d/desertcms_realtime',
            bind_default  => '127.0.0.1',
        },
        channels     => [qw(admin.notifications public.notifications user.notifications live.chat live.presence stream.presence dashboard.widgets)],
        scope        => 'notifications, live chat, chat presence, stream presence, and dashboard updates only',
    };
}

sub service_status {
    my ($class, $config) = @_;
    my $enabled = _truthy(_config_get($config, 'realtime_enabled'));
    my $host = _config_get($config, 'realtime_bind_host') || '127.0.0.1';
    my $port = int(_config_get($config, 'realtime_port') || 8787);
    my $public_url = $class->normalize_public_url(_config_get($config, 'realtime_public_url') || '');
    my $events_url = length($public_url) ? $public_url : "http://$host:$port/events";
    my $websocket_url = $events_url;
    $websocket_url =~ s{/events\z}{/ws};
    $websocket_url =~ s{\Ahttps://}{wss://}i;
    $websocket_url =~ s{\Ahttp://}{ws://}i;
    return {
        enabled       => $enabled ? 1 : 0,
        host          => $host,
        port          => $port,
        url           => $events_url,
        events_url    => $events_url,
        websocket_url => $websocket_url,
    };
}

sub allowed_origins {
    my ($class, $config, %args) = @_;
    my %allowed;
    for my $origin (
        _origin_from_url(_config_get($config, 'site_url') || ''),
        _split_origins(_config_get($config, 'realtime_allowed_origins') || ''),
    ) {
        my $normalized = _normalize_origin($origin);
        $allowed{$normalized} = 1 if length $normalized;
    }
    my $host_header = _clean_host_header($args{host_header} || '');
    if (length($host_header) && _is_loopback_host_header($host_header)) {
        $allowed{"http://$host_header"} = 1;
        $allowed{"https://$host_header"} = 1;
    }
    my $status = $class->service_status($config);
    my $service_host = _clean_host_header(($status->{host} || '') . ':' . int($status->{port} || 8787));
    if (length $service_host) {
        $allowed{"http://$service_host"} = 1;
        $allowed{"https://$service_host"} = 1;
        if ($service_host =~ /\A127\.0\.0\.1:(\d+)\z/) {
            $allowed{"http://localhost:$1"} = 1;
            $allowed{"https://localhost:$1"} = 1;
        }
    }
    return [ sort keys %allowed ];
}

sub origin_allowed {
    my ($class, $config, $origin, %args) = @_;
    $origin = '' unless defined $origin;
    $origin =~ s/^\s+|\s+\z//g;
    return 1 unless length $origin;
    my $normalized = _normalize_origin($origin);
    return 0 unless length $normalized;
    my %allowed = map { $_ => 1 } @{ $class->allowed_origins($config, %args) };
    return $allowed{$normalized} ? 1 : 0;
}

sub cors_headers {
    my ($class, $config, $origin, %args) = @_;
    $origin = '' unless defined $origin;
    $origin =~ s/^\s+|\s+\z//g;
    return "Vary: Origin\r\n" unless length $origin;
    return "Vary: Origin\r\n" unless $class->origin_allowed($config, $origin, %args);
    my $normalized = _normalize_origin($origin);
    return "Vary: Origin\r\n" unless length $normalized;
    return "Access-Control-Allow-Origin: $normalized\r\nAccess-Control-Allow-Credentials: true\r\nVary: Origin\r\n";
}

sub normalize_allowed_origins {
    my ($class, $value) = @_;
    my @origins;
    my %seen;
    for my $origin (_split_origins($value || '')) {
        my $normalized = _normalize_origin($origin);
        die "realtime origin must be an http:// or https:// origin"
            unless length $normalized;
        next if $seen{$normalized}++;
        push @origins, $normalized;
    }
    return join "\n", @origins;
}

sub normalize_public_url {
    my ($class, $value) = @_;
    return _normalize_public_url($value);
}

sub event_log_path {
    my ($class, $config) = @_;
    my $path = _config_get($config, 'realtime_event_log_path') || '';
    if (!length $path && $config) {
        my $data_dir = _config_get($config, 'data_dir') || '';
        $path = length($data_dir) ? "$data_dir/realtime-events.jsonl" : '';
    }
    return $path;
}

sub publish {
    my ($class, $config, $event) = @_;
    my $path = $class->event_log_path($config);
    die "realtime event log path is not configured" unless length $path;
    my $normalized = $class->normalize_event($event);
    make_path(dirname($path)) unless -d dirname($path);
    sysopen my $fh, $path, O_WRONLY | O_CREAT | O_APPEND
        or die "cannot open realtime event log: $!";
    flock($fh, LOCK_EX);
    print {$fh} encode_json($normalized) . "\n";
    close $fh;
    return { delivered => 1, path => $path, event => $normalized };
}

sub recent_events {
    my ($class, $config, %args) = @_;
    my $path = $class->event_log_path($config);
    return [] unless length($path) && -e $path;
    my $limit = int($args{limit} || 100);
    $limit = 1 if $limit < 1;
    $limit = 500 if $limit > 500;
    my $channel = $class->normalize_channel_filter($args{channel} || '');
    my @events;
    open my $fh, '<', $path or die "cannot read realtime event log: $!";
    while (defined(my $line = <$fh>)) {
        my $decoded = eval { decode_json($line) };
        next unless ref($decoded) eq 'HASH';
        my $event = eval { $class->normalize_event($decoded) };
        next unless $event;
        next unless _event_visible_for_filter($event->{channel} || '', $channel);
        push @events, $event;
        shift @events while @events > $limit;
    }
    close $fh;
    return \@events;
}

sub sse_prelude {
    my ($class, %args) = @_;
    my $retry = int($args{retry_ms} || 5000);
    $retry = 1000 if $retry < 1000;
    return ": DesertCMS realtime\nretry: $retry\n\n";
}

sub allowed_event_types {
    return [qw(
        admin.notification
        public.notification
        user.notification
        dashboard.widget
        stream.presence
        live.presence
        live.chat
    )];
}

sub allowed_channels {
    my ($class) = @_;
    my %channels;
    for my $channels (values %{ $class->event_channels }) {
        $channels{$_} = 1 for @{$channels || []};
    }
    return [ sort keys %channels ];
}

sub normalize_channel_filter {
    my ($class, $channel) = @_;
    $channel = _clean_channel($channel || '');
    return '' unless length $channel;
    die "realtime user notification channel must be account scoped" if $channel eq 'user.notifications';
    die "realtime channel filter is not allowed" unless _channel_allowed($class, $channel);
    return $channel;
}

sub channel_requires_token {
    my ($class, $channel) = @_;
    my $normalized = eval { $class->normalize_channel_filter($channel || '') };
    return 0 unless length($normalized || '');
    return $normalized =~ /\Auser\.notifications\.[0-9]+\z/ ? 1 : 0;
}

sub channel_token {
    my ($class, $config, %args) = @_;
    my $channel = $class->normalize_channel_filter($args{channel} || '');
    die "realtime channel token requires a protected channel"
        unless $class->channel_requires_token($channel);
    my $ttl = int($args{ttl_seconds} || 900);
    $ttl = 60 if $ttl < 60;
    $ttl = 3600 if $ttl > 3600;
    my $expires = int($args{expires_at} || (time + $ttl));
    my $secret = _config_app_secret($config);
    die "realtime channel token secret is not configured" unless length $secret;
    return $expires . ':' . _channel_token_signature($secret, $channel, $expires);
}

sub channel_token_valid {
    my ($class, $config, %args) = @_;
    my $channel = eval { $class->normalize_channel_filter($args{channel} || '') };
    return 0 unless length($channel || '') && $class->channel_requires_token($channel);
    my $token = $args{token} || '';
    return 0 unless $token =~ /\A([0-9]{9,12}):([0-9a-f]{64})\z/;
    my ($expires, $sig) = ($1, $2);
    return 0 if int($expires) < int($args{now} || time);
    my $secret = eval { _config_app_secret($config) } || '';
    return 0 unless length $secret;
    return constant_time_eq(_channel_token_signature($secret, $channel, $expires), $sig) ? 1 : 0;
}

sub channel_request_authorized {
    my ($class, $config, %args) = @_;
    my $channel = eval { $class->normalize_channel_filter($args{channel} || '') };
    return 1 unless length($channel || '') && $class->channel_requires_token($channel);
    return $class->channel_token_valid($config, channel => $channel, token => $args{token}, now => $args{now});
}

sub event_channels {
    return {
        'admin.notification'  => [ 'admin.notifications' ],
        'public.notification' => [ 'public.notifications' ],
        'user.notification'   => [ 'user.notifications' ],
        'dashboard.widget'    => [ 'dashboard.widgets' ],
        'stream.presence'     => [ 'stream.presence' ],
        'live.presence'       => [ 'live.presence' ],
        'live.chat'           => [ 'live.chat' ],
    };
}

sub normalize_event {
    my ($class, $event) = @_;
    die "realtime event must be a hash" unless ref($event) eq 'HASH';
    my $type = $event->{type} || '';
    my %allowed = map { $_ => 1 } @{ $class->allowed_event_types };
    die "realtime event type is not allowed" unless $allowed{$type};
    my $data = ref($event->{data}) eq 'HASH' ? $event->{data} : {};
    my $channel = _clean_channel($event->{channel} || _default_channel($type));
    if ($type eq 'user.notification') {
        my $recipient_account_id = int($data->{recipient_account_id} || 0);
        die "realtime user notification recipient account is required" unless $recipient_account_id > 0;
        my $expected = 'user.notifications.' . $recipient_account_id;
        die "realtime user notification channel must be account scoped"
            if length($event->{channel} || '') && $channel ne $expected;
        $channel = $expected;
    }
    die "realtime event channel is not allowed" unless _event_channel_allowed($class, $type, $channel);
    return {
        id         => _clean_id($event->{id} || _event_id()),
        type       => $type,
        channel    => $channel,
        data       => $data,
        created_at => int($event->{created_at} || time),
    };
}

sub notification_event {
    my ($class, $notification) = @_;
    $notification ||= {};
    my $audience = ($notification->{audience} || 'admin') eq 'user'
        ? 'user'
        : (($notification->{audience} || '') eq 'public' ? 'public' : 'admin');
    my $event_type = $audience . '.notification';
    my $channel = $audience . '.notifications';
    $channel .= '.' . int($notification->{recipient_account_id} || 0) if $audience eq 'user';
    my $details = _notification_details($notification);
    return {
        type    => $event_type,
        channel => $channel,
        data    => {
            id          => int($notification->{id} || 0),
            audience    => $audience,
            topic       => $notification->{topic} || '',
            module_key  => $notification->{module_key} || '',
            severity    => $notification->{severity} || 'info',
            title       => $notification->{title} || '',
            body        => $notification->{body} || '',
            url         => $notification->{url} || '',
            actor_user_id        => int($notification->{actor_user_id} || 0),
            actor_account_id     => int($notification->{actor_account_id} || 0),
            recipient_user_id    => int($notification->{recipient_user_id} || 0),
            recipient_account_id => int($notification->{recipient_account_id} || 0),
            entity_type => $notification->{entity_type} || '',
            entity_id   => $notification->{entity_id} || '',
            created_at  => int($notification->{created_at} || 0),
            details     => $details,
        },
    };
}

sub sse_event {
    my ($class, $event) = @_;
    $event = $class->normalize_event($event || { type => 'admin.notification' });
    my $id = length($event->{id} || '') ? 'id: ' . $event->{id} . "\n" : '';
    return $id
        . 'event: ' . $event->{type} . "\n"
        . 'data: ' . encode_json($event->{data} || {}) . "\n\n";
}

sub websocket_accept_key {
    my ($class, $client_key) = @_;
    $client_key = '' unless defined $client_key;
    $client_key =~ s/[\r\n]+//g;
    die "websocket client key is required"
        unless $client_key =~ /\A[A-Za-z0-9+\/=]{16,80}\z/;
    return encode_base64(sha1($client_key . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
}

sub websocket_snapshot_payload {
    my ($class, $config, %args) = @_;
    my $events = $class->recent_events(
        $config,
        channel => $args{channel} || '',
        limit   => $args{limit} || 100,
    );
    $events = [
        $class->normalize_event({
            type    => 'dashboard.widget',
            channel => 'dashboard.widgets',
            data    => { status => 'ready' },
        }),
    ] unless @{$events};
    return encode_json({ events => $events });
}

sub websocket_text_frame {
    my ($class, $text) = @_;
    $text = '' unless defined $text;
    my $length;
    {
        use bytes;
        $length = length($text);
    }
    die "websocket payload is too large" if $length > 65_535;
    my $header = $length < 126
        ? pack('C C', 0x81, $length)
        : pack('C C n', 0x81, 126, $length);
    return $header . $text;
}

sub websocket_snapshot_frame {
    my ($class, $config, %args) = @_;
    return $class->websocket_text_frame($class->websocket_snapshot_payload($config, %args));
}

sub _default_channel {
    my ($type) = @_;
    return 'admin.notifications' if $type eq 'admin.notification';
    return 'public.notifications' if $type eq 'public.notification';
    return 'user.notifications' if $type eq 'user.notification';
    return $type || 'admin.notification';
}

sub _event_channel_allowed {
    my ($class, $type, $channel) = @_;
    return $channel =~ /\Auser\.notifications\.[0-9]+\z/ ? 1 : 0 if $type eq 'user.notification';
    for my $base (@{ $class->event_channels->{$type} || [] }) {
        return 1 if $channel eq $base;
        return 1 if _scoped_channel_allowed($base, $channel);
    }
    return 0;
}

sub _channel_allowed {
    my ($class, $channel) = @_;
    return 0 if $channel eq 'user.notifications';
    for my $base (@{ $class->allowed_channels }) {
        return 1 if $channel eq $base;
        return 1 if _scoped_channel_allowed($base, $channel);
    }
    return 0;
}

sub _scoped_channel_allowed {
    my ($base, $channel) = @_;
    return 0 unless $base =~ /\A(?:user\.notifications|live\.chat|live\.presence|stream\.presence)\z/;
    return $channel =~ /\A\Q$base\E\.[0-9]+\z/ ? 1 : 0;
}

sub _event_visible_for_filter {
    my ($event_channel, $filter) = @_;
    return _channel_matches_filter($event_channel, $filter) if length($filter || '');
    return 0 if $event_channel =~ /\Auser\.notifications\.[0-9]+\z/;
    return 1;
}

sub _channel_matches_filter {
    my ($event_channel, $filter) = @_;
    return 1 if $event_channel eq $filter;
    return 1 if $filter =~ /\A(?:live\.chat|live\.presence|stream\.presence)\z/
        && $event_channel =~ /\A\Q$filter\E\.[0-9]+\z/;
    return 0;
}

sub _channel_token_signature {
    my ($secret, $channel, $expires) = @_;
    return hmac_sha256_hex('realtime-channel:' . ($channel || '') . ':' . int($expires || 0), $secret || '');
}

sub _notification_details {
    my ($notification) = @_;
    return { %{ $notification->{details} } } if ref($notification->{details}) eq 'HASH';
    my $json = $notification->{details_json};
    return {} unless defined($json) && length($json);
    my $decoded = eval { decode_json($json) };
    return ref($decoded) eq 'HASH' ? $decoded : {};
}

sub _config_app_secret {
    my ($config) = @_;
    return '' unless $config;
    return $config->app_secret if ref($config) && $config->can('app_secret');
    return _config_get($config, 'app_secret') || '';
}

sub _event_id {
    return join '-', time, $$, int(rand(1_000_000));
}

sub _clean_id {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/[^A-Za-z0-9_.:-]+/-/g;
    $value =~ s/\A-+|-+\z//g;
    return $value;
}

sub _clean_channel {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/[^A-Za-z0-9_.:-]+/-/g;
    $value =~ s/\A-+|-+\z//g;
    return $value;
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _config_get {
    my ($config, $key) = @_;
    return '' unless $config && length($key || '');
    return $config->{$key} if ref($config) eq 'HASH';
    return $config->get($key) if ref($config) && $config->can('get');
    return '';
}

sub _split_origins {
    my ($value) = @_;
    $value = '' unless defined $value;
    return grep { length } split /[\s,]+/, $value;
}

sub _origin_from_url {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return '' unless $value =~ m{\Ahttps?://}i;
    return $1 if $value =~ m{\A(https?://[^/?#]+)}i;
    return '';
}

sub _normalize_origin {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return '' unless $value =~ m{\A(https?)://([^/?#]+)\z}i;
    my $scheme = lc($1);
    my $host = _clean_host_header($2);
    return '' unless length $host;
    return "$scheme://$host";
}

sub _normalize_public_url {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return '' unless length $value;
    die "realtime public URL must be an http:// or https:// URL\n"
        unless $value =~ m{\Ahttps?://}i;
    die "realtime public URL must not include whitespace\n"
        if $value =~ /\s/;
    die "realtime public URL must not include userinfo, query, or fragment\n"
        if $value =~ m{\Ahttps?://[^/?#]*@}i || $value =~ /[?#]/;
    $value =~ s{/+\z}{};
    $value .= '/events' if $value =~ m{\Ahttps?://[^/]+\z}i;
    return $value;
}

sub _clean_host_header {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return '' unless length $value;
    return '' if $value =~ /[\r\n\/\\]/;
    return '' unless $value =~ /\A(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9_.-]+)(?::\d{1,5})?\z/;
    return lc $value;
}

sub _is_loopback_host_header {
    my ($value) = @_;
    $value =~ s/:\d+\z//;
    return 1 if $value eq 'localhost' || $value eq '127.0.0.1' || $value eq '[::1]';
    return 0;
}

1;
