use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP qw(decode_json encode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::HTTP;
use DesertCMS::Media;
use DesertCMS::Membership;
use DesertCMS::Modules;
use DesertCMS::Settings;

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public/assets/media", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data", "$root/docs");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Membership Test
site_url = https://members.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
docs_source_dir = $root/docs
secure_cookies = 0
CONF

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
my $content = DesertCMS::Content->new(config => $config, db => $db);

_write("$root/docs/member-guide.md", <<"MD");
---
title: Member Guide
summary: Private onboarding guide for members.
audience: Site Management
resource_type: Member Resource
tags: membership, private
updated: 2026-07-03
access: Members only
order: 10
---

# Member Guide

Private member instructions.
MD

my $home = $content->save(
    type      => 'page',
    title     => 'Home',
    slug      => 'home',
    body_text => 'Membership home.',
);
$content->publish(id => $home->{id});

DesertCMS::Settings::set_many($config, $db, {
    module_membership_enabled => 1,
    module_docs_enabled       => 1,
    membership_title          => 'Client Portal',
    membership_intro          => 'Private pages, member docs, and downloads.',
    membership_signup_enabled => 1,
    membership_notify_postmark_enabled => 0,
});

my $settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'membership'), 'membership feature can be enabled independently');
my $catalog = DesertCMS::Modules::catalog($settings, config => $config);
like(_module_catalog_text($catalog), qr/Membership \/ Gated Content.*member login, groups, member dashboards, gated pages/s, 'feature catalog describes Membership / Gated Content');
like(_module_catalog_text($catalog), qr/Membership Payments.*paid member resources, subscription records, Stripe Checkout/s, 'feature catalog describes separate Membership Payments entitlement');

my $membership = DesertCMS::Membership->new(config => $config, db => $db);
my $group = $membership->save_group(
    name        => 'Clients',
    slug        => 'clients',
    description => 'Client portal members',
);
ok($group->{id}, 'member group is saved');

my $member = $membership->save_member(
    email        => 'client@example.test',
    display_name => 'Client User',
    password     => 'correct horse battery staple',
    status       => 'active',
    group_ids    => [ $group->{id} ],
    signup_source => 'test',
);
ok($member->{id}, 'member account is saved');
is_deeply($member->{group_ids}, [ $group->{id} ], 'member group assignment is stored');

my ($auth_member, $auth_error) = $membership->authenticate(
    email    => 'client@example.test',
    password => 'correct horse battery staple',
);
ok($auth_member && !$auth_error, 'member can authenticate');
my ($session_token) = $membership->create_session(member => $auth_member, ip_address => '127.0.0.1', user_agent => 'test');
ok($membership->session_from_token($session_token), 'member session resolves from cookie token');

my $member_page = $content->save(
    type          => 'page',
    title         => 'Client Notes',
    slug          => 'client-notes',
    excerpt       => 'Notes for members.',
    body_text     => 'Private member page body.',
    access_policy => 'members',
);
$content->publish(id => $member_page->{id});

my $group_page = $content->save(
    type            => 'page',
    title           => 'Client Project',
    slug            => 'client-project',
    excerpt         => 'Group-only project page.',
    body_text       => 'Group-only page body.',
    access_policy   => 'group',
    access_group_id => $group->{id},
);
$content->publish(id => $group_page->{id});

my $private_page = $content->save(
    type          => 'page',
    title         => 'Internal Draft',
    slug          => 'internal-draft',
    body_text     => 'Hidden from everyone.',
    access_policy => 'private',
);
$content->publish(id => $private_page->{id});

my $source_path = "$root/originals/private-guide.txt";
_write($source_path, "private source payload\n");
my $checksum = 'd' x 64;
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
        VALUES
            ('private-guide.txt', ?, '', '', 'Private Guide', 'Private member guide.',
             'text/plain', NULL, NULL, 23, ?, '{}', ?)
    },
    undef,
    $source_path,
    $checksum,
    time
);
my $media_id = $db->dbh->sqlite_last_insert_rowid;
my $resource = $membership->save_resource(
    title           => 'Private Guide',
    slug            => 'private-guide',
    summary         => 'A private source download.',
    body            => 'Download the original private source file.',
    media_asset_id  => $media_id,
    collection_name => 'Client Files',
    access_policy   => 'group',
    access_group_id => $group->{id},
    status          => 'published',
    direct_download => 0,
);
ok($resource->{id}, 'member resource is saved');

