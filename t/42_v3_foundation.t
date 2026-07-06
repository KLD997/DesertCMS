use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP qw(encode_json);
use MIME::Base64 qw(encode_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Accounts;
use DesertCMS::Analytics;
use DesertCMS::Blueprints;
use DesertCMS::Config;
use DesertCMS::Dashboard;
use DesertCMS::DB;
use DesertCMS::Forums;
use DesertCMS::HTTP;
use DesertCMS::LiveStreaming;
use DesertCMS::ModuleManifest;
use DesertCMS::Modules;
use DesertCMS::Notifications;
use DesertCMS::Realtime;
use DesertCMS::SecurityCenter;
use DesertCMS::Settings;
use DesertCMS::SiteTheme;
use DesertCMS::Social;

{
    package TestOAuthHTTP;

    sub new {
        my ($class, %args) = @_;
        return bless {
            issuer         => $args{issuer} || 'https://accounts.google.com',
            audience       => $args{audience} || 'google-client-id',
            subject        => $args{subject} || 'google-oauth-subject',
            email          => $args{email} || 'oauth-user@example.test',
            email_verified => exists $args{email_verified} ? $args{email_verified} : JSON::PP::true,
            omit_email_verified => $args{omit_email_verified} ? 1 : 0,
            name           => $args{name} || 'OAuth User',
            nonce          => $args{nonce} || '',
            exp            => $args{exp},
            nbf            => $args{nbf},
            iat            => $args{iat},
            azp            => $args{azp},
        }, $class;
    }

    sub set_nonce {
        my ($self, $nonce) = @_;
        $self->{nonce} = $nonce || '';
        return $self;
    }

    sub post_form {
        my ($self, $url, $form) = @_;
        my %claims = (
            iss                => $self->{issuer},
            aud                => $self->{audience},
            sub                => $self->{subject},
            email              => $self->{email},
            name               => $self->{name},
            preferred_username => 'oauth-user',
            nonce              => $self->{nonce},
            exp                => defined($self->{exp}) ? $self->{exp} : time + 600,
            (defined($self->{nbf}) ? (nbf => $self->{nbf}) : ()),
            iat                => defined($self->{iat}) ? $self->{iat} : time,
        );
        $claims{email_verified} = $self->{email_verified} unless $self->{omit_email_verified};
        $claims{azp} = $self->{azp} if defined $self->{azp};
        return {
            success => 1,
            status  => 200,
            content => JSON::PP::encode_json({
                access_token => 'mock-access-token',
                token_type   => 'Bearer',
                expires_in   => 3600,
                id_token     => main::test_jwt(%claims),
            }),
        };
    }

    sub get {
        my ($self, $url, $options) = @_;
        if ($url =~ m{/.well-known/openid-configuration\z}) {
            my $issuer = $self->{issuer};
            return {
                success => 1,
                status  => 200,
                content => JSON::PP::encode_json({
                    issuer                 => $issuer,
                    authorization_endpoint => "$issuer/authorize",
                    token_endpoint         => "$issuer/token",
                    userinfo_endpoint      => "$issuer/userinfo",
                    jwks_uri               => "$issuer/certs",
                }),
            };
        }
        if ($url =~ m{/certs\z}) {
            $self->{jwks_fetches} = int($self->{jwks_fetches} || 0) + 1;
            return {
                success => 1,
                status  => 200,
                content => JSON::PP::encode_json({
                    keys => [
                        { kty => 'RSA', kid => 'test-key', alg => 'RS256', use => 'sig', x5c => [ 'test-cert' ] },
                    ],
                }),
            };
        }
        my %userinfo = (
            sub                => $self->{subject},
            email              => $self->{email},
            name               => $self->{name},
            preferred_username => 'oauth-user',
            picture            => 'https://accounts.example.test/avatar.png',
        );
        $userinfo{email_verified} = $self->{email_verified} unless $self->{omit_email_verified};
        return {
            success => 1,
            status  => 200,
            content => JSON::PP::encode_json(\%userinfo),
        };
    }
}

sub test_jwt {
    my (%claims) = @_;
    my $header = _test_b64url(encode_json({ alg => 'RS256', kid => 'test-key', typ => 'JWT' }));
    my $payload = _test_b64url(encode_json(\%claims));
    my $signature = _test_b64url('mock-signature');
    return join '.', $header, $payload, $signature;
}

sub _test_b64url {
    my ($value) = @_;
    my $encoded = encode_base64($value, '');
    $encoded =~ tr{+/}{-_};
    $encoded =~ s/=+\z//;
    return $encoded;
}

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/data", "$root/themes", "$root/admin-assets");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = V3 Foundation Test
site_url = https://v3.example.test
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
my $admin_ts = time;
$db->dbh->do(
    q{
        INSERT INTO admin_users (username, email, role, password_hash, password_algo, created_at, updated_at)
        VALUES ('v3admin', 'admin@example.test', 'owner', 'test-hash', 'test', ?, ?)
    },
    undef,
    $admin_ts,
    $admin_ts
);
my $admin_user_id = int($db->dbh->sqlite_last_insert_rowid);

my $settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'posts'), 'Posts module is enabled by default');
ok(DesertCMS::Modules::enabled($settings, 'notifications'), 'Notifications module is enabled by default');
ok(DesertCMS::Modules::enabled($settings, 'security_center'), 'Security Center module is enabled by default');

my %manifest = map { $_->{key} => $_ } @{ DesertCMS::ModuleManifest::manifests(settings => $settings, config => $config) };
for my $key (qw(pages analytics dashboard theme_engine realtime posts accounts live_streaming forums social notifications security_center)) {
    ok($manifest{$key}, "manifest exists for $key");
    my @errors = DesertCMS::ModuleManifest::validate_manifest($manifest{$key});
    is_deeply(\@errors, [], "$key manifest satisfies contract");
}

like(
    join(',', @{ DesertCMS::ModuleManifest::notification_topics(settings => $settings, config => $config) }),
    qr/security\.check_failed/,
    'manifest registry exposes Security Center notification topics'
);
my %manifest_checks = map { $_ => 1 } @{ DesertCMS::ModuleManifest::security_checks(settings => $settings, config => $config) };
ok($manifest_checks{pf} && $manifest_checks{httpd} && $manifest_checks{acme_client}, 'manifest registry exposes OpenBSD security checks');
ok($manifest_checks{package_updates} && $manifest_checks{cve_matching} && $manifest_checks{provider_webhooks}, 'manifest registry exposes package, CVE, and provider webhook checks');

DesertCMS::Settings::set_many($config, $db, { module_posts_enabled => 0 });
$settings = DesertCMS::Settings::all($config, $db);
ok(!DesertCMS::Modules::enabled($settings, 'posts'), 'Posts module can be disabled without deleting post data');

DesertCMS::Settings::set_many($config, $db, {
    module_accounts_enabled => 0,
    module_social_enabled   => 1,
});
$settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'social'), 'Social module can be enabled');
ok(DesertCMS::Modules::enabled($settings, 'accounts'), 'Social effectively enables Accounts');
is($settings->{module_accounts_enabled}, 1, 'Settings persistence keeps Accounts enabled when Social is enabled');
DesertCMS::Settings::set_many($config, $db, { module_accounts_enabled => 0 });
$settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'social'), 'Social module remains enabled after an Accounts disable attempt');
ok(DesertCMS::Modules::enabled($settings, 'accounts'), 'Settings block disabling Accounts while Social remains enabled');
my ($persisted_accounts_gate) = $db->dbh->selectrow_array(
    q{SELECT value FROM settings WHERE key = ?},
    undef,
    'module_accounts_enabled'
);
is($persisted_accounts_gate, 1, 'Settings persistence repairs Accounts gate when Social already depends on it');

my $blueprints = DesertCMS::Blueprints->new(config => $config, db => $db);
my $v3_blueprint = $blueprints->save(
    name => 'V3 Community Site',
    slug => 'v3-community-site',
    description => 'Exercises v3 SubCMS module gates.',
    category => 'event-community-site',
    module_posts_enabled => 1,
    module_social_enabled => 1,
    module_live_streaming_enabled => 1,
    module_forums_enabled => 1,
    module_notifications_enabled => 1,
    module_security_center_enabled => 1,
    default_pages_text => "Home|home|nav\nCommunity|community|nav",
);
my $v3_snapshot = $blueprints->snapshot($v3_blueprint);
ok($v3_snapshot->{module_posts_enabled}, 'blueprint snapshot preserves Posts module gate');
ok($v3_snapshot->{module_social_enabled}, 'blueprint snapshot preserves Social module gate');
ok($v3_snapshot->{module_accounts_enabled}, 'blueprint snapshot enables Accounts when Social is enabled');
my $snapshot_settings = DesertCMS::Blueprints::settings_from_snapshot($v3_snapshot);
ok($snapshot_settings->{module_accounts_enabled}, 'SubCMS settings inherit unified account dependency');
ok($snapshot_settings->{module_live_streaming_enabled} && $snapshot_settings->{module_forums_enabled}, 'SubCMS settings inherit community module gates');

my $v3_plan_features = DesertCMS::Modules::feature_map_from_values({
    feature_accounts_included        => 1,
    feature_live_streaming_included => 0,
    feature_forums_included          => 1,
    feature_social_included          => 0,
    feature_notifications_included   => 1,
    feature_security_center_included => 0,
}, {});
ok($v3_plan_features->{accounts}, 'service plan values include the Accounts v3 entitlement');
ok(!$v3_plan_features->{live_streaming}, 'service plan values can exclude the Live Streaming v3 entitlement');
ok($v3_plan_features->{forums}, 'service plan values include the Forums v3 entitlement');
ok(!$v3_plan_features->{social}, 'service plan values can exclude the Social v3 entitlement');
ok($v3_plan_features->{notifications}, 'service plan values include the Notifications v3 entitlement');
ok(!$v3_plan_features->{security_center}, 'service plan values can exclude the Security Center v3 entitlement');

my $v3_contrib_config_path = "$root/v3-contributor.conf";
_write($v3_contrib_config_path, <<"CONF");
site_name = V3 Contributor
site_url = https://v3-contributor.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $root/themes
admin_asset_dir = $root/admin-assets
contributor_site_id = v3-contributor
contributor_domain = v3-contributor.example.test
secure_cookies = 0
CONF
my $v3_contrib_config = DesertCMS::Config->load($v3_contrib_config_path);
DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json($v3_plan_features),
    module_accounts_enabled        => 1,
    module_live_streaming_enabled => 1,
    module_forums_enabled          => 1,
    module_social_enabled          => 1,
    module_notifications_enabled   => 1,
    module_security_center_enabled => 1,
});
$settings = DesertCMS::Settings::all($config, $db);
my %v3_feature_by_key = map { $_->{key} => $_ } @{ DesertCMS::Modules::catalog($settings, config => $v3_contrib_config) };
ok($v3_feature_by_key{accounts}{available} && $v3_feature_by_key{accounts}{enabled}, 'SubCMS plan allows enabled Accounts at runtime');
ok($v3_feature_by_key{forums}{available} && $v3_feature_by_key{forums}{enabled}, 'SubCMS plan allows enabled Forums at runtime');
ok($v3_feature_by_key{live_streaming}{locked_by_plan}, 'SubCMS plan locks excluded Live Streaming');
ok(!$v3_feature_by_key{live_streaming}{enabled}, 'SubCMS plan disables excluded Live Streaming effectively');
ok($v3_feature_by_key{social}{locked_by_plan}, 'SubCMS plan locks excluded Social');
ok(!$v3_feature_by_key{social}{enabled}, 'SubCMS plan disables excluded Social effectively');
ok($v3_feature_by_key{notifications}{available} && $v3_feature_by_key{notifications}{enabled}, 'SubCMS plan allows enabled Notifications at runtime');

my @expected_tables = qw(
    user_accounts user_account_sessions user_account_oauth_states user_identities user_account_login_attempts user_account_audit_events shop_carts notifications notification_preferences notification_deliveries
    admin_dashboard_widgets security_findings security_remediation_queue realtime_sessions
    live_stream_channels live_stream_sessions live_chat_messages live_chat_presence live_chat_reports live_chat_blocked_terms forum_categories forum_topics
    forum_posts forum_reports social_profiles social_follows social_posts social_replies social_reactions social_reports theme_image_sources
);
for my $table (@expected_tables) {
    my ($exists) = $db->dbh->selectrow_array(
        q{SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?},
        undef,
        $table
    );
    ok($exists, "v3 schema creates $table");
}

