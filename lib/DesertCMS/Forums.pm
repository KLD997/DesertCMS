package DesertCMS::Forums;

use strict;
use warnings;
use DesertCMS::Util qw(now slugify);

my %CATEGORY_STATUS = map { $_ => 1 } qw(open locked hidden);
my %CATEGORY_VISIBILITY = map { $_ => 1 } qw(public accounts moderators);
my %TOPIC_STATUS = map { $_ => 1 } qw(open locked hidden deleted);
my %POST_STATUS = map { $_ => 1 } qw(visible hidden deleted reported);

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

sub save_category {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $title = _clean_text($args{title}, 160);
    die "category title is required" unless length $title;
    my $slug = slugify($args{slug} || $title);
    my $description = _clean_text($args{description}, 500);
    my $position = int($args{position} || 100);
    my $status = _category_status($args{status});
    my $visibility = _category_visibility($args{visibility});
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    if ($id) {
        $dbh->do(
            q{
                UPDATE forum_categories
                SET title = ?, slug = ?, description = ?, position = ?, status = ?, visibility = ?, updated_at = ?
                WHERE id = ?
            },
            undef,
            $title, $slug, $description, $position, $status, $visibility, $ts, $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO forum_categories (title, slug, description, position, status, visibility, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $title, $slug, $description, $position, $status, $visibility, $ts, $ts
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->category_by_id($id);
}

sub categories {
    my ($self, %args) = @_;
    my $include_hidden = $args{include_hidden} ? 1 : 0;
    my $visibility_where = $include_hidden ? '' : $self->_category_visibility_sql('c', $args{viewer_account_id});
    my @where;
    push @where, "c.status <> 'hidden'" unless $include_hidden;
    push @where, $visibility_where if length $visibility_where;
    my $where = @where ? 'WHERE ' . join(' AND ', @where) : '';
    my $topic_join = $include_hidden
        ? "t.category_id = c.id AND t.status <> 'deleted'"
        : "t.category_id = c.id AND t.status NOT IN ('hidden', 'deleted') AND EXISTS (SELECT 1 FROM user_accounts ta WHERE ta.id = t.account_id AND ta.status = 'active')";
    my $post_join = $include_hidden
        ? "p.topic_id = t.id AND p.status <> 'deleted'"
        : "p.topic_id = t.id AND p.status = 'visible' AND EXISTS (SELECT 1 FROM user_accounts pa WHERE pa.id = p.account_id AND pa.status = 'active')";
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT c.*,
                   COUNT(DISTINCT t.id) AS topic_count,
                   COUNT(p.id) AS post_count,
                   MAX(COALESCE(t.last_reply_at, t.created_at)) AS last_activity_at
            FROM forum_categories c
            LEFT JOIN forum_topics t ON $topic_join
            LEFT JOIN forum_posts p ON $post_join
            $where
            GROUP BY c.id
            ORDER BY c.position, lower(c.title), c.id
        },
        { Slice => {} }
    );
}

sub category_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM forum_categories WHERE id = ?', undef, int($id));
}

sub category_by_slug {
    my ($self, $slug) = @_;
    $slug = slugify($slug || '');
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM forum_categories WHERE slug = ?', undef, $slug);
}

