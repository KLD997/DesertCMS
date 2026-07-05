package DesertCMS::Forms;

use strict;
use warnings;
use File::Basename qw(basename);
use File::Path qw(make_path remove_tree);
use File::Spec;
use JSON::PP qw(decode_json encode_json);
use DesertCMS::Email qw(send_postmark);
use DesertCMS::HTTP ();
use DesertCMS::Settings;
use DesertCMS::Util qw(escape_html hmac_sha256_hex now random_hex);

my $MAX_NAME = 100;
my $MAX_EMAIL = 180;
my $MAX_PHONE = 60;
my $MAX_ORG = 160;
my $MAX_SUBJECT = 160;
my $MAX_MESSAGE = 5000;
my $MAX_BUDGET = 80;
my $MAX_DATE = 40;
my $DEFAULT_UPLOAD_MB = 10;
my $MAX_ATTACHMENTS = 3;

my @FORM_TYPES = (
    {
        key         => 'contact',
        label       => 'Contact',
        noun        => 'message',
        description => 'General questions, follow-ups, and direct messages.',
    },
    {
        key         => 'quote',
        label       => 'Quote Request',
        noun        => 'quote request',
        description => 'Project scope, budget, timing, and reference files.',
    },
    {
        key         => 'application',
        label       => 'Application',
        noun        => 'application',
        description => 'Applications, submissions, and eligibility details.',
    },
    {
        key         => 'intake',
        label       => 'Intake Form',
        noun        => 'intake form',
        description => 'Client, project, support, or service intake details.',
    },
    {
        key         => 'rsvp',
        label       => 'RSVP',
        noun        => 'RSVP',
        description => 'Event attendance, guest count, and notes.',
    },
);
my %FORM_TYPE = map { $_->{key} => $_ } @FORM_TYPES;
my @DEFAULT_TYPES = map { $_->{key} } @FORM_TYPES;

