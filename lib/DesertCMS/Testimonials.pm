package DesertCMS::Testimonials;

use strict;
use warnings;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Util qw(hmac_sha256_hex now slugify);

my %STATUS = map { $_ => 1 } qw(draft pending published rejected archived);
my %SOURCE_TYPE = map { $_ => 1 } qw(manual public_submission client customer member event booking other);

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
    return DesertCMS::Modules::enabled(_settings($self), 'testimonials');
}

sub clear_settings_cache {
    my ($self) = @_;
    delete $self->{settings_cache};
    return 1;
}

sub list_admin {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT t.*,
                   de.title AS related_directory_title,
                   bs.title AS related_booking_title
            FROM testimonials t
            LEFT JOIN directory_entries de ON de.id = t.related_directory_entry_id
            LEFT JOIN booking_services bs ON bs.id = t.related_booking_service_id
            ORDER BY
                CASE t.status
                    WHEN 'pending' THEN 0
                    WHEN 'draft' THEN 1
                    WHEN 'published' THEN 2
                    WHEN 'rejected' THEN 3
                    ELSE 4
                END,
                t.featured DESC,
                t.sort_order ASC,
                t.updated_at DESC,
                t.id DESC
        },
        { Slice => {} }
    );
}

sub published_testimonials {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 500, 1, 5000);
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT t.*,
                   de.title AS related_directory_title,
                   bs.title AS related_booking_title
            FROM testimonials t
            LEFT JOIN directory_entries de ON de.id = t.related_directory_entry_id
            LEFT JOIN booking_services bs ON bs.id = t.related_booking_service_id
            WHERE t.status = 'published'
            ORDER BY t.featured DESC, t.sort_order ASC, t.published_at DESC, t.id DESC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub get {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT t.*,
                   de.title AS related_directory_title,
                   bs.title AS related_booking_title
            FROM testimonials t
            LEFT JOIN directory_entries de ON de.id = t.related_directory_entry_id
            LEFT JOIN booking_services bs ON bs.id = t.related_booking_service_id
            WHERE t.id = ?
        },
        undef,
        $id
    );
}

