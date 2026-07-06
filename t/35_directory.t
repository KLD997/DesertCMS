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
use DesertCMS::Directory;
use DesertCMS::HTTP;
use DesertCMS::Modules;
use DesertCMS::Renderer;
use DesertCMS::Settings;

{
    package Local::DirectoryRequest;
    sub new {
        my ($class, $form) = @_;
        return bless { form => $form || {}, query => $form || {} }, $class;
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
make_path("$root/public/assets/media", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Directory Test
site_url = https://directory.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
secure_cookies = 0
CONF

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
my $content = DesertCMS::Content->new(config => $config, db => $db);

my $home = $content->save(
    type      => 'page',
    title     => 'Home',
    slug      => 'home',
    body_text => 'Directory home.',
);
$content->publish(id => $home->{id});

DesertCMS::Settings::set_many($config, $db, {
    module_directory_enabled => 1,
    module_map_enabled       => 1,
    directory_title          => 'Community Directory',
    directory_intro          => 'People, businesses, venues, members, places, and resources.',
    directory_submissions_enabled => 1,
});

my $settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'directory'), 'directory feature can be enabled independently');
my $catalog = DesertCMS::Modules::catalog($settings, config => $config);
like(_module_catalog_text($catalog), qr/Directory.*people, businesses, artists, contributors, vendors, members, places, organizations, and resources/s, 'feature catalog describes Directory');

my $directory = DesertCMS::Directory->new(config => $config, db => $db);
my $directory_image_hash = 'c' x 64;
my $directory_image_path = "/assets/media/$directory_image_hash.png";
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
        VALUES
            (?, ?, ?, ?, ?, ?, 'image/png', 1200, 600, 2048, ?, ?, ?)
    },
    undef,
    'directory-entry.png',
    "$root/originals/directory-entry.png",
    $directory_image_path,
    'Directory listing art',
    'Directory listing art',
    'A transparent PNG directory image.',
    $directory_image_hash,
    encode_json({
        sizes => [
            { label => 'w480', path => "/assets/media/$directory_image_hash-480.png", width => 480, height => 240 },
            { label => 'display', path => $directory_image_path, width => 1200, height => 600 },
        ],
        aspect_ratio => '2.000000',
    }),
    time,
);
my $entry = $directory->save_entry(
    title            => 'Civic Arts Center',
    slug             => 'civic-arts-center',
    kind             => 'place',
    status           => 'published',
    summary          => 'A venue and resource for public workshops.',
    body             => "Open studios and community programs.\nAccessible entrance on Main Street.",
    email            => 'hello@arts.example.test',
    phone            => '555-0100',
    website_url      => 'https://arts.example.test',
    categories_text  => 'Venues, Resources',
    tags_text        => 'arts, workshops',
    featured         => 1,
    image_path       => $directory_image_path,
    location_enabled => 1,
    location_lat     => '34.101234',
    location_lng     => '-112.202345',
    location_label   => 'Civic Hall',
    location_kind    => 'venue',
);
ok($entry->{id}, 'directory entry is saved');
is($entry->{kind}, 'place', 'directory entry stores entry kind');
my $stale_image_path = '/assets/media/stale-directory.png';
my $stale_entry = $directory->save_entry(
    title      => 'Broken Listing',
    slug       => 'broken-listing',
    kind       => 'resource',
    status     => 'published',
    summary    => 'This entry keeps a stale image reference.',
    image_path => $stale_image_path,
);
ok($stale_entry->{id}, 'directory entry with stale image reference is saved');

$content->rebuild_all;
ok(-f File::Spec->catfile($root, 'public', 'directory', 'index.html'), 'directory index is generated');
ok(-f File::Spec->catfile($root, 'public', 'directory', 'civic-arts-center', 'index.html'), 'directory detail page is generated');
ok(-f File::Spec->catfile($root, 'public', 'directory', 'submit', 'index.html'), 'directory submission page is generated when enabled');

my $index_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($index_html, qr{href="/directory/"}, 'enabled Directory appears in public navigation');
like($index_html, qr{Community Directory}, 'public navigation uses configured Directory title');

