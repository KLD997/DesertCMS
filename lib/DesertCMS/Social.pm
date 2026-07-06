package DesertCMS::Social;

use strict;
use warnings;
use DesertCMS::Util qw(now slugify);

my %VISIBILITY = map { $_ => 1 } qw(public followers private);
my %PROFILE_STATUS = map { $_ => 1 } qw(active moderated disabled);
my %POST_STATUS = map { $_ => 1 } qw(visible hidden deleted reported);
my %REPLY_STATUS = map { $_ => 1 } qw(visible hidden deleted reported);
my %FOLLOW_STATUS = map { $_ => 1 } qw(active muted blocked);

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

sub ensure_profile {
    my ($self, %args) = @_;
    my $account_id = int($args{account_id} || 0);
    die "account id is required" unless $account_id > 0;
    my $account = $self->{db}->dbh->selectrow_hashref('SELECT * FROM user_accounts WHERE id = ?', undef, $account_id)
        or die "account was not found";
    my $handle = _handle($args{handle} || $account->{username} || $account->{email});
    my $display = _clean_text($args{display_name} || $account->{display_name} || $handle, 140);
    my $bio = _clean_text($args{bio}, 500);
    my $avatar = _clean_text($args{avatar_path}, 500);
    my $visibility = _visibility($args{visibility});
    my $status = _profile_status($args{status});
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO social_profiles
                (account_id, handle, display_name, bio, avatar_path, visibility, status, created_at, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET
                handle = excluded.handle,
                display_name = excluded.display_name,
                bio = excluded.bio,
                avatar_path = excluded.avatar_path,
                visibility = excluded.visibility,
                status = excluded.status,
                updated_at = excluded.updated_at
        },
        undef,
        $account_id,
        $handle,
        $display,
        $bio,
        $avatar,
        $visibility,
        $status,
        $ts,
        $ts
    );
    return $self->profile_for_account($account_id);
}

sub profile_for_account {
    my ($self, $account_id) = @_;
    return undef unless int($account_id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT p.*, a.email, a.username AS account_username, a.status AS account_status
            FROM social_profiles p
            JOIN user_accounts a ON a.id = p.account_id
            WHERE p.account_id = ?
        },
        undef,
        int($account_id)
    );
}

sub profile_by_handle {
    my ($self, $handle, %args) = @_;
    $handle = _handle($handle);
    my $profile = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT p.*, a.email, a.username AS account_username, a.status AS account_status
            FROM social_profiles p
            JOIN user_accounts a ON a.id = p.account_id
            WHERE p.handle = ?
        },
        undef,
        $handle
    );
    return $profile if $args{include_hidden};
    my ($allowed) = $self->can_view_profile(
        profile           => $profile,
        viewer_account_id => $args{viewer_account_id},
    );
    return $allowed ? $profile : undef;
}

sub profiles {
    my ($self, %args) = @_;
    my $include_hidden = $args{include_hidden} ? 1 : 0;
    my $where = $include_hidden ? '' : "WHERE p.status = 'active' AND p.visibility = 'public' AND a.status = 'active'";
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT p.*, COUNT(f.follower_account_id) AS follower_count
            FROM social_profiles p
            JOIN user_accounts a ON a.id = p.account_id
            LEFT JOIN social_follows f ON f.followed_account_id = p.account_id AND f.status = 'active'
            $where
            GROUP BY p.account_id
            ORDER BY lower(p.handle)
        },
        { Slice => {} }
    );
}

sub create_post {
    my ($self, %args) = @_;
    my $account_id = int($args{account_id} || 0);
    my $body = _clean_text($args{body}, 2000);
    my $ip_address = _clean_ip($args{ip_address});
    die "account and post body are required" unless $account_id > 0 && length $body;
    die "account is not active" unless $self->_account_active($account_id);
    $self->ensure_profile(account_id => $account_id) unless $self->profile_for_account($account_id);
    my $profile = $self->profile_for_account($account_id);
    die "social profile is not active" unless ($profile->{status} || '') eq 'active';
    $self->_enforce_write_limits(account_id => $account_id, ip_address => $ip_address, body => $body);
    my $visibility = _visibility($args{visibility});
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO social_posts (account_id, body, visibility, status, ip_address, created_at, updated_at)
            VALUES (?, ?, ?, 'visible', ?, ?, ?)
        },
        undef,
        $account_id,
        $body,
        $visibility,
        $ip_address,
        $ts,
        $ts
    );
    my $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    my $post = $self->post_by_id($id);
    $self->_emit_notification(
        audience             => 'public',
        topic                => 'social.post_created',
        module_key           => 'social',
        title                => 'New social post',
        body                 => _clean_text($body, 160),
        actor_account_id     => $account_id,
        entity_type          => 'social_post',
        entity_id            => $post->{id},
        url                  => _profile_url($profile),
    );
    $self->_emit_mentions($post, actor_account_id => $account_id);
    return $post;
}

