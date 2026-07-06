use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use MIME::Base64 qw(encode_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Accounts;
use DesertCMS::LiveStreaming;
use DesertCMS::Notifications;
use DesertCMS::OpenBSDHostIntegration;
use DesertCMS::Realtime;
use DesertCMS::SecurityCenter;

{
    package LocalSecurityConfig;
    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }
    sub get {
        my ($self, $key) = @_;
        return $self->{$key};
    }
    sub app_secret {
        my ($self) = @_;
        return $self->{app_secret} || 'local-security-secret';
    }
}

{
    package LocalJwksHTTP;
    sub new {
        my ($class, @responses) = @_;
        return bless { responses => \@responses, gets => 0 }, $class;
    }
    sub get {
        my ($self) = @_;
        $self->{gets}++;
        my $jwks = shift @{ $self->{responses} };
        $jwks ||= { keys => [] };
        return {
            success => 1,
            status  => 200,
            headers => { 'cache-control' => 'max-age=120' },
            content => JSON::PP::encode_json($jwks),
        };
    }
}

{
    package LocalOIDCDiscoveryHTTP;
    sub new {
        my ($class, %metadata) = @_;
        return bless { metadata => \%metadata, gets => 0 }, $class;
    }
    sub get {
        my ($self) = @_;
        $self->{gets}++;
        my $metadata = $self->{metadata};
        return {
            success => 1,
            status  => 200,
            content => JSON::PP::encode_json({
                issuer                 => $metadata->{issuer},
                authorization_endpoint => $metadata->{authorization_endpoint} || 'https://idp.example.test/authorize',
                token_endpoint         => $metadata->{token_endpoint} || 'https://idp.example.test/token',
                userinfo_endpoint      => $metadata->{userinfo_endpoint} || 'https://idp.example.test/userinfo',
                jwks_uri               => $metadata->{jwks_uri} || 'https://idp.example.test/certs',
            }),
        };
    }
}

{
    package LocalSecurityDB;
    sub dbh { return $_[0] }
    sub selectall_arrayref { return [] }
    sub selectrow_array { return 0 }
}

{
    package LocalStreamingSecurityDB;
    sub dbh { return $_[0] }
    sub selectall_arrayref { return [] }
    sub selectrow_array {
        my ($self, $sql, $attrs, $table) = @_;
        return ($table || '') eq 'live_stream_worker_events' ? 1 : 0;
    }
    sub selectrow_hashref {
        my ($self, $sql) = @_;
        return {
            total_events     => 4,
            auth_authorized  => 1,
            auth_rejected    => 2,
            heartbeat_events => 1,
            unhealthy_events => 1,
            latest_event_at  => time,
        } if $sql =~ /COUNT\(\*\) AS total_events/;
        return {
            id         => 42,
            event_type => 'heartbeat',
            status     => 'unhealthy',
            worker_id  => 'obs-worker-test',
            created_at => time,
        };
    }
}

my $app_root = "$FindBin::Bin/..";
my $harness = DesertCMS::OpenBSDHostIntegration->new(
    app_root     => $app_root,
    staging_root => '/tmp/desertcms-v3-test',
    mock         => 1,
);

my $steps = $harness->steps;
my %steps_by_key = map { $_->{key} => $_ } @{$steps};
my @v3_module_syntax_keys = qw(
    perl_v3_accounts_syntax
    perl_v3_dashboard_syntax
    perl_v3_forums_syntax
    perl_v3_live_streaming_syntax
    perl_v3_module_manifest_syntax
    perl_v3_notifications_syntax
    perl_v3_openbsd_host_integration_syntax
    perl_v3_realtime_syntax
    perl_v3_security_center_syntax
    perl_v3_social_syntax
);
for my $key (qw(
    branch_guard stage_branch write_test_config write_openbsd_test_configs perl_cgi_syntax perl_realtime_syntax prove_suite
    schema_migration httpd_route_shape httpd_syntax pf_streaming_shape pf_syntax
    slowcgi_shape slowcgi_syntax acme_client_shape security_center_readonly syspatch_check pkg_add_update_check root_worker_queue_dry_run
), @v3_module_syntax_keys) {
    ok($steps_by_key{$key}, "OpenBSD v3 harness plans $key");
}
is($steps_by_key{branch_guard}{internal}, 'branch_guard', 'OpenBSD v3 harness starts with a local branch guard');
for my $key (@v3_module_syntax_keys) {
    is($steps_by_key{$key}{command}[1], '-Ilib', "$key uses the staged lib path");
    is($steps_by_key{$key}{command}[2], '-c', "$key is a compile-only syntax step");
    like($steps_by_key{$key}{command}[3], qr{\Alib/DesertCMS/}, "$key targets a v3 module file");
}

my $marker_root = tempdir(CLEANUP => 1);
open my $marker_fh, '>', "$marker_root/.desertcms-v3-branch" or die "cannot write branch marker: $!";
print {$marker_fh} "codex/v3-development\n";
close $marker_fh;
my $marker_harness = DesertCMS::OpenBSDHostIntegration->new(
    app_root     => $marker_root,
    staging_root => '/tmp/desertcms-v3-test',
);
is($marker_harness->branch_guard, 'branch codex/v3-development ok', 'OpenBSD v3 harness accepts uploaded staging bundles with a matching branch marker');
open my $bad_marker_fh, '>', "$marker_root/.desertcms-v3-branch" or die "cannot rewrite branch marker: $!";
print {$bad_marker_fh} "main\n";
close $bad_marker_fh;
my $bad_marker_ok = eval { $marker_harness->branch_guard; 1 };
ok(!$bad_marker_ok && $@ =~ /must run from branch codex\/v3-development/, 'OpenBSD v3 harness rejects uploaded staging bundles with the wrong branch marker');

my $dry_run = $harness->run(dry_run => 1);
is(scalar(@{$dry_run}), scalar(@{$steps}), 'OpenBSD v3 harness dry-run reports every planned step');
ok(!(grep { ($_->{status} || '') ne 'planned' } @{$dry_run}), 'OpenBSD v3 harness dry-run does not execute steps');

my @mock_commands;
my $mock_runner = DesertCMS::OpenBSDHostIntegration->new(
    app_root     => $app_root,
    staging_root => '/tmp/desertcms-v3-test',
    mock         => 1,
    runner       => sub { push @mock_commands, $_[0]{key} },
);
my $mock_results = $mock_runner->run(dry_run => 0);
ok(!(grep { ($_->{status} || '') ne 'ok' } @{$mock_results}), 'OpenBSD v3 harness mock execution succeeds locally');
for my $key (qw(perl_cgi_syntax perl_realtime_syntax prove_suite schema_migration httpd_syntax pf_syntax slowcgi_syntax security_center_readonly syspatch_check pkg_add_update_check root_worker_queue_dry_run), @v3_module_syntax_keys) {
    ok((grep { $_ eq $key } @mock_commands), "OpenBSD v3 harness mock runner sees $key");
}
is($steps_by_key{syspatch_check}{command}[0], 'syspatch', 'OpenBSD v3 harness uses syspatch for base patch visibility');
is_deeply($steps_by_key{syspatch_check}{command}, [qw(syspatch -c)], 'OpenBSD v3 harness runs syspatch -c read-only');
is_deeply($steps_by_key{pkg_add_update_check}{command}, [qw(pkg_add -n -u)], 'OpenBSD v3 harness runs pkg_add -n -u dry-run');
like($steps_by_key{root_worker_queue_dry_run}{command}[-1], qr/INSERT INTO admin_users.*approved_by_user_id=>\$admin_id/s, 'OpenBSD v3 harness queues root-worker dry-run with an isolated staging admin approval');

like($steps_by_key{httpd_syntax}{command}[3], qr{/tmp/desertcms-v3-test/local/openbsd-v3/httpd\.conf\z}, 'OpenBSD v3 harness lints generated httpd staging config');
like($steps_by_key{pf_syntax}{command}[2], qr{/tmp/desertcms-v3-test/local/openbsd-v3/pf\.conf\z}, 'OpenBSD v3 harness lints generated pf staging rules');
like($steps_by_key{slowcgi_syntax}{command}[2], qr{/tmp/desertcms-v3-test/local/openbsd-v3/desertcms_slowcgi\z}, 'OpenBSD v3 harness syntax-checks generated slowcgi staging script');
like($harness->config_text, qr/module_accounts_enabled = 1/, 'OpenBSD v3 harness enables Accounts in isolated config');
like($harness->config_text, qr/module_live_streaming_enabled = 1/, 'OpenBSD v3 harness enables Live Streaming in isolated config');
like($harness->config_text, qr/realtime_public_url = https:\/\/v3-integration\.example\.test\/events/, 'OpenBSD v3 harness pins a public realtime events URL for browser clients');
like($harness->config_text, qr/live_chat_account_only = 1/, 'OpenBSD v3 harness exercises account-only live chat config');
like($harness->config_text, qr/live_hls_public_prefix = \/streams/, 'OpenBSD v3 harness pins the HLS public prefix for streaming tests');
like($harness->config_text, qr/live_worker_health_path = \/live\/worker\/health/, 'OpenBSD v3 harness pins the worker health path for streaming tests');
like($harness->config_text, qr{/tmp/desertcms-v3-test/local/openbsd-v3/desertcms\.sqlite}, 'OpenBSD v3 harness uses temp SQLite DB path');
like($harness->config_text, qr/site_url = https:\/\/v3-integration\.example\.test/, 'OpenBSD v3 harness uses a staging-only example.test site URL');
like($harness->generated_httpd_config, qr/server "v3-integration\.example\.test"/, 'OpenBSD v3 harness generates httpd config for the staging host');
like($harness->generated_acme_config, qr/domain "v3-integration\.example\.test"/, 'OpenBSD v3 harness generates acme-client config for the staging host');
my $custom_staging_host = DesertCMS::OpenBSDHostIntegration->new(
    app_root     => $app_root,
    staging_root => '/tmp/desertcms-v3-test',
    staging_host => 'https://custom-v3.example.test:443/path',
);
like($custom_staging_host->config_text, qr/site_url = https:\/\/custom-v3\.example\.test/, 'OpenBSD v3 harness sanitizes configured staging host URLs');

my $branch_ok = DesertCMS::OpenBSDHostIntegration->new(
    app_root        => $app_root,
    staging_root    => '/tmp/desertcms-v3-test',
    expected_branch => 'codex/v3-development',
    branch_reader   => sub { 'codex/v3-development' },
);
is($branch_ok->branch_guard, 'branch codex/v3-development ok', 'OpenBSD v3 harness accepts the v3 development branch');
my $branch_blocked = eval {
    DesertCMS::OpenBSDHostIntegration->new(
        app_root        => $app_root,
        staging_root    => '/tmp/desertcms-v3-test',
        expected_branch => 'codex/v3-development',
        branch_reader   => sub { 'main' },
    )->branch_guard;
    1;
};
ok(!$branch_blocked && $@ =~ /must run from branch codex\/v3-development, not main/, 'OpenBSD v3 harness refuses staging from the wrong branch');

my $shape_source = tempdir(CLEANUP => 1);
my $shape_stage = tempdir(CLEANUP => 1);
make_path("$shape_source/etc", "$shape_stage/etc");
_write("$shape_source/etc/httpd.conf.example", "server \"source-only\" {}\n");
_write("$shape_stage/etc/httpd.conf.example", _httpd_shape_fixture());
_write("$shape_source/etc/pf.conf.example", "block all\n");
_write("$shape_source/etc/acme-client.conf.example", "authority internal {}\n");
my $staged_shape = DesertCMS::OpenBSDHostIntegration->new(
    app_root     => $shape_source,
    staging_root => $shape_stage,
    mock         => 1,
);
like($staged_shape->check_httpd_route_shape, qr/httpd v3 route shape ok/, 'OpenBSD v3 harness internal checks prefer the staged test tree');

