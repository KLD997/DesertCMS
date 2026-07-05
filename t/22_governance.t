use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Auth;
use DesertCMS::CapabilityPolicy;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Governance;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/themes", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Governance Test
site_url = https://example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $root/themes
admin_asset_dir = $root/admin-assets
session_cookie = governance_session
secure_cookies = 0
CONF

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

my $auth = DesertCMS::Auth->new(config => $config, db => $db);
my $owner_id = $auth->create_admin(username => 'owner', email => 'owner@example.test', password => 'CorrectHorseBatteryStaple42');
ok($owner_id, 'created default owner');

my ($owner) = $auth->authenticate(username => 'owner', password => 'CorrectHorseBatteryStaple42');
my ($owner_token) = $auth->create_session(user => $owner);
my $owner_session = $auth->session_from_token($owner_token);
is($owner_session->{role}, 'owner', 'session includes owner role');

my $reviewer_id = $auth->grant_admin_access(
    username      => 'reviewer',
    email         => 'reviewer@example.test',
    role          => 'reviewer',
    password      => 'TemporaryPassword44',
    actor_user_id => $owner_id,
);
my $support_id = $auth->grant_admin_access(
    username      => 'support',
    email         => 'support@example.test',
    role          => 'support',
    password      => 'TemporaryPassword45',
    actor_user_id => $owner_id,
);
ok($reviewer_id && $support_id, 'granted scoped admin users');

my $users = $auth->list_admin_users;
my %role_for = map { $_->{username} => $_->{role} } @{$users};
is($role_for{owner}, 'owner', 'owner role stored');
is($role_for{reviewer}, 'reviewer', 'reviewer role stored');
is($role_for{support}, 'support', 'support role stored');

ok(
    DesertCMS::Governance::allowed($config, 'reviewer', 'POST', '/admin/settings/contributors/requests/12/approve'),
    'reviewer can approve contributor requests'
);
ok(
    DesertCMS::Governance::allowed($config, 'operator', 'POST', '/admin/settings/operations/backup-all'),
    'operator can still run non-code operations'
);
ok(
    !DesertCMS::Governance::allowed($config, 'operator', 'GET', '/admin/settings/upgrade'),
    'operator cannot view root-applied upgrade staging'
);
ok(
    !DesertCMS::Governance::allowed($config, 'operator', 'POST', '/admin/settings/upgrade/apply'),
    'operator cannot queue root-applied upgrade archives'
);
ok(
    !DesertCMS::Governance::allowed($config, 'operator', 'POST', '/admin/settings/operations/rollback'),
    'operator cannot queue root-applied app rollbacks'
);
ok(
    !DesertCMS::Governance::allowed($config, 'reviewer', 'POST', '/admin/settings/sites/action'),
    'reviewer cannot queue contributor site lifecycle actions'
);
ok(
    DesertCMS::Governance::allowed($config, 'curator', 'POST', '/admin/content/4/publish'),
    'curator can publish content'
);
ok(
    !DesertCMS::Governance::allowed($config, 'curator', 'POST', '/admin/settings/contributors'),
    'curator cannot change contributor provider settings'
);
ok(
    DesertCMS::Governance::allowed($config, 'support', 'GET', '/admin/settings/master-control'),
    'support can view Master Control'
);
ok(
    DesertCMS::Governance::allowed($config, 'support', 'GET', '/admin/settings/payments'),
    'support can view centralized payment settings'
);
ok(
    !DesertCMS::Governance::allowed($config, 'support', 'POST', '/admin/settings/master-control/repair-paths'),
    'support cannot run Master Control actions'
);
ok(
    !DesertCMS::Governance::allowed($config, 'support', 'POST', '/admin/settings/payments/save'),
    'support cannot change centralized payment settings'
);
ok(
    DesertCMS::Governance::allowed($config, 'operator', 'POST', '/admin/settings/payments/save'),
    'operator can change provider payment settings'
);
ok(
    DesertCMS::Governance::allowed($config, 'reviewer', 'POST', '/admin/settings/federation/review'),
    'reviewer can review federated content'
);
ok(
    DesertCMS::Governance::allowed($config, 'curator', 'POST', '/admin/settings/federation/refresh'),
    'curator can scan federated content'
);
ok(
    DesertCMS::Governance::allowed($config, 'support', 'GET', '/admin/settings/federation'),
    'support can view federated review'
);
ok(
    !DesertCMS::Governance::allowed($config, 'support', 'POST', '/admin/settings/federation/review'),
    'support cannot change federated review status'
);
ok(
    DesertCMS::Governance::allowed($config, 'support', 'GET', '/admin/settings/plans'),
    'support can view service plans'
);
ok(
    DesertCMS::Governance::allowed($config, 'support', 'GET', '/admin/settings/operations'),
    'support can view operations'
);
ok(
    !DesertCMS::Governance::allowed($config, 'support', 'POST', '/admin/settings/operations/backup-all'),
    'support cannot run operations actions'
);
ok(
    !DesertCMS::Governance::allowed($config, 'support', 'POST', '/admin/settings/plans/assign'),
    'support cannot assign service plans'
);
ok(
    !DesertCMS::Governance::allowed($config, 'curator', 'POST', '/admin/settings/plans/save'),
    'curator cannot change service plans'
);

