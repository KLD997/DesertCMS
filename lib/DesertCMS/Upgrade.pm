package DesertCMS::Upgrade;

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3;
use JSON::PP qw(decode_json encode_json);
use Symbol qw(gensym);
use DesertCMS::Util qw(now);

my $MAX_ARCHIVE_BYTES = 64 * 1024 * 1024;
my $RELEASE_MANIFEST = 'desertcms-release-manifest.json';
my $RELEASE_MANIFEST_FORMAT = 'desertcms-release-manifest-v1';
my @REQUIRED_RELEASE_FILES = qw(
    bin/desertcms.cgi
    bin/desertcms-maint.pl
    lib/DesertCMS/App.pm
    lib/DesertCMS/Config.pm
    tools/openbsd-validate.pl
    install/openbsd-install.pl
    themes/default/templates/layout.html
);

sub upgrade_dir {
    my ($config) = @_;
    return File::Spec->catdir($config->get('data_dir'), 'upgrades');
}

sub jobs_dir {
    my ($config) = @_;
    return File::Spec->catdir(upgrade_dir($config), 'jobs');
}

sub app_backup_dir {
    my ($config) = @_;
    return File::Spec->catdir(upgrade_dir($config), 'app-backups');
}

sub default_app_root {
    my $root = File::Spec->catdir(dirname(__FILE__), '..', '..');
    return abs_path($root) || File::Spec->rel2abs($root);
}

sub stage_upload {
    my ($config, %args) = @_;
    my $upload = $args{upload} or die "Choose a DesertCMS release .tar.gz file first";
    my $filename = basename($upload->{filename} || '');
    die "Upgrade archive must be a .tar.gz or .tgz file"
        unless $filename =~ /\.(?:tar\.gz|tgz)\z/i;

    my $content = $upload->{content};
    die "Upgrade archive is empty" unless defined $content && length $content;
    die "Upgrade archive is larger than the configured admin upload limit"
        if length($content) > ($args{max_bytes} || $MAX_ARCHIVE_BYTES);

    _ensure_dirs($config);
    my $sha = sha256_hex($content);
    if (my $existing = existing_job_for_sha($config, $sha)) {
        return { %{$existing}, reused => 1 };
    }
    my $id = _unique_job_id($config, substr($sha, 0, 12));
    my $archive = File::Spec->catfile(upgrade_dir($config), "$id.tar.gz");
    _write_file_raw($archive, $content);
    chmod 0600, $archive;

    my $validation = eval { validate_archive($config, $archive) };
    if (!$validation) {
        my $err = $@ || 'Upgrade archive validation failed';
        unlink $archive if -f $archive;
        die $err;
    }
    my $job = {
        id                     => $id,
        status                 => 'queued',
        filename               => $filename,
        archive                => $archive,
        bytes                  => length($content),
        sha256                 => $sha,
        submitted_at           => now(),
        submitted_by_user_id   => int($args{submitted_by_user_id} || 0),
        submitted_by_username  => $args{submitted_by_username} || '',
        channel                => _clean_channel($args{channel}),
        release_root           => $validation->{release_root},
        member_count           => $validation->{member_count},
        release_trust          => $validation->{release_trust},
        message                => 'Upgrade queued for the root worker.',
    };
    write_job($config, $job);
    return $job;
}

sub queue_rollback {
    my ($config, %args) = @_;
    my $backup = _select_rollback_backup($config, %args);
    my $sha = _sha256_file($backup->{path});

    for my $existing (@{latest_jobs($config, limit => 500)}) {
        next unless ($existing->{kind} || 'upgrade') eq 'rollback';
        next unless lc($existing->{sha256} || '') eq lc($sha);
        next unless ($existing->{status} || '') =~ /\A(?:queued|running|done)\z/;
        return { %{$existing}, reused => 1 };
    }

    my $id = _unique_job_id($config, substr($sha, 0, 12));
    my $job = {
        id                     => $id,
        kind                   => 'rollback',
        status                 => 'queued',
        filename               => $backup->{filename},
        app_backup             => $backup->{path},
        bytes                  => $backup->{bytes},
        sha256                 => $sha,
        submitted_at           => now(),
        submitted_by_user_id   => int($args{submitted_by_user_id} || 0),
        submitted_by_username  => $args{submitted_by_username} || '',
        message                => 'Rollback queued for the root worker.',
    };
    write_job($config, $job);
    return $job;
}

