use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::Theme;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/data");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Theme Test
site_url = http://localhost
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

ok(DesertCMS::Theme::install_default($config), 'installed default theme');
ok(-f "$root/themes/default/templates/layout.html", 'theme layout seeded');
ok(-f "$root/themes/default/assets/site.js", 'public shell script seeded');

my $layout_path = "$root/themes/default/templates/layout.html";
my $legacy_layout = _read($layout_path);
$legacy_layout =~ s{<html lang="en"[^>]*>}{<html lang="en">};
$legacy_layout =~ s{\s*<script src="/assets/site\.js"></script>\n}{  <script>
  document.documentElement.classList.add('has-js');
  try {
    var defaultTheme = '{{default_theme_mode}}';
    if (defaultTheme === 'dark') {
      document.documentElement.setAttribute('data-theme', 'dark');
    } else {
      document.documentElement.setAttribute('data-theme', 'light');
    }
  } catch (error) {}
  </script>
}s;
$legacy_layout =~ s{\n</body>}{\n  <script>
  (function () {
    var button = document.querySelector('[data-theme-toggle]');
    function setTheme(theme) {
      var next = theme === 'dark' ? 'dark' : 'light';
      document.documentElement.setAttribute('data-theme', next);
      if (button) {
        button.setAttribute('data-theme-state', next);
        button.setAttribute('aria-label', next === 'dark' ? 'Switch to light mode' : 'Switch to dark mode');
      }
    }
    var stored = '{{default_theme_mode}}';
    setTheme(stored);
    if (button) {
      button.addEventListener('click', function () {
        setTheme(document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark');
      });
    }
  }());
  </script>
{{analytics_script}}
</body>}s;
$legacy_layout =~ s{<button type="button" class="theme-toggle" data-theme-toggle aria-label="Toggle color theme"(?: title="Toggle color theme")?>.*?</button>}{<button type="button" class="theme-toggle" data-theme-toggle aria-label="Toggle color theme" title="Toggle color theme">Mode</button>}s;
$legacy_layout =~ s{button\.setAttribute\('data-theme-state', next\);\s*button\.setAttribute\('aria-label', next === 'dark' \? 'Switch to light mode' : 'Switch to dark mode'\);\s*(?:button\.setAttribute\('title', next === 'dark' \? 'Switch to light mode' : 'Switch to dark mode'\);\s*)?}{button.textContent = next === 'dark' ? 'Light' : 'Dark';}s;
$legacy_layout =~ s{var defaultTheme = '\{\{default_theme_mode\}\}';\s*if \(defaultTheme === 'dark'\) \{\s*document\.documentElement\.setAttribute\('data-theme', 'dark'\);\s*\} else \{\s*document\.documentElement\.setAttribute\('data-theme', 'light'\);\s*\}}{var storedTheme = localStorage.getItem('desert-theme');\n    var defaultTheme = '{{default_theme_mode}}';\n    if ((storedTheme || defaultTheme) === 'dark') {\n      document.documentElement.setAttribute('data-theme', 'dark');\n    } else {\n      document.documentElement.setAttribute('data-theme', 'light');\n    }}s;
$legacy_layout =~ s{document\.documentElement\.setAttribute\('data-theme', next\);\s*}{document.documentElement.setAttribute('data-theme', next);\n      try { localStorage.setItem('desert-theme', next); } catch (error) {}\n      }s;
$legacy_layout =~ s{var stored = '\{\{default_theme_mode\}\}';}{var stored = '{{default_theme_mode}}';\n    try { stored = localStorage.getItem('desert-theme') || stored; } catch (error) {}}s;
$legacy_layout =~ s{\{\{theme_style\}\}\s*}{};
$legacy_layout =~ s{\{\{site_brand\}\}}{\{\{site_name\}\}}g;
_write($layout_path, $legacy_layout);
ok(DesertCMS::Theme::install_default($config), 'upgraded legacy public theme toggle');
my $upgraded_layout = _read($layout_path);
like($upgraded_layout, qr/theme-icon--moon/, 'legacy public toggle gains moon icon');
like($upgraded_layout, qr/theme-icon--sun/, 'legacy public toggle gains sun icon');
like($upgraded_layout, qr/\{\{theme_style\}\}/, 'legacy public layout gains theme style placeholder');
like($upgraded_layout, qr/\{\{site_brand\}\}/, 'legacy public layout gains site brand placeholder');
like($upgraded_layout, qr/data-site-menu-toggle/, 'legacy public layout gains mobile navigation toggle');
like($upgraded_layout, qr/\Qid="site-primary-nav" class="{{nav_class}}" data-site-menu\E/, 'legacy public layout gains mobile navigation target');
like($upgraded_layout, qr{data-default-theme="\{\{default_theme_mode\}\}"}, 'legacy public layout gains default theme data attribute');
like($upgraded_layout, qr{data-analytics-enabled="\{\{analytics_enabled\}\}"}, 'legacy public layout gains analytics data attribute');
like($upgraded_layout, qr{<script src="/assets/site\.js"></script>}, 'legacy public layout loads external public shell script');
unlike($upgraded_layout, qr/<a class="site-name" href="\/">\{\{site_name\}\}<\/a>/, 'legacy public layout stops forcing text site name');
unlike($upgraded_layout, qr/>Mode<\/button>/, 'legacy public toggle removes text-only button');
unlike($upgraded_layout, qr/title="Toggle color theme"/, 'legacy public toggle loses browser tooltip text');
unlike($upgraded_layout, qr/<span class="sr-only">Toggle color theme<\/span>/, 'legacy public toggle has no text fallback span');
unlike($upgraded_layout, qr/localStorage/, 'legacy public theme no longer persists visitor mode between pages');
unlike($upgraded_layout, qr/classList\.add\('has-js'\)|setMenu\(open\)|document\.querySelector\('\[data-theme-toggle\]'\)/, 'legacy public layout removes inline shell behavior');
unlike($upgraded_layout, qr/\{\{analytics_script\}\}/, 'legacy public layout removes inline analytics placeholder');
my $site_js = _read("$root/themes/default/assets/site.js");
like($site_js, qr/DesertCMS public shell v2/, 'legacy public shell script is upgraded');
like($site_js, qr/data-theme-state/, 'legacy public toggle no longer rewrites text label');
like($site_js, qr/classList\.add\("has-js"\)/, 'public shell script marks JavaScript-ready state');
like($site_js, qr/function setMenu\(open\)/, 'public shell script owns mobile menu behavior');
like($site_js, qr{/analytics/collect}, 'public shell script owns analytics beacon');
my $upgraded_css = _read("$root/themes/default/assets/site.css");
like($upgraded_css, qr/\.theme-toggle\s*\{[^}]*border:\s*1px solid var\(--line\)/s, 'public theme toggle CSS keeps a visible button target');
like($upgraded_css, qr/\.site-menu-toggle\b/, 'public theme CSS gains mobile navigation toggle rules');
like($upgraded_css, qr/\.has-js\s+\.site-header:not\(\.is-menu-open\)\s+nav\b/, 'public theme CSS hides closed mobile navigation only when JS is active');

_write("$root/themes/default/assets/site.css", ".site-header { display: flex; }\n");
ok(DesertCMS::Theme::install_default($config), 'upgraded legacy public site polish css');
my $polished_css = _read("$root/themes/default/assets/site.css");
like($polished_css, qr/DesertCMS component upgrade: public site polish/, 'legacy public CSS gains public site polish marker');
like($polished_css, qr/\.shop-shell\b/, 'legacy public CSS gains shop shell rules');
like($polished_css, qr/\.contributor-card-media\b/, 'legacy public CSS gains contributor placeholder media rules');
like($polished_css, qr/\.site-footer-nav a\b/, 'legacy public CSS gains footer tap target rules');
like($polished_css, qr/DesertCMS component upgrade: public donations v2/, 'legacy public CSS gains public donations layout rules');
like($polished_css, qr/DesertCMS component upgrade: public donation media fit/, 'legacy public CSS gains non-cropping donation media rules');
like($polished_css, qr/DesertCMS component upgrade: public module media fit/, 'legacy public CSS gains shared public module media rules');
like($polished_css, qr/\.showcase-card--image \.public-media-img\b[\s\S]*?object-fit:\s*contain;/, 'legacy public CSS gains contained Showcase media rules');
like($polished_css, qr/\.donation-amount-grid\b/, 'legacy public CSS gains styled donation amount choices');
like($polished_css, qr/\.donation-card-media img\b[^}]*object-fit:\s*contain/s, 'legacy public CSS scales donation card images without cropping');
like($polished_css, qr/\.directory-detail-image\.public-media-img\b[^}]*object-fit:\s*contain/s, 'legacy public CSS keeps module detail images contained');
like($polished_css, qr/DesertCMS component upgrade: public long text wrapping/, 'legacy public CSS gains long text wrapping marker');
like($polished_css, qr/\.rich-text p\b[^}]*overflow-wrap:\s*anywhere/s, 'legacy public CSS wraps long rich-text strings');