my %ALLOWED_EXT = map { $_ => 1 } qw(
    jpg jpeg png webp gif pdf txt md markdown csv tsv json doc docx xls xlsx ppt pptx
);
my %ALLOWED_MIME = map { $_ => 1 } (
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'application/pdf',
    'application/json',
    'text/plain',
    'text/markdown',
    'text/csv',
    'text/tab-separated-values',
    'application/msword',
    'application/vnd.ms-excel',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
);
my %EXT_MIME = (
    jpg      => 'image/jpeg',
    jpeg     => 'image/jpeg',
    png      => 'image/png',
    webp     => 'image/webp',
    gif      => 'image/gif',
    pdf      => 'application/pdf',
    txt      => 'text/plain',
    md       => 'text/markdown',
    markdown => 'text/markdown',
    csv      => 'text/csv',
    tsv      => 'text/tab-separated-values',
    json     => 'application/json',
    doc      => 'application/msword',
    docx     => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    xls      => 'application/vnd.ms-excel',
    xlsx     => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    ppt      => 'application/vnd.ms-powerpoint',
    pptx     => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
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

sub form_types {
    return [ map { { %{$_} } } @FORM_TYPES ];
}

sub form_type_label {
    my ($key) = @_;
    $key = _clean_form_key($key);
    return $FORM_TYPE{$key}{label} || 'Contact';
}

sub enabled_form_types {
    my ($settings) = @_;
    $settings ||= {};
    my $raw = $settings->{forms_enabled_types};
    my @keys = grep { exists $FORM_TYPE{$_} } map { _clean_form_key($_) } split /[\s,]+/, ($raw || '');
    @keys = @DEFAULT_TYPES unless @keys;
    my %seen;
    return [ grep { !$seen{$_}++ } @keys ];
}

sub submit {
    my ($self, %args) = @_;
    die "form rejected" if _trim($args{website}) ne '';

    my $settings = $args{settings} || DesertCMS::Settings::all($self->{config}, $self->{db});
    my %enabled = map { $_ => 1 } @{ enabled_form_types($settings) };
    my $form_key = _clean_form_key($args{form_key} || $args{form_type} || 'contact');
    die "That form type is not available right now." unless $enabled{$form_key};

    my $name = _clean_text($args{name}, $MAX_NAME);
    my $email = _clean_email($args{email});
    my $phone = _clean_text($args{phone}, $MAX_PHONE);
    my $organization = _clean_text($args{organization}, $MAX_ORG);
    my $subject = _clean_text($args{subject}, $MAX_SUBJECT);
    my $message = _clean_message($args{message});
    my $preferred_date = _clean_date($args{preferred_date});
    my $event_date = _clean_date($args{event_date});
    my $budget = _clean_text($args{budget}, $MAX_BUDGET);
    my $guest_count = _clean_count($args{guest_count});
    my @attachments = grep { $_ } @{ $args{attachments} || [] };

    die "Please enter your name." unless length $name;
    die "Please enter a valid email address." unless length $email;
    die "Please enter a message before sending." unless length $message;

    my $ip = DesertCMS::HTTP::client_ip($args{request}, $self->{config});
    my $ip_hash = length $ip ? $self->_hash('ip', $ip) : '';
    my $ua = $args{request} ? ($args{request}->{user_agent} || '') : '';
    my $ua_hash = length $ua ? $self->_hash('ua', substr($ua, 0, 300)) : '';
    $self->_rate_limit($ip_hash) if length $ip_hash;

    my $uploads_enabled = _truthy($settings->{forms_uploads_enabled});
    my $max_bytes = _upload_limit_bytes($settings);
    die "File uploads are not enabled for this form." if @attachments && !$uploads_enabled;
    die "Upload up to $MAX_ATTACHMENTS files." if @attachments > $MAX_ATTACHMENTS;

    my $ts = now();
    my $dbh = $self->{db}->dbh;
    my ($id, @stored_files);
    my $storage_dir;
    $dbh->begin_work;
    eval {
        $dbh->do(
            q{
                INSERT INTO form_submissions
                    (form_key, name, email, phone, organization, subject, message,
                     preferred_date, event_date, guest_count, budget, attachment_json,
                     status, ip_hash, user_agent_hash, notification_status, notification_error,
                     created_at, updated_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '[]', 'new', ?, ?, 'pending', '', ?, ?)
            },
            undef,
            $form_key,
            $name,
            $email,
            $phone,
            $organization,
            $subject,
            $message,
            $preferred_date,
            $event_date,
            $guest_count,
            $budget,
            $ip_hash,
            $ua_hash,
            $ts,
            $ts
        );
        $id = int($dbh->sqlite_last_insert_rowid);
        $storage_dir = $self->_submission_dir($id);
        my $i = 0;
        for my $upload (@attachments) {
            $i++;
            push @stored_files, $self->_store_upload($id, "attachment_$i", $upload, $max_bytes);
        }
        $dbh->do(
            q{
                UPDATE form_submissions
                SET attachment_json = ?,
                    updated_at = ?
                WHERE id = ?
            },
            undef,
            encode_json(\@stored_files),
            $ts,
            $id
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown forms submission failure';
        eval { $dbh->rollback };
        eval { remove_tree($storage_dir) if $storage_dir && -d $storage_dir };
        die $err;
    };

    my $row = $self->submission_by_id($id);
    my ($notified, $notify_reason) = $self->send_submission_notification($row, $settings);
    return {
        ok                  => 1,
        id                  => $id,
        form_key            => $form_key,
        upload_count        => scalar @stored_files,
        notification_sent   => $notified ? 1 : 0,
        notification_reason => $notify_reason || '',
    };
}

sub submission_by_id {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM form_submissions
            WHERE id = ?
        },
        undef,
        $id
    );
}

sub recent_submissions {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 50);
    $limit = 50 if $limit < 1 || $limit > 200;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM form_submissions
            ORDER BY created_at DESC, id DESC
            LIMIT ?
        },
        { Slice => {} },
        $limit
    );
}

sub counts {
    my ($self) = @_;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT status, COUNT(*) AS count
            FROM form_submissions
            GROUP BY status
        },
        { Slice => {} }
    );
    my %counts = (
        new      => 0,
        read     => 0,
        archived => 0,
        total    => 0,
    );
    for my $row (@{$rows}) {
        my $count = int($row->{count} || 0);
        $counts{total} += $count;
        $counts{$row->{status} || ''} = $count if exists $counts{$row->{status} || ''};
    }
    $counts{by_type} = $self->type_counts;
    return \%counts;
}

