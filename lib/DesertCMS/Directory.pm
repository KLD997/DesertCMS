package DesertCMS::Directory;

use strict;
use warnings;
use DesertCMS::Media;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Util qw(hmac_sha256_hex now slugify);

my %ENTRY_KIND = map { $_ => 1 } qw(
    person business artist contributor vendor member place resource organization other
);

my %LOCATION_KIND = map { $_ => 1 } qw(
    store venue project historical_site event_location service_area other
);

my %STATUS = map { $_ => 1 } qw(draft pending published archived);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub enabled {
    my ($self) = @_;
    return DesertCMS::Modules::enabled(_settings($self), 'directory');
}

sub list_admin {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM directory_entries
            WHERE deleted_at IS NULL
            ORDER BY
                CASE status WHEN 'pending' THEN 0 WHEN 'draft' THEN 1 WHEN 'published' THEN 2 ELSE 3 END,
                featured DESC,
                sort_order ASC,
                updated_at DESC,
                id DESC
        },
        { Slice => {} }
    );
}

sub published_entries {
    my ($self, %args) = @_;
    my @where = ("status = 'published'", 'deleted_at IS NULL');
    my @bind;
    if (length($args{kind} || '')) {
        push @where, 'kind = ?';
        push @bind, _kind($args{kind});
    }
    my $limit = int($args{limit} || 500);
    $limit = 500 if $limit < 1 || $limit > 2000;
    return $self->{db}->dbh->selectall_arrayref(
        'SELECT * FROM directory_entries WHERE ' . join(' AND ', @where)
            . " ORDER BY featured DESC, sort_order ASC, title ASC, id ASC LIMIT $limit",
        { Slice => {} },
        @bind
    );
}

sub public_kinds {
    my ($self) = @_;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT kind, COUNT(*) AS count
            FROM directory_entries
            WHERE status = 'published'
              AND deleted_at IS NULL
            GROUP BY kind
            ORDER BY kind ASC
        },
        { Slice => {} }
    );
    return $rows;
}

sub get {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM directory_entries WHERE id = ? AND deleted_at IS NULL',
        undef,
        $id
    );
}

sub by_slug {
    my ($self, $slug) = @_;
    $slug = _slug($slug);
    return undef unless length $slug;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM directory_entries
            WHERE slug = ?
              AND status = 'published'
              AND deleted_at IS NULL
            LIMIT 1
        },
        undef,
        $slug
    );
}

