package DesertCMS::Content;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use DesertCMS::Media;
use DesertCMS::Renderer;
use DesertCMS::RichText qw(sanitize_rich_html plain_text_from_rich_html);
use DesertCMS::Settings;
use DesertCMS::Util qw(now slugify);

my %TAXONOMY = (
    tags => {
        table       => 'tags',
        join_table  => 'content_tags',
        id_column   => 'tag_id',
        text_column => 'tags_text',
    },
    collections => {
        table       => 'collections',
        join_table  => 'content_collections',
        id_column   => 'collection_id',
        text_column => 'collections_text',
    },
);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub list_items {
    my ($self, %args) = @_;
    my @where = ('deleted_at IS NULL');
    my @bind;

    if ($args{type}) {
        push @where, 'type = ?';
        push @bind, $args{type};
    }

    my $sql = 'SELECT * FROM content_items WHERE ' . join(' AND ', @where) . ' ORDER BY updated_at DESC, id DESC';
    return $self->{db}->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
}

sub get {
    my ($self, $id) = @_;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM content_items WHERE id = ? AND deleted_at IS NULL',
        undef,
        $id
    );
}

sub page_options {
    my ($self, %args) = @_;
    my $exclude_id = int($args{exclude_id} || 0);
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT id, parent_id, title, slug, status
            FROM content_items
            WHERE type = 'page'
              AND deleted_at IS NULL
            ORDER BY title ASC, id ASC
        },
        { Slice => {} }
    );
    return [ grep { !$exclude_id || $_->{id} != $exclude_id } @{$rows} ];
}