sub type_counts {
    my ($self) = @_;
    my %counts = map { $_->{key} => 0 } @FORM_TYPES;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT form_key, COUNT(*) AS count
            FROM form_submissions
            GROUP BY form_key
        },
        { Slice => {} }
    );
    for my $row (@{$rows}) {
        my $key = _clean_form_key($row->{form_key});
        $counts{$key} = int($row->{count} || 0) if exists $counts{$key};
    }
    return \%counts;
}

sub submission_files {
    my ($row) = @_;
    return [] unless $row;
    my $files = eval { decode_json($row->{attachment_json} || '[]') } || [];
    return ref $files eq 'ARRAY' ? $files : [];
}

sub submission_upload {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $index = int($args{index} || 0);
    return undef unless $id > 0 && $index >= 0;
    my $row = $self->submission_by_id($id) or return undef;
    my $files = submission_files($row);
    my $file = $files->[$index] or return undef;
    my $path = $file->{path} || '';
    return undef unless length $path && -f $path;
    return undef unless _is_under($path, $self->_submissions_root);
    return {
        path     => $path,
        filename => _download_filename($file->{filename} || 'form-upload'),
        mime     => $file->{mime_type} || 'application/octet-stream',
        bytes    => int($file->{bytes} || 0),
        row      => $row,
    };
}

sub send_submission_notification {
    my ($self, $row, $settings) = @_;
    return (0, 'submission not found') unless $row;
    $settings ||= DesertCMS::Settings::all($self->{config}, $self->{db});
    my $id = int($row->{id} || 0);
    my $ts = now();

    if (!_truthy($settings->{forms_notify_postmark_enabled})) {
        $self->_record_notification($id, 'skipped', 'Postmark notifications are disabled for forms', undef);
        return (0, 'Postmark notifications are disabled for forms');
    }

    my $to = _clean_email($settings->{forms_notification_email} || $settings->{contributor_request_recipient_email} || '');
    if (!length $to) {
        $self->_record_notification($id, 'skipped', 'Form notification recipient is not configured', undef);
        return (0, 'Form notification recipient is not configured');
    }

    my $type_label = form_type_label($row->{form_key});
    my $site_name = $settings->{site_name} || $self->{config}->get('site_name') || 'DesertCMS';
    my $subject = "New $type_label submission";
    $subject .= ': ' . $row->{subject} if length($row->{subject} || '');
    my $site_url = $self->{config}->get('site_url') || '';
    $site_url =~ s{/+\z}{};
    my $review_url = length $site_url ? "$site_url/admin/settings/modules/forms" : '/admin/settings/modules/forms';
    my $files = submission_files($row);
    my @file_lines = @{$files}
        ? map { '- ' . ($_->{filename} || 'upload') . ' (' . _bytes_label($_->{bytes} || 0) . ')' } @{$files}
        : ('- None');

    my @detail_lines = (
        "A new $type_label submission was received on $site_name.",
        '',
        "Name: " . ($row->{name} || ''),
        "Email: " . ($row->{email} || ''),
    );
    push @detail_lines, "Phone: $row->{phone}" if length($row->{phone} || '');
    push @detail_lines, "Organization: $row->{organization}" if length($row->{organization} || '');
    push @detail_lines, "Subject: $row->{subject}" if length($row->{subject} || '');
    push @detail_lines, "Preferred date: $row->{preferred_date}" if length($row->{preferred_date} || '');
    push @detail_lines, "Event date: $row->{event_date}" if length($row->{event_date} || '');
    push @detail_lines, "Guest count: $row->{guest_count}" if defined $row->{guest_count} && $row->{guest_count} ne '';
    push @detail_lines, "Budget: $row->{budget}" if length($row->{budget} || '');
    push @detail_lines, '', 'Message:', ($row->{message} || ''), '', 'Uploaded files:', @file_lines, '', 'Review:', $review_url;
    my $text = join "\n", @detail_lines;

    my $html = '<p>A new ' . escape_html($type_label) . ' submission was received on ' . escape_html($site_name) . '.</p>'
        . '<ul>'
        . '<li><strong>Name:</strong> ' . escape_html($row->{name} || '') . '</li>'
        . '<li><strong>Email:</strong> ' . escape_html($row->{email} || '') . '</li>'
        . (length($row->{phone} || '') ? '<li><strong>Phone:</strong> ' . escape_html($row->{phone}) . '</li>' : '')
        . (length($row->{organization} || '') ? '<li><strong>Organization:</strong> ' . escape_html($row->{organization}) . '</li>' : '')
        . (length($row->{subject} || '') ? '<li><strong>Subject:</strong> ' . escape_html($row->{subject}) . '</li>' : '')
        . (length($row->{preferred_date} || '') ? '<li><strong>Preferred date:</strong> ' . escape_html($row->{preferred_date}) . '</li>' : '')
        . (length($row->{event_date} || '') ? '<li><strong>Event date:</strong> ' . escape_html($row->{event_date}) . '</li>' : '')
        . ((defined $row->{guest_count} && $row->{guest_count} ne '') ? '<li><strong>Guest count:</strong> ' . escape_html($row->{guest_count}) . '</li>' : '')
        . (length($row->{budget} || '') ? '<li><strong>Budget:</strong> ' . escape_html($row->{budget}) . '</li>' : '')
        . '</ul>'
        . '<p><strong>Message</strong></p><p>' . _html_multiline($row->{message} || '') . '</p>'
        . '<p><strong>Uploaded files</strong></p><ul>'
        . join('', map { '<li>' . escape_html($_->{filename} || 'upload') . ' (' . escape_html(_bytes_label($_->{bytes} || 0)) . ')</li>' } @{$files})
        . (@{$files} ? '' : '<li>None</li>')
        . '</ul>'
        . '<p><a href="' . escape_html($review_url) . '">Review the submission in DesertCMS</a></p>';

    my ($sent, $reason) = send_postmark(
        $self->{config},
        $self->{db},
        to         => $to,
        email_type => 'form_submission',
        subject    => substr($subject, 0, 300),
        text_body  => $text,
        html_body  => $html,
    );
    my $status = $sent ? 'sent' : (($reason || '') =~ /not configured/i ? 'skipped' : 'failed');
    $self->_record_notification($id, $status, $reason || '', $sent ? $ts : undef);
    return ($sent ? 1 : 0, $reason || '');
}

