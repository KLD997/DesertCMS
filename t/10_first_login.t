use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Auth;
use DesertCMS::Config;
use DesertCMS::DB;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/themes", "$root/admin-assets");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Test Site
site_url = http://localhost
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $root/themes
admin_asset_dir = $root/admin-assets
session_cookie = da_session
session_ttl_seconds = 7200
secure_cookies = 0
login_lockout_seconds = 900
login_max_failures = 3
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

my $auth = DesertCMS::Auth->new(config => $config, db => $db);
my $user_id = $auth->create_admin(
    username => 'setup-admin',
    password => 'TemporaryPassword42',
    force_password_change => 1,
);
ok($user_id, 'created forced-change admin');

my ($user) = $auth->authenticate(
    username => 'setup-admin',
    password => 'TemporaryPassword42',
    ip_address => '127.0.0.1',
);
my ($token) = $auth->create_session(user => $user, ip_address => '127.0.0.1', user_agent => 'test');

my $admin_response = _run_app(
    method => 'GET',
    path   => '/admin',
    cookie => "da_session=$token",
);
like($admin_response, qr/^Status:\s*303\b/m, 'forced-change admin is redirected');
like($admin_response, qr/^Location:\s*\/admin\/account\/setup\b/m, 'redirects to account setup');

my $setup_response = _run_app(
    method => 'GET',
    path   => '/admin/account/setup',
    cookie => "da_session=$token",
);
like($setup_response, qr/Set your admin account/, 'renders first-login setup form');

my $csrf = $auth->csrf_token($token);
my $body = join '&',
    'csrf_token=' . _url_escape($csrf),
    'username=owner',
    'password=PermanentPassword42',
    'password_confirm=PermanentPassword42';
my $save_response = _run_app(
    method => 'POST',
    path   => '/admin/account/setup',
    cookie => "da_session=$token",
    body   => $body,
);
like($save_response, qr/^Status:\s*303\b/m, 'setup save redirects');
like($save_response, qr/^Location:\s*\/admin\b/m, 'setup save redirects to dashboard');

my $row = $db->dbh->selectrow_hashref('SELECT username, force_password_change FROM admin_users WHERE id = ?', undef, $user_id);
is($row->{username}, 'owner', 'setup updates username');
is($row->{force_password_change}, 0, 'setup clears force-change flag');

my ($updated_user) = $auth->authenticate(
    username => 'owner',
    password => 'PermanentPassword42',
    ip_address => '127.0.0.1',
);
ok($updated_user, 'updated login works');

done_testing;

sub _run_app {
    my (%args) = @_;
    my $body = $args{body} || '';
    local %ENV = (
        %ENV,
        REQUEST_METHOD => $args{method} || 'GET',
        REQUEST_URI    => $args{path} || '/admin',
        QUERY_STRING   => '',
        CONTENT_TYPE   => length($body) ? 'application/x-www-form-urlencoded' : '',
        CONTENT_LENGTH => length($body),
        HTTP_COOKIE    => $args{cookie} || '',
        HTTP_USER_AGENT => 'first-login-test',
        REMOTE_ADDR    => '127.0.0.1',
    );
    my $input = $body;
    my $output = '';
    open my $in, '<', \$input or die "cannot open request body: $!";
    open my $out, '>', \$output or die "cannot capture response: $!";
    local *STDIN = $in;
    local *STDOUT = $out;
    DesertCMS::App->new->run;
    close $out;
    return $output;
}

sub _url_escape {
    my ($value) = @_;
    $value =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/eg;
    return $value;
}
