package DesertCMS::ContributorRequests;

use strict;
use warnings;
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP qw(encode_json decode_json);
use DesertCMS::Email qw(send_postmark);
use DesertCMS::HTTP ();
use DesertCMS::Media;
use DesertCMS::Settings;
use DesertCMS::Util qw(escape_html hmac_sha256_hex now random_hex);

my $MAX_NAME = 120;
my $MAX_EMAIL = 180;
my $MAX_PHONE = 40;
my $MIN_BIO = 150;
my $MAX_BIO = 500;
my $MAX_PHOTO_BYTES = 8 * 1024 * 1024;
my $MAX_SHOWCASE_BYTES = 12 * 1024 * 1024;
my $PROFILE_TOKEN_TTL = 30 * 24 * 60 * 60;
my $SUBMISSION_COOLDOWN = 30 * 24 * 60 * 60;

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub submit {
    my ($self, %args) = @_;
    die "request rejected" if _trim($args{website}) ne '';

    my $name = _clean_text($args{name}, $MAX_NAME);
    my ($first, $last, $last_initial) = _name_parts($name);
    my $email = _clean_email($args{email});
    my $phone = _clean_text($args{phone}, $MAX_PHONE);
    my $age_raw = defined $args{age} ? $args{age} : '';
    my $age = $age_raw =~ /\A\s*(\d{1,3})\s*\z/ ? int($1) : 0;
    my $application_text = _clean_limited_text(
        defined $args{application_text} ? $args{application_text} : $args{bio},
        'response'
    );
    my @application_showcase = grep { $_ } @{$args{application_showcase_uploads} || $args{showcase_uploads} || []};

    die "Please enter your full name with first and last name." unless length $name && length $first && length $last_initial;
    die "Please enter a valid email address." unless length $email;
    die "Please enter your phone number." unless length $phone;
    die "Please enter an age between 13 and 120." unless $age >= 13 && $age <= 120;
    $self->_enforce_email_cooldown($email);

    my $request = $args{request};
    my $ip = DesertCMS::HTTP::client_ip($request, $self->{config});
    my $ip_hash = length $ip ? $self->_hash('ip', $ip) : '';
    my $ua = $request ? ($request->{user_agent} || '') : '';
    my $ua_hash = length $ua ? $self->_hash('ua', substr($ua, 0, 300)) : '';
    $self->_rate_limit($ip_hash) if length $ip_hash;

    my $ts = now();
    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    my $id;
    eval {
        $dbh->do(
            q{
                INSERT INTO contributor_requests
                    (name, first_name, last_name, last_initial, email, phone, age, application_text,
                     status, ip_hash, user_agent_hash, submitted_at, updated_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, 'new', ?, ?, ?, ?)
            },
            undef,
            $name,
            $first,
            $last,
            $last_initial,
            $email,
            $phone,
            $age,
            $application_text,
            $ip_hash,
            $ua_hash,
            $ts,
            $ts
        );
        $id = int($dbh->sqlite_last_insert_rowid);
        my @stored_showcase;
        my $i = 0;
        for my $upload (@application_showcase) {
            $i++;
            my ($path, $mime) = $self->_store_upload($id, "application-showcase-$i", $upload, $MAX_SHOWCASE_BYTES);
            push @stored_showcase, {
                path => $path,
                mime_type => $mime,
                filename => basename($upload->{filename} || "showcase-$i"),
            };
        }
        $dbh->do(
            q{
                UPDATE contributor_requests
                SET application_showcase_json = ?,
                    updated_at = ?
                WHERE id = ?
            },
            undef,
            encode_json(\@stored_showcase),
            $ts,
            $id
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown contributor request failure';
        eval { $dbh->rollback };
        die $err;
    };

    my $row = $self->request_by_id($id);
    my ($notified, $notify_reason) = $self->send_request_notification($row);
    return {
        ok                  => 1,
        id                  => $id,
        notification_sent   => $notified ? 1 : 0,
        notification_reason => $notify_reason || '',
    };
}

sub list_requests {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 100);
    $limit = 100 if $limit < 1 || $limit > 250;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT r.*,
                   (
                       SELECT s.status
                       FROM contributor_sites s
                       WHERE (s.site_id <> '' AND s.site_id = r.site_id)
                          OR (s.domain <> '' AND s.domain = r.domain)
                       ORDER BY s.updated_at DESC, s.id DESC
                       LIMIT 1
                   ) AS contributor_site_status,
                   (
                       SELECT a.archive_filename
                       FROM archived_sites a
                       WHERE lower(a.owner_email) = lower(r.email)
                         AND a.archived_at >= COALESCE(r.approved_at, r.submitted_at)
                       ORDER BY a.archived_at DESC, a.id DESC
                       LIMIT 1
                   ) AS archived_site_filename,
                   (
                       SELECT a.archived_at
                       FROM archived_sites a
                       WHERE lower(a.owner_email) = lower(r.email)
                         AND a.archived_at >= COALESCE(r.approved_at, r.submitted_at)
                       ORDER BY a.archived_at DESC, a.id DESC
                       LIMIT 1
                   ) AS archived_site_at
            FROM contributor_requests r
            ORDER BY CASE status WHEN 'new' THEN 0 WHEN 'reviewing' THEN 1 WHEN 'approved' THEN 2 ELSE 3 END,
                     submitted_at DESC,
                     id DESC
            LIMIT ?
        },
        { Slice => {} },
        $limit
    );
}

