use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Email qw(
    send_postmark
    resolved_postmark_settings
    postmark_https_transport_status
    email_readiness
    email_delivery_logs
    record_postmark_webhook
    postmark_template_previews
    generate_webhook_token
);
use DesertCMS::Settings;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/themes", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Email Test
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

local $ENV{DESERTCMS_CONFIG} = $config_path;
my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

my $webhook_token = generate_webhook_token();
DesertCMS::Settings::set_many($config, $db, {
    site_name => 'Email Test',
    postmark_sender_mode => 'site',
    postmark_from_email => 'join@example.com',
    postmark_server_token => 'server-token',
    postmark_webhook_token => $webhook_token,
    contributor_request_recipient_email => 'review@example.com',
});

{
    no warnings 'redefine';
    *DesertCMS::Email::postmark_https_transport_status = sub {
        return {
            ok           => 1,
            missing      => [],
            detail       => 'Perl HTTPS transport is available for Postmark.',
            install_hint => '',
        };
    };
}

{
    no warnings 'redefine';
    local *HTTP::Tiny::post = sub {
        return {
            success => 1,
            status  => 200,
            content => encode_json({ MessageID => 'postmark-message-1', SubmittedAt => '2026-06-30T12:00:00Z' }),
        };
    };
    my ($sent, $reason) = send_postmark(
        $config,
        $db,
        to => 'reader@example.com',
        email_type => 'postmark_test',
        subject => 'Test message',
        text_body => 'Testing Postmark.',
    );
    ok($sent, 'send_postmark reports success');
    is($reason, 'sent', 'send_postmark keeps compatible success reason');
}

my $logs = email_delivery_logs($config, $db, limit => 5);
is($logs->[0]{message_id}, 'postmark-message-1', 'successful send stores Postmark message id');
is($logs->[0]{email_type}, 'postmark_test', 'successful send stores email type');
is($logs->[0]{status}, 'sent', 'successful send stores sent status');

my $webhook = record_postmark_webhook(
    $config,
    $db,
    token => $webhook_token,
    body => encode_json({
        RecordType => 'Bounce',
        MessageID  => 'postmark-message-1',
        Email      => 'reader@example.com',
        Description => 'Mailbox unavailable',
    }),
);
ok($webhook->{ok}, 'valid Postmark webhook is accepted');
$logs = email_delivery_logs($config, $db, limit => 1);
is($logs->[0]{status}, 'bounced', 'bounce webhook updates delivery status');
like($logs->[0]{reason}, qr/Mailbox unavailable/, 'bounce webhook stores reason');

my $bad_webhook = record_postmark_webhook(
    $config,
    $db,
    token => 'bad-token',
    body => '{}',
);
is($bad_webhook->{status}, 403, 'invalid webhook token is rejected');

my $readiness = email_readiness($config, $db);
my %check = map { $_->{key} => $_ } @{ $readiness->{checks} };
is($check{sender}{state}, 'ok', 'readiness sees configured sender');
is($check{token}{state}, 'ok', 'readiness sees server token');
is($check{https_transport}{state}, 'ok', 'readiness sees available HTTPS transport');
is($check{webhook}{state}, 'ok', 'readiness sees webhook endpoint token');
is($check{deliverability}{state}, 'warn', 'readiness surfaces recent bounce');

{
    no warnings 'redefine';
    my $called_http = 0;
    local *DesertCMS::Email::postmark_https_transport_status = sub {
        return {
            ok           => 0,
            missing      => [ 'IO::Socket::SSL 1.42 (p5-IO-Socket-SSL)', 'Net::SSLeay 1.49 (p5-Net-SSLeay)' ],
            install_hint => 'OpenBSD: doas pkg_add p5-IO-Socket-SSL p5-Net-SSLeay, then restart desertcms_slowcgi.',
            detail       => 'HTTPS transport is not available. Install OpenBSD packages p5-IO-Socket-SSL and p5-Net-SSLeay, then restart desertcms_slowcgi.',
        };
    };
    local *HTTP::Tiny::post = sub {
        $called_http = 1;
        return { success => 1, status => 200, content => '{}' };
    };
    my ($sent, $reason) = send_postmark(
        $config,
        $db,
        to => 'reader@example.com',
        email_type => 'postmark_test',
        subject => 'Missing HTTPS transport',
        text_body => 'This should fail before the Postmark HTTPS call.',
    );
    ok(!$sent, 'send_postmark reports missing HTTPS transport');
    ok(!$called_http, 'missing HTTPS transport stops before HTTP::Tiny post');
    like($reason, qr/p5-IO-Socket-SSL/, 'transport failure names IO::Socket::SSL OpenBSD package');
    like($reason, qr/p5-Net-SSLeay/, 'transport failure names Net::SSLeay OpenBSD package');
}

