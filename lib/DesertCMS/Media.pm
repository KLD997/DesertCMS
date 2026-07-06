package DesertCMS::Media;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Encode qw(FB_DEFAULT decode);
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Spec;
use IO::Uncompress::Unzip qw($UnzipError);
use JSON::PP qw(decode_json encode_json);
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Util qw(now);

my %IMAGE_EXT = map { $_ => 1 } qw(jpg jpeg png webp);
my %IMAGE_MIME = map { $_ => 1 } qw(image/jpeg image/png image/webp);
my %DOCUMENT_EXT = map { $_ => 1 } qw(pdf txt md markdown csv tsv json docx xlsx pptx);
my %DOCUMENT_MIME = map { $_ => 1 } (
    'application/pdf',
    'application/json',
    'text/plain',
    'text/markdown',
    'text/csv',
    'text/tab-separated-values',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
);
my %AUDIO_EXT = map { $_ => 1 } qw(mp3 m4a wav ogg oga weba flac);
my %AUDIO_MIME = map { $_ => 1 } qw(audio/mpeg audio/mp4 audio/x-m4a audio/wav audio/x-wav audio/ogg audio/webm audio/flac);
my %VIDEO_EXT = map { $_ => 1 } qw(mp4 m4v mov webm ogv);
my %VIDEO_MIME = map { $_ => 1 } qw(video/mp4 video/x-m4v video/quicktime video/webm video/ogg);
my %SOURCE_EXT = (%DOCUMENT_EXT, %AUDIO_EXT, %VIDEO_EXT);
my @RESPONSIVE_WIDTHS = (480, 800, 1200);
my @LIBRARY_FILTERS = qw(all images documents audio video resources unused published private);
my %LIBRARY_FILTER = map { $_ => 1 } @LIBRARY_FILTERS;
my $DEFAULT_LARGE_UNUSED_BYTES = 10 * 1024 * 1024;
my $DEFAULT_RETENTION_UNUSED_DAYS = 90;
my $MAX_PREVIEW_SOURCE_BYTES = 1_500_000;
my $MAX_PREVIEW_TEXT_CHARS = 6000;

sub asset_kind {
    my ($asset_or_mime) = @_;
    my $mime = ref $asset_or_mime eq 'HASH' ? ($asset_or_mime->{mime_type} || '') : ($asset_or_mime || '');
    $mime = lc $mime;
    return 'image' if $mime =~ m{\Aimage/};
    return 'audio' if $mime =~ m{\Aaudio/};
    return 'video' if $mime =~ m{\Avideo/};
    return 'document' if $mime =~ m{\A(?:application/pdf|application/json|text/)};
    return 'document' if $mime =~ m{\Aapplication/vnd\.openxmlformats-officedocument\.};
    return 'asset';
}

sub public_derivative_kind {
    my ($asset) = @_;
    return '' unless ref $asset eq 'HASH' && length($asset->{public_path} || '');
    return asset_kind($asset) eq 'image' ? 'optimized_image' : 'public_derivative';
}

sub is_public_image_path {
    my ($path) = @_;
    return defined $path && $path =~ m{\A/assets/media/[0-9a-f]{64}\.(?:jpg|png|webp)\z} ? 1 : 0;
}

sub is_public_image_variant_path {
    my ($path) = @_;
    return defined $path && $path =~ m{\A/assets/media/[0-9a-f]{64}(?:-[0-9]+)?\.(?:jpg|png|webp)\z} ? 1 : 0;
}

sub public_policy {
    my ($asset) = @_;
    return 'optimized_public_derivative' if ref $asset eq 'HASH'
        && is_public_image_path($asset->{public_path} || '');
    return 'public_resource_download' if ref $asset eq 'HASH'
        && ($asset->{public_path} || '') =~ m{\A/assets/resources/[0-9a-f]{64}\.[a-z0-9]+\z};
    return 'private_source_only';
}

sub library_filters {
    return @LIBRARY_FILTERS;
}

sub library_filter_key {
    my ($filter) = @_;
    $filter = lc($filter || 'all');
    $filter =~ s/[^a-z0-9_-]//g;
    return $LIBRARY_FILTER{$filter} ? $filter : 'all';
}

sub library_filter_counts {
    my ($assets, $usage_by_id) = @_;
    my %counts = map { $_ => 0 } @LIBRARY_FILTERS;
    for my $asset (@{ $assets || [] }) {
        next unless ref $asset eq 'HASH';
        $counts{all}++;
        for my $filter (grep { $_ ne 'all' } @LIBRARY_FILTERS) {
            $counts{$filter}++ if _library_filter_match($asset, $filter, $usage_by_id);
        }
    }
    return \%counts;
}

sub library_filter_assets {
    my ($assets, $filter, $usage_by_id) = @_;
    $filter = library_filter_key($filter);
    return [ @{ $assets || [] } ] if $filter eq 'all';
    return [
        grep { ref $_ eq 'HASH' && _library_filter_match($_, $filter, $usage_by_id) }
            @{ $assets || [] }
    ];
}

sub library_search_query {
    my ($query) = @_;
    $query = '' unless defined $query;
    $query =~ s/[\x00-\x1F\x7F]/ /g;
    return _trim_length($query, 160);
}

sub library_search_assets {
    my ($assets, $query) = @_;
    $query = library_search_query($query);
    return [ @{ $assets || [] } ] unless length $query;
    my @tokens = _search_tokens($query);
    return [ @{ $assets || [] } ] unless @tokens;
    return [
        grep { ref $_ eq 'HASH' && _media_search_matches($_, \@tokens) }
            @{ $assets || [] }
    ];
}

sub media_search_text {
    my ($asset) = @_;
    return _media_search_text($asset);
}

sub media_organization_terms {
    my ($value) = @_;
    return _organization_terms($value);
}

sub library_organization_terms {
    my ($assets, $field) = @_;
    $field = ($field || '') eq 'collections_text' ? 'collections_text' : 'category_text';
    my %seen;
    my @terms;
    for my $asset (@{ $assets || [] }) {
        next unless ref $asset eq 'HASH';
        my @values = $field eq 'category_text'
            ? (_clean_org_label($asset->{$field} || ''))
            : _organization_terms($asset->{$field});
        for my $value (@values) {
            next unless length $value;
            my $key = lc $value;
            next if $seen{$key}++;
            push @terms, $value;
        }
    }
    return [ sort { lc($a) cmp lc($b) } @terms ];
}

sub library_filter_organization_assets {
    my ($assets, %args) = @_;
    my $category = _clean_org_label($args{category});
    my $collection = _clean_org_label($args{collection});
    return [ @{ $assets || [] } ] unless length($category) || length($collection);
    return [
        grep {
            ref $_ eq 'HASH'
                && (!length($category) || lc(_clean_org_label($_->{category_text} || '')) eq lc($category))
                && (!length($collection) || _org_list_contains($_->{collections_text}, $collection))
        } @{ $assets || [] }
    ];
}

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub list_assets {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM media_assets
            WHERE deleted_at IS NULL
            ORDER BY created_at DESC, id DESC
        },
        { Slice => {} }
    );
}

sub store_upload {
    my ($self, %args) = @_;
    my $original_name = basename($args{filename} || 'upload');
    my $mime_type = lc($args{mime_type} || 'application/octet-stream');
    my $content = $args{content};
    my $alt_text = _trim($args{alt_text});
    my $seo_title = _trim_length($args{seo_title}, 90);
    my $seo_description = _trim_length($args{seo_description}, 220);
    my $category_text = _clean_org_label($args{category_text});
    my $tags_text = _clean_org_list($args{tags_text});
    my $collections_text = _clean_org_list($args{collections_text});
    my $owner = $self->_owner_context(%args);
    die "upload content is required" unless defined $content && length $content;
    die "unsupported media type; supported uploads are images, documents, data files, audio, and video"
        unless _allowed_mime($mime_type);
    $self->_enforce_media_limits(length($content));

    my ($ext) = $original_name =~ /\.([A-Za-z0-9]+)\z/;
    $ext = lc($ext || _ext_from_mime($mime_type));
    die "unsupported media extension; supported uploads are images, documents, data files, audio, and video"
        unless _allowed_extension($ext);
    $ext = 'jpg' if $ext eq 'jpeg';
    _validate_extension_for_mime($ext, $mime_type);

    my $checksum = sha256_hex($content);
    my $prefix = substr($checksum, 0, 2);
    my $private_dir = File::Spec->catdir($self->{config}->get('originals_dir'), $prefix);
    make_path($private_dir) unless -d $private_dir;

    my $storage_path = File::Spec->catfile($private_dir, "$checksum.$ext");
    if (!-f $storage_path) {
        open my $fh, '>:raw', $storage_path or die "cannot write private source asset $storage_path: $!";
        print {$fh} $content;
        close $fh;
        chmod 0600, $storage_path;
    }

    my $asset_kind = asset_kind($mime_type);
    my ($public_rel, $width, $height, $derivatives);
    if ($asset_kind eq 'image') {
        my $public_ext = _public_image_extension($mime_type);
        $public_rel = "/assets/media/$checksum.$public_ext";
        my $public_path = File::Spec->catfile($self->{config}->get('public_root'), 'assets', 'media', "$checksum.$public_ext");
        $self->_create_derivative($storage_path, $public_path, max_width => $self->_public_max_width);
        ($width, $height) = $self->_identify($public_path);
        $derivatives = $self->_create_responsive_derivatives(
            $storage_path,
            $checksum,
            $public_ext,
            $public_rel,
            $width,
            $height,
        );
    } else {
        $public_rel = '';
        $width = undef;
        $height = undef;
        $derivatives = _private_source_derivative_policy(
            mime_type => $mime_type,
            extension => $ext,
            bytes     => length($content),
            filename  => $original_name,
            content   => $content,
        );
        $self->_attach_private_preview_metadata(
            $derivatives,
            source_path => $storage_path,
            checksum    => $checksum,
            extension   => $ext,
            mime_type   => $mime_type,
            bytes       => length($content),
            filename    => $original_name,
            content     => $content,
        );
    }

    my $ts = now();
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        q{
            INSERT INTO media_assets
                (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
                 category_text, tags_text, collections_text,
                 owner_site_id, owner_domain, owner_display_name, owner_email,
                 uploaded_by_user_id, uploaded_by_username, uploaded_by_email,
                 mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $original_name,
        $storage_path,
        $public_rel,
        $alt_text,
        $seo_title,
        $seo_description,
        $category_text,
        $tags_text,
        $collections_text,
        $owner->{owner_site_id},
        $owner->{owner_domain},
        $owner->{owner_display_name},
        $owner->{owner_email},
        $owner->{uploaded_by_user_id},
        $owner->{uploaded_by_username},
        $owner->{uploaded_by_email},
        $mime_type,
        $width,
        $height,
        length($content),
        $checksum,
        encode_json($derivatives),
        $ts
    );

    my $id = $dbh->sqlite_last_insert_rowid;
    my $asset = $dbh->selectrow_hashref('SELECT * FROM media_assets WHERE id = ?', undef, $id);
    eval { $self->enqueue_private_preview_job(asset => $asset, reason => 'upload') }
        if _private_preview_job_needed($asset);
    return $asset;
}

sub create_public_derivative {
    my ($self, %args) = @_;
    my $source = $args{source} || '';
    my $dest = $args{dest} || '';
    die "source image is required" unless length $source && -f $source;
    die "destination image path is required" unless length $dest;
    my $max_width = int($args{max_width} || $self->_public_max_width);
    $self->_create_derivative($source, $dest, max_width => $max_width);
    chmod 0644, $dest if -f $dest;
    my ($width, $height) = $self->_identify($dest);
    return {
        path   => $dest,
        width  => int($width || 0),
        height => int($height || 0),
    };
}

sub asset_by_id {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    return undef unless $id;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM media_assets WHERE id = ? AND deleted_at IS NULL',
        undef,
        $id
    );
}

sub source_download {
    my ($self, %args) = @_;
    my $asset = $args{asset} || $self->asset_by_id(id => $args{id});
    die "media asset not found" unless $asset;
    my $path = $asset->{storage_path} || '';
    die "source asset is not available" unless length $path && -f $path;
    die "source asset path is outside the private media store"
        unless _is_under($path, $self->{config}->get('originals_dir'));
    return {
        asset    => $asset,
        path     => $path,
        filename => _download_filename($asset),
        mime     => _download_mime($asset->{mime_type}),
        bytes    => -s $path,
    };
}