my $contrib_config_path = "$root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Governance Test
site_url = https://alexs.example.test
data_dir = $root/data-contrib
db_path = $root/data-contrib/desertcms.sqlite
app_secret_file = $root/data-contrib/app_secret
public_root = $root/public-contrib
originals_dir = $root/originals-contrib
backup_dir = $root/backups-contrib
theme_dir = $root/themes
admin_asset_dir = $root/admin-assets
session_cookie = contributor_governance_session
contributor_site_id = alexs
contributor_domain = alexs.example.test
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
make_path("$root/public-contrib", "$root/originals-contrib", "$root/backups-contrib", "$root/data-contrib");
my $contrib_db = DesertCMS::DB->new(config => $contrib_config);
$contrib_db->migrate;
my $contrib_auth = DesertCMS::Auth->new(config => $contrib_config, db => $contrib_db);
my $contrib_owner_id = $contrib_auth->create_admin(
    username => 'siteowner',
    email    => 'siteowner@example.test',
    password => 'CorrectHorseBatteryStaple43',
);
my ($contrib_owner) = $contrib_auth->authenticate(
    username => 'siteowner',
    password => 'CorrectHorseBatteryStaple43',
);
my ($contrib_owner_token) = $contrib_auth->create_session(user => $contrib_owner);
is(DesertCMS::Governance::scope($contrib_config), 'contributor', 'contributor config has contributor governance scope');
ok(DesertCMS::CapabilityPolicy::contributor_product_mode($contrib_config), 'contributor config enables product mode');
is(DesertCMS::Governance::role_label('owner', 'contributor'), 'Site Manager', 'contributor owner is labeled as site manager');

my %defined_capability = map { $_ => 1 } @{ DesertCMS::CapabilityPolicy::capabilities() };
for my $capability (qw(
    edit_content upload_media customize_theme enable_allowed_modules
    manage_billing view_usage manage_provider_settings run_operations
    download_media_sources publish_media_resources delete_media_assets bulk_manage_media
)) {
    ok($defined_capability{$capability}, "capability policy defines $capability");
}
my $edit_content_definition = DesertCMS::CapabilityPolicy::capability_definition('edit_content');
is($edit_content_definition->{label}, 'Edit content', 'capability definitions expose product-facing labels');

my %site_manager_capability = map { $_ => 1 } @{ DesertCMS::CapabilityPolicy::role_capabilities($contrib_config, 'owner') };
ok($site_manager_capability{edit_content}, 'site manager capability map includes content editing');
ok($site_manager_capability{upload_media}, 'site manager capability map includes media upload');
ok($site_manager_capability{download_media_sources}, 'site manager capability map includes private source downloads');
ok($site_manager_capability{publish_media_resources}, 'site manager capability map includes resource publishing');
ok($site_manager_capability{delete_media_assets}, 'site manager capability map includes unused media deletion');
ok($site_manager_capability{bulk_manage_media}, 'site manager capability map includes bulk media management');
ok($site_manager_capability{customize_theme}, 'site manager capability map includes theme customization');
ok($site_manager_capability{enable_allowed_modules}, 'site manager capability map includes allowed feature management');
ok($site_manager_capability{manage_billing}, 'site manager capability map includes billing management');
ok($site_manager_capability{view_usage}, 'site manager capability map includes usage visibility');
ok(!$site_manager_capability{manage_provider_settings}, 'site manager capability map excludes provider settings');
ok(!$site_manager_capability{run_operations}, 'site manager capability map excludes platform operations');

