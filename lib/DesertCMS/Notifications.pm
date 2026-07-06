package DesertCMS::Notifications;

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use DesertCMS::ModuleManifest ();
use DesertCMS::Realtime ();
use DesertCMS::Settings ();
use DesertCMS::Util qw(now);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config           => $args{config},
        db               => $args{db},
        realtime_adapter => $args{realtime_adapter},
        delivery_adapters => ref($args{delivery_adapters}) eq 'HASH' ? { %{ $args{delivery_adapters} } } : {},
    }, $class;
}

sub set_adapter {
    my ($self, $channel, $adapter) = @_;
    $channel = _delivery_channel($channel || '');
    die "notification adapter must be a code reference" if defined($adapter) && ref($adapter) ne 'CODE';
    if ($channel eq 'realtime') {
        $self->{realtime_adapter} = $adapter;
    } elsif ($adapter) {
        $self->{delivery_adapters}{$channel} = $adapter;
    } else {
        delete $self->{delivery_adapters}{$channel};
    }
    return 1;
}

sub topics {
    my ($self) = @_;
    my $settings = eval { DesertCMS::Settings::all($self->{config}, $self->{db}) } || {};
    my %topics;
    for my $topic (@{ DesertCMS::ModuleManifest::notification_topics(settings => $settings, config => $self->{config}) }) {
        $topics{$topic} = 1 if defined $topic && length $topic;
    }
    return [ sort keys %topics ];
}

sub emit {
    my ($self, %args) = @_;
    my $audience = _enum($args{audience}, [qw(admin public user)], 'admin');
    my $severity = _enum($args{severity}, [qw(info success warning critical)], 'info');
    my $topic = _clean_key($args{topic} || 'system.notice');
    my $module_key = _clean_key($args{module_key} || '');
    my $title = _clean_text($args{title}, 160);
    my $body = _clean_text($args{body}, 4000);
    die "notification title is required" unless length $title;
    die "notification topic is not registered in any module manifest" unless $self->topic_registered($topic);
    die "notification topic is not registered for the module manifest"
        if length($module_key) && !$self->module_topic_registered($module_key, $topic);
    die "user notification recipient account is required"
        if $audience eq 'user' && int($args{recipient_account_id} || 0) <= 0;
    die "user notification recipient account is not active"
        if $audience eq 'user' && !$self->_recipient_account_active($args{recipient_account_id});

    my $ts = now();
    my $details_json = _json($args{details});
    my $dbh = $self->{db}->dbh;
    my $in_app_enabled = $self->preference_enabled(
        audience             => $audience,
        recipient_user_id    => $args{recipient_user_id},
        recipient_account_id => $args{recipient_account_id},
        topic                => $topic,
        delivery_channel     => 'in_app',
    );
    $dbh->do(
        q{
            INSERT INTO notifications
                (audience, scope_key, topic, module_key, severity, title, body,
                 actor_user_id, actor_account_id, recipient_user_id, recipient_account_id,
                 entity_type, entity_id, url, status, details_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $audience,
        _clean_text($args{scope_key}, 120),
        $topic,
        $module_key,
        $severity,
        $title,
        $body,
        _maybe_int($args{actor_user_id}),
        _maybe_int($args{actor_account_id}),
        _maybe_int($args{recipient_user_id}),
        _maybe_int($args{recipient_account_id}),
        _clean_key($args{entity_type} || ''),
        _clean_text($args{entity_id}, 120),
        _clean_url($args{url}),
        $in_app_enabled ? 'unread' : 'archived',
        $details_json,
        $ts,
    );
    my $id = $dbh->last_insert_id('', '', 'notifications', '');
    my $notification = $self->get($id);
    my @channels = _delivery_channels($args{delivery_channels}, $self->{config}, $args{realtime_adapter} || $self->{realtime_adapter});
    for my $channel (@channels) {
        if (!$self->preference_enabled(
            audience             => $audience,
            recipient_user_id    => $args{recipient_user_id},
            recipient_account_id => $args{recipient_account_id},
            topic                => $topic,
            delivery_channel     => $channel,
        )) {
            $self->record_delivery(
                notification_id  => $id,
                delivery_channel => $channel,
                status           => 'skipped',
                last_error       => 'disabled by notification preference',
            );
            next;
        }
        if ($channel eq 'in_app') {
            $self->record_delivery(
                notification_id  => $id,
                delivery_channel => 'in_app',
                status           => $in_app_enabled ? 'delivered' : 'skipped',
                last_error       => $in_app_enabled ? '' : 'disabled by notification preference',
            );
            next;
        }
        if ($channel eq 'realtime') {
            $self->_deliver_realtime($notification, adapter => $args{realtime_adapter});
            next;
        }
        if (my $adapter = $args{$channel . '_adapter'} || $self->{delivery_adapters}{$channel}) {
            $self->_deliver_adapter($notification, channel => $channel, adapter => $adapter);
            next;
        }
        $self->record_delivery(
            notification_id  => $id,
            delivery_channel => $channel,
            status           => 'queued',
            last_error       => 'adapter not configured',
            attempts         => 0,
            next_retry_at    => now() + 300,
        );
    }
    $notification->{deliveries} = $self->deliveries(notification_id => $id);
    return $notification;
}

sub get {
    my ($self, $id) = @_;
    return undef unless $id;
    return $self->{db}->dbh->selectrow_hashref(
        q{SELECT * FROM notifications WHERE id = ?},
        undef,
        int($id)
    );
}

sub list {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 50);
    $limit = 1 if $limit < 1;
    $limit = 200 if $limit > 200;
    my @where;
    my @bind;
    my $audience = length($args{audience} || '') ? _enum($args{audience}, [qw(admin public user)], 'admin') : '';
    _require_user_recipient_scope('list', %args, audience => $audience) if length $audience;
    if (length $audience) {
        push @where, 'audience = ?';
        push @bind, $audience;
    }
    if (length($args{status} || '')) {
        push @where, 'status = ?';
        push @bind, _enum($args{status}, [qw(unread read archived)], 'unread');
    } elsif (!$args{include_archived}) {
        push @where, "status <> 'archived'";
    }
    if (length($args{module_key} || '')) {
        push @where, 'module_key = ?';
        push @bind, _clean_key($args{module_key});
    }
    if (length($args{topic} || '')) {
        push @where, 'topic = ?';
        push @bind, _clean_key($args{topic});
    }
    if (int($args{recipient_user_id} || 0) > 0) {
        push @where, 'recipient_user_id = ?';
        push @bind, int($args{recipient_user_id});
    }
    if (int($args{recipient_account_id} || 0) > 0) {
        push @where, 'recipient_account_id = ?';
        push @bind, int($args{recipient_account_id});
    }
    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT *
            FROM notifications
            $where_sql
            ORDER BY created_at DESC, id DESC
            LIMIT $limit
        },
        { Slice => {} },
        @bind
    );
}