my $accounts = DesertCMS::Accounts->new(config => $config, db => $db);
my $account = $accounts->create_account(
    email        => 'founder@example.test',
    username     => 'founder',
    display_name => 'Founder',
    password     => 'correct horse battery staple',
);
ok($account->{id}, 'Accounts module creates a public account');
my ($authed, $auth_reason) = $accounts->authenticate(
    login    => 'founder',
    password => 'correct horse battery staple',
    ip_address => '127.0.0.1',
    user_agent => 'test',
);
ok($authed && !$auth_reason, 'Accounts module authenticates local password login');
my ($login_audit_count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM user_account_audit_events WHERE account_id = ? AND event_type = ?', undef, $account->{id}, 'account.login');
ok($login_audit_count, 'Accounts module records local login audit events');
for (1 .. 5) {
    $accounts->authenticate(login => 'founder', password => 'wrong password', ip_address => '10.0.0.2', user_agent => 'test');
}
my ($throttled_account, $throttled_reason) = $accounts->authenticate(
    login      => 'founder',
    password   => 'correct horse battery staple',
    ip_address => '10.0.0.2',
    user_agent => 'test',
);
ok(!$throttled_account && $throttled_reason eq 'throttled', 'Accounts module throttles repeated local login failures');
my ($throttled_audit_count) = $db->dbh->selectrow_array(
    q{
        SELECT COUNT(*)
        FROM user_account_audit_events
        WHERE event_type = 'account.login_failed'
          AND ip_address = ?
          AND details_json LIKE ?
    },
    undef,
    '10.0.0.2',
    '%throttled%'
);
ok($throttled_audit_count, 'Accounts module audits throttled local login attempts');
my ($account_token) = $accounts->create_session(account => $authed, ip_address => '127.0.0.1', user_agent => 'test');
like($account_token, qr/\A[0-9a-f]{64}\z/, 'Accounts module creates opaque account session tokens');
my $account_session = $accounts->session_from_token($account_token);
is($account_session->{email}, 'founder@example.test', 'Accounts module resolves active sessions');
my ($logout_token) = $accounts->create_session(account => $authed, ip_address => '127.0.0.1', user_agent => 'logout-test');
ok($accounts->revoke_session($logout_token, ip_address => '127.0.0.1', user_agent => 'logout-test'), 'Accounts module revokes public account sessions');
ok(!$accounts->session_from_token($logout_token), 'Accounts module blocks revoked public account sessions');
my ($logout_audit_count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM user_account_audit_events WHERE account_id = ? AND event_type = ?', undef, $account->{id}, 'account.logout');
ok($logout_audit_count, 'Accounts module records logout audit events from the runtime');
my $sso_max_failures = 30;
$config->{account_login_max_failures} = $sso_max_failures;
my $identity = $accounts->upsert_identity(
    account_id        => $account->{id},
    provider          => 'google',
    provider_subject  => 'google-subject-1',
    email             => 'founder@example.test',
    profile           => { hd => 'example.test' },
);
is($identity->{account_id}, $account->{id}, 'Accounts module stores Google/OIDC identity links');
my $linked_identities = $accounts->linked_identities($account->{id});
ok(@{$linked_identities} == 1, 'Accounts module lists linked provider identities');
my ($direct_link_audit_count) = $db->dbh->selectrow_array(
    q{SELECT COUNT(*) FROM user_account_audit_events WHERE account_id = ? AND event_type = ? AND provider = ? AND details_json LIKE ?},
    undef,
    $account->{id},
    'account.identity_linked',
    'google',
    '%google-subject-1%'
);
ok($direct_link_audit_count, 'Accounts module audits direct provider identity links');
ok($accounts->unlink_identity(account_id => $account->{id}, actor_account_id => $account->{id}, provider => 'google', provider_subject => 'google-subject-1', ip_address => '127.0.0.1', user_agent => 'test'), 'Accounts module unlinks provider identities from a profile');
my ($unlink_audit_count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM user_account_audit_events WHERE account_id = ? AND event_type = ?', undef, $account->{id}, 'account.identity_unlinked');
ok($unlink_audit_count, 'Accounts module records identity unlink audit events');
my ($unlink_actor_id) = $db->dbh->selectrow_array('SELECT actor_account_id FROM user_account_audit_events WHERE account_id = ? AND event_type = ? ORDER BY id DESC LIMIT 1', undef, $account->{id}, 'account.identity_unlinked');
is(int($unlink_actor_id || 0), $account->{id}, 'Accounts module records unlink actor account context');
$accounts->upsert_identity(
    account_id        => $account->{id},
    provider          => 'google',
    provider_subject  => 'google-subject-actorless',
    email             => 'founder@example.test',
    profile           => { hd => 'example.test' },
);
my $actorless_unlink_ok = eval {
    $accounts->unlink_identity(account_id => $account->{id}, provider => 'google', provider_subject => 'google-subject-actorless');
    1;
};
ok(!$actorless_unlink_ok && $@ =~ /identity unlink actor account or active admin user is required/, 'Accounts module requires explicit actor context for identity unlinking');
my $disabled_unlink_account = $accounts->create_account(
    email        => 'disabled-unlink@example.test',
    username     => 'disabled-unlink',
    display_name => 'Disabled Unlink',
    password     => 'correct horse battery staple',
);
$accounts->upsert_identity(
    account_id        => $disabled_unlink_account->{id},
    provider          => 'google',
    provider_subject  => 'disabled-unlink-subject',
    email             => 'disabled-unlink@example.test',
    profile           => {},
);
$accounts->set_status(id => $disabled_unlink_account->{id}, status => 'disabled', moderation_note => 'identity unlink test', admin_user_id => $admin_user_id);
my $disabled_unlink_ok = eval {
    $accounts->unlink_identity(account_id => $disabled_unlink_account->{id}, provider => 'google', provider_subject => 'disabled-unlink-subject');
    1;
};
ok(!$disabled_unlink_ok && $@ =~ /account is not active/, 'Accounts module blocks identity unlinking for disabled accounts');
my $oauth_http = TestOAuthHTTP->new;
my $oauth_settings = {
    accounts_google_client_id     => 'google-client-id',
    accounts_google_client_secret => 'google-client-secret',
    accounts_google_enabled       => 1,
    accounts_allowed_domains      => 'example.test',
};
is(
    DesertCMS::Accounts::normalize_allowed_domains(' Example.TEST, @*.Example.org example.test '),
    'example.test, *.example.org',
    'Accounts module normalizes and deduplicates allowed SSO email domains'
);
my $bad_allowed_domains_ok = eval {
    DesertCMS::Accounts::normalize_allowed_domains('example.test, http://not-a-domain');
    1;
};
ok(!$bad_allowed_domains_ok && $@ =~ /Allowed email domain/, 'Accounts module rejects malformed allowed SSO email domains');
my $google_readiness = DesertCMS::Accounts::oauth_provider_readiness(
    provider     => 'google',
    settings     => $oauth_settings,
    redirect_uri => 'https://v3.example.test/account/sso/google/callback',
);
ok($google_readiness->{ready}, 'Accounts module marks configured Google SSO provider ready');
my $bad_callback_readiness = DesertCMS::Accounts::oauth_provider_readiness(
    provider     => 'google',
    settings     => $oauth_settings,
    redirect_uri => 'http://v3.example.test/account/sso/google/callback',
);
ok(!$bad_callback_readiness->{ready} && grep { /OAuth redirect URI must use https/ } @{ $bad_callback_readiness->{issues} }, 'Accounts module validates SSO callback URLs before provider activation');
my $bad_oidc_readiness = DesertCMS::Accounts::oauth_provider_readiness(
    provider => 'oidc',
    settings => {
        %{$oauth_settings},
        accounts_oidc_enabled       => 1,
        accounts_oidc_discovery_url => 'http://idp.example.test/.well-known/openid-configuration',
        accounts_oidc_client_id     => 'oidc-client-id',
        accounts_oidc_client_secret => 'oidc-client-secret',
    },
    redirect_uri => 'https://v3.example.test/account/sso/oidc/callback',
);
ok(!$bad_oidc_readiness->{ready} && grep { /OIDC discovery URL must use https/ } @{ $bad_oidc_readiness->{issues} }, 'Accounts module validates OIDC discovery URLs without fetching provider metadata');
my $provider_disabled_ok = eval {
    $accounts->oauth_start(
        provider      => 'google',
        settings      => { %{$oauth_settings}, accounts_google_enabled => 0 },
        redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
        redirect_path => '/account',
        ip_address    => '127.0.0.1',
        http          => $oauth_http,
    );
    1;
};
ok(!$provider_disabled_ok && $@ =~ /provider is disabled/, 'Accounts module blocks disabled SSO providers');
my $provider_missing_enable_ok = eval {
    $accounts->oauth_start(
        provider      => 'google',
        settings      => {
            accounts_google_client_id     => 'google-client-id',
            accounts_google_client_secret => 'google-client-secret',
        },
        redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
        redirect_path => '/account',
        ip_address    => '127.0.0.1',
        http          => $oauth_http,
    );
    1;
};
ok(!$provider_missing_enable_ok && $@ =~ /provider is disabled/, 'Accounts module keeps SSO providers disabled until explicitly enabled');
for (1 .. $sso_max_failures) {
    $accounts->record_login_attempt(
        scope      => 'sso:google',
        subject    => 'google',
        ip_address => '127.0.0.201',
        success    => 0,
        reason     => 'test throttle',
    );
}
my ($oauth_state_count_before_throttle) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM user_account_oauth_states WHERE provider = ?', undef, 'google');
my $throttled_start_ok = eval {
    $accounts->oauth_start(
        provider      => 'google',
        settings      => $oauth_settings,
        redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
        redirect_path => '/account',
        ip_address    => '127.0.0.201',
        http          => $oauth_http,
    );
    1;
};
ok(!$throttled_start_ok && $@ =~ /Too many SSO attempts/, 'Accounts module throttles SSO start before creating a provider state');
my ($oauth_state_count_after_throttle) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM user_account_oauth_states WHERE provider = ?', undef, 'google');
is($oauth_state_count_after_throttle, $oauth_state_count_before_throttle, 'Accounts module does not create OAuth state rows for throttled SSO starts');
my $oauth_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/forums',
    ip_address    => '127.0.0.1',
    http          => $oauth_http,
);
like($oauth_start->{authorization_url}, qr{\Ahttps://accounts\.google\.com/o/oauth2/v2/auth\?}, 'Accounts module builds Google authorization URL');
like($oauth_start->{authorization_url}, qr/code_challenge=/, 'Accounts module includes PKCE challenge');
like($oauth_start->{state}, qr/\A[0-9a-f]{48}\z/, 'Accounts module returns opaque OAuth state');
my ($oauth_nonce) = $oauth_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$oauth_http->set_nonce($oauth_nonce);
my ($oauth_state_count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM user_account_oauth_states WHERE provider = ?', undef, 'google');
is($oauth_state_count, 1, 'Accounts module stores OAuth state server-side');
my $oauth_result = $accounts->oauth_complete(
    provider     => 'google',
    settings     => $oauth_settings,
    redirect_uri => 'https://v3.example.test/account/sso/google/callback',
    state        => $oauth_start->{state},
    code         => 'mock-code',
    http         => $oauth_http,
    id_token_verifier => sub { 1 },
);
is($oauth_result->{account}{email}, 'oauth-user@example.test', 'Accounts module creates accounts from verified Google/OIDC claims');
is($oauth_result->{identity}{provider_subject}, 'google-oauth-subject', 'Accounts module links provider subject after callback');
is($oauth_result->{redirect_path}, '/forums', 'Accounts module preserves local OAuth redirect path');
my ($sso_audit_count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM user_account_audit_events WHERE account_id = ? AND event_type = ?', undef, $oauth_result->{account}{id}, 'account.sso_login');
ok($sso_audit_count, 'Accounts module records SSO login audit events');
my ($sso_link_audit_count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM user_account_audit_events WHERE account_id = ? AND event_type = ?', undef, $oauth_result->{account}{id}, 'account.identity_linked');
ok($sso_link_audit_count, 'Accounts module records provider link audit events when SSO creates an identity');
is($oauth_http->{jwks_fetches}, 1, 'Accounts module fetches provider JWKS for ID token validation');
my $merge_account = $accounts->create_account(
    email        => 'merge-oauth@example.test',
    username     => 'merge-oauth',
    display_name => 'Merge OAuth',
    password     => 'correct horse battery staple',
);
my $merge_http = TestOAuthHTTP->new(email => 'merge-oauth@example.test', subject => 'merge-oauth-subject', name => 'Merge OAuth');
my $merge_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.11',
    http          => $merge_http,
);
my ($merge_nonce) = $merge_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$merge_http->set_nonce($merge_nonce);
my $merge_result = $accounts->oauth_complete(
    provider     => 'google',
    settings     => $oauth_settings,
    redirect_uri => 'https://v3.example.test/account/sso/google/callback',
    state        => $merge_start->{state},
    code         => 'mock-code',
    http         => $merge_http,
    id_token_verifier => sub { 1 },
);
is($merge_result->{account}{id}, $merge_account->{id}, 'Accounts module merges SSO identities into existing active email accounts');
my ($merge_audit_count) = $db->dbh->selectrow_array(
    q{SELECT COUNT(*) FROM user_account_audit_events WHERE account_id = ? AND event_type = ? AND provider = ? AND details_json LIKE ?},
    undef,
    $merge_account->{id},
    'account.identity_linked',
    'google',
    '%email_merge%'
);
ok($merge_audit_count, 'Accounts module audits existing-email SSO merges as provider links');
my $oidc_settings = {
    %{$oauth_settings},
    accounts_oidc_enabled       => 1,
    accounts_oidc_discovery_url => 'https://idp.example.test/.well-known/openid-configuration',
    accounts_oidc_client_id     => 'oidc-client-id',
    accounts_oidc_client_secret => 'oidc-client-secret',
};
my $oidc_http = TestOAuthHTTP->new(
    issuer   => 'https://idp.example.test',
    audience => 'oidc-client-id',
    email    => 'oidc-user@example.test',
    subject  => 'oidc-subject',
    name     => 'OIDC User',
    exp      => time - 60,
);
my $oidc_start = $accounts->oauth_start(
    provider      => 'oidc',
    settings      => $oidc_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/oidc/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $oidc_http,
);
like($oidc_start->{authorization_url}, qr{\Ahttps://idp\.example\.test/authorize\?}, 'Accounts module builds generic OIDC authorization URL from discovery');
my ($oidc_nonce) = $oidc_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$oidc_http->set_nonce($oidc_nonce);
my $oidc_result = $accounts->oauth_complete(
    provider     => 'oidc',
    settings     => $oidc_settings,
    redirect_uri => 'https://v3.example.test/account/sso/oidc/callback',
    state        => $oidc_start->{state},
    code         => 'mock-code',
    http         => $oidc_http,
    id_token_verifier => sub { 1 },
);
is($oidc_result->{account}{email}, 'oidc-user@example.test', 'Accounts module completes generic OIDC login');
is($oidc_result->{identity}{provider}, 'oidc', 'Accounts module stores generic OIDC identities');
is($oidc_http->{jwks_fetches}, 1, 'Accounts module fetches generic OIDC JWKS');
my $future_iat_http = TestOAuthHTTP->new(
    issuer   => 'https://idp.example.test',
    audience => 'oidc-client-id',
    email    => 'future-iat@example.test',
    subject  => 'future-iat-subject',
    name     => 'Future IAT',
    iat      => time + 600,
);
my $future_iat_start = $accounts->oauth_start(
    provider      => 'oidc',
    settings      => $oidc_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/oidc/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $future_iat_http,
);
my ($future_iat_nonce) = $future_iat_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$future_iat_http->set_nonce($future_iat_nonce);
my $future_iat_ok = eval {
    $accounts->oauth_complete(
        provider     => 'oidc',
        settings     => $oidc_settings,
        redirect_uri => 'https://v3.example.test/account/sso/oidc/callback',
        state        => $future_iat_start->{state},
        code         => 'mock-code',
        http         => $future_iat_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$future_iat_ok && $@ =~ /issued-at value is invalid/, 'Accounts module rejects OIDC tokens issued beyond clock skew');
my $future_nbf_http = TestOAuthHTTP->new(
    issuer   => 'https://idp.example.test',
    audience => 'oidc-client-id',
    email    => 'future-nbf@example.test',
    subject  => 'future-nbf-subject',
    name     => 'Future NBF',
    nbf      => time + 600,
);
my $future_nbf_start = $accounts->oauth_start(
    provider      => 'oidc',
    settings      => $oidc_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/oidc/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $future_nbf_http,
);
my ($future_nbf_nonce) = $future_nbf_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$future_nbf_http->set_nonce($future_nbf_nonce);
my $future_nbf_ok = eval {
    $accounts->oauth_complete(
        provider     => 'oidc',
        settings     => $oidc_settings,
        redirect_uri => 'https://v3.example.test/account/sso/oidc/callback',
        state        => $future_nbf_start->{state},
        code         => 'mock-code',
        http         => $future_nbf_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$future_nbf_ok && $@ =~ /not-before value is invalid/, 'Accounts module rejects OIDC tokens before the not-before clock-skew window');
my $malformed_nbf_http = TestOAuthHTTP->new(
    issuer   => 'https://idp.example.test',
    audience => 'oidc-client-id',
    email    => 'malformed-nbf@example.test',
    subject  => 'malformed-nbf-subject',
    name     => 'Malformed NBF',
    nbf      => 'not-a-number',
);
my $malformed_nbf_start = $accounts->oauth_start(
    provider      => 'oidc',
    settings      => $oidc_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/oidc/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $malformed_nbf_http,
);
my ($malformed_nbf_nonce) = $malformed_nbf_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$malformed_nbf_http->set_nonce($malformed_nbf_nonce);
my $malformed_nbf_ok = eval {
    $accounts->oauth_complete(
        provider     => 'oidc',
        settings     => $oidc_settings,
        redirect_uri => 'https://v3.example.test/account/sso/oidc/callback',
        state        => $malformed_nbf_start->{state},
        code         => 'mock-code',
        http         => $malformed_nbf_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$malformed_nbf_ok && $@ =~ /not-before value is invalid/, 'Accounts module rejects malformed OIDC not-before claims');
my $bad_state_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => 'not-a-valid-stored-state',
        code         => 'mock-code',
        http         => TestOAuthHTTP->new,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$bad_state_ok && $@ =~ /state was not found/, 'Accounts module rejects unknown OAuth state values');
my $bad_nonce_http = TestOAuthHTTP->new(
    issuer   => 'https://idp.example.test',
    audience => 'oidc-client-id',
    email    => 'bad-nonce@example.test',
    subject  => 'bad-nonce-subject',
    name     => 'Bad Nonce',
);
my $bad_nonce_start = $accounts->oauth_start(
    provider      => 'oidc',
    settings      => $oidc_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/oidc/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $bad_nonce_http,
);
$bad_nonce_http->set_nonce('wrong-nonce');
my $bad_nonce_ok = eval {
    $accounts->oauth_complete(
        provider     => 'oidc',
        settings     => $oidc_settings,
        redirect_uri => 'https://v3.example.test/account/sso/oidc/callback',
        state        => $bad_nonce_start->{state},
        code         => 'mock-code',
        http         => $bad_nonce_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$bad_nonce_ok && $@ =~ /nonce did not match/, 'Accounts module rejects ID tokens with nonce values that do not match OAuth state');
my $throttled_sso_http = TestOAuthHTTP->new(
    issuer   => 'https://idp.example.test',
    audience => 'oidc-client-id',
    email    => 'throttled-sso@example.test',
    subject  => 'throttled-sso-subject',
    name     => 'Throttled SSO',
);
my $throttled_sso_start = $accounts->oauth_start(
    provider      => 'oidc',
    settings      => $oidc_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/oidc/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.44',
    http          => $throttled_sso_http,
);
for (1 .. $sso_max_failures) {
    $accounts->record_login_attempt(
        scope      => 'sso:oidc',
        subject    => 'oidc',
        ip_address => '127.0.0.44',
        success    => 0,
        reason     => 'throttle fixture',
    );
}
my ($throttled_sso_nonce) = $throttled_sso_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$throttled_sso_http->set_nonce($throttled_sso_nonce);
my $throttled_sso_ok = eval {
    $accounts->oauth_complete(
        provider     => 'oidc',
        settings     => $oidc_settings,
        redirect_uri => 'https://v3.example.test/account/sso/oidc/callback',
        state        => $throttled_sso_start->{state},
        code         => 'mock-code',
        ip_address   => '127.0.0.44',
        http         => $throttled_sso_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$throttled_sso_ok && $@ =~ /Too many SSO attempts/, 'Accounts module throttles SSO callbacks before token exchange');
my ($throttled_sso_consumed_at) = $db->dbh->selectrow_array(
    'SELECT consumed_at FROM user_account_oauth_states WHERE state_hash = ?',
    undef,
    $accounts->_oauth_state_hash($throttled_sso_start->{state})
);
ok(!defined($throttled_sso_consumed_at), 'Accounts module preserves OAuth state when SSO callbacks are throttled before consumption');
my $cached_jwks_http = TestOAuthHTTP->new(email => 'cached-oauth@example.test', subject => 'cached-oauth-subject', name => 'Cached OAuth');
my $cached_jwks_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $cached_jwks_http,
);
my ($cached_jwks_nonce) = $cached_jwks_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$cached_jwks_http->set_nonce($cached_jwks_nonce);
my $cached_verifier_saw_jwk = 0;
my $cached_jwks_result = $accounts->oauth_complete(
    provider     => 'google',
    settings     => $oauth_settings,
    redirect_uri => 'https://v3.example.test/account/sso/google/callback',
    state        => $cached_jwks_start->{state},
    code         => 'mock-code',
    http         => $cached_jwks_http,
    id_token_verifier => sub {
        my (%verify_args) = @_;
        $cached_verifier_saw_jwk = (($verify_args{jwk}{kid} || '') eq 'test-key') ? 1 : 0;
        return 1;
    },
);
is($cached_jwks_result->{account}{email}, 'cached-oauth@example.test', 'Accounts module completes SSO with cached JWKS');
is(int($cached_jwks_http->{jwks_fetches} || 0), 0, 'Accounts module reuses cached JWKS for later SSO callbacks');
ok($cached_verifier_saw_jwk, 'Accounts module passes selected JWK to ID token verifier');
my $bad_signature_http = TestOAuthHTTP->new(email => 'bad-signature@example.test', subject => 'bad-signature-subject', name => 'Bad Signature');
my $bad_signature_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $bad_signature_http,
);
my ($bad_signature_nonce) = $bad_signature_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$bad_signature_http->set_nonce($bad_signature_nonce);
my $bad_signature_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $bad_signature_start->{state},
        code         => 'mock-code',
        http         => $bad_signature_http,
        id_token_verifier => sub { 0 },
    );
    1;
};
ok(!$bad_signature_ok && $@ =~ /signature was invalid/, 'Accounts module rejects invalid ID token signatures');
my $expired_state_http = TestOAuthHTTP->new(email => 'expired-state@example.test', subject => 'expired-state-subject', name => 'Expired State');
my $expired_state_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $expired_state_http,
);
$db->dbh->do(
    'UPDATE user_account_oauth_states SET expires_at = ? WHERE state_hash = ?',
    undef,
    time - 1,
    $accounts->_oauth_state_hash($expired_state_start->{state})
);
my ($expired_state_nonce) = $expired_state_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$expired_state_http->set_nonce($expired_state_nonce);
my $expired_state_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $expired_state_start->{state},
        code         => 'mock-code',
        http         => $expired_state_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$expired_state_ok && $@ =~ /state has expired/, 'Accounts module rejects expired OAuth state');
my $link_http = TestOAuthHTTP->new(email => 'founder-alias@example.test', subject => 'founder-google-link', name => 'Founder');
my $link_start = $accounts->oauth_start(
    provider      => 'google',
    account_id    => $account->{id},
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account?linked=1',
    ip_address    => '127.0.0.1',
    http          => $link_http,
);
my ($link_nonce) = $link_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$link_http->set_nonce($link_nonce);
my $link_result = $accounts->oauth_complete(
    provider     => 'google',
    settings     => $oauth_settings,
    redirect_uri => 'https://v3.example.test/account/sso/google/callback',
    state        => $link_start->{state},
    code         => 'mock-code',
    http         => $link_http,
    id_token_verifier => sub { 1 },
);
ok($link_result->{linked} && $link_result->{account}{id} == $account->{id}, 'Accounts module links SSO providers to an existing profile');
my $link_audit = $db->dbh->selectrow_hashref(
    q{
        SELECT actor_account_id, details_json
        FROM user_account_audit_events
        WHERE account_id = ? AND event_type = ? AND provider = ?
        ORDER BY id DESC
        LIMIT 1
    },
    undef,
    $account->{id},
    'account.identity_linked',
    'google'
);
ok($link_audit && int($link_audit->{actor_account_id} || 0) == $account->{id}, 'Accounts module attributes profile-link SSO audit events to the linked account actor');
like($link_audit->{details_json} || '', qr/explicit_profile_link/, 'Accounts module records explicit profile-link mode in SSO audit details');
my $link_email_owner = $accounts->create_account(
    email        => 'profile-link-owner@example.test',
    username     => 'profile-link-owner',
    display_name => 'Profile Link Owner',
    password     => 'correct horse battery staple',
);
my $conflicting_link_http = TestOAuthHTTP->new(
    email   => 'profile-link-owner@example.test',
    subject => 'founder-google-link-conflict',
    name    => 'Profile Link Owner',
);
my $conflicting_link_start = $accounts->oauth_start(
    provider      => 'google',
    account_id    => $account->{id},
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account?linked=1',
    ip_address    => '127.0.0.53',
    http          => $conflicting_link_http,
);
my ($conflicting_link_nonce) = $conflicting_link_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$conflicting_link_http->set_nonce($conflicting_link_nonce);
my $conflicting_link_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $conflicting_link_start->{state},
        code         => 'mock-code',
        ip_address   => '127.0.0.53',
        http         => $conflicting_link_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$conflicting_link_ok && $@ =~ /email is already associated/, 'Accounts module rejects profile-linked SSO identities when the provider email belongs to another account');
ok(!$accounts->identity('google', 'founder-google-link-conflict'), 'Accounts module does not persist rejected profile-link SSO identities');
my $reused_state_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $oauth_start->{state},
        code         => 'mock-code',
        http         => $oauth_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$reused_state_ok && $@ =~ /already been used/, 'Accounts module rejects reused OAuth state');
my ($sso_failed_audit_count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM user_account_audit_events WHERE event_type = ?', undef, 'account.sso_failed');
ok($sso_failed_audit_count, 'Accounts module records failed SSO audit events from rejected callbacks');
my $bad_issuer_http = TestOAuthHTTP->new(issuer => 'https://evil.example.test');
my $bad_issuer_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $bad_issuer_http,
);
my ($bad_issuer_nonce) = $bad_issuer_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$bad_issuer_http->set_nonce($bad_issuer_nonce);
my $bad_issuer_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $bad_issuer_start->{state},
        code         => 'mock-code',
        http         => $bad_issuer_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$bad_issuer_ok && $@ =~ /issuer is not trusted/, 'Accounts module rejects ID tokens with the wrong issuer');
my $bad_audience_http = TestOAuthHTTP->new(audience => 'wrong-client-id');
my $bad_audience_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $bad_audience_http,
);
my ($bad_audience_nonce) = $bad_audience_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$bad_audience_http->set_nonce($bad_audience_nonce);
my $bad_audience_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $bad_audience_start->{state},
        code         => 'mock-code',
        http         => $bad_audience_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$bad_audience_ok && $@ =~ /audience is not trusted/, 'Accounts module rejects ID tokens with the wrong audience');
my $bad_authorized_party_http = TestOAuthHTTP->new(azp => 'other-client-id');
my $bad_authorized_party_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $bad_authorized_party_http,
);
my ($bad_authorized_party_nonce) = $bad_authorized_party_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$bad_authorized_party_http->set_nonce($bad_authorized_party_nonce);
my $bad_authorized_party_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $bad_authorized_party_start->{state},
        code         => 'mock-code',
        http         => $bad_authorized_party_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$bad_authorized_party_ok && $@ =~ /authorized party is not trusted/, 'Accounts module rejects ID tokens with the wrong authorized party');
