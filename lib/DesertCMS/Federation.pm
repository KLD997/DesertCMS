package DesertCMS::Federation;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Media;
use DesertCMS::Settings;
use DesertCMS::Util qw(now);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub refresh_queue {
    my ($self) = @_;
    return { discovered => 0, inserted => 0, updated => 0 }
        if _is_contributor_instance($self->{config});

    my $ts = now();
    my ($discovered, $inserted, $updated) = (0, 0, 0);
    for my $site (@{ $self->_active_sites('all') }) {
        my $site_db = _open_site_db($site);
        next unless $site_db;
        if ($site->{allow_master_gallery}) {
            my $items = $self->_site_media_items($site, $site_db);
            if ($items) {
                my @seen;
                for my $item (@{$items}) {
                    push @seen, int($item->{source_id} || 0);
                    $discovered++;
                    my $result = $self->_upsert_item($item, $ts);
                    $inserted++ if $result eq 'inserted';
                    $updated++ if $result eq 'updated';
                }
                $self->_mark_missing_items($site, 'media', \@seen, $ts);
            }
        }
        if ($site->{allow_master_posts}) {
            my $items = $self->_site_post_items($site, $site_db);
            if ($items) {
                my @seen;
                for my $item (@{$items}) {
                    push @seen, int($item->{source_id} || 0);
                    $discovered++;
                    my $result = $self->_upsert_item($item, $ts);
                    $inserted++ if $result eq 'inserted';
                    $updated++ if $result eq 'updated';
                }
                $self->_mark_missing_items($site, 'post', \@seen, $ts);
            }
        }
    }
    return {
        discovered => $discovered,
        inserted   => $inserted,
        updated    => $updated,
    };
}

sub counts {
    my ($self) = @_;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT status, source_type, COUNT(*) AS count
            FROM federated_content_reviews
            GROUP BY status, source_type
        },
        { Slice => {} }
    );
    my %counts = (
        pending_media  => 0,
        pending_posts  => 0,
        approved_media => 0,
        approved_posts => 0,
        rejected_media => 0,
        rejected_posts => 0,
        pending        => 0,
        approved       => 0,
        rejected       => 0,
        total          => 0,
    );
    for my $row (@{$rows}) {
        my $status = $row->{status} || 'pending';
        my $type = ($row->{source_type} || '') eq 'post' ? 'posts' : 'media';
        my $count = int($row->{count} || 0);
        $counts{"${status}_${type}"} += $count;
        $counts{$status} += $count;
        $counts{total} += $count;
    }
    return \%counts;
}

sub rows {
    my ($self, %args) = @_;
    my $status = _clean_status($args{status} || 'pending');
    my $limit = int($args{limit} || 100);
    $limit = 100 if $limit < 1 || $limit > 250;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT r.*, u.username AS reviewed_by_username
            FROM federated_content_reviews r
            LEFT JOIN admin_users u ON u.id = r.reviewed_by_user_id
            WHERE r.status = ?
            ORDER BY r.last_seen_at DESC, r.id DESC
            LIMIT ?
        },
        { Slice => {} },
        $status,
        $limit
    );
    _decode_details($_) for @{$rows};
    return $rows;
}

sub review {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $status = _clean_status($args{status});
    my $note = _clean_note($args{note});
    die "review item is required" unless $id > 0;
    die "review status is required" unless $status =~ /\A(?:pending|approved|rejected)\z/;

    my $row = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM federated_content_reviews WHERE id = ?',
        undef,
        $id
    ) or die "federated review item not found";

    $self->{db}->dbh->do(
        q{
            UPDATE federated_content_reviews
            SET status = ?,
                reviewed_at = ?,
                reviewed_by_user_id = ?,
                review_note = ?
            WHERE id = ?
        },
        undef,
        $status,
        now(),
        int($args{reviewed_by_user_id} || 0) || undef,
        $note,
        $id
    );
    $row = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM federated_content_reviews WHERE id = ?',
        undef,
        $id
    );
    _decode_details($row);
    return $row;
}

