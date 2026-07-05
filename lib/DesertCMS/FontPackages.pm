package DesertCMS::FontPackages;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
use File::Spec;
use IPC::Open3;
use JSON::PP qw(decode_json encode_json);
use Symbol qw(gensym);
use DesertCMS::Util qw(now);

my @BUILTIN_FONTS = (
    {
        id       => 'serif',
        label    => 'Georgia / platform serif',
        css      => 'Georgia, "Times New Roman", serif',
        fallback => 'serif',
    },
    {
        id       => 'sans',
        label    => 'System sans',
        css      => 'system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        fallback => 'sans-serif',
    },
    {
        id       => 'mono',
        label    => 'System mono',
        css      => 'ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',
        fallback => 'monospace',
    },
);
my %BUILTIN = map { $_->{id} => $_ } @BUILTIN_FONTS;

sub font_dir {
    my ($config) = @_;
    return File::Spec->catdir($config->get('data_dir'), 'font-packages');
}

sub jobs_dir {
    my ($config) = @_;
    return File::Spec->catdir(font_dir($config), 'jobs');
}

sub catalog_path {
    my ($config) = @_;
    return File::Spec->catfile(font_dir($config), 'catalog.json');
}

sub builtin_fonts {
    return [ map { { %{$_} } } @BUILTIN_FONTS ];
}

sub font_options {
    my ($config) = @_;
    my @options = map {
        {
            id       => $_->{id},
            label    => $_->{label},
            source   => 'built-in',
            installed => 1,
        }
    } @BUILTIN_FONTS;

    my $catalog = read_catalog($config);
    my @packages = grep { $_->{installed} && @{$_->{font_files} || []} } @{$catalog->{packages} || []};
    @packages = sort { lc($a->{label} || $a->{stem}) cmp lc($b->{label} || $b->{stem}) } @packages;
    for my $pkg (@packages) {
        push @options, {
            id        => 'pkg:' . $pkg->{stem},
            label     => ($pkg->{label} || $pkg->{stem}) . ' (OpenBSD package)',
            source    => $pkg->{stem},
            installed => 1,
        };
    }
    return \@options;
}

sub css_stack_for_font_id {
    my ($font_id, $fallback_id) = @_;
    $font_id = clean_font_id($font_id, $fallback_id || 'sans');
    return $BUILTIN{$font_id}{css} if $BUILTIN{$font_id};

    if ($font_id =~ /\Apkg:([A-Za-z0-9._+-]+)\z/) {
        my $stem = $1;
        my $family = _font_family_for_stem($stem);
        my $fallback = $fallback_id && $fallback_id eq 'serif' ? 'serif' : $fallback_id && $fallback_id eq 'mono' ? 'monospace' : 'sans-serif';
        return '"' . _css_string($family) . '", ' . $fallback;
    }

    return $BUILTIN{sans}{css};
}

sub clean_font_id {
    my ($font_id, $fallback) = @_;
    $fallback ||= 'sans';
    $fallback = 'sans' unless $BUILTIN{$fallback};
    return $font_id if defined $font_id && $BUILTIN{$font_id};
    return $font_id if defined $font_id && $font_id =~ /\Apkg:[A-Za-z0-9._+-]+\z/;
    return $fallback;
}

sub selected_package_stems {
    my ($site) = @_;
    my %seen;
    my @stems;
    for my $key (qw(theme_heading_font theme_body_font theme_ui_font)) {
        my $id = $site->{$key} || '';
        next unless $id =~ /\Apkg:([A-Za-z0-9._+-]+)\z/;
        next if $seen{$1}++;
        push @stems, $1;
    }
    return @stems;
}

sub font_face_css {
    my ($config, $site) = @_;
    return '' unless $config;
    my $catalog = read_catalog($config);
    my %by_stem = map { ($_->{stem} || '') => $_ } @{$catalog->{packages} || []};
    my $css = '';
    for my $stem (selected_package_stems($site || {})) {
        my $pkg = $by_stem{$stem} || _installed_package_row($stem);
        next unless $pkg && @{$pkg->{font_files} || []};
        my $family = _font_family_for_stem($stem);
        for my $file (@{$pkg->{font_files}}) {
            my $public = _public_font_url($stem, $file);
            next unless length $public;
            my $format = _font_format($file);
            my $weight = _font_weight($file);
            my $style = _font_style($file);
            $css .= "\@font-face {\n"
                . '  font-family: "' . _css_string($family) . "\";\n"
                . "  src: url(\"$public\") format(\"$format\");\n"
                . "  font-weight: $weight;\n"
                . "  font-style: $style;\n"
                . "  font-display: swap;\n"
                . "}\n";
        }
    }
    return $css;
}