sub inbox_for_account {
    my ($self, $account_id, %args) = @_;
    die "recipient account id is required" unless int($account_id || 0) > 0;
    return $self->list(%args, audience => 'user', recipient_account_id => int($account_id));
}

sub inbox_for_user {
    my ($self, $user_id, %args) = @_;
    die "recipient user id is required" unless int($user_id || 0) > 0;
    return $self->list(%args, audience => 'admin', recipient_user_id => int($user_id));
}

sub topic_registered {
    my ($self, $topic) = @_;
    $topic = _clean_key($topic);
    my %topics = map { $_ => 1 } @{ $self->topics };
    return $topics{$topic} ? 1 : 0;
}

sub module_topic_registered {
    my ($self, $module_key, $topic) = @_;
    $module_key = _clean_key($module_key);
    $topic = _clean_key($topic);
    return 0 unless length($module_key) && length($topic);
    my $settings = eval { DesertCMS::Settings::all($self->{config}, $self->{db}) } || {};
    my $manifest = DesertCMS::ModuleManifest::manifest($module_key, settings => $settings, config => $self->{config});
    return 0 unless $manifest && ref($manifest->{notifications}) eq 'ARRAY';
    return (grep { defined($_) && $_ eq $topic } @{ $manifest->{notifications} }) ? 1 : 0;
}

sub _recipient_account_active {
    my ($self, $account_id) = @_;
    return 0 unless int($account_id || 0) > 0;
    my ($active) = $self->{db}->dbh->selectrow_array(
        q{SELECT 1 FROM user_accounts WHERE id = ? AND status = 'active' LIMIT 1},
        undef,
        int($account_id)
    );
    return $active ? 1 : 0;
}

sub _require_user_recipient_scope {
    my ($operation, %args) = @_;
    return unless ($args{audience} || '') eq 'user';
    die "user notification $operation recipient account is required"
        if int($args{recipient_account_id} || 0) <= 0;
}

