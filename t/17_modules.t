use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP qw(encode_json decode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::Modules;
use DesertCMS::Navigation;
use DesertCMS::Settings;

{
    package Local::ModuleRequest;
    sub new {
        my ($class, $form) = @_;
        return bless { form => $form || {} }, $class;
    }
    sub param {
        my ($self, $key) = @_;
        return $self->{form}{$key};
    }
}

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data", "$root/docs-src", "$root/docs-src/archive", "$root/docs-src/members");
_write(
    "$root/docs-src/install.md",
    "---\ntitle: Install Guide\nsummary: OpenBSD install test document.\naudience: Technical\nresource_type: Guide\ntags: OpenBSD, install\nupdated: 2026-07-01\naccess: Public\norder: 20\n---\n\n# Install Guide\n\nUse `doas` on OpenBSD.\n\n```sh\nperl install/openbsd-install.pl --dry-run\n```\n\n<script>alert(1)</script>\n"
);
_write(
    "$root/docs-src/site.md",
    "---\ntitle: Site Guide\nsummary: Site-management test document.\naudience: Site Management\nresource_type: Help Center\ntags: editing, media\naccess: Public\norder: 10\n---\n\n# Site Guide\n\nEdit pages and media.\n"
);
_write(
    "$root/docs-src/faq.md",
    "---\ntitle: Public FAQ\nsummary: Frequently asked public resource questions.\naudience: Site Management\nresource_type: FAQ\ntags: FAQ, help center\naccess: Public\norder: 15\n---\n\n# Public FAQ\n\nAnswers for public resource workflows.\n"
);
_write(
    "$root/docs-src/members/benefits.md",
    "---\ntitle: Member Benefits Packet\nsummary: Member-only benefits and onboarding details.\naudience: Site Management\nresource_type: Member Resource\ntags: members, onboarding\naccess: Members\norder: 16\n---\n\n# Member Benefits Packet\n\nThis should stay out of the public static Resource Hub.\n"
);
_write(
    "$root/docs-src/archive/town-history.md",
    "---\ntitle: Town History Packet\nsummary: Local archive packet for public history resources.\naudience: General\nresource_type: Local Archive\ntags: archive, local history\naccess: Public\norder: 30\n---\n\n# Town History Packet\n\nArchive notes for local history collections.\n"
);

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Module Test
site_url = https://example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
docs_source_dir = $root/docs-src
secure_cookies = 0
shop_enabled = 1
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

my $content = DesertCMS::Content->new(config => $config, db => $db);
my $home = $content->save(
    type => 'page',
    title => 'Home',
    slug => 'home',
    body_text => 'Module test home.',
);
$content->publish(id => $home->{id});

my $settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'map'), 'map module defaults enabled');
ok(DesertCMS::Modules::enabled($settings, 'shop'), 'shop module inherits enabled shop default');
ok(!DesertCMS::Modules::enabled($settings, 'gallery'), 'showcase module defaults disabled');
ok(!DesertCMS::Modules::enabled($settings, 'forms'), 'forms module defaults disabled');
ok(!DesertCMS::Modules::enabled($settings, 'docs'), 'docs module defaults disabled');

my $app = DesertCMS::App->new;
my $editor_home_html = _capture_response(sub {
    $app->_editor_home(undef, { username => 'admin' }, 'editor-session');
});
like($editor_home_html, qr/href="\/admin\/settings\/modules".*<strong>Modules<\/strong>/s, 'editor overview links to modules');
like($editor_home_html, qr/href="\/admin\/site-settings".*<strong>Site &amp; SEO<\/strong>/s, 'editor overview links to site and SEO settings');

