use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Settings;
use DesertCMS::Sites;
use DesertCMS::TenantIsolation;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/themes", "$root/admin-assets", "$root/data");
make_path("$root/alexs-data/backups", "$root/alexs-public", "$root/alexs-originals", "$root/alexs-themes", "$root/alexs-admin-assets");
make_path("$root/data/nested", "$root/public/nested", "$root/alexs-data/child", "$root/alexs-public/child");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Tenant Isolation Test
site_url = https://desertarchives.com
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $root/themes
admin_asset_dir = $root/admin-assets
secure_cookies = 0
CONF

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
DesertCMS::Settings::set_many($config, $db, {
    contributor_domain_root => 'desertarchives.com',
});

my $contrib_config_path = "$root/desertcms-alexs.conf";
_write($contrib_config_path, <<"CONF");
site_name = Alex Contributor
site_url = https://alexs.desertarchives.com
data_dir = $root/alexs-data
db_path = $root/alexs-data/desertcms.sqlite
app_secret_file = $root/alexs-data/app_secret
public_root = $root/alexs-public
originals_dir = $root/alexs-originals
backup_dir = $root/alexs-data/backups
theme_dir = $root/alexs-themes
admin_asset_dir = $root/alexs-admin-assets
secure_cookies = 0
contributor_site_id = alexs
contributor_domain = alexs.desertarchives.com
CONF

my $contrib_config = DesertCMS::Config->load($contrib_config_path);
my $contrib_db = DesertCMS::DB->new(config => $contrib_config);
$contrib_db->migrate;
my $login_ts = time - 120;
$contrib_db->dbh->do(
    q{
        INSERT INTO admin_users
            (username, email, role, password_hash, password_algo, created_at, updated_at)
        VALUES
            ('alex', 'alex@example.com', 'owner', 'hash', 'pbkdf2-sha256', ?, ?)
    },
    undef,
    $login_ts,
    $login_ts
);
my $admin_id = $contrib_db->dbh->sqlite_last_insert_rowid;
$contrib_db->dbh->do(
    q{
        INSERT INTO sessions
            (user_id, token_hash, ip_address, user_agent, created_at, expires_at, last_seen_at)
        VALUES
            (?, ?, '127.0.0.1', 'TenantIsolationTest/1.0', ?, ?, ?)
    },
    undef,
    $admin_id,
    'a' x 64,
    $login_ts,
    $login_ts + 3600,
    $login_ts + 60
);

my $sites = DesertCMS::Sites->new(config => $config, db => $db);
$sites->register_existing_site(
    site_id      => 'alexs',
    domain       => 'alexs.desertarchives.com',
    display_name => 'Alex Contributor',
    config_path  => $contrib_config_path,
    data_dir     => "$root/alexs-data",
    public_root  => "$root/alexs-public",
);

my $audit = DesertCMS::TenantIsolation::audit($config, $db);
is($audit->{status}, 'ok', 'valid contributor site passes tenant isolation audit');
is($audit->{issues}, 0, 'valid contributor site has no isolation issues');

my $fleet = $sites->fleet_status(check_dns => 0, check_tls => 0, app_version => 'test');
my ($alexs) = grep { $_->{site_id} eq 'alexs' } @{$fleet->{sites}};
is($alexs->{last_login}, $login_ts, 'fleet status reports contributor subCMS last login');

$db->dbh->do(
    q{
        INSERT INTO contributor_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             status, config_path, data_dir, public_root, created_at, updated_at)
        VALUES
            ('desertcms', 'desertcms.com', 'DesertCMS', '', '', '',
             'active', ?, ?, ?, ?, ?)
    },
    undef,
    $config_path,
    "$root/data",
    "$root/public",
    time,
    time
);
$audit = DesertCMS::TenantIsolation::audit($config, $db);
is($audit->{status}, 'warn', 'standalone master-domain row fails tenant isolation audit');
ok(_has_issue($audit, qr/Site desertcms domain/), 'audit flags a non-subdomain contributor row');

$db->dbh->do(
    q{
        INSERT INTO contributor_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             status, config_path, data_dir, public_root, created_at, updated_at)
        VALUES
            ('shared', 'shared.desertarchives.com', 'Shared Paths', '', '', '',
             'active', ?, ?, ?, ?, ?)
    },
    undef,
    $config_path,
    "$root/data",
    "$root/public",
    time,
    time
);
$audit = DesertCMS::TenantIsolation::audit($config, $db);
ok(_has_issue($audit, qr/Site shared config_path/), 'audit flags reused master config path');
ok(_has_issue($audit, qr/Site shared data_dir/), 'audit flags reused master data root');
ok(_has_issue($audit, qr/Site shared public_root/), 'audit flags reused master public root');

$db->dbh->do(
    q{
        INSERT INTO contributor_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             status, config_path, data_dir, public_root, created_at, updated_at)
        VALUES
            ('nestedmaster', 'nestedmaster.desertarchives.com', 'Nested Master Paths', '', '', '',
             'active', ?, ?, ?, ?, ?)
    },
    undef,
    "$root/desertcms-nestedmaster.conf",
    "$root/data/nested",
    "$root/public/nested",
    time,
    time
);
$audit = DesertCMS::TenantIsolation::audit($config, $db);
ok(_has_issue($audit, qr/Site nestedmaster data_dir/), 'audit flags contributor data nested under master data root');
ok(_has_issue($audit, qr/Site nestedmaster public_root/), 'audit flags contributor public root nested under master public root');

$db->dbh->do(
    q{
        INSERT INTO contributor_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             status, config_path, data_dir, public_root, created_at, updated_at)
        VALUES
            ('nestedcontrib', 'nestedcontrib.desertarchives.com', 'Nested Contributor Paths', '', '', '',
             'active', ?, ?, ?, ?, ?)
    },
    undef,
    "$root/desertcms-nestedcontrib.conf",
    "$root/alexs-data/child",
    "$root/alexs-public/child",
    time,
    time
);
$audit = DesertCMS::TenantIsolation::audit($config, $db);
ok(_has_issue($audit, qr/Site nestedcontrib data_dir nesting/), 'audit flags contributor data nested under another contributor');
ok(_has_issue($audit, qr/Site nestedcontrib public_root nesting/), 'audit flags contributor public root nested under another contributor');

done_testing;

sub _has_issue {
    my ($audit, $pattern) = @_;
    for my $check (@{$audit->{checks} || []}) {
        next unless ($check->{state} || '') eq 'warn';
        return 1 if ($check->{label} || '') =~ $pattern;
    }
    return 0;
}

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}