my $unverified_http = TestOAuthHTTP->new(email_verified => JSON::PP::false);
my $unverified_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $unverified_http,
);
my ($unverified_nonce) = $unverified_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$unverified_http->set_nonce($unverified_nonce);
my $unverified_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $unverified_start->{state},
        code         => 'mock-code',
        http         => $unverified_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$unverified_ok && $@ =~ /unverified email/, 'Accounts module rejects unverified SSO email addresses');
my $missing_email_verified_http = TestOAuthHTTP->new(
    email                 => 'missing-email-verified@example.test',
    subject               => 'missing-email-verified-subject',
    omit_email_verified   => 1,
);
my $missing_email_verified_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $missing_email_verified_http,
);
my ($missing_email_verified_nonce) = $missing_email_verified_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$missing_email_verified_http->set_nonce($missing_email_verified_nonce);
my $missing_email_verified_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $missing_email_verified_start->{state},
        code         => 'mock-code',
        http         => $missing_email_verified_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$missing_email_verified_ok && $@ =~ /unverified email/, 'Accounts module rejects SSO email addresses when verification is not asserted');
my $nonstandard_email_verified_http = TestOAuthHTTP->new(
    email          => 'nonstandard-email-verified@example.test',
    subject        => 'nonstandard-email-verified-subject',
    email_verified => 'yes',
);
my $nonstandard_email_verified_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $nonstandard_email_verified_http,
);
my ($nonstandard_email_verified_nonce) = $nonstandard_email_verified_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$nonstandard_email_verified_http->set_nonce($nonstandard_email_verified_nonce);
my $nonstandard_email_verified_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $nonstandard_email_verified_start->{state},
        code         => 'mock-code',
        http         => $nonstandard_email_verified_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$nonstandard_email_verified_ok && $@ =~ /unverified email/, 'Accounts module rejects non-standard truthy SSO email verification values');
my $blocked_domain_http = TestOAuthHTTP->new(email => 'oauth-user@blocked.test');
my $blocked_domain_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $blocked_domain_http,
);
my ($blocked_domain_nonce) = $blocked_domain_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$blocked_domain_http->set_nonce($blocked_domain_nonce);
my $blocked_domain_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $blocked_domain_start->{state},
        code         => 'mock-code',
        http         => $blocked_domain_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$blocked_domain_ok && $@ =~ /domain is not allowed/, 'Accounts module enforces allowed SSO email domains');
my $disabled_oauth_account = $accounts->create_account(
    email        => 'disabled-oauth@example.test',
    username     => 'disabled-oauth',
    display_name => 'Disabled OAuth',
    password     => 'correct horse battery staple',
);
$accounts->set_status(id => $disabled_oauth_account->{id}, status => 'disabled', moderation_note => 'SSO conflict test', admin_user_id => $admin_user_id);
my $disabled_http = TestOAuthHTTP->new(email => 'disabled-oauth@example.test', subject => 'disabled-oauth-subject', name => 'Disabled OAuth');
my $disabled_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $disabled_http,
);
my ($disabled_nonce) = $disabled_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$disabled_http->set_nonce($disabled_nonce);
my $disabled_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $disabled_start->{state},
        code         => 'mock-code',
        http         => $disabled_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$disabled_ok && $@ =~ /disabled account/, 'Accounts module rejects SSO merge into disabled accounts');
my $moderated_oauth_account = $accounts->create_account(
    email        => 'moderated-oauth@example.test',
    username     => 'moderated-oauth',
    display_name => 'Moderated OAuth',
    password     => 'correct horse battery staple',
);
$accounts->set_status(id => $moderated_oauth_account->{id}, status => 'moderated', moderation_note => 'SSO moderation conflict test', admin_user_id => $admin_user_id);
my $moderated_http = TestOAuthHTTP->new(email => 'moderated-oauth@example.test', subject => 'moderated-oauth-subject', name => 'Moderated OAuth');
my $moderated_start = $accounts->oauth_start(
    provider      => 'google',
    settings      => $oauth_settings,
    redirect_uri  => 'https://v3.example.test/account/sso/google/callback',
    redirect_path => '/account',
    ip_address    => '127.0.0.1',
    http          => $moderated_http,
);
my ($moderated_nonce) = $moderated_start->{authorization_url} =~ /(?:\?|&)nonce=([^&]+)/;
$moderated_http->set_nonce($moderated_nonce);
my $moderated_ok = eval {
    $accounts->oauth_complete(
        provider     => 'google',
        settings     => $oauth_settings,
        redirect_uri => 'https://v3.example.test/account/sso/google/callback',
        state        => $moderated_start->{state},
        code         => 'mock-code',
        http         => $moderated_http,
        id_token_verifier => sub { 1 },
    );
    1;
};
ok(!$moderated_ok && $@ =~ /moderated account/, 'Accounts module rejects SSO merge into moderated accounts');
my $group = $accounts->save_group(name => 'Moderators', description => 'Forum and social moderators');
ok($group->{id}, 'Accounts module creates reusable groups');
ok($accounts->set_group_member(group_id => $group->{id}, account_id => $account->{id}, role => 'moderator'), 'Accounts module assigns group membership');
my $groups_for_account = $accounts->groups_for_account($account->{id});
is($groups_for_account->[0]{account_role}, 'moderator', 'Accounts module preserves group role');
$db->dbh->do(
    q{
        INSERT INTO shop_carts (session_token_hash, status, currency, details_json, created_at, updated_at)
        VALUES (?, 'open', 'usd', '{}', ?, ?)
    },
    undef,
    DesertCMS::Util::sha256_hexstr('cart-token'),
    time,
    time
);
ok($accounts->attach_cart(account_id => $account->{id}, session_token => 'cart-token'), 'Accounts module attaches open shop carts');
my $actorless_account_status_ok = eval {
    $accounts->set_status(id => $account->{id}, status => 'moderated', moderation_note => 'missing actor test');
    1;
};
ok(!$actorless_account_status_ok && $@ =~ /account moderation actor/, 'Accounts module rejects actorless account moderation');
my $non_moderator_account_status_ok = eval {
    $accounts->set_status(id => $account->{id}, status => 'moderated', actor_account_id => $oauth_result->{account}{id}, moderation_note => 'regular account actor test');
    1;
};
ok(!$non_moderator_account_status_ok && $@ =~ /account moderation actor permission/, 'Accounts module rejects account moderation from regular public accounts');
$accounts->set_status(id => $account->{id}, status => 'disabled', moderation_note => 'test disable', admin_user_id => $admin_user_id);
ok(!$accounts->session_from_token($account_token), 'disabled public accounts cannot keep active sessions');
my ($account_moderation_actor_user_id) = $db->dbh->selectrow_array(
    'SELECT actor_user_id FROM user_account_audit_events WHERE account_id = ? AND event_type = ? ORDER BY id DESC LIMIT 1',
    undef,
    $account->{id},
    'account.moderation'
);
is(int($account_moderation_actor_user_id || 0), $admin_user_id, 'Accounts module stores admin actor context on account moderation audit events');

my $community_account = $accounts->create_account(
    email        => 'community@example.test',
    username     => 'community',
    display_name => 'Community',
    password     => 'correct horse battery staple',
);

my $notifications = DesertCMS::Notifications->new(config => $config, db => $db);