sub private_preview {
    my ($self, %args) = @_;
    my $asset = $args{asset} || $self->asset_by_id(id => $args{id});
    die "media asset not found" unless $asset;
    my $meta = _decode_derivatives($asset->{derivatives_json});
    my $preview = ref $meta->{private_preview} eq 'HASH' ? $meta->{private_preview} : {};
    my $path = $preview->{path} || '';
    die "private preview is not available" unless length $path && -f $path;
    die "private preview path is outside the private media store"
        unless _is_under($path, $self->{config}->get('originals_dir'));
    my $mime = lc($preview->{mime} || 'image/jpeg');
    die "private preview MIME is not displayable" unless $mime =~ m{\Aimage/(?:jpeg|png|webp|svg\+xml)\z};
    return {
        asset    => $asset,
        path     => $path,
        filename => _private_preview_filename($asset, $preview),
        mime     => $mime,
        bytes    => -s $path,
        preview  => $preview,
    };
}

sub preview_job_summary {
    my ($self) = @_;
    my %counts = map { $_ => 0 } qw(queued running done failed skipped);
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT status, COUNT(*) AS count
            FROM media_preview_jobs
            GROUP BY status
        },
        { Slice => {} }
    );
    for my $row (@{$rows || []}) {
        my $status = $row->{status} || '';
        $counts{$status} = int($row->{count} || 0) if exists $counts{$status};
    }

    my $candidates = 0;
    for my $asset (@{ $self->list_assets }) {
        $candidates++ if _private_preview_job_needed($asset);
    }

    return {
        %counts,
        candidates => $candidates,
    };
}

sub enqueue_private_preview_jobs {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 50);
    $limit = 1 if $limit < 1;
    $limit = 500 if $limit > 500;
    my ($queued, $skipped) = (0, 0);
    for my $asset (@{ $self->list_assets }) {
        next unless _private_preview_job_needed($asset);
        my $result = $self->enqueue_private_preview_job(
            asset  => $asset,
            reason => $args{reason} || 'retry',
        );
        if ($result->{queued}) {
            $queued++;
            last if $queued >= $limit;
        } else {
            $skipped++;
        }
    }
    return {
        queued  => $queued,
        skipped => $skipped,
    };
}

sub enqueue_private_preview_job {
    my ($self, %args) = @_;
    my $asset = $args{asset} || $self->asset_by_id(id => $args{id});
    return { queued => 0, reason => 'media asset not found' } unless $asset;
    return { queued => 0, reason => 'preview job is not supported for this asset' }
        unless _private_preview_job_supported($asset);
    return { queued => 0, reason => 'private preview is already current' }
        unless _private_preview_job_needed($asset);

    my $dbh = $self->{db}->dbh;
    my $existing = $dbh->selectrow_hashref(
        q{
            SELECT *
            FROM media_preview_jobs
            WHERE media_id = ? AND status IN ('queued', 'running')
            ORDER BY id DESC
            LIMIT 1
        },
        undef,
        int($asset->{id})
    );
    return { queued => 0, reason => 'preview job is already queued', job => $existing }
        if $existing;

    my $ts = now();
    my $reason = _trim_length($args{reason} || 'retry', 80);
    $dbh->do(
        q{
            INSERT INTO media_preview_jobs
                (media_id, status, reason, attempts, last_error, created_at, updated_at)
            VALUES (?, 'queued', ?, 0, '', ?, ?)
        },
        undef,
        int($asset->{id}),
        $reason,
        $ts,
        $ts
    );
    my $id = $dbh->sqlite_last_insert_rowid;
    return {
        queued => 1,
        job    => $dbh->selectrow_hashref('SELECT * FROM media_preview_jobs WHERE id = ?', undef, $id),
    };
}

sub process_private_preview_jobs {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 10);
    $limit = 1 if $limit < 1;
    $limit = 100 if $limit > 100;
    my $jobs = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM media_preview_jobs
            WHERE status = 'queued'
            ORDER BY created_at ASC, id ASC
            LIMIT ?
        },
        { Slice => {} },
        $limit
    );

    my %summary = (
        checked => scalar(@{$jobs || []}),
        done    => 0,
        failed  => 0,
        skipped => 0,
        errors  => [],
    );
    for my $job (@{$jobs || []}) {
        my $result = $self->_process_private_preview_job($job);
        my $status = $result->{status} || 'failed';
        $summary{$status}++ if exists $summary{$status};
        push @{ $summary{errors} }, $result->{error}
            if length($result->{error} || '') && @{ $summary{errors} } < 3;
    }
    return \%summary;
}

sub publish_resource {
    my ($self, %args) = @_;
    my $asset = $args{asset} || $self->asset_by_id(id => $args{id});
    die "media asset not found" unless $asset;
    die "only private source files can be published as resource downloads"
        if asset_kind($asset) eq 'image';
    $self->_enforce_resource_publishing_allowed;

    my $path = $asset->{storage_path} || '';
    die "source asset is not available" unless length $path && -f $path;
    die "source asset path is outside the private media store"
        unless _is_under($path, $self->{config}->get('originals_dir'));

    my $source_content = _read_binary($path);
    my $ext = _public_resource_extension($asset);
    my $checksum = $asset->{checksum_sha256} || sha256_hex($source_content);
    my $filename = "$checksum.$ext";
    my $public_rel = "/assets/resources/$filename";
    my $public_file = File::Spec->catfile($self->{config}->get('public_root'), 'assets', 'resources', $filename);
    my (undef, $dir) = File::Spec->splitpath($public_file);
    make_path($dir) unless -d $dir;
    copy($path, $public_file) or die "cannot publish public resource $public_file: $!";
    chmod 0644, $public_file;

    my $meta = _decode_derivatives($asset->{derivatives_json});
    my $resource_meta = _private_source_derivative_policy(
        mime_type => $asset->{mime_type},
        extension => $ext,
        bytes     => int($asset->{bytes} || (-s $path) || 0),
        filename  => $asset->{original_name},
        content   => $source_content,
    );
    _preserve_private_preview_metadata($meta, $resource_meta);
    $meta->{version} = 2;
    $meta->{asset_kind} = asset_kind($asset);
    $meta->{public_policy} = 'public_resource_download';
    $meta->{source_access} = 'authenticated_admin_download';
    $meta->{document} = $resource_meta->{document};
    $meta->{preview} = $resource_meta->{preview};
    $meta->{public_resource} = {
        path      => $public_rel,
        mime      => _download_mime($asset->{mime_type}),
        filename  => _download_filename($asset),
        extension => uc($ext),
        bytes     => int($asset->{bytes} || (-s $path) || 0),
        label     => $resource_meta->{document}{type_label},
        byte_label => $resource_meta->{document}{byte_label},
    };

    $self->{db}->dbh->do(
        q{
            UPDATE media_assets
            SET public_path = ?, derivatives_json = ?
            WHERE id = ? AND deleted_at IS NULL
        },
        undef,
        $public_rel,
        encode_json($meta),
        int($asset->{id})
    );
    return $self->asset_by_id(id => $asset->{id});
}

sub unpublish_resource {
    my ($self, %args) = @_;
    my $asset = $args{asset} || $self->asset_by_id(id => $args{id});
    die "media asset not found" unless $asset;
    die "only private source files can be unpublished as resource downloads"
        if asset_kind($asset) eq 'image';

    my $usage = $self->usage_for_asset(asset => $asset);
    if ($usage->{content_count}) {
        my $count = $usage->{content_count};
        my $noun = $count == 1 ? 'page or post' : 'pages or posts';
        die "Public resource is used by $count $noun. Remove it from content before unpublishing it.";
    }

    my $public_path = $asset->{public_path} || '';
    my $meta = _decode_derivatives($asset->{derivatives_json});
    my $resource = ref $meta->{public_resource} eq 'HASH' ? $meta->{public_resource} : {};
    my $resource_path = $resource->{path} || $public_path;
    delete $meta->{public_resource};
    $meta->{public_policy} = 'private_source_only';
    $meta->{source_access} = 'authenticated_admin_download';

    $self->{db}->dbh->do(
        q{
            UPDATE media_assets
            SET public_path = '', derivatives_json = ?
            WHERE id = ? AND deleted_at IS NULL
        },
        undef,
        encode_json($meta),
        int($asset->{id})
    );

    _unlink_public_resource_if_unused($self, $resource_path) if length $resource_path;
    return $self->asset_by_id(id => $asset->{id});
}

sub update_search_text {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "media id is required" unless $id;
    my $current = $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM media_assets WHERE id = ? AND deleted_at IS NULL',
        undef,
        $id
    ) or die "media asset not found";
    my $alt_text = exists $args{alt_text} ? _trim($args{alt_text}) : ($current->{alt_text} || '');
    my $seo_title = exists $args{seo_title} ? _trim_length($args{seo_title}, 90) : ($current->{seo_title} || '');
    my $seo_description = exists $args{seo_description} ? _trim_length($args{seo_description}, 220) : ($current->{seo_description} || '');
    my $category_text = exists $args{category_text} ? _clean_org_label($args{category_text}) : ($current->{category_text} || '');
    my $tags_text = exists $args{tags_text} ? _clean_org_list($args{tags_text}) : ($current->{tags_text} || '');
    my $collections_text = exists $args{collections_text} ? _clean_org_list($args{collections_text}) : ($current->{collections_text} || '');
    $self->{db}->dbh->do(
        q{
            UPDATE media_assets
            SET alt_text = ?, seo_title = ?, seo_description = ?,
                category_text = ?, tags_text = ?, collections_text = ?
            WHERE id = ? AND deleted_at IS NULL
        },
        undef,
        $alt_text,
        $seo_title,
        $seo_description,
        $category_text,
        $tags_text,
        $collections_text,
        $id
    );
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM media_assets WHERE id = ?', undef, $id);
}

sub update_alt_text {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "media id is required" unless $id;
    my $alt_text = _trim($args{alt_text});
    $self->{db}->dbh->do(
        'UPDATE media_assets SET alt_text = ? WHERE id = ? AND deleted_at IS NULL',
        undef,
        $alt_text,
        $id
    );
    return $self->{db}->dbh->selectrow_hashref('SELECT * FROM media_assets WHERE id = ?', undef, $id);
}

sub asset_quality {
    my ($self, %args) = @_;
    my $asset = $args{asset};
    if (!$asset) {
        my $id = int($args{id} || 0);
        return { ok => 0, issues => [ 'Media asset not found.' ], responsive_count => 0 } unless $id;
        $asset = $self->{db}->dbh->selectrow_hashref(
            'SELECT * FROM media_assets WHERE id = ? AND deleted_at IS NULL',
            undef,
            $id
        );
    }
    return { ok => 0, issues => [ 'Media asset not found.' ], responsive_count => 0 } unless $asset;

    my @issues;
    my $kind = asset_kind($asset);
    push @issues, 'Missing default alt text.' if $kind eq 'image' && !length _trim($asset->{alt_text});
    push @issues, 'Missing media search title.' unless length _trim($asset->{seo_title});
    push @issues, 'Missing media search description.' unless length _trim($asset->{seo_description});
    push @issues, 'Missing public derivative dimensions.' if $kind eq 'image' && !(int($asset->{width} || 0) > 0 && int($asset->{height} || 0) > 0);

    my $derivatives = _decode_derivatives($asset->{derivatives_json});
    my $sizes = ref $derivatives->{sizes} eq 'ARRAY' ? $derivatives->{sizes} : [];
    my $responsive_count = scalar grep {
        ref $_ eq 'HASH'
            && is_public_image_variant_path($_->{path} || '')
            && int($_->{width} || 0) > 0
            && int($_->{height} || 0) > 0
    } @{$sizes};
    push @issues, 'Missing responsive image sizes.' if $kind eq 'image' && !$responsive_count;

    return {
        ok               => @issues ? 0 : 1,
        issues           => \@issues,
        responsive_count => $responsive_count,
        asset_kind       => $kind,
        public_policy    => public_policy($asset),
    };
}

sub usage_for_asset {
    my ($self, %args) = @_;
    my $asset = $args{asset};
    if (!$asset) {
        my $id = int($args{id} || 0);
        return { content_count => 0, shop_listing_count => 0, shop_order_count => 0 } unless $id;
        $asset = $self->{db}->dbh->selectrow_hashref(
            'SELECT * FROM media_assets WHERE id = ? AND deleted_at IS NULL',
            undef,
            $id
        );
    }
    return { content_count => 0, shop_listing_count => 0, shop_order_count => 0 } unless $asset;

    my $id = int($asset->{id} || 0);
    my $public_path = $asset->{public_path} || '';
    my $dbh = $self->{db}->dbh;
    my ($content_count) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM content_items
            WHERE deleted_at IS NULL
              AND ? <> ''
              AND (feature_image_path = ? OR body_json LIKE ?)
        },
        undef,
        $public_path,
        $public_path,
        '%' . $public_path . '%'
    );
    my ($shop_listing_count) = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM shop_listings WHERE media_asset_id = ?',
        undef,
        $id
    );
    my ($shop_order_count) = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM shop_orders WHERE media_asset_id = ?',
        undef,
        $id
    );

    return {
        content_count      => int($content_count || 0),
        shop_listing_count => int($shop_listing_count || 0),
        shop_order_count   => int($shop_order_count || 0),
    };
}