my ($contributor_owner_definition) = grep { $_->{role} eq 'owner' } @{ DesertCMS::Governance::role_definitions('contributor') };
my %contributor_owner_definition_capability = map { $_ => 1 } @{ $contributor_owner_definition->{capabilities} };
ok($contributor_owner_definition_capability{edit_content}, 'governance role definitions expose mapped capabilities');

is(DesertCMS::CapabilityPolicy::route_capability('GET', '/admin/settings/account'), 'manage_account', 'account settings route maps to account capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/content/create'), 'edit_content', 'content write route maps to edit_content');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/media/upload'), 'upload_media', 'media upload route maps to upload_media');
is(DesertCMS::CapabilityPolicy::route_capability('GET', '/admin/media/12/preview'), 'view_media', 'media private preview route maps to view_media');
is(DesertCMS::CapabilityPolicy::route_capability('GET', '/admin/media/12/download'), 'download_media_sources', 'media source download route maps to source-download capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/media/12/publish'), 'publish_media_resources', 'media resource publish route maps to publish capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/media/12/unpublish'), 'publish_media_resources', 'media resource unpublish route maps to publish capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/media/12/delete'), 'delete_media_assets', 'media delete route maps to delete capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/media/bulk'), 'bulk_manage_media', 'media bulk route maps to bulk capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/media/previews/queue'), 'bulk_manage_media', 'media preview queue route maps to bulk capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/media/previews/process'), 'bulk_manage_media', 'media preview processing route maps to bulk capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/site-settings/save'), 'customize_theme', 'site design save route maps to customize_theme');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/settings/modules/save'), 'enable_allowed_modules', 'module save route maps to enable_allowed_modules');
is(DesertCMS::CapabilityPolicy::route_capability('GET', '/admin/billing'), 'view_usage', 'billing page route maps to view_usage');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/billing/checkout'), 'manage_billing', 'billing checkout route maps to manage_billing');
is(DesertCMS::CapabilityPolicy::route_capability('GET', '/admin/help'), 'view_home', 'help route maps to home capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/settings/save'), 'manage_provider_settings', 'provider settings save route maps to manage_provider_settings');
is(DesertCMS::CapabilityPolicy::route_capability('GET', '/admin/settings/payments'), 'view_master_control', 'payment settings read route maps to master-control visibility');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/settings/payments/save'), 'manage_provider_settings', 'payment settings save route maps to provider settings capability');
is(DesertCMS::CapabilityPolicy::route_capability('POST', '/admin/settings/operations/backup-all'), 'run_operations', 'operations action route maps to run_operations');