sub save {
    my ($self, %args) = @_;
    my $type = $args{type} && $args{type} eq 'post' ? 'post' : 'page';
    my $title = _trim($args{title});
    die "title is required" unless length $title;

    my $slug = _trim($args{slug});
    $slug = _slug_source($slug || $title, $type);
    $slug = $self->_unique_slug($slug, $args{id});

    my $excerpt = _trim($args{excerpt});
    my $meta_title = _trim($args{meta_title});
    my $meta_description = _trim($args{meta_description});
    my $canonical_url = _trim($args{canonical_url});
    my $feature_image_path = _trim($args{feature_image_path});
    $feature_image_path = '' unless DesertCMS::Media::is_public_image_path($feature_image_path);
    my $location_enabled = $args{location_enabled} ? 1 : 0;
    my $location_lat = _coordinate($args{location_lat}, -90, 90);
    my $location_lng = _coordinate($args{location_lng}, -180, 180);
    if (!defined $location_lat || !defined $location_lng) {
        $location_enabled = 0;
        $location_lat = undef;
        $location_lng = undef;
    }
    my $location_label = _trim($args{location_label});
    $location_label = substr($location_label, 0, 160);
    my $location_kind = _location_kind($args{location_kind});
    my $parent_id = $type eq 'page' ? $self->_valid_parent_id($args{parent_id}, $args{id}) : undef;
    my $show_in_nav = $args{show_in_nav} ? 1 : 0;
    my $nav_label = _trim($args{nav_label});
    my $nav_order = defined $args{nav_order} && $args{nav_order} =~ /\A-?[0-9]+\z/ ? int($args{nav_order}) : 100;
    my $access_policy = _access_policy($args{access_policy});
    my $access_group_id = $access_policy eq 'group' ? $self->_valid_access_group_id($args{access_group_id}) : undef;
    my $body_json = _normalize_body_json($args{body_json}, $args{body_text});
    my $ts = now();
    my $dbh = $self->{db}->dbh;

    my $id = $args{id};
    if ($id) {
        $dbh->do(
            q{
                UPDATE content_items
                SET parent_id = ?, type = ?, title = ?, slug = ?, excerpt = ?,
                    meta_title = ?, meta_description = ?, canonical_url = ?, feature_image_path = ?,
                    location_enabled = ?, location_lat = ?, location_lng = ?, location_label = ?, location_kind = ?,
                    show_in_nav = ?, nav_label = ?, nav_order = ?, access_policy = ?, access_group_id = ?, body_json = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
            },
            undef,
            $parent_id,
            $type,
            $title,
            $slug,
            $excerpt,
            $meta_title,
            $meta_description,
            $canonical_url,
            $feature_image_path,
            $location_enabled,
            $location_lat,
            $location_lng,
            $location_label,
            $location_kind,
            $show_in_nav,
            $nav_label,
            $nav_order,
            $access_policy,
            $access_group_id,
            $body_json,
            $ts,
            $id
        );
    } else {
        $self->_enforce_content_quota($type);
        $dbh->do(
            q{
                INSERT INTO content_items
                    (parent_id, type, title, slug, status, excerpt, meta_title, meta_description, canonical_url,
                     feature_image_path, location_enabled, location_lat, location_lng, location_label, location_kind,
                      show_in_nav, nav_label, nav_order, access_policy, access_group_id, body_json, created_at, updated_at)
                VALUES
                    (?, ?, ?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $parent_id,
            $type,
            $title,
            $slug,
            $excerpt,
            $meta_title,
            $meta_description,
            $canonical_url,
            $feature_image_path,
            $location_enabled,
            $location_lat,
            $location_lng,
            $location_label,
            $location_kind,
            $show_in_nav,
            $nav_label,
            $nav_order,
            $access_policy,
            $access_group_id,
            $body_json,
            $ts,
            $ts
        );
        $id = $dbh->sqlite_last_insert_rowid;
    }

    $self->_sync_terms($id, 'tags', $args{tags_text});
    $self->_sync_terms($id, 'collections', $args{collections_text});
    $self->_create_revision($id, $args{author_user_id});
    return $self->get($id);
}

sub publish {
    my ($self, %args) = @_;
    my $id = $args{id} or die "content id is required";
    my $item = $self->get($id) or die "content item not found";
    my $html = DesertCMS::Renderer::render_item($self->{config}, $item, $self->{db});
    my $ts = now();

    $self->{db}->dbh->do(
        q{
            UPDATE content_items
            SET status = 'published', published_at = ?, updated_at = ?, published_html = ?
            WHERE id = ?
        },
        undef,
        $ts,
        $ts,
        $html,
        $id
    );

    $item = $self->get($id);
    DesertCMS::Renderer::publish_item($self->{config}, $item, $html, $self->{db});
    DesertCMS::Renderer::rebuild_indexes($self->{config}, $self->{db});
    $self->_create_revision($id, $args{author_user_id});
    return $item;
}

sub rebuild_all {
    my ($self) = @_;
    my $items = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM content_items
            WHERE status = 'published' AND deleted_at IS NULL
            ORDER BY type, slug
        },
        { Slice => {} }
    );

    for my $item (@{$items}) {
        my $html = DesertCMS::Renderer::render_item($self->{config}, $item, $self->{db});
        $self->{db}->dbh->do(
            'UPDATE content_items SET published_html = ?, updated_at = ? WHERE id = ?',
            undef,
            $html,
            now(),
            $item->{id}
        );
        DesertCMS::Renderer::publish_item($self->{config}, $item, $html, $self->{db});
    }
    DesertCMS::Renderer::rebuild_indexes($self->{config}, $self->{db});
    return scalar @{$items};
}

sub delete_item {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $item = $self->get($id) or die "content item not found";
    my $dbh = $self->{db}->dbh;

    if (($item->{type} || '') eq 'page') {
        my ($child_count) = $dbh->selectrow_array(
            q{
                SELECT COUNT(*)
                FROM content_items
                WHERE parent_id = ?
                  AND deleted_at IS NULL
            },
            undef,
            $id
        );
        die "delete child pages first" if ($child_count || 0) > 0;
    }

    my $published_path = DesertCMS::Renderer::public_path_for($self->{config}, $item, $self->{db});
    my $ts = now();
    $dbh->do(
        q{
            UPDATE content_items
            SET status = 'draft',
                show_in_nav = 0,
                deleted_at = ?,
                updated_at = ?
            WHERE id = ?
              AND deleted_at IS NULL
        },
        undef,
        $ts,
        $ts,
        $id
    );

    unlink $published_path if defined $published_path && -f $published_path;
    DesertCMS::Renderer::rebuild_indexes($self->{config}, $self->{db});

    $item->{deleted_at} = $ts;
    $item->{status} = 'draft';
    $item->{show_in_nav} = 0;
    return $item;
}

