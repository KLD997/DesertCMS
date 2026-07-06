#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::OpenBSDHostIntegration;

my %opt = (
    app_root     => "$FindBin::Bin/..",
    staging_root => '/tmp/desertcms-v3-test',
    staging_host => 'v3-integration.example.test',
    expected_branch => 'codex/v3-development',
    config       => '',
    dry_run      => 1,
    help         => 0,
);

GetOptionsFromArray(
    \@ARGV,
    'app-root=s'     => \$opt{app_root},
    'staging-root=s' => \$opt{staging_root},
    'staging-host=s' => \$opt{staging_host},
    'expected-branch=s' => \$opt{expected_branch},
    'config=s'       => \$opt{config},
    'dry-run'        => sub { $opt{dry_run} = 1 },
    'run'            => sub { $opt{dry_run} = 0 },
    'help'           => \$opt{help},
) or die usage();

if ($opt{help}) {
    print usage();
    exit 0;
}

my $harness = DesertCMS::OpenBSDHostIntegration->new(
    app_root     => $opt{app_root},
    staging_root => $opt{staging_root},
    staging_host => $opt{staging_host},
    expected_branch => $opt{expected_branch},
    ($opt{config} ? (config_path => $opt{config}) : ()),
);

my $results = $harness->run(dry_run => $opt{dry_run});
my $failed = 0;
for my $step (@{$results}) {
    my $line = sprintf '[%s] %s', $step->{status}, $step->{label};
    $line .= ' :: ' . $harness->command_line($step) if $step->{command} || $step->{internal};
    $line .= ' :: ' . $step->{detail} if length($step->{detail} || '');
    print "$line\n";
    $failed = 1 if ($step->{status} || '') eq 'failed';
}
exit($failed ? 1 : 0);

sub usage {
    return <<"USAGE";
usage: $0 [--dry-run] [--run] [--app-root PATH] [--staging-root /tmp/desertcms-v3-test] [--staging-host v3-integration.example.test] [--expected-branch codex/v3-development] [--config PATH]

Default mode is --dry-run and only prints the non-live v3 OpenBSD integration plan.
Real execution requires branch codex/v3-development, OpenBSD, DESERTCMS_OPENBSD_INTEGRATION=1, and a staging-only example.test hostname.
Uploaded staging bundles without .git may include .desertcms-v3-branch containing codex/v3-development.
USAGE
}