sub request_by_id {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT r.*,
                   (
                       SELECT s.status
                       FROM contributor_sites s
                       WHERE (s.site_id <> '' AND s.site_id = r.site_id)
                          OR (s.domain <> '' AND s.domain = r.domain)
                       ORDER BY s.updated_at DESC, s.id DESC
                       LIMIT 1
                   ) AS contributor_site_status,
                   (
                       SELECT a.archive_filename
                       FROM archived_sites a
                       WHERE lower(a.owner_email) = lower(r.email)
                         AND a.archived_at >= COALESCE(r.approved_at, r.submitted_at)
                       ORDER BY a.archived_at DESC, a.id DESC
                       LIMIT 1
                   ) AS archived_site_filename,
                   (
                       SELECT a.archived_at
                       FROM archived_sites a
                       WHERE lower(a.owner_email) = lower(r.email)
                         AND a.archived_at >= COALESCE(r.approved_at, r.submitted_at)
                       ORDER BY a.archived_at DESC, a.id DESC
                       LIMIT 1
                   ) AS archived_site_at
            FROM contributor_requests r
            WHERE r.id = ?
        },
        undef,
        $id
    );
}

sub mark_reviewing {
    my ($self, $id) = @_;
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            UPDATE contributor_requests
            SET status = 'reviewing',
                reviewed_at = COALESCE(reviewed_at, ?),
                updated_at = ?
            WHERE id = ?
              AND status = 'new'
        },
        undef,
        $ts,
        $ts,
        int($id || 0)
    );
}

sub deny {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $note = _clean_note($args{note});
    my $row = $self->request_by_id($id) or die "request not found";
    die "request has already been approved" if ($row->{status} || '') eq 'approved';
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            UPDATE contributor_requests
            SET status = 'denied',
                review_note = ?,
                reviewed_at = COALESCE(reviewed_at, ?),
                denied_at = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        $note,
        $ts,
        $ts,
        $ts,
        $id
    );
    $row = $self->request_by_id($id);
    my ($sent, $reason) = $self->send_denial_email($row);
    $row->{denial_email_sent} = $sent ? 1 : 0;
    $row->{denial_email_reason} = $reason || '';
    return $row;
}

sub approve {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $sites = $args{sites} or die "sites service is required";
    my $note = _clean_note($args{note});
    my $row = $self->request_by_id($id) or die "request not found";
    die "request has already been denied" if ($row->{status} || '') eq 'denied';
    die "request has already been approved" if ($row->{status} || '') eq 'approved';

    my $site = $sites->create_from_request(
        request_id => $id,
        name       => $row->{name},
        first_name => $row->{first_name},
        last_name  => $row->{last_name},
        last_initial => $row->{last_initial},
        email      => $row->{email},
        bio        => $row->{bio},
        blueprint_id => $args{blueprint_id},
    );
    my $token = random_hex(32);
    my $token_hash = $self->_hash('profile-token', $token);
    my $expires_at = now() + $PROFILE_TOKEN_TTL;
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            UPDATE contributor_requests
            SET status = 'approved',
                site_id = ?,
                domain = ?,
                blueprint_id = ?,
                profile_token_hash = ?,
                profile_token_expires_at = ?,
                review_note = ?,
                reviewed_at = COALESCE(reviewed_at, ?),
                approved_at = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        $site->{site_id},
        $site->{domain},
        $site->{blueprint_id},
        $token_hash,
        $expires_at,
        $note,
        $ts,
        $ts,
        $ts,
        $id
    );
    $row = $self->request_by_id($id);
    my ($sent, $reason) = $self->send_approval_email($row, profile_token => $token);
    $row->{approval_email_sent} = $sent ? 1 : 0;
    $row->{approval_email_reason} = $reason || '';
    $row->{profile_token} = $token;
    return $row;
}