ok(DesertCMS::CapabilityPolicy::has($contrib_config, 'owner', 'enable_allowed_modules'), 'site manager can enable allowed features');
ok(DesertCMS::CapabilityPolicy::has($contrib_config, 'owner', 'manage_billing'), 'site manager can manage billing');
ok(DesertCMS::CapabilityPolicy::has($contrib_config, 'owner', 'publish_media_resources'), 'site manager can publish media resources');
ok(!DesertCMS::CapabilityPolicy::has($contrib_config, 'contributor', 'download_media_sources'), 'basic contributor cannot download private source files');
ok(!DesertCMS::CapabilityPolicy::has($contrib_config, 'editor', 'delete_media_assets'), 'contributor editor cannot delete media assets by default');
ok(!DesertCMS::CapabilityPolicy::has($contrib_config, 'owner', 'manage_provider_settings'), 'site manager cannot manage platform provider settings');
ok(!DesertCMS::CapabilityPolicy::has($contrib_config, 'owner', 'run_operations'), 'site manager cannot run platform operations');
ok(
    DesertCMS::Governance::allowed($contrib_config, 'contributor', 'POST', '/admin/content/create'),
    'contributor role can create local content'
);
ok(
    DesertCMS::Governance::allowed($contrib_config, 'contributor', 'GET', '/admin/billing'),
    'contributor role can view local billing'
);
ok(
    DesertCMS::Governance::allowed($contrib_config, 'contributor', 'POST', '/admin/billing/checkout'),
    'contributor role can start hosted billing checkout'
);
ok(
    !DesertCMS::Governance::allowed($contrib_config, 'owner', 'GET', '/admin/settings/contributors'),
    'contributor subCMS owner cannot access master contributor settings'
);
ok(
    !DesertCMS::Governance::allowed($contrib_config, 'owner', 'GET', '/admin/settings/payments'),
    'contributor subCMS owner cannot access platform payment settings'
);
ok(
    !DesertCMS::Governance::allowed($contrib_config, 'owner', 'GET', '/admin/settings/plans'),
    'contributor subCMS owner cannot access master service plans'
);
ok(
    !DesertCMS::Governance::allowed($contrib_config, 'owner', 'GET', '/admin/settings/federation'),
    'contributor subCMS owner cannot access master federated review'
);
ok(
    !DesertCMS::Governance::allowed($contrib_config, 'owner', 'GET', '/admin/settings/operations'),
    'contributor subCMS owner cannot access master operations'
);
ok(
    !DesertCMS::Governance::allowed($contrib_config, 'owner', 'GET', '/admin/backups'),
    'contributor subCMS owner cannot access backup operations'
);
ok(
    !DesertCMS::Governance::allowed($contrib_config, 'owner', 'POST', '/admin/theme/save'),
    'contributor subCMS owner cannot save raw theme files'
);
ok(
    !DesertCMS::Governance::allowed($contrib_config, 'owner', 'POST', '/admin/site-settings/fonts/refresh'),
    'contributor subCMS owner cannot refresh platform font packages'
);
ok(
    !DesertCMS::Governance::allowed($contrib_config, 'owner', 'POST', '/admin/site-settings/fonts/install'),
    'contributor subCMS owner cannot install platform font packages'
);
ok(
    DesertCMS::Governance::allowed($contrib_config, 'owner', 'GET', '/admin/settings/modules'),
    'contributor subCMS site manager can open feature catalog'
);

{
    local $ENV{DESERTCMS_CONFIG} = $contrib_config_path;
    my $contrib_app = DesertCMS::App->new;
    my %contrib_cookie = ( contributor_governance_session => $contrib_owner_token );
    my $settings_redirect = _capture_response(sub {
        $contrib_app->_require_login(
            _request(method => 'GET', path => '/admin/settings', cookies => \%contrib_cookie),
            sub { print "unexpected settings handler\n" }
        );
    });
    like($settings_redirect, qr{Status: 303 See Other}, 'contributor direct settings route redirects');
    like($settings_redirect, qr{Location: /admin/settings/account}, 'contributor generic settings redirects to Account');

    my $theme_redirect = _capture_response(sub {
        $contrib_app->_require_login(
            _request(method => 'GET', path => '/admin/theme', cookies => \%contrib_cookie),
            sub { print "unexpected theme handler\n" }
        );
    });
    like($theme_redirect, qr{Location: /admin/site-settings\?section=theme}, 'contributor legacy theme route redirects to Design');

    my $content_new_redirect = _capture_response(sub {
        $contrib_app->_require_login(
            _request(method => 'GET', path => '/admin/content/new', cookies => \%contrib_cookie),
            sub { print "unexpected content-new handler\n" }
        );
    });
    like($content_new_redirect, qr{Location: /admin/pages/new}, 'contributor generic new-content route redirects to Pages');

    my $theme_save_forbidden = _capture_response(sub {
        $contrib_app->_require_login(
            _request(method => 'POST', path => '/admin/theme/save', cookies => \%contrib_cookie),
            sub { print "unexpected theme-save handler\n" }
        );
    });
    like($theme_save_forbidden, qr{Status: 403 Forbidden}, 'contributor direct theme save is denied');

    for my $blocked_post_path (
        '/admin/site-settings/fonts/refresh',
        '/admin/site-settings/fonts/install',
    ) {
        my $blocked = _capture_response(sub {
            $contrib_app->_require_login(
                _request(method => 'POST', path => $blocked_post_path, cookies => \%contrib_cookie),
                sub { print "unexpected blocked handler for $blocked_post_path\n" }
            );
        });
        like($blocked, qr{Status: 403 Forbidden}, "contributor direct $blocked_post_path is denied");
    }

    for my $blocked_path (
        '/admin/settings/master-control',
        '/admin/settings/contributors',
        '/admin/settings/blueprints',
        '/admin/settings/plans',
        '/admin/settings/sites',
        '/admin/settings/federation',
        '/admin/settings/governance',
        '/admin/settings/operations',
        '/admin/settings/upgrade',
        '/admin/backups',
    ) {
        my $blocked = _capture_response(sub {
            $contrib_app->_require_login(
                _request(method => 'GET', path => $blocked_path, cookies => \%contrib_cookie),
                sub { print "unexpected blocked handler for $blocked_path\n" }
            );
        });
        like($blocked, qr{Status: 403 Forbidden}, "contributor direct $blocked_path is denied");
    }
}