my $forums = DesertCMS::Forums->new(config => $config, db => $db, notifications => $notifications);
my $forum_moderator = $accounts->create_account(
    email        => 'forum-mod@example.test',
    username     => 'forum-mod',
    display_name => 'Forum Moderator',
    password     => 'correct horse battery staple',
);
my $forum_group = $accounts->save_group(name => 'Forum Moderators', slug => 'forum-moderators');
$accounts->set_group_member(group_id => $forum_group->{id}, account_id => $forum_moderator->{id}, role => 'moderator');
my $forum_category = $forums->save_category(title => 'General Discussion', description => 'Open community topics');
ok($forum_category->{id}, 'Forums module creates categories');
my $hidden_forum_category = $forums->save_category(title => 'Hidden Forum', description => 'Private review area', status => 'hidden');
my ($can_view_hidden_category, $hidden_category_reason) = $forums->can_account(action => 'view', account_id => $community_account->{id}, category_id => $hidden_forum_category->{id});
ok(!$can_view_hidden_category && $hidden_category_reason =~ /hidden/, 'Forums module blocks hidden category views for regular accounts');
my $locked_forum_category = $forums->save_category(title => 'Locked Forum', description => 'Read-only area', status => 'locked');
my ($can_create_locked_category, $locked_category_reason) = $forums->can_account(action => 'create_topic', account_id => $community_account->{id}, category_id => $locked_forum_category->{id});
ok(!$can_create_locked_category && $locked_category_reason =~ /not open/, 'Forums module blocks topic creation in locked categories');
my $account_only_forum_category = $forums->save_category(title => 'Account Forum', description => 'Signed-in account topics', visibility => 'accounts');
my ($guest_account_category_view, $guest_account_category_reason) = $forums->can_view_category(category => $account_only_forum_category);
ok(!$guest_account_category_view && $guest_account_category_reason =~ /account required/, 'Forums module hides account-only categories from guests');
my ($member_account_category_view) = $forums->can_view_category(category => $account_only_forum_category, viewer_account_id => $community_account->{id});
ok($member_account_category_view, 'Forums module allows active accounts to view account-only categories');
ok(!(grep { $_->{id} == $account_only_forum_category->{id} } @{ $forums->categories }), 'Forums module hides account-only categories from guest category lists');
ok((grep { $_->{id} == $account_only_forum_category->{id} } @{ $forums->categories(viewer_account_id => $community_account->{id}) }), 'Forums module shows account-only categories to active account category lists');
my $account_only_forum_topic = $forums->create_topic(
    category_id => $account_only_forum_category->{id},
    account_id  => $community_account->{id},
    title       => 'Account-only visibility',
    body        => 'This topic is only visible to signed-in accounts.',
);
ok(!$forums->topic_by_slug($account_only_forum_category->{slug}, $account_only_forum_topic->{slug}), 'Forums module hides account-only direct topics from guests');
ok($forums->topic_by_slug($account_only_forum_category->{slug}, $account_only_forum_topic->{slug}, viewer_account_id => $community_account->{id}), 'Forums module shows account-only direct topics to active accounts');
my $moderator_only_forum_category = $forums->save_category(title => 'Moderator Forum', description => 'Moderator-only topics', visibility => 'moderators');
my ($regular_moderator_category_view, $regular_moderator_category_reason) = $forums->can_view_category(category => $moderator_only_forum_category, viewer_account_id => $community_account->{id});
ok(!$regular_moderator_category_view && $regular_moderator_category_reason =~ /moderator/, 'Forums module hides moderator-only categories from regular accounts');
my ($moderator_category_view) = $forums->can_view_category(category => $moderator_only_forum_category, viewer_account_id => $forum_moderator->{id});
ok($moderator_category_view, 'Forums module allows moderators to view moderator-only categories');
my ($regular_moderator_topic_create, $regular_moderator_topic_reason) = $forums->can_account(action => 'create_topic', account_id => $community_account->{id}, category => $moderator_only_forum_category);
ok(!$regular_moderator_topic_create && $regular_moderator_topic_reason =~ /moderator/, 'Forums module blocks regular accounts from creating moderator-only topics');
my $moderator_only_forum_topic = $forums->create_topic(
    category_id => $moderator_only_forum_category->{id},
    account_id  => $forum_moderator->{id},
    title       => 'Moderator-only visibility',
    body        => 'This topic is only visible to forum moderators.',
);
ok(!$forums->topic_by_slug($moderator_only_forum_category->{slug}, $moderator_only_forum_topic->{slug}, viewer_account_id => $community_account->{id}), 'Forums module hides moderator-only direct topics from regular accounts');
ok($forums->topic_by_slug($moderator_only_forum_category->{slug}, $moderator_only_forum_topic->{slug}, viewer_account_id => $forum_moderator->{id}), 'Forums module shows moderator-only direct topics to moderators');
my $updated_policy_category = $forums->save_category(title => 'Policy Updates', description => 'Starts public and becomes moderator-only');
ok((grep { $_->{id} == $updated_policy_category->{id} } @{ $forums->categories }), 'Forums module includes newly public categories in guest lists');
$updated_policy_category = $forums->save_category(
    id          => $updated_policy_category->{id},
    title       => $updated_policy_category->{title},
    slug        => $updated_policy_category->{slug},
    description => $updated_policy_category->{description},
    position    => $updated_policy_category->{position},
    status      => 'open',
    visibility  => 'moderators',
);
ok(!(grep { $_->{id} == $updated_policy_category->{id} } @{ $forums->categories(viewer_account_id => $community_account->{id}) }), 'Forums module applies updated moderator-only category policy to regular accounts');
ok((grep { $_->{id} == $updated_policy_category->{id} } @{ $forums->categories(viewer_account_id => $forum_moderator->{id}) }), 'Forums module applies updated moderator-only category policy to moderators');
my $forum_topic = $forums->create_topic(
    category_id => $forum_category->{id},
    account_id  => $community_account->{id},
    ip_address  => '198.51.100.10',
    title       => 'Welcome to v3',
    body        => 'The v3 forum module is active.',
);
ok($forum_topic->{id}, 'Forums module creates account-backed topics');
is($forum_topic->{ip_address}, '198.51.100.10', 'Forums module stores topic IP context for abuse controls');
my $later_hidden_category = $forums->save_category(title => 'Later Hidden Forum', description => 'Starts open and is hidden after content exists');
my $later_hidden_topic = $forums->create_topic(
    category_id => $later_hidden_category->{id},
    account_id  => $community_account->{id},
    title       => 'Visibility boundary',
    body        => 'This topic disappears from public forum helpers when the category is hidden.',
);
$later_hidden_category = $forums->save_category(
    id          => $later_hidden_category->{id},
    title       => $later_hidden_category->{title},
    slug        => $later_hidden_category->{slug},
    description => $later_hidden_category->{description},
    status      => 'hidden',
);
ok(!@{ $forums->topics_for_category($later_hidden_category->{id}) }, 'Forums module hides topic lists when a category becomes hidden');
ok(!$forums->topic_by_slug($later_hidden_category->{slug}, $later_hidden_topic->{slug}), 'Forums module hides direct topic lookup for hidden categories');
ok(!@{ $forums->posts_for_topic($later_hidden_topic->{id}) }, 'Forums module hides post lists for topics in hidden categories');
ok($forums->topic_by_slug($later_hidden_category->{slug}, $later_hidden_topic->{slug}, include_hidden => 1), 'Forums module keeps admin access to hidden-category topics');
ok(@{ $forums->posts_for_topic($later_hidden_topic->{id}, include_hidden => 1) }, 'Forums module keeps admin access to hidden-category posts');
my $forum_reply = $forums->add_reply(
    topic_id   => $forum_topic->{id},
    account_id => $community_account->{id},
    ip_address => '198.51.100.10',
    body       => 'Replying through the unified account system.',
);
ok($forum_reply->{id}, 'Forums module creates replies');
is($forum_reply->{ip_address}, '198.51.100.10', 'Forums module stores reply IP context for abuse controls');
my $forum_external_reply = $forums->add_reply(
    topic_id   => $forum_topic->{id},
    account_id => $oauth_result->{account}{id},
    body       => 'Replying to @community through notifications.',
);
ok($forum_external_reply->{id}, 'Forums module creates cross-account replies');
my $disabled_forum_account = $accounts->create_account(
    email        => 'disabled-forum@example.test',
    username     => 'disabled-forum',
    display_name => 'Disabled Forum',
    password     => 'correct horse battery staple',
);
my $disabled_forum_topic = $forums->create_topic(
    category_id => $forum_category->{id},
    account_id  => $disabled_forum_account->{id},
    title       => 'Disabled account topic',
    body        => 'This topic should leave public forum helpers after account moderation.',
);
my $disabled_forum_reply = $forums->add_reply(
    topic_id   => $forum_topic->{id},
    account_id => $disabled_forum_account->{id},
    body       => 'This reply should leave public forum helpers after account moderation.',
);
$accounts->set_status(id => $disabled_forum_account->{id}, status => 'disabled', moderation_note => 'forum read visibility test', admin_user_id => $admin_user_id);
ok(!(grep { $_->{id} == $disabled_forum_topic->{id} } @{ $forums->topics_for_category($forum_category->{id}) }), 'Forums module hides disabled-account topics from public topic lists');
ok(!(grep { $_->{id} == $disabled_forum_topic->{id} } @{ $forums->latest_topics }), 'Forums module hides disabled-account topics from latest topic lists');
ok(!$forums->topic_by_slug($forum_category->{slug}, $disabled_forum_topic->{slug}), 'Forums module hides disabled-account direct topic lookup');
ok($forums->topic_by_slug($forum_category->{slug}, $disabled_forum_topic->{slug}, include_hidden => 1), 'Forums module keeps admin access to disabled-account topics');
ok(!(grep { $_->{id} == $disabled_forum_reply->{id} } @{ $forums->posts_for_topic($forum_topic->{id}) }), 'Forums module hides disabled-account replies from public post lists');
ok((grep { $_->{id} == $disabled_forum_reply->{id} } @{ $forums->posts_for_topic($forum_topic->{id}, include_hidden => 1) }), 'Forums module keeps admin access to disabled-account replies');
my ($public_forum_topic_summary) = grep { $_->{id} == $forum_topic->{id} } @{ $forums->topics_for_category($forum_category->{id}) };
is(int($public_forum_topic_summary->{reply_count} || 0), 3, 'Forums module excludes disabled-account replies from public topic reply counts');
my ($admin_forum_topic_summary) = grep { $_->{id} == $forum_topic->{id} } @{ $forums->topics_for_category($forum_category->{id}, include_hidden => 1) };
ok(int($admin_forum_topic_summary->{reply_count} || 0) >= 4, 'Forums module keeps disabled-account replies in admin topic review counts');
my ($public_forum_category_counts) = grep { $_->{id} == $forum_category->{id} } @{ $forums->categories };
my ($admin_forum_category_counts) = grep { $_->{id} == $forum_category->{id} } @{ $forums->categories(include_hidden => 1) };
ok(int($public_forum_category_counts->{topic_count} || 0) < int($admin_forum_category_counts->{topic_count} || 0), 'Forums module excludes disabled-account topics from public category counts');
ok(int($public_forum_category_counts->{post_count} || 0) < int($admin_forum_category_counts->{post_count} || 0), 'Forums module excludes disabled-account posts from public category counts');
my ($can_view_disabled_forum_topic, $disabled_forum_topic_reason) = $forums->can_account(action => 'view', account_id => $community_account->{id}, topic_id => $disabled_forum_topic->{id});
ok(!$can_view_disabled_forum_topic && $disabled_forum_topic_reason =~ /not visible/, 'Forums module blocks direct views of disabled-account topics');
my ($can_report_disabled_forum_reply, $disabled_forum_reply_reason) = $forums->can_account(action => 'report', account_id => $community_account->{id}, post_id => $disabled_forum_reply->{id});
ok(!$can_report_disabled_forum_reply && $disabled_forum_reply_reason =~ /not visible/, 'Forums module blocks reports against disabled-account replies');
my ($can_reply) = $forums->can_account(action => 'reply', account_id => $community_account->{id}, topic_id => $forum_topic->{id});
ok($can_reply, 'Forums module grants reply permission on open topics');
ok($forums->can_edit_post(post_id => $forum_reply->{id}, account_id => $community_account->{id}), 'Forums module grants post edit permission inside the edit window');
my ($can_edit_other_post, $edit_other_reason) = $forums->can_edit_post(post_id => $forum_reply->{id}, account_id => $oauth_result->{account}{id});
ok(!$can_edit_other_post && $edit_other_reason =~ /another account/, 'Forums module blocks edits from other regular accounts');
my $edited_reply = $forums->edit_post(id => $forum_reply->{id}, account_id => $community_account->{id}, body => 'Edited forum reply.');
is($edited_reply->{body}, 'Edited forum reply.', 'Forums module allows edits inside the edit window');
my $deletable_forum_reply = $forums->add_reply(
    topic_id   => $forum_topic->{id},
    account_id => $community_account->{id},
    body       => 'This reply can be soft deleted by its author.',
);
ok($forums->can_delete_post(post_id => $deletable_forum_reply->{id}, account_id => $community_account->{id}), 'Forums module grants post delete permission inside the edit window');
my ($can_delete_topic_starter, $delete_topic_starter_reason) = $forums->can_delete_post(post_id => $forums->_topic_starter_post_id($forum_topic->{id}), account_id => $community_account->{id});
ok(!$can_delete_topic_starter && $delete_topic_starter_reason =~ /topic starter/, 'Forums module blocks public deletion of topic starter posts');
my $deleted_reply = $forums->delete_post(id => $deletable_forum_reply->{id}, account_id => $community_account->{id});
is($deleted_reply->{status}, 'deleted', 'Forums module soft deletes author-owned replies');
ok(!(grep { $_->{id} == $deletable_forum_reply->{id} } @{ $forums->posts_for_topic($forum_topic->{id}) }), 'Forums module hides soft-deleted replies from public topic pages');
ok((grep { $_->{id} == $deletable_forum_reply->{id} } @{ $forums->posts_for_topic($forum_topic->{id}, include_hidden => 1) }), 'Forums module keeps soft-deleted replies available for admin review');
my $disabled_forum_editor = $accounts->create_account(
    email        => 'disabled-forum-editor@example.test',
    username     => 'disabled-forum-editor',
    display_name => 'Disabled Forum Editor',
    password     => 'correct horse battery staple',
);
my $disabled_editor_reply = $forums->add_reply(
    topic_id   => $forum_topic->{id},
    account_id => $disabled_forum_editor->{id},
    body       => 'This reply cannot be edited after account moderation.',
);
$accounts->set_status(id => $disabled_forum_editor->{id}, status => 'disabled', moderation_note => 'forum edit permission test', admin_user_id => $admin_user_id);
my $disabled_editor_ok = eval {
    $forums->edit_post(id => $disabled_editor_reply->{id}, account_id => $disabled_forum_editor->{id}, body => 'Disabled account edit attempt.');
    1;
};
ok(!$disabled_editor_ok && $@ =~ /account is not active/, 'Forums module blocks direct edits from disabled accounts');
my $duplicate_forum_ok = eval {
    $forums->add_reply(topic_id => $forum_topic->{id}, account_id => $community_account->{id}, body => 'Edited forum reply.');
    1;
};
ok(!$duplicate_forum_ok && $@ =~ /duplicate forum post/, 'Forums module suppresses duplicate replies');
$config->{forum_min_account_age_seconds} = 3600;
my $too_new_forum_account = $accounts->create_account(
    email        => 'too-new-forum@example.test',
    username     => 'too-new-forum',
    display_name => 'Too New Forum',
    password     => 'correct horse battery staple',
);
my $too_new_topic_ok = eval {
    $forums->create_topic(
        category_id => $forum_category->{id},
        account_id  => $too_new_forum_account->{id},
        title       => 'Too new',
        body        => 'This should wait for the account age gate.',
    );
    1;
};
ok(!$too_new_topic_ok && $@ =~ /too new/, 'Forums module blocks writes from accounts younger than the configured minimum age');
$config->{forum_min_account_age_seconds} = 0;
$config->{forum_max_posts_per_ip_window} = 1;
my $ip_limited_reply_ok = eval {
    $forums->add_reply(
        topic_id   => $forum_topic->{id},
        account_id => $oauth_result->{account}{id},
        ip_address => '203.0.113.55',
        body       => 'First reply from this IP is allowed.',
    );
    $forums->add_reply(
        topic_id   => $forum_topic->{id},
        account_id => $community_account->{id},
        ip_address => '203.0.113.55',
        body       => 'Second reply from this IP is blocked.',
    );
    1;
};
ok(!$ip_limited_reply_ok && $@ =~ /ip rate limit/, 'Forums module enforces IP-based write limits');
$config->{forum_max_posts_per_ip_window} = 30;
my $forum_topic_report = $forums->report_topic(topic_id => $forum_topic->{id}, reporter_account_id => $oauth_result->{account}{id}, reason => 'Review this topic');
ok($forum_topic_report->{id}, 'Forums module stores topic report queue items');
my $forum_report = $forums->report_post(post_id => $forum_reply->{id}, reporter_account_id => $community_account->{id}, reason => 'Review this reply');
ok($forum_report->{id}, 'Forums module stores report queue items');
my $duplicate_forum_report_ok = eval {
    $forums->report_post(post_id => $forum_reply->{id}, reporter_account_id => $community_account->{id}, reason => 'Review this reply again');
    1;
};
ok(!$duplicate_forum_report_ok && $@ =~ /duplicate forum report/, 'Forums module suppresses duplicate open reports from the same account');
ok(@{ $forums->reports(status => 'open') } >= 1, 'Forums module lists open reports');
is($forums->set_report_status(id => $forum_report->{id}, status => 'actioned', moderator_account_id => $forum_moderator->{id}, moderator_note => 'Handled')->{status}, 'actioned', 'Forums module resolves reports');
my $non_moderator_pin_ok = eval {
    $forums->pin_topic(id => $forum_topic->{id}, pinned => 1, moderator_account_id => $community_account->{id});
    1;
};
ok(!$non_moderator_pin_ok && $@ =~ /moderator permission/, 'Forums module rejects moderator actions from regular accounts');
my $missing_forum_actor_ok = eval {
    $forums->set_post_status(id => $forum_reply->{id}, status => 'hidden');
    1;
};
ok(!$missing_forum_actor_ok && $@ =~ /moderator account or active admin user/, 'Forums module rejects actorless moderation actions');
is($forums->pin_topic(id => $forum_topic->{id}, pinned => 1, moderator_account_id => $forum_moderator->{id})->{pinned}, 1, 'Forums module pins topics through moderator accounts');
is($forums->set_post_status(id => $forum_reply->{id}, status => 'hidden', moderator_account_id => $forum_moderator->{id}, moderator_note => 'Off-topic')->{moderator_note}, 'Off-topic', 'Forums module stores post moderation notes');
my ($can_report_hidden_post, $hidden_post_reason) = $forums->can_account(action => 'report', account_id => $community_account->{id}, post_id => $forum_reply->{id});
ok(!$can_report_hidden_post && $hidden_post_reason =~ /not visible/, 'Forums module blocks reports against hidden posts for regular accounts');
my $moderator_report_hidden_post_ok = eval {
    $forums->report_post(post_id => $forum_reply->{id}, reporter_account_id => $forum_moderator->{id}, reason => 'Moderator report should not bypass public visibility.');
    1;
};
ok(!$moderator_report_hidden_post_ok && $@ =~ /not visible/, 'Forums module keeps report permission visibility-bound even for moderators');
is($forums->set_post_status(id => $forum_reply->{id}, status => 'visible', moderator_account_id => $forum_moderator->{id})->{status}, 'visible', 'Forums module restores post visibility');
my $hidden_topic = $forums->create_topic(
    category_id => $forum_category->{id},
    account_id  => $community_account->{id},
    title       => 'Hidden topic',
    body        => 'This topic is hidden by moderation.',
);
is($forums->set_topic_status(id => $hidden_topic->{id}, status => 'hidden', moderator_account_id => $forum_moderator->{id}, moderator_note => 'Needs review')->{moderator_note}, 'Needs review', 'Forums module stores topic moderation notes');
my ($can_view_hidden_topic, $hidden_topic_reason) = $forums->can_account(action => 'view', account_id => $community_account->{id}, topic_id => $hidden_topic->{id});
ok(!$can_view_hidden_topic && $hidden_topic_reason =~ /not visible/, 'Forums module denies hidden topic views for regular accounts');
ok($forums->can_account(action => 'view', account_id => $forum_moderator->{id}, topic_id => $hidden_topic->{id}), 'Forums module allows moderators to view hidden topics');
is($forums->soft_delete_topic(id => $hidden_topic->{id}, moderator_account_id => $forum_moderator->{id})->{status}, 'deleted', 'Forums module soft-deletes topics through moderation');
is($forums->set_topic_status(id => $forum_topic->{id}, status => 'locked', moderator_account_id => $forum_moderator->{id})->{status}, 'locked', 'Forums module moderates topic status');
my ($can_reply_locked, $locked_reason) = $forums->can_account(action => 'reply', account_id => $community_account->{id}, topic_id => $forum_topic->{id});
ok(!$can_reply_locked && $locked_reason =~ /not open/, 'Forums module blocks replies on locked topics');
my $forum_notices = $notifications->list(module_key => 'forums', limit => 100);
ok((grep { $_->{topic} eq 'forums.reply_created' } @{$forum_notices}), 'Forums module emits reply notifications');
ok((grep { $_->{topic} eq 'forums.mention' } @{$forum_notices}), 'Forums module emits mention notifications');
ok((grep { $_->{topic} eq 'forums.reported' } @{$forum_notices}), 'Forums module emits report notifications');
ok((grep { $_->{topic} eq 'forums.moderation_needed' } @{$forum_notices}), 'Forums module emits moderation notifications');
ok((grep { $_->{topic} eq 'forums.moderation_action' } @{$forum_notices}), 'Forums module emits moderation action notifications');

