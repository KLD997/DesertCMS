use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::SEO;
use DesertCMS::Settings;
use DesertCMS::Util qw(now);

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/data", "$root/originals", "$root/backups");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = SEO Test
site_url = https://archive.example
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
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

DesertCMS::Settings::set_many($config, $db, {
    google_oauth_client_id => 'client-123',
    google_oauth_client_secret => 'secret-456',
    google_search_console_property => 'https://archive.example/',
});

my $settings = DesertCMS::Settings::all($config, $db);
my $auth_url = DesertCMS::SEO::google_auth_url($config, $settings, state => 'state-token');
like($auth_url, qr{client_id=client-123}, 'Google OAuth URL includes client id');
like($auth_url, qr{redirect_uri=https%3A%2F%2Farchive\.example%2Fadmin%2Fsite-settings%2Fgoogle%2Fcallback}, 'Google OAuth URL includes admin callback');
like($auth_url, qr{scope=https%3A%2F%2Fwww\.googleapis\.com%2Fauth%2Fwebmasters}, 'Google OAuth URL requests Search Console scope');
like($auth_url, qr{state=state-token}, 'Google OAuth URL includes CSRF state');

my $token_http = Local::SEOHTTP->new(
    { success => 1, status => 200, content => '{"access_token":"google-access","refresh_token":"google-refresh","expires_in":3600,"scope":"https://www.googleapis.com/auth/webmasters"}' },
);
DesertCMS::SEO::exchange_google_code($config, $db, code => 'auth-code', http => $token_http);
$settings = DesertCMS::Settings::all($config, $db);
is($settings->{google_oauth_access_token}, 'google-access', 'stores Google access token');
is($settings->{google_oauth_refresh_token}, 'google-refresh', 'stores Google refresh token');
ok(DesertCMS::SEO::google_connected($settings), 'reports Google connected');
is($token_http->{post_forms}[0]{url}, 'https://oauth2.googleapis.com/token', 'exchanges code at Google token endpoint');

_write_sitemap($config, [
    'https://archive.example/',
    'https://archive.example/posts/one/',
]);

DesertCMS::Settings::set_many($config, $db, {
    google_oauth_access_token => 'fresh-access',
    google_oauth_expires_at => now() + 3600,
});
my $google_http = Local::SEOHTTP->new(
    { success => 1, status => 204, content => '{}' },
);
my $google_result = DesertCMS::SEO::submit_google_sitemap($config, $db, http => $google_http);
is($google_result->{engine}, 'Google Search Console', 'Google submit returns engine label');
is($google_http->{requests}[0]{method}, 'PUT', 'Google sitemap submit uses PUT');
like($google_http->{requests}[0]{url}, qr{sites/https%3A%2F%2Farchive\.example%2F/sitemaps/https%3A%2F%2Farchive\.example%2Fsitemap\.xml}, 'Google submit URL encodes property and sitemap');
is($google_http->{requests}[0]{args}{headers}{Authorization}, 'Bearer fresh-access', 'Google submit sends bearer token');
$settings = DesertCMS::Settings::all($config, $db);
is($settings->{google_sitemap_last_status}, 'submitted', 'stores Google submit status');

DesertCMS::Settings::set_many($config, $db, {
    indexnow_enabled => 1,
    indexnow_key => 'abc123xyz',
});
my $indexnow_http = Local::SEOHTTP->new(
    { success => 1, status => 202, content => '{}' },
);
my $indexnow_result = DesertCMS::SEO::submit_indexnow($config, $db, http => $indexnow_http);
is($indexnow_result->{engine}, 'IndexNow', 'IndexNow submit returns engine label');
is($indexnow_result->{urls}, 2, 'IndexNow submits sitemap URL count');
my $key_file = File::Spec->catfile($root, 'public', 'abc123xyz.txt');
ok(-f $key_file, 'writes IndexNow key file');
is(_read($key_file), 'abc123xyz', 'IndexNow key file contains key');
my $payload = decode_json($indexnow_http->{posts}[0]{args}{content});
is($payload->{host}, 'archive.example', 'IndexNow payload includes host');
is($payload->{key}, 'abc123xyz', 'IndexNow payload includes key');
is($payload->{keyLocation}, 'https://archive.example/abc123xyz.txt', 'IndexNow payload includes key location');
is_deeply($payload->{urlList}, ['https://archive.example/', 'https://archive.example/posts/one/'], 'IndexNow payload includes sitemap URLs');
$settings = DesertCMS::Settings::all($config, $db);
is($settings->{indexnow_last_status}, 'submitted', 'stores IndexNow submit status');
is($settings->{indexnow_last_url_count}, 2, 'stores IndexNow submitted URL count');

done_testing;

sub _write_sitemap {
    my ($config, $urls) = @_;
    my $path = File::Spec->catfile($config->get('public_root'), 'sitemap.xml');
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} qq{<?xml version="1.0" encoding="UTF-8"?>\n<urlset>\n};
    print {$fh} "  <url><loc>$_</loc></url>\n" for @{$urls};
    print {$fh} "</urlset>\n";
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

package Local::SEOHTTP;

sub new {
    my ($class, @responses) = @_;
    return bless {
        responses => \@responses,
        post_forms => [],
        requests => [],
        posts => [],
    }, $class;
}

sub _next {
    my ($self) = @_;
    return shift @{$self->{responses}} || { success => 1, status => 200, content => '{}' };
}

sub post_form {
    my ($self, $url, $form) = @_;
    push @{$self->{post_forms}}, { url => $url, form => $form };
    return $self->_next;
}

sub request {
    my ($self, $method, $url, $args) = @_;
    push @{$self->{requests}}, { method => $method, url => $url, args => $args || {} };
    return $self->_next;
}

sub post {
    my ($self, $url, $args) = @_;
    push @{$self->{posts}}, { url => $url, args => $args || {} };
    return $self->_next;
}