sub feed {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 40, 1, 100);
    my $offset = _offset($args{offset}, $args{page}, $limit);
    my $include_hidden = $args{include_hidden} ? 1 : 0;
    my $viewer = int($args{viewer_account_id} || $args{account_id} || 0);
    my @where;
    my @bind;
    if (!$include_hidden) {
        push @where, "sp.status = 'active'";
        push @where, "a.status = 'active'";
        push @where, "p.status = 'visible'";
        if ($viewer > 0) {
            push @where, q{
                NOT EXISTS (
                    SELECT 1
                    FROM social_follows bx
                    WHERE bx.status = 'blocked'
                      AND (
                          (bx.follower_account_id = ? AND bx.followed_account_id = p.account_id)
                          OR (bx.follower_account_id = p.account_id AND bx.followed_account_id = ?)
                      )
                )
            };
            push @bind, $viewer, $viewer;
        }
    }
    if (int($args{profile_account_id} || 0) > 0) {
        my $profile_account_id = int($args{profile_account_id});
        if (!$include_hidden) {
            my ($can_view_profile) = $self->can_view_profile(profile_account_id => $profile_account_id, viewer_account_id => $viewer);
            return [] unless $can_view_profile;
        }
        push @where, 'p.account_id = ?';
        push @bind, $profile_account_id;
        if (!$include_hidden && $viewer != $profile_account_id) {
            if ($viewer > 0 && $self->_can_view_followers_content($viewer, $profile_account_id)) {
                push @where, "p.visibility IN ('public', 'followers')";
            } else {
                push @where, "p.visibility = 'public'";
            }
        }
    } elsif (($args{kind} || '') eq 'following') {
        die "viewer account is required for following feed" unless $viewer > 0;
        return [] if !$include_hidden && !$self->_account_active($viewer);
        return [] if !$include_hidden && !$self->_active_profile($viewer);
        push @where, q{
            p.account_id IN (
                SELECT followed_account_id
                FROM social_follows
                WHERE follower_account_id = ?
                  AND status = 'active'
            )
        };
        push @bind, $viewer;
        push @where, "p.visibility IN ('public', 'followers')" unless $include_hidden;
        push @where, "sp.visibility IN ('public', 'followers')" unless $include_hidden;
    } elsif (!$include_hidden) {
        push @where, "p.visibility = 'public'";
        push @where, "sp.visibility = 'public'";
    }
    my $where = @where ? 'WHERE ' . join(' AND ', @where) : '';
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT p.*, sp.handle, sp.display_name, sp.avatar_path,
                   COUNT(r.id) AS reaction_count
            FROM social_posts p
            LEFT JOIN social_profiles sp ON sp.account_id = p.account_id
            LEFT JOIN user_accounts a ON a.id = p.account_id
            LEFT JOIN social_reactions r ON r.post_id = p.id
            $where
            GROUP BY p.id
            ORDER BY p.created_at DESC, p.id DESC
            LIMIT $limit
            OFFSET $offset
        },
        { Slice => {} },
        @bind
    );
}

sub post_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT p.*, sp.handle, sp.display_name, sp.avatar_path, sp.status AS profile_status
            FROM social_posts p
            LEFT JOIN social_profiles sp ON sp.account_id = p.account_id
            WHERE p.id = ?
        },
        undef,
        int($id)
    );
}

sub add_reply {
    my ($self, %args) = @_;
    my $post_id = int($args{post_id} || 0);
    my $account_id = int($args{account_id} || 0);
    my $body = _clean_text($args{body}, 2000);
    my $ip_address = _clean_ip($args{ip_address});
    die "post, account, and reply body are required" unless $post_id > 0 && $account_id > 0 && length $body;
    die "account is not active" unless $self->_account_active($account_id);
    my $post = $self->post_by_id($post_id) or die "social post was not found";
    my ($can_view, $view_reason) = $self->can_view_post(viewer_account_id => $account_id, post => $post);
    die "social post is not visible: $view_reason" unless $can_view;
    $self->ensure_profile(account_id => $account_id) unless $self->profile_for_account($account_id);
    my $profile = $self->profile_for_account($account_id);
    die "social profile is not active" unless ($profile->{status} || '') eq 'active';
    $self->_enforce_reply_limits(account_id => $account_id, post_id => $post_id, ip_address => $ip_address, body => $body);
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO social_replies (post_id, account_id, body, status, ip_address, created_at, updated_at)
            VALUES (?, ?, ?, 'visible', ?, ?, ?)
        },
        undef,
        $post_id,
        $account_id,
        $body,
        $ip_address,
        $ts,
        $ts
    );
    my $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    my $reply = $self->reply_by_id($id);
    $self->_emit_notification(
        audience             => 'user',
        topic                => 'social.reply_created',
        module_key           => 'social',
        title                => 'New social reply',
        body                 => _clean_text($body, 160),
        actor_account_id     => $account_id,
        recipient_account_id => int($post->{account_id} || 0),
        entity_type          => 'social_reply',
        entity_id            => $reply->{id},
        url                  => _profile_url($post),
        details              => { post_id => $post_id },
    ) if int($post->{account_id} || 0) && int($post->{account_id} || 0) != $account_id;
    $self->_emit_mentions(
        $reply,
        body             => $body,
        actor_account_id => $account_id,
        entity_type      => 'social_reply',
        entity_id        => $reply->{id},
        url              => _profile_url($post),
    );
    return $reply;
}

sub reply_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT r.*, a.status AS account_status,
                   p.account_id AS post_account_id, p.visibility AS post_visibility, pa.status AS post_account_status,
                   sp.handle, sp.display_name, sp.avatar_path
            FROM social_replies r
            JOIN social_posts p ON p.id = r.post_id
            LEFT JOIN user_accounts a ON a.id = r.account_id
            LEFT JOIN user_accounts pa ON pa.id = p.account_id
            LEFT JOIN social_profiles sp ON sp.account_id = r.account_id
            WHERE r.id = ?
        },
        undef,
        int($id)
    );
}

sub replies_for_post {
    my ($self, %args) = @_;
    my $post_id = int($args{post_id} || $args{id} || 0);
    die "post id is required" unless $post_id > 0;
    my $limit = _limit($args{limit}, 50, 1, 200);
    if (!$args{include_hidden}) {
        my ($can_view) = $self->can_view_post(post_id => $post_id, viewer_account_id => $args{viewer_account_id});
        return [] unless $can_view;
    }
    my @where = ('r.post_id = ?');
    my @bind = ($post_id);
    if (!$args{include_hidden}) {
        push @where, "r.status = 'visible'";
        push @where, "p.status = 'visible'";
        push @where, "a.status = 'active'";
        push @where, "pa.status = 'active'";
        push @where, "sp.status = 'active'";
    }
    my $where = join(' AND ', @where);
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT r.*, sp.handle, sp.display_name, sp.avatar_path
            FROM social_replies r
            JOIN social_posts p ON p.id = r.post_id
            LEFT JOIN user_accounts a ON a.id = r.account_id
            LEFT JOIN user_accounts pa ON pa.id = p.account_id
            LEFT JOIN social_profiles sp ON sp.account_id = r.account_id
            WHERE $where
            ORDER BY r.created_at ASC, r.id ASC
            LIMIT $limit
        },
        { Slice => {} },
        @bind
    );
}