my $social = DesertCMS::Social->new(config => $config, db => $db, notifications => $notifications);
my $profile = $social->ensure_profile(
    account_id   => $community_account->{id},
    handle       => 'community',
    display_name => 'Community',
    bio          => 'Unified public account profile.',
);
is($profile->{handle}, 'community', 'Social module creates account profile');
my $follower_profile = $social->ensure_profile(
    account_id   => $oauth_result->{account}{id},
    handle       => 'oauthuser',
    display_name => 'OAuth User',
);
is($follower_profile->{handle}, 'oauthuser', 'Social module creates a second profile for follows and mentions');
my $stranger_account = $accounts->create_account(
    email        => 'stranger@example.test',
    username     => 'stranger',
    display_name => 'Stranger',
    password     => 'correct horse battery staple',
);
$social->ensure_profile(
    account_id   => $stranger_account->{id},
    handle       => 'stranger',
    display_name => 'Stranger',
);
my $disabled_social_account = $accounts->create_account(
    email        => 'disabled-social@example.test',
    username     => 'disabled-social',
    display_name => 'Disabled Social',
    password     => 'correct horse battery staple',
);
$accounts->set_status(id => $disabled_social_account->{id}, status => 'disabled', moderation_note => 'social disabled-user test', admin_user_id => $admin_user_id);
my $disabled_social_post_ok = eval {
    $social->create_post(account_id => $disabled_social_account->{id}, body => 'Disabled users cannot post.');
    1;
};
ok(!$disabled_social_post_ok && $@ =~ /account is not active/, 'Social module blocks disabled users from posting');
my $social_post = $social->create_post(
    account_id => $community_account->{id},
    body       => 'Social module feed post.',
);
ok($social_post->{id}, 'Social module creates feed posts');
my $social_ip_post = $social->create_post(
    account_id  => $community_account->{id},
    body        => 'Social module records IP context on posts.',
    ip_address  => '198.51.100.120',
);
is($social_ip_post->{ip_address}, '198.51.100.120', 'Social module stores post IP context for abuse controls');
my $too_new_social_account = $accounts->create_account(
    email        => 'too-new-social@example.test',
    username     => 'too-new-social',
    display_name => 'Too New Social',
    password     => 'correct horse battery staple',
);
$config->{social_min_account_age_seconds} = 3600;
my $too_new_social_ok = eval {
    $social->create_post(
        account_id => $too_new_social_account->{id},
        body       => 'Too-new social accounts cannot post yet.',
        ip_address => '198.51.100.121',
    );
    1;
};
ok(!$too_new_social_ok && $@ =~ /too new/, 'Social module blocks writes from accounts younger than the configured minimum age');
$config->{social_min_account_age_seconds} = 0;
$config->{social_rate_window_seconds} = 600;
$config->{social_max_posts_per_ip_window} = 1;
$social->create_post(
    account_id => $community_account->{id},
    body       => 'First social post from a limited IP.',
    ip_address => '198.51.100.122',
);
my $social_ip_limit_ok = eval {
    $social->create_post(
        account_id => $stranger_account->{id},
        body       => 'Second social post from a limited IP.',
        ip_address => '198.51.100.122',
    );
    1;
};
ok(!$social_ip_limit_ok && $@ =~ /social ip rate limit/, 'Social module enforces per-IP post rate limits');
$config->{social_max_posts_per_ip_window} = 30;
my $followers_post = $social->create_post(
    account_id => $community_account->{id},
    body       => 'Followers-only social module post.',
    visibility => 'followers',
);
my $private_post = $social->create_post(
    account_id => $community_account->{id},
    body       => 'Private social module post.',
    visibility => 'private',
);
my $second_public_post = $social->create_post(
    account_id => $community_account->{id},
    body       => 'Second public social module post for pagination.',
);
my $author_deleted_social_post = $social->create_post(
    account_id => $community_account->{id},
    body       => 'Author deleted social module post.',
);
is($social->delete_post(id => $author_deleted_social_post->{id}, account_id => $community_account->{id})->{status}, 'deleted', 'Social module lets authors soft-delete their own posts');
ok(!(grep { $_->{id} == $author_deleted_social_post->{id} } @{ $social->global_feed(viewer_account_id => $stranger_account->{id}) }), 'Social module excludes author-deleted posts from public feeds');
my $wrong_author_social_delete_ok = eval {
    $social->delete_post(id => $social_ip_post->{id}, account_id => $stranger_account->{id});
    1;
};
ok(!$wrong_author_social_delete_ok && $@ =~ /belongs to another account/, 'Social module rejects author post deletes from other accounts');
my $private_profile_account = $accounts->create_account(
    email        => 'private-profile@example.test',
    username     => 'private-profile',
    display_name => 'Private Profile',
    password     => 'correct horse battery staple',
);
$social->ensure_profile(
    account_id   => $private_profile_account->{id},
    handle       => 'privateprofile',
    display_name => 'Private Profile',
    visibility   => 'private',
);
my $private_profile_public_post = $social->create_post(
    account_id => $private_profile_account->{id},
    body       => 'Public post on a private social profile.',
);
my $private_profile_reply = $social->add_reply(
    post_id    => $private_profile_public_post->{id},
    account_id => $private_profile_account->{id},
    body       => 'Private-profile reply remains scoped to visible viewers.',
);
ok(!$social->profile_by_handle('privateprofile', viewer_account_id => $stranger_account->{id}), 'Social module hides private profiles from unrelated accounts');
ok($social->profile_by_handle('privateprofile', viewer_account_id => $private_profile_account->{id}), 'Social module lets owners view private profiles');
ok($social->profile_by_handle('privateprofile', include_hidden => 1), 'Social module keeps admin access to private profile lookups');
my $private_profile_report_ok = eval {
    $social->report_profile(profile_account_id => $private_profile_account->{id}, reporter_account_id => $stranger_account->{id}, reason => 'Cannot report a private profile that is not visible.');
    1;
};
ok(!$private_profile_report_ok && $@ =~ /profile is private/, 'Social module blocks profile reports when the reporter cannot view the profile');
ok(!(grep { $_->{id} == $private_profile_public_post->{id} } @{ $social->global_feed(viewer_account_id => $stranger_account->{id}) }), 'Social module excludes private-profile posts from the global feed');
my ($can_view_private_profile_post, $private_profile_post_reason) = $social->can_view_post(viewer_account_id => $stranger_account->{id}, post_id => $private_profile_public_post->{id});
ok(!$can_view_private_profile_post && $private_profile_post_reason =~ /private/, 'Social module applies profile visibility to direct post checks');
ok((grep { $_->{id} == $private_profile_public_post->{id} } @{ $social->profile_feed(profile_account_id => $private_profile_account->{id}, viewer_account_id => $private_profile_account->{id}) }), 'Social module lets owners read private-profile feeds');
ok(!@{ $social->replies_for_post(post_id => $private_profile_public_post->{id}, viewer_account_id => $stranger_account->{id}) }, 'Social module hides private-profile replies from unrelated accounts');
ok((grep { $_->{id} == $private_profile_reply->{id} } @{ $social->replies_for_post(post_id => $private_profile_public_post->{id}, viewer_account_id => $private_profile_account->{id}) }), 'Social module lets owners read private-profile replies');
ok((grep { $_->{id} == $social_post->{id} } @{ $social->global_feed(viewer_account_id => $stranger_account->{id}) }), 'Social module returns public posts in the global feed');
ok(!(grep { $_->{id} == $followers_post->{id} } @{ $social->global_feed(viewer_account_id => $stranger_account->{id}) }), 'Social module excludes followers-only posts from the global feed');
ok(!(grep { $_->{id} == $followers_post->{id} } @{ $social->profile_feed(profile_account_id => $community_account->{id}, viewer_account_id => $stranger_account->{id}) }), 'Social module hides followers-only profile posts from non-followers');
ok((grep { $_->{id} == $private_post->{id} } @{ $social->profile_feed(profile_account_id => $community_account->{id}, viewer_account_id => $community_account->{id}) }), 'Social module shows private profile posts to the owner');
my ($can_view_private) = $social->can_view_post(viewer_account_id => $stranger_account->{id}, post_id => $private_post->{id});
ok(!$can_view_private, 'Social module blocks private posts from other accounts');
my $global_page_one = $social->global_feed(limit => 1, page => 1);
my $global_page_two = $social->global_feed(limit => 1, page => 2);
ok(@{$global_page_one} == 1 && @{$global_page_two} == 1 && $global_page_one->[0]{id} != $global_page_two->[0]{id}, 'Social module paginates feed results without duplicate rows');
my $duplicate_social_ok = eval {
    $social->create_post(account_id => $community_account->{id}, body => 'Social module feed post.');
    1;
};
ok(!$duplicate_social_ok && $@ =~ /duplicate social post/, 'Social module suppresses duplicate feed posts');
my $disabled_follow_ok = eval {
    $social->follow(follower_account_id => $disabled_social_account->{id}, followed_account_id => $community_account->{id});
    1;
};
ok(!$disabled_follow_ok && $@ =~ /follower account is not active/, 'Social module blocks disabled users from following');
ok($social->follow(follower_account_id => $oauth_result->{account}{id}, followed_account_id => $community_account->{id}), 'Social module follows profiles');
is($social->follow_status(follower_account_id => $oauth_result->{account}{id}, followed_account_id => $community_account->{id}), 'active', 'Social module reports active follow state');
ok($social->can_view_post(viewer_account_id => $oauth_result->{account}{id}, post_id => $followers_post->{id}), 'Social module allows active followers to view followers-only posts');
ok((grep { $_->{id} == $followers_post->{id} } @{ $social->profile_feed(profile_account_id => $community_account->{id}, viewer_account_id => $oauth_result->{account}{id}) }), 'Social module includes followers-only posts in follower profile feeds');
ok((grep { $_->{id} == $social_post->{id} } @{ $social->following_feed(account_id => $oauth_result->{account}{id}) }), 'Social module returns following feed posts');
my $later_disabled_follower = $accounts->create_account(
    email        => 'later-disabled-follower@example.test',
    username     => 'later-disabled-follower',
    display_name => 'Later Disabled Follower',
    password     => 'correct horse battery staple',
);
$social->ensure_profile(
    account_id   => $later_disabled_follower->{id},
    handle       => 'laterdisabledfollower',
    display_name => 'Later Disabled Follower',
);
ok($social->follow(follower_account_id => $later_disabled_follower->{id}, followed_account_id => $community_account->{id}), 'Social module follows before account moderation');
ok((grep { $_->{id} == $followers_post->{id} } @{ $social->following_feed(account_id => $later_disabled_follower->{id}) }), 'Social module returns following feed posts for active viewers');
$accounts->set_status(id => $later_disabled_follower->{id}, status => 'disabled', moderation_note => 'social feed visibility test', admin_user_id => $admin_user_id);
ok(!@{ $social->following_feed(account_id => $later_disabled_follower->{id}) }, 'Social module hides following feeds from disabled viewers');
my ($disabled_follower_can_view, $disabled_follower_reason) = $social->can_view_post(viewer_account_id => $later_disabled_follower->{id}, post_id => $followers_post->{id});
ok(!$disabled_follower_can_view && $disabled_follower_reason =~ /viewer account is not active/, 'Social module blocks disabled viewers from follower-only direct post checks');
my $moderated_profile_follower = $accounts->create_account(
    email        => 'moderated-profile-follower@example.test',
    username     => 'moderated-profile-follower',
    display_name => 'Moderated Profile Follower',
    password     => 'correct horse battery staple',
);
$social->ensure_profile(account_id => $moderated_profile_follower->{id}, handle => 'moderatedprofilefollower');
ok($social->follow(follower_account_id => $moderated_profile_follower->{id}, followed_account_id => $community_account->{id}), 'Social module follows before profile moderation');
ok((grep { $_->{id} == $followers_post->{id} } @{ $social->following_feed(account_id => $moderated_profile_follower->{id}) }), 'Social module returns following feed posts for active social profiles');
is($social->set_profile_status(account_id => $moderated_profile_follower->{id}, status => 'moderated', admin_user_id => $admin_user_id)->{status}, 'moderated', 'Social module can moderate follower profiles');
ok(!@{ $social->following_feed(account_id => $moderated_profile_follower->{id}) }, 'Social module hides following feeds from moderated social profiles');
my ($moderated_profile_can_view, $moderated_profile_reason) = $social->can_view_post(viewer_account_id => $moderated_profile_follower->{id}, post_id => $followers_post->{id});
ok(!$moderated_profile_can_view && $moderated_profile_reason =~ /requires following/, 'Social module blocks moderated social profiles from follower-only direct post checks');
ok($social->block(blocker_account_id => $community_account->{id}, blocked_account_id => $oauth_result->{account}{id}), 'Social module exposes first-class profile blocking');
is($social->follow_status(follower_account_id => $community_account->{id}, followed_account_id => $oauth_result->{account}{id}), 'blocked', 'Social module stores blocked relationships');
is($social->follow_status(follower_account_id => $oauth_result->{account}{id}, followed_account_id => $community_account->{id}), '', 'Social module removes reciprocal follows when blocking');
my $blocked_follow_ok = eval {
    $social->follow(follower_account_id => $oauth_result->{account}{id}, followed_account_id => $community_account->{id});
    1;
};
ok(!$blocked_follow_ok && $@ =~ /blocked/, 'Social module blocks new follows across blocked relationships');
my ($can_view_blocked, $blocked_reason) = $social->can_view_post(viewer_account_id => $oauth_result->{account}{id}, post_id => $followers_post->{id});
ok(!$can_view_blocked && $blocked_reason =~ /blocked/, 'Social module blocks feed visibility across blocked relationships');
my $blocked_react_ok = eval {
    $social->react(post_id => $followers_post->{id}, account_id => $oauth_result->{account}{id}, reaction => 'like');
    1;
};
ok(!$blocked_react_ok && $@ =~ /blocked/, 'Social module blocks reactions across blocked relationships');
my $blocked_reply_ok = eval {
    $social->add_reply(post_id => $followers_post->{id}, account_id => $oauth_result->{account}{id}, body => 'Blocked users cannot reply.');
    1;
};
ok(!$blocked_reply_ok && $@ =~ /blocked/, 'Social module blocks replies across blocked relationships');
my $blocked_report_ok = eval {
    $social->report_post(post_id => $followers_post->{id}, reporter_account_id => $oauth_result->{account}{id}, reason => 'Blocked users cannot report hidden content.');
    1;
};
ok(!$blocked_report_ok && $@ =~ /blocked/, 'Social module blocks reports across blocked relationships');
ok($social->unblock(blocker_account_id => $community_account->{id}, blocked_account_id => $oauth_result->{account}{id}), 'Social module exposes first-class profile unblocking');
is($social->follow_status(follower_account_id => $community_account->{id}, followed_account_id => $oauth_result->{account}{id}), '', 'Social module removes blocked relationships');
ok($social->unfollow(follower_account_id => $oauth_result->{account}{id}, followed_account_id => $community_account->{id}), 'Social module unfollows profiles');
is($social->follow_status(follower_account_id => $oauth_result->{account}{id}, followed_account_id => $community_account->{id}), '', 'Social module clears follow state after unfollow');
my ($stranger_mention_count_before) = $db->dbh->selectrow_array(
    'SELECT COUNT(*) FROM notifications WHERE module_key = ? AND topic = ? AND recipient_account_id = ?',
    undef,
    'social',
    'social.mention',
    $stranger_account->{id}
);
$social->create_post(
    account_id => $community_account->{id},
    body       => 'Follower-only mention should not notify @stranger.',
    visibility => 'followers',
);
my ($stranger_mention_count_after) = $db->dbh->selectrow_array(
    'SELECT COUNT(*) FROM notifications WHERE module_key = ? AND topic = ? AND recipient_account_id = ?',
    undef,
    'social',
    'social.mention',
    $stranger_account->{id}
);
is($stranger_mention_count_after, $stranger_mention_count_before, 'Social module does not notify mentions when the recipient cannot view the post');
ok($social->follow(follower_account_id => $oauth_result->{account}{id}, followed_account_id => $community_account->{id}), 'Social module restores a follower relationship for mention visibility checks');
my ($follower_mention_count_before) = $db->dbh->selectrow_array(
    'SELECT COUNT(*) FROM notifications WHERE module_key = ? AND topic = ? AND recipient_account_id = ?',
    undef,
    'social',
    'social.mention',
    $oauth_result->{account}{id}
);
$social->create_post(
    account_id => $community_account->{id},
    body       => 'Follower-only mention should notify @oauthuser.',
    visibility => 'followers',
);
my ($follower_mention_count_after) = $db->dbh->selectrow_array(
    'SELECT COUNT(*) FROM notifications WHERE module_key = ? AND topic = ? AND recipient_account_id = ?',
    undef,
    'social',
    'social.mention',
    $oauth_result->{account}{id}
);
is($follower_mention_count_after, $follower_mention_count_before + 1, 'Social module notifies mentions when the recipient can view the post');
my $mention_post = $social->create_post(
    account_id => $community_account->{id},
    body       => 'Mentioning @oauthuser from the v3 social feed.',
);
ok((grep { $_->{handle} eq 'oauthuser' } @{ $social->mentions_for_post($mention_post) }), 'Social module extracts active profile mentions');
my $disabled_reaction_ok = eval {
    $social->react(post_id => $social_post->{id}, account_id => $disabled_social_account->{id}, reaction => 'like');
    1;
};
ok(!$disabled_reaction_ok && $@ =~ /account is not active/, 'Social module blocks disabled users from reacting');
ok($social->react(post_id => $social_post->{id}, account_id => $oauth_result->{account}{id}, reaction => 'like'), 'Social module stores reactions');
my $social_reply = $social->add_reply(
    post_id    => $social_post->{id},
    account_id => $oauth_result->{account}{id},
    body       => 'Replying to @community from the social module.',
);
ok($social_reply->{id}, 'Social module creates replies');
my $author_deleted_social_reply = $social->add_reply(
    post_id    => $social_post->{id},
    account_id => $oauth_result->{account}{id},
    body       => 'Author deleted social module reply.',
);
is($social->delete_reply(id => $author_deleted_social_reply->{id}, account_id => $oauth_result->{account}{id})->{status}, 'deleted', 'Social module lets authors soft-delete their own replies');
ok(!(grep { $_->{id} == $author_deleted_social_reply->{id} } @{ $social->replies_for_post(post_id => $social_post->{id}) }), 'Social module excludes author-deleted replies from public reply lists');
my $wrong_author_social_reply_delete_ok = eval {
    $social->delete_reply(id => $social_reply->{id}, account_id => $community_account->{id});
    1;
};
ok(!$wrong_author_social_reply_delete_ok && $@ =~ /belongs to another account/, 'Social module rejects author reply deletes from other accounts');
my $social_ip_reply = $social->add_reply(
    post_id    => $social_post->{id},
    account_id => $oauth_result->{account}{id},
    body       => 'Social module records IP context on replies.',
    ip_address => '198.51.100.123',
);
is($social_ip_reply->{ip_address}, '198.51.100.123', 'Social module stores reply IP context for abuse controls');
$config->{social_max_replies_per_ip_window} = 1;
$social->add_reply(
    post_id    => $social_post->{id},
    account_id => $oauth_result->{account}{id},
    body       => 'First social reply from a limited IP.',
    ip_address => '198.51.100.124',
);
my $social_reply_ip_limit_ok = eval {
    $social->add_reply(
        post_id    => $social_post->{id},
        account_id => $stranger_account->{id},
        body       => 'Second social reply from a limited IP.',
        ip_address => '198.51.100.124',
    );
    1;
};
ok(!$social_reply_ip_limit_ok && $@ =~ /social ip rate limit/, 'Social module enforces per-IP reply rate limits');
$config->{social_max_replies_per_ip_window} = 60;
ok((grep { $_->{handle} eq 'community' } @{ $social->mentions_for_reply($social_reply) }), 'Social module extracts reply mentions');
ok((grep { $_->{id} == $social_reply->{id} } @{ $social->replies_for_post(post_id => $social_post->{id}) }), 'Social module lists visible replies');
my $later_disabled_reply_author = $accounts->create_account(
    email        => 'later-disabled-social-reply@example.test',
    username     => 'later-disabled-social-reply',
    display_name => 'Later Disabled Social Reply',
    password     => 'correct horse battery staple',
);
my $later_disabled_social_reply = $social->add_reply(
    post_id    => $social_post->{id},
    account_id => $later_disabled_reply_author->{id},
    body       => 'This reply should leave public social helpers after account moderation.',
);
$accounts->set_status(id => $later_disabled_reply_author->{id}, status => 'disabled', moderation_note => 'social reply visibility test', admin_user_id => $admin_user_id);
ok(!(grep { $_->{id} == $later_disabled_social_reply->{id} } @{ $social->replies_for_post(post_id => $social_post->{id}) }), 'Social module hides disabled-account replies from public reply lists');
my $disabled_social_reply_report_ok = eval {
    $social->report_reply(reply_id => $later_disabled_social_reply->{id}, reporter_account_id => $community_account->{id}, reason => 'Hidden disabled-account replies cannot be reported publicly.');
    1;
};
ok(!$disabled_social_reply_report_ok && $@ =~ /reply is not visible/, 'Social module blocks reports against disabled-account replies');
my $non_moderator_social_status_ok = eval {
    $social->set_post_status(id => $second_public_post->{id}, status => 'hidden', moderator_account_id => $community_account->{id});
    1;
};
ok(!$non_moderator_social_status_ok && $@ =~ /social moderator permission/, 'Social module rejects moderation actions from regular accounts');
my $missing_social_actor_ok = eval {
    $social->set_reply_status(id => $social_reply->{id}, status => 'hidden');
    1;
};
ok(!$missing_social_actor_ok && $@ =~ /moderator account or active admin user/, 'Social module rejects actorless moderation actions');
is($social->set_post_status(id => $second_public_post->{id}, status => 'hidden', moderator_account_id => $forum_moderator->{id}, moderator_note => 'Moderator hidden')->{status}, 'hidden', 'Social module allows moderator-role accounts to moderate posts');
is($social->set_post_status(id => $second_public_post->{id}, status => 'visible', moderator_account_id => $forum_moderator->{id})->{status}, 'visible', 'Social module restores moderated posts through moderator accounts');
is($social->set_reply_status(id => $social_reply->{id}, status => 'hidden', moderator_account_id => $forum_moderator->{id})->{status}, 'hidden', 'Social module moderates reply status through moderator accounts');
ok(!(grep { $_->{id} == $social_reply->{id} } @{ $social->replies_for_post(post_id => $social_post->{id}) }), 'Social module hides moderated replies from public reply lists');
my $reported_social_reply = $social->add_reply(
    post_id    => $social_post->{id},
    account_id => $oauth_result->{account}{id},
    body       => 'This social reply should enter moderation.',
);
my $social_reply_report = $social->report_reply(reply_id => $reported_social_reply->{id}, reporter_account_id => $community_account->{id}, reason => 'Review this reply');
ok($social_reply_report->{id}, 'Social module stores reply report queue items');
ok((grep { int($_->{reply_id} || 0) == $reported_social_reply->{id} } @{ $social->reports(status => 'open') }), 'Social module lists open reply reports');
my $social_profile_report = $social->report_profile(profile_account_id => $community_account->{id}, reporter_account_id => $oauth_result->{account}{id}, reason => 'Review this profile');
ok($social_profile_report->{id}, 'Social module stores profile report queue items');
my $social_report = $social->report_post(post_id => $social_post->{id}, reporter_account_id => $oauth_result->{account}{id}, reason => 'Review this post');
ok($social_report->{id}, 'Social module stores report queue items');
my $duplicate_social_report_ok = eval {
    $social->report_post(post_id => $social_post->{id}, reporter_account_id => $oauth_result->{account}{id}, reason => 'Review this post again');
    1;
};
ok(!$duplicate_social_report_ok && $@ =~ /duplicate social report/, 'Social module suppresses duplicate open reports from the same account');
ok(@{ $social->reports(status => 'open') } >= 1, 'Social module lists open reports');
is($social->set_report_status(id => $social_report->{id}, status => 'actioned', moderator_account_id => $forum_moderator->{id}, moderator_note => 'Handled')->{status}, 'actioned', 'Social module resolves reports through moderator accounts');
is($social->set_post_status(id => $social_post->{id}, status => 'reported', moderator_account_id => $forum_moderator->{id})->{status}, 'reported', 'Social module supports post moderation through moderator accounts');
my $social_notices = $notifications->list(module_key => 'social', limit => 100);
ok((grep { $_->{topic} eq 'social.post_created' } @{$social_notices}), 'Social module emits post notifications');
ok((grep { $_->{topic} eq 'social.reply_created' } @{$social_notices}), 'Social module emits reply notifications');
ok((grep { $_->{topic} eq 'social.follow' } @{$social_notices}), 'Social module emits follow notifications');
ok((grep { $_->{topic} eq 'social.mention' } @{$social_notices}), 'Social module emits mention notifications');
ok((grep { $_->{topic} eq 'social.reaction' } @{$social_notices}), 'Social module emits reaction notifications');
ok((grep { $_->{topic} eq 'social.reported' } @{$social_notices}), 'Social module emits report notifications');
ok((grep { $_->{topic} eq 'social.moderation_needed' } @{$social_notices}), 'Social module emits moderation notifications');