sub approved_media_items {
    my ($self) = @_;
    $self->refresh_queue;
    my %active = map { $_->{site_id} => $_ } @{ $self->_active_sites('gallery') };
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM federated_content_reviews
            WHERE status = 'approved'
              AND source_type = 'media'
              AND source_missing_at IS NULL
            ORDER BY source_updated_at DESC, last_seen_at DESC, id DESC
        },
        { Slice => {} }
    );
    my @items;
    for my $row (@{$rows}) {
        my $site = $active{$row->{source_site_id} || ''} or next;
        _decode_details($row);
        my $details = $row->{details} || {};
        push @items, {
            id                 => int($row->{source_id} || 0),
            original_name      => $details->{original_name} || $row->{title} || '',
            public_path        => $details->{public_path} || '',
            image_url          => $row->{image_url} || $row->{source_url} || '',
            alt_text           => $details->{alt_text} || $row->{title} || '',
            seo_title          => $details->{seo_title} || $row->{title} || '',
            seo_description    => $details->{seo_description} || $row->{summary} || '',
            width              => int($details->{width} || 0),
            height             => int($details->{height} || 0),
            owner_site_id      => $row->{source_site_id} || '',
            owner_domain       => $row->{source_domain} || $site->{domain} || '',
            owner_display_name => $site->{display_name} || $row->{source_domain} || '',
            created_at         => int($details->{created_at} || $row->{source_updated_at} || $row->{last_seen_at} || 0),
        };
    }
    return \@items;
}

sub approved_post_items {
    my ($self) = @_;
    $self->refresh_queue;
    my %active = map { $_->{site_id} => $_ } @{ $self->_active_sites('posts') };
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM federated_content_reviews
            WHERE status = 'approved'
              AND source_type = 'post'
              AND source_missing_at IS NULL
            ORDER BY source_updated_at DESC, last_seen_at DESC, id DESC
        },
        { Slice => {} }
    );
    my @items;
    for my $row (@{$rows}) {
        my $site = $active{$row->{source_site_id} || ''} or next;
        _decode_details($row);
        my $details = $row->{details} || {};
        push @items, {
            id                 => int($row->{source_id} || 0),
            title              => $row->{title} || $details->{title} || '',
            slug               => $row->{source_slug} || $details->{slug} || '',
            excerpt            => $row->{summary} || $details->{excerpt} || '',
            url                => $row->{source_url} || '',
            owner_site_id      => $row->{source_site_id} || '',
            owner_domain       => $row->{source_domain} || $site->{domain} || '',
            owner_display_name => $site->{display_name} || $row->{source_domain} || '',
            sort_time          => int($row->{source_updated_at} || $row->{last_seen_at} || 0),
        };
    }
    return \@items;
}

sub _active_sites {
    my ($self, $surface) = @_;
    my $rows = eval {
        $self->{db}->dbh->selectall_arrayref(
            q{
                SELECT site_id, domain, display_name, config_path,
                       allow_master_gallery, allow_master_posts
                FROM contributor_sites
                WHERE status = 'active'
                  AND config_path <> ''
                ORDER BY display_name ASC, site_id ASC
            },
            { Slice => {} }
        );
    };
    return [] if $@;
    $rows ||= [];
    my $root = _contributor_domain_root($self->{config}, $self->{db});
    my @filtered = grep { _safe_domain($_->{domain}) } @{$rows};
    if (length $root) {
        @filtered = grep { _domain_is_subdomain($_->{domain}, $root) } @filtered;
    }
    if (($surface || '') eq 'gallery') {
        @filtered = grep { $_->{allow_master_gallery} ? 1 : 0 } @filtered;
    } elsif (($surface || '') eq 'posts') {
        @filtered = grep { $_->{allow_master_posts} ? 1 : 0 } @filtered;
    } elsif (($surface || '') ne 'all') {
        @filtered = ();
    }
    return \@filtered;
}