sub follow {
    my ($self, %args) = @_;
    my $follower = int($args{follower_account_id} || 0);
    my $followed = int($args{followed_account_id} || 0);
    die "follower and followed account are required" unless $follower > 0 && $followed > 0 && $follower != $followed;
    die "follower account is not active" unless $self->_account_active($follower);
    die "followed account is not active" unless $self->_account_active($followed);
    my $follower_profile = $self->_require_active_profile($follower, 'follower');
    my $followed_profile = $self->profile_for_account($followed) or die "followed social profile was not found";
    die "followed social profile is not active" unless ($followed_profile->{status} || '') eq 'active';
    my $status = _follow_status($args{status});
    die "social profile is blocked" if $status ne 'blocked' && $self->_blocked_between($follower, $followed);
    my $previous_status = $self->follow_status(follower_account_id => $follower, followed_account_id => $followed);
    $self->{db}->dbh->do(
        q{
            INSERT INTO social_follows (follower_account_id, followed_account_id, status, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(follower_account_id, followed_account_id) DO UPDATE SET status = excluded.status
        },
        undef,
        $follower,
        $followed,
        $status,
        now()
    );
    $self->_emit_notification(
        audience             => 'user',
        topic                => 'social.follow',
        module_key           => 'social',
        title                => 'New follower',
        body                 => 'A profile followed you.',
        actor_account_id     => $follower,
        recipient_account_id => $followed,
        entity_type          => 'social_profile',
        entity_id            => $followed,
        url                  => _profile_url($follower_profile),
    ) if $status eq 'active' && ($previous_status || '') ne 'active';
    return 1;
}

sub block {
    my ($self, %args) = @_;
    my $blocker = int($args{blocker_account_id} || $args{follower_account_id} || 0);
    my $blocked = int($args{blocked_account_id} || $args{followed_account_id} || 0);
    die "blocker and blocked account are required" unless $blocker > 0 && $blocked > 0 && $blocker != $blocked;
    die "blocker account is not active" unless $self->_account_active($blocker);
    die "blocked account is not active" unless $self->_account_active($blocked);
    $self->_require_active_profile($blocker, 'blocker');
    my $blocked_profile = $self->profile_for_account($blocked) or die "blocked social profile was not found";
    die "blocked social profile is not active" unless ($blocked_profile->{status} || '') eq 'active';
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        'DELETE FROM social_follows WHERE follower_account_id = ? AND followed_account_id = ?',
        undef,
        $blocked,
        $blocker
    );
    $dbh->do(
        q{
            INSERT INTO social_follows (follower_account_id, followed_account_id, status, created_at)
            VALUES (?, ?, 'blocked', ?)
            ON CONFLICT(follower_account_id, followed_account_id) DO UPDATE SET status = 'blocked'
        },
        undef,
        $blocker,
        $blocked,
        now()
    );
    return 1;
}

sub unblock {
    my ($self, %args) = @_;
    my $blocker = int($args{blocker_account_id} || $args{follower_account_id} || 0);
    my $blocked = int($args{blocked_account_id} || $args{followed_account_id} || 0);
    die "blocker and blocked account are required" unless $blocker > 0 && $blocked > 0 && $blocker != $blocked;
    $self->{db}->dbh->do(
        q{
            DELETE FROM social_follows
            WHERE follower_account_id = ?
              AND followed_account_id = ?
              AND status = 'blocked'
        },
        undef,
        $blocker,
        $blocked
    );
    return 1;
}

sub unfollow {
    my ($self, %args) = @_;
    my $follower = int($args{follower_account_id} || 0);
    my $followed = int($args{followed_account_id} || 0);
    die "follower and followed account are required" unless $follower > 0 && $followed > 0 && $follower != $followed;
    $self->{db}->dbh->do(
        'DELETE FROM social_follows WHERE follower_account_id = ? AND followed_account_id = ?',
        undef,
        $follower,
        $followed
    );
    return 1;
}

sub follow_status {
    my ($self, %args) = @_;
    my $follower = int($args{follower_account_id} || 0);
    my $followed = int($args{followed_account_id} || 0);
    return '' unless $follower > 0 && $followed > 0 && $follower != $followed;
    my ($status) = $self->{db}->dbh->selectrow_array(
        'SELECT status FROM social_follows WHERE follower_account_id = ? AND followed_account_id = ?',
        undef,
        $follower,
        $followed
    );
    return $status || '';
}