my $live = DesertCMS::LiveStreaming->new(config => $config, db => $db, notifications => $notifications);
my $worker_contract = $live->worker_contract;
ok((grep { $_ eq 'pf' } @{ $worker_contract->{openbsd}{required_base} }), 'Live Streaming worker contract keeps pf as the network gate');
is($worker_contract->{hls}{served_by}, 'httpd', 'Live Streaming worker contract keeps httpd serving HLS assets');
ok($live->validate_hls_path('/streams/v3-launch-stream/index.m3u8'), 'Live Streaming module accepts local HLS playlist paths');
ok(!$live->validate_hls_path('https://evil.example.test/index.m3u8'), 'Live Streaming module rejects remote HLS playlist paths');
my $channel = $live->create_channel(
    title       => 'V3 Launch Stream',
    description => 'OBS-compatible stream channel.',
);
ok($channel->{id} && $channel->{stream_key}, 'Live Streaming module creates channel and one-time stream key');
ok($channel->{stream_key_rotated_at}, 'Live Streaming module records initial stream key rotation timestamp');
my $original_stream_key = $channel->{stream_key};
ok($live->verify_stream_key($channel->{id}, $original_stream_key), 'Live Streaming module verifies hashed stream keys');
my $rotated_channel = $live->rotate_stream_key($channel->{id});
ok(!$live->verify_stream_key($channel->{id}, $original_stream_key), 'Live Streaming module rejects rotated-out stream keys');
ok($live->verify_stream_key($channel->{id}, $rotated_channel->{stream_key}), 'Live Streaming module accepts rotated stream keys');
my $missing_rotation_ok = eval {
    $live->rotate_stream_key(999_999);
    1;
};
ok(!$missing_rotation_ok && $@ =~ /live channel was not found/, 'Live Streaming module rejects missing-channel stream key rotation');
ok(!$live->ingest_authorized(channel_id => $channel->{id}, stream_key => 'wrong key'), 'Live Streaming module rejects wrong OBS ingest keys');
my $authorized_ingest = $live->ingest_authorized(channel_id => $channel->{id}, stream_key => $rotated_channel->{stream_key});
like($authorized_ingest->{ingest_endpoint}, qr{\Artmp://}, 'Live Streaming module returns OBS ingest metadata for valid stream keys');
my $policy_disabled_channel = $live->create_channel(
    title         => 'Policy Disabled Ingest',
    ingest_policy => { enabled => 0 },
);
ok($live->verify_stream_key($policy_disabled_channel->{id}, $policy_disabled_channel->{stream_key}), 'Live Streaming module can retain a stream key while policy disables ingest');
ok(!$live->ingest_authorized(channel_id => $policy_disabled_channel->{id}, stream_key => $policy_disabled_channel->{stream_key}), 'Live Streaming direct ingest auth rejects policy-disabled channels');
my $policy_disabled_worker_ok = eval {
    $live->worker_ingest_auth(channel_id => $policy_disabled_channel->{id}, stream_key => $policy_disabled_channel->{stream_key}, worker_id => 'obs-worker-policy-disabled');
    1;
};
ok(!$policy_disabled_worker_ok && $@ =~ /ingest is disabled/, 'Live Streaming worker auth rejects policy-disabled channels');
my $policy_disabled_events = $live->worker_events(worker_id => 'obs-worker-policy-disabled');
ok((grep { $_->{event_type} eq 'auth' && $_->{status} eq 'rejected' && $_->{details}{reason} eq 'ingest_policy_disabled' } @{$policy_disabled_events}), 'Live Streaming worker auth records policy-disabled rejections');
my $status_policy_channel = $live->create_channel(
    title         => 'Status Policy Ingest',
    ingest_policy => { allowed_statuses => ['live'] },
);
ok(!$live->ingest_authorized(channel_id => $status_policy_channel->{id}, stream_key => $status_policy_channel->{stream_key}), 'Live Streaming direct ingest auth rejects disallowed channel statuses');
my $status_policy_worker_ok = eval {
    $live->worker_ingest_auth(channel_id => $status_policy_channel->{id}, stream_key => $status_policy_channel->{stream_key}, worker_id => 'obs-worker-status-policy');
    1;
};
ok(!$status_policy_worker_ok && $@ =~ /status is not allowed/, 'Live Streaming worker auth rejects channels outside allowed ingest statuses');
my $status_policy_events = $live->worker_events(worker_id => 'obs-worker-status-policy');
ok((grep { $_->{event_type} eq 'auth' && $_->{status} eq 'rejected' && $_->{details}{reason} eq 'channel_status_rejected' } @{$status_policy_events}), 'Live Streaming worker auth records channel-status policy rejections');
my $worker_auth = $live->worker_ingest_auth(channel_slug => $channel->{slug}, stream_key => $rotated_channel->{stream_key});
ok($worker_auth->{authorized} && $worker_auth->{channel}{id} == $channel->{id}, 'Live Streaming worker auth accepts channel slug and stream key');
ok($worker_auth->{worker_event_id}, 'Live Streaming worker auth returns a worker event correlation id');
is($worker_auth->{hls}{served_by}, 'httpd', 'Live Streaming worker auth keeps HLS served by httpd');
like($worker_auth->{log_format}, qr/worker_id channel_id session_id status/, 'Live Streaming worker auth returns the worker log format');
my $query_worker_auth = $live->worker_ingest_auth(name => $channel->{slug} . '?key=' . $rotated_channel->{stream_key}, worker_id => 'obs-worker-query');
ok($query_worker_auth->{authorized} && $query_worker_auth->{channel}{id} == $channel->{id}, 'Live Streaming worker auth accepts OBS query-style stream names');
my $slash_worker_auth = $live->worker_ingest_auth(stream => $channel->{slug} . '/' . $rotated_channel->{stream_key}, worker_id => 'obs-worker-slash');
ok($slash_worker_auth->{authorized} && $slash_worker_auth->{channel}{id} == $channel->{id}, 'Live Streaming worker auth accepts OBS slash-style stream names');
my $token_worker_auth = $live->worker_ingest_auth(channel_slug => $channel->{slug}, name => $rotated_channel->{stream_key}, worker_id => 'obs-worker-token-name');
ok($token_worker_auth->{authorized} && $token_worker_auth->{channel}{id} == $channel->{id}, 'Live Streaming worker auth accepts stream-key-only names when the channel is already scoped');
my $worker_auth_events = $live->worker_events(channel_id => $channel->{id});
ok((grep { $_->{event_type} eq 'auth' && $_->{status} eq 'authorized' } @{$worker_auth_events}), 'Live Streaming worker auth records a worker audit event');
my $bad_worker_auth_ok = eval {
    $live->worker_ingest_auth(channel_slug => $channel->{slug}, stream_key => 'wrong key');
    1;
};
ok(!$bad_worker_auth_ok && $@ =~ /stream key/, 'Live Streaming worker auth rejects wrong stream keys');
my $rejected_worker_auth_events = $live->worker_events(channel_id => $channel->{id});
ok((grep { $_->{event_type} eq 'auth' && $_->{status} eq 'rejected' && $_->{message} =~ /stream key/ } @{$rejected_worker_auth_events}), 'Live Streaming worker auth records rejected stream-key attempts');
my $unknown_worker_auth_ok = eval {
    $live->worker_ingest_auth(channel_slug => 'missing-v3-stream', stream_key => 'wrong key', worker_id => 'obs-worker-probe');
    1;
};
ok(!$unknown_worker_auth_ok && $@ =~ /live channel/, 'Live Streaming worker auth rejects unknown channel probes');
my $unknown_worker_auth_events = $live->worker_events(worker_id => 'obs-worker-probe');
ok((grep { $_->{event_type} eq 'auth' && $_->{status} eq 'rejected' && $_->{details}{reason} eq 'channel_lookup_failed' } @{$unknown_worker_auth_events}), 'Live Streaming worker auth records unknown channel probes');
my $stream_session = $live->save_session(
    channel_id => $channel->{id},
    title      => 'Launch test',
);
is($stream_session->{status}, 'scheduled', 'Live Streaming module schedules sessions');
my $due_stream_session = $live->save_session(
    channel_id    => $channel->{id},
    title         => 'Due v3 launch stream',
    status        => 'scheduled',
    scheduled_at  => time - 60,
);
my $future_stream_session = $live->save_session(
    channel_id    => $channel->{id},
    title         => 'Future v3 launch stream',
    status        => 'scheduled',
    scheduled_at  => time + 3600,
);
my $due_sessions = $live->due_scheduled_sessions(now => time);
ok((grep { $_->{id} == $due_stream_session->{id} } @{$due_sessions}), 'Live Streaming module lists scheduled sessions that are due now');
ok(!(grep { $_->{id} == $future_stream_session->{id} } @{$due_sessions}), 'Live Streaming module excludes future sessions from due-now lists');
my $due_notified = $live->emit_schedule_due_notifications(now => time);
ok((grep { $_->{id} == $due_stream_session->{id} && $_->{ingest_detail}{schedule_due_notified_at} } @{$due_notified}), 'Live Streaming module marks due scheduled sessions after notification');
is(scalar(@{ $live->emit_schedule_due_notifications(now => time) }), 0, 'Live Streaming module suppresses duplicate scheduled-stream due notifications');
my $missing_lifecycle_actor_ok = eval {
    $live->set_session_status(id => $stream_session->{id}, status => 'live');
    1;
};
ok(!$missing_lifecycle_actor_ok && $@ =~ /moderator account or active admin user/, 'Live Streaming module rejects actorless session lifecycle changes');
$stream_session = $live->set_session_status(id => $stream_session->{id}, status => 'live', admin_user_id => $admin_user_id);
is($stream_session->{status}, 'live', 'Live Streaming module starts sessions');
my $worker_runtime = $live->record_worker_ingest_heartbeat(
    channel_id       => $channel->{id},
    stream_key       => $rotated_channel->{stream_key},
    session_id       => $stream_session->{id},
    worker_id        => 'obs-worker-api',
    status           => 'live',
    hls_output_path  => '/streams/v3-launch-stream/index.m3u8',
    viewer_count     => 8,
    message          => 'worker heartbeat',
);
ok($worker_runtime->{authorized} && $worker_runtime->{session}{id} == $stream_session->{id}, 'Live Streaming worker heartbeat authenticates and updates a session');
ok($worker_runtime->{session}{worker_event_id}, 'Live Streaming worker heartbeat returns a worker event correlation id');
is($worker_runtime->{hls}{output_path}, '/streams/v3-launch-stream/index.m3u8', 'Live Streaming worker heartbeat returns validated HLS output path');
my $obs_worker_runtime = $live->record_worker_ingest_heartbeat(
    name             => $channel->{slug} . ':' . $rotated_channel->{stream_key},
    worker_id        => 'obs-worker-colon',
    status           => 'live',
    hls_output_path  => '/streams/v3-launch-stream/index.m3u8',
    viewer_count     => 9,
    message          => 'colon stream name heartbeat',
);
ok($obs_worker_runtime->{authorized} && $obs_worker_runtime->{session}{id} == $stream_session->{id}, 'Live Streaming worker heartbeat accepts OBS colon-style stream names');
my $ingest_worker_events = $live->worker_events(session_id => $stream_session->{id});
ok((grep { $_->{event_type} eq 'heartbeat' && $_->{worker_id} eq 'obs-worker-api' && $_->{log_line} =~ /worker heartbeat/ } @{$ingest_worker_events}), 'Live Streaming worker heartbeat persists a structured worker event');
$stream_session = $live->record_worker_heartbeat(
    session_id       => $stream_session->{id},
    worker_id        => 'obs-worker-1',
    status           => 'live',
    hls_output_path  => '/streams/v3-launch-stream/index.m3u8',
    viewer_count     => 12,
);
is($stream_session->{worker_id}, 'obs-worker-1', 'Live Streaming module records worker heartbeat identity');
is($stream_session->{viewer_peak}, 12, 'Live Streaming module tracks HLS session viewer peak');
is($stream_session->{hls_output_path}, '/streams/v3-launch-stream/index.m3u8', 'Live Streaming module records validated HLS output path');
my $session_worker_events = $live->worker_events(session_id => $stream_session->{id}, limit => 5);
ok((grep { $_->{event_type} eq 'heartbeat' && $_->{worker_id} eq 'obs-worker-1' && $_->{viewer_count} == 12 } @{$session_worker_events}), 'Live Streaming direct worker heartbeat persists a worker event');
ok($stream_session->{ingest_detail}{last_heartbeat}{worker_event_id}, 'Live Streaming session detail references the latest worker event id');
my $bad_hls_ok = eval {
    $live->record_worker_heartbeat(
        session_id      => $stream_session->{id},
        worker_id       => 'obs-worker-1',
        status          => 'live',
        hls_output_path => 'https://evil.example.test/index.m3u8',
    );
    1;
};
ok(!$bad_hls_ok && $@ =~ /HLS path/, 'Live Streaming module rejects unsafe HLS worker output paths');
my $auto_channel = $live->create_channel(
    title       => 'Worker Auto Session',
    description => 'Worker-created runtime session.',
);
my $auto_worker_runtime = $live->record_worker_ingest_heartbeat(
    channel_slug     => $auto_channel->{slug},
    stream_key       => $auto_channel->{stream_key},
    worker_id        => 'obs-worker-auto',
    status           => 'live',
    hls_output_path  => '/streams/worker-auto-session/index.m3u8',
    viewer_count     => 3,
);
ok($auto_worker_runtime->{session}{id}, 'Live Streaming worker heartbeat creates a session when none is scheduled');
is($auto_worker_runtime->{session}{status}, 'live', 'Live Streaming worker heartbeat starts an auto-created session');
my $terminal_channel = $live->create_channel(
    title       => 'Terminal Worker Session',
    description => 'Worker heartbeat terminal-session guard.',
);
my $terminal_session = $live->save_session(
    channel_id => $terminal_channel->{id},
    title      => 'Ended worker session',
);
$terminal_session = $live->set_session_status(id => $terminal_session->{id}, status => 'ended', admin_user_id => $admin_user_id);
my $terminal_worker_ok = eval {
    $live->record_worker_ingest_heartbeat(
        channel_id       => $terminal_channel->{id},
        stream_key       => $terminal_channel->{stream_key},
        session_id       => $terminal_session->{id},
        worker_id        => 'obs-worker-terminal',
        status           => 'live',
        hls_output_path  => '/streams/terminal-worker-session/index.m3u8',
    );
    1;
};
ok(!$terminal_worker_ok && $@ =~ /terminal/, 'Live Streaming worker heartbeat rejects terminal sessions');
my $terminal_worker_events = $live->worker_events(worker_id => 'obs-worker-terminal');
ok((grep { $_->{event_type} eq 'auth' && $_->{status} eq 'rejected' && $_->{details}{reason} eq 'session_lookup_failed' } @{$terminal_worker_events}), 'Live Streaming worker auth records terminal-session rejections');
is($live->session_by_id($terminal_session->{id})->{status}, 'ended', 'Live Streaming worker heartbeat does not reopen terminal sessions');
my $worker_health = $live->worker_health;
ok($worker_health->{channels} >= 2 && $worker_health->{contract}{health}{path} eq '/live/worker/health', 'Live Streaming worker health reports channel state and the routed health endpoint');
ok($worker_health->{worker_events}{heartbeat_events} >= 2, 'Live Streaming worker health reports recent worker heartbeat telemetry');
ok($worker_health->{worker_events}{auth_rejected} >= 2, 'Live Streaming worker health reports recent rejected worker auth attempts');
ok($worker_health->{worker_events}{latest_event_id}, 'Live Streaming worker health exposes the latest worker event id');
my $presence_sse = DesertCMS::Realtime->sse_event($live->presence_event($stream_session));
like($presence_sse, qr/event: stream\.presence/, 'Live Streaming module emits stream presence realtime events');
my $chat = $live->add_chat_message(
    session_id   => $stream_session->{id},
    account_id   => $community_account->{id},
    display_name => 'Community',
    body         => 'Live chat uses unified accounts.',
);
ok($chat->{id}, 'Live Streaming module stores live chat messages');
my $chat_sse = DesertCMS::Realtime->sse_event($live->chat_event($chat));
like($chat_sse, qr/event: live\.chat/, 'Live Streaming module emits live chat realtime events');
my @author_delete_events;
my $author_deleted_chat = $live->delete_own_chat_message(
    id                => $chat->{id},
    account_id        => $community_account->{id},
    channel_id        => $channel->{id},
    realtime_publish  => sub { push @author_delete_events, $_[0]; return 1; },
);
is($author_deleted_chat->{status}, 'deleted', 'Live Streaming module lets chat authors soft-delete their own messages');
is($author_delete_events[0]{data}{body}, '', 'Live Streaming author delete realtime events redact deleted chat body');
ok(!(grep { $_->{id} == $author_deleted_chat->{id} } @{ $live->chat_messages($stream_session->{id}) }), 'Live Streaming public chat history excludes author-deleted messages');
my $ip_chat = $live->add_chat_message(
    session_id   => $stream_session->{id},
    account_id   => $community_account->{id},
    display_name => 'Community',
    body         => 'Live chat stores IP context for moderation.',
    ip_address   => '198.51.100.150',
);
is($ip_chat->{ip_address}, '198.51.100.150', 'Live Streaming module stores chat IP context for abuse controls');
my ($public_ip_chat) = grep { $_->{id} == $ip_chat->{id} } @{ $live->chat_messages($stream_session->{id}) };
ok($public_ip_chat && !exists $public_ip_chat->{ip_address}, 'Live Streaming public chat history does not expose chat IP context');
my ($moderator_ip_chat) = grep { $_->{id} == $ip_chat->{id} } @{ $live->chat_messages($stream_session->{id}, include_hidden => 1) };
is($moderator_ip_chat->{ip_address}, '198.51.100.150', 'Live Streaming moderator chat history keeps chat IP context for review');
my $wrong_author_delete_ok = eval {
    $live->delete_own_chat_message(id => $ip_chat->{id}, account_id => $oauth_result->{account}{id}, channel_id => $channel->{id});
    1;
};
ok(!$wrong_author_delete_ok && $@ =~ /belongs to another account/, 'Live Streaming author delete rejects other account messages');
my $wrong_channel_delete_ok = eval {
    $live->delete_own_chat_message(id => $ip_chat->{id}, account_id => $community_account->{id}, channel_id => $policy_disabled_channel->{id});
    1;
};
ok(!$wrong_channel_delete_ok && $@ =~ /does not belong to this channel/, 'Live Streaming author delete rejects cross-channel message ids');
$config->{live_chat_rate_window_seconds} = 600;
$config->{live_chat_max_messages_per_ip_window} = 1;
my $chat_ip_limited_ok = eval {
    $live->add_chat_message(
        session_id   => $stream_session->{id},
        account_id   => $oauth_result->{account}{id},
        display_name => 'OAuth User',
        body         => 'Second live chat from a limited IP.',
        ip_address   => '198.51.100.150',
    );
    1;
};
ok(!$chat_ip_limited_ok && $@ =~ /live chat ip rate limit/, 'Live Streaming module enforces per-IP chat rate limits');
$config->{live_chat_max_messages_per_ip_window} = 30;
my $disabled_chat_account = $accounts->create_account(
    email        => 'disabled-chat@example.test',
    username     => 'disabled-chat',
    display_name => 'Disabled Chat',
    password     => 'correct horse battery staple',
);
my $disabled_account_chat = $live->add_chat_message(
    session_id   => $stream_session->{id},
    account_id   => $disabled_chat_account->{id},
    display_name => 'Disabled Chat',
    body         => 'This live chat message should disappear if the account is disabled.',
);
my $disabled_account_presence = $live->update_chat_presence(
    session_id   => $stream_session->{id},
    account_id   => $disabled_chat_account->{id},
    display_name => 'Disabled Chat',
);
$accounts->set_status(id => $disabled_chat_account->{id}, status => 'disabled', moderation_note => 'live chat visibility test', admin_user_id => $admin_user_id);
ok(!(grep { $_->{id} == $disabled_account_chat->{id} } @{ $live->chat_messages($stream_session->{id}) }), 'Live Streaming public chat history hides messages from disabled accounts');
ok((grep { $_->{id} == $disabled_account_chat->{id} } @{ $live->chat_messages($stream_session->{id}, include_hidden => 1) }), 'Live Streaming moderator chat history keeps disabled-account messages available for review');
ok(!(grep { $_->{id} == $disabled_account_presence->{id} } @{ $live->chat_presence($stream_session->{id}) }), 'Live Streaming public chat presence hides disabled accounts');
ok((grep { $_->{id} == $disabled_account_presence->{id} } @{ $live->chat_presence($stream_session->{id}, include_inactive => 1) }), 'Live Streaming moderator chat presence can include disabled accounts for review');
my @presence_events;
my $chat_presence = $live->update_chat_presence(
    session_id        => $stream_session->{id},
    account_id        => $community_account->{id},
    display_name      => 'Community',
    realtime_publish  => sub { push @presence_events, $_[0]; return 1; },
);
ok($chat_presence->{id}, 'Live Streaming module records live chat presence');
is($chat_presence->{realtime_delivery}, 'delivered', 'Live Streaming module can fan out live chat presence updates');
is($presence_events[0]{type}, 'live.presence', 'Live Streaming module emits live presence event payloads');
my $presence_sse_payload = DesertCMS::Realtime->sse_event($live->live_presence_event($chat_presence));
like($presence_sse_payload, qr/event: live\.presence/, 'Realtime service serializes live presence events');
ok(@{ $live->chat_presence($stream_session->{id}) } >= 1, 'Live Streaming module lists active chat presence');
$chat_presence = $live->update_chat_presence(
    session_id   => $stream_session->{id},
    account_id   => $community_account->{id},
    display_name => 'Community',
    status       => 'idle',
);
is($chat_presence->{status}, 'idle', 'Live Streaming module updates chat presence state');
$config->{live_chat_account_only} = 1;
my $guest_presence_ok = eval {
    $live->update_chat_presence(
        session_id    => $stream_session->{id},
        client_id     => 'guest-presence',
        display_name  => 'Guest',
    );
    1;
};
ok(!$guest_presence_ok && $@ =~ /presence requires an active account/, 'Live Streaming module enforces account-only chat presence');
my $guest_chat_ok = eval {
    $live->add_chat_message(
        session_id    => $stream_session->{id},
        display_name  => 'Guest',
        body          => 'Guest chat should be blocked when account-only mode is active.',
    );
    1;
};
ok(!$guest_chat_ok && $@ =~ /requires an active account/, 'Live Streaming module enforces account-only live chat');
$config->{live_chat_account_only} = 0;
is($live->leave_chat_presence(session_id => $stream_session->{id}, account_id => $community_account->{id})->{status}, 'left', 'Live Streaming module records chat presence leaves');
ok(!(grep { $_->{account_id} && $_->{account_id} == $community_account->{id} } @{ $live->chat_presence($stream_session->{id}) }), 'Live Streaming module excludes left chat presence from active lists');
$config->{live_chat_slow_mode_seconds} = 60;
my $slow_chat_ok = eval {
    $live->add_chat_message(
        session_id   => $stream_session->{id},
        account_id   => $community_account->{id},
        display_name => 'Community',
        body         => 'Second chat message too quickly.',
    );
    1;
};
ok(!$slow_chat_ok && $@ =~ /slow mode/, 'Live Streaming module enforces chat slow-mode');
$config->{live_chat_slow_mode_seconds} = 0;
my $moderated_chat = $live->add_chat_message(
    session_id   => $stream_session->{id},
    account_id   => $oauth_result->{account}{id},
    display_name => 'OAuth User',
    body         => 'This chat message can be hidden by moderators.',
);
my $missing_live_actor_ok = eval {
    $live->hide_chat_message(id => $moderated_chat->{id});
    1;
};
ok(!$missing_live_actor_ok && $@ =~ /moderator account or active admin user/, 'Live Streaming module rejects actorless chat moderation');
my $non_moderator_live_ok = eval {
    $live->hide_chat_message(id => $moderated_chat->{id}, moderator_account_id => $community_account->{id});
    1;
};
ok(!$non_moderator_live_ok && $@ =~ /live chat moderator permission/, 'Live Streaming module rejects chat moderation from regular accounts');
my @chat_moderation_events;
my $hidden_chat = $live->hide_chat_message(
    id                   => $moderated_chat->{id},
    moderator_account_id => $forum_moderator->{id},
    moderator_note       => 'Off-topic live chat',
    realtime_publish     => sub { push @chat_moderation_events, $_[0]; return 1; },
);
is($hidden_chat->{status}, 'hidden', 'Live Streaming module hides chat messages');
is($chat_moderation_events[0]{data}{body}, '', 'Live Streaming moderation realtime events redact hidden chat body');
ok(!(grep { $_->{id} == $hidden_chat->{id} } @{ $live->chat_messages($stream_session->{id}) }), 'Live Streaming module hides moderated chat from public chat lists');
my $hidden_chat_report_ok = eval {
    $live->report_chat_message(message_id => $hidden_chat->{id}, reporter_account_id => $community_account->{id}, reason => 'Hidden chat should not be reportable publicly.');
    1;
};
ok(!$hidden_chat_report_ok && $@ =~ /chat message is not visible/, 'Live Streaming module blocks public reports against hidden chat messages');
my $deleted_chat = $live->add_chat_message(
    session_id   => $stream_session->{id},
    account_id   => $oauth_result->{account}{id},
    display_name => 'OAuth User',
    body         => 'This chat message can be deleted by moderators.',
);
is($live->delete_chat_message(id => $deleted_chat->{id}, moderator_account_id => $forum_moderator->{id})->{status}, 'deleted', 'Live Streaming module soft-deletes chat messages');
my $blocked_term = $live->save_blocked_term(term => 'spoiler', action => 'report');
is($blocked_term->{action}, 'report', 'Live Streaming module stores blocked chat terms');
my $reported_chat = $live->add_chat_message(
    session_id   => $stream_session->{id},
    account_id   => $community_account->{id},
    display_name => 'Community',
    body         => 'This spoiler should enter moderation.',
);
is($reported_chat->{status}, 'reported', 'Live Streaming module marks blocked chat messages for moderation');
ok(@{ $live->chat_reports(status => 'open') } >= 1, 'Live Streaming module lists open chat moderation reports');
my $hidden_blocked_term = $live->save_blocked_term(term => 'backstage-only', action => 'hide');
is($hidden_blocked_term->{action}, 'hide', 'Live Streaming module stores auto-hide blocked chat terms');
my $hidden_blocked_chat = $live->add_chat_message(
    session_id   => $stream_session->{id},
    account_id   => $oauth_result->{account}{id},
    display_name => 'OAuth User',
    body         => 'This backstage-only note should be hidden and queued.',
);
is($hidden_blocked_chat->{status}, 'hidden', 'Live Streaming module hides auto-hide blocked chat messages');
ok($hidden_blocked_chat->{moderation_report}{id}, 'Live Streaming module queues auto-hide blocked chat matches for moderation');
my ($hidden_blocked_report) = grep { $_->{id} == $hidden_blocked_chat->{moderation_report}{id} } @{ $live->chat_reports(status => 'open') };
ok($hidden_blocked_report && ($hidden_blocked_report->{message_status} || '') eq 'hidden', 'Live Streaming blocked-term reports preserve hidden message status');
ok(!(grep { $_->{id} == $hidden_blocked_chat->{id} } @{ $live->chat_messages($stream_session->{id}) }), 'Live Streaming public chat history excludes auto-hidden blocked-term messages');
my $duplicate_chat_report_ok = eval {
    $live->report_chat_message(message_id => $reported_chat->{id}, reporter_account_id => $community_account->{id}, reason => 'Report this chat again');
    1;
};
ok(!$duplicate_chat_report_ok && $@ =~ /duplicate live chat report/, 'Live Streaming module suppresses duplicate open chat reports from the same account');
is($live->set_chat_report_status(id => $reported_chat->{moderation_report}{id}, status => 'actioned', moderator_account_id => $forum_moderator->{id}, moderator_note => 'Handled')->{status}, 'actioned', 'Live Streaming module resolves chat moderation reports');
ok($live->revoke_stream_key($channel->{id}), 'Live Streaming module revokes stream keys');
ok(!$live->verify_stream_key($channel->{id}, $rotated_channel->{stream_key}), 'Live Streaming module rejects revoked stream keys');
my $revoked_worker_auth_ok = eval {
    $live->worker_ingest_auth(channel_slug => $channel->{slug}, stream_key => $rotated_channel->{stream_key}, worker_id => 'obs-worker-revoked-key');
    1;
};
ok(!$revoked_worker_auth_ok && $@ =~ /revoked/, 'Live Streaming worker auth rejects revoked stream keys distinctly');
my $revoked_worker_auth_events = $live->worker_events(worker_id => 'obs-worker-revoked-key');
ok((grep { $_->{event_type} eq 'auth' && $_->{status} eq 'rejected' && $_->{details}{reason} eq 'stream_key_revoked' } @{$revoked_worker_auth_events}), 'Live Streaming worker auth records revoked stream-key attempts');
my $missing_revoke_ok = eval {
    $live->revoke_stream_key(999_999);
    1;
};
ok(!$missing_revoke_ok && $@ =~ /live channel was not found/, 'Live Streaming module rejects missing-channel stream key revocation');
my $stream_notices = $notifications->list(module_key => 'live_streaming', limit => 100);
ok((grep { $_->{topic} eq 'stream.started' } @{$stream_notices}), 'Live Streaming module emits stream lifecycle notifications');
ok((grep { $_->{topic} eq 'stream.started' && int($_->{actor_user_id} || 0) == $admin_user_id } @{$stream_notices}), 'Live Streaming lifecycle notifications carry admin actor context');
ok((grep { $_->{topic} eq 'stream.schedule_due' } @{$stream_notices}), 'Live Streaming module emits scheduled-stream due notifications');
ok((grep { $_->{topic} eq 'stream.chat_reported' } @{$stream_notices}), 'Live Streaming module emits chat report notifications');
ok((grep { $_->{topic} eq 'stream.chat_moderated' } @{$stream_notices}), 'Live Streaming module emits chat moderation notifications');

ok($notifications->topic_registered('security.check_failed'), 'notification bus validates topics from module manifests');
ok($notifications->module_topic_registered('security_center', 'security.check_failed'), 'notification bus validates module-owned topics from manifests');
my $cross_module_notice_ok = eval {
    $notifications->emit(
        audience   => 'admin',
        severity   => 'warning',
        topic      => 'security.check_failed',
        module_key => 'social',
        title      => 'cross module topic',
        body       => 'A module cannot emit another module manifest topic.',
    );
    1;
};
ok(!$cross_module_notice_ok && $@ =~ /not registered for the module manifest/, 'notification bus rejects module/topic ownership mismatches');
my $admin_unread_before_security_notice = $notifications->unread_count(audience => 'admin');
my $notice = $notifications->emit(
    audience   => 'admin',
    severity   => 'warning',
    topic      => 'security.check_failed',
    module_key => 'security_center',
    title      => 'pf check needs review',
    body       => 'pfctl was not found in the local development environment.',
    url        => '/admin/settings/security',
);
ok($notice->{id}, 'notification emit returns inserted row');
my $notice_deliveries = $notifications->deliveries(notification_id => $notice->{id});
ok((grep { $_->{delivery_channel} eq 'in_app' && $_->{status} eq 'delivered' } @{$notice_deliveries}), 'notification bus records in-app delivery state');
my ($social_actor_notice) = grep { $_->{topic} eq 'social.follow' } @{$social_notices};
is($social_actor_notice->{actor_account_id}, $oauth_result->{account}{id}, 'notification bus stores public actor account context');
my $unscoped_user_notice_ok = eval {
    $notifications->emit(
        audience         => 'user',
        severity         => 'info',
        topic            => 'social.follow',
        module_key       => 'social',
        title            => 'unscoped user notification',
        body             => 'This should not be allowed without an account recipient.',
        actor_account_id => $oauth_result->{account}{id},
    );
    1;
};
ok(!$unscoped_user_notice_ok && $@ =~ /recipient account is required/, 'notification bus rejects unscoped public account notifications');
my $disabled_recipient_notice_ok = eval {
    $notifications->emit(
        audience             => 'user',
        severity             => 'info',
        topic                => 'social.follow',
        module_key           => 'social',
        title                => 'disabled recipient notification',
        body                 => 'This should not be delivered to a disabled account.',
        actor_account_id     => $oauth_result->{account}{id},
        recipient_account_id => $disabled_social_account->{id},
    );
    1;
};
ok(!$disabled_recipient_notice_ok && $@ =~ /recipient account is not active/, 'notification bus rejects disabled public account recipients');
my $community_inbox = $notifications->inbox_for_account($community_account->{id}, topic => 'social.follow');
ok((grep { $_->{id} == $social_actor_notice->{id} } @{$community_inbox}), 'notification bus exposes account-scoped public inboxes');
my $community_unread_before_mark = $notifications->unread_count(audience => 'user', recipient_account_id => $community_account->{id});
ok($community_unread_before_mark >= scalar(@{$community_inbox}), 'notification unread count can be scoped to a public account');
is($notifications->mark_read(id => $social_actor_notice->{id}, audience => 'user', recipient_account_id => $oauth_result->{account}{id}), 0, 'notification mark_read refuses the wrong account recipient');
is($notifications->mark_read(id => $social_actor_notice->{id}, audience => 'user', recipient_account_id => $community_account->{id}), 1, 'notification mark_read accepts the intended account recipient');
is($notifications->unread_count(audience => 'user', recipient_account_id => $community_account->{id}), $community_unread_before_mark - 1, 'account-scoped unread count updates after mark_read');
my $unscoped_mark_read_ok = eval {
    $notifications->mark_read(id => $notice->{id});
    1;
};
ok(!$unscoped_mark_read_ok && $@ =~ /mark_read audience is required/, 'notification mark_read rejects id-only updates without an audience scope');
my $unscoped_user_list_ok = eval {
    $notifications->list(audience => 'user');
    1;
};
ok(!$unscoped_user_list_ok && $@ =~ /recipient account is required/, 'notification list rejects unscoped public account inbox reads');
my $unscoped_user_unread_count_ok = eval {
    $notifications->unread_count(audience => 'user');
    1;
};
ok(!$unscoped_user_unread_count_ok && $@ =~ /recipient account is required/, 'notification unread_count rejects unscoped public account inbox counts');
my $unscoped_user_preference_ok = eval {
    $notifications->set_preference(audience => 'user', topic => 'social.follow', delivery_channel => 'in_app', enabled => 0);
    1;
};
ok(!$unscoped_user_preference_ok && $@ =~ /recipient account is required/, 'notification preferences reject unscoped public account preferences');
my $disabled_user_preference_ok = eval {
    $notifications->set_preference(audience => 'user', recipient_account_id => $disabled_social_account->{id}, topic => 'social.follow', delivery_channel => 'in_app', enabled => 0);
    1;
};
ok(!$disabled_user_preference_ok && $@ =~ /recipient account is not active/, 'notification preferences reject disabled public account recipients');
ok($notifications->set_preference(audience => 'user', recipient_account_id => $community_account->{id}, topic => 'social.follow', delivery_channel => 'in_app', enabled => 0), 'notification preferences can target a public account inbox');
my $muted_account_notice = $notifications->emit(
    audience             => 'user',
    severity             => 'info',
    topic                => 'social.follow',
    module_key           => 'social',
    title                => 'muted account follow',
    body                 => 'This account-scoped event is muted.',
    actor_account_id     => $oauth_result->{account}{id},
    recipient_account_id => $community_account->{id},
    entity_type          => 'social_profile',
    entity_id            => $community_account->{id},
);
is($muted_account_notice->{status}, 'archived', 'account-scoped notification preferences filter inbox delivery');
ok((grep { $_->{delivery_channel} eq 'in_app' && $_->{status} eq 'skipped' } @{ $muted_account_notice->{deliveries} }), 'muted account notification records skipped delivery');
my $default_muted_account_inbox = $notifications->inbox_for_account($community_account->{id}, topic => 'social.follow');
ok(!(grep { $_->{id} == $muted_account_notice->{id} } @{$default_muted_account_inbox}), 'account inbox hides archived preference-muted notifications by default');
my $archived_muted_account_inbox = $notifications->inbox_for_account($community_account->{id}, topic => 'social.follow', include_archived => 1);
ok((grep { $_->{id} == $muted_account_notice->{id} } @{$archived_muted_account_inbox}), 'account inbox can include archived notifications for review');
$notifications->set_preference(audience => 'user', recipient_account_id => $community_account->{id}, topic => 'social.follow', delivery_channel => 'in_app', enabled => 1);
is($notifications->unread_count(audience => 'admin'), $admin_unread_before_security_notice + 1, 'notification unread count tracks inserted row');
is($notifications->mark_read(id => $notice->{id}, audience => 'admin'), 1, 'notification can be marked read with an admin audience scope');
is($notifications->unread_count(audience => 'admin'), $admin_unread_before_security_notice, 'mark_read clears unread count for the selected notice');
ok($notifications->set_preference(audience => 'admin', topic => 'security.check_failed', delivery_channel => 'in_app', enabled => 0), 'notification preferences persist per topic and channel');
my $muted_notice = $notifications->emit(
    audience   => 'admin',
    severity   => 'warning',
    topic      => 'security.check_failed',
    module_key => 'security_center',
    title      => 'muted pf check',
    body       => 'This event is muted for the admin inbox.',
    url        => '/admin/settings/security',
);
is($muted_notice->{status}, 'archived', 'notification preferences filter inbox delivery');
ok((grep { $_->{delivery_channel} eq 'in_app' && $_->{status} eq 'skipped' } @{ $muted_notice->{deliveries} }), 'muted notification records skipped delivery');
my $default_admin_inbox = $notifications->list(audience => 'admin', topic => 'security.check_failed');
ok(!(grep { $_->{id} == $muted_notice->{id} } @{$default_admin_inbox}), 'admin inbox hides archived preference-muted notifications by default');
my $archived_admin_inbox = $notifications->list(audience => 'admin', topic => 'security.check_failed', include_archived => 1);
ok((grep { $_->{id} == $muted_notice->{id} } @{$archived_admin_inbox}), 'admin inbox can include archived notifications for review');
$notifications->set_preference(audience => 'admin', topic => 'security.check_failed', delivery_channel => 'in_app', enabled => 1);
$config->{realtime_enabled} = 1;
my @realtime_events;
my $realtime_notice = $notifications->emit(
    audience          => 'admin',
    severity          => 'critical',
    topic             => 'security.check_failed',
    module_key        => 'security_center',
    title             => 'realtime pf check',
    body              => 'Realtime adapter should receive this event.',
    details           => { check_key => 'pf', status => 'critical' },
    delivery_channels => [qw(in_app realtime)],
    realtime_adapter  => sub { push @realtime_events, $_[0]; return 1; },
);
is($realtime_events[0]{type}, 'admin.notification', 'notification bus publishes through realtime adapter');
is($realtime_events[0]{data}{details}{check_key}, 'pf', 'notification bus carries structured details through realtime adapter events');
ok((grep { $_->{delivery_channel} eq 'realtime' && $_->{status} eq 'delivered' } @{ $realtime_notice->{deliveries} }), 'notification bus records realtime delivery success');
my @account_realtime_events;
my $account_realtime_notice = $notifications->emit(
    audience             => 'user',
    severity             => 'info',
    topic                => 'social.follow',
    module_key           => 'social',
    title                => 'realtime account follow',
    body                 => 'Realtime should carry public account context.',
    actor_account_id     => $oauth_result->{account}{id},
    recipient_account_id => $community_account->{id},
    entity_type          => 'social_profile',
    entity_id            => $community_account->{id},
    delivery_channels    => [qw(realtime)],
    realtime_adapter     => sub { push @account_realtime_events, $_[0]; return 1; },
);
is($account_realtime_events[0]{type}, 'user.notification', 'notification bus publishes account notifications through realtime adapter');
is($account_realtime_events[0]{data}{recipient_account_id}, $community_account->{id}, 'realtime account notifications include recipient account context');
ok((grep { $_->{delivery_channel} eq 'realtime' && $_->{status} eq 'delivered' } @{ $account_realtime_notice->{deliveries} }), 'notification bus records account realtime delivery success');
my $failed_realtime = $notifications->emit(
    audience          => 'admin',
    severity          => 'critical',
    topic             => 'security.check_failed',
    module_key        => 'security_center',
    title             => 'failed realtime pf check',
    body              => 'Realtime adapter failure should be recorded.',
    delivery_channels => [qw(realtime)],
    realtime_adapter  => sub { die 'mock realtime failure' },
);
ok((grep { $_->{delivery_channel} eq 'realtime' && $_->{status} eq 'failed' && $_->{last_error} =~ /mock realtime failure/ } @{ $failed_realtime->{deliveries} }), 'notification bus records realtime delivery failure');
my $queued_email_notice = $notifications->emit(
    audience          => 'admin',
    severity          => 'warning',
    topic             => 'security.check_failed',
    module_key        => 'security_center',
    title             => 'queued email pf check',
    body              => 'Email delivery is queued until an adapter is configured.',
    delivery_channels => [qw(email)],
);
ok((grep { $_->{delivery_channel} eq 'email' && $_->{status} eq 'queued' } @{ $queued_email_notice->{deliveries} }), 'notification bus queues optional email adapter delivery');
my $retry_disabled_account = $accounts->create_account(
    email        => 'retry-disabled-recipient@example.test',
    username     => 'retry-disabled-recipient',
    display_name => 'Retry Disabled Recipient',
    password     => 'correct horse battery staple',
);
my $retry_disabled_notice = $notifications->emit(
    audience             => 'user',
    severity             => 'info',
    topic                => 'social.follow',
    module_key           => 'social',
    title                => 'queued account email follow',
    body                 => 'This queued account notification should not retry after recipient moderation.',
    actor_account_id     => $oauth_result->{account}{id},
    recipient_account_id => $retry_disabled_account->{id},
    delivery_channels    => [qw(email)],
);
my ($retry_disabled_delivery) = grep { $_->{delivery_channel} eq 'email' && $_->{status} eq 'queued' } @{ $retry_disabled_notice->{deliveries} };
ok($retry_disabled_delivery, 'notification bus queues account-scoped adapter delivery while recipient is active');
$accounts->set_status(id => $retry_disabled_account->{id}, status => 'disabled', moderation_note => 'notification retry test', admin_user_id => $admin_user_id);
my $retryable_deliveries = $notifications->retryable_deliveries(now => time + 600);
ok((grep { $_->{notification_id} == $failed_realtime->{id} && $_->{delivery_channel} eq 'realtime' } @{$retryable_deliveries}), 'notification bus exposes failed realtime deliveries for retry');
ok((grep { $_->{notification_id} == $queued_email_notice->{id} && $_->{delivery_channel} eq 'email' } @{$retryable_deliveries}), 'notification bus exposes queued adapter deliveries for retry');
ok((grep { $_->{notification_id} == $retry_disabled_notice->{id} && $_->{delivery_channel} eq 'email' } @{$retryable_deliveries}), 'notification bus exposes queued account adapter deliveries before retry moderation checks');
my @email_payloads;
$notifications->set_adapter(email => sub { push @email_payloads, $_[0]; return { provider => 'mock-email', accepted => 1 }; });
my $delivered_email_notice = $notifications->emit(
    audience          => 'admin',
    severity          => 'warning',
    topic             => 'security.check_failed',
    module_key        => 'security_center',
    title             => 'delivered email pf check',
    body              => 'Configured email adapter should receive this event.',
    delivery_channels => [qw(email)],
);
is($email_payloads[0]{topic}, 'security.check_failed', 'notification bus sends configured email adapter payloads');
ok((grep { $_->{delivery_channel} eq 'email' && $_->{status} eq 'delivered' } @{ $delivered_email_notice->{deliveries} }), 'notification bus records configured email adapter delivery success');
my $email_payloads_before_disabled_retry = scalar @email_payloads;
my $skipped_disabled_retry = $notifications->retry_delivery(delivery_id => $retry_disabled_delivery->{id});
is($skipped_disabled_retry->{status}, 'skipped', 'notification retry skips disabled public account recipients');
like($skipped_disabled_retry->{last_error}, qr/recipient account is not active/, 'notification retry records disabled recipient skip reason');
is(scalar @email_payloads, $email_payloads_before_disabled_retry, 'notification retry does not call adapters for disabled public account recipients');
my ($queued_email_delivery) = grep { $_->{delivery_channel} eq 'email' && $_->{status} eq 'queued' } @{ $queued_email_notice->{deliveries} };
my $retried_email_delivery = $notifications->retry_delivery(delivery_id => $queued_email_delivery->{id});
is($retried_email_delivery->{id}, $queued_email_delivery->{id}, 'notification retry updates the original queued email delivery row');
is($retried_email_delivery->{status}, 'delivered', 'notification retry delivers queued email through the configured adapter');
my ($failed_realtime_delivery) = grep { $_->{delivery_channel} eq 'realtime' && $_->{status} eq 'failed' } @{ $failed_realtime->{deliveries} };
my @retried_realtime_events;
my $retried_realtime_delivery = $notifications->retry_delivery(
    delivery_id       => $failed_realtime_delivery->{id},
    realtime_adapter  => sub { push @retried_realtime_events, $_[0]; return 1; },
);
is($retried_realtime_delivery->{id}, $failed_realtime_delivery->{id}, 'notification retry updates the original failed realtime delivery row');
is($retried_realtime_delivery->{status}, 'delivered', 'notification retry delivers failed realtime through the adapter');
is($retried_realtime_events[0]{type}, 'admin.notification', 'notification retry rebuilds realtime event payloads');
my $retryable_after_delivery = $notifications->retryable_deliveries(now => time + 600);
ok(!(grep { $_->{id} == $queued_email_delivery->{id} || $_->{id} == $failed_realtime_delivery->{id} } @{$retryable_after_delivery}), 'notification retry removes delivered rows from retryable delivery lists');
$notifications->set_adapter(email => undef);
my $due_email_notice = $notifications->emit(
    audience          => 'admin',
    severity          => 'warning',
    topic             => 'security.check_failed',
    module_key        => 'security_center',
    title             => 'due email pf check',
    body              => 'Batch retry should deliver this queued email.',
    delivery_channels => [qw(email)],
);
my ($due_email_delivery) = grep { $_->{delivery_channel} eq 'email' && $_->{status} eq 'queued' } @{ $due_email_notice->{deliveries} };
$notifications->set_adapter(email => sub { return { provider => 'mock-email-batch', accepted => 1 }; });
my $batch_retry_results = $notifications->retry_due_deliveries(now => time + 600, limit => 10);
ok((grep { $_->{id} == $due_email_delivery->{id} && $_->{status} eq 'delivered' } @{$batch_retry_results}), 'notification bus retries due queued adapter deliveries in batches');
$notifications->set_adapter(email => undef);
my $throwing_retry_notice = $notifications->emit(
    audience          => 'admin',
    severity          => 'warning',
    topic             => 'security.check_failed',
    module_key        => 'security_center',
    title             => 'throwing retry pf check',
    body              => 'Batch retry should persist unexpected retry failures.',
    delivery_channels => [qw(email)],
);
my ($throwing_retry_delivery) = grep { $_->{delivery_channel} eq 'email' && $_->{status} eq 'queued' } @{ $throwing_retry_notice->{deliveries} };
my $throwing_retry_results;
{
    no warnings 'redefine';
    local *DesertCMS::Notifications::retry_delivery = sub { die "mock batch retry explosion\n"; };
    $throwing_retry_results = $notifications->retry_due_deliveries(now => time + 600, limit => 10);
}
ok((grep { $_->{id} == $throwing_retry_delivery->{id} && $_->{status} eq 'failed' && $_->{last_error} =~ /mock batch retry explosion/ } @{$throwing_retry_results}), 'notification bus returns persisted failures from thrown batch retries');
my ($persisted_throwing_retry) = grep { $_->{id} == $throwing_retry_delivery->{id} } @{ $notifications->deliveries(notification_id => $throwing_retry_notice->{id}) };
is($persisted_throwing_retry->{status}, 'failed', 'notification bus persists thrown batch retry failures');
like($persisted_throwing_retry->{last_error}, qr/mock batch retry explosion/, 'notification bus stores thrown batch retry error detail');
ok(int($persisted_throwing_retry->{attempts} || 0) >= 1, 'notification bus increments attempts for thrown batch retry failures');

my $dashboard = DesertCMS::Dashboard->new(config => $config, db => $db);
my %catalog = map { $_->{key} => $_ } @{ $dashboard->widget_catalog };
ok($catalog{security_summary} && $catalog{notifications} && $catalog{module_status}, 'dashboard catalog includes Security Center, notifications, and module widgets');
my $saved_widgets = $dashboard->save_widgets(
    user_id => 0,
    role    => 'owner',
    values  => {
        enabled   => { analytics_overview => 1, security_summary => 1, notifications => 1 },
        sizes     => { security_summary => 'wide' },
        positions => { security_summary => 5, analytics_overview => 10, notifications => 20 },
    },
);
my %saved_widgets = map { $_->{key} => $_ } @{$saved_widgets};
is($saved_widgets{security_summary}{size}, 'wide', 'dashboard widget size preferences persist');
ok(!$saved_widgets{top_ips}{enabled}, 'dashboard widget disable preferences persist');

my $analytics = DesertCMS::Analytics::summary($config, $db, days => 90, daily_days => 45, limit => 3);
is($analytics->{days}, 90, 'analytics summary accepts dashboard time range');
is($analytics->{daily_days}, 45, 'analytics summary accepts dashboard daily range');

my $theme_css = DesertCMS::SiteTheme::css_vars({
    %{$settings},
    theme_background_effect => 'wash',
    theme_motion_effect => 'lift',
    theme_lighting_effect => 'soft',
    theme_box_transparency => 20,
    theme_outline_transparency => 30,
    theme_box_shape => 'round',
    theme_gradient_style => 'accent',
});
like($theme_css, qr/--site-background-overlay:/, 'theme CSS exposes v3 background effect token');
like($theme_css, qr/--site-box-radius: 18px;/, 'theme CSS exposes v3 box shape token');
like($theme_css, qr/--site-gradient-bg:/, 'theme CSS exposes v3 gradient token');

my $security_center = DesertCMS::SecurityCenter->new(config => $config, db => $db);
DesertCMS::Settings::set_many($config, $db, { module_live_streaming_enabled => 1 });
my $checks = $security_center->run_checks;
my %checks = map { $_->{key} => $_ } @{$checks};
for my $check_key (qw(dns tls pf httpd acme_client file_permissions worker_health backups package_updates cve_matching provider_webhooks streaming_ports read_only_default)) {
    ok($checks{$check_key}, "Security Center includes $check_key check");
}
ok($checks{streaming_ports}{details}{worker_events}{auth_rejected} >= 2, 'Security Center streaming check reports recent rejected worker auth telemetry');
like($checks{streaming_ports}{detail}, qr/rejected worker auth/, 'Security Center streaming check summarizes worker auth failures');
my $queued = $security_center->queue_fix(
    check_key           => 'pf',
    action              => 'review_pf_rules',
    approved_by_user_id => undef,
);
is($queued->{status}, 'queued', 'Security Center queues approved remediation instead of mutating host');

my $realtime = DesertCMS::Realtime->manifest;
is($realtime->{runtime}, 'perl', 'realtime service contract stays Perl based');
is_deeply($realtime->{openbsd}{required_base}, [qw(pf httpd acme-client)], 'realtime service keeps OpenBSD base requirements');
ok((grep { $_ eq 'user.notifications' } @{ $realtime->{channels} }), 'realtime service declares account notification channels');
is(
    DesertCMS::Realtime->normalize_public_url('https://realtime.example.test'),
    'https://realtime.example.test/events',
    'realtime service normalizes browser-facing events URLs'
);
is(
    DesertCMS::Realtime->service_status({ realtime_enabled => 1, realtime_public_url => 'https://realtime.example.test/events' })->{websocket_url},
    'wss://realtime.example.test/ws',
    'realtime service derives secure WebSocket URLs from public HTTPS events URLs'
);
like(DesertCMS::Realtime->sse_prelude, qr/retry: 5000/, 'realtime SSE prelude is available');
like(DesertCMS::Realtime->sse_event($realtime_events[0]), qr/event: admin\.notification/, 'realtime formats notification adapter events as SSE');

my $admin_html = DesertCMS::HTTP->html_page(
    title    => 'Admin',
    body     => '<section>Admin</section>',
    user_nav => '<nav id="admin-primary-nav"><a href="/admin">Analytics</a></nav>',
);
like($admin_html, qr/body class="admin-product-mode--master has-admin-nav"/, 'authenticated admin shell marks sidebar layout state');

done_testing;

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}