sub available_rollbacks {
    my ($config, %args) = @_;
    my @roots = _rollback_roots($config, $args{roots});
    my @rows;
    my %seen;
    for my $root (@roots) {
        next unless defined $root && length $root && -d $root;
        opendir my $dh, $root or next;
        for my $file (grep { _safe_rollback_filename($_) } readdir $dh) {
            my $path = File::Spec->catfile($root, $file);
            next unless -f $path;
            my $abs = abs_path($path) || $path;
            next if $seen{$abs}++;
            my @st = stat($path);
            push @rows, {
                filename => $file,
                path     => $abs,
                root     => $root,
                bytes    => int($st[7] || 0),
                mtime    => int($st[9] || 0),
            };
        }
        closedir $dh;
    }
    @rows = sort { ($b->{mtime} || 0) <=> ($a->{mtime} || 0) || ($b->{filename} || '') cmp ($a->{filename} || '') } @rows;
    return \@rows;
}

sub validate_archive {
    my ($config, $archive) = @_;
    die "Upgrade archive is required" unless defined $archive && length $archive;
    die "Upgrade archive was not found: $archive" unless -f $archive;

    my $tar = $config->get('tar_tool') || 'tar';
    my ($out, $err, $status) = _capture($tar, '-tzf', $archive);
    die "Unable to list upgrade archive: $err" if $status != 0;

    my @members;
    for my $line (split /\n/, $out) {
        my $member = _safe_archive_member($line);
        push @members, $member if length $member;
    }
    die "Upgrade archive does not contain files" unless @members;
    my $release_root = _release_root_for_members(@members);
    my $release_signature = _validate_release_signature($config, $archive, $tar, \@members, $release_root);

    return {
        release_root  => $release_root,
        member_count  => scalar @members,
        release_trust => $release_signature->{release_trust},
    };
}

sub queued_jobs {
    my ($config) = @_;
    return [ grep { ($_->{status} || '') eq 'queued' } @{latest_jobs($config, limit => 500)} ];
}

sub existing_job_for_sha {
    my ($config, $sha) = @_;
    return undef unless defined $sha && $sha =~ /\A[0-9a-f]{64}\z/;
    for my $job (@{latest_jobs($config, limit => 500)}) {
        next unless lc($job->{sha256} || '') eq lc($sha);
        next if ($job->{status} || '') =~ /\A(?:failed|cancelled)\z/;
        return $job if ($job->{status} || '') =~ /\A(?:queued|running|done)\z/;
    }
    return undef;
}

sub latest_jobs {
    my ($config, %args) = @_;
    my $limit = int($args{limit} || 10);
    _ensure_dirs($config);
    my @jobs;
    opendir my $dh, jobs_dir($config) or return [];
    for my $file (grep { /\.json\z/ } readdir $dh) {
        my $path = File::Spec->catfile(jobs_dir($config), $file);
        my $job = eval { read_job_path($path) };
        push @jobs, $job if $job && ref $job eq 'HASH';
    }
    closedir $dh;
    @jobs = sort {
        ($b->{submitted_at} || $b->{updated_at} || 0) <=> ($a->{submitted_at} || $a->{updated_at} || 0)
            || ($b->{id} || '') cmp ($a->{id} || '')
    } @jobs;
    splice @jobs, $limit if @jobs > $limit;
    return \@jobs;
}

sub read_job {
    my ($config, $id) = @_;
    return read_job_path(_job_path($config, $id));
}

sub read_job_path {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read upgrade job $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return decode_json($body || '{}');
}