sub react {
    my ($self, %args) = @_;
    my $post_id = int($args{post_id} || 0);
    my $account_id = int($args{account_id} || 0);
    my $reaction = _reaction($args{reaction});
    die "post and account are required" unless $post_id > 0 && $account_id > 0;
    die "account is not active" unless $self->_account_active($account_id);
    $self->_require_active_profile($account_id, 'reactor');
    my $post = $self->post_by_id($post_id) or die "social post was not found";
    my ($can_view, $view_reason) = $self->can_view_post(viewer_account_id => $account_id, post => $post);
    die "social post is not visible: $view_reason" unless $can_view;
    my $changed = $self->{db}->dbh->do(
        q{
            INSERT INTO social_reactions (post_id, account_id, reaction, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(post_id, account_id, reaction) DO NOTHING
        },
        undef,
        $post_id,
        $account_id,
        $reaction,
        now()
    );
    $self->_emit_notification(
        audience             => 'user',
        topic                => 'social.reaction',
        module_key           => 'social',
        title                => 'New reaction',
        body                 => 'Someone reacted to your post.',
        actor_account_id     => $account_id,
        recipient_account_id => int($post->{account_id} || 0),
        entity_type          => 'social_post',
        entity_id            => $post_id,
        url                  => _profile_url($post),
        details              => { reaction => $reaction },
    ) if int($changed || 0) > 0 && $post && int($post->{account_id} || 0) && int($post->{account_id} || 0) != $account_id;
    return 1;
}

sub set_post_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "post id is required" unless $id > 0;
    my $post = $self->post_by_id($id) or die "social post was not found";
    my $status = _post_status($args{status});
    my %actor = $self->_moderation_actor(%args);
    return $post if ($post->{status} || '') eq $status;
    $self->{db}->dbh->do('UPDATE social_posts SET status = ?, updated_at = ? WHERE id = ?', undef, $status, now(), $id);
    $post = $self->post_by_id($id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'social.moderation_needed',
        module_key       => 'social',
        title            => 'Social post status changed',
        body             => 'A social post was moderated.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'social_post',
        entity_id        => $id,
        url              => _profile_url($post),
        details          => _moderation_details(status => $status, moderator_note => _clean_text($args{moderator_note}, 500), system_action => $actor{system_action}),
    );
    return $post;
}

sub set_reply_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "reply id is required" unless $id > 0;
    my $reply = $self->reply_by_id($id) or die "social reply was not found";
    my $status = _reply_status($args{status});
    my %actor = $self->_moderation_actor(%args);
    return $reply if ($reply->{status} || '') eq $status;
    $self->{db}->dbh->do('UPDATE social_replies SET status = ?, updated_at = ? WHERE id = ?', undef, $status, now(), $id);
    $reply = $self->reply_by_id($id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'social.moderation_needed',
        module_key       => 'social',
        title            => 'Social reply status changed',
        body             => 'A social reply was moderated.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'social_reply',
        entity_id        => $id,
        url              => _profile_url($reply),
        details          => _moderation_details(status => $status, post_id => int($reply->{post_id} || 0), moderator_note => _clean_text($args{moderator_note}, 500), system_action => $actor{system_action}),
    );
    return $reply;
}

sub delete_post {
    my ($self, %args) = @_;
    my $id = int($args{id} || $args{post_id} || 0);
    my $account_id = int($args{account_id} || 0);
    die "post and account are required" unless $id > 0 && $account_id > 0;
    my $post = $self->post_by_id($id) or die "social post was not found";
    my ($allowed, $reason) = $self->can_delete_post(post => $post, account_id => $account_id);
    die "social permission denied: $reason" unless $allowed;
    $self->{db}->dbh->do('UPDATE social_posts SET status = ?, updated_at = ? WHERE id = ?', undef, 'deleted', now(), $id);
    return $self->post_by_id($id);
}

sub delete_reply {
    my ($self, %args) = @_;
    my $id = int($args{id} || $args{reply_id} || 0);
    my $account_id = int($args{account_id} || 0);
    die "reply and account are required" unless $id > 0 && $account_id > 0;
    my $reply = $self->reply_by_id($id) or die "social reply was not found";
    my ($allowed, $reason) = $self->can_delete_reply(reply => $reply, account_id => $account_id);
    die "social permission denied: $reason" unless $allowed;
    $self->{db}->dbh->do('UPDATE social_replies SET status = ?, updated_at = ? WHERE id = ?', undef, 'deleted', now(), $id);
    return $self->reply_by_id($id);
}

sub can_delete_post {
    my ($self, %args) = @_;
    my $id = int($args{id} || $args{post_id} || 0);
    my $account_id = int($args{account_id} || 0);
    return _permission(0, 'post and account are required') unless ($id > 0 || ref($args{post}) eq 'HASH') && $account_id > 0;
    return _permission(0, 'account is not active') unless $self->_account_active($account_id);
    return _permission(0, 'social profile is not active') unless $self->_active_profile($account_id);
    my $post = $args{post} || $self->post_by_id($id);
    return _permission(0, 'social post was not found') unless $post;
    return _permission(0, 'social post belongs to another account')
        unless int($post->{account_id} || 0) == $account_id;
    return _permission(0, 'social post cannot be deleted')
        unless ($post->{status} || '') =~ /\A(?:visible|reported)\z/;
    my $window = _positive_int($self->{config}->get('social_delete_window_seconds') || 900, 900);
    return _permission(0, 'social post delete window has closed')
        unless int($post->{created_at} || 0) >= now() - $window;
    return _permission(1, '');
}

sub can_delete_reply {
    my ($self, %args) = @_;
    my $id = int($args{id} || $args{reply_id} || 0);
    my $account_id = int($args{account_id} || 0);
    return _permission(0, 'reply and account are required') unless ($id > 0 || ref($args{reply}) eq 'HASH') && $account_id > 0;
    return _permission(0, 'account is not active') unless $self->_account_active($account_id);
    return _permission(0, 'social profile is not active') unless $self->_active_profile($account_id);
    my $reply = $args{reply} || $self->reply_by_id($id);
    return _permission(0, 'social reply was not found') unless $reply;
    return _permission(0, 'social reply belongs to another account')
        unless int($reply->{account_id} || 0) == $account_id;
    return _permission(0, 'social reply cannot be deleted')
        unless ($reply->{status} || '') =~ /\A(?:visible|reported)\z/;
    my $window = _positive_int($self->{config}->get('social_delete_window_seconds') || 900, 900);
    return _permission(0, 'social reply delete window has closed')
        unless int($reply->{created_at} || 0) >= now() - $window;
    return _permission(1, '');
}

