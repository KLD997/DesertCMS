use strict;
use warnings;
use Test::More;
use File::Find;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use Cwd qw(getcwd);
use JSON::PP qw(decode_json);
use MIME::Base64 qw(encode_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::Settings;

{
    package Local::SettingsRequest;
    sub new {
        my ($class, $form) = @_;
        return bless { form => $form || {} }, $class;
    }
    sub param {
        my ($self, $key) = @_;
        return $self->{form}{$key};
    }
    sub upload {
        return undef;
    }
}

my $repo = getcwd();
my ($image_tool, $tool_mode) = _find_image_tool($repo);
plan skip_all => 'Image tool not found' unless $image_tool;

$repo =~ s{\\}{/}g;
$image_tool =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/data");

my $source = File::Spec->catfile($root, 'site-image.png');
my @sample_cmd = $tool_mode eq 'vips'
    ? (_sibling_command($image_tool, 'vips'), 'black', $source, 1200, 630, '--bands', 3)
    : _image_tool_cmd($image_tool, $tool_mode, 'convert', '-size', '1200x630', 'xc:#0b6b57', $source);
system @sample_cmd;
is($?, 0, 'created settings image');

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Config Name
site_url = https://archive.example
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
image_tool = $image_tool
secure_cookies = 0
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

my $image = _read_binary($source);
my $favicon_path = DesertCMS::Settings::store_site_image(
    $config,
    kind => 'favicon',
    mime_type => 'image/png',
    content => $image,
);
my $logo_path = DesertCMS::Settings::store_site_image(
    $config,
    kind => 'site_logo',
    mime_type => 'image/png',
    content => $image,
);
my %logo_paths = DesertCMS::Settings::site_logo_derivative_paths();
my $social_path = DesertCMS::Settings::store_site_image(
    $config,
    kind => 'social_image',
    mime_type => 'image/png',
    content => $image,
);
my $background_path = DesertCMS::Settings::store_site_image(
    $config,
    kind => 'site_background',
    mime_type => 'image/png',
    content => $image,
);

DesertCMS::Settings::set_many($config, $db, {
    site_name => 'Settings Name',
    site_description => 'Settings description',
    site_meta_title => 'Default SEO Title',
    site_meta_description => 'Default SEO Description',
    favicon_path => $favicon_path,
    site_logo_path => $logo_path,
    site_logo_nav_path => $logo_paths{site_logo_nav_path},
    site_logo_admin_path => $logo_paths{site_logo_admin_path},
    site_logo_fit => 'cover',
    site_logo_focal_x => '25',
    site_logo_focal_y => '70',
    site_logo_max_width_px => '300',
    site_logo_max_height_px => '80',
    social_image_path => $social_path,
    site_background_image_path => $background_path,
    theme_light_preset => 'light-coast',
    theme_dark_preset => 'dark-forest',
    theme_default_mode => 'dark',
    site_header_layout => 'centered',
    site_brand_display => 'logo-name',
    site_logo_size => 'large',
    site_nav_style => 'pills',
    site_homepage_layout => 'landing',
    site_content_width => 'wide',
    site_spacing_scale => 'spacious',
    site_footer_layout => 'compact',
    site_footer_order => 'nav-brand-credit',
    site_footer_nav_enabled => 0,
    site_footer_description_enabled => 0,
    site_footer_credit => 'Built {{year}} for {{site_name}}',
});

ok(-f "$root/public/assets/site/favicon.png", 'favicon derivative written');
ok(-f "$root/public/assets/site/logo.png", 'logo derivative written');
ok(-f "$root/public/assets/site/logo-nav.png", 'nav logo derivative written');
ok(-f "$root/public/assets/site/logo-admin.png", 'admin logo derivative written');
ok(-f "$root/public/assets/site/social.jpg", 'social derivative written');
ok(-f "$root/public/assets/site/background.jpg", 'background derivative written');
ok(-f "$root/public/assets/site/site-images.json", 'site image manifest written');
my $site_image_manifest = decode_json(_read("$root/public/assets/site/site-images.json"));
is($site_image_manifest->{favicon}{favicon}{width}, 512, 'favicon manifest records predictable width');
is($site_image_manifest->{favicon}{favicon}{height}, 512, 'favicon manifest records predictable height');
is($site_image_manifest->{social_image}{social}{width}, 1200, 'social image manifest records predictable width');
is($site_image_manifest->{social_image}{social}{height}, 630, 'social image manifest records predictable height');
ok(($site_image_manifest->{site_logo}{nav}{width} || 9999) <= 360, 'nav logo manifest records bounded width');
ok(($site_image_manifest->{site_logo}{nav}{height} || 9999) <= 120, 'nav logo manifest records bounded height');
my $relative_thumb = DesertCMS::Settings::_sibling_command('vips', 'vipsthumbnail');
ok($relative_thumb eq 'vipsthumbnail' || $relative_thumb =~ m{(?:^|[\\/])vipsthumbnail(?:\.exe)?\z}, 'settings vips helper resolves to an executable name or path');
_openbsd_sandbox_settings_image_check($config_path, $source) if $^O eq 'openbsd' && $tool_mode eq 'vips';

my $content = DesertCMS::Content->new(config => $config, db => $db);
my $page = $content->save(
    type => 'page',
    title => 'Home',
    slug => 'home',
    body_text => 'Settings SEO body',
);
$content->publish(id => $page->{id});

my $landing = $content->save(
    type => 'page',
    title => 'Landing',
    slug => 'landing',
    body_text => 'Selected homepage body',
);
$content->publish(id => $landing->{id});

DesertCMS::Settings::set_many($config, $db, {
    homepage_content_id => $landing->{id},
});
$content->rebuild_all;

my $html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($html, qr/<title>Landing<\/title>/, 'selected homepage title falls back to content title');
like($html, qr/Selected homepage body/, 'selected homepage renders at root');
like($html, qr/<link rel="canonical" href="https:\/\/archive\.example\/">/, 'selected homepage canonical points at root');
like($html, qr/<meta name="description" content="Default SEO Description">/, 'page uses default meta description');
like($html, qr/<link rel="icon" href="\/assets\/site\/favicon\.png" sizes="512x512">/, 'page includes favicon link with generated dimensions');
like($html, qr/<meta property="og:image" content="https:\/\/archive\.example\/assets\/site\/social\.jpg">/, 'page uses default social image');
like($html, qr/<img class="site-logo" src="\/assets\/site\/logo-nav\.png" alt="Settings Name" decoding="async" width="\d+" height="\d+">/, 'page uses generated nav logo derivative with dimensions');
like($html, qr/<body class="[^"]*site-home--landing[^"]*site-width--wide[^"]*site-spacing--spacious[^"]*site-header-layout--centered[^"]*site-nav-style--pills[^"]*site-footer-layout--compact/, 'page includes site customization body classes');
like($html, qr/<header class="site-header site-header--centered site-logo-size--large">/, 'page uses selected header layout and logo size');
like($html, qr/<a class="site-name site-brand--logo-name" href="\/">.*site-brand-text">Settings Name<\/span>/s, 'page can show logo and site name together');
like($html, qr/<nav id="site-primary-nav" class="site-nav site-nav--pills" data-site-menu>/, 'page uses selected navigation style');
like($html, qr/<main class="site-main site-main--home site-main--wide">/, 'page uses selected homepage and width classes');
like($html, qr/<footer class="site-footer site-footer--compact site-footer-order--nav-brand-credit">/, 'page uses selected footer layout and order');
unlike($html, qr/<nav class="site-footer-nav">/, 'footer navigation can be hidden');
like($html, qr/<small class="site-footer-credit">Built \d{4} for Settings Name<\/small>/, 'footer credit supports template variables');
like($html, qr/--site-background-image: url\("\/assets\/site\/background\.jpg"\)/, 'page includes local background image CSS');
like($html, qr/--site-content-width: 1040px;/, 'page includes content width token');
like($html, qr/--site-logo-max-width: 300px;/, 'page includes custom logo max width token');
like($html, qr/--site-logo-max-height: 80px;/, 'page includes custom logo max height token');
like($html, qr/--site-logo-object-fit: cover;/, 'page includes logo fit token');
like($html, qr/--site-logo-object-position: 25% 70%;/, 'page includes logo focal point token');
like($html, qr/:root\[data-theme="light"\] \{[^}]*--paper: #edf7f8;/s, 'settings light theme applies to light mode');
like($html, qr/:root\[data-theme="dark"\] \{[^}]*--paper: #091511;/s, 'settings dark theme applies to dark mode');
like($html, qr/<html[^>]*data-default-theme="dark"[^>]*data-theme="dark"/, 'explicit dark mode becomes the default public mode');
like($html, qr/Settings Name/, 'page uses settings site name');

my $app = DesertCMS::App->new;
my $admin_html = _capture_response(sub {
    $app->_html_response('Admin Brand Test', '<p>Admin body</p>', { username => 'admin' });
});
like($admin_html, qr/<a class="brand" href="\/admin"><img class="admin-brand-logo" src="\/assets\/site\/logo-admin\.png" alt="Settings Name"><\/a>/, 'admin shell uses generated admin logo derivative');
unlike($admin_html, qr/<a class="brand" href="\/admin">Desert Archive<\/a>/, 'admin shell does not hardcode Desert Archive brand');
like($admin_html, qr/<a href="\/admin">Analytics<\/a>/, 'admin shell labels dashboard route as analytics');
like($admin_html, qr/data-admin-menu-toggle/, 'admin shell renders mobile navigation toggle');
unlike($admin_html, qr/>Dashboard<\/a>/, 'admin shell no longer labels analytics as dashboard');

my $active_admin_html = _capture_response(sub {
    $app->_html_response('Analytics', '<p>Admin body</p>', { username => 'admin' });
});
like($active_admin_html, qr/<a href="\/admin" class="active" aria-current="page">Analytics<\/a>/, 'admin primary nav marks active section');

my $settings_html = _capture_response(sub {
    $app->_site_settings_page(undef, { username => 'admin' }, 'settings-session');
});
like($settings_html, qr/<nav class="settings-section-nav"[^>]*>/, 'site settings renders internal section nav');
like($settings_html, qr/href="\/admin\/site-settings\?section=identity" class="active">Identity<\/a>/, 'identity subpage is active by default');
like($settings_html, qr/href="\/admin\/site-settings\?section=search">Search &amp; Discovery<\/a>/, 'section nav links to search page');
like($settings_html, qr/href="\/admin\/site-settings\?section=indexing">Indexing<\/a>/, 'section nav links to indexing page');
like($settings_html, qr/href="\/admin\/site-settings\?section=theme">Theme &amp; Layout<\/a>/, 'section nav links to theme and layout page');
like($settings_html, qr/id="settings-identity".*Site name.*Homepage.*Header logo/s, 'identity page renders identity controls');
like($settings_html, qr/settings-logo-preview-grid.*\/assets\/site\/logo-nav\.png.*\/assets\/site\/logo-admin\.png/s, 'identity page previews generated logo derivatives');
unlike($settings_html, qr/settings-accordion|<details\b|Header layout|Google Search Console|Default search title/, 'identity page does not render accordion or unrelated sections');

my $search_settings_html = _capture_response(sub {
    $app->_site_settings_page(Local::SettingsRequest->new({ section => 'search' }), { username => 'admin' }, 'settings-session');
});
like($search_settings_html, qr/href="\/admin\/site-settings\?section=search" class="active">Search &amp; Discovery<\/a>/, 'search subpage becomes active');
like($search_settings_html, qr/id="settings-search".*Default search title.*Default social image/s, 'search subpage renders search defaults only');
unlike($search_settings_html, qr/Header logo|Header layout|Google Search Console/, 'search subpage omits identity theme and indexing controls');

my $indexing_settings_html = _capture_response(sub {
    $app->_site_settings_page(Local::SettingsRequest->new({ section => 'indexing' }), { username => 'admin' }, 'settings-session');
});
like($indexing_settings_html, qr/id="settings-indexing".*Google Search Console.*IndexNow.*form="search-submit-form"/s, 'indexing subpage contains GSC, IndexNow, and sitemap submit action');

{
    make_path("$root/contrib-public", "$root/contrib-originals", "$root/contrib-backups", "$root/contrib-data");
    my $contrib_config_path = "$root/contributor.conf";
    open my $contrib_fh, '>', $contrib_config_path or die "cannot write $contrib_config_path: $!";
    print {$contrib_fh} <<"CONF";
site_name = Contributor Settings
site_url = https://contributor.example
data_dir = $root/contrib-data
db_path = $root/contrib-data/desertcms.sqlite
app_secret_file = $root/contrib-data/app_secret
public_root = $root/contrib-public
originals_dir = $root/contrib-originals
backup_dir = $root/contrib-backups
theme_dir = $repo/themes
admin_asset_dir = $root/contrib-admin-assets
image_tool = $image_tool
secure_cookies = 0
contributor_site_id = contributor
contributor_domain = contributor.example
CONF
    close $contrib_fh;

    local $ENV{DESERTCMS_CONFIG} = $contrib_config_path;
    my $contrib_config = DesertCMS::Config->load;
    my $contrib_db = DesertCMS::DB->new(config => $contrib_config);
    $contrib_db->migrate;
    DesertCMS::Settings::set_many($contrib_config, $contrib_db, {
        google_search_console_property => 'https://inherited.example/',
        contributor_allow_indexing_override => 0,
    });
    my $contrib_app = DesertCMS::App->new;
    my $contrib_indexing_html = _capture_response(sub {
        $contrib_app->_site_settings_page(Local::SettingsRequest->new({ section => 'indexing' }), { username => 'owner', role => 'owner' }, 'contrib-settings-session');
    });
    like($contrib_indexing_html, qr/Search-engine submission settings are inherited from the platform for this plan/, 'contributor indexing route explains inherited provider settings');
    like($contrib_indexing_html, qr/id="settings-search"/, 'contributor indexing route falls back to search settings');
    unlike($contrib_indexing_html, qr/href="\/admin\/site-settings\?section=indexing"|Google Search Console|IndexNow|form="search-submit-form"/, 'contributor plan without override hides indexing providers and submit controls');

    my $contrib_theme_html = _capture_response(sub {
        $contrib_app->_site_settings_page(Local::SettingsRequest->new({ section => 'theme' }), { username => 'owner', role => 'owner' }, 'contrib-settings-session');
    });
    like($contrib_theme_html, qr/<h1>Design<\/h1>/, 'contributor theme page uses Design heading');
    like($contrib_theme_html, qr/Platform Fonts/, 'contributor theme page presents fonts as platform-managed');
    unlike($contrib_theme_html, qr/OpenBSD Font Packages|Refresh OpenBSD catalog|doas perl/, 'contributor theme page hides platform font worker controls');

    _capture_response(sub {
        $contrib_app->_site_settings_save(
            Local::SettingsRequest->new({
                setting_section => 'indexing',
                google_search_console_property => 'https://custom.example/',
                indexnow_enabled => 1,
                indexnow_key => 'customkey123',
            }),
            { username => 'owner', role => 'owner' },
            'contrib-settings-session',
        );
    });
    my $contrib_settings_after_blocked_save = DesertCMS::Settings::all($contrib_config, $contrib_db);
    is($contrib_settings_after_blocked_save->{google_search_console_property}, 'https://inherited.example/', 'blocked contributor indexing save preserves existing property');
    is($contrib_settings_after_blocked_save->{indexnow_enabled}, 0, 'blocked contributor indexing save does not enable IndexNow');

    DesertCMS::Settings::set_many($contrib_config, $contrib_db, {
        contributor_allow_indexing_override => 1,
    });
    my $contrib_allowed_indexing_html = _capture_response(sub {
        $contrib_app->_site_settings_page(Local::SettingsRequest->new({ section => 'indexing' }), { username => 'owner', role => 'owner' }, 'contrib-settings-session');
    });
    like($contrib_allowed_indexing_html, qr/id="settings-indexing".*Google Search Console.*IndexNow.*form="search-submit-form"/s, 'contributor plan with override exposes indexing controls');
}

my $theme_settings_html = _capture_response(sub {
    $app->_site_settings_page(Local::SettingsRequest->new({ section => 'theme' }), { username => 'admin' }, 'settings-session');
});
like($theme_settings_html, qr/href="\/admin\/site-settings\?section=theme" class="active">Theme &amp; Layout<\/a>/, 'theme subpage becomes active');
like($theme_settings_html, qr/data-theme-panel-nav.*Preview &amp; Colors.*Structure.*Typography.*Footer/s, 'theme subpage renders a tabbed layout nav');
like($theme_settings_html, qr/data-theme-panel="preview".*Live Theme Preview.*data-theme-preview.*theme-preview-device--desktop.*theme-preview-device--mobile/s, 'theme preview panel contains live desktop and mobile previews');
like($theme_settings_html, qr/data-theme-preview-mode-button="light".*data-theme-preview-mode-button="dark"/s, 'theme preview panel contains light and dark preview controls');
like($theme_settings_html, qr/theme-appearance-panel.*Color Theme.*data-theme-vars=/s, 'theme preview panel contains color theme controls');
like($theme_settings_html, qr/data-theme-panel="structure".*Structure &amp; Layout.*Header layout.*Logo fit.*Logo max width px.*Logo focal X.*Homepage layout preset/s, 'theme structure panel contains layout controls');
like($theme_settings_html, qr/data-theme-panel="typography".*Typography &amp; Components.*OpenBSD Font Packages.*Refresh OpenBSD catalog/s, 'theme typography panel contains font and component controls');
like($theme_settings_html, qr/data-theme-panel="footer".*Footer section order/s, 'theme footer panel contains footer controls');
unlike($theme_settings_html, qr/id="settings-layout"|Default search title|Google Search Console/, 'theme subpage does not render old layout group or unrelated sections');
unlike($settings_html, qr/search-submit-panel/, 'site settings no longer renders a bottom search submit panel');
unlike($settings_html, qr/<h2>Submit To Search Engines<\/h2>/, 'site settings does not duplicate submit section heading');
is(() = $settings_html =~ /Save identity and rebuild/g, 1, 'identity subpage has one section-specific save button');

my $indexing_before_identity_save = DesertCMS::Settings::all($config, $db)->{google_search_console_property};
_capture_response(sub {
    $app->_site_settings_save(
        Local::SettingsRequest->new({
            setting_section     => 'identity',
            site_name           => 'Identity Changed',
            site_description    => 'Identity description changed',
            homepage_content_id => $landing->{id},
        }),
        { username => 'admin' },
        'settings-session',
    );
});
my $saved_settings = DesertCMS::Settings::all($config, $db);
is($saved_settings->{site_name}, 'Identity Changed', 'identity subpage save updates identity settings');
is($saved_settings->{site_header_layout}, 'centered', 'identity subpage save preserves theme layout settings');
is($saved_settings->{google_search_console_property}, $indexing_before_identity_save, 'identity subpage save preserves indexing settings');

_capture_response(sub {
    $app->_site_settings_save(
        Local::SettingsRequest->new({
            setting_section          => 'theme',
            site_header_layout       => 'compact',
            site_brand_display       => 'logo',
            site_logo_size           => 'small',
            site_logo_fit            => 'contain',
            site_logo_focal_x        => '110',
            site_logo_focal_y        => '35',
            site_logo_max_width_px   => '90',
            site_logo_max_height_px  => '300',
            site_nav_style           => 'underline',
            site_homepage_layout     => 'standard',
            site_content_width       => 'narrow',
            site_spacing_scale       => 'compact',
            site_footer_layout       => 'minimal',
            site_footer_order        => 'credit-brand-nav',
            theme_heading_font       => 'pkg:noto-fonts',
            theme_body_font          => 'sans',
            theme_ui_font            => 'serif',
            font_package_repo        => 'https://ftp.example/pub/OpenBSD/7.4/packages/amd64/',
            theme_heading_scale      => 'large',
            theme_body_scale         => 'compact',
            theme_button_style       => 'outline',
            theme_button_radius      => 'pill',
            theme_card_style         => 'raised',
            theme_card_radius        => 'round',
            theme_light_preset       => 'light-archive',
            theme_dark_preset        => 'dark-archive',
            theme_default_mode       => 'light',
            theme_custom_name        => 'Bounded Theme',
        }),
        { username => 'admin' },
        'settings-session',
    );
});
my $theme_saved_settings = DesertCMS::Settings::all($config, $db);
is($theme_saved_settings->{site_logo_fit}, 'contain', 'theme save stores logo fit');
is($theme_saved_settings->{site_logo_focal_x}, 50, 'theme save resets out-of-range focal X');
is($theme_saved_settings->{site_logo_focal_y}, 35, 'theme save stores bounded focal Y');
is($theme_saved_settings->{site_logo_max_width_px}, 90, 'theme save stores bounded custom logo width');
is($theme_saved_settings->{site_logo_max_height_px}, '', 'theme save drops out-of-range custom logo height');
is($theme_saved_settings->{theme_heading_font}, 'pkg:noto-fonts', 'theme save stores package heading font token');
is($theme_saved_settings->{theme_body_font}, 'sans', 'theme save stores body font token');
is($theme_saved_settings->{theme_ui_font}, 'serif', 'theme save stores interface font token');
is($theme_saved_settings->{font_package_repo}, 'https://ftp.example/pub/OpenBSD/7.4/packages/amd64/', 'theme save stores OpenBSD font package repo');
is($theme_saved_settings->{theme_heading_scale}, 'large', 'theme save stores heading scale token');
is($theme_saved_settings->{theme_body_scale}, 'compact', 'theme save stores body scale token');
is($theme_saved_settings->{theme_button_style}, 'outline', 'theme save stores button style token');
is($theme_saved_settings->{theme_button_radius}, 'pill', 'theme save stores button radius token');
is($theme_saved_settings->{theme_card_style}, 'raised', 'theme save stores card style token');
is($theme_saved_settings->{theme_card_radius}, 'round', 'theme save stores card radius token');

my $app_source = _read(File::Spec->catfile($repo, 'lib', 'DesertCMS', 'App.pm'));
like($app_source, qr/initThemeBuilderPreview/, 'admin JavaScript wires the Theme Builder live preview');
like($app_source, qr/preview-logo-max-width.*site_header_layout.*theme_heading_font/s, 'Theme Builder preview reacts to logo, header, and typography controls');
like($app_source, qr/\.settings-section-nav \{ position: static;/, 'site settings section nav stays in normal page flow');
like($app_source, qr/\.theme-preview-composer \{[^}]*grid-template-columns: minmax\(0, 1fr\)/s, 'theme preview composer gives preview and colors a full-width flow');
unlike($app_source, qr/\.theme-preview-composer \{[^}]*1\.45fr/s, 'theme preview composer no longer squeezes preview beside color controls');
like($app_source, qr/name\\\@\$suggested_contributor_root/, 'contributors email placeholder follows configured site host');
like($app_source, qr/review\\\@\$suggested_contributor_root/, 'contributor request inbox placeholder follows configured site host');
unlike($app_source, qr/desertarchives\.com/, 'contributor settings do not hardcode production contributor domain');
unlike($app_source, qr/Desert Archive/, 'contributor settings do not hardcode old product name');

done_testing;

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _read_binary {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _capture_response {
    my ($code) = @_;
    my ($fh, $path) = tempfile();
    {
        no warnings 'redefine';
        local *DesertCMS::HTTP::response = sub {
            my ($class, %args) = @_;
            print defined $args{body} ? $args{body} : '';
            return;
        };
        local *STDOUT = $fh;
        $code->();
    }
    seek $fh, 0, 0;
    local $/;
    my $output = <$fh>;
    close $fh;
    unlink $path if defined $path && -f $path;
    return $output;
}

sub _find_image_tool {
    my ($root) = @_;
    my $from_path = _which('magick');
    return ($from_path, 'magick') if $from_path;
    my $gm = _which('gm');
    return ($gm, 'gm') if $gm;
    my $vips = _which('vips');
    return ($vips, 'vips') if $vips;

    my $tools = File::Spec->catdir($root, '.tools', 'imagemagick');
    return undef unless -d $tools;

    my $found;
    find(
        sub {
            return if $found;
            return unless /^magick(?:\.exe)?\z/i;
            $found = $File::Find::name;
        },
        $tools
    );
    return ($found, 'magick');
}

sub _image_tool_cmd {
    my ($tool, $mode, $operation, @args) = @_;
    return ($tool, $operation, @args) if $mode eq 'gm' || $operation eq 'identify';
    return ($tool, @args);
}

sub _sibling_command {
    my ($tool, $command) = @_;
    my $name = $tool || '';
    $name =~ s{\\}{/}g;
    $name =~ s{\A.*/}{};
    my $suffix = $name =~ /\.exe\z/i ? '.exe' : '';
    return $command . $suffix unless ($tool || '') =~ m{[\\/]};

    my ($volume, $dir) = File::Spec->splitpath($tool);
    return File::Spec->catpath($volume, $dir, $command . $suffix);
}

sub _which {
    my ($name) = @_;
    for my $dir (File::Spec->path) {
        for my $candidate (
            File::Spec->catfile($dir, $name),
            File::Spec->catfile($dir, "$name.exe"),
        ) {
            return $candidate if -x $candidate;
        }
    }
    return undef;
}

sub _openbsd_sandbox_settings_image_check {
    my ($config_path, $source_path) = @_;
    my $code = <<'PERL';
use strict;
use warnings;
use DesertCMS::Config;
use DesertCMS::Settings;
use DesertCMS::Security qw(apply_openbsd_sandbox);
my ($config_path, $source_path) = @ARGV;
my $config = DesertCMS::Config->load($config_path);
$config->{image_tool} = 'vips';
open my $fh, '<:raw', $source_path or die "cannot read source image: $!";
local $/;
my $content = <$fh>;
close $fh;
apply_openbsd_sandbox($config);
DesertCMS::Settings::store_site_image($config, kind => 'favicon', mime_type => 'image/png', content => $content);
DesertCMS::Settings::store_site_image($config, kind => 'site_logo', mime_type => 'image/png', content => $content);
DesertCMS::Settings::store_site_image($config, kind => 'social_image', mime_type => 'image/png', content => $content);
DesertCMS::Settings::store_site_image($config, kind => 'site_background', mime_type => 'image/png', content => $content);
PERL
    my $encoded = encode_base64($code, '');
    my $status = system(
        $^X,
        '-Ilib',
        '-MMIME::Base64=decode_base64',
        '-e',
        'eval decode_base64(shift); die $@ if $@',
        $encoded,
        $config_path,
        $source_path
    );
    is($status, 0, 'settings image processing works after OpenBSD pledge/unveil with relative vips config');
}
