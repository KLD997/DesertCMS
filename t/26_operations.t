use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Backup;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Operations;
use DesertCMS::Settings;
use DesertCMS::Sites;
use DesertCMS::Theme;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path(
    "$root/public",
    "$root/originals",
    "$root/backups",
    "$root/themes",
    "$root/admin-assets",
    "$root/data",
    "$root/kaleb-public",
    "$root/kaleb-originals",
    "$root/kaleb-data/backups",
    "$root/kaleb-themes",
    "$root/kaleb-admin-assets",
);

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Operations Test
site_url = https://desertarchives.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $root/themes
admin_asset_dir = $root/admin-assets
secure_cookies = 0
tar_tool = tar
stripe_secret_key = sk_test_secret
postmark_server_token = postmark-token
CONF

local $ENV{DESERTCMS_CONFIG} = $config_path;
my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
DesertCMS::Theme::install_default($config);
DesertCMS::Settings::set_many($config, $db, {
    contributor_domain_root => 'desertarchives.test',
    operations_backup_schedule_enabled => 1,
    operations_backup_interval_hours => 1,
});

my $contrib_config_path = "$root/kaleb.conf";
_write($contrib_config_path, <<"CONF");
site_name = Kaleb Operations
site_url = https://kaleb.desertarchives.test
data_dir = $root/kaleb-data
db_path = $root/kaleb-data/desertcms.sqlite
app_secret_file = $root/kaleb-data/app_secret
public_root = $root/kaleb-public
originals_dir = $root/kaleb-originals
backup_dir = $root/kaleb-data/backups
theme_dir = $root/kaleb-themes
admin_asset_dir = $root/kaleb-admin-assets
secure_cookies = 0
tar_tool = tar
contributor_site_id = kaleb
contributor_domain = kaleb.desertarchives.test
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
my $contrib_db = DesertCMS::DB->new(config => $contrib_config);
$contrib_db->migrate;
DesertCMS::Theme::install_default($contrib_config);

my $sites = DesertCMS::Sites->new(config => $config, db => $db);
$sites->register_existing_site(
    site_id      => 'kaleb',
    domain       => 'kaleb.desertarchives.test',
    display_name => 'Kaleb Operations',
    config_path  => $contrib_config_path,
    data_dir     => "$root/kaleb-data",
    public_root  => "$root/kaleb-public",
);

my $operations = DesertCMS::Operations->new(config => $config, db => $db, sites => $sites);
my $managed = $operations->managed_sites;
is(scalar @{$managed}, 2, 'operations manages master plus contributor subCMS');

my $backup_summary = $operations->backup_all_sites(user_id => undef);
is($backup_summary->{ok_count}, 2, 'backup all creates backups for both sites');
is($backup_summary->{failed}, 0, 'backup all has no failures');
ok(glob("$root/backups/desertcms-*.tar.gz"), 'master backup archive exists');
ok(glob("$root/kaleb-data/backups/desertcms-*.tar.gz"), 'contributor backup archive exists');

my $submit_summary = $operations->submit_all_sitemaps;
is($submit_summary->{failed}, 0, 'sitemap submission skips unconfigured providers without failing');

DesertCMS::Settings::set_many($config, $db, { operations_backup_last_run_at => 0 });
my $scheduled = $operations->run_due_scheduled_backups;
ok($scheduled->{due}, 'scheduled backups run when due');
is($scheduled->{failed}, 0, 'scheduled backups complete without failures');

my $rebuild = $operations->rebuild_all_sites;
is($rebuild->{failed}, 0, 'rebuild all completes for active sites');
ok(-f "$root/public/index.html", 'master public index is rebuilt');
ok(-f "$root/kaleb-public/index.html", 'contributor public index is rebuilt');

my $bundle = $operations->create_support_bundle(created_by_username => 'owner');
ok(-f $bundle->{path}, 'support bundle archive is created');
my $extract = "$root/support-extract";
make_path($extract);
system('tar', '-xzf', $bundle->{path}, '-C', $extract) == 0 or die "cannot extract support bundle";
my $redacted = _read("$extract/configs/master.conf.redacted");
unlike($redacted, qr/sk_test_secret/, 'support bundle redacts Stripe secret key from config');
unlike($redacted, qr/postmark-token/, 'support bundle redacts Postmark token from config');
like($redacted, qr/stripe_secret_key = \[redacted\]/, 'support bundle keeps redacted key names for troubleshooting');

my $app = DesertCMS::App->new;
my $operations_html = _capture_response(sub {
    $app->_settings_operations_page(_request(), { username => 'admin', role => 'owner', user_id => 1 }, 'operations-session');
});
like($operations_html, qr/Operations and Recovery/, 'operations settings page renders');
like($operations_html, qr/module-section-nav" aria-label="Operations sections".*href="\#operations-bulk-actions">Bulk Actions<\/a>.*href="\#operations-backups">Backup Schedule<\/a>.*href="\#operations-restore">Restore Testing<\/a>.*href="\#operations-rollback">Rollback<\/a>.*href="\#operations-support">Support Bundles<\/a>.*href="\#operations-jobs">Recent Jobs<\/a>/s, 'operations page exposes local section navigation');
like($operations_html, qr/id="operations-bulk-actions".*id="operations-backups".*id="operations-restore".*id="operations-rollback".*id="operations-support".*id="operations-jobs"/s, 'operations section nav targets stable page anchors');
like($operations_html, qr/action="\/admin\/settings\/operations\/backup-all"/, 'operations page exposes backup all action');
like($operations_html, qr/action="\/admin\/settings\/operations\/submit-all-sitemaps"/, 'operations page exposes submit all sitemaps action');
like($operations_html, qr/Support Bundle Export/, 'operations page exposes support bundle export');
like($operations_html, qr/class="content-table compact-table admin-card-table"/, 'operations history tables use responsive admin card class');
like($operations_html, qr/admin-empty-state.*No upgrade or rollback jobs yet/s, 'operations page uses clear empty state for missing upgrade jobs');
my $upgrade_html = _capture_response(sub {
    $app->_settings_upgrade_page(_request(), { username => 'admin', role => 'owner', user_id => 1 }, 'upgrade-session');
});
like($upgrade_html, qr/id="upgrade-jobs"/, 'upgrade page gives recent jobs a stable upgrade-specific anchor');
unlike($upgrade_html, qr/id="module-testimonials"/, 'upgrade page no longer reuses testimonial module anchor');

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

sub _capture_response {
    my ($code) = @_;
    my $output = '';
    open my $fh, '>', \$output or die "cannot capture output: $!";
    {
        local *STDOUT = $fh;
        $code->();
    }
    close $fh;
    return $output;
}

sub _request {
    return bless { params => {} }, 'Local::Request';
}

package Local::Request;

sub param {
    my ($self, $key) = @_;
    return $self->{params}{$key};
}

package main;