sub create_topic {
    my ($self, %args) = @_;
    my $category_id = int($args{category_id} || 0);
    my $account_id = int($args{account_id} || 0);
    my $ip_address = _clean_ip($args{ip_address});
    my $title = _clean_text($args{title}, 180);
    my $body = _clean_text($args{body}, 8000);
    die "category, account, title, and body are required" unless $category_id > 0 && $account_id > 0 && length($title) && length($body);
    my $category = $self->category_by_id($category_id) or die "forum category was not found";
    my ($allowed, $reason) = $self->can_account(action => 'create_topic', account_id => $account_id, category => $category);
    die "forum permission denied: $reason" unless $allowed;
    $self->_enforce_write_limits(account_id => $account_id, ip_address => $ip_address, body => $body);
    my $slug = $self->_unique_topic_slug($category_id, $args{slug} || $title);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my $topic_id;
    $dbh->begin_work;
    eval {
        $dbh->do(
            q{
                INSERT INTO forum_topics (category_id, account_id, title, slug, status, pinned, ip_address, last_reply_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, 'open', 0, ?, ?, ?, ?)
            },
            undef,
            $category_id, $account_id, $title, $slug, $ip_address, $ts, $ts, $ts
        );
        $topic_id = int($dbh->sqlite_last_insert_rowid);
        $dbh->do(
            q{
                INSERT INTO forum_posts (topic_id, account_id, parent_id, body, status, ip_address, created_at, updated_at)
                VALUES (?, ?, NULL, ?, 'visible', ?, ?, ?)
            },
            undef,
            $topic_id, $account_id, $body, $ip_address, $ts, $ts
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'topic create failed';
        eval { $dbh->rollback };
        die $err;
    };
    my $topic = $self->topic_by_id($topic_id);
    $self->_emit_notification(
        audience             => 'public',
        topic                => 'forums.topic_created',
        module_key           => 'forums',
        title                => 'New forum topic',
        body                 => $topic->{title} || $title,
        actor_account_id     => $account_id,
        entity_type          => 'forum_topic',
        entity_id            => $topic->{id},
        url                  => _topic_url($topic),
        details              => { category_id => $category_id },
    );
    $self->_emit_mentions(
        body             => $body,
        actor_account_id => $account_id,
        topic_key        => 'forums.mention',
        entity_type      => 'forum_topic',
        entity_id        => $topic->{id},
        url              => _topic_url($topic),
    );
    return $topic;
}

sub topics_for_category {
    my ($self, $category_id, %args) = @_;
    return [] unless int($category_id || 0) > 0;
    my $include_hidden = $args{include_hidden} ? 1 : 0;
    my $category = $self->category_by_id($category_id);
    return [] unless $category;
    return [] if !$include_hidden && ($category->{status} || '') eq 'hidden';
    my ($can_view) = $self->can_view_category(category => $category, viewer_account_id => $args{viewer_account_id}, include_hidden => $include_hidden);
    return [] unless $can_view;
    my $where = $include_hidden ? '' : "AND t.status NOT IN ('hidden', 'deleted') AND a.status = 'active'";
    my $post_join = $include_hidden
        ? "p.topic_id = t.id AND p.status <> 'deleted'"
        : "p.topic_id = t.id AND p.status = 'visible' AND EXISTS (SELECT 1 FROM user_accounts pa WHERE pa.id = p.account_id AND pa.status = 'active')";
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT t.*, a.display_name, a.username, a.status AS account_status, COUNT(p.id) AS reply_count
            FROM forum_topics t
            LEFT JOIN user_accounts a ON a.id = t.account_id
            LEFT JOIN forum_posts p ON $post_join
            WHERE t.category_id = ?
            $where
            GROUP BY t.id
            ORDER BY t.pinned DESC, COALESCE(t.last_reply_at, t.created_at) DESC, t.id DESC
        },
        { Slice => {} },
        int($category_id)
    );
}

sub latest_topics {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 20, 1, 100);
    my $category_visibility = $self->_category_visibility_sql('c', $args{viewer_account_id});
    $category_visibility = length $category_visibility ? "AND $category_visibility" : '';
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT t.*, c.title AS category_title, c.slug AS category_slug,
                   a.display_name, a.username, a.status AS account_status, COUNT(p.id) AS reply_count
            FROM forum_topics t
            JOIN forum_categories c ON c.id = t.category_id
            LEFT JOIN user_accounts a ON a.id = t.account_id
            LEFT JOIN forum_posts p ON p.topic_id = t.id
                AND p.status = 'visible'
                AND EXISTS (SELECT 1 FROM user_accounts pa WHERE pa.id = p.account_id AND pa.status = 'active')
            WHERE t.status NOT IN ('hidden', 'deleted')
              AND c.status <> 'hidden'
              $category_visibility
              AND a.status = 'active'
            GROUP BY t.id
            ORDER BY t.pinned DESC, COALESCE(t.last_reply_at, t.created_at) DESC, t.id DESC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub topic_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT t.*, c.title AS category_title, c.slug AS category_slug, c.status AS category_status,
                   c.visibility AS category_visibility,
                   a.display_name, a.username, a.status AS account_status
            FROM forum_topics t
            JOIN forum_categories c ON c.id = t.category_id
            LEFT JOIN user_accounts a ON a.id = t.account_id
            WHERE t.id = ?
        },
        undef,
        int($id)
    );
}

sub topic_by_slug {
    my ($self, $category_slug, $topic_slug, %args) = @_;
    $category_slug = slugify($category_slug || '');
    $topic_slug = slugify($topic_slug || '');
    my $include_hidden = $args{include_hidden} ? 1 : 0;
    my $category_visibility = $include_hidden ? '' : $self->_category_visibility_sql('c', $args{viewer_account_id});
    my $visibility = $include_hidden ? '' : "AND c.status <> 'hidden' AND t.status NOT IN ('hidden', 'deleted') AND a.status = 'active'";
    $visibility .= " AND $category_visibility" if length $category_visibility;
    return $self->{db}->dbh->selectrow_hashref(
        qq{
            SELECT t.*, c.title AS category_title, c.slug AS category_slug, c.status AS category_status,
                   c.visibility AS category_visibility,
                   a.display_name, a.username, a.status AS account_status
            FROM forum_topics t
            JOIN forum_categories c ON c.id = t.category_id
            LEFT JOIN user_accounts a ON a.id = t.account_id
            WHERE c.slug = ? AND t.slug = ?
            $visibility
        },
        undef,
        $category_slug,
        $topic_slug
    );
}