sub set_preference {
    my ($self, %args) = @_;
    my $audience = _enum($args{audience}, [qw(admin public user)], 'admin');
    die "user notification preference recipient account is required"
        if $audience eq 'user' && int($args{recipient_account_id} || 0) <= 0;
    die "user notification preference recipient account is not active"
        if $audience eq 'user' && !$self->_recipient_account_active($args{recipient_account_id});
    my $topic = _clean_key($args{topic});
    die "notification topic is not registered in any module manifest" unless $self->topic_registered($topic);
    my $channel = _delivery_channel($args{delivery_channel} || 'in_app');
    my $ts = now();
    my ($recipient_where, @recipient_bind) = _recipient_preference_where(
        recipient_user_id    => $args{recipient_user_id},
        recipient_account_id => $args{recipient_account_id},
    );
    my $changed = $self->{db}->dbh->do(
        qq{
            UPDATE notification_preferences
            SET enabled = ?, updated_at = ?
            WHERE audience = ?
              AND $recipient_where
              AND topic = ?
              AND delivery_channel = ?
        },
        undef,
        $args{enabled} ? 1 : 0,
        $ts,
        $audience,
        @recipient_bind,
        $topic,
        $channel
    );
    if (int($changed || 0) <= 0) {
        $self->{db}->dbh->do(
            q{
                INSERT INTO notification_preferences
                    (audience, recipient_user_id, recipient_account_id, topic, delivery_channel, enabled, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $audience,
            _maybe_int($args{recipient_user_id}),
            _maybe_int($args{recipient_account_id}),
            $topic,
            $channel,
            $args{enabled} ? 1 : 0,
            $ts,
            $ts
        );
    }
    return $self->preference(
        audience             => $audience,
        recipient_user_id    => $args{recipient_user_id},
        recipient_account_id => $args{recipient_account_id},
        topic                => $topic,
        delivery_channel     => $channel,
    );
}

sub preference {
    my ($self, %args) = @_;
    my ($recipient_where, @recipient_bind) = _recipient_preference_where(
        recipient_user_id    => $args{recipient_user_id},
        recipient_account_id => $args{recipient_account_id},
    );
    return $self->{db}->dbh->selectrow_hashref(
        qq{
            SELECT *
            FROM notification_preferences
            WHERE audience = ?
              AND $recipient_where
              AND topic = ?
              AND delivery_channel = ?
            ORDER BY updated_at DESC, id DESC
            LIMIT 1
        },
        undef,
        _enum($args{audience}, [qw(admin public user)], 'admin'),
        @recipient_bind,
        _clean_key($args{topic}),
        _delivery_channel($args{delivery_channel} || 'in_app')
    );
}

sub _recipient_preference_where {
    my (%args) = @_;
    my @where;
    my @bind;
    for my $field (qw(recipient_user_id recipient_account_id)) {
        my $id = int($args{$field} || 0);
        if ($id > 0) {
            push @where, "$field = ?";
            push @bind, $id;
        } else {
            push @where, "$field IS NULL";
        }
    }
    return (join(' AND ', @where), @bind);
}

sub preference_enabled {
    my ($self, %args) = @_;
    my $pref = $self->preference(%args);
    return 1 unless $pref;
    return $pref->{enabled} ? 1 : 0;
}

sub record_delivery {
    my ($self, %args) = @_;
    my $notification_id = int($args{notification_id} || 0);
    die "notification id is required" unless $notification_id > 0;
    my $delivery_id = int($args{delivery_id} || 0);
    my $channel = _delivery_channel($args{delivery_channel} || 'in_app');
    my $status = _enum($args{status}, [qw(queued delivered failed skipped)], 'queued');
    my $attempts = defined($args{attempts}) ? int($args{attempts}) : ($status eq 'delivered' || $status eq 'failed' ? 1 : 0);
    my $ts = now();
    if ($delivery_id > 0) {
        my $changed = $self->{db}->dbh->do(
            q{
                UPDATE notification_deliveries
                SET status = ?,
                    attempts = attempts + ?,
                    last_error = ?,
                    adapter_response_json = ?,
                    updated_at = ?,
                    next_retry_at = ?
                WHERE id = ? AND notification_id = ?
            },
            undef,
            $status,
            $attempts,
            _clean_text($args{last_error}, 500),
            _json($args{adapter_response} || {}),
            $ts,
            _maybe_int($args{next_retry_at}),
            $delivery_id,
            $notification_id
        );
        die "notification delivery was not found" unless int($changed || 0) > 0;
        return $self->{db}->dbh->selectrow_hashref(
            'SELECT * FROM notification_deliveries WHERE id = ? AND notification_id = ?',
            undef,
            $delivery_id,
            $notification_id
        );
    }
    $self->{db}->dbh->do(
        q{
            INSERT INTO notification_deliveries
                (notification_id, delivery_channel, status, attempts, last_error, adapter_response_json, created_at, updated_at, next_retry_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $notification_id,
        $channel,
        $status,
        $attempts,
        _clean_text($args{last_error}, 500),
        _json($args{adapter_response} || {}),
        $ts,
        $ts,
        _maybe_int($args{next_retry_at})
    );
    my $id = $self->{db}->dbh->last_insert_id('', '', 'notification_deliveries', '');
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM notification_deliveries WHERE id = ?', undef, $id);
}

sub deliveries {
    my ($self, %args) = @_;
    my $notification_id = int($args{notification_id} || 0);
    return [] unless $notification_id > 0;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM notification_deliveries
            WHERE notification_id = ?
            ORDER BY created_at ASC, id ASC
        },
        { Slice => {} },
        $notification_id
    );
}

sub retryable_deliveries {
    my ($self, %args) = @_;
    my $now = defined($args{now}) ? int($args{now}) : now();
    my $limit = int($args{limit} || 50);
    $limit = 1 if $limit < 1;
    $limit = 200 if $limit > 200;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT d.*, n.audience, n.topic, n.module_key, n.recipient_user_id, n.recipient_account_id
            FROM notification_deliveries d
            JOIN notifications n ON n.id = d.notification_id
            WHERE d.status IN ('queued', 'failed')
              AND COALESCE(d.next_retry_at, 0) <= ?
            ORDER BY COALESCE(d.next_retry_at, d.created_at) ASC, d.id ASC
            LIMIT $limit
        },
        { Slice => {} },
        $now
    );
}