my $comments_js_path = "$root/themes/default/assets/comments.js";
_write(
    $comments_js_path,
    'if (comment.removed) { body.textContent = "Comment Removed by Author"; article.classList.add("is-deleted"); }'
);
ok(DesertCMS::Theme::install_default($config), 'upgraded legacy comments script');
my $upgraded_comments_js = _read($comments_js_path);
like($upgraded_comments_js, qr/hasMatchingComment/, 'legacy comments script gains posted-comment recovery');
unlike($upgraded_comments_js, qr/Comment Removed by Author|comment\.removed|is-deleted/, 'legacy comments script drops deleted-comment placeholder behavior');

my $map_js_path = "$root/themes/default/assets/map.js";
my $legacy_map_js = _read($map_js_path);
$legacy_map_js =~ s{\n\s*image: /\^\\\/assets\\\/media\\\/\[0-9a-f\]\{64\}\\\.jpg\$\/i\.test\(pin\.image \|\| ''\) \? pin\.image : '',}{};
$legacy_map_js =~ s{var image = pin\.image \? '<img class="map-popup-media" src="' \+ escapeHtml\(pin\.image\) \+ '" alt="' \+ title \+ '" loading="lazy">' : '';\s*return '<div class="map-popup">' \+ image \+ '<strong>' \+ title \+ '</strong><span>' \+ label \+ '</span>' \+ excerpt \+ link \+ '</div>';}
                  {return '<div class="map-popup"><strong>' + title + '</strong><span>' + label + '</span>' + excerpt + link + '</div>';}s;
