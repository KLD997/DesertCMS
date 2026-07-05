use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

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
my $user_id = $auth->create_admin(username => 'Admin', password => 'CorrectHorseBatteryStaple42');
ok($user_id, 'created admin');

my ($bad_user, $bad_reason) = $auth->authenticate(
    username => 'admin',
    password => 'wrong-password',
    ip_address => '127.0.0.1',
);
ok(!$bad_user, 'rejects wrong password');
is($bad_reason, 'invalid', 'wrong password reason');

my ($user, $reason) = $auth->authenticate(
    username => 'admin',
    password => 'CorrectHorseBatteryStaple42',
    ip_address => '127.0.0.1',
);
ok($user, 'authenticates correct password');
is($reason, undef, 'no auth failure reason');

my ($token, $expires) = $auth->create_session(
    user => $user,
    ip_address => '127.0.0.1',
    user_agent => 'test',
);
like($token, qr/\A[0-9a-f]{64}\z/, 'session token format');
ok($expires > time, 'session expires in future');

my $session = $auth->session_from_token($token);
ok($session, 'loads session from token');
is($session->{username}, 'admin', 'session has username');
is($session->{role}, 'owner', 'session has default owner role');

ok(
    $auth->update_admin_credentials(
        user_id  => $session->{user_id},
        username => 'New.Admin',
        password => 'NewCorrectHorseBatteryStaple43',
    ),
    'updates admin credentials'
);

my ($updated_user) = $auth->authenticate(
    username => 'new.admin',
    password => 'NewCorrectHorseBatteryStaple43',
    ip_address => '127.0.0.1',
);
ok($updated_user, 'authenticates updated credentials');

my $duplicate_error = eval {
    $auth->create_admin(username => 'second-admin', password => 'AnotherCorrectHorse44');
    '';
} || $@;
like($duplicate_error, qr/Governance to add scoped users/, 'rejects bootstrap creation after an admin exists');

my $csrf = $auth->csrf_token($token);
ok($auth->verify_csrf($token, $csrf), 'valid csrf token passes');
ok(!$auth->verify_csrf($token, 'bad'), 'invalid csrf token fails');

for (1 .. 3) {
    $auth->authenticate(username => 'new.admin', password => 'bad', ip_address => '10.0.0.1');
}
ok($auth->is_login_locked(username => 'new.admin', ip_address => '10.0.0.1'), 'lockout activates');

my ($locked_user, $locked_reason) = $auth->authenticate(
    username => 'new.admin',
    password => 'NewCorrectHorseBatteryStaple43',
    ip_address => '10.0.0.1',
);
ok(!$locked_user, 'locked login is rejected even with correct password');
is($locked_reason, 'locked', 'locked reason');

my ($audit_count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM audit_log');
ok($audit_count >= 4, 'audit log has auth events');

my $reset_id = $auth->reset_single_admin(
    username => 'setup-admin',
    password => 'TemporaryPassword44',
);
ok($reset_id, 'resets the single admin account');

my ($active_admins) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM admin_users WHERE disabled_at IS NULL');
is($active_admins, 1, 'only one active admin remains after reset');
my $reset_row = $db->dbh->selectrow_hashref('SELECT username, role, force_password_change FROM admin_users WHERE id = ?', undef, $reset_id);
is($reset_row->{username}, 'setup-admin', 'reset account has requested username');
is($reset_row->{role}, 'owner', 'reset account has owner role');
is($reset_row->{force_password_change}, 1, 'reset account requires first-login credential change');
ok(!$auth->session_from_token($token), 'admin reset revokes existing sessions');

my ($reset_user) = $auth->authenticate(
    username => 'setup-admin',
    password => 'TemporaryPassword44',
    ip_address => '127.0.0.2',
);
ok($reset_user, 'reset admin can authenticate');

ok(
    $auth->update_admin_account(
        user_id  => $reset_user->{id},
        username => 'setup-admin',
        email    => 'setup@example.test',
    ),
    'stores admin account email without changing password'
);

my $password_reset = $auth->create_password_reset_token_for_email(
    email      => 'SETUP@example.test',
    ip_address => '127.0.0.3',
);
ok($password_reset, 'creates password reset token for admin email');
like($password_reset->{token}, qr/\A[0-9a-f]{64}\z/, 'password reset token format');

my ($stored_reset_token) = $db->dbh->selectrow_array(
    'SELECT token_hash FROM password_reset_tokens WHERE user_id = ? AND status = ?',
    undef,
    $reset_user->{id},
    'pending'
);
isnt($stored_reset_token, $password_reset->{token}, 'plain password reset token is not stored');
ok($auth->password_reset_from_token($password_reset->{token}), 'loads valid reset token');

ok(
    $auth->consume_password_reset_token(
        token    => $password_reset->{token},
        username => 'final-admin',
        password => 'FinalPasswordReset44',
    ),
    'consumes password reset token'
);
ok(!$auth->password_reset_from_token($password_reset->{token}), 'used reset token cannot be reused');

my ($final_user) = $auth->authenticate(
    username => 'final-admin',
    password => 'FinalPasswordReset44',
    ip_address => '127.0.0.4',
);
ok($final_user, 'authenticates with reset password');

done_testing;