sub approved_profiles {
    my ($self) = @_;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT r.*
            FROM contributor_requests r
            JOIN contributor_sites s
              ON s.site_id = r.site_id
             AND s.domain = r.domain
             AND s.status IN ('pending_provision', 'active')
            WHERE r.status = 'approved'
              AND r.domain <> ''
              AND (
                    r.profile_completed_at IS NOT NULL
                 OR (r.bio <> '' AND r.public_profile_image_path <> '')
              )
            ORDER BY r.approved_at DESC, r.id DESC
        },
        { Slice => {} }
    );
}

sub profile_by_token {
    my ($self, $token) = @_;
    $token = _clean_token($token);
    return undef unless length $token;
    my $hash = $self->_hash('profile-token', $token);
    my $row = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM contributor_requests
            WHERE profile_token_hash = ?
              AND status = 'approved'
            LIMIT 1
        },
        undef,
        $hash
    );
    return undef unless $row;
    return undef if $row->{profile_token_expires_at} && $row->{profile_token_expires_at} < now();
    return $row;
}

sub complete_profile {
    my ($self, %args) = @_;
    my $token = _clean_token($args{token});
    my $row = $self->profile_by_token($token) or die "This profile link is invalid or expired. Ask the site administrator for a new link.";
    my $id = int($row->{id});
    my $bio = _clean_limited_text($args{bio}, 'bio');
    my $photo = $args{photo};
    my @showcase = grep { $_ } @{$args{showcase_uploads} || []};

    die "Please upload a portrait image before saving your profile." unless $photo || ($row->{profile_photo_path} || '') =~ /\S/;
    die "Please upload at least one profile sample image." unless @showcase || @{showcase_files($row)};

    my $photo_path = $row->{profile_photo_path} || '';
    my $photo_mime = $row->{profile_photo_mime} || '';
    my @stored_showcase;
    if (@showcase) {
        my $i = 0;
        for my $upload (@showcase) {
            $i++;
            my ($path, $mime) = $self->_store_upload($id, "profile-showcase-$i", $upload, $MAX_SHOWCASE_BYTES);
            push @stored_showcase, {
                path => $path,
                mime_type => $mime,
                filename => basename($upload->{filename} || "profile-showcase-$i"),
            };
        }
    } else {
        @stored_showcase = @{showcase_files($row)};
    }

    if ($photo) {
        ($photo_path, $photo_mime) = $self->_store_upload($id, 'profile', $photo, $MAX_PHOTO_BYTES);
    }

    my $ts = now();
    my $dbh = $self->{db}->dbh;
    $dbh->do(
        q{
            UPDATE contributor_requests
            SET bio = ?,
                profile_photo_path = ?,
                profile_photo_mime = ?,
                showcase_json = ?,
                profile_completed_at = COALESCE(profile_completed_at, ?),
                updated_at = ?
            WHERE id = ?
        },
        undef,
        $bio,
        $photo_path,
        $photo_mime,
        encode_json(\@stored_showcase),
        $ts,
        $ts,
        $id
    );

    $row = $self->request_by_id($id);
    my $public_image = $self->publish_profile_image($row, $row->{site_id});
    $self->{db}->dbh->do(
        q{
            UPDATE contributor_requests
            SET public_profile_image_path = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        $public_image,
        now(),
        $id
    );
    return $self->request_by_id($id);
}

sub publish_profile_image {
    my ($self, $row, $site_id) = @_;
    return '' unless $row && ($row->{profile_photo_path} || '') =~ /\S/;
    my $source = $row->{profile_photo_path};
    return '' unless -f $source;
    $site_id = _clean_site_id($site_id || $row->{site_id} || 'contributor');
    my $dir = File::Spec->catdir($self->{config}->get('public_root'), 'assets', 'contributors');
    make_path($dir) unless -d $dir;
    my $dest = File::Spec->catfile($dir, "$site_id.jpg");
    my $media = DesertCMS::Media->new(config => $self->{config}, db => $self->{db});
    $media->create_public_derivative(
        source    => $source,
        dest      => $dest,
        max_width => 960,
    );
    return "/assets/contributors/$site_id.jpg";
}

sub send_request_notification {
    my ($self, $row) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $to = _clean_email($settings->{contributor_request_recipient_email} || '');
    my $site_url = $self->{config}->get('site_url') || '';
    $site_url =~ s{/+\z}{};
    my $review_url = $site_url . '/admin/settings/contributors/requests/' . int($row->{id});
    my $subject = 'New contributor request from ' . ($row->{name} || $row->{email});
    my $application_text = $row->{application_text} || $row->{bio} || '';
    my $text = join "\n\n",
        "A new contributor request was submitted.",
        "Name: $row->{name}",
        "Email: $row->{email}",
        "Phone: $row->{phone}",
        "Age: $row->{age}",
        "Why they want to join:",
        $application_text,
        "Review:",
        $review_url;
    my $html = '<p>A new contributor request was submitted.</p>'
        . '<ul><li><strong>Name:</strong> ' . escape_html($row->{name}) . '</li>'
        . '<li><strong>Email:</strong> ' . escape_html($row->{email}) . '</li>'
        . '<li><strong>Phone:</strong> ' . escape_html($row->{phone}) . '</li>'
        . '<li><strong>Age:</strong> ' . escape_html($row->{age}) . '</li></ul>'
        . '<p>' . escape_html($application_text) . '</p>'
        . '<p><a href="' . escape_html($review_url) . '">Review request</a></p>';
    return send_postmark(
        $self->{config},
        $self->{db},
        to         => $to,
        email_type => 'contributor_request_notification',
        subject    => $subject,
        text_body  => $text,
        html_body  => $html,
    );
}

sub send_denial_email {
    my ($self, $row) = @_;
    return unless $row && _valid_email($row->{email});
    my $site_name = _site_name($self);
    my $subject = "Your $site_name contributor request";
    my $text = join "\n\n",
        "Thank you for your interest in becoming a contributor to $site_name.",
        "We are sorry, but you were not selected at this time.";
    my $html = '<p>Thank you for your interest in becoming a contributor to '
        . escape_html($site_name)
        . '.</p><p>We are sorry, but you were not selected at this time.</p>';
    return send_postmark(
        $self->{config},
        $self->{db},
        to         => $row->{email},
        email_type => 'contributor_request_denied',
        subject    => $subject,
        text_body  => $text,
        html_body  => $html
    );
}

sub send_approval_email {
    my ($self, $row, %args) = @_;
    return unless $row && _valid_email($row->{email});
    my $domain = $row->{domain} || '';
    my $site_name = _site_name($self);
    my $profile_url = $args{profile_url} || '';
    if (!length $profile_url && $args{profile_token}) {
        my $site_url = $self->{config}->get('site_url') || '';
        $site_url =~ s{/+\z}{};
        $profile_url = $site_url . '/contributors/profile/' . _clean_token($args{profile_token}) if length $site_url;
    }
    my $subject = "Your $site_name contributor request was approved";
    my $text = join "\n\n",
        "Congratulations. Your contributor request was approved.",
        length $profile_url ? ("Complete your public contributor profile here:", $profile_url) : (),
        length $domain ? "Your contributor site is being created at https://$domain/." : (),
        "You will receive your temporary admin setup email as soon as provisioning is complete.";
    my $html = '<p>Congratulations. Your contributor request was approved.</p>'
        . (length $profile_url ? '<p><a href="' . escape_html($profile_url) . '">Complete your public contributor profile</a></p>' : '')
        . (length $domain ? '<p>Your contributor site is being created at <a href="https://' . escape_html($domain) . '/">https://' . escape_html($domain) . '/</a>.</p>' : '')
        . '<p>You will receive your temporary admin setup email as soon as provisioning is complete.</p>';
    return send_postmark(
        $self->{config},
        $self->{db},
        to         => $row->{email},
        email_type => 'contributor_request_approved',
        subject    => $subject,
        text_body  => $text,
        html_body  => $html
    );
}

sub showcase_files {
    my ($row) = @_;
    return [] unless $row;
    return eval { decode_json($row->{showcase_json} || '[]') } || [];
}

sub application_showcase_files {
    my ($row) = @_;
    return [] unless $row;
    my $files = eval { decode_json($row->{application_showcase_json} || '[]') } || [];
    return $files if @{$files};
    return showcase_files($row) unless $row->{profile_completed_at};
    return [];
}

sub _store_upload {
    my ($self, $id, $name, $upload, $max_bytes) = @_;
    my $label = _upload_label($name);
    die "$label is required." unless $upload && defined $upload->{content} && length $upload->{content};
    die "$label is too large. Upload images up to " . _bytes_label($max_bytes) . "." if length($upload->{content}) > $max_bytes;
    my $mime = lc($upload->{content_type} || 'application/octet-stream');
    die "$label must be a JPEG, PNG, or WebP image." unless $mime =~ /\Aimage\/(?:jpeg|png|webp)\z/;
    my $ext = _extension_for_mime($mime) || 'jpg';
    my $dir = File::Spec->catdir($self->{config}->get('data_dir'), 'contributor-requests', int($id));
    make_path($dir) unless -d $dir;
    my $path = File::Spec->catfile($dir, "$name.$ext");
    open my $fh, '>:raw', $path or die "cannot write contributor request upload: $!";
    print {$fh} $upload->{content};
    close $fh;
    chmod 0600, $path;
    return ($path, $mime);
}

sub _rate_limit {
    my ($self, $ip_hash) = @_;
    my $since = now() - (15 * 60);
    my ($count) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM contributor_requests
            WHERE ip_hash = ?
              AND submitted_at >= ?
        },
        undef,
        $ip_hash,
        $since
    );
    die "Too many requests were submitted recently. Please wait a few minutes and try again." if ($count || 0) >= 3;
}