sub delete_asset {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    die "media id is required" unless $id;

    my $dbh = $self->{db}->dbh;
    my $asset = $dbh->selectrow_hashref(
        'SELECT * FROM media_assets WHERE id = ? AND deleted_at IS NULL',
        undef,
        $id
    ) or die "media asset not found";

    my $usage = $self->usage_for_asset(asset => $asset);
    if ($usage->{content_count}) {
        my $count = $usage->{content_count};
        my $noun = $count == 1 ? 'page or post' : 'pages or posts';
        die "Media asset is used by $count $noun. Remove it from content before deleting it.";
    }

    my $ts = now();
    $dbh->begin_work;
    eval {
        $dbh->do(
            'UPDATE media_assets SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL',
            undef,
            $ts,
            $id
        );
        $dbh->do(
            q{
                UPDATE shop_listings
                SET active = 0,
                    personal_enabled = 0,
                    commercial_enabled = 0,
                    full_rights_enabled = 0,
                    updated_at = ?
                WHERE media_asset_id = ?
            },
            undef,
            $ts,
            $id
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'media delete failed';
        eval { $dbh->rollback };
        die $err;
    };

    if (!$usage->{shop_order_count}) {
        _unlink_public_derivative_if_unused($self, $asset);
        _unlink_public_resource_if_unused($self, $asset->{public_path} || '');
        _unlink_private_preview_if_unused($self, $asset);
        _unlink_original_if_unused($self, $asset);
    }

    return {
        %{$asset},
        deleted_at => $ts,
        usage      => $usage,
    };
}

sub lifecycle_audit {
    my ($self, %args) = @_;
    my $large_min_bytes = _lifecycle_large_min_bytes($args{large_min_bytes}, $args{large_min_mb});
    my $retention_days = _lifecycle_retention_days($args{retention_days});
    my $retention_before = now() - ($retention_days * 86400);
    my $assets = $self->list_assets;
    my %active_public_path;
    my %active_resource_path;
    my @missing_sources;
    my @large_unused;
    my @retention_unused;

    for my $asset (@{$assets || []}) {
        my $id = int($asset->{id} || 0);
        my $storage_path = $asset->{storage_path} || '';
        my $source_available = 0;
        if (!length $storage_path) {
            push @missing_sources, _lifecycle_asset_entry($asset, reason => 'No private source path is recorded.');
        } elsif (!_is_under($storage_path, $self->{config}->get('originals_dir'))) {
            push @missing_sources, _lifecycle_asset_entry($asset, reason => 'Private source path is outside the configured source store.');
        } elsif (!-f $storage_path) {
            push @missing_sources, _lifecycle_asset_entry($asset, reason => 'Private source file is missing from disk.');
        } else {
            $source_available = 1;
        }

        if (public_policy($asset) eq 'public_resource_download') {
            $active_resource_path{$asset->{public_path} || ''} = $id if length($asset->{public_path} || '');
        }
        if (asset_kind($asset) eq 'image') {
            for my $rel (_public_derivative_paths($asset)) {
                next unless is_public_image_variant_path($rel);
                $active_public_path{$rel} = $id;
            }
        }

        if (int($asset->{bytes} || 0) >= $large_min_bytes) {
            my $usage = $self->usage_for_asset(asset => $asset);
            if (_lifecycle_asset_unused($usage)) {
                push @large_unused, _lifecycle_asset_entry($asset, usage => $usage, reason => 'Large media asset is not referenced by content, shop listings, or order records.');
            }
        }

        if ($source_available && int($asset->{created_at} || 0) > 0 && int($asset->{created_at} || 0) <= $retention_before) {
            my $usage = $self->usage_for_asset(asset => $asset);
            if (_lifecycle_asset_unused($usage)) {
                push @retention_unused, _lifecycle_asset_entry(
                    $asset,
                    usage => $usage,
                    reason => 'Old unused media is eligible for private archive before deletion.',
                );
            }
        }
    }

    my @orphaned_resources;
    for my $file (@{ $self->_public_files('assets', 'resources') }) {
        next unless $file->{rel} =~ m{\A/assets/resources/[0-9a-f]{64}\.[a-z0-9]+\z};
        next if $active_resource_path{$file->{rel}};
        push @orphaned_resources, {
            %{$file},
            reason => 'Public resource file is not referenced by an active media row.',
        };
    }

    my @stale_derivatives;
    for my $file (@{ $self->_public_files('assets', 'media') }) {
        next unless is_public_image_variant_path($file->{rel});
        next if $active_public_path{$file->{rel}};
        push @stale_derivatives, {
            %{$file},
            reason => 'Public image derivative is not referenced by an active media row.',
        };
    }

    @missing_sources = sort { ($b->{bytes} || 0) <=> ($a->{bytes} || 0) || ($a->{name} || '') cmp ($b->{name} || '') } @missing_sources;
    @large_unused = sort { ($b->{bytes} || 0) <=> ($a->{bytes} || 0) || ($a->{name} || '') cmp ($b->{name} || '') } @large_unused;
    @retention_unused = sort { int($a->{created_at} || 0) <=> int($b->{created_at} || 0) || ($b->{bytes} || 0) <=> ($a->{bytes} || 0) || ($a->{name} || '') cmp ($b->{name} || '') } @retention_unused;
    @orphaned_resources = sort { ($b->{bytes} || 0) <=> ($a->{bytes} || 0) || ($a->{rel} || '') cmp ($b->{rel} || '') } @orphaned_resources;
    @stale_derivatives = sort { ($b->{bytes} || 0) <=> ($a->{bytes} || 0) || ($a->{rel} || '') cmp ($b->{rel} || '') } @stale_derivatives;

    my %summary = (
        missing_sources_count     => scalar @missing_sources,
        missing_sources_bytes     => _sum_bytes(\@missing_sources),
        orphaned_resources_count  => scalar @orphaned_resources,
        orphaned_resources_bytes  => _sum_bytes(\@orphaned_resources),
        stale_derivatives_count   => scalar @stale_derivatives,
        stale_derivatives_bytes   => _sum_bytes(\@stale_derivatives),
        large_unused_count        => scalar @large_unused,
        large_unused_bytes        => _sum_bytes(\@large_unused),
        large_min_bytes           => $large_min_bytes,
        retention_unused_count    => scalar @retention_unused,
        retention_unused_bytes    => _sum_bytes(\@retention_unused),
        retention_days            => $retention_days,
        retention_before          => $retention_before,
    );

    return {
        summary             => \%summary,
        large_min_bytes     => $large_min_bytes,
        retention_days      => $retention_days,
        retention_before    => $retention_before,
        missing_sources     => \@missing_sources,
        orphaned_resources  => \@orphaned_resources,
        stale_derivatives   => \@stale_derivatives,
        large_unused        => \@large_unused,
        retention_unused    => \@retention_unused,
    };
}

sub cleanup_lifecycle {
    my ($self, %args) = @_;
    my $action = lc($args{action} || '');
    $action =~ s/[^a-z_]+//g;
    die "unsupported media lifecycle cleanup action"
        unless $action =~ /\A(?:remove_orphaned_resources|remove_stale_derivatives|delete_large_unused|archive_old_unused)\z/;

    my $audit = $self->lifecycle_audit(%args);
    my ($changed, $bytes, $skipped) = (0, 0, 0);
    my @errors;
    my $archive_path = '';
    if ($action eq 'remove_orphaned_resources') {
        ($changed, $bytes, $skipped, @errors) = $self->_cleanup_public_files($audit->{orphaned_resources});
    } elsif ($action eq 'remove_stale_derivatives') {
        ($changed, $bytes, $skipped, @errors) = $self->_cleanup_public_files($audit->{stale_derivatives});
    } elsif ($action eq 'delete_large_unused') {
        for my $entry (@{ $audit->{large_unused} || [] }) {
            my $ok = eval {
                my $deleted = $self->delete_asset(id => $entry->{id});
                $bytes += int($entry->{bytes} || 0) if $deleted && $deleted->{deleted_at};
                1;
            };
            if ($ok) {
                $changed++;
            } else {
                $skipped++;
                push @errors, _trim_length($@ || 'delete failed', 220) if @errors < 3;
            }
        }
    } elsif ($action eq 'archive_old_unused') {
        my $result = $self->_archive_and_delete_retention_assets(
            $audit->{retention_unused},
            retention_days => $audit->{retention_days},
        );
        $changed = int($result->{changed} || 0);
        $bytes = int($result->{bytes} || 0);
        $skipped = int($result->{skipped} || 0);
        @errors = @{ $result->{errors} || [] };
        $archive_path = $result->{archive_path} || '';
    }

    return {
        action       => $action,
        changed      => $changed,
        bytes        => $bytes,
        skipped      => $skipped,
        errors       => \@errors,
        archive_path => $archive_path,
        audit        => $audit,
    };
}

sub _create_derivative {
    my ($self, $source, $dest, %opts) = @_;
    my (undef, $dir) = File::Spec->splitpath($dest);
    make_path($dir) unless -d $dir;

    my $max_width = int($opts{max_width} || $self->_public_max_width);
    my $quality = $self->_public_quality;
    my $tool = $self->{config}->get('image_tool') || 'magick';

    my @cmd = _uses_vips($tool)
        ? _vips_thumbnail_cmd(
            $tool,
            $source,
            $dest,
            size    => $max_width . 'x' . $max_width,
            quality => $quality,
        )
        : _image_tool_cmd(
            $tool,
            'convert',
            $source,
            '-auto-orient',
            '-resize',
            $max_width . 'x' . $max_width . '>',
            '-strip',
            '-colorspace',
            'sRGB',
            '-quality',
            $quality,
            $dest,
        );
    system @cmd;
    my $status = $?;
    if ($status != 0 || !-f $dest) {
        my $reason = $status == -1
            ? "could not execute $cmd[0]: $!"
            : "status $status";
        die "image derivative failed ($reason)";
    }
}

sub _create_responsive_derivatives {
    my ($self, $source, $checksum, $extension, $canonical_rel, $canonical_width, $canonical_height) = @_;
    $extension = $extension && $extension =~ /\A(?:jpg|png|webp)\z/ ? $extension : 'jpg';
    my $max_width = $self->_public_max_width;
    my %seen;
    my @sizes;
    my $add_size = sub {
        my ($label, $rel, $width, $height) = @_;
        $width = int($width || 0);
        $height = int($height || 0);
        return unless $width > 0 && $height > 0;
        return if $seen{$width}++;
        push @sizes, {
            label  => $label,
            path   => $rel,
            width  => $width,
            height => $height,
        };
    };

    for my $target (@RESPONSIVE_WIDTHS) {
        next if $target >= int($canonical_width || 0);
        next if $target > $max_width;
        my $filename = "$checksum-$target.$extension";
        my $rel = "/assets/media/$filename";
        my $dest = File::Spec->catfile($self->{config}->get('public_root'), 'assets', 'media', $filename);
        $self->_create_derivative($source, $dest, max_width => $target);
        my ($width, $height) = $self->_identify($dest);
        if ($seen{int($width || 0)}) {
            unlink $dest if -f $dest;
            next;
        }
        $add_size->("w$target", $rel, $width, $height);
    }
    $add_size->('display', $canonical_rel, $canonical_width, $canonical_height);
    @sizes = sort { int($a->{width} || 0) <=> int($b->{width} || 0) } @sizes;

    my $aspect_ratio = 0;
    $aspect_ratio = sprintf('%.6f', $canonical_width / $canonical_height)
        if int($canonical_width || 0) > 0 && int($canonical_height || 0) > 0;
    return {
        version      => 1,
        sizes        => \@sizes,
        aspect_ratio => $aspect_ratio,
    };
}

sub _public_max_width {
    my ($self) = @_;
    my $max_width = int($self->{config}->get('image_public_max_width') || 1600);
    $max_width = 320 if $max_width < 320;
    $max_width = 4096 if $max_width > 4096;
    return $max_width;
}

sub _public_quality {
    my ($self) = @_;
    my $quality = int($self->{config}->get('image_public_quality') || 82);
    $quality = 82 if $quality < 1 || $quality > 100;
    return $quality;
}

sub _public_image_extension {
    my ($mime_type) = @_;
    $mime_type = lc($mime_type || '');
    return 'png' if $mime_type eq 'image/png' || $mime_type eq 'image/webp';
    return 'jpg';
}

sub _enforce_media_limits {
    my ($self, $incoming_bytes) = @_;
    return unless $self->{config}->get('contributor_site_id');
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $upload_limit = _effective_upload_limit_bytes($self->{config}, $settings);
    if ($upload_limit > 0 && int($incoming_bytes || 0) > $upload_limit) {
        die "Media upload is larger than the current plan limit of " . _format_bytes_label($upload_limit);
    }
    my $quota_mb = $settings->{contributor_media_quota_mb};
    return unless defined $quota_mb && "$quota_mb" =~ /\A[0-9]+\z/;
    my $quota_bytes = int($quota_mb) * 1024 * 1024;
    my ($used) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT COALESCE(SUM(bytes), 0)
            FROM media_assets
            WHERE deleted_at IS NULL
        }
    );
    if (int($used || 0) + int($incoming_bytes || 0) > $quota_bytes) {
        die "Media quota reached for this contributor site";
    }
}