$auth->record_audit(
    actor_user_id => $owner_id,
    action        => 'test.governance',
    subject_type  => 'test',
    subject_id    => 99,
    details       => { role => 'owner', ok => 1 },
);
my $audit_rows = $auth->audit_rows(limit => 5);
my ($audit_match) = grep { ($_->{action} || '') eq 'test.governance' } @{$audit_rows};
ok($audit_match, 'audit rows include explicit governance action');
is($audit_match->{details}{role}, 'owner', 'audit details are decoded');

my $disable_owner_error = eval {
    $auth->disable_admin_user(id => $owner_id, actor_user_id => $reviewer_id);
    '';
} || $@;
like($disable_owner_error, qr/at least one active owner/, 'cannot disable the last active owner');

my ($reviewer) = $auth->authenticate(username => 'reviewer', password => 'TemporaryPassword44');
my ($reviewer_token) = $auth->create_session(user => $reviewer);
ok($auth->session_from_token($reviewer_token), 'reviewer session starts active');
ok($auth->disable_admin_user(id => $reviewer_id, actor_user_id => $owner_id), 'owner disables reviewer');
ok(!$auth->session_from_token($reviewer_token), 'disabling a user revokes active sessions');

my $app = DesertCMS::App->new;
my $page = _capture_response(sub {
    $app->_settings_governance_page(_request(), $owner_session, $owner_token);
});
like($page, qr/Roles and Audit/, 'governance page renders');
like($page, qr/Owner/, 'governance page shows owner role');
like($page, qr/reviewer/, 'governance page lists scoped users');
like($page, qr/test\.governance/, 'governance page lists audit rows');
like($page, qr/class="content-table compact-table admin-card-table"/, 'governance account tables use responsive card table markup');
like($page, qr/data-label="User".*data-label="Actions".*data-label="Actor".*data-label="Details"/s, 'governance account rows expose mobile table labels');
like($page, qr/aria-label="Governance sections".*href="#governance-roles">Role Model<\/a>.*href="#governance-users">Admin Users<\/a>.*href="#governance-grant">Grant Access<\/a>.*href="#governance-audit">Audit Log<\/a>/s, 'governance page renders local section nav');
like($page, qr/id="governance-roles".*id="governance-users".*id="governance-grant".*id="governance-audit"/s, 'governance page exposes stable section anchors');
my $federation_page = _capture_response(sub {
    $app->_settings_federation_page(_request(), $owner_session, $owner_token);
});
like($federation_page, qr/Contributor Content Review/, 'federated review page renders');
like($federation_page, qr/Scan contributor sites/, 'federated review page exposes scan action');
like($federation_page, qr/class="content-table compact-table admin-card-table"/, 'federated review tables use responsive card table markup');
like($federation_page, qr/<th>Item<\/th><th>Contributor<\/th><th>Seen<\/th><th>Preview<\/th><th>Actions<\/th>/, 'federated review responsive tables keep labeled headers for empty states');
like($federation_page, qr/aria-label="Federated review sections".*href="#federation-summary">Summary<\/a>.*href="#federation-pending">Pending Review<\/a>.*href="#federation-approved">Approved<\/a>.*href="#federation-rejected">Rejected<\/a>/s, 'federated review page renders local section nav');
like($federation_page, qr/id="federation-summary".*id="federation-pending".*id="federation-approved".*id="federation-rejected"/s, 'federated review page exposes stable section anchors');