sub posts_for_topic {
    my ($self, $topic_id, %args) = @_;
    return [] unless int($topic_id || 0) > 0;
    my $include_hidden = $args{include_hidden} ? 1 : 0;
    if (!$include_hidden) {
        my $topic = $self->topic_by_id($topic_id);
        return [] unless $topic;
        return [] if ($topic->{category_status} || '') eq 'hidden';
        return [] if ($topic->{status} || '') =~ /\A(?:hidden|deleted)\z/;
        my ($can_view) = $self->can_view_topic(topic => $topic, viewer_account_id => $args{viewer_account_id});
        return [] unless $can_view;
    }
    my $where = $include_hidden ? '' : "AND p.status = 'visible' AND a.status = 'active'";
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT p.*, a.display_name, a.username, a.status AS account_status,
                   t.status AS topic_status, c.status AS category_status, c.visibility AS category_visibility
            FROM forum_posts p
            JOIN forum_topics t ON t.id = p.topic_id
            JOIN forum_categories c ON c.id = t.category_id
            LEFT JOIN user_accounts a ON a.id = p.account_id
            WHERE p.topic_id = ?
            $where
            ORDER BY p.created_at, p.id
        },
        { Slice => {} },
        int($topic_id)
    );
}

sub add_reply {
    my ($self, %args) = @_;
    my $topic_id = int($args{topic_id} || 0);
    my $account_id = int($args{account_id} || 0);
    my $ip_address = _clean_ip($args{ip_address});
    my $body = _clean_text($args{body}, 8000);
    die "topic, account, and reply body are required" unless $topic_id > 0 && $account_id > 0 && length $body;
    my $topic = $self->topic_by_id($topic_id) or die "forum topic was not found";
    my ($allowed, $reason) = $self->can_account(action => 'reply', account_id => $account_id, topic => $topic);
    die "forum permission denied: $reason" unless $allowed;
    $self->_enforce_write_limits(account_id => $account_id, ip_address => $ip_address, body => $body);
    my $ts = now();
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        q{
            INSERT INTO forum_posts (topic_id, account_id, parent_id, body, status, ip_address, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'visible', ?, ?, ?)
        },
        undef,
        $topic_id,
        $account_id,
        int($args{parent_id} || 0) || undef,
        $body,
        $ip_address,
        $ts,
        $ts
    );
    my $id = int($dbh->sqlite_last_insert_rowid);
    $dbh->do('UPDATE forum_topics SET last_reply_at = ?, updated_at = ? WHERE id = ?', undef, $ts, $ts, $topic_id);
    my $post = $dbh->selectrow_hashref('SELECT * FROM forum_posts WHERE id = ?', undef, $id);
    $self->_emit_notification(
        audience             => 'user',
        topic                => 'forums.reply_created',
        module_key           => 'forums',
        title                => 'New forum reply',
        body                 => $topic->{title} || 'A forum topic has a new reply.',
        actor_account_id     => $account_id,
        recipient_account_id => int($topic->{account_id} || 0) || undef,
        entity_type          => 'forum_post',
        entity_id            => $post->{id},
        url                  => _topic_url($topic),
        details              => { topic_id => $topic_id },
    ) if int($topic->{account_id} || 0) && int($topic->{account_id} || 0) != $account_id;
    $self->_emit_mentions(
        body             => $body,
        actor_account_id => $account_id,
        topic_key        => 'forums.mention',
        entity_type      => 'forum_post',
        entity_id        => $post->{id},
        url              => _topic_url($topic),
    );
    return $post;
}

sub set_topic_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "topic id is required" unless $id > 0;
    my $existing = $self->topic_by_id($id) or die "forum topic was not found";
    my $status = _topic_status($args{status});
    my %actor = $self->_moderation_actor(%args);
    my $note = _clean_text($args{moderator_note}, 500);
    return $existing if ($existing->{status} || '') eq $status && ($existing->{moderator_note} || '') eq $note;
    $self->{db}->dbh->do(
        'UPDATE forum_topics SET status = ?, moderator_note = ?, updated_at = ? WHERE id = ?',
        undef,
        $status,
        $note,
        now(),
        $id
    );
    my $topic = $self->topic_by_id($id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'forums.moderation_action',
        module_key       => 'forums',
        title            => 'Forum topic status changed',
        body             => $topic->{title} || 'A forum topic was moderated.',
        entity_type      => 'forum_topic',
        entity_id        => $id,
        url              => _topic_url($topic),
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        details          => _moderation_details(status => $status, moderator_note => $note, system_action => $actor{system_action}),
    );
    return $topic;
}

