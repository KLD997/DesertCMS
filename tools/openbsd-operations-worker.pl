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
use DesertCMS::Operations;
use DesertCMS::Sites;

my %opt = (
    config       => '/etc/desertcms.conf',
    app_root     => '/usr/local/www/desertcms',
    app_user     => '_desertcms',
    quiet        => 0,
    install_cron => 0,
    dry_run      => 0,
);

GetOptionsFromArray(
    \@ARGV,
    'config=s'     => \$opt{config},
    'app-root=s'   => \$opt{app_root},
    'app-user=s'   => \$opt{app_user},
    'quiet'        => \$opt{quiet},
    'install-cron' => \$opt{install_cron},
    'dry-run'      => \$opt{dry_run},
) or die usage();

install_cron_and_exit() if $opt{install_cron};

my $config = DesertCMS::Config->load($opt{config});
my $db = DesertCMS::DB->new(config => $config);
$db->migrate unless $opt{dry_run};
my $sites = DesertCMS::Sites->new(config => $config, db => $db);
my $operations = DesertCMS::Operations->new(config => $config, db => $db, sites => $sites);

acquire_lock();
my $result = $opt{dry_run}
    ? { due => 0, reason => 'dry run' }
    : $operations->run_due_scheduled_backups;
log_msg(result_line($result));
exit 0;

sub acquire_lock {
    return if $opt{dry_run};
    my $lock_dir = File::Spec->catdir($config->get('data_dir'), 'locks');
    make_path($lock_dir) unless -d $lock_dir;
    my $lock_file = File::Spec->catfile($lock_dir, 'operations.lock');
    open my $fh, '>', $lock_file or die "cannot open lock $lock_file: $!\n";
    if (!flock($fh, LOCK_EX | LOCK_NB)) {
        log_msg('operations worker already running');
        exit 0;
    }
    $SIG{INT} = $SIG{TERM} = sub { close $fh; exit 1 };
}

sub install_cron_and_exit {
    die "--install-cron must run as root\n" if $> != 0;
    my $cmd = "su -m $opt{app_user} -c " . shell_quote("env DESERTCMS_CONFIG=$opt{config} $^X $opt{app_root}/tools/openbsd-operations-worker.pl --quiet");
    my $marker = '# DesertCMS operations worker';
    my $current = qx(crontab -l 2>/dev/null);
    my @lines = grep { $_ !~ /\Q$marker\E/ && $_ !~ /openbsd-operations-worker\.pl/ } split /\n/, $current;
    push @lines, $marker, "*/15 * * * * $cmd";
    my $body = join("\n", @lines) . "\n";
    open my $pipe, '|-', 'crontab', '-' or die "cannot install root crontab: $!\n";
    print {$pipe} $body;
    close $pipe or die "crontab install failed\n";
    print "installed root cron worker for DesertCMS operations\n";
    exit 0;
}

sub result_line {
    my ($result) = @_;
    return 'scheduled backups disabled' if ($result->{reason} || '') eq 'disabled';
    return 'scheduled backups not due until ' . scalar localtime($result->{next_run_at}) if ($result->{reason} || '') eq 'not due';
    return 'dry run: no scheduled backup work performed' if ($result->{reason} || '') eq 'dry run';
    return 'scheduled backups ran: ' . int($result->{ok_count} || 0) . ' OK, ' . int($result->{failed} || 0) . ' failed'
        if $result->{due};
    return 'no scheduled backup work';
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
usage: $0 [--config /etc/desertcms.conf] [--app-root /usr/local/www/desertcms] [--quiet] [--dry-run] [--install-cron]
USAGE
}
