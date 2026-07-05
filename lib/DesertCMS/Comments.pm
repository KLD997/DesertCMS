package DesertCMS::Comments;

use strict;
use warnings;
use POSIX qw(strftime);
use DesertCMS::HTTP ();
use DesertCMS::Util qw(hmac_sha256_hex now random_hex);

my $MAX_NAME_BYTES = 40;
my $MAX_BODY_BYTES = 2000;
my $TOKEN_MAX_AGE = 180 * 24 * 60 * 60;

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub thread {
    my ($self, %args) = @_;
    my $content_id = int($args{content_id} || 0);
    my $post = $self->_published_post($content_id)
        or die "post not found";

    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT id, content_id, parent_id, author_name, body, status, created_at
            FROM comments
            WHERE content_id = ?
              AND status = 'visible'
            ORDER BY created_at ASC, id ASC
        },
        { Slice => {} },
        $content_id
    );

    my @comments = map { _public_comment($_) } @{$rows};
    return {
        post => {
            id    => int($post->{id}),
            title => $post->{title} || '',
            url   => _post_url($post),
        },
        count    => scalar @comments,
        comments => \@comments,
    };
}

sub admin_thread {
    my ($self, %args) = @_;
    my $content_id = int($args{content_id} || 0);
    my $post = $self->_admin_post($content_id)
        or die "post not found";

    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT id, content_id, parent_id, author_name, body, status,
                   created_at, updated_at
            FROM comments
            WHERE content_id = ?
              AND status = 'visible'
            ORDER BY created_at ASC, id ASC
        },
        { Slice => {} },
        $content_id
    );

    return {
        post => {
            id     => int($post->{id}),
            title  => $post->{title} || '',
            status => $post->{status} || '',
            url    => _post_url($post),
        },
        count    => scalar @{$rows},
        comments => [ map { _admin_comment($_) } @{$rows} ],
    };
}

sub delete_comment {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "comment not found" unless $id;

    my $row = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT c.id, c.content_id
            FROM comments c
            JOIN content_items post ON post.id = c.content_id
            WHERE c.id = ?
              AND post.type = 'post'
              AND post.deleted_at IS NULL
            LIMIT 1
        },
        undef,
        $id
    ) or die "comment not found";

    $self->{db}->dbh->do('DELETE FROM comments WHERE id = ?', undef, $id);

    return {
        id         => int($row->{id}),
        content_id => int($row->{content_id}),
    };
}

sub counts_for_posts {
    my ($self, @content_ids) = @_;
    my @ids = grep { defined $_ && /^\d+\z/ && int($_) > 0 } @content_ids;
    return {} unless @ids;

    my $placeholders = join ',', ('?') x @ids;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT content_id, COUNT(*) AS comment_count
            FROM comments
            WHERE content_id IN ($placeholders)
              AND status = 'visible'
            GROUP BY content_id
        },
        { Slice => {} },
        @ids
    );
    my %counts = map { int($_->{content_id}) => int($_->{comment_count} || 0) } @{$rows};
    return \%counts;
}

sub create {
    my ($self, %args) = @_;
    my $content_id = int($args{content_id} || 0);
    my $post = $self->_published_post($content_id)
        or die "post not found";

    my $parent_id = int($args{parent_id} || 0);
    if ($parent_id) {
        my ($parent_content_id) = $self->{db}->dbh->selectrow_array(
            q{
                SELECT content_id
                FROM comments
                WHERE id = ?
                  AND status = 'visible'
            },
            undef,
            $parent_id
        );
        die "parent comment not found" unless $parent_content_id && $parent_content_id == $content_id;
    } else {
        $parent_id = undef;
    }

    my ($token, $token_generated) = _clean_token($args{commenter_token});
    my $token_hash = $self->_hash('token', $token);
    my $ip = DesertCMS::HTTP::client_ip($args{request}, $self->{config});
    my $ip_hash = length $ip ? $self->_hash('ip', $ip) : '';
    my $ua = $args{request} ? ($args{request}->{user_agent} || '') : '';
    my $ua_hash = length $ua ? $self->_hash('ua', substr($ua, 0, 300)) : '';

    $self->_rate_limit($token_hash, $ip_hash);

    my $author_name = _clean_author($args{author_name});
    my $body = _clean_body($args{body});
    die "comment body is required" unless length $body;

    my $ts = now();
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        q{
            INSERT INTO comments
                (content_id, parent_id, author_name, body, status, commenter_token_hash,
                 ip_hash, user_agent_hash, created_at, updated_at)
            VALUES
                (?, ?, ?, ?, 'visible', ?, ?, ?, ?, ?)
        },
        undef,
        $post->{id},
        $parent_id,
        $author_name,
        $body,
        $token_hash,
        $ip_hash,
        $ua_hash,
        $ts,
        $ts
    );

    my $id = $dbh->sqlite_last_insert_rowid;
    my $comment = $dbh->selectrow_hashref(
        q{
            SELECT id, content_id, parent_id, author_name, body, status, created_at
            FROM comments
            WHERE id = ?
        },
        undef,
        $id
    );

    return {
        ok        => 1,
        token     => $token_generated ? $token : undef,
        comment   => _public_comment($comment),
        post_url  => _post_url($post),
    };
}