sub _enforce_resource_publishing_allowed {
    my ($self) = @_;
    return unless $self->{config}->get('contributor_site_id');
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    return if DesertCMS::Modules::enabled($settings, 'resource_publishing');
    die "Resource publishing is not included in the current plan";
}

sub _effective_upload_limit_bytes {
    my ($config, $settings) = @_;
    $settings ||= {};
    my $limit_mb = $settings->{contributor_media_upload_limit_mb};
    return 0 unless defined $limit_mb && "$limit_mb" =~ /\A[0-9]+\z/ && int($limit_mb) > 0;
    my $limit = int($limit_mb) * 1024 * 1024;
    my $server_cap = int($config->get('max_request_body_bytes') || 0);
    return $server_cap if $server_cap > 0 && $server_cap < $limit;
    return $limit;
}

sub _identify {
    my ($self, $path) = @_;
    my $tool = $self->{config}->get('image_tool') || 'magick';
    return _vips_identify($tool, $path) if _uses_vips($tool);

    my @cmd = _image_tool_cmd($tool, 'identify', '-format', '%w %h', $path);
    open my $pipe, '-|', @cmd
        or die "cannot run image identify: $!";
    my $out = do { local $/; <$pipe> };
    close $pipe;
    die "image identify failed" if $? != 0;
    my ($width, $height) = $out =~ /([0-9]+)\s+([0-9]+)/;
    return ($width || undef, $height || undef);
}

sub _vips_identify {
    my ($tool, $path) = @_;
    my @cmd = (_sibling_command($tool, 'vipsheader'), $path);
    open my $pipe, '-|', @cmd
        or die "cannot run vips image identify: $!";
    my $out = do { local $/; <$pipe> };
    close $pipe;
    die "vips image identify failed" if $? != 0;
    my ($width, $height) = $out =~ /:\s*([0-9]+)x([0-9]+)\b/;
    return ($width || undef, $height || undef);
}

sub _vips_thumbnail_cmd {
    my ($tool, $source, $dest, %opts) = @_;
    my $output = $dest;
    if ($dest =~ /\.jpe?g\z/i) {
        my $quality = int($opts{quality} || 82);
        $quality = 82 if $quality < 1 || $quality > 100;
        $output .= "[Q=$quality,strip]";
    }
    my @cmd = (
        _sibling_command($tool, 'vipsthumbnail'),
        $source,
        '--size',
        $opts{size} || '1600x1600',
    );
    push @cmd, '--smartcrop', $opts{smartcrop} if $opts{smartcrop};
    push @cmd, '-o', $output;
    return @cmd;
}

sub _image_tool_cmd {
    my ($tool, $operation, @args) = @_;
    my $name = $tool;
    $name =~ s{\\}{/}g;
    $name =~ s{\A.*/}{};
    my $resolved = _resolve_command($tool);
    return ($resolved, $operation, @args)
        if $name eq 'gm' || $name =~ /^gm(?:\.exe)?\z/i || $operation eq 'identify';
    return ($resolved, @args);
}

sub _uses_vips {
    my ($tool) = @_;
    my $name = $tool || '';
    $name =~ s{\\}{/}g;
    $name =~ s{\A.*/}{};
    return $name =~ /^(?:vips|vipsthumbnail|vipsheader)(?:\.exe)?\z/i;
}

sub _sibling_command {
    my ($tool, $command) = @_;
    my $name = $tool || '';
    $name =~ s{\\}{/}g;
    $name =~ s{\A.*/}{};
    my $suffix = $name =~ /\.exe\z/i ? '.exe' : '';
    return _resolve_command($command . $suffix) unless ($tool || '') =~ m{[\\/]};

    my ($volume, $dir) = File::Spec->splitpath($tool);
    return File::Spec->catpath($volume, $dir, $command . $suffix);
}

sub _resolve_command {
    my ($command) = @_;
    return $command unless defined $command && length $command;
    return $command if $command =~ m{[\\/]};

    my %seen;
    for my $dir (File::Spec->path, qw(/usr/local/bin /usr/bin /bin /usr/local/sbin /usr/sbin /sbin)) {
        next unless defined $dir && length $dir && !$seen{$dir}++;
        my $candidate = File::Spec->catfile($dir, $command);
        return $candidate if -x $candidate;
    }
    return $command;
}

sub _command_available {
    my ($command) = @_;
    my $resolved = _resolve_command($command);
    return defined $resolved && length $resolved && -x $resolved ? 1 : 0;
}

sub _system_quiet {
    my (@cmd) = @_;
    my $devnull = File::Spec->devnull;
    open my $oldout, '>&', \*STDOUT or return system(@cmd);
    open my $olderr, '>&', \*STDERR or do {
        open STDOUT, '>&', $oldout;
        close $oldout;
        return system(@cmd);
    };
    open STDOUT, '>', $devnull;
    open STDERR, '>', $devnull;
    system @cmd;
    my $status = $?;
    open STDOUT, '>&', $oldout;
    open STDERR, '>&', $olderr;
    close $oldout;
    close $olderr;
    return $status;
}

sub _ext_from_mime {
    my ($mime) = @_;
    return 'jpg' if $mime eq 'image/jpeg';
    return 'png' if $mime eq 'image/png';
    return 'webp' if $mime eq 'image/webp';
    return 'mp3' if $mime eq 'audio/mpeg';
    return 'm4a' if $mime eq 'audio/mp4' || $mime eq 'audio/x-m4a';
    return 'wav' if $mime eq 'audio/wav' || $mime eq 'audio/x-wav';
    return 'ogg' if $mime eq 'audio/ogg';
    return 'weba' if $mime eq 'audio/webm';
    return 'flac' if $mime eq 'audio/flac';
    return 'mp4' if $mime eq 'video/mp4';
    return 'm4v' if $mime eq 'video/x-m4v';
    return 'mov' if $mime eq 'video/quicktime';
    return 'webm' if $mime eq 'video/webm';
    return 'ogv' if $mime eq 'video/ogg';
    return 'pdf' if $mime eq 'application/pdf';
    return 'json' if $mime eq 'application/json';
    return 'txt' if $mime eq 'text/plain';
    return 'md' if $mime eq 'text/markdown';
    return 'csv' if $mime eq 'text/csv';
    return 'tsv' if $mime eq 'text/tab-separated-values';
    return 'docx' if $mime eq 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    return 'xlsx' if $mime eq 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    return 'pptx' if $mime eq 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    return '';
}

sub _allowed_mime {
    my ($mime) = @_;
    $mime = lc($mime || '');
    return 1 if $IMAGE_MIME{$mime};
    return 1 if $DOCUMENT_MIME{$mime};
    return 1 if $AUDIO_MIME{$mime};
    return 1 if $VIDEO_MIME{$mime};
    return 0;
}

sub _allowed_extension {
    my ($ext) = @_;
    $ext = lc($ext || '');
    return 1 if $IMAGE_EXT{$ext};
    return 1 if $SOURCE_EXT{$ext};
    return 0;
}

sub _validate_extension_for_mime {
    my ($ext, $mime) = @_;
    my $kind = asset_kind($mime);
    if ($kind eq 'image') {
        die "image uploads must use JPEG, PNG, or WebP extensions" unless $IMAGE_EXT{$ext};
        return 1;
    }
    if ($kind eq 'audio') {
        die "audio uploads must use MP3, M4A, WAV, OGG, WebM audio, or FLAC extensions" unless $AUDIO_EXT{$ext};
        return 1;
    }
    if ($kind eq 'video') {
        die "video uploads must use MP4, M4V, MOV, WebM, or OGV extensions" unless $VIDEO_EXT{$ext};
        return 1;
    }
    die "source asset uploads must use a supported document, data, audio, or video extension" unless $DOCUMENT_EXT{$ext};
    return 1;
}

sub _private_source_derivative_policy {
    my (%args) = @_;
    my $mime = $args{mime_type} || 'application/octet-stream';
    my $extension = $args{extension} || '';
    my $bytes = int($args{bytes} || 0);
    my $label = _document_label($extension, $mime);
    my $family = _document_family($extension, $mime);
    my $family_label = _document_family_label($family);
    my $byte_label = _format_bytes_label($bytes);
    my $text_preview = _text_preview_metadata(
        extension => $extension,
        mime_type => $mime,
        content   => $args{content},
    );
    my $extraction_label = _preview_extraction_label($text_preview);
    my $document = {
        type_label   => $label,
        family       => $family,
        family_label => $family_label,
        extension    => uc($extension || ''),
        mime         => _download_mime($mime),
        bytes        => $bytes,
        byte_label   => $byte_label,
        filename     => _safe_metadata_filename($args{filename}),
    };
    $document->{text_preview} = $text_preview if %{$text_preview};

    my $detail = join ' - ', grep { length } ($family_label, $byte_label, $extraction_label);
    my $preview = {
        kind         => 'document_card',
        label        => $label,
        type_label   => $label,
        family       => $family,
        family_label => $family_label,
        extension    => uc($extension || ''),
        mime         => _download_mime($mime),
        byte_label   => $byte_label,
        detail       => $detail,
    };
    for my $key (qw(snippet text_heading line_count column_count json_shape extraction_source extraction_status extraction_label)) {
        $preview->{$key} = $text_preview->{$key} if exists $text_preview->{$key};
    }

    return {
        version       => 2,
        asset_kind    => asset_kind($mime),
        public_policy => 'private_source_only',
        source_access => 'authenticated_admin_download',
        document      => $document,
        preview       => $preview,
        bytes         => $bytes,
    };
}

sub _process_private_preview_job {
    my ($self, $job) = @_;
    my $dbh = $self->{db}->dbh;
    my $id = int($job->{id} || 0);
    my $ts = now();
    $dbh->do(
        q{
            UPDATE media_preview_jobs
            SET status = 'running', attempts = attempts + 1, updated_at = ?, last_error = ''
            WHERE id = ? AND status = 'queued'
        },
        undef,
        $ts,
        $id
    );

    my $status = 'failed';
    my $error = '';
    my $ok = eval {
        my $asset = $self->asset_by_id(id => $job->{media_id});
        if (!$asset) {
            $status = 'skipped';
            $error = 'media asset is no longer active';
            return 1;
        }
        if (!_private_preview_job_supported($asset)) {
            $status = 'skipped';
            $error = 'private preview generation is not supported for this asset type';
            return 1;
        }
        my $preview = $self->_refresh_private_preview_metadata($asset);
        if (($preview->{status} || '') eq 'generated' && length($preview->{path} || '') && -f $preview->{path}) {
            $status = 'done';
            return 1;
        }
        $status = 'failed';
        $error = $preview->{detail} || $preview->{label} || 'private preview could not be generated';
        return 1;
    };
    if (!$ok) {
        $status = 'failed';
        $error = _clean_job_error($@);
    }

    $ts = now();
    $dbh->do(
        q{
            UPDATE media_preview_jobs
            SET status = ?, last_error = ?, updated_at = ?, completed_at = ?
            WHERE id = ?
        },
        undef,
        $status,
        _trim_length($error, 500),
        $ts,
        $ts,
        $id
    );
    return {
        status => $status,
        error  => $error,
    };
}

sub _refresh_private_preview_metadata {
    my ($self, $asset) = @_;
    die "media asset is required" unless $asset;
    my $path = $asset->{storage_path} || '';
    die "source asset is not available" unless length $path && -f $path;
    die "source asset path is outside the private media store"
        unless _is_under($path, $self->{config}->get('originals_dir'));

    my $meta = _decode_derivatives($asset->{derivatives_json});
    my $ext = _asset_source_extension($asset);
    $self->_attach_private_preview_metadata(
        $meta,
        source_path => $path,
        checksum    => $asset->{checksum_sha256} || '',
        extension   => $ext,
        mime_type   => $asset->{mime_type} || '',
        bytes       => int($asset->{bytes} || (-s $path) || 0),
        filename    => $asset->{original_name} || '',
    );
    my $preview = ref $meta->{private_preview} eq 'HASH' ? $meta->{private_preview} : {};
    die "private preview metadata was not produced" unless length($preview->{kind} || '');

    $self->{db}->dbh->do(
        q{
            UPDATE media_assets
            SET derivatives_json = ?
            WHERE id = ? AND deleted_at IS NULL
        },
        undef,
        encode_json($meta),
        int($asset->{id})
    );
    return $preview;
}