sub pin_topic {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "topic id is required" unless $id > 0;
    my $existing = $self->topic_by_id($id) or die "forum topic was not found";
    my %actor = $self->_moderation_actor(%args);
    my $pinned = $args{pinned} ? 1 : 0;
    return $existing if int($existing->{pinned} || 0) == $pinned;
    $self->{db}->dbh->do(
        'UPDATE forum_topics SET pinned = ?, updated_at = ? WHERE id = ?',
        undef,
        $pinned,
        now(),
        $id
    );
    my $topic = $self->topic_by_id($id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'forums.moderation_action',
        module_key       => 'forums',
        title            => 'Forum topic pin changed',
        body             => $topic->{title} || 'A forum topic pin state changed.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'forum_topic',
        entity_id        => $id,
        url              => _topic_url($topic),
        details          => _moderation_details(pinned => $pinned, system_action => $actor{system_action}),
    );
    return $topic;
}

sub set_post_status {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "post id is required" unless $id > 0;
    my $existing = $self->post_by_id($id) or die "forum post was not found";
    my $status = _post_status($args{status});
    my %actor = $self->_moderation_actor(%args);
    my $note = _clean_text($args{moderator_note}, 500);
    return $existing if ($existing->{status} || '') eq $status && ($existing->{moderator_note} || '') eq $note;
    $self->{db}->dbh->do(
        'UPDATE forum_posts SET status = ?, moderator_note = ?, updated_at = ? WHERE id = ?',
        undef,
        $status,
        $note,
        now(),
        $id
    );
    my $post = $self->post_by_id($id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'forums.moderation_action',
        module_key       => 'forums',
        title            => 'Forum post status changed',
        body             => 'A forum post was moderated.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'forum_post',
        entity_id        => $id,
        details          => _moderation_details(status => $status, topic_id => $post->{topic_id}, moderator_note => $note, system_action => $actor{system_action}),
    );
    return $post;
}

sub soft_delete_topic {
    my ($self, %args) = @_;
    $args{status} = 'deleted';
    return $self->set_topic_status(%args);
}

sub soft_delete_post {
    my ($self, %args) = @_;
    $args{status} = 'deleted';
    return $self->set_post_status(%args);
}

sub post_by_id {
    my ($self, $id) = @_;
    return undef unless int($id || 0) > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT p.*, a.status AS account_status,
                   t.status AS topic_status, t.account_id AS topic_account_id, ta.status AS topic_account_status,
                   t.category_id, c.status AS category_status, c.visibility AS category_visibility
            FROM forum_posts p
            JOIN forum_topics t ON t.id = p.topic_id
            JOIN forum_categories c ON c.id = t.category_id
            LEFT JOIN user_accounts a ON a.id = p.account_id
            LEFT JOIN user_accounts ta ON ta.id = t.account_id
            WHERE p.id = ?
        },
        undef,
        int($id)
    );
}

sub edit_post {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $account_id = int($args{account_id} || 0);
    my $body = _clean_text($args{body}, 8000);
    die "post, account, and body are required" unless $id > 0 && $account_id > 0 && length $body;
    my $post = $self->post_by_id($id) or die "forum post was not found";
    my ($allowed, $reason) = $self->can_edit_post(post => $post, account_id => $account_id);
    die "forum permission denied: $reason" unless $allowed;
    $self->{db}->dbh->do(
        'UPDATE forum_posts SET body = ?, updated_at = ? WHERE id = ?',
        undef,
        $body,
        now(),
        $id
    );
    return $self->post_by_id($id);
}

sub delete_post {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $account_id = int($args{account_id} || 0);
    die "post and account are required" unless $id > 0 && $account_id > 0;
    my $post = $self->post_by_id($id) or die "forum post was not found";
    my ($allowed, $reason) = $self->can_delete_post(post => $post, account_id => $account_id);
    die "forum permission denied: $reason" unless $allowed;
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        'UPDATE forum_posts SET status = ?, updated_at = ? WHERE id = ?',
        undef,
        'deleted',
        now(),
        $id
    );
    $self->_refresh_topic_activity($post->{topic_id});
    return $self->post_by_id($id);
}

