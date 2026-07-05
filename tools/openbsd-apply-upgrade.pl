#!/usr/bin/env perl

use strict;
use warnings;
use Cwd qw(abs_path);
use Fcntl qw(:flock);
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use File::Find;
use File::Path qw(make_path remove_tree);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::Upgrade;
use DesertCMS::Util qw(now);

my %opt = (
    config       => '/etc/desertcms.conf',
    app_root     => '/usr/local/www/desertcms',
    app_user     => '_desertcms',
    lock_file    => '/var/run/desertcms-upgrade.lock',
    max_jobs     => 1,
    quiet        => 0,
    dry_run      => 0,
    install_cron => 0,
);

GetOptionsFromArray(
    \@ARGV,
    'config=s'       => \$opt{config},
    'app-root=s'     => \$opt{app_root},
    'app-user=s'     => \$opt{app_user},
    'lock-file=s'    => \$opt{lock_file},
    'max-jobs=i'     => \$opt{max_jobs},
    'quiet'          => \$opt{quiet},
    'dry-run'        => \$opt{dry_run},
    'install-cron'   => \$opt{install_cron},
) or die usage();

install_cron_and_exit() if $opt{install_cron};
die "this tool must run as root\n" if !$opt{dry_run} && $> != 0;

my $config = DesertCMS::Config->load($opt{config});
my $app_root_abs = abs_path($opt{app_root}) || $opt{app_root};
die "app root does not exist: $opt{app_root}\n" unless -d $opt{app_root};

acquire_lock();
process_jobs();

sub process_jobs {
    my $jobs = DesertCMS::Upgrade::queued_jobs($config);
    my $count = 0;
    for my $job (@{$jobs}) {
        last if $count++ >= int($opt{max_jobs} || 1);
        apply_job($job);
    }
    log_msg('no queued upgrade work') if !$count;
}

sub apply_job {
    my ($job) = @_;
    my $id = $job->{id};
    return apply_rollback_job($job) if ($job->{kind} || 'upgrade') eq 'rollback';

    log_msg("starting upgrade job $id");
    DesertCMS::Upgrade::update_job($config, $id,
        status     => 'running',
        message    => 'Upgrade worker is applying this release.',
        started_at => now(),
    );

    eval {
        my $archive = verified_archive_path($job->{archive});
        my $validation = DesertCMS::Upgrade::validate_archive($config, $archive);
        my $backup = backup_current_app();
        my ($work_dir, $release_root) = extract_release($archive, $validation->{release_root});
        replace_application($release_root);
        normalize_permissions();
        install_rc_script();
        migrate_and_rebuild_instances();
        restart_services();
        remove_tree($work_dir) if -d $work_dir && !$opt{dry_run};
        DesertCMS::Upgrade::update_job($config, $id,
            status       => 'done',
            message      => 'Upgrade applied successfully.',
            completed_at => now(),
            app_backup   => $backup,
        );
        log_msg("upgrade job $id done");
        1;
    } or do {
        my $err = $@ || 'unknown upgrade failure';
        DesertCMS::Upgrade::update_job($config, $id,
            status       => 'failed',
            message      => substr($err, 0, 4000),
            completed_at => now(),
        );
        log_msg("upgrade job $id failed: $err");
    };
}

sub apply_rollback_job {
    my ($job) = @_;
    my $id = $job->{id};
    log_msg("starting rollback job $id");
    DesertCMS::Upgrade::update_job($config, $id,
        status     => 'running',
        message    => 'Upgrade worker is applying this rollback.',
        started_at => now(),
    );

    eval {
        my $archive = verified_app_backup_path($job->{app_backup});
        my $pre_rollback_backup = backup_current_app();
        restore_application_backup($archive);
        normalize_permissions();
        install_rc_script();
        migrate_and_rebuild_instances();
        restart_services();
        DesertCMS::Upgrade::update_job($config, $id,
            status              => 'done',
            message             => 'Rollback applied successfully.',
            completed_at        => now(),
            rollback_backup     => $archive,
            pre_rollback_backup => $pre_rollback_backup,
        );
        log_msg("rollback job $id done");
        1;
    } or do {
        my $err = $@ || 'unknown rollback failure';
        DesertCMS::Upgrade::update_job($config, $id,
            status       => 'failed',
            message      => substr($err, 0, 4000),
            completed_at => now(),
        );
        log_msg("rollback job $id failed: $err");
    };
}