sub _attach_private_preview_metadata {
    my ($self, $meta, %args) = @_;
    return unless ref $meta eq 'HASH';
    my $mime = lc($args{mime_type} || '');
    my $ext = lc($args{extension} || '');
    my $kind = asset_kind($mime);
    my $preview;

    if ($ext eq 'pdf' || $mime eq 'application/pdf') {
        $preview = $self->_generate_pdf_private_preview(%args);
    } elsif ($kind eq 'video') {
        $preview = $self->_generate_video_private_preview(%args);
    } elsif ($kind eq 'audio') {
        $preview = _audio_private_preview_metadata(%args);
    }

    return unless ref $preview eq 'HASH' && length($preview->{kind} || '');
    $meta->{private_preview} = $preview;
    $meta->{preview} ||= {};
    $meta->{preview}{visual_preview_kind} = $preview->{kind};
    $meta->{preview}{visual_preview_status} = $preview->{status} || '';
    $meta->{preview}{visual_preview_label} = $preview->{label} || '';
    $meta->{preview}{visual_preview_detail} = $preview->{detail} || '';
    $meta->{preview}{visual_preview_available} = $preview->{path} ? 1 : 0;
    for my $key (qw(duration_label title artist album year technical_label)) {
        $meta->{preview}{$key} = $preview->{$key} if length($preview->{$key} || '');
    }
}

sub _preserve_private_preview_metadata {
    my ($existing, $replacement) = @_;
    return unless ref $existing eq 'HASH' && ref $replacement eq 'HASH';
    my $preview = ref $existing->{private_preview} eq 'HASH' ? $existing->{private_preview} : undef;
    return unless $preview && length($preview->{kind} || '');
    $replacement->{private_preview} = $preview;
    $replacement->{preview} ||= {};
    $replacement->{preview}{visual_preview_kind} = $preview->{kind};
    $replacement->{preview}{visual_preview_status} = $preview->{status} || '';
    $replacement->{preview}{visual_preview_label} = $preview->{label} || '';
    $replacement->{preview}{visual_preview_detail} = $preview->{detail} || '';
    $replacement->{preview}{visual_preview_available} = $preview->{path} ? 1 : 0;
    for my $key (qw(duration_label title artist album year technical_label)) {
        $replacement->{preview}{$key} = $preview->{$key} if length($preview->{$key} || '');
    }
}

sub _generate_pdf_private_preview {
    my ($self, %args) = @_;
    my $source = $args{source_path} || '';
    my $checksum = $args{checksum} || '';
    my $artifact = {
        kind   => 'pdf_page_thumbnail',
        status => 'unavailable',
        label  => 'PDF thumbnail unavailable',
        detail => 'The PDF source stays private. Install PDF-capable image tooling to generate an admin thumbnail.',
    };
    return $artifact unless length($source) && -f $source && length $checksum;

    my $dest = $self->_private_preview_path($checksum, 'pdf-page.jpg');
    my $tool = $self->{config}->get('image_tool') || 'vips';
    my @cmd = _uses_vips($tool)
        ? _vips_thumbnail_cmd($tool, $source . '[page=0]', $dest, size => '640x640', quality => 78)
        : _image_tool_cmd(
            $tool,
            'convert',
            $source . '[0]',
            '-thumbnail',
            '640x640>',
            '-background',
            'white',
            '-alpha',
            'remove',
            '-strip',
            '-quality',
            '78',
            $dest,
        );

    my (undef, $dir) = File::Spec->splitpath($dest);
    make_path($dir) unless -d $dir;
    unlink $dest if -f $dest;
    my $ok = eval {
        my $status = _system_quiet(@cmd);
        die "thumbnail command failed" if $status != 0 || !-f $dest || !-s $dest;
        chmod 0600, $dest;
        1;
    };
    return $artifact unless $ok;

    my ($width, $height) = eval { $self->_identify($dest) };
    return {
        kind       => 'pdf_page_thumbnail',
        status     => 'generated',
        label      => 'PDF page thumbnail',
        detail     => 'First-page thumbnail generated for signed-in admins.',
        path       => $dest,
        mime       => 'image/jpeg',
        bytes      => int((-s $dest) || 0),
        byte_label => _format_bytes_label((-s $dest) || 0),
        width      => int($width || 0),
        height     => int($height || 0),
    };
}

sub _generate_video_private_preview {
    my ($self, %args) = @_;
    my $source = $args{source_path} || '';
    my $checksum = $args{checksum} || '';
    my $artifact = {
        kind   => 'video_poster',
        status => 'unavailable',
        label  => 'Video poster unavailable',
        detail => 'Video poster generation is optional and requires ffmpeg on the server.',
    };
    return $artifact unless length($source) && -f $source && length $checksum;
    return $artifact unless _command_available('ffmpeg');

    my $dest = $self->_private_preview_path($checksum, 'video-poster.jpg');
    my (undef, $dir) = File::Spec->splitpath($dest);
    make_path($dir) unless -d $dir;
    unlink $dest if -f $dest;
    my @cmd = (
        _resolve_command('ffmpeg'),
        '-y',
        '-v',
        'error',
        '-ss',
        '1',
        '-i',
        $source,
        '-frames:v',
        '1',
        '-vf',
        'scale=640:-2',
        '-q:v',
        '5',
        $dest,
    );
    my $ok = eval {
        my $status = _system_quiet(@cmd);
        die "ffmpeg poster generation failed" if $status != 0 || !-f $dest || !-s $dest;
        chmod 0600, $dest;
        1;
    };
    return $artifact unless $ok;

    my ($width, $height) = eval { $self->_identify($dest) };
    return {
        kind       => 'video_poster',
        status     => 'generated',
        label      => 'Video poster',
        detail     => 'Poster frame generated for signed-in admins.',
        path       => $dest,
        mime       => 'image/jpeg',
        bytes      => int((-s $dest) || 0),
        byte_label => _format_bytes_label((-s $dest) || 0),
        width      => int($width || 0),
        height     => int($height || 0),
    };
}

sub _audio_private_preview_metadata {
    my (%args) = @_;
    my $content = defined $args{content} ? $args{content} : '';
    my $ext = lc($args{extension} || '');
    my $mime = lc($args{mime_type} || '');
    my %preview = (
        kind   => 'audio_metadata',
        status => 'metadata',
        label  => 'Audio metadata preview',
        detail => 'Audio source stays private. Metadata preview is available without publishing a waveform.',
    );
    my $duration = _audio_duration_seconds($content, $ext, $mime);
    $preview{duration_seconds} = $duration if defined $duration;
    $preview{duration_label} = _duration_label($duration) if defined $duration;
    my $technical = _audio_technical_label($content, $ext, $mime);
    $preview{technical_label} = $technical if length $technical;
    my $tags = _audio_id3v1_tags($content);
    for my $key (qw(title artist album year)) {
        $preview{$key} = $tags->{$key} if length($tags->{$key} || '');
    }
    return \%preview;
}

sub _document_family {
    my ($ext, $mime) = @_;
    $ext = lc($ext || '');
    $mime = lc($mime || '');
    return 'audio' if $AUDIO_EXT{$ext} || $mime =~ m{\Aaudio/};
    return 'video' if $VIDEO_EXT{$ext} || $mime =~ m{\Avideo/};
    return 'spreadsheet' if $ext eq 'xlsx';
    return 'presentation' if $ext eq 'pptx';
    return 'data' if $ext =~ /\A(?:csv|tsv|json)\z/ || $mime =~ m{\A(?:application/json|text/(?:csv|tab-separated-values))\z};
    return 'text' if $ext =~ /\A(?:txt|md|markdown)\z/ || $mime =~ m{\Atext/};
    return 'document';
}

sub _document_family_label {
    my ($family) = @_;
    return 'Audio' if ($family || '') eq 'audio';
    return 'Video' if ($family || '') eq 'video';
    return 'Spreadsheet' if ($family || '') eq 'spreadsheet';
    return 'Presentation' if ($family || '') eq 'presentation';
    return 'Data' if ($family || '') eq 'data';
    return 'Text' if ($family || '') eq 'text';
    return 'Document';
}

sub _document_label {
    my ($ext, $mime) = @_;
    $ext = lc($ext || '');
    $mime = lc($mime || '');
    return 'MP3 audio' if $ext eq 'mp3' || $mime eq 'audio/mpeg';
    return 'M4A audio' if $ext eq 'm4a' || $mime eq 'audio/mp4' || $mime eq 'audio/x-m4a';
    return 'WAV audio' if $ext eq 'wav' || $mime eq 'audio/wav' || $mime eq 'audio/x-wav';
    return 'OGG audio' if $ext eq 'ogg' || $ext eq 'oga' || $mime eq 'audio/ogg';
    return 'WebM audio' if $ext eq 'weba' || $mime eq 'audio/webm';
    return 'FLAC audio' if $ext eq 'flac' || $mime eq 'audio/flac';
    return 'MP4 video' if $ext eq 'mp4' || $mime eq 'video/mp4';
    return 'M4V video' if $ext eq 'm4v' || $mime eq 'video/x-m4v';
    return 'QuickTime video' if $ext eq 'mov' || $mime eq 'video/quicktime';
    return 'WebM video' if $ext eq 'webm' || $mime eq 'video/webm';
    return 'OGV video' if $ext eq 'ogv' || $mime eq 'video/ogg';
    return 'PDF document' if $ext eq 'pdf' || ($mime || '') eq 'application/pdf';
    return 'Markdown document' if $ext eq 'md' || $ext eq 'markdown';
    return 'Text document' if $ext eq 'txt';
    return 'CSV data file' if $ext eq 'csv';
    return 'TSV data file' if $ext eq 'tsv';
    return 'JSON data file' if $ext eq 'json';
    return 'Word document' if $ext eq 'docx';
    return 'Spreadsheet' if $ext eq 'xlsx';
    return 'Presentation' if $ext eq 'pptx';
    return 'Document';
}

