use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Version;

my $root = tempdir(CLEANUP => 1);
make_path($root);
my $version_path = File::Spec->catfile($root, 'VERSION');

open my $fh, '>', $version_path or die "cannot write $version_path: $!";
print {$fh} "9.8.7\n";
close $fh;

is(DesertCMS::Version::version_file($root), $version_path, 'version_file points at VERSION under app root');
is(DesertCMS::Version::from_app_root($root), '9.8.7', 'from_app_root reads and trims VERSION');
is(DesertCMS::Version::from_file($version_path), '9.8.7', 'from_file reads explicit version file');
is(DesertCMS::Version::from_app_root(File::Spec->catdir($root, 'missing')), 'unknown', 'missing VERSION defaults to unknown');
is(DesertCMS::Version::from_app_root(File::Spec->catdir($root, 'missing'), fallback => '1.0'), '1.0', 'missing VERSION can use a caller fallback');

my $current = DesertCMS::Version::current();
like($current, qr/\A\d+\.\d+(?:\.\d+)?\z/, 'current version reads the app VERSION file');

done_testing;