sub save_entry {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $title = _text($args{title}, 180);
    die "directory entry title is required" unless length $title;
    my $slug = _unique_slug($self->{db}->dbh, _slug($args{slug}) || slugify($title), $id);
    my $status = _status($args{status});
    my $kind = _kind($args{kind});
    my $now = now();
    my %row = (
        kind              => $kind,
        title             => $title,
        slug              => $slug,
        status            => $status,
        summary           => _text($args{summary}, 500),
        body              => _body($args{body}, 8000),
        image_path        => _image_path($args{image_path}),
        email             => _email($args{email}),
        phone             => _text($args{phone}, 80),
        website_url       => _url($args{website_url}),
        social_url        => _url($args{social_url}),
        contact_label     => _text($args{contact_label}, 80) || 'Contact',
        address           => _text($args{address}, 500),
        tags_text         => _terms($args{tags_text}, 500),
        categories_text   => _terms($args{categories_text}, 500),
        featured          => _bool($args{featured}),
        sort_order        => _int($args{sort_order}, 100, 0, 100000),
        related_content_id => _positive_int($args{related_content_id}),
        related_event_id   => _positive_int($args{related_event_id}),
        related_shop_listing_id => _positive_int($args{related_shop_listing_id}),
        location_enabled  => _bool($args{location_enabled}),
        location_lat      => _coordinate($args{location_lat}, -90, 90),
        location_lng      => _coordinate($args{location_lng}, -180, 180),
        location_label    => _text($args{location_label}, 300),
        location_kind     => _location_kind($args{location_kind}),
        source            => _source($args{source}),
        submitter_name    => _text($args{submitter_name}, 120),
        submitter_email   => _email($args{submitter_email}),
        submission_note   => _text($args{submission_note}, 1000),
    );
    $row{location_enabled} = 0 unless defined $row{location_lat} && defined $row{location_lng};
    my $published_at = $status eq 'published'
        ? (int($args{published_at} || 0) || $now)
        : undef;

    my $dbh = $self->{db}->dbh;
    if ($id > 0 && $self->get($id)) {
        $dbh->do(
            q{
                UPDATE directory_entries
                SET kind = ?, title = ?, slug = ?, status = ?, summary = ?, body = ?,
                    image_path = ?, email = ?, phone = ?, website_url = ?, social_url = ?,
                    contact_label = ?, address = ?, tags_text = ?, categories_text = ?,
                    featured = ?, sort_order = ?, related_content_id = ?, related_event_id = ?,
                    related_shop_listing_id = ?, location_enabled = ?, location_lat = ?, location_lng = ?,
                    location_label = ?, location_kind = ?, source = ?, submitter_name = ?,
                    submitter_email = ?, submission_note = ?, updated_at = ?,
                    published_at = CASE WHEN ? = 'published' AND published_at IS NULL THEN ? ELSE published_at END
                WHERE id = ?
            },
            undef,
            @row{qw(
                kind title slug status summary body image_path email phone website_url social_url
                contact_label address tags_text categories_text featured sort_order related_content_id
                related_event_id related_shop_listing_id location_enabled location_lat location_lng
                location_label location_kind source submitter_name submitter_email submission_note
            )},
            $now,
            $status,
            $now,
            $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO directory_entries
                    (kind, title, slug, status, summary, body, image_path, email, phone,
                     website_url, social_url, contact_label, address, tags_text, categories_text,
                     featured, sort_order, related_content_id, related_event_id, related_shop_listing_id,
                     location_enabled, location_lat, location_lng, location_label, location_kind,
                     source, submitter_name, submitter_email, submission_note,
                     ip_hash, user_agent_hash, created_at, updated_at, published_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            @row{qw(
                kind title slug status summary body image_path email phone website_url social_url
                contact_label address tags_text categories_text featured sort_order related_content_id
                related_event_id related_shop_listing_id location_enabled location_lat location_lng
                location_label location_kind source submitter_name submitter_email submission_note
            )},
            _hash($self, $args{ip_address}),
            _hash($self, $args{user_agent}),
            $now,
            $now,
            $published_at
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->get($id);
}

sub submit_public {
    my ($self, %args) = @_;
    my $settings = _settings($self);
    die "directory submissions are not enabled" unless _bool($settings->{directory_submissions_enabled});
    $args{status} = 'pending';
    $args{source} = 'public_submission';
    $args{submitter_name} ||= $args{title};
    $args{submitter_email} ||= $args{email};
    return $self->save_entry(%args);
}

sub publish_entry {
    my ($self, $id) = @_;
    my $entry = $self->get($id) or die "directory entry not found";
    $self->{db}->dbh->do(
        q{
            UPDATE directory_entries
            SET status = 'published',
                published_at = COALESCE(published_at, ?),
                updated_at = ?
            WHERE id = ?
        },
        undef,
        now(),
        now(),
        int($id || 0)
    );
    return $self->get($id);
}

sub archive_entry {
    my ($self, $id) = @_;
    my $entry = $self->get($id) or die "directory entry not found";
    $self->{db}->dbh->do(
        q{
            UPDATE directory_entries
            SET status = 'archived',
                deleted_at = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        now(),
        now(),
        int($id || 0)
    );
    return $entry;
}

sub csv_export {
    my ($self) = @_;
    my @headers = qw(id status kind title slug summary email phone website_url categories_text tags_text featured updated_at);
    my $csv = join(',', map { _csv($_) } @headers) . "\n";
    for my $row (@{ $self->list_admin }) {
        $csv .= join(',', map { _csv($row->{$_}) } @headers) . "\n";
    }
    return $csv;
}

sub kind_label {
    my ($kind) = @_;
    my %labels = (
        person       => 'Person',
        business     => 'Business',
        artist       => 'Artist',
        contributor  => 'Contributor',
        vendor       => 'Vendor',
        member       => 'Member',
        place        => 'Place',
        resource     => 'Resource',
        organization => 'Organization',
        other        => 'Other',
    );
    return $labels{_kind($kind)} || 'Other';
}

sub kinds {
    return [ qw(person business artist contributor vendor member place resource organization other) ];
}

sub _settings {
    my ($self) = @_;
    $self->{settings_cache} ||= DesertCMS::Settings::all($self->{config}, $self->{db});
    return $self->{settings_cache};
}

sub clear_settings_cache {
    my ($self) = @_;
    delete $self->{settings_cache};
    return 1;
}

sub _unique_slug {
    my ($dbh, $base, $id) = @_;
    $base = _slug($base) || 'directory-entry';
    my $slug = $base;
    my $i = 2;
    while (1) {
        my ($existing) = $dbh->selectrow_array(
            'SELECT id FROM directory_entries WHERE slug = ? AND deleted_at IS NULL AND (? = 0 OR id <> ?) LIMIT 1',
            undef,
            $slug,
            int($id || 0),
            int($id || 0)
        );
        return $slug unless $existing;
        $slug = "$base-$i";
        $i++;
    }
}

sub _kind {
    my ($value) = @_;
    $value = lc($value || 'other');
    $value =~ s/[-\s]+/_/g;
    return $ENTRY_KIND{$value} ? $value : 'other';
}

sub _location_kind {
    my ($value) = @_;
    $value = lc($value || 'other');
    $value =~ s/[-\s]+/_/g;
    return $LOCATION_KIND{$value} ? $value : 'other';
}

sub _status {
    my ($value) = @_;
    $value = lc($value || 'draft');
    return $STATUS{$value} ? $value : 'draft';
}

sub _slug {
    my ($value) = @_;
    return slugify(_text($value, 160));
}

sub _text {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
    $value =~ s/^\s+|\s+\z//g;
    $max ||= 255;
    return substr($value, 0, $max);
}

sub _body {
    my ($value, $max) = @_;
    $value = _text($value, $max || 8000);
    return $value;
}

sub _terms {
    my ($value, $max) = @_;
    $value = _text($value, $max || 500);
    my @terms = grep { length } map {
        my $term = $_;
        $term =~ s/^\s+|\s+\z//g;
        substr($term, 0, 80);
    } split /,/, $value;
    my %seen;
    return join(', ', grep { !$seen{lc $_}++ } @terms);
}

sub _email {
    my ($value) = @_;
    $value = lc _text($value, 180);
    return '' unless length $value;
    die "email address is invalid" unless $value =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/;
    return $value;
}

sub _url {
    my ($value) = @_;
    $value = _text($value, 500);
    return '' unless length $value;
    die "URL must start with http:// or https://" unless $value =~ m{\Ahttps?://}i;
    return $value;
}

sub _image_path {
    my ($value) = @_;
    $value = _text($value, 300);
    return $value if DesertCMS::Media::is_public_image_path($value);
    return '';
}

sub _source {
    my ($value) = @_;
    $value = lc($value || 'manual');
    $value =~ s/[-\s]+/_/g;
    return $value =~ /\A(?:manual|public_submission|import)\z/ ? $value : 'manual';
}

sub _coordinate {
    my ($value, $min, $max) = @_;
    return undef unless defined $value && "$value" =~ /\S/;
    die "coordinate is invalid" unless "$value" =~ /\A-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/;
    my $n = 0 + $value;
    die "coordinate is out of range" if $n < $min || $n > $max;
    return $n;
}

sub _positive_int {
    my ($value) = @_;
    $value = int($value || 0);
    return $value > 0 ? $value : undef;
}

sub _int {
    my ($value, $default, $min, $max) = @_;
    $value = defined $value && "$value" =~ /\A-?[0-9]+\z/ ? int($value) : $default;
    $value = $min if defined $min && $value < $min;
    $value = $max if defined $max && $value > $max;
    return $value;
}

sub _bool {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _hash {
    my ($self, $value) = @_;
    $value = '' unless defined $value;
    return '' unless length $value;
    return hmac_sha256_hex($value, $self->{config}->app_secret);
}

sub _csv {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

1;
