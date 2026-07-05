use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::Upgrade;

my $root = tempdir(CLEANUP => 1);
my $data = File::Spec->catdir($root, 'data');
make_path($data);

my $config_path = File::Spec->catfile($root, 'desertcms.conf');
_write($config_path, <<"CONF");
site_name = Upgrade Test
site_url = http://localhost
data_dir = $data
db_path = $data/desertcms.sqlite
public_root = $root/public
originals_dir = $data/originals
backup_dir = $data/backups
theme_dir = $data/themes
admin_asset_dir = $root/admin-assets
tar_tool = tar
CONF

my $config = DesertCMS::Config->load($config_path);
my $release_parent = File::Spec->catdir($root, 'release');
my $release_root = File::Spec->catdir($release_parent, 'desertcms');
for my $required (DesertCMS::Upgrade::required_release_files()) {
    my $path = File::Spec->catfile($release_root, split m{/}, $required);
    _write($path, "# $required\n");
}
_write(File::Spec->catfile($release_root, 'README.md'), "DesertCMS test release\n");

my $archive = File::Spec->catfile($root, 'desertcms-openbsd-runtime-test.tar.gz');
my $tar_ok = system('tar', '-czf', $archive, '-C', $release_parent, 'desertcms') == 0 && -f $archive;
plan skip_all => 'tar is required for upgrade archive tests' unless $tar_ok;

my $validation = DesertCMS::Upgrade::validate_archive($config, $archive);
is($validation->{release_root}, 'desertcms', 'detects release root prefix');
ok($validation->{member_count} >= 7, 'counts archive members');
is($validation->{release_trust}, 'unsigned-owner-only', 'unsigned archive remains owner-only compatible without signing config');

my $strict_config_path = File::Spec->catfile($root, 'desertcms-strict-upgrades.conf');
_write($strict_config_path, <<"CONF");
site_name = Upgrade Test
site_url = http://localhost
data_dir = $data
db_path = $data/desertcms.sqlite
public_root = $root/public
originals_dir = $data/originals
backup_dir = $data/backups
theme_dir = $data/themes
admin_asset_dir = $root/admin-assets
tar_tool = tar
upgrade_require_signed_releases = 1
CONF
my $strict_config = DesertCMS::Config->load($strict_config_path);
my $strict_ok = eval { DesertCMS::Upgrade::validate_archive($strict_config, $archive); 1 };
ok(!$strict_ok, 'strict upgrade signing rejects unsigned archives');
like($@, qr/upgrade_signify_public_key/, 'strict signing error names missing public key');

open my $fh, '<:raw', $archive or die "cannot read archive: $!";
local $/;
my $content = <$fh>;
close $fh;

my $job = DesertCMS::Upgrade::stage_upload(
    $config,
    upload => {
        filename     => 'desertcms-openbsd-runtime-test.tar.gz',
        content_type => 'application/gzip',
        content      => $content,
    },
    submitted_by_user_id  => 7,
    submitted_by_username => 'admin',
);

is($job->{status}, 'queued', 'stages upload as queued job');
ok(-f $job->{archive}, 'writes staged archive');
like($job->{sha256}, qr/\A[0-9a-f]{64}\z/, 'records archive sha256');
is($job->{submitted_by_user_id}, 7, 'records submitter id');
is($job->{release_trust}, 'unsigned-owner-only', 'records owner-only unsigned trust state');

my $latest = DesertCMS::Upgrade::latest_jobs($config, limit => 1)->[0];
is($latest->{id}, $job->{id}, 'latest job reads staged job');
is(scalar @{DesertCMS::Upgrade::queued_jobs($config)}, 1, 'queued job appears in queue');

my $duplicate = DesertCMS::Upgrade::stage_upload(
    $config,
    upload => {
        filename     => 'desertcms-openbsd-runtime-test-copy.tar.gz',
        content_type => 'application/gzip',
        content      => $content,
    },
);
is($duplicate->{id}, $job->{id}, 'duplicate archive upload reuses existing job');
ok($duplicate->{reused}, 'duplicate archive is flagged as reused');
is(scalar @{DesertCMS::Upgrade::latest_jobs($config, limit => 10)}, 1, 'duplicate archive does not create another job');

my $rollback_dir = DesertCMS::Upgrade::app_backup_dir($config);
make_path($rollback_dir);
my $rollback_archive = File::Spec->catfile($rollback_dir, 'desertcms-app-20260630-010203.tar.gz');
copy($archive, $rollback_archive) or die "cannot copy rollback archive: $!";
my $rollbacks = DesertCMS::Upgrade::available_rollbacks($config);
ok((grep { $_->{filename} eq 'desertcms-app-20260630-010203.tar.gz' } @{$rollbacks}), 'lists app rollback backups');
my $rollback_job = DesertCMS::Upgrade::queue_rollback(
    $config,
    filename => 'desertcms-app-20260630-010203.tar.gz',
    submitted_by_user_id => 8,
    submitted_by_username => 'operator',
);
is($rollback_job->{kind}, 'rollback', 'queues rollback job kind');
is($rollback_job->{status}, 'queued', 'rollback job is queued');
is($rollback_job->{submitted_by_user_id}, 8, 'rollback job records submitter');
my $duplicate_rollback = DesertCMS::Upgrade::queue_rollback(
    $config,
    filename => 'desertcms-app-20260630-010203.tar.gz',
);
is($duplicate_rollback->{id}, $rollback_job->{id}, 'duplicate rollback target reuses existing job');
ok($duplicate_rollback->{reused}, 'duplicate rollback is flagged as reused');

my $bad_parent = File::Spec->catdir($root, 'bad-release');
make_path($bad_parent);
_write(File::Spec->catfile($bad_parent, 'note.txt'), "not a release\n");
my $bad_archive = File::Spec->catfile($root, 'bad.tar.gz');
system('tar', '-czf', $bad_archive, '-C', $bad_parent, 'note.txt') == 0
    or die "cannot create bad archive";
my $bad_ok = eval { DesertCMS::Upgrade::validate_archive($config, $bad_archive); 1 };
ok(!$bad_ok, 'rejects archive without DesertCMS release files');
like($@, qr/not a DesertCMS release bundle/, 'reports invalid release bundle');

my $extension_ok = eval {
    DesertCMS::Upgrade::stage_upload(
        $config,
        upload => {
            filename     => 'desertcms.zip',
            content_type => 'application/zip',
            content      => 'zip',
        },
    );
    1;
};
ok(!$extension_ok, 'rejects non tar.gz uploads');

done_testing;

sub _write {
    my ($path, $body) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}