sub can_edit_post {
    my ($self, %args) = @_;
    my $post = $args{post};
    my $id = int($args{id} || $args{post_id} || (ref($post) eq 'HASH' ? $post->{id} : 0) || 0);
    my $account_id = int($args{account_id} || 0);
    return _permission(0, 'post and account are required') unless $id > 0 && $account_id > 0;
    return _permission(0, 'account is not active') unless $self->_account_active($account_id);
    $post ||= $self->post_by_id($id);
    return _permission(0, 'forum post was not found') unless $post;
    my $moderator = $self->_is_moderator($account_id);
    return _permission(1, '') if $moderator;
    return _permission(0, 'forum post cannot be edited') if ($post->{status} || '') eq 'deleted';
    return _permission(0, 'forum post belongs to another account') unless int($post->{account_id} || 0) == $account_id;
    my $window = _positive_int($self->{config}->get('forum_edit_window_seconds') || 900, 900);
    return _permission(0, 'forum post edit window has closed')
        unless int($post->{created_at} || 0) >= now() - $window;
    return _permission(1, '');
}

sub can_delete_post {
    my ($self, %args) = @_;
    my $post = $args{post};
    my $id = int($args{id} || $args{post_id} || (ref($post) eq 'HASH' ? $post->{id} : 0) || 0);
    my $account_id = int($args{account_id} || 0);
    return _permission(0, 'post and account are required') unless $id > 0 && $account_id > 0;
    return _permission(0, 'account is not active') unless $self->_account_active($account_id);
    $post ||= $self->post_by_id($id);
    return _permission(0, 'forum post was not found') unless $post;
    my $moderator = $self->_is_moderator($account_id);
    return _permission(1, '') if $moderator;
    return _permission(0, 'forum post cannot be deleted') if ($post->{status} || '') eq 'deleted';
    return _permission(0, 'forum post belongs to another account') unless int($post->{account_id} || 0) == $account_id;
    return _permission(0, 'forum topic starter cannot be deleted here') if $self->_topic_starter_post_id($post->{topic_id}) == int($post->{id} || 0);
    my $window = _positive_int($self->{config}->get('forum_edit_window_seconds') || 900, 900);
    return _permission(0, 'forum post delete window has closed')
        unless int($post->{created_at} || 0) >= now() - $window;
    return _permission(1, '');
}

sub report_post {
    my ($self, %args) = @_;
    my $post = $self->post_by_id($args{id} || $args{post_id}) or die "forum post was not found";
    my $reporter_id = int($args{reporter_account_id} || 0);
    my ($allowed, $reason) = $self->can_account(action => 'report', account_id => $reporter_id, post => $post);
    die "forum permission denied: $reason" unless $allowed;
    my $report = $self->_create_report(
        topic_id            => $post->{topic_id},
        post_id             => $post->{id},
        reporter_account_id => $reporter_id,
        reason              => $args{reason},
    );
    $self->set_post_status(id => $post->{id}, status => 'reported', system_action => 'forum_report_post');
    $self->_emit_notification(
        audience             => 'admin',
        topic                => 'forums.reported',
        module_key           => 'forums',
        severity             => 'warning',
        title                => 'Forum post reported',
        body                 => _clean_text($args{reason}, 160) || 'A forum post was reported.',
        actor_account_id     => int($args{reporter_account_id} || 0) || undef,
        entity_type          => 'forum_report',
        entity_id            => $report->{id},
        details              => { post_id => $post->{id}, topic_id => $post->{topic_id} },
    );
    return $report;
}

sub report_topic {
    my ($self, %args) = @_;
    my $topic = $self->topic_by_id($args{id} || $args{topic_id}) or die "forum topic was not found";
    my $reporter_id = int($args{reporter_account_id} || 0);
    my ($allowed, $reason) = $self->can_account(action => 'report', account_id => $reporter_id, topic => $topic);
    die "forum permission denied: $reason" unless $allowed;
    my $report = $self->_create_report(
        topic_id            => $topic->{id},
        reporter_account_id => $reporter_id,
        reason              => $args{reason},
    );
    $self->_emit_notification(
        audience             => 'admin',
        topic                => 'forums.reported',
        module_key           => 'forums',
        severity             => 'warning',
        title                => 'Forum topic reported',
        body                 => _clean_text($args{reason}, 160) || ($topic->{title} || 'A forum topic was reported.'),
        actor_account_id     => int($args{reporter_account_id} || 0) || undef,
        entity_type          => 'forum_report',
        entity_id            => $report->{id},
        url                  => _topic_url($topic),
        details              => { topic_id => $topic->{id} },
    );
    return $report;
}