sub verified_archive_path {
    my ($archive) = @_;
    die "upgrade archive path is missing\n" unless defined $archive && length $archive;
    die "upgrade archive not found: $archive\n" unless -f $archive;
    my $upgrades = abs_path(DesertCMS::Upgrade::upgrade_dir($config)) || DesertCMS::Upgrade::upgrade_dir($config);
    my $archive_abs = abs_path($archive) || $archive;
    die "upgrade archive is outside the staged upgrade directory\n"
        unless _under_path($archive_abs, $upgrades);
    return $archive_abs;
}

sub verified_app_backup_path {
    my ($archive) = @_;
    die "rollback backup path is missing\n" unless defined $archive && length $archive;
    die "rollback backup not found: $archive\n" unless -f $archive;
    my $filename = basename($archive);
    die "invalid rollback backup filename: $filename\n"
        unless $filename =~ /\Adesertcms-app-[0-9]{8}-[0-9]{6}(?:-[0-9]+)?\.tar\.gz\z/;
    my $archive_abs = abs_path($archive) || $archive;
    my @roots = grep { defined && length } (
        -d '/var/backups' ? '/var/backups' : '',
        File::Spec->catdir(DesertCMS::Upgrade::upgrade_dir($config), 'app-backups'),
    );
    for my $root (@roots) {
        my $root_abs = abs_path($root) || $root;
        return $archive_abs if _under_path($archive_abs, $root_abs);
    }
    die "rollback backup is outside the approved app backup directories\n";
}

sub backup_current_app {
    my $backup_dir = -d '/var/backups'
        ? '/var/backups'
        : File::Spec->catdir(DesertCMS::Upgrade::upgrade_dir($config), 'app-backups');
    make_path($backup_dir) unless -d $backup_dir;
    my $backup = File::Spec->catfile($backup_dir, 'desertcms-app-' . timestamp() . '.tar.gz');
    run_cmd($config->get('tar_tool') || 'tar', '-czf', $backup, '-C', $opt{app_root}, '.');
    chmod 0600, $backup if -f $backup;
    return $backup;
}

sub extract_release {
    my ($archive, $release_prefix) = @_;
    my $work_dir = File::Spec->catdir(DesertCMS::Upgrade::upgrade_dir($config), 'work-' . timestamp() . '-' . $$);
    remove_tree($work_dir) if -d $work_dir;
    make_path($work_dir);
    run_cmd($config->get('tar_tool') || 'tar', '-xzf', $archive, '-C', $work_dir);
    my $release_root = length($release_prefix || '')
        ? File::Spec->catdir($work_dir, split m{/}, $release_prefix)
        : $work_dir;
    die "extracted release root is missing: $release_root\n" unless -d $release_root;
    reject_symlinks($release_root);
    validate_release_root($release_root);
    return ($work_dir, $release_root);
}

sub restore_application_backup {
    my ($archive) = @_;
    my $work_dir = File::Spec->catdir(DesertCMS::Upgrade::upgrade_dir($config), 'rollback-' . timestamp() . '-' . $$);
    remove_tree($work_dir) if -d $work_dir;
    make_path($work_dir);
    run_cmd($config->get('tar_tool') || 'tar', '-xzf', $archive, '-C', $work_dir);
    reject_symlinks($work_dir);
    validate_release_root($work_dir);
    replace_application($work_dir);
    remove_tree($work_dir) if -d $work_dir && !$opt{dry_run};
}

sub validate_release_root {
    my ($release_root) = @_;
    for my $required (DesertCMS::Upgrade::required_release_files()) {
        my $path = File::Spec->catfile($release_root, split m{/}, $required);
        die "release bundle is missing $required\n" unless -f $path;
    }
}

sub reject_symlinks {
    my ($root) = @_;
    find(
        {
            no_chdir => 1,
            wanted => sub {
                die "release bundle contains a symlink: $File::Find::name\n" if -l $File::Find::name;
            },
        },
        $root
    );
}

sub replace_application {
    my ($release_root) = @_;
    die "release root cannot be the app root\n"
        if (abs_path($release_root) || $release_root) eq $app_root_abs;

    my @source_items = source_top_items($release_root);
    my %replace = map { $_ => 1 } qw(
        .gitignore README.md admin bin docs etc install lib public sql t themes tools
    );
    $replace{$_} = 1 for @source_items;

    for my $item (sort keys %replace) {
        next unless safe_top_item($item);
        my $target = File::Spec->catfile($opt{app_root}, $item);
        safe_remove($target) if -e $target || -l $target;
    }

    for my $item (@source_items) {
        next unless safe_top_item($item);
        copy_item(File::Spec->catfile($release_root, $item), File::Spec->catfile($opt{app_root}, $item));
    }
}