sub _site_media_items {
    my ($self, $site, $site_db) = @_;
    my $rows = eval {
        $site_db->dbh->selectall_arrayref(
            q{
                SELECT id, original_name, public_path, alt_text, seo_title, seo_description, width, height,
                       owner_site_id, owner_domain, owner_display_name, created_at
                FROM media_assets
                WHERE deleted_at IS NULL
                  AND public_path LIKE '/assets/media/%'
                ORDER BY created_at DESC, id DESC
                LIMIT 250
            },
            { Slice => {} }
        );
    };
    return undef if $@;
    $rows ||= [];
    my @items;
    for my $row (@{$rows}) {
        next unless DesertCMS::Media::is_public_image_path($row->{public_path});
        my $image_url = 'https://' . $site->{domain} . $row->{public_path};
        push @items, {
            source_site_id    => $site->{site_id},
            source_domain     => $site->{domain},
            source_type       => 'media',
            source_id         => int($row->{id} || 0),
            source_slug       => '',
            source_url        => $image_url,
            image_url         => $image_url,
            title             => _first_text($row->{seo_title}, $row->{alt_text}, $row->{original_name}, 'Contributor image'),
            summary           => $row->{seo_description} || '',
            source_updated_at => int($row->{created_at} || 0) || undef,
            details           => {
                %{$row},
                owner_site_id        => $row->{owner_site_id} || $site->{site_id},
                owner_domain         => $row->{owner_domain} || $site->{domain},
                owner_display_name   => $row->{owner_display_name} || $site->{display_name},
            },
        };
    }
    return \@items;
}

sub _site_post_items {
    my ($self, $site, $site_db) = @_;
    my $rows = eval {
        $site_db->dbh->selectall_arrayref(
            q{
                SELECT id, title, slug, excerpt, published_at, updated_at
                FROM content_items
                WHERE type = 'post'
                  AND status = 'published'
                  AND deleted_at IS NULL
                ORDER BY published_at DESC, updated_at DESC
                LIMIT 100
            },
            { Slice => {} }
        );
    };
    return undef if $@;
    $rows ||= [];
    my @items;
    for my $row (@{$rows}) {
        my $slug = $row->{slug} || '';
        next unless $slug =~ /\A[a-z0-9][a-z0-9-]{0,199}\z/;
        my $url = 'https://' . $site->{domain} . '/posts/' . $slug . '/';
        push @items, {
            source_site_id    => $site->{site_id},
            source_domain     => $site->{domain},
            source_type       => 'post',
            source_id         => int($row->{id} || 0),
            source_slug       => $slug,
            source_url        => $url,
            image_url         => '',
            title             => $row->{title} || 'Contributor post',
            summary           => $row->{excerpt} || '',
            source_updated_at => int($row->{published_at} || $row->{updated_at} || 0) || undef,
            details           => $row,
        };
    }
    return \@items;
}

sub _upsert_item {
    my ($self, $item, $ts) = @_;
    my $existing = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT id
            FROM federated_content_reviews
            WHERE source_site_id = ?
              AND source_type = ?
              AND source_id = ?
        },
        undef,
        $item->{source_site_id},
        $item->{source_type},
        $item->{source_id}
    );
    $self->{db}->dbh->do(
        q{
            INSERT INTO federated_content_reviews
                (source_site_id, source_domain, source_type, source_id, source_slug,
                 source_url, image_url, title, summary, status, first_seen_at, last_seen_at,
                 source_updated_at, details_json)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)
            ON CONFLICT(source_site_id, source_type, source_id) DO UPDATE SET
                source_domain = excluded.source_domain,
                source_slug = excluded.source_slug,
                source_url = excluded.source_url,
                image_url = excluded.image_url,
                title = excluded.title,
                summary = excluded.summary,
                last_seen_at = excluded.last_seen_at,
                source_updated_at = excluded.source_updated_at,
                source_missing_at = NULL,
                details_json = excluded.details_json
        },
        undef,
        $item->{source_site_id},
        $item->{source_domain},
        $item->{source_type},
        $item->{source_id},
        $item->{source_slug} || '',
        $item->{source_url} || '',
        $item->{image_url} || '',
        _clean_text($item->{title}, 220),
        _clean_text($item->{summary}, 700),
        $ts,
        $ts,
        $item->{source_updated_at},
        encode_json($item->{details} || {}),
    );
    return $existing ? 'updated' : 'inserted';
}