sub reports {
    my ($self, %args) = @_;
    my $status = _report_status($args{status} || 'open');
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT r.*, t.title AS topic_title, t.status AS topic_status,
                   p.body AS post_body, p.status AS post_status,
                   a.display_name AS reporter_display_name, a.username AS reporter_username
            FROM forum_reports r
            LEFT JOIN forum_topics t ON t.id = r.topic_id
            LEFT JOIN forum_posts p ON p.id = r.post_id
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
    my $existing = $self->{db}->dbh->selectrow_hashref('SELECT * FROM forum_reports WHERE id = ?', undef, $id)
        or die "forum report was not found";
    my $status = _report_status($args{status});
    my %actor = $self->_moderation_actor(%args);
    my $note = _clean_text($args{moderator_note}, 500);
    return $existing if ($existing->{status} || '') eq $status && ($existing->{moderator_note} || '') eq $note;
    my $resolved = $status eq 'open' ? undef : ($existing->{resolved_at} || now());
    $self->{db}->dbh->do(
        'UPDATE forum_reports SET status = ?, moderator_note = ?, updated_at = ?, resolved_at = ? WHERE id = ?',
        undef,
        $status,
        $note,
        now(),
        $resolved,
        $id
    );
    my $report = $self->{db}->dbh->selectrow_hashref('SELECT * FROM forum_reports WHERE id = ?', undef, $id);
    $self->_emit_notification(
        audience         => 'admin',
        topic            => 'forums.moderation_needed',
        module_key       => 'forums',
        title            => 'Forum report status changed',
        body             => _clean_text($args{moderator_note}, 160) || 'A forum report was moderated.',
        actor_account_id => $actor{actor_account_id} || undef,
        actor_user_id    => $actor{actor_user_id} || undef,
        entity_type      => 'forum_report',
        entity_id        => $id,
        details          => _moderation_details(status => $status, system_action => $actor{system_action}),
    );
    return $report;
}

sub can_view_category {
    my ($self, %args) = @_;
    my $category = $args{category} || $self->category_by_id($args{category_id});
    return _permission(0, 'category was not found') unless $category;
    return _permission(1, '') if $args{include_hidden};
    return _permission(0, 'category is hidden') if ($category->{status} || '') eq 'hidden';
    my $visibility = _category_visibility($category->{visibility});
    return _permission(1, '') if $visibility eq 'public';
    my $viewer = int($args{viewer_account_id} || $args{account_id} || 0);
    return _permission(0, 'account required') unless $viewer > 0;
    return _permission(0, 'account is not active') unless $self->_account_active($viewer);
    return _permission(1, '') if $visibility eq 'accounts';
    return _permission($self->_is_moderator($viewer) ? 1 : 0, 'forum moderator permission required');
}

sub can_view_topic {
    my ($self, %args) = @_;
    my $topic = $args{topic} || $self->topic_by_id($args{topic_id});
    return _permission(0, 'topic was not found') unless $topic;
    return _permission(0, 'category is hidden') if ($topic->{category_status} || '') eq 'hidden';
    return _permission(0, 'topic is not visible') unless $self->_row_account_active($topic);
    return _permission(0, 'topic is not visible') if ($topic->{status} || '') =~ /\A(?:hidden|deleted)\z/;
    return $self->can_view_category(
        category => {
            id         => $topic->{category_id},
            status     => $topic->{category_status},
            visibility => $topic->{category_visibility},
        },
        viewer_account_id => $args{viewer_account_id} || $args{account_id},
    );
}