sub retry_delivery {
    my ($self, %args) = @_;
    my $delivery_id = int($args{delivery_id} || $args{id} || 0);
    die "delivery id is required" unless $delivery_id > 0;
    my $delivery = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT d.*, n.audience, n.scope_key, n.topic, n.module_key, n.severity, n.title, n.body,
                   n.actor_user_id, n.actor_account_id, n.recipient_user_id, n.recipient_account_id,
                   n.entity_type, n.entity_id, n.url, n.status AS notification_status, n.details_json, n.created_at AS notification_created_at
            FROM notification_deliveries d
            JOIN notifications n ON n.id = d.notification_id
            WHERE d.id = ?
        },
        undef,
        $delivery_id
    ) or die "notification delivery was not found";
    my $channel = _delivery_channel($delivery->{delivery_channel});
    die "notification delivery is not retryable" unless ($delivery->{status} || '') =~ /\A(?:queued|failed)\z/;
    my $notification = {
        id                   => int($delivery->{notification_id}),
        audience             => $delivery->{audience},
        scope_key            => $delivery->{scope_key},
        topic                => $delivery->{topic},
        module_key           => $delivery->{module_key},
        severity             => $delivery->{severity},
        title                => $delivery->{title},
        body                 => $delivery->{body},
        actor_user_id        => $delivery->{actor_user_id},
        actor_account_id     => $delivery->{actor_account_id},
        recipient_user_id    => $delivery->{recipient_user_id},
        recipient_account_id => $delivery->{recipient_account_id},
        entity_type          => $delivery->{entity_type},
        entity_id            => $delivery->{entity_id},
        url                  => $delivery->{url},
        status               => $delivery->{notification_status},
        details_json         => $delivery->{details_json},
        created_at           => $delivery->{notification_created_at},
    };
    if (($notification->{audience} || '') eq 'user' && !$self->_recipient_account_active($notification->{recipient_account_id})) {
        return $self->record_delivery(
            delivery_id      => $delivery_id,
            notification_id  => $notification->{id},
            delivery_channel => $channel,
            status           => 'skipped',
            last_error       => 'user notification recipient account is not active',
        );
    }
    if (!$self->preference_enabled(
        audience             => $notification->{audience},
        recipient_user_id    => $notification->{recipient_user_id},
        recipient_account_id => $notification->{recipient_account_id},
        topic                => $notification->{topic},
        delivery_channel     => $channel,
    )) {
        return $self->record_delivery(
            delivery_id      => $delivery_id,
            notification_id  => $notification->{id},
            delivery_channel => $channel,
            status           => 'skipped',
            last_error       => 'disabled by notification preference',
        );
    }
    if ($channel eq 'realtime') {
        return $self->_deliver_realtime($notification, adapter => $args{realtime_adapter}, delivery_id => $delivery_id);
    }
    my $adapter = $args{adapter} || $args{$channel . '_adapter'} || $self->{delivery_adapters}{$channel};
    if ($adapter) {
        return $self->_deliver_adapter($notification, channel => $channel, adapter => $adapter, delivery_id => $delivery_id);
    }
    return $self->record_delivery(
        delivery_id      => $delivery_id,
        notification_id  => $notification->{id},
        delivery_channel => $channel,
        status           => 'queued',
        last_error       => 'adapter not configured',
        attempts         => 0,
        next_retry_at    => now() + 300,
    );
}

