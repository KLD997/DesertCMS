#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::DB;

my $command = shift @ARGV || '';
my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);

if ($command eq 'init-db') {
    require DesertCMS::Theme;
    $config->app_secret;
    $db->migrate;
    DesertCMS::Theme::install_default($config);
    print "initialized database at " . $config->get('db_path') . "\n";
    exit 0;
}

if ($command eq 'create-admin') {
    require DesertCMS::Maintenance;
    DesertCMS::Maintenance::create_admin($config, $db, @ARGV);
    exit 0;
}

if ($command eq 'reset-admin') {
    require DesertCMS::Maintenance;
    DesertCMS::Maintenance::reset_admin($config, $db, @ARGV);
    exit 0;
}

if ($command eq 'backup') {
    require DesertCMS::Backup;
    my $path = DesertCMS::Backup::create_backup($config, $db, undef);
    print "created backup $path\n";
    exit 0;
}

if ($command eq 'rebuild') {
    require DesertCMS::Content;
    $db->migrate;
    my $content = DesertCMS::Content->new(config => $config, db => $db);
    my $count = $content->rebuild_all;
    print "rebuilt $count published item(s)\n";
    exit 0;
}

if ($command eq 'media-preview-jobs') {
    require DesertCMS::Media;
    $db->migrate;
    my $limit = 10;
    my $queue = 0;
    my $process = 0;
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg eq '--limit') {
            $limit = shift @ARGV || die "usage: $0 media-preview-jobs [--queue] [--process] [--limit N]\n";
            die "--limit must be a positive integer\n" unless "$limit" =~ /\A[0-9]+\z/ && int($limit) > 0;
            next;
        }
        if ($arg eq '--queue') {
            $queue = 1;
            next;
        }
        if ($arg eq '--process') {
            $process = 1;
            next;
        }
        die "unknown argument: $arg\n";
    }
    $process = 1 unless $queue || $process;
    my $media = DesertCMS::Media->new(config => $config, db => $db);
    if ($queue) {
        my $queued = $media->enqueue_private_preview_jobs(reason => 'maintenance', limit => $limit);
        print "queued $queued->{queued} media preview job(s), skipped $queued->{skipped}\n";
    }
    if ($process) {
        my $processed = $media->process_private_preview_jobs(limit => $limit);
        print "processed $processed->{checked} media preview job(s): $processed->{done} generated, $processed->{failed} failed, $processed->{skipped} skipped\n";
    }
    exit 0;
}

if ($command eq 'geoip-import') {
    require DesertCMS::GeoIP;
    $db->migrate;
    my %args;
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg eq '--blocks') {
            $args{blocks} = shift @ARGV || die "usage: $0 geoip-import [FILE] [--blocks BLOCKS.csv --locations LOCATIONS.csv]\n";
            next;
        }
        if ($arg eq '--locations') {
            $args{locations} = shift @ARGV || die "usage: $0 geoip-import [FILE] [--blocks BLOCKS.csv --locations LOCATIONS.csv]\n";
            next;
        }
        if ($arg eq '--source') {
            $args{source} = shift @ARGV || die "usage: $0 geoip-import [FILE] [--source LABEL]\n";
            next;
        }
        if ($arg eq '--append') {
            $args{append} = 1;
            next;
        }
        die "unknown argument: $arg\n" if $arg =~ /\A-/;
        die "only one GeoIP file can be imported at a time\n" if $args{path};
        $args{path} = $arg;
    }
    die "usage: $0 geoip-import FILE\n       $0 geoip-import --blocks GeoLite2-City-Blocks-IPv4.csv --locations GeoLite2-City-Locations-en.csv\n"
        unless $args{path} || ($args{blocks} && $args{locations});
    my $result = DesertCMS::GeoIP::import_file($db, %args);
    print "imported $result->{imported} GeoIP range(s) from $result->{source} ($result->{format})\n";
    exit 0;
}

if ($command eq 'geoip-refresh-dbip-lite') {
    require DesertCMS::GeoIP;
    $db->migrate;
    my %args;
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg eq '--url') {
            $args{url} = shift @ARGV || die "usage: $0 geoip-refresh-dbip-lite [--url URL] [--observed-only] [--no-backfill]\n";
            next;
        }
        if ($arg eq '--source') {
            $args{source} = shift @ARGV || die "usage: $0 geoip-refresh-dbip-lite [--source LABEL]\n";
            next;
        }
        if ($arg eq '--observed-only') {
            $args{observed_only} = 1;
            next;
        }
        if ($arg eq '--no-backfill') {
            $args{no_backfill} = 1;
            next;
        }
        die "unknown argument: $arg\n";
    }
    my $result = DesertCMS::GeoIP::refresh_dbip_city_lite($config, $db, %args);
    print "downloaded $result->{url} to $result->{path}\n";
    print "imported $result->{imported} GeoIP range(s) from $result->{source} ($result->{format})\n";
    print "observed $result->{observed} public IPv4 address(es), matched $result->{matched}\n"
        if exists $result->{observed};
    print "checked $result->{backfill}{checked} analytics row(s), updated $result->{backfill}{updated}, skipped $result->{backfill}{skipped}\n";
    exit 0;
}

if ($command eq 'geoip-backfill') {
    require DesertCMS::GeoIP;
    $db->migrate;
    my %args;
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg eq '--limit') {
            $args{limit} = shift @ARGV || die "usage: $0 geoip-backfill [--limit N]\n";
            next;
        }
        die "unknown argument: $arg\n";
    }
    my $result = DesertCMS::GeoIP::backfill_events($db, %args);
    print "checked $result->{checked} analytics row(s), updated $result->{updated}, skipped $result->{skipped}\n";
    exit 0;
}

if ($command eq 'restore') {
    require DesertCMS::Backup;
    my $backup = shift @ARGV or die "usage: $0 restore /path/to/backup.tar.gz\n";
    DesertCMS::Backup::restore_backup($config, $db, $backup, undef);
    print "restored backup $backup\n";
    exit 0;
}

die <<"USAGE";
usage: $0 COMMAND

Commands:
  init-db
  create-admin USERNAME [--password PASSWORD]
  reset-admin USERNAME [--password PASSWORD]
  backup
  rebuild
  media-preview-jobs [--queue] [--process] [--limit N]
  geoip-import [--append] FILE
  geoip-import [--append] --blocks GeoLite2-City-Blocks-IPv4.csv --locations GeoLite2-City-Locations-en.csv
  geoip-refresh-dbip-lite [--url URL] [--observed-only] [--no-backfill]
  geoip-backfill [--limit N]
  restore /path/to/backup.tar.gz
USAGE
