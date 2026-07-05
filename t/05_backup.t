use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Backup;
use DesertCMS::Config;
use DesertCMS::DB;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;

my $public = "$root/public";
my $originals = "$root/originals";
my $backups = "$root/backups";
my $themes = "$root/themes";
my $data = "$root/data";
make_path(
    $public,
    $originals,
    $backups,
    $data,
    "$themes/default/templates",
    "$themes/default/assets",
);

_write("$public/index.html", "public before\n");
_write("$originals/original.txt", "original before\n");
_write("$themes/default/templates/layout.html", "theme before\n");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Backup Test
site_url = http://localhost
data_dir = $data
db_path = $data/desertcms.sqlite
app_secret_file = $data/app_secret
public_root = $public
originals_dir = $originals
backup_dir = $backups
theme_dir = $themes
admin_asset_dir = $root/admin-assets
tar_tool = tar
secure_cookies = 0
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
$db->dbh->do(
    'INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)',
    undef,
    'backup_test',
    'before',
    time
);

my $archive = DesertCMS::Backup::create_backup($config, $db, undef);
ok(-f $archive, 'created backup archive');
my $restore_test = DesertCMS::Backup::test_backup($config, $archive);
ok($restore_test->{ok}, 'restore test verifies backup archive');
is($restore_test->{db_integrity}, 'ok', 'restore test runs SQLite integrity check');

$db->dbh->do(
    'UPDATE settings SET value = ?, updated_at = ? WHERE key = ?',
    undef,
    'after',
    time,
    'backup_test'
);
_write("$public/index.html", "public after\n");
_write("$originals/original.txt", "original after\n");
_write("$themes/default/templates/layout.html", "theme after\n");

ok(DesertCMS::Backup::restore_backup($config, $db, $archive, undef), 'restored backup archive');

my ($value) = $db->dbh->selectrow_array('SELECT value FROM settings WHERE key = ?', undef, 'backup_test');
is($value, 'before', 'database restored');
is(_read("$public/index.html"), "public before\n", 'public webroot restored');
is(_read("$originals/original.txt"), "original before\n", 'private source assets restored');
is(_read("$themes/default/templates/layout.html"), "theme before\n", 'themes restored');

my @archives = glob "$backups/desertcms-*.tar.gz";
ok(@archives >= 2, 'restore created a pre-restore backup');

done_testing;

sub _write {
    my ($path, $body) = @_;
    my ($volume, $dir) = File::Spec->splitpath($path);
    make_path($dir) unless -d $dir;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}