sub retry_due_deliveries {
    my ($self, %args) = @_;
    my $due = $self->retryable_deliveries(now => $args{now}, limit => $args{limit});
    my @results;
    for my $delivery (@{$due}) {
        my $result = eval { $self->retry_delivery(delivery_id => $delivery->{id}, %args) };
        if ($result) {
            push @results, $result;
        } else {
            my $error = $@ || 'retry failed';
            my $failed = eval {
                $self->record_delivery(
                    delivery_id      => int($delivery->{id} || 0),
                    notification_id  => int($delivery->{notification_id} || 0),
                    delivery_channel => $delivery->{delivery_channel} || '',
                    status           => 'failed',
                    last_error       => $error,
                    next_retry_at    => now() + 300,
                );
            };
            push @results, $failed || {
                id               => int($delivery->{id} || 0),
                notification_id  => int($delivery->{notification_id} || 0),
                delivery_channel => $delivery->{delivery_channel} || '',
                status           => 'failed',
                last_error       => $error,
            };
        }
    }
    return \@results;
}

sub unread_count {
    my ($self, %args) = @_;
    my @where = q{status = 'unread'};
    my @bind;
    my $audience = length($args{audience} || '') ? _enum($args{audience}, [qw(admin public user)], 'admin') : '';
    _require_user_recipient_scope('unread_count', %args, audience => $audience) if length $audience;
    if (length $audience) {
        push @where, 'audience = ?';
        push @bind, $audience;
    }
    if (int($args{recipient_user_id} || 0) > 0) {
        push @where, 'recipient_user_id = ?';
        push @bind, int($args{recipient_user_id});
    }
    if (int($args{recipient_account_id} || 0) > 0) {
        push @where, 'recipient_account_id = ?';
        push @bind, int($args{recipient_account_id});
    }
    my ($count) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM notifications WHERE ' . join(' AND ', @where),
        undef,
        @bind
    );
    return int($count || 0);
}

sub mark_read {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    return 0 unless $id;
    die "notification mark_read audience is required" unless length($args{audience} || '');
    my $audience = _enum($args{audience}, [qw(admin public user)], 'admin');
    die "user notification mark_read recipient account is required"
        if $audience eq 'user' && int($args{recipient_account_id} || 0) <= 0;
    my @where = ('id = ?', q{status = 'unread'});
    my @bind = ($id);
    push @where, 'audience = ?';
    push @bind, $audience;
    if (int($args{recipient_user_id} || 0) > 0) {
        push @where, 'recipient_user_id = ?';
        push @bind, int($args{recipient_user_id});
    }
    if (int($args{recipient_account_id} || 0) > 0) {
        push @where, 'recipient_account_id = ?';
        push @bind, int($args{recipient_account_id});
    }
    unshift @bind, now();
    my $rows = $self->{db}->dbh->do(
        'UPDATE notifications SET status = ?, read_at = ? WHERE ' . join(' AND ', @where),
        undef,
        'read',
        @bind
    );
    return int($rows || 0);
}