my $directory_html = _read(File::Spec->catfile($root, 'public', 'directory', 'index.html'));
like($directory_html, qr{Civic Arts Center}, 'directory index renders published entry');
like($directory_html, qr{Place}, 'directory index renders entry type label');
like($directory_html, qr{Suggest a listing}, 'directory index links public submission page');
like($directory_html, qr{<img src="/assets/media/c{64}\.png" alt="Directory listing art" loading="lazy" decoding="async" width="1200" height="600" srcset="[^"]*/assets/media/c{64}-480\.png 480w[^"]*/assets/media/c{64}\.png 1200w" sizes="\(max-width: 760px\) 100vw, 360px" class="public-media-img">}, 'directory index renders responsive listing media');
unlike($directory_html, qr/\Q$stale_image_path\E/, 'directory index hides stale image references');

my $detail_html = _read(File::Spec->catfile($root, 'public', 'directory', 'civic-arts-center', 'index.html'));
like($detail_html, qr{Civic Arts Center}, 'directory detail renders title');
like($detail_html, qr{hello\@arts\.example\.test}, 'directory detail renders contact email');
like($detail_html, qr{Civic Hall}, 'directory detail renders location label');
like($detail_html, qr{View location}, 'directory detail links to map when coordinates exist');
like($detail_html, qr{Venues}, 'directory detail renders categories');
like($detail_html, qr{<img src="/assets/media/c{64}\.png" alt="Directory listing art" loading="eager" decoding="async" width="1200" height="600" srcset="[^"]*/assets/media/c{64}-480\.png 480w[^"]*/assets/media/c{64}\.png 1200w" sizes="\(max-width: 760px\) 100vw, 720px" class="directory-detail-image public-media-img">}, 'directory detail renders responsive media without broken fallbacks');