sub set_profile_status {
    my ($self, %args) = @_;
    my $account_id = int($args{account_id} || 0);
    die "account id is required" unless $account_id > 0;
    my $profile = $self->profile_for_account($account_id) or die "social profile was not found";
    my $status = _profile_status($args{status});
    my %actor = $self->_moderation_actor(
        moderator_account_id => $args{moderator_account_id} || $args{actor_account_id},
        admin_user_id        => $args{admin_user_id} || $args{actor_user_id},
        system_action        => $args{system_action},
    );
    return $profile if ($profile->{status} || '') eq $status;
    $self->{db}->dbh->do('UPDATE social_profiles SET status = ?, updated_at = ? WHERE account_id = ?', undef, $status, now(), $account_id);
    $profile = $self->profile_for_account($account_id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'social.moderation_needed',
        module_key       => 'social',
        title            => 'Social profile status changed',
        body             => $profile->{handle} || 'A social profile was moderated.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'social_profile',
        entity_id        => $account_id,
        url              => _profile_url($profile),
        details          => _moderation_details(status => $status, moderator_note => _clean_text($args{moderator_note}, 500), system_action => $actor{system_action}),
    );
    return $profile;
}

sub report_post {
    my ($self, %args) = @_;
    my $post = $self->post_by_id($args{id} || $args{post_id}) or die "social post was not found";
    my $reporter_id = int($args{reporter_account_id} || 0);
    die "reporter account is not active" unless $self->_account_active($reporter_id);
    my ($can_view, $view_reason) = $self->can_view_post(viewer_account_id => $reporter_id, post => $post);
    die "social post is not visible: $view_reason" unless $can_view;
    my $report = $self->_create_report(
        post_id             => $post->{id},
        reporter_account_id => $reporter_id,
        reason              => $args{reason},
    );
    $self->set_post_status(id => $post->{id}, status => 'reported', system_action => 'social_report_post');
    $self->_emit_notification(
        audience             => 'admin',
        topic                => 'social.reported',
        module_key           => 'social',
        severity             => 'warning',
        title                => 'Social post reported',
        body                 => _clean_text($args{reason}, 160) || 'A social post was reported.',
        actor_account_id     => int($args{reporter_account_id} || 0) || undef,
        entity_type          => 'social_report',
        entity_id            => $report->{id},
        details              => { post_id => $post->{id} },
    );
    return $report;
}

sub report_reply {
    my ($self, %args) = @_;
    my $reply = $self->reply_by_id($args{id} || $args{reply_id}) or die "social reply was not found";
    my $reporter_id = int($args{reporter_account_id} || 0);
    die "reporter account is not active" unless $self->_account_active($reporter_id);
    die "social reply is not visible" unless ($reply->{status} || '') eq 'visible';
    die "social reply is not visible" unless ($reply->{account_status} || '') eq 'active';
    my ($can_view, $view_reason) = $self->can_view_post(viewer_account_id => $reporter_id, post_id => $reply->{post_id});
    die "social post is not visible: $view_reason" unless $can_view;
    my $report = $self->_create_report(
        post_id             => $reply->{post_id},
        reply_id            => $reply->{id},
        reporter_account_id => $reporter_id,
        reason              => $args{reason},
    );
    $self->set_reply_status(id => $reply->{id}, status => 'reported', system_action => 'social_report_reply');
    $self->_emit_notification(
        audience             => 'admin',
        topic                => 'social.reported',
        module_key           => 'social',
        severity             => 'warning',
        title                => 'Social reply reported',
        body                 => _clean_text($args{reason}, 160) || 'A social reply was reported.',
        actor_account_id     => int($args{reporter_account_id} || 0) || undef,
        entity_type          => 'social_report',
        entity_id            => $report->{id},
        details              => { post_id => int($reply->{post_id} || 0), reply_id => $reply->{id} },
    );
    return $report;
}

sub report_profile {
    my ($self, %args) = @_;
    my $account_id = int($args{profile_account_id} || $args{account_id} || 0);
    my $reporter_id = int($args{reporter_account_id} || 0);
    die "profile account id is required" unless $account_id > 0;
    die "reporter account is not active" unless $self->_account_active($reporter_id);
    my $profile = $self->profile_for_account($account_id) or die "social profile was not found";
    die "social profile is not active" unless ($profile->{status} || '') eq 'active' && $self->_account_active($profile->{account_id});
    die "social profile is blocked" if $self->_blocked_between($reporter_id, $profile->{account_id});
    my ($can_view, $view_reason) = $self->can_view_profile(viewer_account_id => $reporter_id, profile => $profile);
    die "social profile is not visible: $view_reason" unless $can_view;
    my $report = $self->_create_report(
        profile_account_id   => $profile->{account_id},
        reporter_account_id  => $reporter_id,
        reason               => $args{reason},
    );
    $self->_emit_notification(
        audience             => 'admin',
        topic                => 'social.reported',
        module_key           => 'social',
        severity             => 'warning',
        title                => 'Social profile reported',
        body                 => _clean_text($args{reason}, 160) || 'A social profile was reported.',
        actor_account_id     => int($args{reporter_account_id} || 0) || undef,
        entity_type          => 'social_report',
        entity_id            => $report->{id},
        url                  => _profile_url($profile),
        details              => { profile_account_id => $profile->{account_id} },
    );
    return $report;
}

sub reports {
    my ($self, %args) = @_;
    my $status = _report_status($args{status} || 'open');
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT r.*, p.body AS post_body, p.status AS post_status,
                   sr.body AS reply_body, sr.status AS reply_status,
                   sp.handle AS profile_handle, sp.status AS profile_status,
                   a.display_name AS reporter_display_name, a.username AS reporter_username
            FROM social_reports r
            LEFT JOIN social_posts p ON p.id = r.post_id
            LEFT JOIN social_replies sr ON sr.id = r.reply_id
            LEFT JOIN social_profiles sp ON sp.account_id = r.profile_account_id
            LEFT JOIN user_accounts a ON a.id = r.reporter_account_id
            WHERE r.status = ?
            ORDER BY r.created_at ASC, r.id ASC
        },
        { Slice => {} },
        $status
    );
}

