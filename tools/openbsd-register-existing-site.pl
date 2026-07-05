#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Settings;
use DesertCMS::Sites;

my %opt = (
    config => $ENV{DESERTCMS_CONFIG} || '/etc/desertcms.conf',
);

GetOptionsFromArray(
    \@ARGV,
    'config=s'       => \$opt{config},
    'site-id=s'      => \$opt{site_id},
    'domain=s'       => \$opt{domain},
    'display-name=s' => \$opt{display_name},
    'first-name=s'   => \$opt{first_name},
    'last-initial=s' => \$opt{last_initial},
    'email=s'        => \$opt{email},
    'domain-root=s'  => \$opt{domain_root},
) or die usage();

die usage() unless $opt{site_id} && $opt{domain};

local $ENV{DESERTCMS_CONFIG} = $opt{config};
my $config = DesertCMS::Config->load($opt{config});
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

if (defined $opt{domain_root} && length $opt{domain_root}) {
    DesertCMS::Settings::set_many($config, $db, {
        contributor_domain_root => $opt{domain_root},
    });
}

my $sites = DesertCMS::Sites->new(config => $config, db => $db);
$sites->register_existing_site(
    site_id            => $opt{site_id},
    domain             => $opt{domain},
    display_name       => $opt{display_name} || $opt{domain},
    owner_first_name   => $opt{first_name} || '',
    owner_last_initial => $opt{last_initial} || '',
    owner_email        => $opt{email} || '',
);

print "registered $opt{domain}\n";

sub usage {
    return <<"USAGE";
usage: $0 --site-id ID --domain DOMAIN [--display-name NAME] [--domain-root DOMAIN]
USAGE
}