sub can_account {
    my ($self, %args) = @_;
    my $action = _permission_action($args{action});
    my $account_id = int($args{account_id} || 0);
    return _permission(0, 'account required') unless $account_id > 0;
    return _permission(0, 'account is not active') unless $self->_account_active($account_id);
    my $moderator = $self->_is_moderator($account_id);
    return _permission(1, '') if $moderator && $action =~ /\A(?:view|lock|hide|pin|moderate|delete)\z/;
    if ($action eq 'create_topic') {
        my $category = $args{category} || $self->category_by_id($args{category_id});
        return _permission(0, 'category was not found') unless $category;
        my ($can_view, $view_reason) = $self->can_view_category(category => $category, viewer_account_id => $account_id);
        return _permission(0, $view_reason) unless $can_view;
        return _permission(0, 'account is too new') unless $self->_account_old_enough($account_id);
        return _permission(($category->{status} || '') eq 'open' ? 1 : 0, 'category is not open');
    }
    if ($action eq 'reply') {
        my $topic = $args{topic} || $self->topic_by_id($args{topic_id});
        return _permission(0, 'topic was not found') unless $topic;
        my ($can_view, $view_reason) = $self->can_view_topic(topic => $topic, viewer_account_id => $account_id);
        return _permission(0, $view_reason) unless $can_view;
        return _permission(0, 'account is too new') unless $self->_account_old_enough($account_id);
        return _permission(0, 'topic is not visible') unless $self->_row_account_active($topic);
        return _permission(0, 'category is not open') if ($topic->{category_status} || 'open') ne 'open';
        return _permission(($topic->{status} || '') eq 'open' ? 1 : 0, 'topic is not open');
    }
    if ($action eq 'view' || $action eq 'report') {
        my $category = $args{category} || (int($args{category_id} || 0) ? $self->category_by_id($args{category_id}) : undef);
        my $topic = $args{topic} || $self->topic_by_id($args{topic_id});
        my $post = $args{post} || $self->post_by_id($args{post_id});
        $topic ||= $self->topic_by_id($post->{topic_id}) if $post && int($post->{topic_id} || 0);
        return _permission(0, 'category is hidden') if $category && ($category->{status} || '') eq 'hidden';
        if ($category) {
            my ($can_view, $view_reason) = $self->can_view_category(category => $category, viewer_account_id => $account_id);
            return _permission(0, $view_reason) unless $can_view;
        }
        if ($topic) {
            my ($can_view, $view_reason) = $self->can_view_topic(topic => $topic, viewer_account_id => $account_id);
            return _permission(0, $view_reason) unless $can_view;
        }
        return _permission(0, 'post is not visible') if $post && !$self->_row_account_active($post);
        return _permission(0, 'post is not visible') if $post && ($post->{status} || '') =~ /\A(?:hidden|deleted)\z/;
        return _permission(1, '');
    }
    return _permission(0, 'moderator permission required');
}

sub _unique_topic_slug {
    my ($self, $category_id, $title) = @_;
    my $base = slugify($title || 'topic');
    my $slug = $base;
    my $i = 2;
    while ($self->{db}->dbh->selectrow_array('SELECT 1 FROM forum_topics WHERE category_id = ? AND slug = ?', undef, $category_id, $slug)) {
        $slug = "$base-$i";
        $i++;
    }
    return $slug;
}

sub _create_report {
    my ($self, %args) = @_;
    my $topic_id = int($args{topic_id} || 0) || undef;
    my $post_id = int($args{post_id} || 0) || undef;
    my $reporter_id = int($args{reporter_account_id} || 0) || undef;
    die "topic or post is required" unless $topic_id || $post_id;
    my @where = ("status = 'open'");
    my @bind;
    for my $field (
        [ topic_id            => $topic_id ],
        [ post_id             => $post_id ],
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
        'SELECT id FROM forum_reports WHERE ' . join(' AND ', @where) . ' LIMIT 1',
        undef,
        @bind
    );
    die "duplicate forum report suppressed" if $existing;
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO forum_reports
                (topic_id, post_id, reporter_account_id, reason, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'open', ?, ?)
        },
        undef,
        $topic_id,
        $post_id,
        $reporter_id,
        _clean_text($args{reason}, 500),
        $ts,
        $ts
    );
    my $id = int($self->{db}->dbh->sqlite_last_insert_rowid);
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM forum_reports WHERE id = ?', undef, $id);
}

sub _topic_starter_post_id {
    my ($self, $topic_id) = @_;
    return 0 unless int($topic_id || 0) > 0;
    my ($id) = $self->{db}->dbh->selectrow_array(
        'SELECT id FROM forum_posts WHERE topic_id = ? ORDER BY created_at ASC, id ASC LIMIT 1',
        undef,
        int($topic_id)
    );
    return int($id || 0);
}

sub _refresh_topic_activity {
    my ($self, $topic_id) = @_;
    return unless int($topic_id || 0) > 0;
    my ($last) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT MAX(created_at)
            FROM forum_posts
            WHERE topic_id = ?
              AND status = 'visible'
        },
        undef,
        int($topic_id)
    );
    $self->{db}->dbh->do(
        'UPDATE forum_topics SET last_reply_at = ?, updated_at = ? WHERE id = ?',
        undef,
        int($last || now()),
        now(),
        int($topic_id)
    );
}

sub _emit_mentions {
    my ($self, %args) = @_;
    for my $account (@{ $self->_mentioned_accounts($args{body}) }) {
        next if int($account->{id} || 0) == int($args{actor_account_id} || 0);
        $self->_emit_notification(
            audience             => 'user',
            topic                => $args{topic_key} || 'forums.mention',
            module_key           => 'forums',
            title                => 'Forum mention',
            body                 => 'You were mentioned in a forum post.',
            actor_account_id     => int($args{actor_account_id} || 0) || undef,
            recipient_account_id => int($account->{id} || 0),
            entity_type          => $args{entity_type} || 'forum_post',
            entity_id            => $args{entity_id},
            url                  => $args{url},
        );
    }
}