sub body_text_from_json {
    my ($body_json) = @_;
    my $blocks = eval { decode_json($body_json || '[]') } || [];
    my @text;
    for my $block (@{$blocks}) {
        next unless ref $block eq 'HASH';
        my $type = $block->{type} || '';
        if ($type eq 'text' || $type eq 'image_text') {
            my $plain = plain_text_from_rich_html($block->{html});
            $plain = $block->{text} || '' unless length $plain;
            push @text, $plain if length $plain;
        } elsif ($type eq 'heading' || $type eq 'quote') {
            push @text, $block->{text} if defined $block->{text} && length $block->{text};
        } elsif ($type eq 'contributor_request') {
            push @text, $block->{title} if defined $block->{title} && length $block->{title};
            push @text, $block->{intro} if defined $block->{intro} && length $block->{intro};
        } elsif ($type eq 'code') {
            push @text, $block->{code} if defined $block->{code} && length $block->{code};
        }
    }
    return join "\n\n", @text;
}

sub normalize_body_json {
    my ($self, $body_json, $body_text) = @_;
    return _normalize_body_json($body_json, $body_text);
}

sub tags_text {
    my ($self, $id) = @_;
    return $self->_terms_text($id, 'tags');
}

sub collections_text {
    my ($self, $id) = @_;
    return $self->_terms_text($id, 'collections');
}

sub _create_revision {
    my ($self, $id, $author_user_id) = @_;
    my $item = $self->get($id) or return;
    $self->{db}->dbh->do(
        q{
            INSERT INTO content_revisions
                (content_id, parent_id, title, slug, status, excerpt, meta_title, meta_description, canonical_url,
                 feature_image_path, location_enabled, location_lat, location_lng, location_label, location_kind,
                  show_in_nav, nav_label, nav_order, access_policy, access_group_id, tags_text, collections_text,
                  body_json, author_user_id, created_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $item->{id},
        $item->{parent_id},
        $item->{title},
        $item->{slug},
        $item->{status},
        $item->{excerpt},
        $item->{meta_title},
        $item->{meta_description},
        $item->{canonical_url},
        $item->{feature_image_path},
        $item->{location_enabled},
        $item->{location_lat},
        $item->{location_lng},
        $item->{location_label},
        $item->{location_kind},
        $item->{show_in_nav},
        $item->{nav_label},
        $item->{nav_order},
        $item->{access_policy} || 'public',
        $item->{access_group_id},
        $self->tags_text($id),
        $self->collections_text($id),
        $item->{body_json},
        $author_user_id,
        now()
    );
}

sub _valid_parent_id {
    my ($self, $parent_id, $id) = @_;
    $parent_id = int($parent_id || 0);
    return undef unless $parent_id;
    die "content cannot be its own parent" if $id && $parent_id == int($id);

    my $parent = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT id, parent_id
            FROM content_items
            WHERE id = ?
              AND type = 'page'
              AND deleted_at IS NULL
        },
        undef,
        $parent_id
    );
    die "parent page not found" unless $parent;

    my %seen;
    my $current = $parent;
    while ($current && $current->{parent_id}) {
        die "parent page cycle detected" if $seen{$current->{id}}++;
        die "content cannot be nested below itself" if $id && int($current->{parent_id}) == int($id);
        $current = $self->{db}->dbh->selectrow_hashref(
            'SELECT id, parent_id FROM content_items WHERE id = ?',
            undef,
            $current->{parent_id}
        );
    }

    return $parent_id;
}

sub _valid_access_group_id {
    my ($self, $group_id) = @_;
    $group_id = int($group_id || 0);
    return undef unless $group_id > 0;
    my ($exists) = $self->{db}->dbh->selectrow_array(
        'SELECT id FROM member_groups WHERE id = ?',
        undef,
        $group_id
    );
    return $exists ? $group_id : undef;
}