sub _text_preview_metadata {
    my (%args) = @_;
    my $ext = lc($args{extension} || '');
    my $mime = lc($args{mime_type} || '');
    return {} unless defined $args{content};
    return {} unless _text_preview_supported($ext, $mime);

    my ($text, $source) = _extract_preview_text(
        extension => $ext,
        mime_type => $mime,
        content   => $args{content},
    );
    $text = _clean_extracted_text($text);
    my @lines = split /\n/, $text;
    my @nonempty = grep { /\S/ } @lines;
    my $joined = join "\n", @nonempty;
    $joined =~ s/[ \t]+/ /g;
    $joined =~ s/\n{3,}/\n\n/g;
    $joined = _trim_length($joined, 360);

    my %preview;
    $preview{snippet} = $joined if length $joined;
    $preview{line_count} = scalar @lines if @lines;
    $preview{extraction_source} = $source if length $source;
    $preview{extraction_status} = length $joined ? 'text_extracted' : 'metadata_only';
    $preview{extraction_label} = length $joined ? 'Text preview extracted' : 'Metadata only';
    if ($ext eq 'md' || $ext eq 'markdown' || $mime eq 'text/markdown') {
        for my $line (@nonempty) {
            if ($line =~ /\A\s{0,3}#{1,6}\s+(.+?)\s*\z/) {
                $preview{text_heading} = _trim_length($1, 90);
                last;
            }
        }
    } elsif ($source =~ /\A(?:pdf|office)_/) {
        for my $line (@nonempty) {
            my $heading = _trim_length($line, 90);
            if (length $heading) {
                $preview{text_heading} = $heading;
                last;
            }
        }
    }
    if ($ext eq 'csv' || $ext eq 'tsv' || $mime =~ m{\Atext/(?:csv|tab-separated-values)\z}) {
        my $delimiter = ($ext eq 'tsv' || $mime eq 'text/tab-separated-values') ? "\t" : ',';
        my ($header) = @nonempty;
        my @columns = defined $header ? split /\Q$delimiter\E/, $header : ();
        $preview{column_count} = scalar @columns if @columns;
    }
    if ($ext eq 'json' || $mime eq 'application/json') {
        my $trimmed = $text;
        $trimmed =~ s/\A\s+|\s+\z//g;
        $preview{json_shape} = $trimmed =~ /\A\[/ ? 'Array'
            : $trimmed =~ /\A\{/ ? 'Object'
            : 'JSON';
    }
    return \%preview;
}

sub _text_preview_supported {
    my ($ext, $mime) = @_;
    return 1 if lc($ext || '') =~ /\A(?:txt|md|markdown|csv|tsv|json)\z/;
    return 1 if lc($ext || '') =~ /\A(?:pdf|docx|xlsx|pptx)\z/;
    return 1 if lc($mime || '') eq 'application/pdf';
    return 1 if lc($mime || '') =~ m{\Aapplication/vnd\.openxmlformats-officedocument\.};
    return 1 if lc($mime || '') =~ m{\A(?:text/|application/json\z)};
    return 0;
}

sub _extract_preview_text {
    my (%args) = @_;
    my $ext = lc($args{extension} || '');
    my $mime = lc($args{mime_type} || '');
    my $content = defined $args{content} ? $args{content} : '';
    if ($ext =~ /\A(?:txt|md|markdown|csv|tsv|json)\z/ || $mime =~ m{\A(?:text/|application/json\z)}) {
        my $text = eval { decode('UTF-8', $content, FB_DEFAULT) };
        $text = $content unless defined $text;
        return ($text, 'text_source');
    }
    if ($ext eq 'pdf' || $mime eq 'application/pdf') {
        return (_pdf_preview_text($content), 'pdf_literal_text');
    }
    if ($ext =~ /\A(?:docx|xlsx|pptx)\z/ || $mime =~ m{\Aapplication/vnd\.openxmlformats-officedocument\.}) {
        return (_office_preview_text($content, $ext), 'office_open_xml');
    }
    return ('', '');
}

sub _clean_extracted_text {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text = substr($text, 0, $MAX_PREVIEW_TEXT_CHARS * 4) if length($text) > $MAX_PREVIEW_TEXT_CHARS * 4;
    $text =~ s/\r\n?/\n/g;
    $text =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/ /g;
    $text =~ s/[ \t]+/ /g;
    $text =~ s/[ ]*\n[ ]*/\n/g;
    $text =~ s/\n{3,}/\n\n/g;
    $text =~ s/\A\s+|\s+\z//g;
    return substr($text, 0, $MAX_PREVIEW_TEXT_CHARS) if length($text) > $MAX_PREVIEW_TEXT_CHARS;
    return $text;
}

sub _preview_extraction_label {
    my ($preview) = @_;
    return '' unless ref $preview eq 'HASH' && length($preview->{extraction_status} || '');
    return $preview->{extraction_label} || (
        $preview->{extraction_status} eq 'text_extracted' ? 'Text preview extracted' : 'Metadata only'
    );
}

sub _pdf_preview_text {
    my ($content) = @_;
    return '' unless defined $content && length $content;
    $content = substr($content, 0, $MAX_PREVIEW_SOURCE_BYTES) if length($content) > $MAX_PREVIEW_SOURCE_BYTES;
    my @parts;

    while ($content =~ m{/Title\s*(\((?:\\.|[^\\()]){1,500}\)|<([0-9A-Fa-f\s]{2,1000})>)}sg) {
        my $value = defined $2 ? _decode_pdf_hex_string($2) : _decode_pdf_literal_string($1);
        push @parts, $value if _useful_preview_text($value);
        last if join("\n", @parts) =~ /.{900}/s;
    }

    while ($content =~ m{\((?:\\.|[^\\()]){2,700}\)\s*(?:Tj|TJ|'|")}sg) {
        my $token = $&;
        $token =~ s{\s*(?:Tj|TJ|'|")\z}{};
        my $value = _decode_pdf_literal_string($token);
        push @parts, $value if _useful_preview_text($value);
        last if join("\n", @parts) =~ /.{1400}/s;
    }
    while ($content =~ m{<([0-9A-Fa-f\s]{4,1200})>\s*(?:Tj|TJ)}sg) {
        my $value = _decode_pdf_hex_string($1);
        push @parts, $value if _useful_preview_text($value);
        last if join("\n", @parts) =~ /.{1800}/s;
    }

    return _dedupe_preview_lines(@parts);
}

sub _decode_pdf_literal_string {
    my ($token) = @_;
    $token = '' unless defined $token;
    $token =~ s/\A\(//;
    $token =~ s/\)\z//;
    $token =~ s/\\([nrtbf()\\])/
        $1 eq 'n' ? "\n" :
        $1 eq 'r' ? "\n" :
        $1 eq 't' ? "\t" :
        $1 eq 'b' ? "\b" :
        $1 eq 'f' ? "\f" : $1
    /eg;
    $token =~ s/\\([0-7]{1,3})/chr(oct($1))/eg;
    $token =~ s/\\\r?\n//g;
    my $decoded = eval { decode('UTF-8', $token, FB_DEFAULT) };
    $decoded = $token unless defined $decoded;
    return $decoded;
}

sub _decode_pdf_hex_string {
    my ($hex) = @_;
    $hex = '' unless defined $hex;
    $hex =~ s/\s+//g;
    $hex .= '0' if length($hex) % 2;
    my $bytes = pack('H*', $hex);
    if ($bytes =~ /\A\xFE\xFF/s) {
        my $decoded = eval { decode('UTF-16BE', substr($bytes, 2), FB_DEFAULT) };
        return $decoded if defined $decoded;
    }
    my $decoded = eval { decode('UTF-8', $bytes, FB_DEFAULT) };
    $decoded = $bytes unless defined $decoded;
    return $decoded;
}

sub _office_preview_text {
    my ($content, $ext) = @_;
    return '' unless defined $content && length $content;
    my $zip = IO::Uncompress::Unzip->new(\$content);
    return '' unless $zip;

    my @parts;
    my $read_bytes = 0;
    while (1) {
        my $header = $zip->getHeaderInfo || {};
        my $name = $header->{Name} || '';
        if (_office_preview_member($name, $ext)) {
            my $xml = '';
            my $buffer = '';
            while ($zip->read($buffer, 32768) > 0) {
                $xml .= $buffer;
                $read_bytes += length($buffer);
                last if length($xml) > 500_000 || $read_bytes > $MAX_PREVIEW_SOURCE_BYTES;
            }
            my $text = _office_xml_text($xml, $ext, $name);
            push @parts, $text if _useful_preview_text($text);
        }
        last if join("\n", @parts) =~ /.{1800}/s || $read_bytes > $MAX_PREVIEW_SOURCE_BYTES;
        last unless $zip->nextStream;
    }
    return _dedupe_preview_lines(@parts);
}

sub _office_preview_member {
    my ($name, $ext) = @_;
    $name ||= '';
    $ext = lc($ext || '');
    return $name =~ m{\Aword/(?:document|footnotes|endnotes|comments|header[0-9]+|footer[0-9]+)\.xml\z} if $ext eq 'docx';
    return $name =~ m{\Axl/(?:sharedStrings|workbook)\.xml\z} || $name =~ m{\Axl/worksheets/sheet[0-9]+\.xml\z} if $ext eq 'xlsx';
    return $name =~ m{\Appt/slides/slide[0-9]+\.xml\z} if $ext eq 'pptx';
    return 0;
}

sub _office_xml_text {
    my ($xml, $ext, $name) = @_;
    return '' unless defined $xml && length $xml;
    $xml =~ s/\r\n?/\n/g;
    $xml =~ s{</(?:w:p|a:p|row|si)>}{\n}g;
    my @parts;
    if (($ext || '') eq 'xlsx' && ($name || '') =~ m{workbook\.xml\z}) {
        while ($xml =~ m{\bname="([^"]{1,160})"}sg) {
            push @parts, _decode_xml_text($1);
        }
    }
    while ($xml =~ m{<(?:(?:w|a):)?t\b[^>]*>(.*?)</(?:(?:w|a):)?t>}sg) {
        push @parts, _decode_xml_text($1);
        last if join(' ', @parts) =~ /.{2500}/s;
    }
    return join "\n", grep { length } @parts;
}

sub _decode_xml_text {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/<[^>]+>/ /g;
    $text =~ s/&#x([0-9A-Fa-f]+);/chr(hex($1))/eg;
    $text =~ s/&#([0-9]+);/chr($1)/eg;
    $text =~ s/&lt;/</g;
    $text =~ s/&gt;/>/g;
    $text =~ s/&quot;/"/g;
    $text =~ s/&apos;/'/g;
    $text =~ s/&amp;/&/g;
    $text =~ s/\s+/ /g;
    $text =~ s/\A\s+|\s+\z//g;
    return $text;
}

sub _useful_preview_text {
    my ($text) = @_;
    $text = _clean_extracted_text($text);
    return 0 unless length($text) >= 3;
    my $letters = () = $text =~ /[A-Za-z0-9]/g;
    return $letters >= 3;
}

sub _dedupe_preview_lines {
    my (@parts) = @_;
    my %seen;
    my @lines;
    for my $part (@parts) {
        $part = _clean_extracted_text($part);
        for my $line (split /\n/, $part) {
            $line = _trim_length($line, 220);
            next unless _useful_preview_text($line);
            my $key = lc $line;
            next if $seen{$key}++;
            push @lines, $line;
            last if join("\n", @lines) =~ /.{1800}/s;
        }
    }
    return join "\n", @lines;
}

sub _format_bytes_label {
    my ($bytes) = @_;
    $bytes = int($bytes || 0);
    return '' unless $bytes > 0;
    return $bytes . ' B' if $bytes < 1024;
    return sprintf('%.1f KB', $bytes / 1024) if $bytes < 1024 * 1024;
    return sprintf('%.1f MB', $bytes / (1024 * 1024)) if $bytes < 1024 * 1024 * 1024;
    return sprintf('%.1f GB', $bytes / (1024 * 1024 * 1024));
}

sub _duration_label {
    my ($seconds) = @_;
    return '' unless defined $seconds && $seconds >= 0;
    $seconds = int($seconds + 0.5);
    my $hours = int($seconds / 3600);
    my $minutes = int(($seconds % 3600) / 60);
    my $secs = $seconds % 60;
    return sprintf('%d:%02d:%02d', $hours, $minutes, $secs) if $hours;
    return sprintf('%d:%02d', $minutes, $secs);
}

sub _audio_duration_seconds {
    my ($content, $ext, $mime) = @_;
    return undef unless defined $content && length($content) >= 44;
    if (substr($content, 0, 4) eq 'RIFF' && substr($content, 8, 4) eq 'WAVE') {
        my $byte_rate = unpack('V', substr($content, 28, 4));
        return undef unless $byte_rate && $byte_rate > 0;
        my $data_size;
        my $offset = 12;
        while ($offset + 8 <= length($content)) {
            my $chunk = substr($content, $offset, 4);
            my $size = unpack('V', substr($content, $offset + 4, 4));
            if ($chunk eq 'data') {
                $data_size = $size;
                last;
            }
            $offset += 8 + $size + ($size % 2);
        }
        return defined $data_size ? ($data_size / $byte_rate) : undef;
    }
    return undef;
}

sub _audio_technical_label {
    my ($content, $ext, $mime) = @_;
    $ext = lc($ext || '');
    $mime = lc($mime || '');
    if (defined $content && length($content) >= 36 && substr($content, 0, 4) eq 'RIFF' && substr($content, 8, 4) eq 'WAVE') {
        my $channels = unpack('v', substr($content, 22, 2));
        my $sample_rate = unpack('V', substr($content, 24, 4));
        my $bits = unpack('v', substr($content, 34, 2));
        my @parts;
        push @parts, $sample_rate . ' Hz' if $sample_rate;
        push @parts, $bits . '-bit' if $bits;
        push @parts, $channels == 1 ? 'mono' : $channels == 2 ? 'stereo' : $channels . ' channels' if $channels;
        return join ', ', @parts;
    }
    return 'MP3 audio metadata' if $ext eq 'mp3' || $mime eq 'audio/mpeg';
    return 'M4A audio metadata' if $ext eq 'm4a' || $mime eq 'audio/mp4' || $mime eq 'audio/x-m4a';
    return 'OGG audio metadata' if $ext eq 'ogg' || $ext eq 'oga' || $mime eq 'audio/ogg';
    return 'FLAC audio metadata' if $ext eq 'flac' || $mime eq 'audio/flac';
    return '';
}

sub _audio_id3v1_tags {
    my ($content) = @_;
    return {} unless defined $content && length($content) >= 128;
    my $tag = substr($content, -128);
    return {} unless substr($tag, 0, 3) eq 'TAG';
    return {
        title  => _clean_id3_text(substr($tag, 3, 30)),
        artist => _clean_id3_text(substr($tag, 33, 30)),
        album  => _clean_id3_text(substr($tag, 63, 30)),
        year   => _clean_id3_text(substr($tag, 93, 4)),
    };
}

sub _clean_id3_text {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\x00+\z//g;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/[\x00-\x1F\x7F]/ /g;
    $value =~ s/\s+/ /g;
    return _trim_length($value, 90);
}

sub _safe_metadata_filename {
    my ($name) = @_;
    $name = basename($name || '');
    $name =~ s/[\r\n"\\\/]+/-/g;
    $name =~ s/^\.+//;
    $name =~ s/\s+/ /g;
    return _trim_length($name, 180);
}

sub _download_mime {
    my ($mime) = @_;
    $mime = lc($mime || 'application/octet-stream');
    return $mime if _allowed_mime($mime);
    return 'application/octet-stream';
}

sub _download_filename {
    my ($asset) = @_;
    my $name = basename($asset->{original_name} || 'source-asset');
    $name =~ s/[\r\n"\\\/]+/-/g;
    $name =~ s/^\.+//;
    $name =~ s/\s+/ /g;
    return length($name) ? $name : 'source-asset';
}

sub _private_preview_filename {
    my ($asset, $preview) = @_;
    my $name = basename($asset->{original_name} || 'media-preview');
    $name =~ s/\.[A-Za-z0-9]+\z//;
    $name =~ s/[\r\n"\\\/]+/-/g;
    $name =~ s/^\.+//;
    $name =~ s/\s+/-/g;
    $name =~ s/[^A-Za-z0-9._-]+/-/g;
    $name =~ s/-+/-/g;
    $name =~ s/\A[-.]+|[-.]+\z//g;
    $name = 'media-preview' unless length $name;
    my $mime = lc($preview->{mime} || 'image/jpeg');
    my $ext = $mime eq 'image/png' ? 'png'
        : $mime eq 'image/webp' ? 'webp'
        : $mime eq 'image/svg+xml' ? 'svg'
        : 'jpg';
    return substr($name, 0, 120) . "-preview.$ext";
}

sub _private_preview_path {
    my ($self, $checksum, $suffix) = @_;
    $checksum = lc($checksum || '');
    $checksum =~ s/[^a-f0-9]//g;
    $checksum = sha256_hex($checksum || now()) unless length $checksum >= 16;
    $suffix ||= 'preview.jpg';
    $suffix =~ s/[^A-Za-z0-9._-]+/-/g;
    my $prefix = substr($checksum, 0, 2);
    return File::Spec->catfile(
        $self->{config}->get('originals_dir'),
        'previews',
        $prefix,
        "$checksum-$suffix",
    );
}

sub _private_preview_files {
    my ($asset) = @_;
    my $meta = _decode_derivatives($asset->{derivatives_json});
    my $preview = ref $meta->{private_preview} eq 'HASH' ? $meta->{private_preview} : {};
    my $path = $preview->{path} || '';
    return () unless length $path;
    return ($path);
}

sub _private_preview_job_supported {
    my ($asset) = @_;
    return 0 unless ref $asset eq 'HASH';
    my $mime = lc($asset->{mime_type} || '');
    return 1 if asset_kind($asset) eq 'video';
    my $ext = _asset_source_extension($asset);
    return 1 if $ext eq 'pdf' || $mime eq 'application/pdf';
    return 0;
}

sub _private_preview_job_needed {
    my ($asset) = @_;
    return 0 unless _private_preview_job_supported($asset);
    my $meta = _decode_derivatives($asset->{derivatives_json});
    my $preview = ref $meta->{private_preview} eq 'HASH' ? $meta->{private_preview} : {};
    return 1 unless ($preview->{status} || '') eq 'generated';
    my $path = $preview->{path} || '';
    return 1 unless length $path && -f $path;
    return 0;
}

sub _asset_source_extension {
    my ($asset) = @_;
    return '' unless ref $asset eq 'HASH';
    my ($ext) = ($asset->{original_name} || '') =~ /\.([A-Za-z0-9]+)\z/;
    if (!$ext && length($asset->{storage_path} || '')) {
        ($ext) = ($asset->{storage_path} || '') =~ /\.([A-Za-z0-9]+)\z/;
    }
    $ext = lc($ext || _ext_from_mime(lc($asset->{mime_type} || '')));
    $ext = 'txt' if $ext eq 'text';
    return $ext;
}

sub _clean_job_error {
    my ($error) = @_;
    $error = "$error";
    $error =~ s/\s+/ /g;
    $error =~ s/\A\s+|\s+\z//g;
    return _trim_length($error || 'unknown preview generation error', 500);
}

sub _public_resource_extension {
    my ($asset) = @_;
    my ($ext) = ($asset->{original_name} || '') =~ /\.([A-Za-z0-9]+)\z/;
    $ext = lc($ext || _ext_from_mime(lc($asset->{mime_type} || '')));
    $ext = 'txt' if $ext eq 'text';
    die "resource publishing requires a supported private source extension" unless $SOURCE_EXT{$ext};
    return $ext;
}

sub _read_binary {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read source asset $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _owner_context {
    my ($self, %args) = @_;
    my $site_id = _clean_identifier(
        $args{owner_site_id}
        || $self->{config}->get('contributor_site_id')
        || _infer_site_id($self->{config})
        || 'main'
    );
    my $domain = _trim($args{owner_domain} || $self->{config}->get('contributor_domain') || _host_from_url($self->{config}->get('site_url')));
    my $name = _trim($args{owner_display_name} || $self->{config}->get('contributor_owner_name') || $self->{config}->get('site_name') || '');
    $name = $site_id eq 'main' ? 'Main deployment' : $site_id unless length $name;
    my $email = _clean_email($args{owner_email} || $self->{config}->get('contributor_owner_email') || '');
    my $uploaded_by_id = int($args{uploaded_by_user_id} || 0) || undef;

    return {
        owner_site_id        => $site_id,
        owner_domain         => $domain,
        owner_display_name   => $name,
        owner_email          => $email,
        uploaded_by_user_id  => $uploaded_by_id,
        uploaded_by_username => _clean_username($args{uploaded_by_username}),
        uploaded_by_email    => _clean_email($args{uploaded_by_email}),
    };
}

sub _infer_site_id {
    my ($config) = @_;
    my $path = $config->{path} || '';
    $path =~ s{\\}{/}g;
    return $1 if $path =~ m{/desertcms-([a-z0-9-]+)\.conf\z};

    my $data_dir = $config->get('data_dir') || '';
    $data_dir =~ s{\\}{/}g;
    return $1 if $data_dir =~ m{/desertcms-sites/([a-z0-9-]+)\z};
    return '';
}

sub _host_from_url {
    my ($url) = @_;
    return lc($1) if defined $url && $url =~ m{\Ahttps?://([^/:/]+)}i;
    return '';
}

sub _clean_identifier {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/[^a-z0-9-]/-/g;
    $value =~ s/-+/-/g;
    $value =~ s/\A-+|-+\z//g;
    return length $value ? substr($value, 0, 80) : 'main';
}

sub _clean_username {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/[^a-z0-9._-]//g;
    return substr($value, 0, 80);
}

sub _clean_email {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/^\s+|\s+$//g;
    return $value =~ /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z/ ? $value : '';
}

sub _unlink_public_derivative_if_unused {
    my ($self, $asset) = @_;
    my $public_path = $asset->{public_path} || '';
    return unless is_public_image_path($public_path);

    my ($remaining) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM media_assets WHERE deleted_at IS NULL AND public_path = ?',
        undef,
        $public_path
    );
    return if $remaining;

    for my $rel (_public_derivative_paths($asset)) {
        next unless is_public_image_variant_path($rel);
        my $file = File::Spec->catfile($self->{config}->get('public_root'), split m{/}, substr($rel, 1));
        next unless _is_under($file, $self->{config}->get('public_root'));
        unlink $file if -f $file;
    }
}

sub _unlink_public_resource_if_unused {
    my ($self, $public_path) = @_;
    return unless ($public_path || '') =~ m{\A/assets/resources/[0-9a-f]{64}\.[a-z0-9]+\z};

    my ($remaining) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM media_assets WHERE deleted_at IS NULL AND public_path = ?',
        undef,
        $public_path
    );
    return if $remaining;

    my $file = File::Spec->catfile($self->{config}->get('public_root'), split m{/}, substr($public_path, 1));
    return unless _is_under($file, $self->{config}->get('public_root'));
    unlink $file if -f $file;
}

sub _unlink_private_preview_if_unused {
    my ($self, $asset) = @_;
    my @paths = _private_preview_files($asset);
    return unless @paths;
    my $checksum = $asset->{checksum_sha256} || '';
    if (length $checksum) {
        my ($remaining) = $self->{db}->dbh->selectrow_array(
            'SELECT COUNT(*) FROM media_assets WHERE deleted_at IS NULL AND checksum_sha256 = ?',
            undef,
            $checksum
        );
        return if $remaining;
    }
    my $root = $self->{config}->get('originals_dir') || '';
    for my $path (@paths) {
        next unless _is_under($path, $root);
        unlink $path if -f $path;
    }
}

sub _unlink_original_if_unused {
    my ($self, $asset) = @_;
    my $storage_path = $asset->{storage_path} || '';
    return unless length $storage_path;

    my ($remaining) = $self->{db}->dbh->selectrow_array(
        'SELECT COUNT(*) FROM media_assets WHERE deleted_at IS NULL AND storage_path = ?',
        undef,
        $storage_path
    );
    return if $remaining;
    return unless _is_under($storage_path, $self->{config}->get('originals_dir'));
    unlink $storage_path if -f $storage_path;
}

sub _library_filter_match {
    my ($asset, $filter, $usage_by_id) = @_;
    my $kind = asset_kind($asset);
    my $policy = public_policy($asset);
    return 1 if $filter eq 'all';
    return $kind eq 'image' if $filter eq 'images';
    return $kind eq 'document' if $filter eq 'documents';
    return $kind eq 'audio' if $filter eq 'audio';
    return $kind eq 'video' if $filter eq 'video';
    return $policy eq 'public_resource_download' if $filter eq 'resources';
    return $policy ne 'private_source_only' if $filter eq 'published';
    return $policy eq 'private_source_only' if $filter eq 'private';
    return _library_asset_unused($asset, $usage_by_id) if $filter eq 'unused';
    return 0;
}

sub _library_asset_unused {
    my ($asset, $usage_by_id) = @_;
    my $id = int($asset->{id} || 0);
    my $usage = ref $usage_by_id eq 'HASH' && ref $usage_by_id->{$id} eq 'HASH'
        ? $usage_by_id->{$id}
        : {};
    return !(
        int($usage->{content_count} || 0)
        || int($usage->{shop_listing_count} || 0)
        || int($usage->{shop_order_count} || 0)
    );
}

sub _search_tokens {
    my ($query) = @_;
    $query = lc library_search_query($query);
    return grep { length } split /\s+/, $query;
}

sub _media_search_matches {
    my ($asset, $tokens) = @_;
    my $text = lc _media_search_text($asset);
    for my $token (@{ $tokens || [] }) {
        return 0 if index($text, $token) < 0;
    }
    return 1;
}

sub _media_search_text {
    my ($asset) = @_;
    return '' unless ref $asset eq 'HASH';
    my @parts = map { defined $_ ? $_ : '' } @{$asset}{qw(
        original_name
        alt_text
        seo_title
        seo_description
        category_text
        tags_text
        collections_text
        public_path
        mime_type
        owner_site_id
        owner_domain
        owner_display_name
        uploaded_by_username
    )};
    push @parts, asset_kind($asset), public_policy($asset);
    my $meta = _decode_derivatives($asset->{derivatives_json});
    _flatten_search_metadata($meta, \@parts, 0);
    my $text = join ' ', grep { defined $_ && length $_ } @parts;
    $text =~ s/[_\-\/.]+/ /g;
    $text =~ s/\s+/ /g;
    return $text;
}

sub _flatten_search_metadata {
    my ($value, $parts, $depth) = @_;
    return if $depth > 4;
    if (!ref $value) {
        push @{$parts}, $value if defined $value && length "$value";
        return;
    }
    if (ref $value eq 'ARRAY') {
        _flatten_search_metadata($_, $parts, $depth + 1) for @{$value};
        return;
    }
    if (ref $value eq 'HASH') {
        for my $key (sort keys %{$value}) {
            next if $key =~ /\A(?:width|height|bytes|line_count|column_count)\z/;
            push @{$parts}, $key if $key =~ /\A(?:type_label|family_label|extension|filename|snippet|text_heading|json_shape|label|mime)\z/;
            _flatten_search_metadata($value->{$key}, $parts, $depth + 1);
        }
    }
}

sub _is_under {
    my ($path, $root) = @_;
    return 0 unless defined $path && defined $root && length $path && length $root;
    $path =~ s{\\}{/}g;
    $root =~ s{\\}{/}g;
    $root =~ s{/+\z}{};
    return $path eq $root || index($path, "$root/") == 0;
}

sub _public_derivative_paths {
    my ($asset) = @_;
    my %seen;
    my @paths;
    my $add = sub {
        my ($path) = @_;
        return unless defined $path && length $path;
        return if $seen{$path}++;
        push @paths, $path;
    };
    $add->($asset->{public_path});
    my $derivatives = _decode_derivatives($asset->{derivatives_json});
    for my $size (@{ref $derivatives->{sizes} eq 'ARRAY' ? $derivatives->{sizes} : []}) {
        next unless ref $size eq 'HASH';
        $add->($size->{path});
    }
    return @paths;
}

sub _asset_public_files {
    my ($self, $asset) = @_;
    my $public_root = $self->{config}->get('public_root') || '';
    return [] unless length $public_root && -d $public_root;
    my @rels;
    if (asset_kind($asset) eq 'image') {
        @rels = _public_derivative_paths($asset);
    } elsif (public_policy($asset) eq 'public_resource_download') {
        @rels = ($asset->{public_path} || '');
    }

    my @files;
    my %seen;
    for my $rel (@rels) {
        next unless defined $rel && $rel =~ m{\A/assets/(?:media|resources)/};
        next if $seen{$rel}++;
        my $path = File::Spec->catfile($public_root, split m{/}, substr($rel, 1));
        next unless _is_under($path, $public_root) && -f $path;
        push @files, {
            rel        => $rel,
            path       => $path,
            bytes      => int((-s $path) || 0),
            byte_label => _format_bytes_label((-s $path) || 0),
        };
    }
    return \@files;
}

sub _retention_source_member {
    my ($asset) = @_;
    my $id = int($asset->{id} || 0) || 0;
    my $name = basename($asset->{original_name} || 'source-asset');
    $name =~ s/[\r\n"\\\/]+/-/g;
    $name =~ s/^\.+//;
    $name =~ s/\s+/-/g;
    $name =~ s/[^A-Za-z0-9._-]+/-/g;
    $name =~ s/-+/-/g;
    $name =~ s/\A[-.]+|[-.]+\z//g;
    $name = 'source-asset' unless length $name;
    $name = substr($name, 0, 140);
    return 'sources/' . $id . '-' . $name;
}

sub _decode_derivatives {
    my ($json) = @_;
    return {} unless defined $json && length $json;
    my $decoded = eval { decode_json($json) };
    return ref $decoded eq 'HASH' ? $decoded : {};
}

sub _archive_and_delete_retention_assets {
    my ($self, $entries, %args) = @_;
    my $retention_days = _lifecycle_retention_days($args{retention_days});
    my $cutoff = now() - ($retention_days * 86400);
    my @assets;
    my $skipped = 0;
    my @errors;

    for my $entry (@{ $entries || [] }) {
        my $id = int($entry->{id} || 0);
        if (!$id) {
            $skipped++;
            next;
        }
        my $asset = $self->{db}->dbh->selectrow_hashref(
            'SELECT * FROM media_assets WHERE id = ? AND deleted_at IS NULL',
            undef,
            $id
        );
        if (!$asset) {
            $skipped++;
            next;
        }
        my $usage = $self->usage_for_asset(asset => $asset);
        if (!_lifecycle_asset_unused($usage) || int($asset->{created_at} || 0) > $cutoff) {
            $skipped++;
            next;
        }
        my $source = $asset->{storage_path} || '';
        if (!length($source) || !_is_under($source, $self->{config}->get('originals_dir')) || !-f $source) {
            $skipped++;
            push @errors, _trim_length('Skipped media #' . $id . ' because the private source file could not be archived.', 220) if @errors < 3;
            next;
        }
        push @assets, $asset;
    }

    return { changed => 0, bytes => 0, skipped => $skipped, errors => \@errors, archive_path => '' }
        unless @assets;

    my ($archive_path, $manifest) = $self->_create_retention_archive(\@assets, retention_days => $retention_days);
    my ($changed, $bytes) = (0, 0);
    for my $asset (@assets) {
        my $id = int($asset->{id} || 0);
        my $ok = eval {
            my $deleted = $self->delete_asset(id => $id);
            $bytes += int($asset->{bytes} || 0) if $deleted && $deleted->{deleted_at};
            1;
        };
        if ($ok) {
            $changed++;
        } else {
            $skipped++;
            push @errors, _trim_length($@ || 'delete failed', 220) if @errors < 3;
        }
    }

    return {
        changed      => $changed,
        bytes        => $bytes,
        skipped      => $skipped,
        errors       => \@errors,
        archive_path => $archive_path,
        manifest     => $manifest,
    };
}

sub _create_retention_archive {
    my ($self, $assets, %args) = @_;
    my $retention_days = _lifecycle_retention_days($args{retention_days});
    my $backup_dir = $self->{config}->get('backup_dir') || File::Spec->catdir($self->{config}->get('data_dir') || '.', 'backups');
    make_path($backup_dir) unless -d $backup_dir;
    my $archive_dir = File::Spec->catdir($backup_dir, 'media-retention');
    make_path($archive_dir) unless -d $archive_dir;

    my $stamp = _media_archive_timestamp();
    my ($staging, $archive) = _unique_media_archive_paths($backup_dir, $archive_dir, $stamp);
    remove_tree($staging) if -d $staging;
    make_path($staging);

    my $manifest;
    eval {
        my @manifest_assets;
        my %copied;
        for my $asset (@{ $assets || [] }) {
            my $id = int($asset->{id} || 0);
            my $source_member = _retention_source_member($asset);
            my $source_dest = File::Spec->catfile($staging, split m{/}, $source_member);
            _copy_file($asset->{storage_path}, $source_dest);
            my @public_members;
            for my $file (@{ $self->_asset_public_files($asset) }) {
                my $member = 'public' . $file->{rel};
                $member =~ s{\A/+}{};
                next if $copied{$member}++;
                my $dest = File::Spec->catfile($staging, split m{/}, $member);
                _copy_file($file->{path}, $dest);
                push @public_members, $member;
            }
            my @preview_members;
            for my $path (_private_preview_files($asset)) {
                next unless _is_under($path, $self->{config}->get('originals_dir')) && -f $path;
                my $member = 'private-previews/' . $id . '-' . basename($path);
                next if $copied{$member}++;
                my $dest = File::Spec->catfile($staging, split m{/}, $member);
                _copy_file($path, $dest);
                push @preview_members, $member;
            }
            push @manifest_assets, {
                id                => $id,
                original_name     => $asset->{original_name} || '',
                mime_type         => $asset->{mime_type} || '',
                bytes             => int($asset->{bytes} || 0),
                checksum_sha256   => $asset->{checksum_sha256} || '',
                created_at        => int($asset->{created_at} || 0),
                public_path       => $asset->{public_path} || '',
                public_policy     => public_policy($asset),
                source_member     => $source_member,
                public_members    => \@public_members,
                private_preview_members => \@preview_members,
            };
        }

        $manifest = {
            version        => 1,
            archive_type   => 'media-retention',
            created_at     => now(),
            retention_days => $retention_days,
            site_name      => $self->{config}->get('site_name') || '',
            asset_count    => scalar @manifest_assets,
            assets         => \@manifest_assets,
        };
        _write_file(File::Spec->catfile($staging, 'manifest.json'), encode_json($manifest));
        _tar_create($self->{config}, $archive, $staging);
        1;
    } or do {
        my $err = $@ || 'media retention archive failed';
        remove_tree($staging) if -d $staging;
        unlink $archive if -f $archive;
        die $err;
    };

    remove_tree($staging) if -d $staging;
    return ($archive, $manifest);
}

sub _trim {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s+/ /g;
    return substr($value, 0, 240);
}

sub _trim_length {
    my ($value, $max) = @_;
    $value = _trim($value);
    return substr($value, 0, $max) if length($value) > $max;
    return $value;
}

sub _clean_org_label {
    my ($value) = @_;
    $value = _trim_length($value, 80);
    $value =~ s/[,;|]+/ /g;
    $value =~ s/\s+/ /g;
    return $value;
}

sub _clean_org_list {
    my ($value) = @_;
    my %seen;
    my @terms;
    for my $term (_organization_terms($value)) {
        my $key = lc $term;
        next if $seen{$key}++;
        push @terms, $term;
        last if @terms >= 30;
    }
    return join ', ', @terms;
}

sub _organization_terms {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\x00-\x09\x0B\x0C\x0E-\x1F\x7F]/ /g;
    my @terms;
    for my $part (split /[,;\n\r|]+/, $value) {
        my $term = _clean_org_label($part);
        push @terms, $term if length $term;
    }
    return @terms;
}

sub _org_list_contains {
    my ($value, $needle) = @_;
    $needle = lc _clean_org_label($needle);
    return 0 unless length $needle;
    for my $term (_organization_terms($value)) {
        return 1 if lc($term) eq $needle;
    }
    return 0;
}

sub _copy_file {
    my ($source, $dest) = @_;
    die "source file missing: $source" unless defined $source && -f $source;
    make_path(dirname($dest)) unless -d dirname($dest);
    copy($source, $dest) or die "cannot copy $source to $dest: $!";
}

sub _write_file {
    my ($path, $body) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _tar_create {
    my ($config, $archive, $staging) = @_;
    my $tar = $config->get('tar_tool') || 'tar';
    system $tar, '-czf', $archive, '-C', $staging, '.';
    die "media retention tar create failed with status $?" if $? != 0 || !-f $archive;
}

sub _media_archive_timestamp {
    my @t = localtime;
    return sprintf '%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

sub _unique_media_archive_paths {
    my ($backup_dir, $archive_dir, $stamp) = @_;
    my $suffix = '';
    my $i = 1;
    while (1) {
        my $staging = File::Spec->catdir($backup_dir, ".media-retention-$stamp$suffix");
        my $archive = File::Spec->catfile($archive_dir, "media-retention-$stamp$suffix.tar.gz");
        return ($staging, $archive) if !-e $archive && !-d $staging;
        $i++;
        $suffix = "-$i";
    }
}

sub _lifecycle_large_min_bytes {
    my ($bytes, $mb) = @_;
    if (defined $bytes && "$bytes" =~ /\A[0-9]+\z/) {
        return int($bytes) > 0 ? int($bytes) : $DEFAULT_LARGE_UNUSED_BYTES;
    }
    if (defined $mb && "$mb" =~ /\A[0-9]+(?:\.[0-9]+)?\z/) {
        my $value = int($mb * 1024 * 1024);
        return $value > 0 ? $value : $DEFAULT_LARGE_UNUSED_BYTES;
    }
    return $DEFAULT_LARGE_UNUSED_BYTES;
}

sub _lifecycle_retention_days {
    my ($days) = @_;
    return $DEFAULT_RETENTION_UNUSED_DAYS unless defined $days && "$days" =~ /\A[0-9]+\z/;
    $days = int($days);
    $days = 1 if $days < 1;
    $days = 3650 if $days > 3650;
    return $days;
}

sub _lifecycle_asset_entry {
    my ($asset, %args) = @_;
    $asset ||= {};
    my $bytes = int($asset->{bytes} || 0);
    return {
        id           => int($asset->{id} || 0),
        name         => $asset->{original_name} || 'source asset',
        kind         => asset_kind($asset),
        public_path  => $asset->{public_path} || '',
        storage_path => $asset->{storage_path} || '',
        mime_type    => $asset->{mime_type} || '',
        bytes        => $bytes,
        byte_label   => _format_bytes_label($bytes),
        created_at   => int($asset->{created_at} || 0),
        reason       => _trim($args{reason} || ''),
        usage        => ref $args{usage} eq 'HASH' ? $args{usage} : undef,
    };
}

sub _lifecycle_asset_unused {
    my ($usage) = @_;
    $usage ||= {};
    return !(
        int($usage->{content_count} || 0)
        || int($usage->{shop_listing_count} || 0)
        || int($usage->{shop_order_count} || 0)
    );
}

sub _sum_bytes {
    my ($entries) = @_;
    my $sum = 0;
    for my $entry (@{ $entries || [] }) {
        $sum += int($entry->{bytes} || 0);
    }
    return $sum;
}

sub _public_files {
    my ($self, @parts) = @_;
    my $public_root = $self->{config}->get('public_root') || '';
    return [] unless length $public_root && -d $public_root;
    my $dir = File::Spec->catdir($public_root, @parts);
    return [] unless -d $dir && _is_under($dir, $public_root);

    my @files;
    find(
        {
            wanted => sub {
                return unless -f $File::Find::name;
                my $path = $File::Find::name;
                return unless _is_under($path, $public_root);
                my $rel = $path;
                $rel =~ s{\\}{/}g;
                my $root = $public_root;
                $root =~ s{\\}{/}g;
                $root =~ s{/+\z}{};
                return unless index($rel, "$root/") == 0;
                $rel = substr($rel, length($root));
                my $bytes = -s $path;
                push @files, {
                    rel        => $rel,
                    path       => $path,
                    bytes      => int($bytes || 0),
                    byte_label => _format_bytes_label($bytes || 0),
                };
            },
            no_chdir => 1,
        },
        $dir
    );
    return \@files;
}

sub _cleanup_public_files {
    my ($self, $entries) = @_;
    my $public_root = $self->{config}->get('public_root') || '';
    my ($changed, $bytes, $skipped) = (0, 0, 0);
    my @errors;
    for my $entry (@{ $entries || [] }) {
        my $path = $entry->{path} || '';
        if (!length($path) || !_is_under($path, $public_root) || !-f $path) {
            $skipped++;
            next;
        }
        my $size = int($entry->{bytes} || (-s $path) || 0);
        if (unlink $path) {
            $changed++;
            $bytes += $size;
        } else {
            $skipped++;
            push @errors, _trim_length("cannot remove $path: $!", 220) if @errors < 3;
        }
    }
    return ($changed, $bytes, $skipped, @errors);
}

1;