sub source_top_items {
    my ($release_root) = @_;
    opendir my $dh, $release_root or die "cannot read release root $release_root: $!\n";
    my @items = grep { $_ ne '.' && $_ ne '..' && safe_top_item($_) } readdir $dh;
    closedir $dh;
    die "release bundle has no safe top-level files\n" unless @items;
    return @items;
}

sub safe_top_item {
    my ($item) = @_;
    return 1 if defined $item && $item eq '.gitignore';
    return 0 unless defined $item && $item =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return 0 if $item =~ /\A(?:data|local|originals|backups|upgrades)\z/;
    return 0 if $item =~ /\A\.(?:git|tools)\z/;
    return 1;
}

sub safe_remove {
    my ($path) = @_;
    my $parent = dirname($path);
    my $parent_abs = abs_path($parent) || $parent;
    die "refusing to remove path outside app root: $path\n" unless _under_path($parent_abs, $app_root_abs);
    log_msg("remove $path");
    return if $opt{dry_run};
    if (-d $path && !-l $path) {
        my $target_abs = abs_path($path) || $path;
        die "refusing to remove directory outside app root: $path\n" unless _under_path($target_abs, $app_root_abs);
        remove_tree($path);
    } else {
        unlink $path or die "cannot remove $path: $!\n";
    }
}

sub copy_item {
    my ($source, $dest) = @_;
    die "release source item missing: $source\n" unless -e $source;
    log_msg("copy $source to $dest");
    return if $opt{dry_run};
    if (-d $source) {
        make_path($dest) unless -d $dest;
        find(
            {
                no_chdir => 1,
                wanted => sub {
                    return if $File::Find::name eq $source;
                    die "release bundle contains a symlink: $File::Find::name\n" if -l $File::Find::name;
                    my $rel = File::Spec->abs2rel($File::Find::name, $source);
                    my $target = File::Spec->catfile($dest, $rel);
                    if (-d $File::Find::name) {
                        make_path($target) unless -d $target;
                    } else {
                        make_path(dirname($target)) unless -d dirname($target);
                        copy($File::Find::name, $target) or die "cannot copy $File::Find::name to $target: $!\n";
                    }
                },
            },
            $source
        );
    } else {
        make_path(dirname($dest)) unless -d dirname($dest);
        copy($source, $dest) or die "cannot copy $source to $dest: $!\n";
    }
}

sub normalize_permissions {
    run_cmd('chown', '-R', 'root:wheel', $opt{app_root});
    run_cmd('find', $opt{app_root}, '-type', 'd', '-exec', 'chmod', '755', '{}', '+');
    run_cmd('find', $opt{app_root}, '-type', 'f', '-exec', 'chmod', '644', '{}', '+');
    my @executable = (
        File::Spec->catfile($opt{app_root}, 'bin', 'desertcms.cgi'),
        File::Spec->catfile($opt{app_root}, 'bin', 'desertcms-maint.pl'),
        glob(File::Spec->catfile($opt{app_root}, 'tools', '*.pl')),
        glob(File::Spec->catfile($opt{app_root}, 'install', '*.pl')),
        glob(File::Spec->catfile($opt{app_root}, 'install', '*.ksh')),
    );
    @executable = grep { -f $_ } @executable;
    run_cmd('chmod', '755', @executable) if @executable;
}

sub install_rc_script {
    my $source = File::Spec->catfile($opt{app_root}, 'etc', 'rc.d', 'desertcms_slowcgi');
    return unless -f $source;
    my $dest = '/etc/rc.d/desertcms_slowcgi';
    backup_root_file($dest) if -f $dest;
    log_msg("install $source to $dest");
    return if $opt{dry_run};
    copy($source, $dest) or die "cannot copy $source to $dest: $!\n";
    chmod 0555, $dest;
    run_cmd('chown', 'root:wheel', $dest);
}

sub migrate_and_rebuild_instances {
    for my $conf (instance_configs()) {
        ensure_instance_state_dirs($conf);
        repair_instance_public_root_ownership($conf);
        run_as_app('env', "DESERTCMS_CONFIG=$conf", 'perl', File::Spec->catfile($opt{app_root}, 'bin', 'desertcms-maint.pl'), 'init-db');
        run_as_app('env', "DESERTCMS_CONFIG=$conf", 'perl', File::Spec->catfile($opt{app_root}, 'bin', 'desertcms-maint.pl'), 'rebuild');
    }
}

sub ensure_instance_state_dirs {
    my ($conf_path) = @_;
    my $instance = eval { DesertCMS::Config->load($conf_path) };
    if (!$instance) {
        log_msg("skip state directory check for $conf_path: " . ($@ || 'config load failed'));
        return;
    }
    my $data_dir = $instance->get('data_dir') || '';
    return unless length $data_dir;
    my $font_dir = File::Spec->catdir($data_dir, 'font-packages');
    run_cmd('install', '-d', '-o', $opt{app_user}, '-g', $opt{app_user}, '-m', '750', $font_dir)
        unless -d $font_dir;
}

