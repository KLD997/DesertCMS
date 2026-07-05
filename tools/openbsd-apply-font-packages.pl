#!/usr/bin/env perl

use strict;
use warnings;
use Fcntl qw(:flock);
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);
use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::FontPackages;
use DesertCMS::Settings;

my %opt = (
    config       => '/etc/desertcms.conf',
    app_root     => '/usr/local/www/desertcms',
    lock_file    => 'font-packages.lock',
    package_repo => '',
    quiet        => 0,
    dry_run      => 0,
    install_cron => 0,
);

GetOptionsFromArray(
    \@ARGV,
    'config=s'       => \$opt{config},
    'app-root=s'     => \$opt{app_root},
    'lock-file=s'    => \$opt{lock_file},
    'package-repo=s' => \$opt{package_repo},
    'quiet'          => \$opt{quiet},
    'dry-run'        => \$opt{dry_run},
    'install-cron'   => \$opt{install_cron},
) or die usage();

install_cron_and_exit() if $opt{install_cron};
die "font package worker must run as root\n" if !$opt{dry_run} && $> != 0;

my $config = DesertCMS::Config->load($opt{config});
my $repo = DesertCMS::FontPackages::clean_repo($opt{package_repo});
if (!length $repo) {
    $repo = eval {
        my $db = DesertCMS::DB->new(config => $config);
        DesertCMS::Settings::all($config, $db)->{font_package_repo} || '';
    } || '';
}

acquire_lock();
my $result = DesertCMS::FontPackages::apply_queued_jobs(
    $config,
    package_repo => $repo,
    dry_run      => $opt{dry_run},
);
log_msg("font package jobs: $result->{total} total, $result->{done} installed, $result->{failed} failed");
exit($result->{failed} ? 1 : 0);

sub acquire_lock {
    return if $opt{dry_run};
    my $lock_dir = File::Spec->catdir($config->get('data_dir'), 'locks');
    make_path($lock_dir) unless -d $lock_dir;
    my $lock_file = $opt{lock_file};
    if ($lock_file !~ m{\A/}) {
        $lock_file = File::Spec->catfile($lock_dir, $lock_file);
    }
    open my $fh, '>', $lock_file or die "cannot open lock $lock_file: $!\n";
    if (!flock($fh, LOCK_EX | LOCK_NB)) {
        log_msg('font package worker already running');
        exit 0;
    }
    $SIG{INT} = $SIG{TERM} = sub { close $fh; exit 1 };
}

sub install_cron_and_exit {
    die "--install-cron must run as root\n" if $> != 0;
    my $cmd = "env DESERTCMS_CONFIG=$opt{config} $^X $opt{app_root}/tools/openbsd-apply-font-packages.pl --config $opt{config} --quiet";
    my $marker = '# DesertCMS font package worker ' . $opt{config};
    my $current = qx(crontab -l 2>/dev/null);
    my @lines = grep {
        $_ !~ /\Q$marker\E/
            && !($_ =~ /openbsd-apply-font-packages\.pl/ && $_ =~ /--config\s+\Q$opt{config}\E/)
    } split /\n/, $current;
    push @lines, $marker, "*/5 * * * * " . shell_quote_cmd($cmd);
    my $body = join("\n", @lines) . "\n";
    open my $pipe, '|-', 'crontab', '-' or die "cannot install root crontab: $!\n";
    print {$pipe} $body;
    close $pipe or die "crontab install failed\n";
    print "installed root cron worker for DesertCMS font packages\n";
    exit 0;
}

sub shell_quote_cmd {
    my ($cmd) = @_;
    my @parts = split /\s+/, $cmd;
    return join ' ', map { shell_quote($_) } @parts;
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
    print scalar(localtime) . " $msg\n";
}

sub usage {
    return <<"USAGE";
usage: $0 [--config /etc/desertcms.conf] [--app-root /usr/local/www/desertcms] [--package-repo URL] [--quiet] [--dry-run] [--install-cron]
USAGE
}