sub write_job {
    my ($config, $job) = @_;
    die "upgrade job id is required" unless $job && $job->{id};
    $job->{updated_at} = now();
    _ensure_dirs($config);
    _write_file_text(_job_path($config, $job->{id}), encode_json($job));
    chmod 0600, _job_path($config, $job->{id});
    _repair_file_ownership($config, _job_path($config, $job->{id})) if $> == 0;
    return $job;
}

sub update_job {
    my ($config, $id, %fields) = @_;
    my $job = read_job($config, $id);
    @{$job}{keys %fields} = values %fields;
    return write_job($config, $job);
}

sub job_path {
    my ($config, $id) = @_;
    return _job_path($config, $id);
}

sub required_release_files {
    return @REQUIRED_RELEASE_FILES;
}

sub release_root_for_members {
    my (@members) = @_;
    return _release_root_for_members(@members);
}

sub _validate_release_signature {
    my ($config, $archive, $tar, $members, $release_root) = @_;
    my $require_signed = _config_bool($config, 'upgrade_require_signed_releases');
    my $public_key = _trim($config->get('upgrade_signify_public_key') || '');

    if (!length $public_key) {
        die "Signed release verification is required but upgrade_signify_public_key is not configured\n"
            if $require_signed;
        return { release_trust => 'unsigned-owner-only' };
    }
    die "Configured upgrade_signify_public_key was not found: $public_key\n"
        unless -f $public_key;

    my %member = map { $_ => 1 } @{$members};
    my $manifest_member = _release_member($release_root, $RELEASE_MANIFEST);
    my $signature_member = "$manifest_member.sig";
    die "Signed release manifest is required when upgrade_signify_public_key is configured\n"
        unless $member{$manifest_member} && $member{$signature_member};

    my $manifest_body = _archive_member_bytes($tar, $archive, $manifest_member);
    my $signature_body = _archive_member_bytes($tar, $archive, $signature_member);
    my $manifest = eval { decode_json($manifest_body) };
    die "Signed release manifest is not valid JSON\n"
        unless $manifest && ref $manifest eq 'HASH';
    die "Signed release manifest format is not supported\n"
        unless ($manifest->{format} || '') eq $RELEASE_MANIFEST_FORMAT;
    die "Signed release manifest must contain a files object\n"
        unless ref($manifest->{files}) eq 'HASH';

    _verify_release_manifest_files(
        $tar,
        $archive,
        $members,
        $release_root,
        $manifest->{files},
        $manifest_member,
        $signature_member,
    );
    _verify_manifest_signature($config, $public_key, $manifest_body, $signature_body);

    return { release_trust => 'signed' };
}

sub _verify_release_manifest_files {
    my ($tar, $archive, $members, $release_root, $manifest_files, $manifest_member, $signature_member) = @_;
    my %archive_files;
    for my $member (_archive_file_members($members)) {
        next if $member eq $manifest_member || $member eq $signature_member;
        my $relative = _strip_release_root($member, $release_root);
        next unless defined $relative && length $relative;
        $archive_files{$relative} = $member;
    }

    for my $relative (sort keys %{$manifest_files}) {
        my $safe = eval { _safe_archive_member($relative) };
        die "Signed release manifest contains an unsafe path: $relative\n"
            unless defined $safe && length $safe && $safe eq $relative;
        die "Signed release manifest must not list manifest signature files: $relative\n"
            if $relative eq $RELEASE_MANIFEST || $relative eq "$RELEASE_MANIFEST.sig";
        die "Signed release manifest references a missing archive file: $relative\n"
            unless exists $archive_files{$relative};
        die "Signed release manifest has an invalid sha256 for $relative\n"
            unless lc($manifest_files->{$relative} || '') =~ /\A[0-9a-f]{64}\z/;
    }

    for my $relative (sort keys %archive_files) {
        die "Signed release manifest does not cover archive file: $relative\n"
            unless exists $manifest_files->{$relative};
        my $body = _archive_member_bytes($tar, $archive, $archive_files{$relative});
        my $expected = lc($manifest_files->{$relative});
        my $actual = sha256_hex($body);
        die "Signed release manifest hash mismatch for $relative\n"
            unless $actual eq $expected;
    }
}