$content->rebuild_all;
ok(-f File::Spec->catfile($root, 'public', 'index.html'), 'public home is generated');
ok(!-f File::Spec->catfile($root, 'public', 'client-notes', 'index.html'), 'members-only page is not generated as public static HTML');
ok(!-f File::Spec->catfile($root, 'public', 'client-project', 'index.html'), 'group-only page is not generated as public static HTML');
ok(!-f File::Spec->catfile($root, 'public', 'internal-draft', 'index.html'), 'private page is not generated as public static HTML');

my $index_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($index_html, qr{href="/members/"}, 'enabled Membership appears in public navigation');
unlike($index_html, qr{client-notes}, 'members-only page is omitted from public navigation');
my $sitemap = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
like($sitemap, qr{https://members\.example\.test/members/</loc>}, 'sitemap includes public member portal landing');
unlike($sitemap, qr{client-notes}, 'sitemap omits gated member page');

my $app = DesertCMS::App->new;
my $dashboard = _capture_response(sub {
    $app->_dispatch_members(_member_request('/members', 'GET', {}, $session_token));
});
like($dashboard, qr{Client Portal}, 'member dashboard renders configured title');
like($dashboard, qr{Client Notes}, 'member dashboard lists members-only content');
like($dashboard, qr{Client Project}, 'member dashboard lists group-only content');
like($dashboard, qr{Member Guide}, 'member dashboard lists member-only docs');
like($dashboard, qr{Private Guide}, 'member dashboard lists protected resources');

my $content_response = _capture_response(sub {
    $app->_dispatch_members(_member_request('/members/content/client-project', 'GET', {}, $session_token));
});
like($content_response, qr{Group-only page body}, 'member content route renders authorized group page');

my $doc_response = _capture_response(sub {
    $app->_dispatch_members(_member_request('/members/docs/member-guide', 'GET', {}, $session_token));
});
like($doc_response, qr{Private member instructions}, 'member docs route renders held docs catalog item');

my $download_response = _capture_response(sub {
    $app->_dispatch_members(_member_request('/members/resources/private-guide/download', 'GET', {}, $session_token));
});
like($download_response, qr{Content-Disposition: attachment; filename="private-guide\.txt"}, 'resource download uses private source filename');
like($download_response, qr{private source payload}, 'resource download streams private source payload');

my $anonymous_response = _capture_response(sub {
    $app->_dispatch_members(_member_request('/members/resources/private-guide/download'));
});
like($anonymous_response, qr{Status: 303 See Other}, 'anonymous protected download redirects to login');
like($anonymous_response, qr{Location: /members/login}, 'anonymous protected download targets member login');

my $admin_html = _capture_response(sub {
    $app->_module_membership_settings_page(undef, { username => 'admin', role => 'owner' }, 'membership-session');
});
like($admin_html, qr/<h1>Membership \/ Gated Content<\/h1>/, 'admin Membership surface renders');
like($admin_html, qr/module-section-nav" aria-label="Membership setup sections".*href="\#module-settings">Portal Settings<\/a>.*href="\#module-members">Members<\/a>.*href="\#module-groups">Groups<\/a>.*href="\#module-invites">Invites<\/a>.*href="\#module-resources">Member Resources<\/a>.*href="\#module-payments">Membership Payments<\/a>/s, 'admin Membership surface exposes local section navigation');
like($admin_html, qr{<code>/members/</code>}, 'admin Membership surface shows public path');
like($admin_html, qr{Client User}, 'admin Membership surface lists member');
like($admin_html, qr{Private Guide}, 'admin Membership surface lists member resource');
like($admin_html, qr{Membership Payments}, 'admin Membership surface shows isolated payment section');
like($admin_html, qr/content-table compact-table admin-card-table/, 'admin Membership tables use responsive card markup');
like($admin_html, qr/data-label="Member".*data-label="Resource"/s, 'admin Membership populated rows expose mobile card labels');
like($admin_html, qr/<th>Stripe Session<\/th>/, 'admin Membership payment table keeps responsive payment headers for empty states');
like($admin_html, qr/module-section-nav" aria-label="Membership portal editor sections".*href="\#membership-portal-status">Status<\/a>.*href="\#membership-public-copy">Public Copy<\/a>.*href="\#membership-notifications">Notifications<\/a>/s, 'admin Membership portal settings expose local form navigation');
like($admin_html, qr/id="membership-portal-status".*id="membership-public-copy".*id="membership-notifications"/s, 'admin Membership portal settings navigation targets stable anchors');
like($admin_html, qr/module-section-nav" aria-label="Member resource editor sections".*href="\#membership-resource-content">Content<\/a>.*href="\#membership-resource-file">File &amp; Access<\/a>.*href="\#membership-resource-publish">Publishing<\/a>/s, 'admin Membership resource editor exposes local form navigation');
like($admin_html, qr/id="membership-resource-content".*id="membership-resource-file".*id="membership-resource-publish"/s, 'admin Membership resource editor navigation targets stable anchors');

my $content_form = _capture_response(sub {
    $app->_content_form(_member_request('/admin/content/' . $member_page->{id} . '/edit'), { username => 'admin', role => 'owner', user_id => 1 }, 'content-session', $member_page->{id});
});
like($content_form, qr{name="access_policy"}, 'content editor shows access policy control when Membership is enabled');
like($content_form, qr{Members only}, 'content editor includes members-only access option');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        membership          => 1,
        membership_payments => 0,
        docs                => 1,
    }),
    commerce_model => 'master_owned',
    stripe_secret_key => 'sk_test_members',
    stripe_webhook_secret => 'whsec_members',
});
my $contrib_config_path = "$root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Members
site_url = https://member-site.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
docs_source_dir = $root/docs
contributor_site_id = member-site
contributor_domain = member-site.example.test
secure_cookies = 0
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
my $locked_membership = DesertCMS::Membership->new(config => $contrib_config, db => $db);
my $locked_catalog = DesertCMS::Modules::catalog(DesertCMS::Settings::all($config, $db), config => $contrib_config);
my %feature_by_key = map { $_->{key} => $_ } @{$locked_catalog};
ok($feature_by_key{membership_payments}{locked_by_plan}, 'feature catalog can lock Membership Payments by plan');
ok(!$locked_membership->membership_payments_allowed_by_plan, 'membership_payments is locked independently of Membership');
ok(!$locked_membership->checkout_ready, 'locked Membership Payments keeps checkout unavailable');
my $locked_error = eval { $locked_membership->create_payment_checkout(member => $member, resource_id => $resource->{id}); 1 } ? '' : $@;
like($locked_error, qr/Membership Payments/, 'membership checkout is rejected when membership_payments is locked');

done_testing;

sub _member_request {
    my ($path, $method, $form, $session_token) = @_;
    my %cookies;
    $cookies{desertcms_member_session} = $session_token if $session_token;
    return bless {
        method => $method || 'GET',
        path   => $path || '/members',
        host   => 'members.example.test',
        form   => $form || {},
        query  => $form || {},
        cookies => \%cookies,
        ip_address => '127.0.0.1',
        user_agent => 'membership-test',
    }, 'DesertCMS::HTTP';
}

sub _module_catalog_text {
    my ($catalog) = @_;
    return join "\n", map {
        join ' ', $_->{label} || '', $_->{description} || '', $_->{public_path} || ''
    } @{$catalog || []};
}

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _capture_response {
    my ($code) = @_;
    my $output = '';
    open my $fh, '>', \$output or die "cannot capture output: $!";
    {
        local *STDOUT = $fh;
        DesertCMS::HTTP::reset_response_state();
        $code->();
    }
    return $output;
}