sub publish_selected_fonts {
    my ($config, $site) = @_;
    my $dest_root = File::Spec->catdir($config->get('public_root'), 'assets', 'fonts');
    my $catalog = read_catalog($config);
    my %by_stem = map { ($_->{stem} || '') => $_ } @{$catalog->{packages} || []};
    my %selected = map { $_ => 1 } selected_package_stems($site || {});

    remove_tree($dest_root) if -d $dest_root;
    make_path($dest_root);

    for my $stem (keys %selected) {
        my $pkg = $by_stem{$stem} || _installed_package_row($stem);
        next unless $pkg && @{$pkg->{font_files} || []};
        my $safe = _safe_slug($stem);
        my $dest_dir = File::Spec->catdir($dest_root, $safe);
        remove_tree($dest_dir) if -d $dest_dir;
        make_path($dest_dir);
        for my $file (@{$pkg->{font_files}}) {
            next unless _safe_installed_font_file($file);
            if (!-f $file) {
                warn "skipping unavailable font $file\n";
                next;
            }
            my $dest = File::Spec->catfile($dest_dir, _public_font_filename($file));
            if (!copy($file, $dest)) {
                warn "skipping font $file: $!\n";
                next;
            }
        }
    }
}

sub read_catalog {
    my ($config) = @_;
    my $path = catalog_path($config);
    return _empty_catalog('missing', 'Font package catalog has not been refreshed yet.') unless -f $path;
    my $body = _read_file($path);
    my $data = eval { decode_json($body || '{}') };
    return _empty_catalog('failed', 'Font package catalog is not valid JSON.') if $@ || ref $data ne 'HASH';
    $data->{packages} = [] unless ref $data->{packages} eq 'ARRAY';
    return $data;
}

sub refresh_catalog {
    my ($config, %args) = @_;
    my $repo = clean_repo($args{package_repo}) || _auto_package_repo();
    my @installed = _installed_packages();
    my %installed = map { _package_stem($_) => $_ } @installed;

    my $status = 1;
    my $out = '';
    my $err = '';
    my %query_seen;
    for my $query (qw(font fonts ttf otf)) {
        next if $query_seen{$query}++;
        my ($query_out, $query_err, $query_status) = length($repo)
            ? _capture_env({ PKG_PATH => $repo }, 'pkg_info', '-Q', $query)
            : _capture('pkg_info', '-Q', $query);
        if ($query_status == 0) {
            $status = 0;
            $out .= "\n" if length $out && length $query_out;
            $out .= $query_out;
        } elsif (!length $err) {
            $err = $query_err || $query_out;
        }
    }
    my @packages;
    if ($status == 0) {
        my %seen;
        for my $line (split /\n/, $out) {
            $line =~ s/\r\z//;
            $line =~ s/^\s+|\s+$//g;
            next unless _safe_package_name($line);
            my $stem = _package_stem($line);
            next unless _looks_like_font_package($line, $stem);
            next if $seen{$stem}++;
            my $installed_name = $installed{$stem} || '';
            push @packages, _package_row(
                package => $line,
                stem => $stem,
                installed => length($installed_name) ? 1 : 0,
                installed_package => $installed_name,
            );
        }
    }

    my %catalog_stem = map { ($_->{stem} || '') => 1 } @packages;
    for my $pkg (@installed) {
        my $stem = _package_stem($pkg);
        next unless _looks_like_font_package($pkg, $stem);
        next if $catalog_stem{$stem}++;
        push @packages, _package_row(
            package => $pkg,
            stem => $stem,
            installed => 1,
            installed_package => $pkg,
        );
    }

    @packages = sort { lc($a->{label}) cmp lc($b->{label}) || lc($a->{stem}) cmp lc($b->{stem}) } @packages;
    my $catalog = {
        status => $status == 0 ? 'ok' : 'failed',
        package_repo => $repo,
        refreshed_at => now(),
        error => $status == 0 ? '' : _trim_error($err || $out || 'pkg_info -Q font failed'),
        packages => \@packages,
    };
    _write_catalog($config, $catalog);
    return $catalog;
}

sub queue_install {
    my ($config, %args) = @_;
    my $package = clean_package($args{package});
    die "choose a font package to install" unless length $package;
    my $repo = clean_repo($args{package_repo});
    my $job = {
        id => _unique_job_id($config),
        status => 'queued',
        package => $package,
        package_repo => $repo,
        submitted_at => now(),
        submitted_by_user_id => int($args{submitted_by_user_id} || 0),
        submitted_by_username => $args{submitted_by_username} || '',
        message => 'Font package install queued for the root worker.',
    };
    write_job($config, $job);
    return $job;
}