sub _verify_manifest_signature {
    my ($config, $public_key, $manifest_body, $signature_body) = @_;
    my $signify = _trim($config->get('upgrade_signify_tool') || 'signify') || 'signify';
    my $temp = tempdir(CLEANUP => 1);
    my $manifest_path = File::Spec->catfile($temp, $RELEASE_MANIFEST);
    my $signature_path = "$manifest_path.sig";
    _write_file_raw($manifest_path, $manifest_body);
    _write_file_raw($signature_path, $signature_body);

    my ($out, $err, $status) = _capture(
        $signify,
        '-V',
        '-p', $public_key,
        '-m', $manifest_path,
        '-x', $signature_path,
    );
    die "Signed release verification failed: " . ($err || $out || "signify exited $status") if $status != 0;
}

sub _archive_member_bytes {
    my ($tar, $archive, $member) = @_;
    my ($out, $err, $status) = _capture($tar, '-xOzf', $archive, $member);
    die "Unable to read upgrade archive member $member: $err" if $status != 0;
    return $out;
}

sub _archive_file_members {
    my ($members) = @_;
    my %has_child;
    for my $member (@{$members}) {
        my $parent = $member;
        while ($parent =~ s{/[^/]+\z}{}) {
            $has_child{$parent} = 1;
        }
    }
    return grep { !$has_child{$_} } @{$members};
}

sub _release_member {
    my ($release_root, $relative) = @_;
    return length($release_root || '') ? "$release_root/$relative" : $relative;
}

sub _strip_release_root {
    my ($member, $release_root) = @_;
    return $member unless length($release_root || '');
    return undef if $member eq $release_root;
    return undef unless $member =~ s{\A\Q$release_root\E/}{};
    return $member;
}

sub _config_bool {
    my ($config, $key) = @_;
    my $value = $config->get($key);
    return 0 unless defined $value;
    $value = lc _trim($value);
    return $value =~ /\A(?:1|true|yes|on|required)\z/ ? 1 : 0;
}

sub _trim {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\A\s+|\s+\z//g;
    return $value;
}

sub _ensure_dirs {
    my ($config) = @_;
    my @dirs = (upgrade_dir($config), jobs_dir($config), app_backup_dir($config));
    for my $dir (@dirs) {
        make_path($dir, { mode => 0750 }) unless -d $dir;
        chmod 0750, $dir if -d $dir;
    }
    _repair_dir_ownership($config, @dirs) if $> == 0;
}

sub _repair_dir_ownership {
    my ($config, @dirs) = @_;
    my @st = stat($config->get('data_dir'));
    return unless @st;
    my ($uid, $gid) = @st[4, 5];
    for my $dir (@dirs) {
        next unless -d $dir;
        chown $uid, $gid, $dir;
        chmod 0750, $dir;
    }
}

sub _repair_file_ownership {
    my ($config, $path) = @_;
    my @st = stat($config->get('data_dir'));
    return unless @st && -f $path;
    my ($uid, $gid) = @st[4, 5];
    chown $uid, $gid, $path;
    chmod 0600, $path;
}

sub _job_path {
    my ($config, $id) = @_;
    die "invalid upgrade job id" unless defined $id && $id =~ /\A[0-9]{8}-[0-9]{6}-[0-9a-f]{12}(?:-[0-9]+)?\z/;
    return File::Spec->catfile(jobs_dir($config), "$id.json");
}

sub _unique_job_id {
    my ($config, $sha_prefix) = @_;
    my $base = _timestamp() . '-' . lc($sha_prefix || '000000000000');
    my $id = $base;
    my $i = 1;
    while (-e File::Spec->catfile(upgrade_dir($config), "$id.tar.gz")
        || -e File::Spec->catfile(jobs_dir($config), "$id.json")) {
        $i++;
        $id = "$base-$i";
    }
    return $id;
}