sub set_report_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "report id is required" unless $id > 0;
    my $existing = $self->{db}->dbh->selectrow_hashref('SELECT * FROM social_reports WHERE id = ?', undef, $id)
        or die "social report was not found";
    my $status = _report_status($args{status});
    my %actor = $self->_moderation_actor(%args);
    my $note = _clean_text($args{moderator_note}, 500);
    return $existing if ($existing->{status} || '') eq $status && ($existing->{moderator_note} || '') eq $note;
    my $resolved = $status eq 'open' ? undef : ($existing->{resolved_at} || now());
    $self->{db}->dbh->do(
        'UPDATE social_reports SET status = ?, moderator_note = ?, updated_at = ?, resolved_at = ? WHERE id = ?',
        undef,
        $status,
        $note,
        now(),
        $resolved,
        $id
    );
    my $report = $self->{db}->dbh->selectrow_hashref('SELECT * FROM social_reports WHERE id = ?', undef, $id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'social.moderation_needed',
        module_key       => 'social',
        title            => 'Social report status changed',
        body             => _clean_text($args{moderator_note}, 160) || 'A social report was moderated.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'social_report',
        entity_id        => $id,
        details          => _moderation_details(status => $status, moderator_note => _clean_text($args{moderator_note}, 500), system_action => $actor{system_action}),
    );
    return $report;
}

sub mentions_for_post {
    my ($self, $post_or_id) = @_;
    my $post = ref($post_or_id) eq 'HASH' ? $post_or_id : $self->post_by_id($post_or_id);
    return [] unless $post;
    return $self->mentions_for_text($post->{body});
}

sub mentions_for_reply {
    my ($self, $reply_or_id) = @_;
    my $reply = ref($reply_or_id) eq 'HASH' ? $reply_or_id : $self->reply_by_id($reply_or_id);
    return [] unless $reply;
    return $self->mentions_for_text($reply->{body});
}

sub mentions_for_text {
    my ($self, $body) = @_;
    my %seen;
    my @handles = grep { !$seen{$_}++ } map { _handle($_) } (($body || '') =~ /\@([A-Za-z0-9_.-]{2,80})/g);
    return [] unless @handles;
    my $placeholders = join ',', ('?') x @handles;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT *
            FROM social_profiles
            WHERE handle IN ($placeholders)
              AND status = 'active'
        },
        { Slice => {} },
        @handles
    );
}

sub following_feed {
    my ($self, %args) = @_;
    return $self->feed(%args, kind => 'following');
}

sub profile_feed {
    my ($self, %args) = @_;
    return $self->feed(%args);
}

sub global_feed {
    my ($self, %args) = @_;
    delete $args{profile_account_id};
    delete $args{kind};
    return $self->feed(%args);
}

sub can_view_profile {
    my ($self, %args) = @_;
    my $viewer = int($args{viewer_account_id} || $args{account_id} || 0);
    my $profile = $args{profile} || $self->profile_for_account($args{profile_account_id});
    return _permission(0, 'profile was not found') unless $profile;
    return _permission(0, 'profile is not active')
        unless ($profile->{status} || '') eq 'active' && ($profile->{account_status} || 'active') eq 'active';
    my $owner = int($profile->{account_id} || 0);
    return _permission(1, '') if $viewer > 0 && $viewer == $owner;
    return _permission(0, 'viewer account is not active') unless $viewer == 0 || $self->_account_active($viewer);
    return _permission(0, 'profile is blocked') if $viewer > 0 && $self->_blocked_between($viewer, $owner);
    my $visibility = _visibility($profile->{visibility});
    return _permission(1, '') if $visibility eq 'public';
    return _permission(1, '') if $visibility eq 'followers' && $viewer > 0 && $self->_can_view_followers_content($viewer, $owner);
    return _permission(0, $visibility eq 'private' ? 'profile is private' : 'profile requires following');
}

sub can_view_post {
    my ($self, %args) = @_;
    my $viewer = int($args{viewer_account_id} || $args{account_id} || 0);
    my $post = $args{post} || $self->post_by_id($args{post_id} || $args{id});
    return _permission(0, 'post was not found') unless $post;
    return _permission(0, 'post is not visible') unless ($post->{status} || '') =~ /\A(?:visible|reported)\z/;
    my $owner = int($post->{account_id} || 0);
    return _permission(0, 'post owner is not active') unless $owner > 0 && $self->_account_active($owner);
    my $profile = $self->profile_for_account($owner);
    return _permission(0, 'profile is not active') unless $profile && ($profile->{status} || '') eq 'active';
    return _permission(1, '') if $viewer > 0 && $viewer == $owner;
    return _permission(0, 'viewer account is not active') unless $viewer == 0 || $self->_account_active($viewer);
    return _permission(0, 'profile is blocked') if $viewer > 0 && $self->_blocked_between($viewer, $owner);
    my ($can_view_profile, $profile_reason) = $self->can_view_profile(profile => $profile, viewer_account_id => $viewer);
    return _permission(0, $profile_reason) unless $can_view_profile;
    my $visibility = _visibility($post->{visibility});
    return _permission(1, '') if $visibility eq 'public';
    return _permission(1, '') if $visibility eq 'followers' && $viewer > 0 && $self->_can_view_followers_content($viewer, $owner);
    return _permission(0, $visibility eq 'private' ? 'post is private' : 'post requires following');
}