my $generated_stage = tempdir(CLEANUP => 1);
my $generated = DesertCMS::OpenBSDHostIntegration->new(
    app_root     => $shape_source,
    staging_root => $generated_stage,
);
like($generated->write_openbsd_test_configs, qr/wrote generated OpenBSD staging configs/, 'OpenBSD v3 harness writes generated staging configs');
ok(-e "$generated_stage/local/openbsd-v3/httpd.conf", 'OpenBSD v3 harness writes generated httpd config');
ok(-e "$generated_stage/local/openbsd-v3/pf.conf", 'OpenBSD v3 harness writes generated pf rules');
ok(-e "$generated_stage/local/openbsd-v3/acme-client.conf", 'OpenBSD v3 harness writes generated acme-client config');
ok(-e "$generated_stage/local/openbsd-v3/desertcms_slowcgi", 'OpenBSD v3 harness writes generated slowcgi rc.d script');
like($generated->check_httpd_route_shape, qr/httpd v3 route shape ok/, 'OpenBSD v3 harness checks generated httpd routes before source examples');
like($generated->check_pf_streaming_shape, qr/pf streaming shape ok/, 'OpenBSD v3 harness checks generated pf streaming shape before source examples');
like($generated->check_acme_shape, qr/acme-client shape ok/, 'OpenBSD v3 harness checks generated acme-client shape before source examples');
like($generated->check_slowcgi_shape, qr/slowcgi rc\.d shape ok/, 'OpenBSD v3 harness checks generated slowcgi shape before source examples');
my $generated_stage_slash = $generated_stage;
$generated_stage_slash =~ s{\\}{/}g;
like(_read("$generated_stage/local/openbsd-v3/httpd.conf"), qr/DESERTCMS_CONFIG "\Q$generated_stage_slash\E/, 'generated httpd config points at isolated test config');
like(_read("$generated_stage/local/openbsd-v3/httpd.conf"), qr{location "/streams/\*"}, 'generated httpd config serves HLS streams as static assets');
like(_read("$generated_stage/local/openbsd-v3/httpd.conf"), qr{/run/desertcms-v3-test\.sock}, 'generated httpd config uses an isolated v3 slowcgi socket');
like(_read("$generated_stage/local/openbsd-v3/desertcms_slowcgi"), qr{/var/www/run/desertcms-v3-test\.sock}, 'generated slowcgi rc.d script uses an isolated v3 socket path');

my $unsafe_dry_run_target = eval {
    DesertCMS::OpenBSDHostIntegration->new(
        app_root     => $app_root,
        staging_root => '/var/www/desertcms-v3-test',
    )->run(dry_run => 1);
    1;
};
ok(!$unsafe_dry_run_target && $@ =~ /staging root must be under \/tmp\/desertcms-v3-test/, 'OpenBSD v3 harness refuses live-looking dry-run staging roots');

my $unsafe_traversal_target = eval {
    DesertCMS::OpenBSDHostIntegration->new(
        app_root     => $app_root,
        staging_root => '/tmp/desertcms-v3-test/../desertcms-live',
    )->run(dry_run => 1);
    1;
};
ok(!$unsafe_traversal_target && $@ =~ /staging root must be under \/tmp\/desertcms-v3-test/, 'OpenBSD v3 harness rejects traversal-shaped staging roots');

my $unsafe_dry_run_config = eval {
    DesertCMS::OpenBSDHostIntegration->new(
        app_root     => $app_root,
        staging_root => '/tmp/desertcms-v3-test',
        config_path  => '/etc/desertcms.conf',
    )->run(dry_run => 1);
    1;
};
ok(!$unsafe_dry_run_config && $@ =~ /config path must stay under the staging root/, 'OpenBSD v3 harness refuses production config paths even in dry-run');

my $unsafe_generated_config = eval {
    DesertCMS::OpenBSDHostIntegration->new(
        app_root             => $app_root,
        staging_root         => '/tmp/desertcms-v3-test',
        generated_httpd_path => '/tmp/desertcms-v3-test/../httpd.conf',
    )->run(dry_run => 1);
    1;
};
ok(!$unsafe_generated_config && $@ =~ /generated OpenBSD integration files must stay under the staging root/, 'OpenBSD v3 harness rejects traversal-shaped generated config paths');

my $unsafe_live_host = eval {
    DesertCMS::OpenBSDHostIntegration->new(
        app_root     => $app_root,
        staging_root => '/tmp/desertcms-v3-test',
        staging_host => 'desertarchives.com',
    )->run(dry_run => 1);
    1;
};
ok(!$unsafe_live_host && $@ =~ /staging-only example\.test hostname|live DesertCMS domains/, 'OpenBSD v3 harness refuses live desertarchives.com hostnames');

my $unsafe_legacy_live_host = eval {
    DesertCMS::OpenBSDHostIntegration->new(
        app_root     => $app_root,
        staging_root => '/tmp/desertcms-v3-test',
        staging_host => 'desertcms.com',
    )->run(dry_run => 1);
    1;
};
ok(!$unsafe_legacy_live_host && $@ =~ /staging-only example\.test hostname|live DesertCMS domains/, 'OpenBSD v3 harness refuses legacy desertcms.com hostnames');

my $blocked_real_run = eval {
    local $ENV{DESERTCMS_OPENBSD_INTEGRATION} = '';
    DesertCMS::OpenBSDHostIntegration->new(app_root => $app_root, staging_root => '/tmp/desertcms-v3-test')->run(dry_run => 0);
    1;
};
ok(!$blocked_real_run && $@ =~ /DESERTCMS_OPENBSD_INTEGRATION=1/, 'OpenBSD v3 harness blocks real runs without explicit env gate');

if ($^O ne 'openbsd') {
    my $wrong_os_run = eval {
        local $ENV{DESERTCMS_OPENBSD_INTEGRATION} = '1';
        DesertCMS::OpenBSDHostIntegration->new(app_root => $app_root, staging_root => '/tmp/desertcms-v3-test')->run(dry_run => 0);
        1;
    };
    ok(!$wrong_os_run && $@ =~ /must run on OpenBSD/, 'OpenBSD v3 harness blocks real runs outside OpenBSD even with env gate');
} else {
    pass('OpenBSD v3 harness OS gate is evaluated by the optional real integration subtest on OpenBSD');
}

my $live_target_run = eval {
    local $ENV{DESERTCMS_OPENBSD_INTEGRATION} = '1';
    my $unsafe = DesertCMS::OpenBSDHostIntegration->new(
        app_root     => $app_root,
        staging_root => '/var/www/desertcms-v3-test',
    );
    $unsafe->_assert_non_live_target;
    1;
};
ok(!$live_target_run && $@ =~ /staging root must be under \/tmp\/desertcms-v3-test/, 'OpenBSD v3 harness refuses non-staging real-run targets');

like($harness->check_httpd_route_shape, qr/httpd v3 route shape ok/, 'OpenBSD v3 harness validates v3 httpd dynamic route shape');
like($harness->check_pf_streaming_shape, qr/pf streaming shape ok/, 'OpenBSD v3 harness validates pf streaming shape');
like($harness->check_slowcgi_shape, qr/slowcgi rc\.d shape ok/, 'OpenBSD v3 harness validates slowcgi shape');
like($harness->check_acme_shape, qr/acme-client shape ok/, 'OpenBSD v3 harness validates acme-client shape');

my $tool = _read("$app_root/tools/openbsd-v3-integration.pl");
like($tool, qr/--run/, 'OpenBSD v3 integration entrypoint documents real run mode');
like($tool, qr/staging_host\s*=>\s*'v3-integration\.example\.test'/, 'OpenBSD v3 integration entrypoint defaults to a staging-only host');
like($tool, qr/'staging-host=s'\s*=>\s*\\\$opt\{staging_host\}/, 'OpenBSD v3 integration entrypoint accepts an explicit staging host');
like($tool, qr/staging_host\s*=>\s*\$opt\{staging_host\}/, 'OpenBSD v3 integration entrypoint passes the staging host to the guarded harness');
like($tool, qr/--staging-host v3-integration\.example\.test/, 'OpenBSD v3 integration usage documents staging host selection');
like($tool, qr/--expected-branch codex\/v3-development/, 'OpenBSD v3 integration entrypoint documents the v3 branch guard');
like($tool, qr/DESERTCMS_OPENBSD_INTEGRATION=1.*staging-only example\.test hostname/s, 'OpenBSD v3 integration entrypoint documents the real-run environment and staging-host gates');

my $pf = _read("$app_root/etc/pf.conf.example");
like($pf, qr/port 1935/, 'pf example documents opt-in OBS ingest port');
like($pf, qr/Enable only after the streaming worker/, 'pf example keeps streaming ingress opt-in');

my $cve_feed = "$generated_stage/local/openbsd-v3/cve-feed.json";
_write($cve_feed, q{[{"cve":"CVE-2099-0001","package":"openssl","summary":"mock vulnerable package"}]});
my %security_command_results = (
    syspatch_check => { available => 1, ran => 1, exit => 0, output => "001_mock.patch\n" },
    pkg_add_update_check => { available => 1, ran => 1, exit => 0, output => "Update candidates: vim-9.1\n" },
    pkg_info_inventory => { available => 1, ran => 1, exit => 0, output => "openssl-3.4.0\nsqlite-3.46.0\n" },
);
my $security_center = DesertCMS::SecurityCenter->new(
    config => LocalSecurityConfig->new(security_cve_feed_path => $cve_feed),
    db     => bless({}, 'LocalSecurityDB'),
    command_runner => sub {
        my ($key, @command) = @_;
        return $security_command_results{$key} || { available => 0, ran => 0, exit => 127, error => "unexpected command @command" };
    },
);
my $package_check = $security_center->_package_update_check;
is($package_check->{status}, 'warning', 'Security Center reports package visibility output as reviewable updates');
like($package_check->{detail}, qr/1 base syspatch candidate/, 'Security Center summarizes syspatch -c output');
is($package_check->{details}{package_update_lines}[0], 'Update candidates: vim-9.1', 'Security Center preserves pkg_add -n -u dry-run lines');
my $cve_check = $security_center->_cve_matching_check;
is($cve_check->{status}, 'critical', 'Security Center reports local CVE matches against installed package inventory');
like($cve_check->{details}{matches}[0], qr/CVE-2099-0001 affects openssl-3\.4\.0/, 'Security Center includes matched package CVE detail');
my $origin_config = LocalSecurityConfig->new(
    site_url                 => 'https://desertcms.example.test',
    realtime_enabled         => 1,
    realtime_bind_host       => '127.0.0.1',
    realtime_port            => 8787,
    realtime_public_url      => 'https://realtime.example.test/events',
    realtime_allowed_origins => "https://admin.example.test\nhttp://localhost:8787",
);
is(
    DesertCMS::Realtime->normalize_public_url('https://realtime.example.test/'),
    'https://realtime.example.test/events',
    'Realtime normalizes host-only public event URLs'
);
my $bad_public_url_ok = eval { DesertCMS::Realtime->normalize_public_url('https://user:secret@realtime.example.test/events'); 1 };
ok(!$bad_public_url_ok && $@ =~ /public URL/, 'Realtime rejects public event URLs with userinfo');
my $public_status = DesertCMS::Realtime->service_status($origin_config);
is($public_status->{events_url}, 'https://realtime.example.test/events', 'Realtime service status exposes the configured public events URL');
is($public_status->{websocket_url}, 'wss://realtime.example.test/ws', 'Realtime service status derives a secure WebSocket URL from HTTPS events');
my $local_status = DesertCMS::Realtime->service_status({
    realtime_enabled   => 1,
    realtime_bind_host => '127.0.0.1',
    realtime_port      => 8787,
});
is($local_status->{websocket_url}, 'ws://127.0.0.1:8787/ws', 'Realtime service status derives a local WebSocket URL from loopback HTTP events');
ok(DesertCMS::Realtime->origin_allowed($origin_config, 'https://desertcms.example.test'), 'Realtime allows configured site origin');
ok(DesertCMS::Realtime->origin_allowed($origin_config, 'https://admin.example.test'), 'Realtime allows configured extra origin');
ok(!DesertCMS::Realtime->origin_allowed($origin_config, 'https://evil.example.test'), 'Realtime rejects unconfigured browser origins');
like(
    DesertCMS::Realtime->cors_headers($origin_config, 'https://admin.example.test'),
    qr/Access-Control-Allow-Origin: https:\/\/admin\.example\.test/,
    'Realtime emits CORS headers for allowed browser origins'
);
unlike(
    DesertCMS::Realtime->cors_headers($origin_config, 'https://evil.example.test'),
    qr/Access-Control-Allow-Origin/,
    'Realtime does not emit CORS headers for rejected browser origins'
);
is(
    DesertCMS::Realtime->normalize_allowed_origins("https://Admin.example.test\nhttp://localhost:8787"),
    "https://admin.example.test\nhttp://localhost:8787",
    'Realtime normalizes exact allowed origins'
);
my $bad_origin_ok = eval { DesertCMS::Realtime->normalize_allowed_origins('https://example.test/path') };
ok(!$bad_origin_ok && $@ =~ /realtime origin/, 'Realtime rejects allowed origins with paths');
is(DesertCMS::Notifications::_delivery_channel(''), 'in_app', 'Notifications default omitted delivery channels to in-app');
my $bad_notification_channel_ok = eval { DesertCMS::Notifications::_delivery_channel('sms'); 1 };
ok(!$bad_notification_channel_ok && $@ =~ /notification delivery channel is not supported/, 'Notifications reject unknown delivery channels instead of silently coercing them');
is(DesertCMS::Realtime->normalize_channel_filter(' live.chat '), 'live.chat', 'Realtime accepts declared channel filters');
is(DesertCMS::Realtime->normalize_channel_filter('live.chat.42'), 'live.chat.42', 'Realtime accepts scoped live chat channel filters');
is(DesertCMS::Realtime->normalize_channel_filter('stream.presence.7'), 'stream.presence.7', 'Realtime accepts scoped stream presence channel filters');
is(DesertCMS::Realtime->normalize_channel_filter('user.notifications.9'), 'user.notifications.9', 'Realtime accepts account-scoped user notification channel filters');
my $bad_user_channel_filter_ok = eval { DesertCMS::Realtime->normalize_channel_filter('user.notifications') };
ok(!$bad_user_channel_filter_ok && $@ =~ /user notification channel must be account scoped/, 'Realtime rejects unscoped user notification channel filters');
my $bad_channel_filter_ok = eval { DesertCMS::Realtime->normalize_channel_filter('unknown.channel') };
ok(!$bad_channel_filter_ok && $@ =~ /channel filter is not allowed/, 'Realtime rejects undeclared channel filters');
my $account_channel_token = DesertCMS::Realtime->channel_token($origin_config, channel => 'user.notifications.9', expires_at => time + 300);
ok(DesertCMS::Realtime->channel_requires_token('user.notifications.9'), 'Realtime flags account notification channels as token-protected');
ok(DesertCMS::Realtime->channel_token_valid($origin_config, channel => 'user.notifications.9', token => $account_channel_token), 'Realtime accepts signed account notification channel tokens');
ok(!DesertCMS::Realtime->channel_token_valid($origin_config, channel => 'user.notifications.10', token => $account_channel_token), 'Realtime rejects channel tokens replayed for another account channel');
ok(!DesertCMS::Realtime->channel_token_valid($origin_config, channel => 'user.notifications.9', token => $account_channel_token, now => time + 400), 'Realtime rejects expired account notification channel tokens');
ok(DesertCMS::Realtime->channel_request_authorized($origin_config, channel => 'live.chat.42'), 'Realtime does not require tokens for live chat channels');
ok(!DesertCMS::Realtime->channel_request_authorized($origin_config, channel => 'user.notifications.9'), 'Realtime rejects account notification channel requests without a token');
ok(DesertCMS::Realtime->channel_request_authorized($origin_config, channel => 'user.notifications.9', token => $account_channel_token), 'Realtime authorizes account notification channel requests with a valid token');
my $normalized_live_chat_event = DesertCMS::Realtime->normalize_event({
    type => 'live.chat',
    data => { body => 'hello' },
});
is($normalized_live_chat_event->{channel}, 'live.chat', 'Realtime assigns the manifest channel for live chat events');
my $normalized_scoped_live_chat_event = DesertCMS::Realtime->normalize_event({
    type    => 'live.chat',
    channel => 'live.chat.42',
    data    => { body => 'session scoped' },
});
is($normalized_scoped_live_chat_event->{channel}, 'live.chat.42', 'Realtime accepts scoped live chat event channels');
my $normalized_scoped_presence_event = DesertCMS::Realtime->normalize_event({
    type    => 'stream.presence',
    channel => 'stream.presence.7',
    data    => { status => 'live' },
});
is($normalized_scoped_presence_event->{channel}, 'stream.presence.7', 'Realtime accepts scoped stream presence event channels');
my $normalized_user_notification_event = DesertCMS::Realtime->normalize_event({
    type => 'user.notification',
    data => { recipient_account_id => 9, title => 'private' },
});
is($normalized_user_notification_event->{channel}, 'user.notifications.9', 'Realtime scopes user notification events to the recipient account');
my $notification_detail_event = DesertCMS::Realtime->notification_event({
    audience     => 'admin',
    topic        => 'security.check_failed',
    title        => 'Security check',
    details_json => encode_json({ check_key => 'pf', status => 'critical' }),
});
is($notification_detail_event->{data}{details}{check_key}, 'pf', 'Realtime notification events preserve structured notification details');
my $unscoped_user_notification_ok = eval {
    DesertCMS::Realtime->normalize_event({
        type    => 'user.notification',
        channel => 'user.notifications',
        data    => { recipient_account_id => 9, title => 'private' },
    });
    1;
};
ok(!$unscoped_user_notification_ok && $@ =~ /user notification channel must be account scoped/, 'Realtime rejects unscoped user notification events');
my $cross_channel_event_ok = eval {
    DesertCMS::Realtime->normalize_event({
        type    => 'live.chat',
        channel => 'admin.notifications',
        data    => { body => 'wrong channel' },
    });
    1;
};
ok(!$cross_channel_event_ok && $@ =~ /event channel is not allowed/, 'Realtime rejects events published onto the wrong manifest channel');
my $realtime_event_dir = tempdir(CLEANUP => 1);
my $realtime_event_log = "$realtime_event_dir/realtime-events.jsonl";
my $realtime_log_config = LocalSecurityConfig->new(realtime_event_log_path => $realtime_event_log);
my $bad_publish_ok = eval {
    DesertCMS::Realtime->publish($realtime_log_config, {
        type    => 'live.chat',
        channel => 'admin.notifications',
        data    => { body => 'do not write' },
    });
    1;
};
ok(!$bad_publish_ok && $@ =~ /event channel is not allowed/, 'Realtime publish rejects cross-channel events before persistence');
ok(!-e $realtime_event_log, 'Realtime publish does not create an event log for rejected events');
ok(DesertCMS::Realtime->publish($realtime_log_config, {
    type    => 'live.chat',
    channel => 'live.chat',
    data    => { body => 'write this' },
})->{delivered}, 'Realtime publish accepts valid channel-scoped events');
_write(
    $realtime_event_log,
    join("\n",
        encode_json({ type => 'live.chat', channel => 'live.chat', data => { body => 'kept' }, created_at => 1 }),
        encode_json({ type => 'live.chat', channel => 'live.chat.42', data => { body => 'scoped kept' }, created_at => 2 }),
        encode_json({ type => 'live.chat', channel => 'admin.notifications', data => { body => 'dropped' }, created_at => 2 }),
        encode_json({ type => 'admin.notification', channel => 'admin.notifications', data => { title => 'kept' }, created_at => 3 }),
        encode_json({ type => 'user.notification', channel => 'user.notifications.9', data => { recipient_account_id => 9, title => 'private kept' }, created_at => 4 }),
        ''
    )
);
my $live_chat_replay = DesertCMS::Realtime->recent_events($realtime_log_config, channel => 'live.chat', limit => 10);
is(scalar(@{$live_chat_replay}), 2, 'Realtime replay filters live chat events by validated channel');
is($live_chat_replay->[0]{data}{body}, 'kept', 'Realtime replay skips malformed persisted cross-channel events');
my $scoped_live_chat_replay = DesertCMS::Realtime->recent_events($realtime_log_config, channel => 'live.chat.42', limit => 10);
is(scalar(@{$scoped_live_chat_replay}), 1, 'Realtime replay can target one scoped live chat channel');
is($scoped_live_chat_replay->[0]{data}{body}, 'scoped kept', 'Realtime scoped replay returns the requested session channel');
my $scoped_user_replay = DesertCMS::Realtime->recent_events($realtime_log_config, channel => 'user.notifications.9', limit => 10);
is(scalar(@{$scoped_user_replay}), 1, 'Realtime replay can target one account-scoped notification channel');
is($scoped_user_replay->[0]{data}{title}, 'private kept', 'Realtime scoped replay returns the requested account notification channel');
my $all_replay = DesertCMS::Realtime->recent_events($realtime_log_config, limit => 10);
is(scalar(@{$all_replay}), 3, 'Realtime unfiltered replay keeps valid broadcast events and skips account-scoped user notifications');
my $bad_recent_filter_ok = eval {
    DesertCMS::Realtime->recent_events($realtime_log_config, channel => 'unknown.channel', limit => 10);
    1;
};
ok(!$bad_recent_filter_ok && $@ =~ /channel filter is not allowed/, 'Realtime replay rejects undeclared channel filters');
my $bad_ws_filter_ok = eval {
    DesertCMS::Realtime->websocket_snapshot_payload($realtime_log_config, channel => 'unknown.channel', limit => 10);
    1;
};
ok(!$bad_ws_filter_ok && $@ =~ /channel filter is not allowed/, 'Realtime WebSocket snapshots reject undeclared channel filters');
my $origin_center = DesertCMS::SecurityCenter->new(
    config => $origin_config,
    db     => bless({}, 'LocalSecurityDB'),
);
my $origin_check = $origin_center->_realtime_origin_filter_check;
is($origin_check->{status}, 'ok', 'Security Center accepts configured realtime origin filter');
ok((grep { $_ eq 'https://admin.example.test' } @{ $origin_check->{details}{effective_origins} }), 'Security Center reports effective realtime origins');
my $streaming_center = DesertCMS::SecurityCenter->new(
    config => LocalSecurityConfig->new(
        module_live_streaming_enabled     => 1,
        live_worker_event_window_seconds  => 900,
    ),
    db => bless({}, 'LocalStreamingSecurityDB'),
);
my $worker_event_state = $streaming_center->_streaming_worker_event_state(window_seconds => 900);
is($worker_event_state->{auth_rejected}, 2, 'Security Center summarizes rejected streaming worker auth events');
is($worker_event_state->{unhealthy_events}, 1, 'Security Center summarizes unhealthy streaming worker events');
my $streaming_check = $streaming_center->_streaming_ports_check;
is($streaming_check->{status}, 'critical', 'Security Center escalates unhealthy streaming worker events');
like($streaming_check->{detail}, qr/rejected worker auth/, 'Security Center streaming check describes worker auth failures');
is($streaming_check->{details}{worker_events}{latest_worker_id}, 'obs-worker-test', 'Security Center streaming check reports latest worker event identity');
my $stream_prefix_runtime = DesertCMS::LiveStreaming->new(
    config => LocalSecurityConfig->new(
        live_hls_public_prefix => '/tenant-streams',
        live_hls_output_dir    => '/var/www/htdocs/desertcms-site/tenant-streams',
    ),
    db => bless({}, 'LocalSecurityDB'),
);
is(
    $stream_prefix_runtime->worker_contract->{hls}{required_path},
    '/tenant-streams/<channel>/index.m3u8',
    'Live Streaming worker contract reflects the configured HLS public prefix'
);
ok($stream_prefix_runtime->validate_hls_path('/tenant-streams/channel/index.m3u8'), 'Live Streaming accepts configured-prefix HLS playlist paths');
ok(!$stream_prefix_runtime->validate_hls_path('/streams/channel/index.m3u8'), 'Live Streaming rejects default-prefix HLS paths when a custom prefix is configured');
ok(!$stream_prefix_runtime->validate_hls_path('/tenant-streams/../secret/index.m3u8'), 'Live Streaming rejects traversal in configured-prefix HLS paths');

my $app = _read("$app_root/lib/DesertCMS/App.pm");
like($app, qr{path eq '/live/worker/health'}, 'app dispatch exposes the Live Streaming worker health endpoint');
like($app, qr{path eq '/live/worker/auth'}, 'app dispatch exposes the Live Streaming worker auth endpoint');
like($app, qr{path eq '/live/worker/heartbeat'}, 'app dispatch exposes the Live Streaming worker heartbeat endpoint');
like($app, qr/channel_id channel_slug slug name stream stream_name stream_key key token session_id/s, 'app forwards common OBS worker auth callback aliases');
like($app, qr/LiveStreaming->new\(config => \$config, db => \$db, notifications => \$notifications\)/, 'app wires Live Streaming to the central notification bus');
like($app, qr{path eq '/admin/live/channels/key/rotate'}, 'app dispatch exposes Live Streaming admin stream key rotation');
like($app, qr{path eq '/admin/live/channels/key/revoke'}, 'app dispatch exposes Live Streaming admin stream key revocation');
like($app, qr{path eq '/admin/live/sessions/due'}, 'app dispatch exposes Live Streaming due-session notification checks');
like($app, qr{live/\(\[A-Za-z0-9-\]\+\)/presence}, 'app dispatch exposes Live Streaming chat presence updates');
like($app, qr{live/\(\[A-Za-z0-9-\]\+\)/presence/leave}, 'app dispatch exposes Live Streaming chat presence leave updates');
like($app, qr{live/\(\[A-Za-z0-9-\]\+\)/chat/delete}, 'app dispatch exposes Live Streaming public author chat deletion');
like($app, qr{live/\(\[A-Za-z0-9-\]\+\)/chat/report}, 'app dispatch exposes Live Streaming chat reporting');
like($app, qr{path eq '/admin/live/chat/status'}, 'app dispatch exposes Live Streaming admin chat moderation');
like($app, qr{path eq '/admin/live/chat/reports/status'}, 'app dispatch exposes Live Streaming admin report moderation');
like($app, qr{path eq '/admin/live/blocked-terms/save'}, 'app dispatch exposes Live Streaming blocked-term save route');
like($app, qr{path eq '/admin/live/blocked-terms/delete'}, 'app dispatch exposes Live Streaming blocked-term delete route');
like($app, qr{action="/live/\$safe_slug/chat/report"}, 'Live Streaming public channel page renders chat report forms');
like($app, qr{action="/live/\$safe_slug/chat/delete"}, 'Live Streaming public channel page renders author chat delete forms');
like($app, qr{action="/admin/live/channels/key/rotate"}, 'Live Streaming admin page renders stream key rotation forms');
like($app, qr{action="/admin/live/channels/key/revoke"}, 'Live Streaming admin page renders stream key revocation forms');
like($app, qr{action="/admin/live/sessions/due"}, 'Live Streaming admin page renders due-session notification checks');
like($app, qr{action="/admin/live/blocked-terms/save"}, 'Live Streaming admin page renders blocked-term save forms');
like($app, qr{action="/admin/live/blocked-terms/delete"}, 'Live Streaming admin page renders blocked-term delete forms');
like($app, qr{name="scheduled_at" type="datetime-local"}, 'Live Streaming admin page exposes scheduled session time input');
like($app, qr/scheduled_at\s*=>\s*_admin_parse_datetime_value\(\$request->param\('scheduled_at'\), 'UTC'\)/, 'Live Streaming admin route persists scheduled session times');
like($app, qr/sub _admin_parse_datetime_value.*?DateTimeLite->new.*?scheduled time is invalid/s, 'Live Streaming admin schedule parser validates datetime-local values');
like($app, qr/sub _admin_live_sessions_due.*?emit_schedule_due_notifications\(now => now\(\)\).*?live\.sessions_due_checked/s, 'Live Streaming admin due-session action emits notifications and audits the check');
like($app, qr/sub _admin_live_blocked_term_save.*?save_blocked_term.*?live\.blocked_term_saved/s, 'Live Streaming admin blocked-term saves route through the runtime and audit trail');
like($app, qr/sub _admin_live_blocked_term_delete.*?delete_blocked_term.*?live\.blocked_term_deleted/s, 'Live Streaming admin blocked-term deletes route through the runtime and audit trail');
like($app, qr/_live_presence_apply/, 'Live Streaming public routes update chat presence through the module runtime');
like($app, qr/_admin_live_chat_report_rows/, 'Live Streaming admin page renders the chat moderation queue');
like($app, qr/_admin_live_blocked_term_rows/, 'Live Streaming admin page renders blocked-term management');
like($app, qr/_admin_live_worker_event_rows/, 'Live Streaming admin page renders worker event history');
like($app, qr/Worker Events/, 'Live Streaming admin page labels the worker event history panel');
like($app, qr/sub _realtime_publish_adapter/, 'app exposes a local realtime publish adapter');
like($app, qr/Realtime->publish\(\$self->\{config\}, \$event\)/, 'app realtime adapter publishes through the Perl realtime contract');
like($app, qr/realtime_publish\s*=>\s*\$self->_realtime_publish_adapter/, 'Live Streaming app routes pass realtime publishers into runtime actions');
like($app, qr{forums/posts/\(\[0-9\]\+\)/edit}, 'app dispatch exposes Forum post editing');
like($app, qr{forums/posts/\(\[0-9\]\+\)/delete}, 'app dispatch exposes Forum post soft delete');
like($app, qr{path eq '/forums/report'}, 'app dispatch exposes Forum reporting');
like($app, qr{path eq '/admin/forums/categories/update'}, 'app dispatch exposes Forum admin category policy updates');
like($app, qr{path eq '/admin/forums/posts/status'}, 'app dispatch exposes Forum admin post moderation');
like($app, qr{path eq '/admin/forums/topics/pin'}, 'app dispatch exposes Forum admin topic pinning');
like($app, qr{path eq '/admin/forums/reports/status'}, 'app dispatch exposes Forum admin report moderation');
like($app, qr{action="/forums/report"}, 'Forum topic page renders public report forms');
like($app, qr{action="/forums/posts/\$post_id/edit"}, 'Forum topic page renders public edit forms');
like($app, qr{action="/forums/posts/\$post_id/delete"}, 'Forum topic page renders public soft-delete forms');
like($app, qr{name="visibility".*?_forum_category_visibility_options\('public'\)}s, 'Forum admin category form exposes account and moderator visibility policy');
like($app, qr{action="/admin/forums/categories/update"}, 'Forum admin category table renders policy update forms');
like($app, qr/sub _admin_forum_category_update.*?save_category.*?forums\.category_policy_saved/s, 'Forum admin category policy updates route through the runtime and audit trail');
like($app, qr{action="/admin/forums/topics/pin"}, 'Forum admin topic table renders pin and unpin forms');
like($app, qr/sub _admin_forum_topic_rows.*?my \$moderator_note = escape_html\(\$topic->\{moderator_note\} \|\| ''\).*?Moderator note: \$moderator_note.*?action="\/admin\/forums\/topics\/status".*?name="moderator_note".*?maxlength="500"/s, 'Forum admin topic moderation rows preserve and submit moderator notes');
like($app, qr/sub _admin_forum_topic_pin.*?pin_topic.*?admin_user_id\s*=>\s*\$session->\{user_id\}.*?forums\.topic_pin_saved/s, 'Forum admin topic pinning routes through the runtime and audit trail');
like($app, qr/sub _forums_home.*?viewer_account_id => \$viewer_id/s, 'Forum home filters categories by viewer account context');
like($app, qr/sub _forum_category_page.*?can_view_category.*?topics_for_category\(\$category->\{id\}, viewer_account_id => \$viewer_id\).*?can_account\(action => 'create_topic'/s, 'Forum category page gates reads and topic creation through category permissions');
like($app, qr/sub _forum_topic_page.*?topic_by_slug\(\$category_slug, \$topic_slug, viewer_account_id => \$viewer_id\).*?posts_for_topic\(\$topic->\{id\}, viewer_account_id => \$viewer_id\).*?can_account\(action => 'reply'/s, 'Forum topic page gates direct topic reads, post reads, and replies through viewer-aware permissions');
like($app, qr/_admin_forum_report_rows/, 'Forum admin page renders the report queue');
like($app, qr{path eq '/social/replies/create'}, 'app dispatch exposes Social reply creation');
like($app, qr{path eq '/social/follow'}, 'app dispatch exposes Social follow');
like($app, qr{path eq '/social/unfollow'}, 'app dispatch exposes Social unfollow');
like($app, qr{path eq '/social/block'}, 'app dispatch exposes Social block');
like($app, qr{path eq '/social/unblock'}, 'app dispatch exposes Social unblock');
like($app, qr{path eq '/social/react'}, 'app dispatch exposes Social reactions');
like($app, qr{path eq '/social/posts/delete'}, 'app dispatch exposes Social public post delete');
like($app, qr{path eq '/social/replies/delete'}, 'app dispatch exposes Social public reply delete');
like($app, qr{path eq '/social/report'}, 'app dispatch exposes Social reporting');
like($app, qr{path eq '/admin/social/replies/status'}, 'app dispatch exposes Social admin reply moderation');
like($app, qr{path eq '/admin/social/profiles/status'}, 'app dispatch exposes Social admin profile moderation');
like($app, qr{path eq '/admin/social/reports/status'}, 'app dispatch exposes Social admin report moderation');
like($app, qr/Social->new\(config => \$config, db => \$db, notifications => \$notifications\)/, 'app wires Social to the central notification bus');
like($app, qr/action="\/social\/replies\/create"/, 'Social feed renders public reply forms');
like($app, qr/action="\/social\/report"/, 'Social feed renders public report forms');
like($app, qr/action="\/social\/posts\/delete"/, 'Social feed renders public post delete forms');
like($app, qr/action="\/social\/replies\/delete"/, 'Social feed renders public reply delete forms');
like($app, qr/action="\/social\/react".*?name="reaction" value="like"/s, 'Social feed renders public reaction forms');
like($app, qr/action="\/social\/follow"/, 'Social profile renders follow forms');
like($app, qr/action="\/social\/block"/, 'Social profile renders block forms');
like($app, qr/action="\/social\/unblock"/, 'Social profile renders unblock forms');
like($app, qr/profile_by_handle\(\$handle, viewer_account_id => \$viewer_id, include_hidden => \$account/, 'Social profile route passes viewer context into profile visibility checks');
like($app, qr/blocked_profile.*?This profile is blocked.*?Unblock/s, 'Social profile route renders a minimal unblock surface for profiles blocked by the viewer');
like($app, qr/my \$mode = _social_feed_mode\(\$request->param\('feed'\)\).*?feed_mode\s*=>\s*\$mode/s, 'Social public feed exposes global/following feed mode through the route layer');
like($app, qr/sub _social_feed_cards.*?return '<p class="muted">Sign in with an account to view followed profiles.*?kind\} = 'following'.*?_social_feed_pager/s, 'Social public feed gates following mode to signed-in accounts and renders pagination');
like($app, qr/sub _social_feed_pager.*?Previous.*?Next/s, 'Social public feed renders previous/next pagination links');
like($app, qr/_admin_social_report_rows/, 'Social admin page renders the report queue');
like($app, qr/_admin_social_profile_rows\(\$profiles, \$csrf\).*?sub _admin_social_profile_rows.*?action="\/admin\/social\/profiles\/status".*?profile_account_id.*?name="moderator_note".*?maxlength="500"/s, 'Social admin profile table renders moderation forms with moderator notes');
like($app, qr/sub _admin_social_post_rows.*?action="\/admin\/social\/posts\/status".*?name="moderator_note".*?maxlength="500"/s, 'Social admin post moderation rows submit moderator notes');
like($app, qr/sub _admin_social_report_rows.*?action="\/admin\/social\/replies\/status".*?name="moderator_note".*?Moderate reply.*?action="\/admin\/social\/profiles\/status".*?name="moderator_note".*?Moderate profile.*?action="\/admin\/social\/posts\/status".*?name="moderator_note".*?Moderate post/s, 'Social admin report queue target moderation forms submit moderator notes');
like($app, qr/admin_user_id\s*=>\s*\$session->\{user_id\}/, 'admin moderation routes pass the authenticated admin user into module runtimes');
like($app, qr/oauth_provider_readiness\(\s*provider\s*=>\s*'google'/, 'app uses shared SSO readiness for Google public/admin surfaces');
like($app, qr/oauth_provider_readiness\(\s*provider\s*=>\s*'oidc'/, 'app uses shared SSO readiness for OIDC public/admin surfaces');
like($app, qr/normalize_allowed_domains\(\$request->param\('accounts_allowed_domains'\)\)/, 'app normalizes hosted SSO domains before saving Accounts settings');
like($app, qr/accounts_google_secret_clear/, 'Accounts admin settings can clear stored Google SSO secrets explicitly');
like($app, qr/accounts_oidc_secret_clear/, 'Accounts admin settings can clear stored OIDC secrets explicitly');
like($app, qr/\[redacted\]/, 'Accounts module settings audit details redact stored SSO secrets');
like($app, qr/record_sso_failure/, 'app records provider-returned SSO errors through the Accounts runtime');
like($app, qr/revoke_session\(\$token, ip_address => \$request->\{ip_address\}/, 'app delegates account logout audit context to the Accounts runtime');
like($app, qr/unlink_identity\(\s*account_id\s*=>\s*\$account->\{id\}.*?actor_account_id\s*=>\s*\$account->\{id\}/s, 'app passes account actor context into identity unlinking');
like($app, qr{path eq '/account/profile'}, 'app dispatch exposes public account profile editing');
like($app, qr{path eq '/account/password/forgot'}, 'app dispatch exposes public account password reset requests');
like($app, qr{account/password/reset/\(\[0-9a-fA-F\]\{64\}\)}, 'app dispatch exposes tokenized public account password resets');
like($app, qr{action="/account/password/forgot"}, 'account login page links to public account password reset requests');
like($app, qr{sub _account_forgot_password_post.*?create_password_reset_token_for_email.*?_send_account_password_reset_email.*?account\.password_reset_delivery_failed}s, 'account password reset request path creates non-enumerating reset links and audits delivery failures');
like($app, qr{sub _account_password_reset_post.*?consume_password_reset_token.*?Password updated}s, 'account password reset submit path consumes tokens through the Accounts runtime');
like($app, qr{path eq '/account/identity/google/start'}, 'app dispatch exposes Google identity linking');
like($app, qr{path eq '/account/identity/oidc/start'}, 'app dispatch exposes OIDC identity linking');
like($app, qr{path eq '/account/identity/unlink'}, 'app dispatch exposes identity unlinking');
like($app, qr{path eq '/account/notifications'}, 'app dispatch exposes the public account notification inbox');
like($app, qr/sub _account_realtime_notification_source.*?Settings::all.*?Realtime->channel_token.*?realtime_public_url.*?data-realtime-channel.*?data-realtime-token/s, 'account notification page issues signed realtime channel metadata from saved realtime settings only after account session resolution');
like($app, qr{path eq '/admin/notifications/retry-due'}, 'app dispatch exposes admin notification delivery retries');
like($app, qr/sub _notifications_retry_due.*?retry_due_deliveries.*?notifications\.retry_due/s, 'Notification Center retry action processes due deliveries and audits the attempt');
like($app, qr/sub _notifications_page.*?Delivery Queue.*?sub _notification_delivery_rows.*?retryable_deliveries/s, 'Notification Center renders queued and failed delivery state');
like($app, qr{path eq '/account/notifications/mark-read'}, 'app dispatch exposes account notification mark-read actions');
like($app, qr{path eq '/account/notifications/preferences'}, 'app dispatch exposes account notification preferences');
like($app, qr{href="/account/notifications"}, 'account dashboard links to notification settings');
like($app, qr/name="notification_topic"/, 'account notification preferences render topic checkboxes');
like($app, qr/sub _request_values/, 'account notification preferences preserve repeated checkbox values');
like($app, qr/realtime_allowed_origins/, 'Realtime admin settings expose allowed browser origins');
like($app, qr/realtime_public_url/, 'Realtime admin settings expose the public browser events URL');
like($app, qr/normalize_public_url\(\$request->param\('realtime_public_url'\)/, 'Realtime admin settings normalize the public browser events URL before saving');
like($app, qr/normalize_allowed_origins\(\$request->param\('realtime_allowed_origins'\)/, 'Realtime admin settings normalize allowed origins before saving');
like($app, qr/sub _realtime_publish_adapter.*?Settings::all.*?realtime_enabled.*?Realtime->publish\(\$self->\{config\}, \$event\)/s, 'app realtime publisher honors saved realtime enablement before publishing events');

my $accounts = _read("$app_root/lib/DesertCMS/Accounts.pm");
like($accounts, qr/sub normalize_allowed_domains/, 'Accounts module exposes hosted-domain normalization for SSO settings');
like($accounts, qr/sub oauth_provider_readiness/, 'Accounts module exposes provider readiness validation');
like($accounts, qr/OAuth redirect URI/, 'Accounts module validates OAuth callback URLs');
like($accounts, qr/OIDC discovery URL/, 'Accounts module validates OIDC discovery URLs');
like($accounts, qr/_require_https_issuer_url\(\$metadata->\{issuer\}, 'OIDC issuer'\)/, 'Accounts module validates discovered OIDC issuers with issuer-specific URL rules');
like($accounts, qr/must not include userinfo/, 'Accounts module rejects userinfo in OAuth and OIDC HTTPS URLs');
like($accounts, qr/must not include a fragment/, 'Accounts module rejects fragments in OAuth and OIDC HTTPS URLs');
like($accounts, qr/sub _require_https_issuer_url.*?must not include a query/s, 'Accounts module rejects query-bearing OIDC issuer identifiers');
is(
    DesertCMS::Accounts::_require_https_url('https://idp.example.test/oauth/callback?next=account', 'OAuth redirect URI'),
    'https://idp.example.test/oauth/callback?next=account',
    'Accounts HTTPS URL validation accepts ordinary HTTPS URLs'
);
my $issuer_query_ok = eval {
    DesertCMS::Accounts::_require_https_issuer_url('https://idp.example.test/issuer?tenant=desert', 'OIDC issuer');
    1;
};
ok(!$issuer_query_ok && $@ =~ /must not include a query/, 'Accounts issuer URL validation rejects query-bearing OIDC issuers');
my $userinfo_url_ok = eval {
    DesertCMS::Accounts::_require_https_url('https://client-secret@idp.example.test/certs', 'OIDC JWKS URL');
    1;
};
ok(!$userinfo_url_ok && $@ =~ /must not include userinfo/, 'Accounts HTTPS URL validation rejects userinfo credentials in provider URLs');
my $fragment_url_ok = eval {
    DesertCMS::Accounts::_require_https_url('https://idp.example.test/callback#token', 'OAuth redirect URI');
    1;
};
ok(!$fragment_url_ok && $@ =~ /must not include a fragment/, 'Accounts HTTPS URL validation rejects URL fragments');
like($accounts, qr/sub _oauth_provider_enabled.*?unless _setting_truthy\(\$settings->\{\$key\}\)/s, 'Accounts module keeps SSO providers disabled until explicitly enabled');
like($accounts, qr/Allowed email domain/, 'Accounts module rejects malformed hosted-domain allowlists');
like($accounts, qr/OAuth state was not found/, 'Accounts module rejects unknown OAuth states');
like($accounts, qr/ID token nonce did not match OAuth state/, 'Accounts module rejects ID tokens with mismatched OAuth nonces');
like($accounts, qr/defined\(\$claims->\{azp\}\).*?ID token authorized party is not trusted/s, 'Accounts module rejects mismatched ID-token authorized parties even with a single audience');
like($accounts, qr/OAuth provider returned an unverified email address"\s+unless exists\(\$claims->\{email_verified\}\) && _truthy_claim\(\$claims->\{email_verified\}\)/, 'Accounts module treats missing SSO email verification as unverified');
ok(DesertCMS::Accounts::_truthy_claim(JSON::PP::true), 'Accounts module accepts JSON true for SSO email verification');
ok(!DesertCMS::Accounts::_truthy_claim(JSON::PP::false), 'Accounts module rejects JSON false for SSO email verification');
ok(DesertCMS::Accounts::_truthy_claim('true'), 'Accounts module accepts explicit true string for SSO email verification');
ok(!DesertCMS::Accounts::_truthy_claim('yes'), 'Accounts module rejects non-standard truthy SSO email verification strings');
like($accounts, qr/ID token expiration is invalid/, 'Accounts module rejects malformed ID token temporal claims');
like($accounts, qr/not-before value is invalid/, 'Accounts module rejects ID tokens before the not-before clock-skew window');
like($accounts, qr/login_throttled\(scope => 'local'.*?account\.login_failed.*?reason => 'throttled'.*?return \(undef, 'throttled'\)/s, 'Accounts module audits throttled local login attempts');
like($accounts, qr/sub oauth_start.*?login_throttled\(scope => "sso:\$provider".*?_record_sso_failure.*?Too many SSO attempts.*?oauth_provider_metadata/s, 'Accounts module throttles SSO starts before provider metadata or state creation');
like($accounts, qr/login_throttled\(scope => "sso:\$provider".*?_consume_oauth_state/s, 'Accounts module throttles SSO callbacks before consuming OAuth state');
unlike($accounts, qr/subject\s*=>\s*\$provider/, 'Accounts SSO throttling does not use the provider as a global lockout subject');
like($accounts, qr/\$failure_subject = int\(\$state_row->\{account_id\} \|\| 0\) > 0 \? 'account:' \. int\(\$state_row->\{account_id\}\) : ''/, 'Accounts SSO callback throttling becomes account-scoped only after OAuth state consumption');
like($accounts, qr/sub record_sso_failure/, 'Accounts module exposes failed SSO attempt and audit recording');
like($accounts, qr/sub oauth_complete.*?if \(!\$link_account_id\) \{.*?UPDATE user_accounts SET last_login_at = \?, updated_at = \? WHERE id = \?.*?event_type => 'account\.sso_login'/s, 'Accounts SSO sign-ins update last-login timestamps without treating profile-link flows as logins');
like($accounts, qr/event_type\s*=>\s*'account\.logout'/, 'Accounts runtime records logout audit events when sessions are revoked');
like($accounts, qr/sub create_password_reset_token_for_email.*?login_throttled\(scope => 'password_reset'.*?user_account_password_reset_tokens.*?account\.password_reset_requested/s, 'Accounts password reset requests are throttled, tokenized, and audited');
like($accounts, qr/sub password_reset_from_token.*?user_account_password_reset_tokens.*?status = 'pending'.*?a\.status = 'active'/s, 'Accounts password reset token lookup requires pending tokens and active accounts');
like($accounts, qr/sub consume_password_reset_token.*?UPDATE user_accounts.*?password_hash.*?UPDATE user_account_password_reset_tokens SET status = 'used'.*?UPDATE user_account_sessions SET revoked_at.*?account\.password_reset_used/s, 'Accounts password reset consumption updates the password, marks tokens used, revokes sessions, and audits use');
like($accounts, qr/sub upsert_identity.*?event_type\s*=>\s*'account\.identity_linked'/s, 'Accounts shared identity linking records provider-link audit events');
like($accounts, qr/sub oauth_complete.*?my %audit_actor = \$link_account_id \? \(actor_account_id => \$link_account_id\) : \(\).*?event_type => 'account\.identity_linked'/s, 'Accounts SSO profile-link audit events retain the logged-in account actor');
like($accounts, qr/sub upsert_identity.*?account_by_email\(\$email\).*?SSO email is already associated with another account/s, 'Accounts shared identity linking rejects profile-link email ownership conflicts');
like($accounts, qr/sub unlink_identity.*?account is not active.*?actor_account_id/s, 'Accounts shared identity unlinking rejects inactive accounts and records actor context');
like($accounts, qr/sub unlink_identity.*?_identity_unlink_actor\(%args, account_id => \$account_id\).*?account\.identity_unlinked.*?sub _identity_unlink_actor.*?identity unlink actor account or active admin user is required/s, 'Accounts shared identity unlinking requires explicit account or admin actor context');
like($accounts, qr/sub _identity_unlink_actor.*?identity unlink actor account is not active.*?identity unlink actor cannot modify this account/s, 'Accounts shared identity unlinking validates actor ownership and active state');
like($accounts, qr/link_mode\s*=>\s*\$link_mode/, 'Accounts module records SSO link-mode audit details');
like($accounts, qr/UPDATE user_account_oauth_states SET consumed_at = \? WHERE id = \? AND consumed_at IS NULL.*?defined\(\$changed\) && \$changed > 0/s, 'Accounts OAuth state consumption requires the conditional update to affect a row');
like($accounts, qr/email_merge/, 'Accounts module distinguishes existing-email SSO merges');
like($accounts, qr/sub _status_actor/, 'Accounts module centralizes account moderation actor validation');
like($accounts, qr/account moderation actor account, active admin user, or system action is required/, 'Accounts module rejects actorless account moderation');
like($accounts, qr/account moderation actor permission required/, 'Accounts module rejects non-moderator account moderation actors');
like($accounts, qr/actor_user_id/, 'Accounts audit events store admin user actor context');
like($accounts, qr/refresh => 1/, 'Accounts ID-token validation can refresh JWKS after a missing cached signing key');
like($accounts, qr/sub _pem_public_key_from_rsa_jwk/, 'Accounts ID-token validation can build OpenSSL public keys from RSA JWK modulus and exponent');
like($accounts, qr/ID token signing key does not include RSA modulus and exponent/, 'Accounts ID-token validation rejects RSA JWKs without usable key material');

my $rsa_jwk_pem = DesertCMS::Accounts::_pem_public_key_from_rsa_jwk({
    n => _test_b64url("\x01\x02\x03\x04\x05"),
    e => _test_b64url("\x01\x00\x01"),
});
like($rsa_jwk_pem, qr/\A-----BEGIN PUBLIC KEY-----\n/, 'Accounts module renders RSA JWK n/e as a PEM public key');
like($rsa_jwk_pem, qr/-----END PUBLIC KEY-----\n\z/, 'Accounts module terminates RSA JWK PEM public keys correctly');
my $missing_rsa_jwk_ok = eval {
    DesertCMS::Accounts::_pem_public_key_from_rsa_jwk({ kid => 'missing-rsa-material' });
    1;
};
ok(!$missing_rsa_jwk_ok && $@ =~ /RSA modulus and exponent/, 'Accounts module rejects RSA JWK public-key conversion without n/e fields');

my $jwks_accounts = DesertCMS::Accounts->new(
    config => LocalSecurityConfig->new(app_secret => 'jwks-rotation-secret'),
    db     => bless({}, 'LocalSecurityDB'),
);
my $oidc_metadata_settings = {
    accounts_oidc_client_id     => 'oidc-client-id',
    accounts_oidc_client_secret => 'oidc-client-secret',
    accounts_oidc_discovery_url => 'https://idp.example.test/.well-known/openid-configuration',
};
my $good_oidc_metadata = $jwks_accounts->oauth_provider_metadata(
    provider => 'oidc',
    settings => $oidc_metadata_settings,
    http     => LocalOIDCDiscoveryHTTP->new(issuer => 'https://idp.example.test'),
);
is($good_oidc_metadata->{issuer}, 'https://idp.example.test', 'Accounts OIDC discovery accepts HTTPS issuer metadata');
my $bad_oidc_issuer_ok = eval {
    $jwks_accounts->oauth_provider_metadata(
        provider => 'oidc',
        settings => $oidc_metadata_settings,
        http     => LocalOIDCDiscoveryHTTP->new(issuer => 'http://idp.example.test'),
    );
    1;
};
ok(!$bad_oidc_issuer_ok && $@ =~ /OIDC issuer must use https/, 'Accounts OIDC discovery rejects non-HTTPS issuer metadata');
my $jwks_uri = 'https://idp.example.test/certs';
$jwks_accounts->{jwks_cache}{$jwks_uri} = {
    jwks       => { keys => [ { kid => 'old-key', kty => 'RSA', alg => 'RS256', use => 'sig' } ] },
    expires_at => time + 3600,
};
my $jwks_http = LocalJwksHTTP->new(
    { keys => [ { kid => 'new-key', kty => 'RSA', alg => 'RS256', use => 'sig' } ] },
);
my $jwks_nonce = 'jwks-rotation-nonce';
my $jwks_claims = $jwks_accounts->_validate_id_token(
    provider  => 'oidc',
    metadata  => {
        issuer   => 'https://idp.example.test',
        jwks_uri => $jwks_uri,
    },
    state_row => { nonce_hash => $jwks_accounts->_oauth_nonce_hash($jwks_nonce) },
    token     => _test_jwt(
        { alg => 'RS256', kid => 'new-key' },
        {
            iss   => 'https://idp.example.test',
            aud   => 'oidc-client-id',
            sub   => 'jwks-rotation-subject',
            exp   => time + 600,
            nonce => $jwks_nonce,
        },
    ),
    http      => $jwks_http,
    client_id => 'oidc-client-id',
    verifier  => sub {
        my (%args) = @_;
        return ($args{jwk}{kid} || '') eq 'new-key';
    },
);
is($jwks_claims->{sub}, 'jwks-rotation-subject', 'Accounts ID-token validation accepts a provider key after JWKS rotation refresh');
is($jwks_http->{gets}, 1, 'Accounts ID-token validation refetches JWKS once when the cached signing key is missing');
my $bad_azp_nonce = 'bad-authorized-party-nonce';
my $bad_azp_ok = eval {
    $jwks_accounts->_validate_id_token(
        provider  => 'oidc',
        metadata  => {
            issuer   => 'https://idp.example.test',
            jwks_uri => $jwks_uri,
        },
        state_row => { nonce_hash => $jwks_accounts->_oauth_nonce_hash($bad_azp_nonce) },
        token     => _test_jwt(
            { alg => 'RS256', kid => 'new-key' },
            {
                iss   => 'https://idp.example.test',
                aud   => 'oidc-client-id',
                azp   => 'other-client-id',
                sub   => 'bad-authorized-party-subject',
                exp   => time + 600,
                nonce => $bad_azp_nonce,
            },
        ),
        http      => $jwks_http,
        client_id => 'oidc-client-id',
        verifier  => sub { 1 },
    );
    1;
};
ok(!$bad_azp_ok && $@ =~ /authorized party is not trusted/, 'Accounts ID-token validation rejects a mismatched authorized party even when audience matches');

my $bad_signature_accounts = DesertCMS::Accounts->new(
    config => LocalSecurityConfig->new(app_secret => 'jwks-signature-secret'),
    db     => bless({}, 'LocalSecurityDB'),
);
$bad_signature_accounts->{jwks_cache}{$jwks_uri} = {
    jwks       => { keys => [ { kid => 'signature-key', kty => 'RSA', alg => 'RS256', use => 'sig' } ] },
    expires_at => time + 3600,
};
my $bad_signature_http = LocalJwksHTTP->new(
    { keys => [ { kid => 'rotated-signature-key', kty => 'RSA', alg => 'RS256', use => 'sig' } ] },
);
my $bad_signature_nonce = 'jwks-bad-signature-nonce';
my $bad_signature_ok = eval {
    $bad_signature_accounts->_validate_id_token(
        provider  => 'oidc',
        metadata  => {
            issuer   => 'https://idp.example.test',
            jwks_uri => $jwks_uri,
        },
        state_row => { nonce_hash => $bad_signature_accounts->_oauth_nonce_hash($bad_signature_nonce) },
        token     => _test_jwt(
            { alg => 'RS256', kid => 'signature-key' },
            {
                iss   => 'https://idp.example.test',
                aud   => 'oidc-client-id',
                sub   => 'bad-signature-subject',
                exp   => time + 600,
                nonce => $bad_signature_nonce,
            },
        ),
        http      => $bad_signature_http,
        client_id => 'oidc-client-id',
        verifier  => sub { 0 },
    );
    1;
};
ok(!$bad_signature_ok && $@ =~ /signature was invalid/, 'Accounts ID-token validation does not mask invalid signatures as JWKS rotation');
is($bad_signature_http->{gets}, 0, 'Accounts ID-token validation does not refetch JWKS after a signature failure with a matching key');

my $schema = _read("$app_root/sql/schema.sql");
like($schema, qr/user_account_audit_events.*actor_user_id/s, 'v3 schema stores admin actor context for account audit events');
like($schema, qr/CREATE TABLE IF NOT EXISTS user_account_password_reset_tokens.*idx_user_account_password_reset_tokens_account_status/s, 'v3 schema stores indexed public account password reset tokens');
like($schema, qr/CREATE TABLE IF NOT EXISTS live_chat_messages.*ip_address TEXT NOT NULL DEFAULT ''.*idx_live_chat_messages_ip_time/s, 'v3 schema stores and indexes live chat IP context');
like($schema, qr/CREATE TABLE IF NOT EXISTS forum_categories.*visibility TEXT NOT NULL DEFAULT 'public'.*'accounts'.*'moderators'/s, 'v3 schema stores Forum category visibility policy');
like($schema, qr/CREATE TABLE IF NOT EXISTS forum_topics.*ip_address TEXT NOT NULL DEFAULT ''.*CREATE TABLE IF NOT EXISTS forum_posts.*ip_address TEXT NOT NULL DEFAULT ''.*idx_forum_posts_ip_time/s, 'v3 schema stores and indexes Forum IP abuse-control context');
like($schema, qr/CREATE TABLE IF NOT EXISTS social_posts.*ip_address TEXT NOT NULL DEFAULT ''.*idx_social_posts_ip_time/s, 'v3 schema stores and indexes Social post IP context');
like($schema, qr/CREATE TABLE IF NOT EXISTS social_replies.*ip_address TEXT NOT NULL DEFAULT ''.*idx_social_replies_ip_time/s, 'v3 schema stores and indexes Social reply IP context');

my $db_source = _read("$app_root/lib/DesertCMS/DB.pm");
like($db_source, qr/CURRENT_SCHEMA_VERSION => 2026070618/, 'v3 schema version advances for legacy content revision migration repair');
like($db_source, qr/_ensure_columns\('content_revisions'.*?author_user_id.*?access_policy.*?tags_text/s, 'DB migration repairs legacy content revision ownership and v3 publishing columns idempotently');
like($db_source, qr/_ensure_columns\('forum_categories'.*?visibility.*?public.*?accounts.*?moderators/s, 'DB migration repairs Forum category visibility idempotently');
like($db_source, qr/_ensure_columns\('forum_topics'.*?ip_address.*?_ensure_columns\('forum_posts'.*?ip_address.*?idx_forum_posts_ip_time/s, 'DB migration repairs Forum IP abuse-control columns and indexes idempotently');
like($db_source, qr/_ensure_columns\('live_chat_messages'.*?ip_address.*?idx_live_chat_messages_ip_time/s, 'DB migration repairs live chat IP columns and indexes idempotently');
like($db_source, qr/_ensure_columns\('social_posts'.*?ip_address.*?_ensure_columns\('social_replies'.*?ip_address.*?idx_social_posts_ip_time.*?idx_social_replies_ip_time/s, 'DB migration repairs Social IP columns and indexes idempotently');

my $migration_regression = _read("$app_root/t/44_v3_migration_regression.t");
like($migration_regression, qr/legacy-page.*?v3 migration preserves imported page content type.*?Legacy Revision.*?author_user_id.*?CREATE TABLE content_revisions/s, 'v3 migration regression covers legacy pages and content revisions, not only posts');
like($migration_regression, qr/user_account_password_reset_tokens.*idx_user_account_password_reset_tokens_account_status/s, 'v3 migration regression covers Account password reset tables and indexes');
like($migration_regression, qr/live_chat_messages.*idx_live_chat_messages_ip_time/s, 'v3 migration regression covers Live Streaming chat IP abuse-control columns and indexes');
like($migration_regression, qr/forum_categories.*visibility/s, 'v3 migration regression covers Forum category visibility policy');
like($migration_regression, qr/forum_topics.*ip_address.*forum_posts.*ip_address.*idx_forum_posts_ip_time/s, 'v3 migration regression covers Forum IP abuse-control columns and indexes');
like($migration_regression, qr/social_posts.*social_replies.*idx_social_posts_ip_time.*idx_social_replies_ip_time/s, 'v3 migration regression covers Social IP abuse-control columns and indexes');

my $settings_source = _read("$app_root/lib/DesertCMS/Settings.pm");
like($settings_source, qr/sub set_many.*?_social_requires_accounts\(\$db, \$values\).*?module_accounts_enabled.*?sub _social_requires_accounts.*?module_social_enabled/s, 'Settings persistence blocks disabling Accounts while Social remains active');

my $forums = _read("$app_root/lib/DesertCMS/Forums.pm");
like($forums, qr/sub _moderation_actor/, 'Forums module centralizes moderation actor validation');
like($forums, qr/forum moderator account or active admin user is required/, 'Forums module rejects actorless moderation');
like($forums, qr/forum_report_post/, 'Forums module uses explicit system moderation actions for report flows');
like($forums, qr/duplicate forum report suppressed/, 'Forums module suppresses duplicate open reports');
like($forums, qr/sub categories.*?t\.status NOT IN \('hidden', 'deleted'\).*?ta\.status = 'active'.*?p\.status = 'visible'.*?pa\.status = 'active'/s, 'Forums module applies public visibility rules to category aggregate counts');
like($forums, qr/sub topics_for_category.*?my \$post_join = \$include_hidden.*?p\.status = 'visible'.*?pa\.status = 'active'.*?sub latest_topics.*?p\.status = 'visible'.*?pa\.status = 'active'/s, 'Forums module applies public visibility rules to topic reply counts');
like($forums, qr/sub topics_for_category.*?return \[\] if !\$include_hidden && \(\$category->\{status\} \|\| ''\) eq 'hidden'.*?sub topic_by_slug.*?c\.status <> 'hidden'.*?sub posts_for_topic.*?category_status/s, 'Forums module enforces hidden category visibility in public read helpers');
like($forums, qr/sub topics_for_category.*?a\.status = 'active'.*?sub latest_topics.*?a\.status = 'active'.*?sub topic_by_slug.*?a\.status = 'active'.*?sub posts_for_topic.*?p\.status = 'visible' AND a\.status = 'active'.*?sub can_account.*?_row_account_active/s, 'Forums module hides disabled-account content from public read helpers');
like($forums, qr/sub can_view_category.*?visibility eq 'public'.*?visibility eq 'accounts'.*?forum moderator permission required/s, 'Forums module enforces public, account-only, and moderator-only category visibility');
like($forums, qr/sub can_view_topic.*?can_view_category/s, 'Forums module routes topic visibility through category visibility policy');
like($forums, qr/sub can_account.*?create_topic.*?can_view_category.*?reply.*?can_view_topic/s, 'Forums write/report permissions include category visibility checks');
like($forums, qr/sub _category_visibility_sql.*?public.*?accounts.*?moderators/s, 'Forums list queries share the category visibility SQL policy');
like($forums, qr/sub edit_post.*?can_edit_post\(post => \$post, account_id => \$account_id\).*?forum permission denied/s, 'Forums module routes post edits through the central edit permission gate');
like($forums, qr/sub delete_post.*?can_delete_post\(post => \$post, account_id => \$account_id\).*?status = \?, updated_at = \?.*?deleted/s, 'Forums module routes public post soft deletes through the central delete permission gate');
like($forums, qr/sub can_delete_post.*?forum topic starter cannot be deleted here.*?forum post delete window has closed/s, 'Forums module limits public soft delete to author-owned replies inside the edit window');
like($forums, qr/return _permission\(1, ''\) if \$moderator && \$action =~ \/\\A\(\?:view\|lock\|hide\|pin\|moderate\|delete\)\\z\//, 'Forums module keeps public report permission out of the moderator bypass');
like($forums, qr/sub _enforce_write_limits.*?forum_max_posts_per_ip_window.*?duplicate forum post suppressed.*?sub _account_old_enough.*?forum_min_account_age_seconds/s, 'Forums module enforces minimum account age, per-IP write limits, and duplicate suppression');
like($forums, qr/actor_user_id\s*=>\s*\$actor\{actor_user_id\}/, 'Forums moderation notifications carry admin user context');
like($forums, qr/sub set_topic_status.*?my \$existing = \$self->topic_by_id\(\$id\).*?my %actor = \$self->_moderation_actor\(%args\).*?return \$existing if \(\$existing->\{status\} \|\| ''\) eq \$status && \(\$existing->\{moderator_note\} \|\| ''\) eq \$note.*?forums\.moderation_action/s, 'Forums topic moderation status saves are idempotent after actor validation');
like($forums, qr/sub pin_topic.*?my \$existing = \$self->topic_by_id\(\$id\).*?my %actor = \$self->_moderation_actor\(%args\).*?my \$pinned = \$args\{pinned\} \? 1 : 0;.*?return \$existing if int\(\$existing->\{pinned\} \|\| 0\) == \$pinned.*?pinned => \$pinned/s, 'Forums topic pin saves are idempotent after actor validation');
like($forums, qr/sub set_post_status.*?my \$existing = \$self->post_by_id\(\$id\).*?my %actor = \$self->_moderation_actor\(%args\).*?return \$existing if \(\$existing->\{status\} \|\| ''\) eq \$status && \(\$existing->\{moderator_note\} \|\| ''\) eq \$note.*?forums\.moderation_action/s, 'Forums post moderation status saves are idempotent after actor validation');
like($forums, qr/sub set_report_status.*?forum report was not found.*?my %actor = \$self->_moderation_actor\(%args\).*?return \$existing if \(\$existing->\{status\} \|\| ''\) eq \$status && \(\$existing->\{moderator_note\} \|\| ''\) eq \$note/s, 'Forums report moderation rejects missing reports and suppresses no-op status notifications');

my $social = _read("$app_root/lib/DesertCMS/Social.pm");
like($social, qr/sub _require_moderator/, 'Social module exposes moderator-role enforcement');
like($social, qr/social moderator permission required/, 'Social module rejects non-moderator account moderation');
like($social, qr/sub _moderation_actor/, 'Social module centralizes moderation actor validation');
like($social, qr/social moderator account or active admin user is required/, 'Social module rejects actorless moderation');
like($social, qr/social_report_reply/, 'Social module uses explicit system moderation actions for report flows');
like($social, qr/duplicate social report suppressed/, 'Social module suppresses duplicate open reports');
like($social, qr/sub create_post.*?my \$ip_address = _clean_ip\(\$args\{ip_address\}\).*?INSERT INTO social_posts.*?ip_address/s, 'Social module stores post IP context at creation');
like($social, qr/sub add_reply.*?my \$ip_address = _clean_ip\(\$args\{ip_address\}\).*?INSERT INTO social_replies.*?ip_address/s, 'Social module stores reply IP context at creation');
like($social, qr/sub _enforce_write_limits.*?social account is too new.*?social_max_posts_per_ip_window.*?social ip rate limit exceeded/s, 'Social module enforces minimum account age and per-IP post limits');
like($social, qr/sub _enforce_reply_limits.*?social account is too new.*?social_max_replies_per_ip_window.*?social ip rate limit exceeded/s, 'Social module enforces minimum account age and per-IP reply limits');
like($social, qr/sub follow.*?_require_active_profile\(\$follower, 'follower'\).*?my \$previous_status = \$self->follow_status.*?social\.follow.*?\$previous_status/s, 'Social module requires active follower profiles and suppresses duplicate follow notifications');
like($social, qr/sub follow.*?social profile is blocked.*?_blocked_between/s, 'Social module blocks new follows across blocked relationships');
like($social, qr/sub block.*?DELETE FROM social_follows.*?status = 'blocked'/s, 'Social module exposes first-class blocking and removes reciprocal follows');
like($social, qr/sub unblock.*?DELETE FROM social_follows.*?status = 'blocked'/s, 'Social module exposes first-class unblocking');
like($social, qr/sub react.*?_require_active_profile\(\$account_id, 'reactor'\).*?my \$changed = \$self->\{db\}->dbh->do.*?social\.reaction.*?int\(\$changed \|\| 0\) > 0/s, 'Social module requires active reactor profiles and only emits reaction notifications for new reactions');
like($social, qr/sub profile_by_handle.*?can_view_profile/s, 'Social module enforces profile visibility in public profile lookup');
like($social, qr/sub report_profile.*?can_view_profile\(viewer_account_id => \$reporter_id, profile => \$profile\).*?social profile is not visible/s, 'Social module enforces profile visibility in profile reports');
like($social, qr/sub report_post.*?reporter account is not active.*?can_view_post\(viewer_account_id => \$reporter_id/s, 'Social module requires active reporter accounts for post reports');
like($social, qr/sub report_reply.*?reporter account is not active.*?social reply is not visible/s, 'Social module requires active reporter accounts for reply reports');
like($social, qr/sp\.visibility IN \('public', 'followers'\).*?sp\.visibility = 'public'/s, 'Social module enforces profile visibility in feed helpers');
like($social, qr/kind\} \|\| ''\) eq 'following'.*?_account_active\(\$viewer\).*?_active_profile\(\$viewer\)/s, 'Social module rejects disabled viewers and inactive profiles on following feeds');
like($social, qr/sub _active_profile.*?profile_for_account.*?account_status.*?sub _can_view_followers_content.*?_active_profile\(\$viewer\)/s, 'Social module gates follower-only direct visibility on active viewer profiles');
like($social, qr/sub reply_by_id.*?a\.status AS account_status.*?sub report_reply.*?account_status.*?active/s, 'Social module blocks public reports against disabled-account replies');
like($social, qr/sub _emit_mentions.*?can_view_post/s, 'Social module only emits mention notifications for recipients who can view the post');
like($social, qr/actor_account_id\s*=>\s*\$actor\{actor_account_id\}/, 'Social moderation notifications carry moderator account context');
like($social, qr/actor_user_id\s*=>\s*\$actor\{actor_user_id\}/, 'Social moderation notifications carry admin user context');
like($social, qr/sub set_post_status.*?my \$post = \$self->post_by_id\(\$id\).*?my %actor = \$self->_moderation_actor\(%args\).*?return \$post if \(\$post->\{status\} \|\| ''\) eq \$status.*?social\.moderation_needed/s, 'Social post moderation status saves are idempotent after actor validation');
like($social, qr/sub set_reply_status.*?my \$reply = \$self->reply_by_id\(\$id\).*?my %actor = \$self->_moderation_actor\(%args\).*?return \$reply if \(\$reply->\{status\} \|\| ''\) eq \$status.*?social\.moderation_needed/s, 'Social reply moderation status saves are idempotent after actor validation');
like($social, qr/sub delete_post.*?can_delete_post\(post => \$post, account_id => \$account_id\).*?UPDATE social_posts SET status = \?, updated_at = \?.*?deleted/s, 'Social public post deletes route through the central ownership gate');
like($social, qr/sub delete_reply.*?can_delete_reply\(reply => \$reply, account_id => \$account_id\).*?UPDATE social_replies SET status = \?, updated_at = \?.*?deleted/s, 'Social public reply deletes route through the central ownership gate');
like($social, qr/sub can_delete_post.*?social post belongs to another account.*?social post delete window has closed/s, 'Social limits public post soft delete to author-owned posts inside the delete window');
like($social, qr/sub can_delete_reply.*?social reply belongs to another account.*?social reply delete window has closed/s, 'Social limits public reply soft delete to author-owned replies inside the delete window');
like($social, qr/sub set_profile_status.*?my \$profile = \$self->profile_for_account\(\$account_id\).*?my %actor = \$self->_moderation_actor.*?return \$profile if \(\$profile->\{status\} \|\| ''\) eq \$status.*?social\.moderation_needed/s, 'Social profile moderation status saves are idempotent after actor validation');
like($social, qr/sub set_report_status.*?social report was not found.*?my %actor = \$self->_moderation_actor\(%args\).*?return \$existing if \(\$existing->\{status\} \|\| ''\) eq \$status && \(\$existing->\{moderator_note\} \|\| ''\) eq \$note/s, 'Social report moderation rejects missing reports and suppresses no-op notifications');

my $live_streaming = _read("$app_root/lib/DesertCMS/LiveStreaming.pm");
like($live_streaming, qr/sub _publish_realtime/, 'Live Streaming runtime centralizes realtime publish delivery state');
like($live_streaming, qr/sub _session_lifecycle_actor/, 'Live Streaming runtime centralizes stream lifecycle actor validation');
like($live_streaming, qr/live session moderator account or active admin user is required/, 'Live Streaming runtime rejects actorless stream lifecycle changes');
like($live_streaming, qr/_emit_stream_status_notification\(\$session,\s*\$status,\s*%actor\)/, 'Live Streaming manual lifecycle notifications include actor context');
like($live_streaming, qr/stream_worker_heartbeat/, 'Live Streaming worker lifecycle notifications use an explicit system action');
like($live_streaming, qr/sub _moderation_actor/, 'Live Streaming runtime centralizes chat moderation actor validation');
like($live_streaming, qr/live chat moderator account or active admin user is required/, 'Live Streaming runtime rejects actorless chat moderation');
like($live_streaming, qr/live chat moderator permission required/, 'Live Streaming runtime rejects non-moderator account chat moderation');
like($live_streaming, qr/actor_account_id\s*=>\s*\$actor\{actor_account_id\}/, 'Live Streaming moderation notifications carry moderator account context');
like($live_streaming, qr/actor_user_id\s*=>\s*\$actor\{actor_user_id\}/, 'Live Streaming moderation notifications carry admin user context');
like($live_streaming, qr/sub set_session_status.*?my \$existing = \$self->session_by_id\(\$id\).*?my %actor = \$self->_session_lifecycle_actor\(%args\).*?return \$existing.*?status ne 'live'.*?ended\|failed.*?_emit_stream_status_notification/s, 'Live Streaming session status changes are idempotent after actor validation');
like($live_streaming, qr/sub set_chat_status.*?my \$existing = \$self->chat_message_by_id\(\$id\).*?my %actor = \$self->_moderation_actor\(%args\).*?return \$existing if \(\$existing->\{status\} \|\| ''\) eq \$status.*?stream\.chat_moderated/s, 'Live Streaming chat moderation status saves are idempotent after actor validation');
like($live_streaming, qr/sub delete_own_chat_message.*?can_delete_own_chat_message\(message => \$message, account_id => \$account_id\).*?status = \?, updated_at = \?.*?deleted/s, 'Live Streaming author chat deletes route through the central ownership gate');
like($live_streaming, qr/sub can_delete_own_chat_message.*?belongs to another account.*?live chat message delete window has closed/s, 'Live Streaming limits public chat soft delete to author-owned messages inside the delete window');
like($live_streaming, qr/sub set_chat_report_status.*?live chat report was not found.*?my %actor = \$self->_moderation_actor\(%args\).*?return \$existing if \(\$existing->\{status\} \|\| ''\) eq \$status && \(\$existing->\{moderator_note\} \|\| ''\) eq \$note/s, 'Live Streaming chat report moderation rejects missing reports and suppresses no-op notifications');
like($live_streaming, qr/presence_event\(\$session\)/, 'Live Streaming runtime publishes stream presence updates');
like($live_streaming, qr/chat_event\(\$message\)/, 'Live Streaming runtime publishes live chat updates');
like($live_streaming, qr/live_presence_event\(\$presence\)/, 'Live Streaming runtime publishes live chat presence updates');
like($live_streaming, qr/m\.account_id IS NULL OR a\.status = 'active'/, 'Live Streaming public chat history hides disabled-account messages');
like($live_streaming, qr/sub add_chat_message.*?my \$ip_address = _clean_ip\(\$args\{ip_address\}\).*?INSERT INTO live_chat_messages.*?ip_address/s, 'Live Streaming runtime stores chat IP context at creation');
like($live_streaming, qr/sub chat_messages.*?if \(!\$include_hidden\).*?delete \$_->\{ip_address\} for \@\{\$rows\}/s, 'Live Streaming runtime strips chat IP context from public chat history');
like($live_streaming, qr/sub _enforce_chat_ip_rate_limit.*?live_chat_max_messages_per_ip_window.*?live chat ip rate limit exceeded/s, 'Live Streaming runtime enforces per-IP chat rate limits');
like($live_streaming, qr/include_inactive.*?p\.account_id IS NULL OR a\.status = 'active'/s, 'Live Streaming public chat presence hides disabled accounts');
like($live_streaming, qr/sub validate_hls_path.*?live_hls_public_prefix.*?_valid_hls_path/s, 'Live Streaming validates HLS paths against the configured public prefix');
like($live_streaming, qr/sub record_worker_heartbeat.*?my \$hls_prefix = _hls_prefix.*?_hls_path_or_die\(\$args\{hls_output_path\}, \$hls_prefix\).*?\$details->\{log_line\} = \$self->worker_log_line.*?hls_output_path => \$hls_output_path/s, 'Live Streaming sanitizes worker heartbeat HLS paths before storing heartbeat log details');
like($live_streaming, qr/sub _record_worker_event/, 'Live Streaming runtime persists structured worker events');
like($live_streaming, qr/sub _record_worker_event.*?_worker_event_hls_path.*?prefix\s*=>\s*_hls_prefix.*?sub _worker_event_hls_path.*?hls_output_path_rejected.*?invalid_public_hls_path/s, 'Live Streaming worker event telemetry rejects unsafe HLS output paths using the configured public prefix');
like($live_streaming, qr/sub worker_events/, 'Live Streaming runtime exposes worker event history');
like($live_streaming, qr/sub worker_event_summary/, 'Live Streaming runtime exposes worker event health summaries');
like($live_streaming, qr/sub due_scheduled_sessions.*?scheduled_at <= \?.*?schedule_due_notified_at/s, 'Live Streaming runtime lists due scheduled sessions without already-notified rows');
like($live_streaming, qr/sub emit_schedule_due_notifications.*?stream\.schedule_due.*?_mark_schedule_due_notified/s, 'Live Streaming runtime emits idempotent scheduled-stream due notifications');
like($live_streaming, qr/sub _reject_worker_auth/, 'Live Streaming runtime records rejected worker auth attempts');
like($live_streaming, qr/stream_key_rejected/, 'Live Streaming runtime labels rejected stream-key attempts');
like($live_streaming, qr/sub rotate_stream_key.*?die "live channel was not found" unless defined\(\$rows\) && \$rows > 0.*?sub revoke_stream_key.*?die "live channel was not found" unless defined\(\$rows\) && \$rows > 0/s, 'Live Streaming runtime fails closed for missing stream-key rotation and revocation targets');
like($live_streaming, qr/sub _stream_key_rejection.*?stream_key_revoked.*?stream_key_missing.*?stream_key_rejected/s, 'Live Streaming runtime classifies revoked, missing, and rejected stream keys distinctly');
like($live_streaming, qr/sub worker_ingest_auth.*?_stream_key_rejection.*?details => \$key_rejection->\{details\}/s, 'Live Streaming worker auth preserves structured stream-key rejection reasons');
like($live_streaming, qr/sub ingest_authorized.*?_ingest_policy_rejection.*?sub worker_ingest_auth.*?_ingest_policy_rejection.*?ingest_policy_disabled.*?channel_status_rejected/s, 'Live Streaming runtime applies per-channel ingest policy to direct and worker auth');
like($live_streaming, qr/sub worker_ingest_auth.*?_normalize_worker_args.*?sub record_worker_ingest_heartbeat.*?_normalize_worker_args/s, 'Live Streaming worker auth and heartbeat normalize OBS callback stream names');
like($live_streaming, qr/sub _normalize_worker_args.*?stream_key.*?key.*?token.*?stream_name name stream.*?_stream_query_params.*?_stream_name_slug/s, 'Live Streaming worker normalization accepts query, slash, colon, and token callback aliases');
like($live_streaming, qr/session_lookup_failed.*?terminal and cannot accept worker heartbeats/s, 'Live Streaming runtime rejects worker heartbeats for terminal sessions');
like($live_streaming, qr/sub report_chat_message.*?live chat message is not visible.*?status = 'active'/s, 'Live Streaming runtime keeps public chat reports visibility-bound');
like($live_streaming, qr/system_action\s*=>\s*'live_chat_blocked_term'/, 'Live Streaming runtime preserves blocked-term system reports');
like($live_streaming, qr{\(\$match->\{action\} \|\| ''\) =~ /\\A\(\?:report\|hide\)\\z/.*?my \$message_status = \(\$message->\{status\} \|\| ''\) eq 'hidden' \? 'hidden' : 'reported'}s, 'Live Streaming queues hidden blocked-term matches without exposing them as reported chat');
like($live_streaming, qr/duplicate live chat report suppressed/, 'Live Streaming runtime suppresses duplicate open chat reports');
like($live_streaming, qr/sub delete_blocked_term.*?blocked_term_by_id.*?DELETE FROM live_chat_blocked_terms/s, 'Live Streaming runtime deletes blocked terms behind the module boundary');

my $realtime = _read("$app_root/lib/DesertCMS/Realtime.pm");
my $notifications_source = _read("$app_root/lib/DesertCMS/Notifications.pm");
like($notifications_source, qr/user notification recipient account is required/, 'Notifications runtime rejects unscoped public account notifications');
like($notifications_source, qr/user notification preference recipient account is required/, 'Notifications runtime rejects unscoped public account notification preferences');
like($notifications_source, qr/sub _recipient_account_active/, 'Notifications runtime validates active public account recipients');
like($notifications_source, qr/user notification recipient account is not active/, 'Notifications runtime rejects inactive public account recipients');
like($notifications_source, qr/user notification preference recipient account is not active/, 'Notifications runtime rejects inactive public account notification preferences');
like($notifications_source, qr/topic_registered\(\$topic\)/, 'Notifications runtime validates emitted topics against module manifests');
like($notifications_source, qr/sub module_topic_registered/, 'Notifications runtime validates module-owned topics');
like($notifications_source, qr/not registered for the module manifest/, 'Notifications runtime rejects cross-module notification topics');
like($notifications_source, qr/include_archived.*?status <> 'archived'/s, 'Notifications inbox helpers hide archived preference-muted notifications by default');
like($notifications_source, qr/sub list.*?_require_user_recipient_scope\('list'.*?sub unread_count.*?_require_user_recipient_scope\('unread_count'/s, 'Notifications runtime requires scoped public account inbox reads and counts');
like($notifications_source, qr/sub _require_user_recipient_scope.*?recipient account is required/s, 'Notifications runtime centralizes public account read scoping');
like($notifications_source, qr/sub mark_read.*?notification mark_read audience is required.*?user notification mark_read recipient account is required/s, 'Notifications runtime requires scoped mark-read operations');
like($notifications_source, qr/retryable_deliveries/, 'Notifications runtime exposes retryable adapter delivery state');
like($notifications_source, qr/sub retry_delivery.*?audience.*?user.*?_recipient_account_active.*?recipient account is not active/s, 'Notifications runtime skips retries for disabled public account recipients');
like($notifications_source, qr/sub retry_due_deliveries.*?record_delivery\(\s*delivery_id.*?status\s*=>\s*'failed'.*?next_retry_at\s*=>\s*now\(\) \+ 300/s, 'Notifications runtime persists thrown batch retry failures for later review');
like($notifications_source, qr/sub record_delivery.*?WHERE id = \? AND notification_id = \?.*?notification delivery was not found.*?SELECT \* FROM notification_deliveries WHERE id = \? AND notification_id = \?/s, 'Notifications runtime refuses cross-notification delivery updates');
like($realtime, qr/sub publish/, 'Realtime module can append validated events for service fanout');
like($realtime, qr/sub recent_events/, 'Realtime module can read recent events for SSE clients');
like($realtime, qr/sub normalize_channel_filter/, 'Realtime module validates requested channel filters');
like($realtime, qr/realtime channel filter is not allowed/, 'Realtime module rejects undeclared channel filters');
like($realtime, qr/sub event_channels/, 'Realtime module maps event types to explicit manifest channels');
like($realtime, qr/event channel is not allowed/, 'Realtime module rejects events outside their manifest channel');
like($realtime, qr/sub _scoped_channel_allowed.*?live\\.chat.*?stream\\.presence/s, 'Realtime module supports scoped streaming channels');
like($realtime, qr/user notification channel must be account scoped.*?sub _event_visible_for_filter.*?user\\.notifications/s, 'Realtime module keeps user notifications account-scoped in replay channels');
like($realtime, qr/sub notification_event.*?details\s*=>\s*\$details.*?sub _notification_details/s, 'Realtime module includes stored notification details in adapter events');
like($realtime, qr/sub channel_token.*?_channel_token_signature.*?sub channel_token_valid.*?constant_time_eq.*?sub _channel_token_signature.*?hmac_sha256_hex/s, 'Realtime module signs and verifies protected account notification channel tokens');
like($realtime, qr/sub channel_request_authorized.*?channel_requires_token.*?channel_token_valid/s, 'Realtime module centralizes private channel request authorization');
like($realtime, qr/sub _channel_matches_filter/, 'Realtime module lets base streaming channel filters include scoped channels');
like($realtime, qr/realtime-events\.jsonl/, 'Realtime module defaults to a local JSONL event log');
like($realtime, qr/sub websocket_accept_key/, 'Realtime module can validate WebSocket upgrade keys');
like($realtime, qr/sub websocket_text_frame/, 'Realtime module can frame server-to-client WebSocket messages');
like($realtime, qr/sub websocket_snapshot_frame/, 'Realtime module exposes WebSocket snapshots over the event log');
like($realtime, qr/sub origin_allowed/, 'Realtime module validates browser origins');
like($realtime, qr/sub cors_headers/, 'Realtime module emits safe CORS headers for allowed origins');
like($realtime, qr/sub normalize_allowed_origins/, 'Realtime module normalizes configured origin allowlists');
like($realtime, qr/sub normalize_public_url/, 'Realtime module normalizes the browser-facing events URL');
like($realtime, qr/wss:\/\/.*?ws:\/\//s, 'Realtime module derives WebSocket URLs with WebSocket schemes');

my $realtime_service = _read("$app_root/bin/desertcms-realtime.pl");
like($realtime_service, qr/recent_events/, 'Realtime service serves stored events instead of a static placeholder only');
like($realtime_service, qr/channel => \$params\{channel\}/, 'Realtime service supports channel-filtered SSE reads');
like($realtime_service, qr/bad realtime channel/, 'Realtime service reports invalid channel filters as bad requests');
like($realtime_service, qr/channel_request_authorized\(\s*\$config,\s*channel => \$params\{channel\} \|\| '',\s*token\s*=>\s*\$params\{token\}/s, 'Realtime service validates signed channel tokens before private stream reads');
like($realtime_service, qr/private realtime channel forbidden/, 'Realtime service rejects private account channels without valid tokens');
like($realtime_service, qr{\(\$path \|\| ''\) eq '/ws'}, 'Realtime service exposes a WebSocket endpoint');
like($realtime_service, qr/Sec-WebSocket-Accept/, 'Realtime service completes WebSocket handshakes');
like($realtime_service, qr/origin_allowed/, 'Realtime service enforces the origin allowlist');
like($realtime_service, qr/cors_headers/, 'Realtime service emits CORS headers for allowed SSE origins');
like($realtime_service, qr/origin forbidden/, 'Realtime service rejects forbidden browser origins');

my $security_center_source = _read("$app_root/lib/DesertCMS/SecurityCenter.pm");
like($security_center_source, qr/sub _realtime_origin_filter_check/, 'Security Center implements the realtime origin filter check');
like($security_center_source, qr/review_realtime_origins/, 'Security Center can guide realtime origin remediation');
like($security_center_source, qr/sub _streaming_worker_event_state/, 'Security Center implements streaming worker event telemetry checks');
like($security_center_source, qr/review_streaming_worker_events/, 'Security Center can guide streaming worker event remediation');

my $manifest = _read("$app_root/lib/DesertCMS/ModuleManifest.pm");
like($manifest, qr{method => 'POST', path => '/admin/settings/realtime'}, 'Realtime manifest declares settings save route');
like($manifest, qr{method => 'GET', path => '/ws'}, 'Realtime manifest declares WebSocket service route');
like($manifest, qr/realtime_allowed_origins/, 'Realtime manifest declares allowed origin settings');
like($manifest, qr/realtime_public_url/, 'Realtime manifest declares the public browser events URL setting');
like($manifest, qr/live_stream_worker_events/, 'Live Streaming manifest declares worker event migration');
like($manifest, qr{path => '/admin/settings/modules/posts/save'}, 'Posts manifest declares module settings save route');
like($manifest, qr{path => '/admin/posts'}, 'Posts manifest declares admin post list route');
like($manifest, qr{path => '/account/profile'}, 'Accounts manifest declares public profile route');
like($manifest, qr{path => '/admin/settings/modules/accounts/save'}, 'Accounts manifest declares module settings save route');
like($manifest, qr{path => '/account/password/forgot'}, 'Accounts manifest declares public password reset request route');
like($manifest, qr{path => '/account/password/reset/:token'}, 'Accounts manifest declares tokenized public password reset route');
like($manifest, qr/user_account_password_reset_tokens/, 'Accounts manifest declares password reset token migration');
like($manifest, qr{path => '/account/identity/google/start'}, 'Accounts manifest declares Google identity linking route');
like($manifest, qr{path => '/account/identity/oidc/start'}, 'Accounts manifest declares OIDC identity linking route');
like($manifest, qr{path => '/account/identity/unlink'}, 'Accounts manifest declares identity unlink route');
like($manifest, qr{path => '/admin/settings/modules/forums/save'}, 'Forums manifest declares module settings save route');
like($manifest, qr{path => '/forums/posts/:id/edit'}, 'Forums manifest declares public post edit route');
like($manifest, qr{path => '/forums/posts/:id/delete'}, 'Forums manifest declares public post soft-delete route');
like($manifest, qr{path => '/forums/report'}, 'Forums manifest declares public report route');
like($manifest, qr{path => '/admin/forums/categories/update'}, 'Forums manifest declares admin category policy update route');
like($manifest, qr{path => '/admin/forums/reports/status'}, 'Forums manifest declares admin report moderation route');
like($manifest, qr{path => '/admin/forums/posts/status'}, 'Forums manifest declares admin reply moderation route');
like($manifest, qr{path => '/admin/forums/topics/pin'}, 'Forums manifest declares admin topic pin route');
like($manifest, qr/forum\.edit/, 'Forums manifest declares edit permission');
like($manifest, qr{path => '/admin/settings/modules/social/save'}, 'Social manifest declares module settings save route');
like($manifest, qr{path => '/social/replies/create'}, 'Social manifest declares public reply route');
like($manifest, qr{path => '/social/follow'}, 'Social manifest declares public follow route');
like($manifest, qr{path => '/social/unfollow'}, 'Social manifest declares public unfollow route');
like($manifest, qr{path => '/social/block'}, 'Social manifest declares public block route');
like($manifest, qr{path => '/social/unblock'}, 'Social manifest declares public unblock route');
like($manifest, qr{path => '/social/react'}, 'Social manifest declares public reaction route');
like($manifest, qr{path => '/social/posts/delete'}, 'Social manifest declares public post delete route');
like($manifest, qr{path => '/social/replies/delete'}, 'Social manifest declares public reply delete route');
like($manifest, qr{path => '/social/report'}, 'Social manifest declares public report route');
like($manifest, qr{path => '/admin/social/reports/status'}, 'Social manifest declares admin report moderation route');
like($manifest, qr{path => '/admin/social/profiles/status'}, 'Social manifest declares admin profile moderation route');
like($manifest, qr{path => '/admin/settings/modules/live-streaming/save'}, 'Live Streaming manifest declares module settings save route');
like($manifest, qr{path => '/live/:slug/chat/report'}, 'Live Streaming manifest declares public chat report route');
like($manifest, qr{path => '/live/:slug/chat/delete'}, 'Live Streaming manifest declares public author chat delete route');
like($manifest, qr{path => '/admin/live/channels/key/rotate'}, 'Live Streaming manifest declares admin stream key rotation route');
like($manifest, qr{path => '/admin/live/channels/key/revoke'}, 'Live Streaming manifest declares admin stream key revocation route');
like($manifest, qr{path => '/admin/live/sessions/due'}, 'Live Streaming manifest declares admin due-session notification route');
like($manifest, qr{path => '/live/:slug/presence'}, 'Live Streaming manifest declares public chat presence route');
like($manifest, qr{path => '/live/worker/health'}, 'Live Streaming manifest declares worker health route');
like($manifest, qr{path => '/live/worker/auth'}, 'Live Streaming manifest declares worker auth route');
like($manifest, qr{path => '/live/worker/heartbeat'}, 'Live Streaming manifest declares worker heartbeat route');
like($manifest, qr{path => '/admin/live/chat/status'}, 'Live Streaming manifest declares admin chat moderation route');
like($manifest, qr{path => '/admin/live/blocked-terms/save'}, 'Live Streaming manifest declares admin blocked-term save route');
like($manifest, qr{path => '/admin/live/blocked-terms/delete'}, 'Live Streaming manifest declares admin blocked-term delete route');
like($manifest, qr/moderate_live_chat/, 'Live Streaming manifest declares chat moderation permission');
like($manifest, qr{path => '/admin/notifications'}, 'Notifications manifest declares admin notification center route');
like($manifest, qr{path => '/admin/notifications/mark-read'}, 'Notifications manifest declares admin notification mark-read route');
like($manifest, qr{path => '/admin/notifications/retry-due'}, 'Notifications manifest declares admin delivery retry route');
like($manifest, qr{path => '/admin/settings/modules/notifications/save'}, 'Notifications manifest declares module settings save route');
like($manifest, qr{path => '/account/notifications'}, 'Notifications manifest declares public account inbox route');
like($manifest, qr{path => '/account/notifications/mark-read'}, 'Notifications manifest declares public account mark-read route');
like($manifest, qr{path => '/account/notifications/preferences'}, 'Notifications manifest declares public account preferences route');
like($manifest, qr{path => '/admin/settings/security/queue'}, 'Security Center manifest declares root-worker queue route');
like($manifest, qr{path => '/admin/settings/modules/security-center/save'}, 'Security Center manifest declares module settings save route');

my $modules_source = _read("$app_root/lib/DesertCMS/Modules.pm");
for my $v3_module (
    [ accounts        => 'module_accounts_enabled' ],
    [ live_streaming => 'module_live_streaming_enabled' ],
    [ forums          => 'module_forums_enabled' ],
    [ social          => 'module_social_enabled' ],
    [ notifications   => 'module_notifications_enabled' ],
    [ security_center => 'module_security_center_enabled' ],
) {
    my ($key, $setting) = @{$v3_module};
    like(
        $modules_source,
        qr/key\s*=>\s*'$key'.*?setting_key\s*=>\s*'$setting'.*?default_plan_enabled\s*=>\s*[01]/s,
        "Modules catalog exposes $key as a SubCMS service-plan feature"
    );
}
like($modules_source, qr/sub _default_plan_feature_map.*?\@MODULE_DEFINITIONS/s, 'Modules default plan map is generated from module definitions');
like($modules_source, qr/my \$param = 'feature_' \. \$key \. '_included'/, 'Modules service-plan value parser accepts per-feature form fields');
like($app, qr/keys => \[qw\(posts accounts live_streaming forums social notifications\)\]/, 'service-plan form groups v3 community entitlements together');

SKIP: {
    skip 'set DESERTCMS_OPENBSD_INTEGRATION_TESTS=1 on an OpenBSD staging host to run real host integration', 1
        unless ($ENV{DESERTCMS_OPENBSD_INTEGRATION_TESTS} || '') eq '1';
    skip 'real host integration requires OpenBSD', 1 unless $^O eq 'openbsd';
    local $ENV{DESERTCMS_OPENBSD_INTEGRATION} = '1';
    my $real = DesertCMS::OpenBSDHostIntegration->new(
        app_root     => $app_root,
        staging_root => '/tmp/desertcms-v3-test',
    );
    my $results = $real->run(dry_run => 0);
    ok(!(grep { ($_->{status} || '') eq 'failed' } @{$results}), 'OpenBSD v3 real host integration passes on staging host');
}

done_testing;

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _test_jwt {
    my ($header, $claims) = @_;
    my $encoded_header = _test_b64url(encode_json($header || {}));
    my $encoded_claims = _test_b64url(encode_json($claims || {}));
    my $signature = _test_b64url('test-signature');
    return join '.', $encoded_header, $encoded_claims, $signature;
}

sub _test_b64url {
    my ($bytes) = @_;
    my $encoded = encode_base64($bytes || '', '');
    $encoded =~ tr{+/}{-_};
    $encoded =~ s/=+\z//;
    return $encoded;
}

sub _httpd_shape_fixture {
    return join "\n",
        'server "v3" {',
        '    location "/admin*" { fastcgi socket "/run/desertcms.sock"; param SCRIPT_NAME "/admin" }',
        '    location "/account*" { fastcgi socket "/run/desertcms.sock"; param SCRIPT_NAME "/account" }',
        '    location "/forums*" { fastcgi socket "/run/desertcms.sock"; param SCRIPT_NAME "/forums" }',
        '    location "/social*" { fastcgi socket "/run/desertcms.sock"; param SCRIPT_NAME "/social" }',
        '    location "/live*" { fastcgi socket "/run/desertcms.sock"; param SCRIPT_NAME "/live" }',
        '    location "/streams/*" { root "/htdocs/desertcms-v3-test" }',
        '}',
        '';
}