sub _enforce_email_cooldown {
    my ($self, $email) = @_;
    return unless length($email || '');
    my $since = now() - $SUBMISSION_COOLDOWN;
    my $row = $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT id, submitted_at
            FROM contributor_requests
            WHERE email = ? COLLATE NOCASE
              AND submitted_at >= ?
            ORDER BY submitted_at DESC, id DESC
            LIMIT 1
        },
        undef,
        $email,
        $since
    );
    return unless $row;
    my $remaining = $SUBMISSION_COOLDOWN - (now() - int($row->{submitted_at} || 0));
    $remaining = 0 if $remaining < 0;
    my $days = int(($remaining + 86399) / 86400) || 1;
    die "A contributor request from this email was already submitted recently. Please wait $days day" . ($days == 1 ? '' : 's') . " before trying again.";
}

sub _hash {
    my ($self, $kind, $value) = @_;
    $value = '' unless defined $value;
    return hmac_sha256_hex('contributor-request:' . $kind . ':' . $value, $self->{config}->app_secret);
}

sub _name_parts {
    my ($name) = @_;
    $name = _clean_text($name, $MAX_NAME);
    my @parts = grep { length } split /\s+/, $name;
    my $first = $parts[0] || '';
    my $last = @parts > 1 ? $parts[-1] : '';
    my $initial = length $last ? uc substr($last, 0, 1) : '';
    return ($first, $last, $initial);
}