sub _create_report {
    my ($self, %args) = @_;
    my $post_id = int($args{post_id} || 0) || undef;
    my $reply_id = int($args{reply_id} || 0) || undef;
    my $profile_account_id = int($args{profile_account_id} || 0) || undef;
    my $reporter_id = int($args{reporter_account_id} || 0) || undef;
    die "post, reply, or profile is required" unless $post_id || $reply_id || $profile_account_id;
    my @where = ("status = 'open'");
    my @bind;
    for my $field (
        [ post_id            => $post_id ],
        [ reply_id           => $reply_id ],
        [ profile_account_id => $profile_account_id ],
        [ reporter_account_id => $reporter_id ],
    ) {
        if (defined $field->[1]) {
            push @where, "$field->[0] = ?";
            push @bind, int($field->[1]);
        } else {
            push @where, "$field->[0] IS NULL";
        }
    }
    my ($existing) = $self->{db}->dbh->selectrow_array(
        'SELECT id FROM social_reports WHERE ' . join(' AND ', @where) . ' LIMIT 1',
        undef,
        @bind
    );
    die "duplicate social report suppressed" if $existing;
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO social_reports
                (post_id, reply_id, profile_account_id, reporter_account_id, reason, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 'open', ?, ?)
        },
        undef,
        $post_id,
        $reply_id,
        $profile_account_id,
        $reporter_id,
        _clean_text($args{reason}, 500),
        $ts,
        $ts
    );
    my $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM social_reports WHERE id = ?', undef, $id);
}

sub _emit_mentions {
    my ($self, $entity, %args) = @_;
    my $body = exists($args{body}) ? $args{body} : ($entity ? $entity->{body} : '');
    my $entity_type = $args{entity_type} || 'social_post';
    my $entity_id = int($args{entity_id} || ($entity ? $entity->{id} : 0) || 0);
    my $url = $args{url} || _profile_url($entity);
    my $post = $entity_type eq 'social_reply'
        ? $self->post_by_id($args{post_id} || ($entity ? $entity->{post_id} : 0))
        : $entity;
    for my $profile (@{ $self->mentions_for_text($body) }) {
        next if int($profile->{account_id} || 0) == int($args{actor_account_id} || 0);
        if ($post) {
            my ($can_view) = $self->can_view_post(
                post              => $post,
                viewer_account_id => int($profile->{account_id} || 0),
            );
            next unless $can_view;
        }
        $self->_emit_notification(
            audience             => 'user',
            topic                => 'social.mention',
            module_key           => 'social',
            title                => 'Social mention',
            body                 => $entity_type eq 'social_reply' ? 'You were mentioned in a social reply.' : 'You were mentioned in a social post.',
            actor_account_id     => int($args{actor_account_id} || 0) || undef,
            recipient_account_id => int($profile->{account_id} || 0),
            entity_type          => $entity_type,
            entity_id            => $entity_id,
            url                  => $url,
        );
    }
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

sub _enforce_write_limits {
    my ($self, %args) = @_;
    my $account_id = int($args{account_id} || 0);
    return unless $account_id > 0;
    die "social account is too new" unless $self->_account_old_enough($account_id);
    my $window = _positive_int($self->{config}->get('social_rate_window_seconds') || 600, 600);
    my $max = _positive_int($self->{config}->get('social_max_posts_per_window') || 30, 30);
    my ($count) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM social_posts WHERE account_id = ? AND created_at >= ?',
        undef,
        $account_id,
        now() - $window
    );
    die "social post rate limit exceeded" if int($count || 0) >= $max;
    my $ip_address = _clean_ip($args{ip_address});
    if (length $ip_address) {
        my $ip_max = _positive_int($self->{config}->get('social_max_posts_per_ip_window') || $max, $max);
        my ($ip_count) = $self->{db}->dbh->selectrow_array(
            'SELECT COUNT(*) FROM social_posts WHERE ip_address = ? AND created_at >= ?',
            undef,
            $ip_address,
            now() - $window
        );
        die "social ip rate limit exceeded" if int($ip_count || 0) >= $ip_max;
    }
    my $body = _clean_text($args{body}, 2000);
    return unless length $body;
    my ($duplicate) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT 1
            FROM social_posts
            WHERE account_id = ?
              AND body = ?
              AND status <> 'deleted'
              AND created_at >= ?
            LIMIT 1
        },
        undef,
        $account_id,
        $body,
        now() - 120
    );
    die "duplicate social post suppressed" if $duplicate;
}

sub _enforce_reply_limits {
    my ($self, %args) = @_;
    my $account_id = int($args{account_id} || 0);
    my $post_id = int($args{post_id} || 0);
    return unless $account_id > 0 && $post_id > 0;
    die "social account is too new" unless $self->_account_old_enough($account_id);
    my $window = _positive_int($self->{config}->get('social_rate_window_seconds') || 600, 600);
    my $max = _positive_int($self->{config}->get('social_max_replies_per_window') || 60, 60);
    my ($count) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM social_replies WHERE account_id = ? AND created_at >= ?',
        undef,
        $account_id,
        now() - $window
    );
    die "social reply rate limit exceeded" if int($count || 0) >= $max;
    my $ip_address = _clean_ip($args{ip_address});
    if (length $ip_address) {
        my $ip_max = _positive_int($self->{config}->get('social_max_replies_per_ip_window') || $max, $max);
        my ($ip_count) = $self->{db}->dbh->selectrow_array(
            'SELECT COUNT(*) FROM social_replies WHERE ip_address = ? AND created_at >= ?',
            undef,
            $ip_address,
            now() - $window
        );
        die "social ip rate limit exceeded" if int($ip_count || 0) >= $ip_max;
    }
    my $body = _clean_text($args{body}, 2000);
    return unless length $body;
    my ($duplicate) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT 1
            FROM social_replies
            WHERE post_id = ?
              AND account_id = ?
              AND body = ?
              AND status <> 'deleted'
              AND created_at >= ?
            LIMIT 1
        },
        undef,
        $post_id,
        $account_id,
        $body,
        now() - 120
    );
    die "duplicate social reply suppressed" if $duplicate;
}