my $master_account_nav = _capture_response(sub {
    print $app->_settings_nav('governance', $owner_session);
});
like($master_account_nav, qr/href="\/admin\/settings\/account" class="active">Admin Account<\/a>/, 'governance is grouped under Admin Account in master settings nav');
unlike($master_account_nav, qr/>Governance<\/a>|>Federated Review<\/a>/, 'governance and federated review are not top-level settings nav items');
like($page, qr/aria-label="Admin account sections".*href="\/admin\/settings\/account">Login<\/a>.*href="\/admin\/settings\/governance" class="active">Governance<\/a>.*href="\/admin\/settings\/federation">Federated Review<\/a>/s, 'governance page renders Admin Account subnav');
like($federation_page, qr/aria-label="Admin account sections".*href="\/admin\/settings\/governance">Governance<\/a>.*href="\/admin\/settings\/federation" class="active">Federated Review<\/a>/s, 'federated review page stays inside Admin Account subnav');

my $master_contributor_nav = _capture_response(sub {
    print $app->_settings_nav('plans', $owner_session);
});
like($master_contributor_nav, qr/href="\/admin\/settings\/contributors" class="active">Contributor<\/a>/, 'service plans are grouped under Contributor in master settings nav');
unlike($master_contributor_nav, qr/>Blueprints<\/a>|>Service Plans<\/a>|>Contributor Sites<\/a>/, 'contributor management pages are not top-level settings nav items');
my $contributor_subnav = _capture_response(sub {
    print $app->_contributor_settings_nav('plans', $owner_session);
});
like($contributor_subnav, qr/aria-label="Contributor sections".*Requests &amp; Email.*Blueprints.*Service Plans.*Contributor Sites/s, 'Contributor settings subnav contains request, blueprint, plan, and site sections');
like($contributor_subnav, qr/href="\/admin\/settings\/plans" class="active">Service Plans<\/a>/, 'Contributor settings subnav marks the active child page');

my $contrib_nav = _capture_response(sub {
    my $contrib_app = bless { config => $contrib_config }, 'DesertCMS::App';
    print $contrib_app->_contributor_product_nav('Home', { role => 'owner' });
});
like($contrib_nav, qr/class="contributor-product-nav"/, 'contributor product nav uses separate nav class');
like($contrib_nav, qr/data-product-nav="contributor"/, 'contributor product nav is marked as contributor product navigation');
like($contrib_nav, qr/>Home<\/a>/, 'contributor product nav includes Home');
like($contrib_nav, qr/>Site Builder<\/a>/, 'contributor product nav includes Site Builder');
like($contrib_nav, qr/>Features<\/a>/, 'contributor product nav includes Features');
like($contrib_nav, qr/>Billing<\/a>/, 'contributor product nav includes Billing');
like($contrib_nav, qr/>Account<\/a>/, 'contributor product nav includes Account');
like($contrib_nav, qr/>Help<\/a>/, 'contributor product nav includes Help');
unlike($contrib_nav, qr/>Analytics<\/a>/, 'contributor product nav does not expose Analytics');
unlike($contrib_nav, qr/>Settings<\/a>/, 'contributor product nav does not expose generic Settings');