$logs = email_delivery_logs($config, $db, limit => 1);
like($logs->[0]{reason}, qr/p5-IO-Socket-SSL/, 'delivery log stores HTTPS transport package hint');
like($logs->[0]{provider_response_json}, qr/p5-Net-SSLeay/, 'delivery log stores missing transport modules');

{
    no warnings 'redefine';
    local *DesertCMS::Email::postmark_https_transport_status = sub {
        return {
            ok           => 0,
            missing      => [ 'IO::Socket::SSL 1.42 (p5-IO-Socket-SSL)' ],
            install_hint => 'OpenBSD: doas pkg_add p5-IO-Socket-SSL p5-Net-SSLeay, then restart desertcms_slowcgi.',
            detail       => 'HTTPS transport is not available. Install OpenBSD packages p5-IO-Socket-SSL and p5-Net-SSLeay, then restart desertcms_slowcgi.',
        };
    };
    my $transport_readiness = email_readiness($config, $db);
    my %transport_check = map { $_->{key} => $_ } @{ $transport_readiness->{checks} };
    is($transport_check{https_transport}{state}, 'warn', 'readiness warns when HTTPS transport modules are missing');
    like($transport_check{https_transport}{detail}, qr/p5-IO-Socket-SSL/, 'readiness includes HTTPS transport install hint');
}

{
    no warnings 'redefine';
    local *HTTP::Tiny::post = sub {
        return {
            success => 0,
            status  => 599,
            reason  => 'Internal Exception',
            content => 'TLS handshake failed during diagnostic send',
        };
    };
    my ($sent, $reason) = send_postmark(
        $config,
        $db,
        to => 'reader@example.com',
        email_type => 'postmark_test',
        subject => 'Transport failure',
        text_body => 'This should fail before Postmark accepts it.',
    );
    ok(!$sent, 'send_postmark reports transport failure');
    like($reason, qr/TLS handshake failed/, 'transport failure reason includes response content');
}

$logs = email_delivery_logs($config, $db, limit => 1);
like($logs->[0]{reason}, qr/TLS handshake failed/, 'delivery log stores transport failure detail');
like($logs->[0]{provider_response_json}, qr/TLS handshake failed/, 'delivery log stores transport response excerpt');

my $templates = postmark_template_previews($config, $db);
ok(@{$templates} >= 5, 'template preview includes contributor email templates');
like(join(' ', map { $_->{label} } @{$templates}), qr/Contributor invite/, 'template preview includes invite template');

my $master_root = tempdir(CLEANUP => 1);
$master_root =~ s{\\}{/}g;
make_path("$master_root/public", "$master_root/originals", "$master_root/backups", "$master_root/themes", "$master_root/admin-assets", "$master_root/data");
my $master_config_path = "$master_root/master.conf";
_write($master_config_path, <<"CONF");
site_name = Master Email Test
site_url = https://master.example
data_dir = $master_root/data
db_path = $master_root/data/desertcms.sqlite
app_secret_file = $master_root/data/app_secret
public_root = $master_root/public
originals_dir = $master_root/originals
backup_dir = $master_root/backups
theme_dir = $master_root/themes
admin_asset_dir = $master_root/admin-assets
secure_cookies = 0
CONF
my $master_config = DesertCMS::Config->load($master_config_path);
my $master_db = DesertCMS::DB->new(config => $master_config);
$master_db->migrate;
DesertCMS::Settings::set_many($master_config, $master_db, {
    postmark_from_email => 'master@example.com',
    postmark_server_token => 'master-token',
});