_write($map_js_path, $legacy_map_js);
ok(DesertCMS::Theme::install_default($config), 'upgraded legacy map popup script');
my $upgraded_map_js = _read($map_js_path);
like($upgraded_map_js, qr/pin\.image/, 'legacy map script normalizes preview image');
like($upgraded_map_js, qr/map-popup-media/, 'legacy map script renders popup preview image');
like($upgraded_map_js, qr/pin\.kind_label/, 'legacy map script normalizes location kind labels');
like($upgraded_map_js, qr/Open item/, 'legacy map script uses generalized popup link text');
like($upgraded_map_js, qr/No mapped locations yet/, 'legacy map script uses generalized empty state');
unlike($upgraded_map_js, qr/Open story|No mapped stories|stories in this area/, 'legacy map script removes story-specific wording');

my $files = DesertCMS::Theme::read_files($config);
ok(@{$files} >= 5, 'reads editable theme files');

DesertCMS::Theme::save_file(
    $config,
    'templates/content.html',
    '<article class="content"><p class="theme-marker">Custom Theme Marker</p><h1>{{title}}</h1><div class="body">{{body}}</div></article>'
);

eval {
    DesertCMS::Theme::save_file($config, '../bad.html', 'bad');
};
like($@, qr/not editable/, 'rejects disallowed theme path');

my $content = DesertCMS::Content->new(config => $config, db => $db);
my $page = $content->save(
    type => 'page',
    title => 'Home',
    slug => 'home',
    body_text => 'Theme body',
);
$content->publish(id => $page->{id});

my $index_path = File::Spec->catfile($root, 'public', 'index.html');
my $html = _read($index_path);
like($html, qr/Custom Theme Marker/, 'saved theme affects published output');
like($html, qr/Theme body/, 'published output keeps content body');

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