sub save_testimonial {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $author = _text($args{author_name} || $args{display_name}, 180);
    die "testimonial display name is required" unless length $author;
    my $quote = _body($args{quote}, 1200);
    die "testimonial quote is required" unless length $quote;
    my $status = _status($args{status});
    my $slug = _unique_slug($self->{db}->dbh, _slug($args{slug}) || slugify($author), $id);
    my $now = now();
    my %row = (
        author_name                => $author,
        author_title               => _text($args{author_title}, 180),
        organization               => _text($args{organization}, 180),
        slug                       => $slug,
        status                     => $status,
        quote                      => $quote,
        body                       => _body($args{body}, 4000),
        rating                     => _rating($args{rating}),
        source_type                => _source_type($args{source_type}),
        related_directory_entry_id => _positive_int($args{related_directory_entry_id}),
        related_booking_service_id => _positive_int($args{related_booking_service_id}),
        image_path                 => _image_path($args{image_path}),
        featured                   => _bool($args{featured}) ? 1 : 0,
        sort_order                 => _int($args{sort_order}, 100, 0, 100000),
        submitter_email            => _email_optional($args{submitter_email} || $args{email}),
        submission_note            => _text($args{submission_note}, 1000),
    );
    my $dbh = $self->{db}->dbh;
    if ($id > 0 && $self->get($id)) {
        $dbh->do(
            q{
                UPDATE testimonials
                SET author_name = ?, author_title = ?, organization = ?, slug = ?, status = ?,
                    quote = ?, body = ?, rating = ?, source_type = ?,
                    related_directory_entry_id = ?, related_booking_service_id = ?,
                    image_path = ?, featured = ?, sort_order = ?, submitter_email = ?,
                    submission_note = ?, updated_at = ?,
                    published_at = CASE WHEN ? = 'published' THEN COALESCE(published_at, ?) ELSE published_at END,
                    rejected_at = CASE WHEN ? = 'rejected' THEN COALESCE(rejected_at, ?) ELSE rejected_at END,
                    archived_at = CASE WHEN ? = 'archived' THEN COALESCE(archived_at, ?) ELSE archived_at END
                WHERE id = ?
            },
            undef,
            @row{qw(
                author_name author_title organization slug status quote body rating source_type
                related_directory_entry_id related_booking_service_id image_path featured sort_order
                submitter_email submission_note
            )},
            $now,
            $status, $now,
            $status, $now,
            $status, $now,
            $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO testimonials
                    (author_name, author_title, organization, slug, status, quote, body, rating,
                     source_type, related_directory_entry_id, related_booking_service_id, image_path,
                     featured, sort_order, submitter_email, submission_note, ip_hash, user_agent_hash,
                     created_at, updated_at, published_at, rejected_at, archived_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            @row{qw(
                author_name author_title organization slug status quote body rating source_type
                related_directory_entry_id related_booking_service_id image_path featured sort_order
                submitter_email submission_note
            )},
            _hash($self, $args{ip_address}),
            _hash($self, $args{user_agent}),
            $now,
            $now,
            $status eq 'published' ? $now : undef,
            $status eq 'rejected' ? $now : undef,
            $status eq 'archived' ? $now : undef
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->get($id);
}

sub submit_public {
    my ($self, %args) = @_;
    my $settings = _settings($self);
    die "testimonial submissions are not enabled" unless _bool($settings->{testimonials_submissions_enabled});
    $args{status} = 'pending';
    $args{source_type} = 'public_submission';
    $args{submitter_email} ||= $args{email};
    return $self->save_testimonial(%args);
}

sub publish_testimonial {
    my ($self, $id) = @_;
    $self->get($id) or die "testimonial not found";
    $self->{db}->dbh->do(
        q{
            UPDATE testimonials
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

sub reject_testimonial {
    my ($self, $id) = @_;
    $self->get($id) or die "testimonial not found";
    $self->{db}->dbh->do(
        q{
            UPDATE testimonials
            SET status = 'rejected',
                rejected_at = COALESCE(rejected_at, ?),
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

sub archive_testimonial {
    my ($self, $id) = @_;
    $self->get($id) or die "testimonial not found";
    $self->{db}->dbh->do(
        q{
            UPDATE testimonials
            SET status = 'archived',
                archived_at = COALESCE(archived_at, ?),
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

sub csv_export {
    my ($self) = @_;
    my @headers = qw(id status author_name author_title organization quote rating source_type related_directory_title related_booking_title featured sort_order submitter_email created_at updated_at published_at);
    my $csv = join(',', map { _csv($_) } @headers) . "\n";
    for my $row (@{ $self->list_admin }) {
        $csv .= join(',', map { _csv($row->{$_}) } @headers) . "\n";
    }
    return $csv;
}

sub source_type_label {
    my ($value) = @_;
    my %labels = (
        manual            => 'Manual entry',
        public_submission => 'Public submission',
        client            => 'Client',
        customer          => 'Customer',
        member            => 'Member',
        event             => 'Event attendee',
        booking           => 'Booking client',
        other             => 'Other source',
    );
    return $labels{_source_type($value)} || 'Other source';
}

sub source_types {
    return [ qw(manual public_submission client customer member event booking other) ];
}

sub status_label {
    my ($value) = @_;
    my %labels = (
        draft     => 'Draft',
        pending   => 'Pending review',
        published => 'Approved',
        rejected  => 'Rejected',
        archived  => 'Archived',
    );
    return $labels{_status($value)} || 'Draft';
}

sub statuses {
    return [ qw(draft pending published rejected archived) ];
}

sub rating_label {
    my ($rating) = @_;
    $rating = int($rating || 0);
    return '' unless $rating >= 1 && $rating <= 5;
    return $rating == 1 ? '1 star' : "$rating stars";
}

sub _settings {
    my ($self) = @_;
    $self->{settings_cache} ||= DesertCMS::Settings::all($self->{config}, $self->{db});
    return $self->{settings_cache};
}

sub _unique_slug {
    my ($dbh, $base, $id) = @_;
    $base = _slug($base) || 'testimonial';
    my $slug = $base;
    my $i = 2;
    while (1) {
        my ($existing) = $dbh->selectrow_array(
            'SELECT id FROM testimonials WHERE slug = ? AND (? = 0 OR id <> ?) LIMIT 1',
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

sub _status {
    my ($value) = @_;
    $value = lc($value || 'draft');
    $value =~ s/[-\s]+/_/g;
    return $STATUS{$value} ? $value : 'draft';
}

sub _source_type {
    my ($value) = @_;
    $value = lc($value || 'manual');
    $value =~ s/[-\s]+/_/g;
    return $SOURCE_TYPE{$value} ? $value : 'manual';
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
    return _text($value, $max || 4000);
}

sub _email_optional {
    my ($value) = @_;
    $value = lc _text($value, 180);
    return '' unless length $value;
    die "email address is invalid" unless $value =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/;
    return $value;
}

sub _image_path {
    my ($value) = @_;
    $value = _text($value, 300);
    return $value if $value =~ m{\A/assets/media/[0-9a-f]{64}\.jpg\z};
    return '';
}

sub _rating {
    my ($value) = @_;
    return undef unless defined $value && "$value" =~ /\S/;
    die "rating must be between 1 and 5" unless "$value" =~ /\A[1-5]\z/;
    return int($value);
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

sub _limit {
    my ($value, $default, $min, $max) = @_;
    $value = int($value || $default || 0);
    $value = $min if $value < $min;
    $value = $max if $value > $max;
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