sub _admin_post {
    my ($self, $content_id) = @_;
    return undef unless $content_id;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT id, title, slug, status
            FROM content_items
            WHERE id = ?
              AND type = 'post'
              AND deleted_at IS NULL
            LIMIT 1
        },
        undef,
        $content_id
    );
}

sub notifications {
    my ($self, %args) = @_;
    my ($token) = _clean_token($args{commenter_token}, allow_generate => 0);
    return { replies => [] } unless length $token;

    my $token_hash = $self->_hash('token', $token);
    my $since = now() - $TOKEN_MAX_AGE;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT reply.id, reply.content_id, reply.parent_id, reply.author_name,
                   reply.body, reply.created_at, post.title, post.slug
            FROM comments reply
            JOIN comments mine ON mine.id = reply.parent_id
            JOIN content_items post ON post.id = reply.content_id
            WHERE mine.commenter_token_hash = ?
              AND reply.commenter_token_hash <> ?
              AND mine.status = 'visible'
              AND reply.status = 'visible'
              AND post.type = 'post'
              AND post.status = 'published'
              AND post.deleted_at IS NULL
              AND reply.created_at >= ?
            ORDER BY reply.created_at DESC, reply.id DESC
            LIMIT 50
        },
        { Slice => {} },
        $token_hash,
        $token_hash,
        $since
    );

    my @replies;
    for my $row (@{$rows}) {
        my $comment = _public_comment($row);
        $comment->{post_title} = $row->{title} || '';
        $comment->{post_url} = _post_url($row) . '#comment-' . int($row->{id});
        push @replies, $comment;
    }
    return { replies => \@replies };
}

sub _published_post {
    my ($self, $content_id) = @_;
    return undef unless $content_id;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT id, title, slug
            FROM content_items
            WHERE id = ?
              AND type = 'post'
              AND status = 'published'
              AND deleted_at IS NULL
            LIMIT 1
        },
        undef,
        $content_id
    );
}

sub _rate_limit {
    my ($self, $token_hash, $ip_hash) = @_;
    my $dbh = $self->{db}->dbh;
    my $minute = now() - 60;
    my $window = now() - (10 * 60);

    my ($token_recent) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM comments
            WHERE commenter_token_hash = ?
              AND created_at >= ?
        },
        undef,
        $token_hash,
        $minute
    );
    die "please wait before posting another comment" if ($token_recent || 0) >= 3;

    return unless length $ip_hash;
    my ($ip_recent) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM comments
            WHERE ip_hash = ?
              AND created_at >= ?
        },
        undef,
        $ip_hash,
        $window
    );
    die "too many comments from this connection" if ($ip_recent || 0) >= 10;
}

sub _hash {
    my ($self, $kind, $value) = @_;
    $value = '' unless defined $value;
    return hmac_sha256_hex('comments:' . $kind . ':' . $value, $self->{config}->app_secret);
}

sub _public_comment {
    my ($row) = @_;
    return {
        id          => int($row->{id} || 0),
        content_id  => int($row->{content_id} || 0),
        parent_id   => $row->{parent_id} ? int($row->{parent_id}) : undef,
        author_name => $row->{author_name} || 'Anonymous',
        body        => $row->{body} || '',
        status      => $row->{status} || 'visible',
        created_at  => int($row->{created_at} || 0),
        created_iso => _iso_time($row->{created_at}),
    };
}

sub _admin_comment {
    my ($row) = @_;
    return {
        id          => int($row->{id} || 0),
        content_id  => int($row->{content_id} || 0),
        parent_id   => $row->{parent_id} ? int($row->{parent_id}) : undef,
        author_name => $row->{author_name} || 'Anonymous',
        body        => $row->{body} || '',
        status      => $row->{status} || 'visible',
        created_at  => int($row->{created_at} || 0),
        updated_at  => int($row->{updated_at} || 0),
        created_iso => _iso_time($row->{created_at}),
    };
}

sub _clean_token {
    my ($value, %opts) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return ($value, 0) if $value =~ /\A[0-9a-fA-F]{32,128}\z/;
    return ('', 0) if exists $opts{allow_generate} && !$opts{allow_generate};
    return (random_hex(32), 1);
}

sub _clean_author {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/^\s+|\s+\z//g;
    $value =~ s/\s+/ /g;
    $value = 'Anonymous' unless length $value;
    return _trim_bytes($value, $MAX_NAME_BYTES);
}

sub _clean_body {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
    $value =~ s/[ \t]+\n/\n/g;
    $value =~ s/\n{4,}/\n\n\n/g;
    $value =~ s/^\s+|\s+\z//g;
    return _trim_bytes($value, $MAX_BODY_BYTES);
}

sub _trim_bytes {
    my ($value, $max) = @_;
    return $value unless length($value) > $max;
    return substr($value, 0, $max);
}

sub _post_url {
    my ($post) = @_;
    my $slug = lc($post->{slug} || '');
    $slug =~ s/[^a-z0-9-]+/-/g;
    $slug =~ s/^-+//;
    $slug =~ s/-+\z//;
    $slug ||= 'untitled';
    return '/posts/' . $slug . '/';
}

sub _iso_time {
    my ($epoch) = @_;
    $epoch = int($epoch || 0);
    return '' unless $epoch;
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($epoch));
}

1;