sub latest_jobs {
    my ($config, %args) = @_;
    my $limit = int($args{limit} || 8);
    _ensure_dirs($config);
    my @jobs;
    opendir my $dh, jobs_dir($config) or return [];
    for my $file (grep { /\.json\z/ } readdir $dh) {
        my $path = File::Spec->catfile(jobs_dir($config), $file);
        my $job = eval { decode_json(_read_file($path) || '{}') };
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

sub queued_jobs {
    my ($config) = @_;
    return [ grep { ($_->{status} || '') eq 'queued' } @{latest_jobs($config, limit => 500)} ];
}

sub write_job {
    my ($config, $job) = @_;
    die "font job id is required" unless $job && $job->{id};
    $job->{updated_at} = now();
    _ensure_dirs($config);
    my $path = File::Spec->catfile(jobs_dir($config), "$job->{id}.json");
    _write_file($path, encode_json($job));
    chmod 0600, $path;
    _repair_file_ownership($config, $path) if $> == 0;
    return $job;
}

sub apply_queued_jobs {
    my ($config, %args) = @_;
    die "font package worker must run as root\n" if !$args{dry_run} && $> != 0;
    my @jobs = @{queued_jobs($config)};
    my $done = 0;
    my $failed = 0;
    for my $job (@jobs) {
        eval {
            $job->{status} = 'running';
            $job->{message} = 'Installing OpenBSD font package.';
            write_job($config, $job) unless $args{dry_run};
            my $package = clean_package($job->{package});
            die "invalid font package name\n" unless length $package;
            my ($out, $err, $status) = $args{dry_run}
                ? ('', '', 0)
                : length($job->{package_repo} || '')
                    ? _capture_env({ PKG_PATH => clean_repo($job->{package_repo}) }, 'pkg_add', '-I', $package)
                    : _capture('pkg_add', '-I', $package);
            die _trim_error($err || $out || 'pkg_add failed') . "\n" if $status != 0;
            _capture('fc-cache', '-f') if _command_exists('fc-cache') && !$args{dry_run};
            $job->{status} = 'done';
            $job->{completed_at} = now();
            $job->{message} = 'Font package installed.';
            write_job($config, $job) unless $args{dry_run};
            $done++;
            1;
        } or do {
            my $err = $@ || 'unknown font package install failure';
            $job->{status} = 'failed';
            $job->{error} = _trim_error($err);
            $job->{message} = 'Font package install failed.';
            write_job($config, $job) unless $args{dry_run};
            $failed++;
        };
    }
    refresh_catalog($config, package_repo => $args{package_repo}) if @jobs && !$args{dry_run};
    return { total => scalar @jobs, done => $done, failed => $failed };
}

sub clean_package {
    my ($package) = @_;
    $package = '' unless defined $package;
    $package =~ s/^\s+|\s+$//g;
    return $package if _safe_package_name($package);
    return '';
}

sub clean_repo {
    my ($repo) = @_;
    $repo = '' unless defined $repo;
    $repo =~ s/^\s+|\s+$//g;
    return '' unless length $repo;
    return $repo if $repo =~ m{\Ahttps?://[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]+/?\z};
    return '';
}

sub _auto_package_repo {
    return '' if _package_query_count('', 'font') >= 5;

    my $release = _chomp_capture('uname', '-r');
    my $arch = _chomp_capture('uname', '-m');
    return '' unless length $release && length $arch;

    my @bases = (_installurl_bases(), 'https://cdn.openbsd.org/pub/OpenBSD', 'https://ftp.eu.openbsd.org/pub/OpenBSD', 'https://archive.openbsd.org/pub/OpenBSD');
    my %seen;
    for my $base (@bases) {
        $base = '' unless defined $base;
        $base =~ s{/+\z}{};
        next unless length $base;
        next if $seen{$base}++;
        my $repo = "$base/$release/packages/$arch/";
        return $repo if _package_query_count($repo, 'font') >= 5;
    }
    return '';
}

sub _package_query_count {
    my ($repo, $query) = @_;
    my ($out, undef, $status) = length($repo || '')
        ? _capture_env({ PKG_PATH => clean_repo($repo) }, 'pkg_info', '-Q', $query)
        : _capture('pkg_info', '-Q', $query);
    return 0 if $status != 0;
    my %seen;
    my $count = 0;
    for my $line (split /\n/, $out || '') {
        $line =~ s/\s+\(installed\)\z//;
        $line =~ s/^\s+|\s+$//g;
        next unless _safe_package_name($line);
        my $stem = _package_stem($line);
        next unless _looks_like_font_package($line, $stem);
        next if $seen{$stem}++;
        $count++;
    }
    return $count;
}

sub _installurl_bases {
    my @bases;
    if (open my $fh, '<', '/etc/installurl') {
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s/#.*$//;
            $line =~ s/^\s+|\s+$//g;
            push @bases, $line if length $line;
        }
        close $fh;
    }
    return @bases;
}

sub _package_row {
    my (%args) = @_;
    my $stem = $args{stem} || _package_stem($args{package});
    return {
        package => $args{package},
        stem => $stem,
        label => _package_label($stem),
        installed => $args{installed} ? 1 : 0,
        installed_package => $args{installed_package} || '',
        font_files => $args{installed} ? [ _font_files_for_package($args{installed_package} || $args{package} || $stem) ] : [],
    };
}

sub _installed_package_row {
    my ($stem) = @_;
    return undef unless _safe_package_name($stem);
    my ($installed) = grep { _package_stem($_) eq $stem } _installed_packages();
    $installed ||= $stem;
    my @files = _font_files_for_package($installed);
    return undef unless @files;
    return {
        package => $installed,
        stem => $stem,
        label => _package_label($stem),
        installed => 1,
        installed_package => $installed,
        font_files => \@files,
    };
}

sub _installed_packages {
    return () unless _command_exists('pkg_info');
    my ($out, undef, $status) = _capture('pkg_info', '-q');
    return () if $status != 0;
    return grep { _safe_package_name($_) } map { s/^\s+|\s+$//gr } split /\n/, $out;
}

sub _font_files_for_package {
    my ($package) = @_;
    return () unless _command_exists('pkg_info') && _safe_package_name($package);
    my ($out, undef, $status) = _capture('pkg_info', '-L', $package);
    return () if $status != 0;
    my @files;
    my %seen;
    for my $line (split /\n/, $out) {
        $line =~ s/^\s+|\s+$//g;
        next unless _safe_installed_font_file($line);
        next unless -f $line;
        next if $seen{$line}++;
        push @files, $line;
    }
    return @files;
}

sub _safe_installed_font_file {
    my ($path) = @_;
    return 0 unless defined $path && $path =~ /\.(?:ttf|otf|woff|woff2|ttc)\z/i;
    return 0 if $path =~ /[\x00-\x1f\x7f]/;
    return 1 if $path =~ m{\A/usr/local/share/fonts/};
    return 1 if $path =~ m{\A/usr/X11R6/lib/X11/fonts/};
    return 0;
}

sub _public_font_url {
    my ($stem, $source) = @_;
    return '' unless _safe_installed_font_file($source);
    return '/assets/fonts/' . _safe_slug($stem) . '/' . _public_font_filename($source);
}

sub _public_font_filename {
    my ($path) = @_;
    my @parts = File::Spec->splitpath($path);
    my $file = $parts[-1] || 'font.ttf';
    $file =~ s/[^A-Za-z0-9._-]+/-/g;
    return $file;
}

sub _font_format {
    my ($path) = @_;
    return 'woff2' if $path =~ /\.woff2\z/i;
    return 'woff' if $path =~ /\.woff\z/i;
    return 'opentype' if $path =~ /\.otf\z/i;
    return 'truetype';
}

sub _font_style {
    my ($path) = @_;
    return $path =~ /(?:italic|oblique)/i ? 'italic' : 'normal';
}

sub _font_weight {
    my ($path) = @_;
    return 900 if $path =~ /black|heavy/i;
    return 800 if $path =~ /extra.?bold|ultra.?bold/i;
    return 700 if $path =~ /bold/i;
    return 600 if $path =~ /semi.?bold|demi.?bold/i;
    return 500 if $path =~ /medium/i;
    return 300 if $path =~ /light/i;
    return 200 if $path =~ /extra.?light|ultra.?light/i;
    return 400;
}

sub _package_stem {
    my ($package) = @_;
    $package = '' unless defined $package;
    $package =~ s/^\s+|\s+$//g;
    $package =~ s/-[0-9][A-Za-z0-9._,+-]*\z//;
    return $package;
}

sub _package_label {
    my ($stem) = @_;
    $stem ||= '';
    $stem =~ s/\A(?:font|fonts|ttf|otf)-//i;
    $stem =~ s/-fonts?\z//i;
    $stem =~ s/[-_]+/ /g;
    $stem =~ s/\b(\w)/uc($1)/eg;
    return $stem || 'OpenBSD Font';
}

sub _looks_like_font_package {
    my ($package, $stem) = @_;
    my $value = lc(($package || '') . ' ' . ($stem || ''));
    return $value =~ /(?:font|ttf|otf|noto|dejavu|liberation|fira|roboto|lato|merriweather|ubuntu|inconsolata|iosevka|plex|source|cantarell|terminus)/ ? 1 : 0;
}

sub _safe_package_name {
    my ($package) = @_;
    return defined $package && $package =~ /\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/;
}

sub _font_family_for_stem {
    my ($stem) = @_;
    return 'DesertCMS Font ' . _package_label($stem);
}

sub _css_string {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    return $value;
}

sub _safe_slug {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/[^a-z0-9._-]+/-/g;
    $value =~ s/\A-+|-+\z//g;
    return $value || 'font';
}

sub _empty_catalog {
    my ($status, $error) = @_;
    return {
        status => $status,
        package_repo => '',
        refreshed_at => 0,
        error => $error || '',
        packages => [],
    };
}

sub _write_catalog {
    my ($config, $catalog) = @_;
    _ensure_dirs($config);
    my $path = catalog_path($config);
    _write_file($path, encode_json($catalog));
    chmod 0640, $path;
    _repair_file_ownership($config, $path) if $> == 0;
}

sub _ensure_dirs {
    my ($config) = @_;
    for my $dir (font_dir($config), jobs_dir($config)) {
        make_path($dir, { mode => 0750 }) unless -d $dir;
        chmod 0750, $dir if -d $dir;
    }
    _repair_dir_ownership($config, font_dir($config), jobs_dir($config)) if $> == 0;
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
}

sub _read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _write_file {
    my ($path, $body) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    my $tmp = "$path.$$";
    open my $fh, '>', $tmp or die "cannot write $tmp: $!";
    print {$fh} $body;
    close $fh or die "cannot close $tmp: $!";
    rename $tmp, $path or die "cannot replace $path: $!";
}

sub _unique_job_id {
    my ($config) = @_;
    my @t = localtime;
    my $base = sprintf '%04d%02d%02d-%02d%02d%02d-%06d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0], $$;
    my $id = $base;
    my $i = 1;
    _ensure_dirs($config);
    while (-e File::Spec->catfile(jobs_dir($config), "$id.json")) {
        $i++;
        $id = "$base-$i";
    }
    return $id;
}

sub _capture {
    my @cmd = @_;
    my $command = _command_path($cmd[0]);
    return ('', 'command not found: ' . ($cmd[0] || ''), 127) unless length $command;
    $cmd[0] = $command;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @cmd);
    close $in;
    my $stdout = do { local $/; <$out> };
    my $stderr = do { local $/; <$err> };
    waitpid($pid, 0);
    return ($stdout || '', $stderr || '', $? == -1 ? 255 : (($? >> 8) || 0));
}

sub _capture_env {
    my ($env, @cmd) = @_;
    local %ENV = %ENV;
    for my $key (keys %{$env || {}}) {
        my $value = $env->{$key};
        if (defined $value && length $value) {
            $ENV{$key} = $value;
        } else {
            delete $ENV{$key};
        }
    }
    return _capture(@cmd);
}

sub _chomp_capture {
    my @cmd = @_;
    my ($out, undef, $status) = _capture(@cmd);
    return '' if $status != 0;
    $out = '' unless defined $out;
    $out =~ s/[\r\n]+\z//;
    return $out;
}

sub _command_exists {
    my ($cmd) = @_;
    return length _command_path($cmd) ? 1 : 0;
}

sub _command_path {
    my ($cmd) = @_;
    return 0 unless defined $cmd && length $cmd && $cmd =~ /\A[A-Za-z0-9_.-]+\z/;
    for my $dir (_command_search_dirs()) {
        my $path = File::Spec->catfile($dir, $cmd);
        return $path if -x $path;
    }
    return '';
}

sub _command_search_dirs {
    my %seen;
    return grep { length && !$seen{$_}++ } (
        File::Spec->path,
        qw(/usr/sbin /usr/bin /sbin /bin /usr/local/bin /usr/local/sbin /usr/X11R6/bin),
    );
}

sub _trim_error {
    my ($err) = @_;
    $err = '' unless defined $err;
    $err =~ s/[\r\n]+/ /g;
    $err =~ s/\s+/ /g;
    $err =~ s/^\s+|\s+$//g;
    return substr($err || 'unknown error', 0, 500);
}

1;