sub _deliver_realtime {
    my ($self, $notification, %args) = @_;
    my $adapter = $args{adapter} || $self->{realtime_adapter};
    if (!_truthy($self->{config}->get('realtime_enabled'))) {
        return $self->record_delivery(
            delivery_id      => int($args{delivery_id} || 0),
            notification_id  => $notification->{id},
            delivery_channel => 'realtime',
            status           => 'skipped',
            last_error       => 'realtime disabled',
        );
    }
    if (!$adapter) {
        return $self->record_delivery(
            delivery_id      => int($args{delivery_id} || 0),
            notification_id  => $notification->{id},
            delivery_channel => 'realtime',
            status           => 'queued',
            last_error       => 'realtime adapter not connected',
            next_retry_at    => now() + 60,
        );
    }
    my $event = DesertCMS::Realtime->notification_event($notification);
    my $ok = eval { $adapter->($event); 1 };
    return $self->record_delivery(
        delivery_id      => int($args{delivery_id} || 0),
        notification_id  => $notification->{id},
        delivery_channel => 'realtime',
        status           => $ok ? 'delivered' : 'failed',
        last_error       => $ok ? '' : ($@ || 'realtime adapter failed'),
        adapter_response => $ok ? { channel => $event->{channel}, type => $event->{type} } : {},
        next_retry_at    => $ok ? undef : now() + 60,
    );
}

sub _deliver_adapter {
    my ($self, $notification, %args) = @_;
    my $channel = _delivery_channel($args{channel});
    my $adapter = $args{adapter} || $self->{delivery_adapters}{$channel};
    if (!$adapter) {
        return $self->record_delivery(
            delivery_id      => int($args{delivery_id} || 0),
            notification_id  => $notification->{id},
            delivery_channel => $channel,
            status           => 'queued',
            last_error       => 'adapter not configured',
            attempts         => 0,
            next_retry_at    => now() + 300,
        );
    }
    my $response;
    my $ok = eval {
        $response = $adapter->($notification);
        1;
    };
    return $self->record_delivery(
        delivery_id      => int($args{delivery_id} || 0),
        notification_id  => $notification->{id},
        delivery_channel => $channel,
        status           => $ok ? 'delivered' : 'failed',
        last_error       => $ok ? '' : ($@ || "$channel adapter failed"),
        adapter_response => $ok ? (ref($response) ? $response : { response => defined($response) ? "$response" : 'ok' }) : {},
        next_retry_at    => $ok ? undef : now() + 300,
    );
}

sub _delivery_channels {
    my ($channels, $config, $adapter) = @_;
    my @channels = ref($channels) eq 'ARRAY'
        ? @{$channels}
        : (qw(in_app), (_truthy($config ? $config->get('realtime_enabled') : 0) || $adapter ? 'realtime' : ()));
    my %seen;
    my @clean;
    for my $channel (@channels) {
        $channel = _delivery_channel($channel);
        next if $seen{$channel}++;
        push @clean, $channel;
    }
    return @clean;
}

sub _delivery_channel {
    my ($value) = @_;
    $value = lc($value || '');
    return 'in_app' unless length $value;
    return $value if $value eq 'in_app' || $value eq 'email' || $value eq 'realtime';
    die "notification delivery channel is not supported";
}

sub _enum {
    my ($value, $allowed, $default) = @_;
    $value = lc($value || '');
    my %allowed = map { $_ => 1 } @{$allowed || []};
    return $allowed{$value} ? $value : $default;
}

sub _clean_key {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value = lc $value;
    $value =~ s/[^a-z0-9_.:-]+/_/g;
    return substr($value, 0, 120);
}

sub _clean_text {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/^\s+|\s+\z//g;
    $max ||= 4000;
    return substr($value, 0, $max);
}

sub _clean_url {
    my ($value) = @_;
    $value = _clean_text($value, 500);
    return '' if $value =~ /[\r\n<>"']/;
    return $value if $value =~ m{\A/[A-Za-z0-9._~!$&'()*+,;=:@/%?-]*\z};
    return $value if $value =~ m{\Ahttps://[A-Za-z0-9.-]+(?::[0-9]+)?/[A-Za-z0-9._~!$&'()*+,;=:@/%?-]*\z};
    return '';
}

sub _json {
    my ($value) = @_;
    return '{}' unless defined $value;
    return $value if !ref($value) && eval { decode_json($value); 1 };
    return encode_json(ref($value) ? $value : { value => "$value" });
}

sub _maybe_int {
    my ($value) = @_;
    return undef unless defined $value && "$value" =~ /\A[0-9]+\z/;
    return int($value);
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

1;