sub _clean_text {
    my ($value, $max) = @_;
    $value = _trim($value);
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/\s+/ /g;
    return substr($value, 0, $max);
}

sub _clean_limited_text {
    my ($value, $label) = @_;
    $label ||= 'text';
    $value = _trim($value);
    $value =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
    $value =~ s/\s+/ /g;
    if (length($value) < $MIN_BIO || length($value) > $MAX_BIO) {
        die "Please write 150 to 500 characters about why you want to join." if $label eq 'response';
        die "Please write a 150 to 500 character public bio." if $label eq 'bio';
        die "Please write 150 to 500 characters.";
    }
    return $value;
}

sub _clean_note {
    my ($value) = @_;
    $value = _trim($value);
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/\s+/ /g;
    return substr($value, 0, 1000);
}

sub _clean_email {
    my ($value) = @_;
    $value = lc(_clean_text($value, $MAX_EMAIL));
    return '' unless length $value;
    die "Please enter a valid email address." unless _valid_email($value);
    return $value;
}

sub _upload_label {
    my ($name) = @_;
    return 'Portrait image' if ($name || '') eq 'profile';
    return 'Profile sample image' if ($name || '') =~ /\Aprofile-showcase-/;
    return 'Sample image' if ($name || '') =~ /\Aapplication-showcase-/;
    return 'Image upload';
}

sub _bytes_label {
    my ($bytes) = @_;
    my $mb = int(($bytes || 0) / (1024 * 1024));
    return $mb ? "$mb MB" : "$bytes bytes";
}

sub _valid_email {
    my ($value) = @_;
    return ($value || '') =~ /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z/ ? 1 : 0;
}

sub _extension_for_mime {
    my ($mime) = @_;
    $mime = lc($mime || '');
    return 'jpg' if $mime eq 'image/jpeg';
    return 'png' if $mime eq 'image/png';
    return 'webp' if $mime eq 'image/webp';
    return '';
}

sub _clean_site_id {
    my ($site_id) = @_;
    $site_id = lc($site_id || '');
    $site_id =~ s/[^a-z0-9-]//g;
    $site_id =~ s/^-+|-+$//g;
    return $site_id || 'contributor';
}

sub _clean_token {
    my ($token) = @_;
    $token = lc(_trim($token));
    return $token =~ /\A[0-9a-f]{64}\z/ ? $token : '';
}

sub _site_name {
    my ($self) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    return $settings->{site_name} || $self->{config}->get('site_name') || 'DesertCMS';
}

sub _trim {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return $value;
}

1;