sub _sync_terms {
    my ($self, $content_id, $kind, $text) = @_;
    my $taxonomy = $TAXONOMY{$kind} or die "unsupported taxonomy kind";
    my $dbh = $self->{db}->dbh;
    my @terms = _parse_terms($text);
    my $ts = now();

    $dbh->do("DELETE FROM $taxonomy->{join_table} WHERE content_id = ?", undef, $content_id);
    for my $name (@terms) {
        my $slug = slugify($name);
        if ($kind eq 'collections') {
            $dbh->do(
                q{
                    INSERT INTO collections (name, slug, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(slug) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at
                },
                undef,
                $name,
                $slug,
                $ts,
                $ts
            );
        } else {
            $dbh->do(
                q{
                    INSERT INTO tags (name, slug, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(slug) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at
                },
                undef,
                $name,
                $slug,
                $ts,
                $ts
            );
        }
        my ($term_id) = $dbh->selectrow_array(
            "SELECT id FROM $taxonomy->{table} WHERE slug = ?",
            undef,
            $slug
        );
        next unless $term_id;
        $dbh->do(
            "INSERT OR IGNORE INTO $taxonomy->{join_table} (content_id, $taxonomy->{id_column}) VALUES (?, ?)",
            undef,
            $content_id,
            $term_id
        );
    }
}

sub _terms_text {
    my ($self, $content_id, $kind) = @_;
    my $taxonomy = $TAXONOMY{$kind} or die "unsupported taxonomy kind";
    my $rows = $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT t.name
            FROM $taxonomy->{table} t
            JOIN $taxonomy->{join_table} ct ON ct.$taxonomy->{id_column} = t.id
            WHERE ct.content_id = ?
            ORDER BY t.name ASC
        },
        { Slice => {} },
        $content_id
    );
    return join ', ', map { $_->{name} } @{$rows};
}

sub _parse_terms {
    my ($text) = @_;
    my @terms;
    my %seen;
    for my $raw (split /[,\n]/, $text || '') {
        $raw =~ s/^\s+|\s+$//g;
        $raw =~ s/\s+/ /g;
        next unless length $raw;
        my $name = substr($raw, 0, 80);
        my $slug = slugify($name);
        next if $seen{$slug}++;
        push @terms, $name;
        last if @terms >= 20;
    }
    return @terms;
}

sub _slug_source {
    my ($source, $type) = @_;
    $source = '' unless defined $source;
    if ($type eq 'page') {
        my @parts = grep { length $_ } split m{/+}, $source;
        $source = @parts ? $parts[-1] : $source;
    }
    return slugify($source);
}

sub _unique_slug {
    my ($self, $base, $id) = @_;
    my $slug = $base;
    my $i = 2;
    while (1) {
        my $row = $self->{db}->dbh->selectrow_hashref(
            'SELECT id FROM content_items WHERE slug = ? AND deleted_at IS NULL',
            undef,
            $slug
        );
        return $slug if !$row || ($id && $row->{id} == $id);
        $slug = "$base-$i";
        $i++;
    }
}