sub _record_notification {
    my ($self, $id, $status, $reason, $sent_at) = @_;
    $self->{db}->dbh->do(
        q{
            UPDATE form_submissions
            SET notification_status = ?,
                notification_error = ?,
                notification_sent_at = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        substr($status || '', 0, 40),
        substr($reason || '', 0, 1000),
        $sent_at,
        now(),
        int($id || 0)
    );
}

sub _store_upload {
    my ($self, $id, $field, $upload, $max_bytes) = @_;
    die "Upload is missing." unless $upload && defined $upload->{content} && length $upload->{content};
    my $bytes = length($upload->{content});
    die "Uploaded file is too large. Upload files up to " . _bytes_label($max_bytes) . "." if $bytes > $max_bytes;

    my $original = _download_filename(basename($upload->{filename} || 'upload'));
    my ($ext) = $original =~ /\.([A-Za-z0-9]+)\z/;
    $ext = lc($ext || '');
    my $mime = lc($upload->{content_type} || '');
    $mime = $EXT_MIME{$ext} || 'application/octet-stream' unless length $mime;
    die "Uploaded file type is not supported. Use images, PDFs, text, CSV, or Office documents."
        if length($ext) && !$ALLOWED_EXT{$ext};
    die "Uploaded file type is not supported. Use images, PDFs, text, CSV, or Office documents."
        if length($mime) && $mime ne 'application/octet-stream' && !$ALLOWED_MIME{$mime};
    if (!$ext) {
        $ext = _ext_for_mime($mime);
        die "Uploaded file type is not supported. Use images, PDFs, text, CSV, or Office documents." unless length $ext;
        $original .= ".$ext";
    }

    my $dir = $self->_submission_dir($id);
    make_path($dir) unless -d $dir;
    my $stored_name = random_hex(12) . '-' . $original;
    my $path = File::Spec->catfile($dir, $stored_name);
    open my $fh, '>:raw', $path or die "cannot write form upload: $!";
    print {$fh} $upload->{content};
    close $fh;
    chmod 0600, $path;
    return {
        field     => $field,
        path      => $path,
        filename  => $original,
        mime_type => $mime || 'application/octet-stream',
        bytes     => $bytes,
    };
}

sub _submission_dir {
    my ($self, $id) = @_;
    return File::Spec->catdir($self->_submissions_root, int($id || 0));
}

sub _submissions_root {
    my ($self) = @_;
    return File::Spec->catdir($self->{config}->get('data_dir'), 'form-submissions');
}

sub _rate_limit {
    my ($self, $ip_hash) = @_;
    my $since = now() - (10 * 60);
    my ($count) = $self->{db}->dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM form_submissions
            WHERE ip_hash = ?
              AND created_at >= ?
        },
        undef,
        $ip_hash,
        $since
    );
    die "Too many messages were submitted recently. Please wait a few minutes and try again." if ($count || 0) >= 5;
}