sub _mark_missing_items {
    my ($self, $site, $source_type, $seen_ids, $ts) = @_;
    my @ids = grep { $_ > 0 } map { int($_ || 0) } @{$seen_ids || []};
    my $sql = q{
        UPDATE federated_content_reviews
        SET source_missing_at = ?
        WHERE source_site_id = ?
          AND source_type = ?
          AND source_missing_at IS NULL
    };
    my @bind = ($ts, $site->{site_id}, $source_type);
    if (@ids) {
        $sql .= ' AND source_id NOT IN (' . join(',', ('?') x @ids) . ')';
        push @bind, @ids;
    }
    $self->{db}->dbh->do($sql, undef, @bind);
}

sub _open_site_db {
    my ($site) = @_;
    return undef unless $site && _safe_domain($site->{domain});
    my $path = $site->{config_path} || '';
    return undef unless length $path && -f $path;
    my $config = eval { DesertCMS::Config->load($path) };
    return undef unless $config;
    return eval { DesertCMS::DB->new(config => $config) };
}

sub _decode_details {
    my ($row) = @_;
    return unless $row;
    my $details = {};
    eval {
        $details = decode_json($row->{details_json} || '{}');
        1;
    } or do {
        $details = {};
    };
    $row->{details} = $details;
}

sub _clean_status {
    my ($status) = @_;
    $status = lc($status || '');
    return $status if $status =~ /\A(?:pending|approved|rejected)\z/;
    return 'pending';
}

sub _clean_note {
    my ($note) = @_;
    $note = '' unless defined $note;
    $note =~ s/\r\n?/\n/g;
    $note =~ s/^\s+|\s+\z//g;
    return substr($note, 0, 1000);
}

sub _clean_text {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/^\s+|\s+\z//g;
    $value =~ s/\s+/ /g;
    return substr($value, 0, $max || 255);
}

sub _first_text {
    for my $value (@_) {
        $value = _clean_text($value, 220);
        return $value if length $value;
    }
    return '';
}

sub _is_contributor_instance {
    my ($config) = @_;
    return 1 if $config && length($config->get('contributor_site_id') || '');
    return 1 if $config && length($config->get('contributor_domain') || '');
    return 0;
}

sub _safe_domain {
    my ($domain) = @_;
    $domain = lc($domain || '');
    $domain =~ s/^\.+|\.+\z//g;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+[a-z]{2,}\z/ ? 1 : 0;
}

sub _domain_is_subdomain {
    my ($domain, $root) = @_;
    $domain = lc($domain || '');
    $root = lc($root || '');
    $domain =~ s/^\.+|\.+\z//g;
    $root =~ s/^\.+|\.+\z//g;
    return 0 unless length $domain && length $root;
    return 0 if $domain eq $root;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+\Q$root\E\z/ ? 1 : 0;
}

sub _contributor_domain_root {
    my ($config, $db) = @_;
    my $settings = eval { DesertCMS::Settings::all($config, $db) } || {};
    my $root = $settings->{contributor_domain_root} || '';
    if (!length $root) {
        $root = $config->get('site_url') || '';
        $root =~ s{\Ahttps?://}{}i;
        $root =~ s{/.*\z}{};
    }
    $root = lc $root;
    $root =~ s{\Ahttps?://}{}i;
    $root =~ s{/.*\z}{};
    $root =~ s/^\.+|\.+\z//g;
    return _safe_domain($root) ? $root : '';
}

1;
