package DesertCMS::Ratings;

use strict;
use warnings;
use DesertCMS::HTTP ();
use DesertCMS::Util qw(hmac_sha256_hex now);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub summary {
    my ($self, %args) = @_;
    my $content_id = int($args{content_id} || 0);
    my $post = $self->_published_post($content_id)
        or die "post not found";

    my $dbh = $self->{db}->dbh;
    my ($count, $sum) = $dbh->selectrow_array(
        'SELECT COUNT(*), COALESCE(SUM(rating), 0) FROM post_ratings WHERE content_id = ?',
        undef,
        $content_id
    );
    $count = int($count || 0);
    $sum = int($sum || 0);

    my $distribution_rows = $dbh->selectall_arrayref(
        q{
            SELECT rating, COUNT(*) AS rating_count
            FROM post_ratings
            WHERE content_id = ?
            GROUP BY rating
        },
        { Slice => {} },
        $content_id
    );
    my %distribution = map { int($_->{rating}) => int($_->{rating_count} || 0) } @{$distribution_rows};
    my @ratings = map { { rating => $_, count => int($distribution{$_} || 0) } } 1 .. 5;

    my $viewer_rating = 0;
    my $ip = DesertCMS::HTTP::client_ip($args{request}, $self->{config});
    if (length $ip) {
        ($viewer_rating) = $dbh->selectrow_array(
            'SELECT rating FROM post_ratings WHERE content_id = ? AND ip_hash = ?',
            undef,
            $content_id,
            $self->_hash_ip($ip)
        );
        $viewer_rating = int($viewer_rating || 0);
    }

    return {
        post => {
            id    => int($post->{id}),
            title => $post->{title} || '',
            url   => _post_url($post),
        },
        count         => $count,
        average       => $count ? sprintf('%.1f', $sum / $count) + 0 : 0,
        viewer_rating => $viewer_rating,
        ratings       => \@ratings,
    };
}

sub vote {
    my ($self, %args) = @_;
    my $content_id = int($args{content_id} || 0);
    my $post = $self->_published_post($content_id)
        or die "post not found";

    my $rating = int($args{rating} || 0);
    die "rating must be between 1 and 5" unless $rating >= 1 && $rating <= 5;

    my $ip = DesertCMS::HTTP::client_ip($args{request}, $self->{config});
    die "visitor address is required" unless length $ip;

    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO post_ratings
                (content_id, ip_hash, rating, created_at, updated_at)
            VALUES
                (?, ?, ?, ?, ?)
            ON CONFLICT(content_id, ip_hash)
            DO UPDATE SET
                rating = excluded.rating,
                updated_at = excluded.updated_at
        },
        undef,
        int($post->{id}),
        $self->_hash_ip($ip),
        $rating,
        $ts,
        $ts
    );

    return $self->summary(content_id => $post->{id}, request => $args{request});
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

sub _hash_ip {
    my ($self, $ip) = @_;
    return hmac_sha256_hex('ratings:ip:' . ($ip || ''), $self->{config}->app_secret);
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

1;