sub _hash {
    my ($self, $kind, $value) = @_;
    $value = '' unless defined $value;
    return hmac_sha256_hex('forms:' . $kind . ':' . $value, $self->{config}->app_secret);
}

sub _upload_limit_bytes {
    my ($settings) = @_;
    my $mb = int($settings->{forms_max_upload_mb} || $DEFAULT_UPLOAD_MB);
    $mb = $DEFAULT_UPLOAD_MB if $mb < 1;
    $mb = 64 if $mb > 64;
    return $mb * 1024 * 1024;
}

sub _clean_form_key {
    my ($value) = @_;
    $value = lc($value || 'contact');
    $value =~ s/[^a-z0-9_-]+//g;
    return exists $FORM_TYPE{$value} ? $value : 'contact';
}

sub _clean_text {
    my ($value, $max) = @_;
    $value = _trim($value);
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/\s+/ /g;
    return substr($value, 0, $max);
}

sub _clean_email {
    my ($value) = @_;
    $value = lc _clean_text($value, $MAX_EMAIL);
    return '' unless length $value;
    die "Please enter a valid email address."
        unless $value =~ /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z/;
    return $value;
}

sub _clean_message {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
    $value =~ s/[ \t]+\n/\n/g;
    $value =~ s/\n{4,}/\n\n\n/g;
    $value =~ s/^\s+|\s+\z//g;
    return substr($value, 0, $MAX_MESSAGE);
}

sub _clean_date {
    my ($value) = @_;
    $value = _clean_text($value, $MAX_DATE);
    return '' unless length $value;
    return $value if $value =~ /\A\d{4}-\d{2}-\d{2}\z/;
    return $value;
}

sub _clean_count {
    my ($value) = @_;
    return undef unless defined $value && $value =~ /\A\s*\d{1,5}\s*\z/;
    return int($value);
}

sub _trim {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return $value;
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _bytes_label {
    my ($bytes) = @_;
    $bytes = int($bytes || 0);
    return sprintf('%.1f MB', $bytes / 1024 / 1024) if $bytes >= 1024 * 1024;
    return int(($bytes + 1023) / 1024) . ' KB' if $bytes >= 1024;
    return $bytes . ' bytes';
}

sub _ext_for_mime {
    my ($mime) = @_;
    $mime = lc($mime || '');
    for my $ext (sort keys %EXT_MIME) {
        return $ext if $EXT_MIME{$ext} eq $mime;
    }
    return '';
}

sub _download_filename {
    my ($filename) = @_;
    $filename = basename($filename || 'form-upload');
    $filename =~ s/[\r\n"\\\/]+/-/g;
    $filename =~ s/[^\w.\- ]+/-/g;
    $filename =~ s/^\.+//;
    $filename =~ s/\s+/ /g;
    $filename =~ s/^\s+|\s+\z//g;
    return length($filename) ? substr($filename, 0, 180) : 'form-upload';
}

sub _is_under {
    my ($path, $root) = @_;
    return 0 unless length($path || '') && length($root || '');
    my $abs_path = File::Spec->rel2abs($path);
    my $abs_root = File::Spec->rel2abs($root);
    $abs_path =~ s{\\}{/}g;
    $abs_root =~ s{\\}{/}g;
    $abs_root =~ s{/+\z}{};
    return $abs_path eq $abs_root || index($abs_path, "$abs_root/") == 0;
}

sub _html_multiline {
    my ($value) = @_;
    my $safe = escape_html($value || '');
    $safe =~ s/\n/<br>/g;
    return $safe;
}

1;