my $sitemap = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
like($sitemap, qr{https://directory\.example\.test/directory/</loc>}, 'sitemap includes directory index');
like($sitemap, qr{https://directory\.example\.test/directory/civic-arts-center/</loc>}, 'sitemap includes directory detail');
like($sitemap, qr{https://directory\.example\.test/directory/submit/</loc>}, 'sitemap includes directory submission page when enabled');

my $map_data = decode_json(_read(File::Spec->catfile($root, 'public', 'assets', 'map-pins.json')));
my ($directory_pin) = grep { ($_->{type} || '') eq 'directory' } @{ $map_data->{pins} || [] };
ok($directory_pin, 'directory entry appears in map pin JSON');
is($directory_pin->{kind}, 'venue', 'directory map pin keeps location kind');
is($directory_pin->{kind_label}, 'Venue', 'directory map pin includes kind label');
is($directory_pin->{url}, '/directory/civic-arts-center/', 'directory map pin links to entry URL');

my $app = DesertCMS::App->new;
my $public_directory = _capture_response(sub {
    $app->_dispatch_directory(_directory_request('/directory'));
});
like($public_directory, qr{Civic Arts Center}, 'public /directory route renders entry list');
like($public_directory, qr{<script src="/assets/site\.js"></script>}, 'dynamic /directory route uses the public shell script');
unlike($public_directory, qr{/admin/assets/admin\.css}, 'dynamic /directory route does not load admin CSS');
like($public_directory, qr{<img src="/assets/media/c{64}\.png" alt="Directory listing art" loading="lazy" decoding="async" width="1200" height="600" srcset="[^"]*/assets/media/c{64}-480\.png 480w[^"]*/assets/media/c{64}\.png 1200w" sizes="\(max-width: 760px\) 100vw, 360px" class="public-media-img">}, 'dynamic /directory route renders responsive listing media');
unlike($public_directory, qr/\Q$stale_image_path\E/, 'dynamic /directory route hides stale image references');
my $public_detail = _capture_response(sub {
    $app->_dispatch_directory(_directory_request('/directory/civic-arts-center'));
});
like($public_detail, qr{Open studios and community programs}, 'public directory detail route renders entry body');
like($public_detail, qr{<img src="/assets/media/c{64}\.png" alt="Directory listing art" loading="eager" decoding="async" width="1200" height="600" srcset="[^"]*/assets/media/c{64}-480\.png 480w[^"]*/assets/media/c{64}\.png 1200w" sizes="\(max-width: 760px\) 100vw, 720px" class="directory-detail-image public-media-img">}, 'dynamic directory detail renders responsive media');

my $submit_response = _capture_response(sub {
    $app->_dispatch_directory(_directory_request('/directory/submit', 'POST', {
        title           => 'Pending Vendor',
        kind            => 'vendor',
        email           => 'vendor@example.test',
        website_url     => 'https://vendor.example.test',
        summary         => 'Suggested public vendor listing.',
        submission_note => 'Please review this vendor.',
    }));
});
like($submit_response, qr{received for review}, 'public directory submission confirms moderation');
my ($pending_count) = $db->dbh->selectrow_array(
    q{SELECT COUNT(*) FROM directory_entries WHERE status = 'pending' AND source = 'public_submission'}
);
is($pending_count, 1, 'public submission creates pending directory entry');

my $admin_html = _capture_response(sub {
    $app->_module_directory_settings_page(undef, { username => 'admin', role => 'owner' }, 'directory-session');
});
like($admin_html, qr/<h1>Directory<\/h1>/, 'admin Directory surface renders');
like($admin_html, qr/module-section-nav" aria-label="Directory setup sections".*href="\#module-settings">Settings<\/a>.*href="\#module-entries">Entries<\/a>/s, 'admin Directory surface exposes local section navigation');
like($admin_html, qr{<code>/directory/</code>}, 'admin Directory surface shows public path');
like($admin_html, qr{Civic Arts Center}, 'admin Directory table lists published entries');
like($admin_html, qr{Pending Vendor}, 'admin Directory table lists pending public submissions');
like($admin_html, qr{Export CSV}, 'admin Directory surface exposes CSV export');
like($admin_html, qr/content-table compact-table admin-card-table/, 'admin Directory table uses responsive card markup');
like($admin_html, qr/data-label="Entry".*data-label="Actions"/s, 'admin Directory rows expose mobile card labels');
my $entry_form_html = _capture_response(sub {
    $app->_directory_form(undef, { username => 'admin', role => 'owner' }, 'directory-session');
});
like($entry_form_html, qr/module-section-nav" aria-label="Directory entry editor sections".*href="\#directory-profile">Profile<\/a>.*href="\#directory-contact">Contact<\/a>.*href="\#directory-categories">Categories<\/a>.*href="\#directory-location">Map \/ Location<\/a>.*href="\#directory-notes">Submission Notes<\/a>/s, 'admin Directory entry editor exposes local section navigation');
like($entry_form_html, qr/id="directory-profile".*id="directory-contact".*id="directory-categories".*id="directory-location".*id="directory-notes"/s, 'admin Directory entry editor section navigation targets stable form anchors');

my $contrib_config_path = "$root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Directory
site_url = https://directory-site.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
contributor_site_id = directory-site
contributor_domain = directory-site.example.test
secure_cookies = 0
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        directory => 0,
        map       => 1,
    }),
    module_directory_enabled => 1,
});
$settings = DesertCMS::Settings::all($config, $db);
my $feature_catalog = DesertCMS::Modules::catalog($settings, config => $contrib_config);
my %feature_by_key = map { $_->{key} => $_ } @{$feature_catalog};
ok($feature_by_key{directory}{locked_by_plan}, 'contributor feature catalog can lock Directory by plan');
ok(!$feature_by_key{directory}{enabled}, 'locked Directory is not effectively enabled');

local $app->{config} = $contrib_config;
my $feature_catalog_html = _capture_response(sub {
    $app->_settings_modules_page(undef, { username => 'admin', role => 'owner' }, 'modules-session');
});
like($feature_catalog_html, qr/module-catalog-landing" id="module-catalog-workspace".*<h2>Feature setup<\/h2>/s, 'feature catalog renders one setup workspace below the grouped nav');
unlike($feature_catalog_html, qr/data-feature-key=|module-card-kicker/, 'feature catalog no longer repeats locked Directory as a body card');
unlike($feature_catalog_html, qr/master CMS|contributor CMS/, 'contributor feature catalog avoids backend CMS terminology');

done_testing;

sub _directory_request {
    my ($path, $method, $form) = @_;
    return bless {
        method => $method || 'GET',
        path   => $path || '/directory',
        host   => 'directory.example.test',
        form   => $form || {},
        query  => $form || {},
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