sub _select_rollback_backup {
    my ($config, %args) = @_;
    my $wanted = $args{path} || $args{filename} || '';
    die "choose an app backup to roll back to" unless length $wanted;
    my $wanted_file = basename($wanted);
    die "invalid rollback backup filename" unless _safe_rollback_filename($wanted_file);
    my $wanted_abs = $args{path} ? (abs_path($wanted) || $wanted) : '';

    for my $backup (@{available_rollbacks($config, roots => $args{roots})}) {
        return $backup if length($wanted_abs) && ($backup->{path} || '') eq $wanted_abs;
        return $backup if ($backup->{filename} || '') eq $wanted_file;
    }
    die "rollback backup was not found: $wanted_file";
}

sub _clean_channel {
    my ($channel) = @_;
    $channel = lc($channel || 'stable');
    return $channel if $channel =~ /\A(?:stable|beta|nightly)\z/;
    return 'stable';
}

sub _rollback_roots {
    my ($config, $roots) = @_;
    return @{$roots} if ref $roots eq 'ARRAY';
    return (
        '/var/backups',
        app_backup_dir($config),
    );
}

sub _safe_rollback_filename {
    my ($file) = @_;
    return defined $file && $file =~ /\Adesertcms-app-[0-9]{8}-[0-9]{6}(?:-[0-9]+)?\.tar\.gz\z/;
}

sub _sha256_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    my $ctx = Digest::SHA->new(256);
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
}

sub _safe_archive_member {
    my ($member) = @_;
    $member = '' unless defined $member;
    $member =~ s/\r\z//;
    $member =~ s{\A\./+}{};
    $member =~ s{/+\z}{};
    return '' unless length $member;
    die "unsafe archive path: $member" if $member =~ m{\A/};
    die "unsafe archive path: $member" if $member =~ m{\\};
    die "unsafe archive path: $member" if $member =~ m{\A[A-Za-z]:};
    die "unsafe archive path: $member" if $member =~ /[\x00-\x1f\x7f]/;
    for my $part (split m{/}, $member) {
        die "unsafe archive path: $member" if !length($part) || $part eq '.' || $part eq '..';
    }
    return $member;
}

sub _release_root_for_members {
    my (@members) = @_;
    my %member = map { $_ => 1 } @members;
    return '' if _has_required_files('', \%member);

    my %top;
    for my $member (@members) {
        my ($first, $rest) = split m{/}, $member, 2;
        next unless defined $rest && length $rest;
        $top{$first} = 1;
    }
    for my $prefix (sort keys %top) {
        return $prefix if _has_required_files($prefix, \%member);
    }
    die "Archive is not a DesertCMS release bundle";
}

sub _has_required_files {
    my ($prefix, $members) = @_;
    for my $required (@REQUIRED_RELEASE_FILES) {
        my $path = length($prefix || '') ? "$prefix/$required" : $required;
        return 0 unless $members->{$path};
    }
    return 1;
}

sub _write_file_raw {
    my ($path, $body) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    my $tmp = "$path.$$";
    open my $fh, '>:raw', $tmp or die "cannot write $tmp: $!";
    print {$fh} $body;
    close $fh or die "cannot close $tmp: $!";
    rename $tmp, $path or die "cannot replace $path: $!";
}

sub _write_file_text {
    my ($path, $body) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    my $tmp = "$path.$$";
    open my $fh, '>', $tmp or die "cannot write $tmp: $!";
    print {$fh} $body;
    close $fh or die "cannot close $tmp: $!";
    rename $tmp, $path or die "cannot replace $path: $!";
}

sub _capture {
    my @cmd = @_;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @cmd);
    close $in;
    binmode $out;
    binmode $err;
    my $stdout = do { local $/; <$out> };
    my $stderr = do { local $/; <$err> };
    waitpid($pid, 0);
    return ($stdout || '', $stderr || '', $? == -1 ? 255 : (($? >> 8) || 0));
}

sub _timestamp {
    my @t = localtime;
    return sprintf '%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

1;