sub _account_old_enough {
    my ($self, $account_id) = @_;
    my $min_age = _positive_int($self->{config}->get('social_min_account_age_seconds') || 0, 0);
    return 1 unless $min_age > 0;
    my ($created_at) = $self->{db}->dbh->selectrow_array('SELECT created_at FROM user_accounts WHERE id = ?', undef, int($account_id || 0));
    return 0 unless int($created_at || 0) > 0;
    return int($created_at) <= now() - $min_age ? 1 : 0;
}

sub _account_active {
    my ($self, $account_id) = @_;
    my ($status) = $self->{db}->dbh->selectrow_array('SELECT status FROM user_accounts WHERE id = ?', undef, int($account_id || 0));
    return ($status || '') eq 'active' ? 1 : 0;
}

sub _require_active_profile {
    my ($self, $account_id, $label) = @_;
    $label = _clean_text($label || 'social', 40);
    my $profile = $self->profile_for_account($account_id) or die "$label social profile was not found";
    die "$label social profile is not active" unless ($profile->{status} || '') eq 'active';
    return $profile;
}

sub _active_profile {
    my ($self, $account_id) = @_;
    my $profile = $self->profile_for_account($account_id);
    return $profile && ($profile->{status} || '') eq 'active' && ($profile->{account_status} || '') eq 'active' ? 1 : 0;
}

sub _can_view_followers_content {
    my ($self, $viewer, $owner) = @_;
    return 1 if int($viewer || 0) > 0 && int($viewer || 0) == int($owner || 0);
    return 0 unless int($viewer || 0) > 0 && int($owner || 0) > 0;
    return 0 unless $self->_active_profile($viewer);
    return 0 if $self->_blocked_between($viewer, $owner);
    my ($status) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT status
            FROM social_follows
            WHERE follower_account_id = ?
              AND followed_account_id = ?
            LIMIT 1
        },
        undef,
        int($viewer),
        int($owner)
    );
    return ($status || '') =~ /\A(?:active|muted)\z/ ? 1 : 0;
}

sub _blocked_between {
    my ($self, $a, $b) = @_;
    return 0 unless int($a || 0) > 0 && int($b || 0) > 0;
    my ($blocked) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT 1
            FROM social_follows
            WHERE status = 'blocked'
              AND (
                  (follower_account_id = ? AND followed_account_id = ?)
                  OR (follower_account_id = ? AND followed_account_id = ?)
              )
            LIMIT 1
        },
        undef,
        int($a), int($b), int($b), int($a)
    );
    return $blocked ? 1 : 0;
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
        int($account_id || 0)
    );
    return $has_role ? 1 : 0;
}

sub _require_moderator {
    my ($self, $account_id) = @_;
    die "social moderator account is required" unless int($account_id || 0) > 0;
    die "social moderator permission required" unless $self->_account_active($account_id) && $self->_is_moderator($account_id);
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
        die "social admin user is not active" unless $self->_admin_user_active($admin_user_id);
        return (actor_user_id => $admin_user_id);
    }
    my $system_action = _system_moderation_action($args{system_action}, 'social');
    return (system_action => $system_action) if length $system_action;
    die "social moderator account or active admin user is required";
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

sub _permission {
    my ($ok, $reason) = @_;
    return wantarray ? ($ok ? 1 : 0, $reason || '') : ($ok ? 1 : 0);
}

sub _handle {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/\@.*\z//;
    $value = slugify($value);
    $value =~ s/-/_/g;
    return $value || 'profile';
}

sub _visibility {
    my ($value) = @_;
    $value = lc($value || 'public');
    return $VISIBILITY{$value} ? $value : 'public';
}

sub _profile_status {
    my ($value) = @_;
    $value = lc($value || 'active');
    return $PROFILE_STATUS{$value} ? $value : 'active';
}

sub _post_status {
    my ($value) = @_;
    $value = lc($value || 'visible');
    return $POST_STATUS{$value} ? $value : 'visible';
}

sub _reply_status {
    my ($value) = @_;
    $value = lc($value || 'visible');
    return $REPLY_STATUS{$value} ? $value : 'visible';
}

sub _follow_status {
    my ($value) = @_;
    $value = lc($value || 'active');
    return $FOLLOW_STATUS{$value} ? $value : 'active';
}

sub _report_status {
    my ($value) = @_;
    $value = lc($value || 'open');
    return $value =~ /\A(?:open|reviewed|dismissed|actioned)\z/ ? $value : 'open';
}

sub _system_moderation_action {
    my ($value, $prefix) = @_;
    $value = lc($value || '');
    $value =~ s/[^a-z0-9_]+/_/g;
    return '' unless length $value;
    return $value if $value =~ /\A\Q$prefix\E_report_(?:post|reply|profile)\z/;
    die "$prefix system moderation action is invalid";
}

sub _moderation_details {
    my (%details) = @_;
    delete $details{system_action} unless length($details{system_action} || '');
    return \%details;
}

sub _positive_int {
    my ($value, $default) = @_;
    return $default unless defined($value) && "$value" =~ /\A[0-9]+\z/;
    return int($value);
}

sub _reaction {
    my ($value) = @_;
    $value = lc($value || 'like');
    $value =~ s/[^a-z0-9_.-]+/_/g;
    return substr($value || 'like', 0, 40);
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

sub _limit {
    my ($value, $default, $min, $max) = @_;
    $value = $default unless defined $value && $value =~ /\A[0-9]+\z/;
    $value = int($value);
    $value = $min if $value < $min;
    $value = $max if $value > $max;
    return $value;
}

sub _offset {
    my ($offset, $page, $limit) = @_;
    if (defined($offset) && "$offset" =~ /\A[0-9]+\z/) {
        return int($offset);
    }
    if (defined($page) && "$page" =~ /\A[0-9]+\z/ && int($page) > 1) {
        return (int($page) - 1) * int($limit || 1);
    }
    return 0;
}

sub _profile_url {
    my ($profile) = @_;
    return '/social' unless $profile && length($profile->{handle} || '');
    return '/social/@' . $profile->{handle};
}

1;