my $modules_admin_html = _capture_response(sub {
    $app->_settings_modules_page(undef, { username => 'admin' }, 'modules-session');
});
like($modules_admin_html, qr/<a href="\/admin\/settings\/modules" class="active" aria-current="page">Modules<\/a>/, 'module overview marks Modules active in primary navigation');
unlike($modules_admin_html, qr/<nav class="editor-nav" aria-label="Editor sections">/, 'module overview does not borrow editor navigation');
unlike($modules_admin_html, qr/aria-label="Settings sections"/, 'module overview no longer appears under settings navigation');
my $master_module_detail_nav = DesertCMS::App::_editor_nav('events', $config, { role => 'owner' });
is($master_module_detail_nav, '', 'module detail pages do not render editor peer navigation');
my $master_module_primary_nav = $app->_admin_primary_nav('Events', { username => 'admin', role => 'owner' });
like($master_module_primary_nav, qr/<a href="\/admin\/settings\/modules" class="active" aria-current="page">Modules<\/a>/, 'module detail pages mark Modules active in primary navigation');
unlike($master_module_primary_nav, qr/href="\/admin\/settings\/modules\/(?:events|directory|bookings|membership|newsletter|donations|testimonials)"/, 'feature-specific module pages are not peer links in primary navigation');
my $events_module_html = _capture_response(sub {
    $app->_module_events_settings_page(undef, { username => 'admin', role => 'owner' }, 'events-session');
});
like($events_module_html, qr/module-setup-nav" aria-label="Module setup pages"><a href="\/admin\/settings\/modules" class="module-setup-nav-home"><strong>Modules<\/strong><small>Module Catalog<\/small><span>Module parent<\/span><\/a><span class="module-setup-nav-groups">.*data-module-setup-group="modules".*<span class="module-setup-nav-group-title">Core Modules<\/span>.*href="\/admin\/settings\/modules\/events" class="active" aria-current="page">Events<\/a>.*href="\/admin\/settings\/modules\/directory">Directory<\/a>.*href="\/admin\/settings\/modules\/bookings">Bookings \/ Appointments<\/a>.*href="\/admin\/settings\/modules\/membership">Membership \/ Gated Content<\/a>.*href="\/admin\/settings\/modules\/newsletter">Newsletter<\/a>.*href="\/admin\/settings\/modules\/donations">Donations \/ Fundraising<\/a>.*href="\/admin\/settings\/modules\/testimonials">Testimonials \/ Reviews<\/a>.*href="\/admin\/settings\/modules\/shop">Shop \/ Catalog<\/a>.*data-module-setup-group="tools".*<span class="module-setup-nav-group-title">Site Tool Modules<\/span>/s, 'module detail pages render grouped Modules setup nav with active first-party module');
unlike($events_module_html, qr/<nav class="editor-nav" aria-label="Editor sections">/, 'module detail pages do not borrow editor navigation');
unlike($events_module_html, qr/>Shop Payments<\/a>|>Event Payments<\/a>|>Donation Payments<\/a>|>Booking Deposits<\/a>|>Membership Payments<\/a>/, 'payment entitlements stay inside parent module setup pages, not module nav');
like($modules_admin_html, qr/module-catalog-landing" id="module-catalog-workspace".*<h2>Module setup<\/h2>/s, 'module catalog landing renders a single setup workspace below the grouped nav');
like($modules_admin_html, qr/href="\/admin\/settings\/modules\/events">Events<\/a>.*href="\/admin\/settings\/modules\/testimonials">Testimonials \/ Reviews<\/a>.*href="\/admin\/settings\/modules\/map">Map \/ Locations<\/a>.*href="\/admin\/settings\/modules\/showcase">Showcase<\/a>/s, 'module setup nav keeps first-party module edit pages available');
unlike($modules_admin_html, qr/<div class="module-grid">|module-card-kicker|data-feature-key="events"|data-feature-key="map"/, 'module catalog no longer repeats the module list as body cards');
like($modules_admin_html, qr/href="\/admin\/settings\/modules\/showcase"/, 'module catalog links to Showcase settings');
my $showcase_settings_html = _capture_response(sub {
    $app->_module_showcase_settings_page(undef, { username => 'admin', role => 'owner' }, 'showcase-session');
});
like($showcase_settings_html, qr/module-section-nav" aria-label="Showcase setup sections".*href="\#showcase-status">Status<\/a>.*href="\#showcase-copy">Page Copy<\/a>/s, 'showcase settings expose local section navigation');
like($showcase_settings_html, qr/id="showcase-status".*id="showcase-copy"/s, 'showcase settings navigation targets stable sections');

my $new_post_form = _capture_content_form($app, undef, 'post');
like($new_post_form, qr/data-location-map/, 'enabled map module shows post location picker');
like($new_post_form, qr/<h2>Map \/ Location<\/h2>/, 'enabled map module uses generalized location panel heading');
like($new_post_form, qr/name="location_kind".*Service area/s, 'enabled map module shows location type selector');

my $located_post = $content->save(
    type => 'post',
    title => 'Mapped Story',
    slug => 'mapped-story',
    body_text => 'Located post.',
    location_enabled => 1,
    location_lat => '34.101234',
    location_lng => '-112.202345',
    location_label => 'Desert wash',
    location_kind => 'venue',
);
$content->publish(id => $located_post->{id});

my $index_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($index_html, qr{href="https://example\.test/shop">Shop / Catalog</a>}, 'shop module appears as /shop route');
like($index_html, qr{href="/map/"}, 'map module appears in navigation');
ok(-f File::Spec->catfile($root, 'public', 'map', 'index.html'), 'map page is generated');
ok(-f File::Spec->catfile($root, 'public', 'assets', 'map-pins.json'), 'map data is generated');
my $map_data = decode_json(_read(File::Spec->catfile($root, 'public', 'assets', 'map-pins.json')));
is($map_data->{pins}[0]{kind}, 'venue', 'location type survives publish into map pin JSON');
is($map_data->{pins}[0]{kind_label}, 'Venue', 'location type label survives publish into map pin JSON');
my $map_settings_html = _capture_response(sub {
    $app->_module_map_settings_page(undef, { username => 'admin' }, 'map-settings-session');
});
like($map_settings_html, qr/<h1>Map \/ Locations<\/h1>/, 'map settings use Map / Locations heading');
like($map_settings_html, qr/stores, venues, project locations, historical sites, event locations, service areas/, 'map settings explain generalized location uses');
like($map_settings_html, qr/module-section-nav" aria-label="Map \/ Locations setup sections".*href="\#map-status">Status<\/a>.*href="\#map-tiles">Tiles<\/a>.*href="\#map-default-view">Default View<\/a>/s, 'map settings expose local section navigation');
like($map_settings_html, qr/id="map-status".*id="map-tiles".*id="map-default-view"/s, 'map settings navigation targets stable sections');

my $asset_path = '/assets/media/' . ('a' x 64) . '.jpg';
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description, mime_type, width, height, bytes, checksum_sha256, created_at)
        VALUES
            ('portfolio-image.jpg', ?, ?, 'First Portfolio Image', 'Search Title Asset', 'A showcase search description for this media asset.', 'image/jpeg', 1200, 900, 12345, ?, ?)
    },
    undef,
    "$root/originals/portfolio-image.jpg",
    $asset_path,
    'b' x 64,
    time
);
my $resource_path = '/assets/resources/' . ('c' x 64) . '.pdf';
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description, mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
        VALUES
            ('archive-packet.pdf', ?, ?, '', 'Archive Packet', '', 'application/pdf', NULL, NULL, 54321, ?, ?, ?)
    },
    undef,
    "$root/originals/archive-packet.pdf",
    $resource_path,
    'd' x 64,
    encode_json({
        preview => {
            type_label => 'PDF document',
            snippet    => 'A public archive packet for venue and collection context.',
        },
        public_resource => {
            path       => $resource_path,
            filename   => 'archive-packet.pdf',
            extension  => 'PDF',
            label      => 'PDF document',
            byte_label => '53.0 KB',
            bytes      => 54321,
        },
    }),
    time
);
DesertCMS::Settings::set_many($config, $db, {
    module_gallery_enabled => 1,
    module_forms_enabled   => 1,
    module_docs_enabled    => 1,
    gallery_title          => 'Portfolio',
    forms_title            => 'Contact',
    docs_title             => 'Docs',
});
$content->rebuild_all;

$settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'gallery'), 'showcase module can be enabled');
ok(DesertCMS::Modules::enabled($settings, 'forms'), 'forms module can be enabled');
ok(DesertCMS::Modules::enabled($settings, 'docs'), 'docs module can be enabled');

$index_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($index_html, qr{href="/showcase/"}, 'enabled showcase appears in navigation');
unlike($index_html, qr{href="/gallery/"}, 'enabled showcase navigation does not use legacy gallery path');
like($index_html, qr{href="/forms/"}, 'enabled forms appears in navigation');
like($index_html, qr{href="/docs/"}, 'enabled docs appears in navigation');
ok(-f File::Spec->catfile($root, 'public', 'showcase', 'index.html'), 'showcase page is generated');
ok(-f File::Spec->catfile($root, 'public', 'gallery', 'index.html'), 'legacy gallery redirect is generated');
my $showcase_html = _read(File::Spec->catfile($root, 'public', 'showcase', 'index.html'));
like($showcase_html, qr/module-page showcase-page/, 'showcase page uses Showcase module page class');
like($showcase_html, qr/Search Title Asset/, 'showcase renders media search title when present');
like($showcase_html, qr/A showcase search description for this media asset\./, 'showcase renders media search description when present');
like($showcase_html, qr/alt="First Portfolio Image"/, 'showcase keeps alt text for image context');
like($showcase_html, qr/Archive Packet/, 'showcase renders public resource downloads');
like($showcase_html, qr/showcase-resource-badge[^>]*>.*PDF/s, 'showcase renders resource file badge');
like($showcase_html, qr/A public archive packet for venue and collection context\./, 'showcase renders public resource preview snippets');
my $legacy_gallery_html = _read(File::Spec->catfile($root, 'public', 'gallery', 'index.html'));
like($legacy_gallery_html, qr/showcase-legacy-redirect/, 'legacy gallery URL is a redirect page');
like($legacy_gallery_html, qr{url=https://example\.test/showcase/}, 'legacy gallery redirect points to Showcase');
ok(-f File::Spec->catfile($root, 'public', 'docs', 'index.html'), 'docs index is generated');
ok(-f File::Spec->catfile($root, 'public', 'docs', 'install', 'index.html'), 'markdown doc page is generated');
ok(-f File::Spec->catfile($root, 'public', 'docs', 'site', 'index.html'), 'site-management markdown doc page is generated');
ok(-f File::Spec->catfile($root, 'public', 'docs', 'faq', 'index.html'), 'FAQ resource page is generated');
ok(-f File::Spec->catfile($root, 'public', 'docs', 'archive', 'town-history', 'index.html'), 'local archive resource page is generated');
ok(!-e File::Spec->catfile($root, 'public', 'docs', 'members', 'benefits', 'index.html'), 'member-only resource page is not generated publicly');
my $docs_index_html = _read(File::Spec->catfile($root, 'public', 'docs', 'index.html'));
like($docs_index_html, qr/docs-audience-heading">Site Management<\/h2>.*docs-audience-heading">Technical<\/h2>/s, 'docs index groups pages by audience with site-management first');
like($docs_index_html, qr/href="\/docs\/site\/".*Site Guide.*href="\/docs\/install\/".*Install Guide/s, 'docs index links grouped docs');
like($docs_index_html, qr/<p class="kicker">Resource Hub<\/p>/, 'docs index presents Resource Hub product framing');
like($docs_index_html, qr/docs-hub-panel.*Resources.*4.*Sections.*3.*Resource types.*4/s, 'docs index summarizes resource hub inventory');
like($docs_index_html, qr/docs-hub-strip.*Guides.*Local archives.*Member resources.*FAQs.*Help centers/s, 'docs index advertises broader resource hub use cases');
like($docs_index_html, qr/docs-type-pill">Guide<\/span>/, 'docs cards render guide resource type badge');
like($docs_index_html, qr/docs-type-pill">FAQ<\/span>/, 'docs cards render FAQ resource type badge');
like($docs_index_html, qr/docs-type-pill">Local Archive<\/span>/, 'docs cards render local archive resource type badge');
like($docs_index_html, qr/docs-card-tags.*OpenBSD.*Install/s, 'docs cards render resource tags');
unlike($docs_index_html, qr/Member Benefits Packet|Members only/, 'docs index does not expose member-only resources');
unlike($docs_index_html, qr/Markdown source|docs-src|install\.md/, 'docs index does not expose backend source paths');
my $docs_admin_html = _capture_response(sub {
    $app->_module_docs_settings_page(undef, { username => 'admin' }, 'docs-session');
});
like($docs_admin_html, qr/5 resource files/, 'admin Resource Hub catalog counts every markdown resource');
like($docs_admin_html, qr/4 public pages/, 'admin Resource Hub catalog counts generated public pages');
like($docs_admin_html, qr/1 held resource/, 'admin Resource Hub catalog counts held resources');
like($docs_admin_html, qr/Member Benefits Packet.*Held in admin/s, 'admin Resource Hub catalog keeps member-only resources visible without a public URL');
like($docs_admin_html, qr/module-section-nav" aria-label="Docs \/ Resource Hub setup sections".*href="\#docs-status">Status<\/a>.*href="\#docs-copy">Copy &amp; Source<\/a>.*href="\#docs-catalog">Resource Catalog<\/a>/s, 'admin Resource Hub settings expose local section navigation');
like($docs_admin_html, qr/id="docs-status".*id="docs-copy".*id="docs-catalog"/s, 'admin Resource Hub settings navigation targets stable sections');
my $docs_html = _read(File::Spec->catfile($root, 'public', 'docs', 'install', 'index.html'));
like($docs_html, qr/Install Guide/, 'docs page renders markdown heading');
like($docs_html, qr/<p class="kicker">Guide<\/p>/, 'docs page uses the resource type as the article kicker');
like($docs_html, qr/docs-meta-strip.*Section.*Technical.*Access.*Public.*Updated.*2026-07-01.*Tags.*OpenBSD, Install/s, 'docs page renders resource metadata strip');
unlike($docs_html, qr/docs-source-label|Source:|install\.md/, 'docs page does not expose source filename metadata publicly');
like($docs_html, qr/docs-nav-group-title">Site Management<\/span>.*docs-nav-group-title">Technical<\/span>/s, 'docs page navigation groups pages by audience');
like($docs_html, qr/<code>doas<\/code>/, 'docs page renders inline code');
like($docs_html, qr/class="language-sh"/, 'docs page renders fenced code language');
like($docs_html, qr/&lt;script&gt;alert\(1\)&lt;\/script&gt;/, 'docs page escapes raw HTML');
make_path(File::Spec->catdir($root, 'public', 'docs', 'old-guide'));
_write(
    File::Spec->catfile($root, 'public', 'docs', 'old-guide', 'index.html'),
    '<article class="content module-page docs-page"><h1>Old generated docs</h1></article>'
);
$content->rebuild_all;
ok(!-e File::Spec->catfile($root, 'public', 'docs', 'old-guide', 'index.html'), 'docs rebuild removes stale generated docs pages');

my $sitemap_xml = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
like($sitemap_xml, qr{<loc>https://example\.test/showcase/</loc>}, 'enabled showcase is added to sitemap');
unlike($sitemap_xml, qr{<loc>https://example\.test/gallery/</loc>}, 'legacy gallery redirect is not added to sitemap');
like($sitemap_xml, qr{<loc>https://example\.test/forms/</loc>}, 'enabled forms are added to sitemap');
like($sitemap_xml, qr{<loc>https://example\.test/docs/</loc>}, 'enabled docs index is added to sitemap');
like($sitemap_xml, qr{<loc>https://example\.test/docs/install/</loc>}, 'enabled docs page is added to sitemap');
like($sitemap_xml, qr{<loc>https://example\.test/docs/site/</loc>}, 'enabled site-management docs page is added to sitemap');
like($sitemap_xml, qr{<loc>https://example\.test/docs/faq/</loc>}, 'enabled FAQ resource page is added to sitemap');
like($sitemap_xml, qr{<loc>https://example\.test/docs/archive/town-history/</loc>}, 'enabled local archive resource page is added to sitemap');
unlike($sitemap_xml, qr{<loc>https://example\.test/docs/members/benefits/</loc>}, 'member-only resource page is not added to sitemap');

DesertCMS::Navigation::replace_from_text(
    $config,
    $db,
    "Home | /\nMap | /map/\nShowcase | /showcase/\nLegacy Gallery | /gallery/\nForms | /forms/\nContributors | /contributors/\nDocs | /docs/"
);

DesertCMS::Settings::set_many($config, $db, {
    module_map_enabled     => 0,
    module_shop_enabled    => 0,
    module_gallery_enabled => 0,
    module_forms_enabled   => 0,
    module_contributor_requests_enabled => 0,
    module_docs_enabled    => 0,
    shop_enabled           => 0,
});
$content->rebuild_all;

$settings = DesertCMS::Settings::all($config, $db);
ok(!DesertCMS::Modules::enabled($settings, 'map'), 'map module can be disabled');
ok(!DesertCMS::Modules::enabled($settings, 'shop'), 'shop module can be disabled');
ok(!DesertCMS::Modules::enabled($settings, 'gallery'), 'showcase module can be disabled');
ok(!DesertCMS::Modules::enabled($settings, 'forms'), 'forms module can be disabled');
ok(!DesertCMS::Modules::enabled($settings, 'contributor_requests'), 'contributor requests module can be disabled');
ok(!DesertCMS::Modules::enabled($settings, 'docs'), 'docs module can be disabled');

$new_post_form = _capture_content_form($app, undef, 'post');
unlike($new_post_form, qr/data-location-map/, 'disabled map module hides post location picker');
unlike($new_post_form, qr/name="location_enabled"/, 'disabled map module hides location inputs');

_capture_response(sub {
    $app->_content_update(
        Local::ModuleRequest->new({
            type => 'post',
            title => 'Mapped Story Updated',
            slug => 'mapped-story',
            body_text => 'Updated located post.',
            excerpt => '',
            meta_title => '',
            meta_description => '',
            canonical_url => '',
            feature_image_path => '',
            tags_text => '',
            collections_text => '',
        }),
        { username => 'admin' },
        's' x 64,
        $located_post->{id},
    );
});
my $location_row = $db->dbh->selectrow_hashref(
    'SELECT location_enabled, location_lat, location_lng, location_label, location_kind FROM content_items WHERE id = ?',
    undef,
    $located_post->{id}
);
is($location_row->{location_enabled}, 1, 'disabled map module preserves existing location enabled flag on save');
is(sprintf('%.6f', $location_row->{location_lat}), '34.101234', 'disabled map module preserves existing latitude on save');
is(sprintf('%.6f', $location_row->{location_lng}), '-112.202345', 'disabled map module preserves existing longitude on save');
is($location_row->{location_label}, 'Desert wash', 'disabled map module preserves existing location label on save');
is($location_row->{location_kind}, 'venue', 'disabled map module preserves existing location type on save');

$index_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
unlike($index_html, qr{href="https://example\.test/shop"}, 'disabled shop module leaves navigation');
unlike($index_html, qr{href="/map/"}, 'disabled map module leaves navigation');
unlike($index_html, qr{href="/showcase/"}, 'disabled showcase module leaves navigation');
unlike($index_html, qr{href="/gallery/"}, 'disabled showcase module removes legacy gallery navigation');
unlike($index_html, qr{href="/forms/"}, 'disabled forms module leaves navigation');
unlike($index_html, qr{href="/contributors/"}, 'disabled contributor requests module leaves navigation');
unlike($index_html, qr{href="/docs/"}, 'disabled docs module leaves navigation');
ok(!-e File::Spec->catfile($root, 'public', 'map', 'index.html'), 'disabled map removes map page');
ok(!-e File::Spec->catfile($root, 'public', 'assets', 'map-pins.json'), 'disabled map removes map data');
ok(!-e File::Spec->catfile($root, 'public', 'showcase', 'index.html'), 'disabled showcase removes showcase page');
ok(!-e File::Spec->catfile($root, 'public', 'gallery', 'index.html'), 'disabled showcase removes legacy gallery redirect');
ok(!-e File::Spec->catfile($root, 'public', 'contributors', 'index.html'), 'disabled contributor requests removes contributors page');
ok(!-e File::Spec->catfile($root, 'public', 'contributors', 'apply', 'index.html'), 'disabled contributor requests removes apply page');
ok(!-e File::Spec->catfile($root, 'public', 'docs', 'index.html'), 'disabled docs removes docs index');

$sitemap_xml = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
unlike($sitemap_xml, qr{<loc>https://example\.test/map/</loc>}, 'disabled map is removed from sitemap');
unlike($sitemap_xml, qr{<loc>https://example\.test/showcase/</loc>}, 'disabled showcase is removed from sitemap');
unlike($sitemap_xml, qr{<loc>https://example\.test/gallery/</loc>}, 'disabled showcase keeps legacy gallery out of sitemap');
unlike($sitemap_xml, qr{<loc>https://example\.test/forms/</loc>}, 'disabled forms are removed from sitemap');
unlike($sitemap_xml, qr{<loc>https://example\.test/contributors/</loc>}, 'disabled contributors page is removed from sitemap');
unlike($sitemap_xml, qr{<loc>https://example\.test/docs/</loc>}, 'disabled docs is removed from sitemap');

my $contrib_config_path = "$root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Feature Test
site_url = https://feature.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
contributor_site_id = feature
contributor_domain = feature.example.test
secure_cookies = 0
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        map => 1,
        shop => 0,
        shop_payments => 0,
        gallery => 1,
        forms => 0,
        contributor_requests => 0,
        docs => 0,
        resource_publishing => 0,
    }),
    module_map_enabled => 1,
    module_forms_enabled => 1,
    module_docs_enabled => 1,
    module_resource_publishing_enabled => 1,
});
$settings = DesertCMS::Settings::all($config, $db);
my $feature_catalog = DesertCMS::Modules::catalog($settings, config => $contrib_config);
my %feature_by_key = map { $_->{key} => $_ } @{$feature_catalog};
ok($feature_by_key{map}{available}, 'plan catalog marks included feature as available');
ok($feature_by_key{map}{enabled}, 'plan catalog marks included enabled feature as enabled');
ok($feature_by_key{forms}{locked_by_plan}, 'plan catalog marks excluded feature as locked by plan');
ok($feature_by_key{forms}{requires_upgrade}, 'plan catalog marks excluded feature as requiring upgrade');
ok(!$feature_by_key{forms}{enabled}, 'plan catalog disables locked feature effectively');
ok($feature_by_key{shop_payments}{locked_by_plan}, 'plan catalog marks Shop Payments as locked by plan');
ok($feature_by_key{resource_publishing}{locked_by_plan}, 'plan catalog marks Resource Downloads as locked by plan');
ok(!$feature_by_key{resource_publishing}{enabled}, 'plan catalog disables locked Resource Downloads effectively');
ok($feature_by_key{contributor_requests}{managed_by_master}, 'plan catalog marks contributor requests as master-managed in subCMS');
ok(!DesertCMS::Modules::enabled($settings, 'forms'), 'locked feature is not effectively enabled');
ok(!DesertCMS::Modules::enabled($settings, 'resource_publishing'), 'locked Resource Downloads is not effectively enabled');

local $app->{config} = $contrib_config;
my $feature_catalog_html = _capture_response(sub {
    $app->_settings_modules_page(undef, { username => 'admin', role => 'owner' }, 'modules-session');
});
like($feature_catalog_html, qr/<h1>Features<\/h1>/, 'contributor feature catalog uses product heading');
like($feature_catalog_html, qr/<a href="\/admin\/settings\/modules" class="active" aria-current="page">Features<\/a>/, 'contributor feature catalog marks Features active in product navigation');
unlike($feature_catalog_html, qr/<nav class="editor-nav" aria-label="Site builder sections">/, 'contributor feature catalog does not borrow site builder navigation');
like($feature_catalog_html, qr/module-catalog-landing" id="module-catalog-workspace".*<h2>Feature setup<\/h2>/s, 'contributor feature catalog renders one setup workspace below the grouped nav');
like($feature_catalog_html, qr/Locked by plan.*<strong>\d+<\/strong>/s, 'contributor feature catalog summary still reports locked feature counts');
unlike($feature_catalog_html, qr/module-card-kicker|Save features and rebuild|data-feature-key=|View upgrade options/, 'contributor feature catalog no longer repeats plan features as body cards');
unlike($feature_catalog_html, qr/<h1>Modules<\/h1>|Managed by master|master CMS|contributor CMS/, 'contributor feature catalog avoids backend module/master language');
my $contributor_module_detail_nav = DesertCMS::App::_editor_nav('events', $contrib_config, { role => 'owner' });
is($contributor_module_detail_nav, '', 'contributor feature detail pages do not render site builder peer navigation');
my $contributor_feature_setup_nav = _capture_response(sub {
    print $app->_module_setup_nav('map', { username => 'admin', role => 'owner' }, $settings);
});
like($contributor_feature_setup_nav, qr/module-setup-nav" aria-label="Feature setup pages"><a href="\/admin\/settings\/modules" class="module-setup-nav-home"><strong>Features<\/strong><small>Feature Catalog<\/small><span>Plan feature parent<\/span><\/a><span class="module-setup-nav-groups">.*data-module-setup-group="tools".*<span class="module-setup-nav-group-title">Site Tools<\/span>.*href="\/admin\/settings\/modules\/map" class="active" aria-current="page">Map \/ Locations<\/a>.*href="\/admin\/settings\/modules\/showcase">Showcase<\/a>/s, 'contributor feature setup nav is plan-aware, grouped, and product-labeled');
unlike($contributor_feature_setup_nav, qr/>Forms<\/a>|>Docs \/ Resource Hub<\/a>|>Shop Payments<\/a>/, 'contributor feature setup nav omits locked features and payment entitlements');
my $contributor_dashboard_html = _capture_response(sub {
    $app->_contributor_dashboard(undef, { username => 'admin', role => 'owner' }, 'dashboard-session');
});
like($contributor_dashboard_html, qr/<h1>Home<\/h1>/, 'contributor dashboard renders product home');
like($contributor_dashboard_html, qr/<h2>Usage<\/h2>/, 'contributor dashboard exposes plan usage');
like($contributor_dashboard_html, qr/<h2>Quick Edit<\/h2>/, 'contributor dashboard exposes quick edit actions');
like($contributor_dashboard_html, qr/<h2>Recent Content<\/h2>/, 'contributor dashboard exposes recent content');
like($contributor_dashboard_html, qr/Upload media/, 'contributor dashboard includes upload shortcut');
like($contributor_dashboard_html, qr/<h2>Setup Checklist<\/h2>/, 'contributor dashboard exposes onboarding checklist');
like($contributor_dashboard_html, qr/<h2>Upgrade Suggestions<\/h2>/, 'contributor dashboard exposes upgrade suggestions');
like($contributor_dashboard_html, qr/Unlock Forms/, 'contributor dashboard suggests locked feature upgrades');
like($contributor_dashboard_html, qr/Requires upgrade/, 'contributor dashboard shows locked feature state');
unlike($contributor_dashboard_html, qr/<h2>Last 7 Days<\/h2>/, 'contributor dashboard does not show analytics landing chart');
unlike($contributor_dashboard_html, qr/<h2>Visits Per IP<\/h2>/, 'contributor dashboard does not show backend analytics table');
unlike($contributor_dashboard_html, qr/master CMS|contributor CMS/, 'contributor dashboard avoids CMS control-plane language');
my $contributor_map_html = _capture_response(sub {
    $app->_module_map_settings_page(undef, { username => 'admin', role => 'owner' }, 'map-session');
});
like($contributor_map_html, qr/<p class="eyebrow">Feature<\/p>/, 'contributor feature setup uses feature eyebrow');
like($contributor_map_html, qr/Save locations settings and rebuild/, 'contributor feature setup uses settings save label');
unlike($contributor_map_html, qr/Map Module|Save map module|story/, 'contributor feature setup avoids module title and story copy');
_capture_response(sub {
    $app->_settings_modules_save(
        Local::ModuleRequest->new({
            module_map_enabled => 1,
            module_gallery_enabled => 1,
        }),
        { username => 'admin', role => 'owner' },
        's' x 64,
    );
});
$settings = DesertCMS::Settings::all($config, $db);
is($settings->{module_forms_enabled}, 1, 'locked feature save preserves configured value');
ok(!DesertCMS::Modules::enabled($settings, 'forms'), 'locked feature remains effectively disabled after save');

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

sub _capture_content_form {
    my ($app, $id, $default_type) = @_;
    return _capture_response(sub {
        $app->_content_form(
            Local::ModuleRequest->new({}),
            { username => 'admin' },
            's' x 64,
            $id,
            $default_type,
        );
    });
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