sub _trim {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

sub _coordinate {
    my ($value, $min, $max) = @_;
    return undef unless defined $value && "$value" =~ /\A-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/;
    my $number = 0 + $value;
    return undef if $number < $min || $number > $max;
    return sprintf('%.6f', $number);
}

sub _location_kind {
    my ($value) = @_;
    $value = lc(_trim($value));
    $value =~ s/[-\s]+/_/g;
    return $value if $value =~ /\A(?:store|venue|project|historical_site|event_location|service_area|other)\z/;
    return 'other';
}

sub _access_policy {
    my ($value) = @_;
    $value = lc(_trim($value));
    $value =~ s/[-\s]+/_/g;
    return $value if $value =~ /\A(?:public|members|group|private)\z/;
    return 'public';
}

sub _normalize_body_json {
    my ($body_json, $body_text) = @_;
    if (defined $body_json && length $body_json) {
        my $blocks = eval { decode_json($body_json) };
        die "invalid block JSON" if $@ || ref $blocks ne 'ARRAY';

        my @clean;
        for my $block (@{$blocks}) {
            next unless ref $block eq 'HASH';
            my $type = $block->{type} || '';
            if ($type eq 'text') {
                my ($text, $html) = _normalize_rich_text_block($block);
                push @clean, {
                    type => 'text',
                    text => $text,
                    html => $html,
                    align => _normalize_align($block->{align}),
                    font => _normalize_text_font($block->{font}),
                    text_size => _normalize_text_size($block->{text_size}),
                    spacing => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'heading') {
                my $level = defined $block->{level} ? int($block->{level}) : 2;
                $level = 2 unless $level == 2 || $level == 3;
                push @clean, {
                    type  => 'heading',
                    text  => defined $block->{text} ? "$block->{text}" : '',
                    level => $level,
                    align => _normalize_align($block->{align}),
                    font => _normalize_text_font($block->{font}),
                    text_size => _normalize_text_size($block->{text_size}),
                    spacing => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'quote') {
                push @clean, {
                    type     => 'quote',
                    text     => defined $block->{text} ? "$block->{text}" : '',
                    citation => defined $block->{citation} ? "$block->{citation}" : '',
                    align    => _normalize_align($block->{align}),
                    font     => _normalize_text_font($block->{font}),
                    text_size => _normalize_text_size($block->{text_size}),
                    spacing  => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'divider') {
                push @clean, {
                    type    => 'divider',
                    spacing => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'code') {
                push @clean, {
                    type     => 'code',
                    code     => defined $block->{code} ? substr("$block->{code}", 0, 100_000) : '',
                    language => _clean_code_language($block->{language}),
                    spacing  => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'image') {
                my $src = defined $block->{src} ? "$block->{src}" : '';
                next unless $src eq '' || DesertCMS::Media::is_public_image_path($src);
                my $layout = defined $block->{layout} ? "$block->{layout}" : 'full';
                my $size = defined $block->{size} ? "$block->{size}" : 'large';
                $layout = 'full' unless $layout =~ /\A(?:full|left|right|center)\z/;
                $size = 'large' unless $size =~ /\A(?:small|medium|large|full)\z/;
                push @clean, {
                    type    => 'image',
                    src     => $src,
                    alt     => defined $block->{alt} ? "$block->{alt}" : '',
                    caption => defined $block->{caption} ? "$block->{caption}" : '',
                    layout  => $layout,
                    size    => $size,
                    spacing => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'image_text') {
                my $src = defined $block->{src} ? "$block->{src}" : '';
                next unless $src eq '' || DesertCMS::Media::is_public_image_path($src);
                my $image_side = defined $block->{image_side} ? "$block->{image_side}" : 'left';
                $image_side = 'left' unless $image_side =~ /\A(?:left|right)\z/;
                my ($text, $html) = _normalize_rich_text_block($block);
                push @clean, {
                    type       => 'image_text',
                    src        => $src,
                    alt        => defined $block->{alt} ? "$block->{alt}" : '',
                    caption    => defined $block->{caption} ? "$block->{caption}" : '',
                    text       => $text,
                    html       => $html,
                    align      => _normalize_align($block->{align}),
                    font       => _normalize_text_font($block->{font}),
                    text_size  => _normalize_text_size($block->{text_size}),
                    image_side => $image_side,
                    spacing    => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'video') {
                my $url = _clean_public_url($block->{url}, 1);
                push @clean, {
                    type    => 'video',
                    url     => $url,
                    title   => defined $block->{title} ? "$block->{title}" : '',
                    caption => defined $block->{caption} ? "$block->{caption}" : '',
                    spacing => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'link') {
                my $url = _clean_public_url($block->{url}, 0);
                push @clean, {
                    type        => 'link',
                    url         => $url,
                    label       => defined $block->{label} ? "$block->{label}" : '',
                    description => defined $block->{description} ? "$block->{description}" : '',
                    spacing     => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'resource') {
                my $src = defined $block->{src} ? "$block->{src}" : '';
                next unless $src eq '' || $src =~ m{\A/assets/resources/[0-9a-f]{64}\.[a-z0-9]+\z};
                push @clean, {
                    type         => 'resource',
                    src          => $src,
                    label        => _clean_block_text($block->{label}, '', 140),
                    description  => _clean_block_text($block->{description}, '', 300),
                    button_label => _clean_block_text($block->{button_label}, 'Download', 80),
                    spacing      => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'content_ref') {
                my $target_id = int($block->{target_id} || 0);
                next unless $target_id > 0;
                my $style = defined $block->{style} ? "$block->{style}" : 'card';
                $style = 'card' unless $style =~ /\A(?:card|feature)\z/;
                push @clean, {
                    type      => 'content_ref',
                    target_id => $target_id,
                    style     => $style,
                    spacing   => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'contributor_request') {
                push @clean, {
                    type         => 'contributor_request',
                    title        => _clean_block_text($block->{title}, 'Request to become a contributor', 140),
                    intro        => _clean_block_text($block->{intro}, 'Submit your contact details, optional sample images, and why you want to join.', 500),
                    button_label => _clean_block_text($block->{button_label}, 'Submit request', 80),
                    spacing      => _normalize_spacing($block->{spacing}),
                };
            } elsif ($type eq 'social') {
                my $url = _clean_public_url($block->{url}, 0);
                my $platform = defined $block->{platform} ? lc("$block->{platform}") : 'website';
                $platform = 'website' unless $platform =~ /\A(?:instagram|x|facebook|youtube|vimeo|website|email)\z/;
                push @clean, {
                    type     => 'social',
                    platform => $platform,
                    url      => $url,
                    label    => defined $block->{label} ? "$block->{label}" : '',
                    spacing  => _normalize_spacing($block->{spacing}),
                };
            }
        }
        return encode_json(\@clean);
    }

    my $text = defined $body_text ? "$body_text" : '';
    return encode_json([{ type => 'text', text => $text, html => sanitize_rich_html(undef, $text), align => 'left', font => 'serif', text_size => 'normal', spacing => 'default' }]);
}

sub _clean_block_text {
    my ($value, $fallback, $max) = @_;
    $value = defined $value ? "$value" : '';
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+$//g;
    $value = $fallback unless length $value;
    return substr($value, 0, $max);
}

sub _clean_code_language {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/^\s+|\s+$//g;
    return '' unless length $value;
    return $value if $value =~ /\A[a-z0-9_+#.-]{1,32}\z/;
    return '';
}

sub _normalize_rich_text_block {
    my ($block) = @_;
    my $raw_text = defined $block->{text} ? "$block->{text}" : '';
    my $raw_html = defined $block->{html} ? "$block->{html}" : undef;
    my $html = sanitize_rich_html($raw_html, $raw_text);
    my $text = plain_text_from_rich_html($html);
    $text = $raw_text unless length $text || length $html;
    return ($text, $html);
}

sub _normalize_align {
    my ($align) = @_;
    $align = defined $align ? "$align" : 'left';
    return $align =~ /\A(?:left|center|right)\z/ ? $align : 'left';
}

sub _normalize_text_font {
    my ($font) = @_;
    $font = defined $font ? "$font" : 'serif';
    return $font =~ /\A(?:serif|sans|mono)\z/ ? $font : 'serif';
}

sub _normalize_text_size {
    my ($size) = @_;
    $size = defined $size ? "$size" : 'normal';
    return $size =~ /\A(?:small|normal|large)\z/ ? $size : 'normal';
}

sub _normalize_spacing {
    my ($spacing) = @_;
    $spacing = defined $spacing ? "$spacing" : 'default';
    return $spacing =~ /\A(?:default|compact|spacious|none)\z/ ? $spacing : 'default';
}

sub _clean_public_url {
    my ($url, $allow_video) = @_;
    $url = '' unless defined $url;
    $url =~ s/^\s+|\s+$//g;
    return '' if length($url) > 500;
    return '' if $url =~ /[\r\n<>"\\]/;
    return $url if $url =~ m{\Ahttps://[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]+\z};
    return $url if !$allow_video && $url =~ m{\Amailto:[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z};
    return '';
}

sub _enforce_content_quota {
    my ($self, $type) = @_;
    return unless $self->{config}->get('contributor_site_id');
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $key = $type eq 'post' ? 'contributor_post_quota' : 'contributor_page_quota';
    my $quota = $settings->{$key};
    return unless defined $quota && "$quota" =~ /\A[0-9]+\z/;
    $quota = int($quota);
    my ($count) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM content_items
            WHERE type = ?
              AND deleted_at IS NULL
        },
        undef,
        $type
    );
    return if int($count || 0) < $quota;
    die(($type eq 'post' ? 'Post' : 'Page') . " quota reached for this contributor site");
}

1;