sub _mentioned_accounts {
    my ($self, $body) = @_;
    my %seen;
    my @handles = grep { !$seen{$_}++ } map { lc($_) } (($body || '') =~ /\@([A-Za-z0-9_.-]{2,80})/g);
    return [] unless @handles;
    my $placeholders = join ',', ('?') x @handles;
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT id, username, display_name
            FROM user_accounts
            WHERE lower(username) IN ($placeholders)
              AND status = 'active'
        },
        { Slice => {} },
        @handles
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

sub _enforce_write_limits {
    my ($self, %args) = @_;
    my $account_id = int($args{account_id} || 0);
    return unless $account_id > 0;
    die "forum account is too new" unless $self->_account_old_enough($account_id);
    my $window = _positive_int($self->{config}->get('forum_rate_window_seconds') || 600, 600);
    my $max = _positive_int($self->{config}->get('forum_max_posts_per_window') || 30, 30);
    my ($count) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM forum_posts WHERE account_id = ? AND created_at >= ?',
        undef,
        $account_id,
        now() - $window
    );
    die "forum post rate limit exceeded" if int($count || 0) >= $max;
    my $ip_address = _clean_ip($args{ip_address});
    if (length $ip_address) {
        my $ip_max = _positive_int($self->{config}->get('forum_max_posts_per_ip_window') || $max, $max);
        my ($ip_count) = $self->{db}->dbh->selectrow_array(
            'SELECT COUNT(*) FROM forum_posts WHERE ip_address = ? AND created_at >= ?',
            undef,
            $ip_address,
            now() - $window
        );
        die "forum ip rate limit exceeded" if int($ip_count || 0) >= $ip_max;
    }
    my $body = _clean_text($args{body}, 8000);
    return unless length $body;
    my ($duplicate) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT 1
            FROM forum_posts
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
    die "duplicate forum post suppressed" if $duplicate;
}

sub _account_old_enough {
    my ($self, $account_id) = @_;
    my $min_age = _positive_int($self->{config}->get('forum_min_account_age_seconds') || 0, 0);
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

sub _row_account_active {
    my ($self, $row) = @_;
    return 0 unless $row && ref($row) eq 'HASH';
    my $status = $row->{account_status};
    return ($status || '') eq 'active' ? 1 : 0 if length($status || '');
    return $self->_account_active($row->{account_id});
}

sub _is_moderator {
    my ($self, $account_id) = @_;
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
    die "forum moderator account is required" unless int($account_id || 0) > 0;
    die "forum moderator permission required" unless $self->_account_active($account_id) && $self->_is_moderator($account_id);
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
        die "forum admin user is not active" unless $self->_admin_user_active($admin_user_id);
        return (actor_user_id => $admin_user_id);
    }
    my $system_action = _system_moderation_action($args{system_action}, 'forum');
    return (system_action => $system_action) if length $system_action;
    die "forum moderator account or active admin user is required";
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

sub _permission_action {
    my ($value) = @_;
    $value = lc($value || 'view');
    $value =~ s/[^a-z0-9_]+/_/g;
    return $value;
}

sub _category_status {
    my ($value) = @_;
    $value = lc($value || 'open');
    return $CATEGORY_STATUS{$value} ? $value : 'open';
}

sub _category_visibility {
    my ($value) = @_;
    $value = lc($value || 'public');
    return $CATEGORY_VISIBILITY{$value} ? $value : 'public';
}

sub _category_visibility_sql {
    my ($self, $alias, $viewer_account_id) = @_;
    $alias ||= 'c';
    my $column = "$alias.visibility";
    my $viewer = int($viewer_account_id || 0);
    return "$column = 'public'" unless $viewer > 0 && $self->_account_active($viewer);
    return "$column IN ('public', 'accounts', 'moderators')" if $self->_is_moderator($viewer);
    return "$column IN ('public', 'accounts')";
}

sub _topic_status {
    my ($value) = @_;
    $value = lc($value || 'open');
    return $TOPIC_STATUS{$value} ? $value : 'open';
}

sub _post_status {
    my ($value) = @_;
    $value = lc($value || 'visible');
    return $POST_STATUS{$value} ? $value : 'visible';
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
    return $value if $value =~ /\A\Q$prefix\E_report_(?:post|topic)\z/;
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

sub _topic_url {
    my ($topic) = @_;
    return '' unless $topic;
    return '/forums/category/' . ($topic->{category_slug} || '') . '/' . ($topic->{slug} || '');
}

1;