my $contributor_editor_nav = DesertCMS::App::_editor_nav('overview', $contrib_config, { role => 'owner' });
like($contributor_editor_nav, qr/aria-label="Site builder sections"/, 'contributor editor nav uses site-builder aria label');
like($contributor_editor_nav, qr/>Site Builder<\/a>/, 'contributor editor nav renames overview to site builder');
like($contributor_editor_nav, qr/>Layouts<\/a>/, 'contributor editor nav uses product-facing layout label');
like($contributor_editor_nav, qr/>Site Basics<\/a>/, 'contributor editor nav uses product-facing site basics label');
unlike($contributor_editor_nav, qr/>Features<\/a>|>Modules<\/a>|>Site &amp; SEO<\/a>/, 'contributor editor nav does not reuse backend module or feature catalog labels');
my $contributor_module_detail_nav = DesertCMS::App::_editor_nav('events', $contrib_config, { role => 'owner' });
is($contributor_module_detail_nav, '', 'contributor module detail pages do not render site-builder peer navigation');
my $contributor_feature_detail_product_nav = _capture_response(sub {
    my $contrib_app = bless { config => $contrib_config }, 'DesertCMS::App';
    print $contrib_app->_contributor_product_nav('Events', { role => 'owner' });
});
like($contributor_feature_detail_product_nav, qr/href="\/admin\/settings\/modules" class="active" aria-current="page">Features<\/a>/, 'contributor module detail pages mark Features active in product navigation');
unlike($contributor_feature_detail_product_nav, qr/href="\/admin\/settings\/modules\/(?:events|directory|bookings|membership|newsletter|donations|testimonials)"/, 'contributor product nav keeps module-specific setup under Features');

my $contributor_role_nav = _capture_response(sub {
    my $contrib_app = bless { config => $contrib_config }, 'DesertCMS::App';
    print $contrib_app->_contributor_product_nav('Home', { role => 'contributor' });
});
unlike($contributor_role_nav, qr/>Design<\/a>/, 'contributor role nav is a purpose-built reduced product nav');
unlike($contributor_role_nav, qr/>Features<\/a>/, 'contributor role nav does not use policy filtering to expose feature management');

my $contributor_role_cards = DesertCMS::App::_capability_link_cards(
    $contrib_config,
    { role => 'contributor' },
    { href => '/admin/pages',            eyebrow => 'Pages',    title => 'Pages',    body => 'Allowed content card.', detail => 'Allowed', capability => 'view_content' },
    { href => '/admin/settings/modules', eyebrow => 'Features', title => 'Features', body => 'Feature management.',   detail => 'Hidden',  capability => 'view_features' },
    { href => '/admin/site-settings',    eyebrow => 'Design',   title => 'Design',   body => 'Theme controls.',       detail => 'Hidden',  capability => 'view_design' },
);
like($contributor_role_cards, qr/>Pages<\/strong>/, 'capability-filtered cards include allowed contributor destinations');
unlike($contributor_role_cards, qr/>Features<\/strong>/, 'capability-filtered cards hide feature destinations');
unlike($contributor_role_cards, qr/>Design<\/strong>/, 'capability-filtered cards hide design destinations');

my $contributor_settings_nav = _capture_response(sub {
    my $contrib_app = bless { config => $contrib_config }, 'DesertCMS::App';
    print $contrib_app->_settings_nav('account', { role => 'owner' });
});
like($contributor_settings_nav, qr/>Account<\/a>/, 'contributor account nav includes account');
like($contributor_settings_nav, qr/>Help<\/a>/, 'contributor account nav includes help');
unlike($contributor_settings_nav, qr/>Overview<\/a>|>Master Control<\/a>|>Operations<\/a>/, 'contributor account nav does not reuse master settings sections');

my $support_settings_nav = _capture_response(sub {
    print $app->_settings_nav('overview', { role => 'support' });
});
like($support_settings_nav, qr/>Operations<\/a>/, 'support settings nav includes readable operations');
unlike($support_settings_nav, qr/>Contributor Sites<\/a>/, 'support settings nav hides contributor lifecycle');
unlike($support_settings_nav, qr/>Upgrade<\/a>/, 'support settings nav hides upgrade actions');

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
    my (%args) = @_;
    return bless {
        params  => $args{params}  || {},
        cookies => $args{cookies} || {},
        method  => $args{method}  || 'GET',
        path    => $args{path}    || '/admin',
    }, 'Local::Request';
}

package Local::Request;

sub param {
    my ($self, $key) = @_;
    return $self->{params}{$key};
}

sub cookie {
    my ($self, $key) = @_;
    return $self->{cookies}{$key};
}

package main;