sub repair_instance_public_root_ownership {
    my ($conf_path) = @_;
    my $instance = eval { DesertCMS::Config->load($conf_path) };
    if (!$instance) {
        log_msg("skip public root repair for $conf_path: " . ($@ || 'config load failed'));
        return;
    }
    my $public_root = $instance->get('public_root') || '';
    if (!length $public_root) {
        log_msg("skip public root repair for $conf_path: public_root is not configured");
        return;
    }
    die "refusing to repair unsafe public root for $conf_path: $public_root\n"
        unless safe_public_root($public_root);
    run_cmd('install', '-d', '-o', $opt{app_user}, '-g', $opt{app_user}, '-m', '755', $public_root)
        unless -d $public_root;
    run_cmd('chown', '-R', "$opt{app_user}:$opt{app_user}", $public_root);
}

sub safe_public_root {
    my ($path) = @_;
    return defined $path && $path =~ m{\A/var/www/htdocs/[A-Za-z0-9][A-Za-z0-9._-]*\z};
}

sub instance_configs {
    my %seen;
    my @paths = ($opt{config}, glob('/etc/desertcms.conf'), glob('/etc/desertcms-*.conf'));
    @paths = grep { defined && length && -f $_ && !$seen{$_}++ } @paths;
    return @paths;
}

sub restart_services {
    run_cmd('httpd', '-n');
    run_cmd('rcctl', 'restart', 'desertcms_slowcgi');
    run_cmd('rcctl', 'reload', 'httpd');
}

sub run_as_app {
    my @cmd = @_;
    my $body = join ' ', map { shell_quote($_) } @cmd;
    run_cmd('su', '-m', $opt{app_user}, '-c', $body);
}

sub backup_root_file {
    my ($path) = @_;
    return unless -f $path;
    my $backup = "$path.bak." . timestamp();
    log_msg("backup $path to $backup");
    return if $opt{dry_run};
    copy($path, $backup) or die "cannot backup $path to $backup: $!\n";
    chmod 0600, $backup;
}

sub run_cmd {
    my @cmd = @_;
    log_msg(join ' ', map { shell_quote($_) } @cmd);
    return if $opt{dry_run};
    system @cmd;
    die "command failed: @cmd\n" if $?;
}

sub acquire_lock {
    return if $opt{dry_run};
    open my $fh, '>', $opt{lock_file} or die "cannot open lock $opt{lock_file}: $!\n";
    if (!flock($fh, LOCK_EX | LOCK_NB)) {
        log_msg('upgrade applier already running');
        exit 0;
    }
    $SIG{INT} = $SIG{TERM} = sub { close $fh; exit 1 };
}

sub install_cron_and_exit {
    die "--install-cron must run as root\n" if $> != 0;
    my $cmd = "$^X $opt{app_root}/tools/openbsd-apply-upgrade.pl --quiet";
    my $marker = '# DesertCMS upgrade worker';
    my $current = qx(crontab -l 2>/dev/null);
    my @lines = grep { $_ !~ /\Q$marker\E/ && $_ !~ /openbsd-apply-upgrade\.pl/ } split /\n/, $current;
    push @lines, $marker, "* * * * * $cmd";
    my $body = join("\n", @lines) . "\n";
    open my $pipe, '|-', 'crontab', '-' or die "cannot install root crontab: $!\n";
    print {$pipe} $body;
    close $pipe or die "crontab install failed\n";
    print "installed root cron worker for DesertCMS upgrades\n";
    exit 0;
}

sub _under_path {
    my ($path, $root) = @_;
    $path =~ s{\\}{/}g;
    $root =~ s{\\}{/}g;
    $path =~ s{/+\z}{};
    $root =~ s{/+\z}{};
    return $path eq $root || index($path, "$root/") == 0;
}

sub timestamp {
    my @t = localtime;
    return sprintf '%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

sub shell_quote {
    my ($value) = @_;
    $value = '' unless defined $value;
    return "''" if $value eq '';
    return $value if $value =~ /\A[A-Za-z0-9_\-\.\/:=]+\z/;
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

sub log_msg {
    my ($msg) = @_;
    return if $opt{quiet};
    print timestamp() . " $msg\n";
}

sub usage {
    return <<"USAGE";
usage: $0 [--config /etc/desertcms.conf] [--app-root /usr/local/www/desertcms] [--quiet] [--dry-run] [--install-cron]
USAGE
}