my $contrib_root = tempdir(CLEANUP => 1);
$contrib_root =~ s{\\}{/}g;
make_path("$contrib_root/public", "$contrib_root/originals", "$contrib_root/backups", "$contrib_root/themes", "$contrib_root/admin-assets", "$contrib_root/data");
my $contrib_config_path = "$contrib_root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Email Test
site_url = https://alexs.example
data_dir = $contrib_root/data
db_path = $contrib_root/data/desertcms.sqlite
app_secret_file = $contrib_root/data/app_secret
public_root = $contrib_root/public
originals_dir = $contrib_root/originals
backup_dir = $contrib_root/backups
theme_dir = $contrib_root/themes
admin_asset_dir = $contrib_root/admin-assets
secure_cookies = 0
contributor_site_id = alexs
contributor_domain = alexs.example
master_config_path = $master_config_path
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
my $contrib_db = DesertCMS::DB->new(config => $contrib_config);
$contrib_db->migrate;
DesertCMS::Settings::set_many($contrib_config, $contrib_db, {
    postmark_sender_mode => 'site',
    postmark_from_email => 'local@example.com',
    postmark_server_token => 'local-token',
});
my $resolved = resolved_postmark_settings($contrib_config, $contrib_db);
is($resolved->{source}, 'master', 'contributor local Postmark sender is ignored until the plan allows it');
is($resolved->{from_email}, 'master@example.com', 'inherited sender uses master from email');
is($resolved->{token}, 'master-token', 'inherited sender uses master token');
DesertCMS::Settings::set_many($contrib_config, $contrib_db, {
    contributor_allow_postmark_sender_override => 1,
});
$resolved = resolved_postmark_settings($contrib_config, $contrib_db);
is($resolved->{source}, 'site', 'contributor can use local Postmark sender when the plan allows it');
is($resolved->{from_email}, 'local@example.com', 'allowed contributor sender uses local from email');
is($resolved->{token}, 'local-token', 'allowed contributor sender uses local token');

my $app = DesertCMS::App->new;
my $html = _capture_response(sub {
    $app->_settings_contributors_page(undef, { username => 'admin' }, 'email-session');
});
like($html, qr/Email Deliverability/, 'contributors page renders deliverability setup');
like($html, qr/Bounce\/spam webhook/, 'contributors page renders webhook readiness');
like($html, qr/Template Preview/, 'contributors page renders template preview');
like($html, qr/Delivery Log/, 'contributors page renders delivery log');
like($html, qr/class="delivery-log-scroll"/, 'contributors page caps delivery log in a scroll section');

SKIP: {
    skip 'OpenBSD unveil check only runs on OpenBSD', 1 unless $^O eq 'openbsd';
    my $code = <<'PERL';
use strict;
use warnings;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Security qw(apply_openbsd_sandbox);
use DesertCMS::Email qw(postmark_https_transport_status);
my $config = DesertCMS::Config->load($ENV{DESERTCMS_CONFIG});
my $db = DesertCMS::DB->new(config => $config);
apply_openbsd_sandbox($config, $db);
my $status = postmark_https_transport_status();
die $status->{detail} unless $status->{ok};
PERL
    local $ENV{DESERTCMS_CONFIG} = $config_path;
    my $status = system($^X, "-I$FindBin::Bin/../lib", '-e', $code);
    is($status, 0, 'Postmark HTTPS modules remain visible after OpenBSD pledge/unveil');
}

{
    no warnings 'redefine';
    local *DesertCMS::App::send_postmark = sub { return (1, 'sent') };
    DesertCMS::HTTP->reset_response_state;
    my $redirect = _capture_response(sub {
        $app->_settings_contributors_test_email(_request(test_email => 'reader@example.com'), { username => 'admin', user_id => 1 }, 'email-session');
    });
    like($redirect, qr/Status: 303 See Other/, 'test email action redirects after POST');
    like($redirect, qr{Location: /admin/settings/contributors\?notice=postmark-test-sent}, 'test email redirect carries success notice');
}

done_testing;

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
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
    my (%params) = @_;
    return bless { params => \%params }, 'Local::Request';
}

package Local::Request;

sub param {
    my ($self, $key) = @_;
    return $self->{params}{$key};
}

package main;
