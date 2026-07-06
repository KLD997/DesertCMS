use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use MIME::Base64 qw(encode_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::FontPackages;
use DesertCMS::Security qw(apply_openbsd_sandbox);
use DesertCMS::SiteTheme;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/data", "$root/public");
my $repo = File::Spec->catdir($FindBin::Bin, '..');
$repo =~ s{\\}{/}g;

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Font Test
data_dir = $root/data
public_root = $root/public
theme_dir = $repo/themes
CONF
close $fh;

my $config = DesertCMS::Config->load($config_path);

is(DesertCMS::FontPackages::clean_font_id('serif', 'sans'), 'serif', 'accepts built-in font id');
is(DesertCMS::FontPackages::clean_font_id('bundled:space-grotesk', 'sans'), 'bundled:space-grotesk', 'accepts bundled font id');
is(DesertCMS::FontPackages::clean_font_id('pkg:noto-fonts', 'sans'), 'pkg:noto-fonts', 'accepts safe package font id');
is(DesertCMS::FontPackages::clean_font_id('pkg:../../bad', 'sans'), 'sans', 'rejects unsafe package font id');
is(DesertCMS::FontPackages::clean_repo('https://ftp.example/pub/OpenBSD/7.4/packages/amd64/'), 'https://ftp.example/pub/OpenBSD/7.4/packages/amd64/', 'accepts HTTPS package repo');
is(DesertCMS::FontPackages::clean_repo('file:///tmp/packages'), '', 'rejects non-HTTP package repo');
my %command_dirs = map { $_ => 1 } DesertCMS::FontPackages::_command_search_dirs();
ok($command_dirs{'/usr/sbin'}, 'command search includes OpenBSD system package tools');
ok($command_dirs{'/usr/local/bin'}, 'command search includes OpenBSD local package tools');

make_path(DesertCMS::FontPackages::font_dir($config));
_write(
    DesertCMS::FontPackages::catalog_path($config),
    encode_json({
        status => 'ok',
        package_repo => 'https://ftp.example/pub/OpenBSD/7.4/packages/amd64/',
        refreshed_at => 123,
        error => '',
        packages => [
            {
                package => 'noto-fonts-20240201',
                stem => 'noto-fonts',
                label => 'Noto',
                installed => 1,
                installed_package => 'noto-fonts-20240201',
                font_files => [
                    '/usr/local/share/fonts/noto/NotoSans-Regular.ttf',
                    '/usr/local/share/fonts/noto/NotoSans-Bold.ttf',
                ],
            },
            {
                package => 'available-font-1.0',
                stem => 'available-font',
                label => 'Available Font',
                installed => 0,
                font_files => [],
            },
        ],
    })
);

my $options = DesertCMS::FontPackages::font_options($config);
my %ids = map { $_->{id} => $_->{label} } @{$options};
ok($ids{serif}, 'built-in serif option remains available');
is($ids{'bundled:space-grotesk'}, 'Space Grotesk (bundled)', 'bundled Space Grotesk appears as a selectable font');
ok($ids{'pkg:noto-fonts'}, 'installed OpenBSD package font appears as an option');
ok(!$ids{'pkg:available-font'}, 'uninstalled package font is not selectable yet');

like(
    DesertCMS::FontPackages::css_stack_for_font_id('bundled:space-grotesk', 'sans'),
    qr/"Space Grotesk", system-ui/,
    'bundled font stack uses Space Grotesk and local fallbacks'
);

my $site = {
    theme_heading_font => 'pkg:noto-fonts',
    theme_body_font => 'serif',
    theme_ui_font => 'sans',
};
like(
    DesertCMS::FontPackages::css_stack_for_font_id('pkg:noto-fonts', 'serif'),
    qr/"DesertCMS Font Noto", serif/,
    'package font stack uses local DesertCMS family and fallback'
);
my $css = DesertCMS::SiteTheme::css_vars($site, config => $config);
like($css, qr/\@font-face/, 'package selection emits font-face CSS');
like($css, qr/font-family: "DesertCMS Font Noto";/, 'font-face CSS uses package family');
like($css, qr/url\("\/assets\/fonts\/noto-fonts\/NotoSans-Regular\.ttf"\)/, 'font-face CSS points at local public asset path');
like($css, qr/--site-heading-font: "DesertCMS Font Noto", serif;/, 'theme variables use package font stack');
my $published_fonts = eval {
    DesertCMS::FontPackages::publish_selected_fonts($config, $site);
    1;
};
ok($published_fonts, 'missing package font files do not abort font publishing');
ok(-d File::Spec->catdir($root, 'public', 'assets', 'fonts'), 'font publishing still prepares public font directory');

my $bundled_site = {
    theme_heading_font => 'bundled:space-grotesk',
    theme_body_font    => 'bundled:space-grotesk',
    theme_ui_font      => 'bundled:space-grotesk',
};
my $bundled_css = DesertCMS::SiteTheme::css_vars($bundled_site, config => $config);
like($bundled_css, qr/\@font-face/, 'bundled font selection emits font-face CSS');
like($bundled_css, qr/font-family: "Space Grotesk";/, 'bundled font-face uses the Space Grotesk family');
like($bundled_css, qr/url\("\/assets\/fonts\/space-grotesk\/SpaceGrotesk-VariableFont_wght\.woff2"\) format\("woff2"\)/, 'bundled font-face points at local public WOFF2 asset path');
like($bundled_css, qr/font-weight: 300 700;/, 'bundled variable font exposes its weight range');
like($bundled_css, qr/--site-heading-font: "Space Grotesk", system-ui, -apple-system/, 'theme variables use bundled font stack');
DesertCMS::FontPackages::publish_selected_fonts($config, $bundled_site);
ok(
    -f File::Spec->catfile($root, 'public', 'assets', 'fonts', 'space-grotesk', 'SpaceGrotesk-VariableFont_wght.woff2'),
    'font publishing copies the bundled Space Grotesk file when selected'
);

my $job = DesertCMS::FontPackages::queue_install(
    $config,
    package => 'available-font-1.0',
    package_repo => 'https://ftp.example/pub/OpenBSD/7.4/packages/amd64/',
    submitted_by_user_id => 7,
    submitted_by_username => 'admin',
);
ok($job->{id}, 'font package install job receives an id');
is($job->{status}, 'queued', 'font package install job starts queued');
my $queued = DesertCMS::FontPackages::queued_jobs($config);
is(scalar @{$queued}, 1, 'queued font job is discoverable');
is($queued->[0]{package}, 'available-font-1.0', 'queued font job keeps package name');

SKIP: {
    skip 'OpenBSD unveil check only runs on OpenBSD', 1 unless $^O eq 'openbsd';
    my $code = <<'PERL';
use strict;
use warnings;
use DesertCMS::Config;
use DesertCMS::FontPackages;
use DesertCMS::Security qw(apply_openbsd_sandbox);
my ($config_path) = @ARGV;
my $config = DesertCMS::Config->load($config_path);
apply_openbsd_sandbox($config);
die "pkg_info is not visible after unveil\n" unless length DesertCMS::FontPackages::_command_path('pkg_info');
PERL
    my $encoded = encode_base64($code, '');
    my $status = system(
        $^X,
        '-Ilib',
        '-MMIME::Base64=decode_base64',
        '-e',
        'eval decode_base64(shift); die $@ if $@',
        $encoded,
        $config_path
    );
    is($status, 0, 'OpenBSD sandbox keeps pkg_info visible for admin font catalog refresh');
}

done_testing;

sub _write {
    my ($path, $body) = @_;
    open my $out, '>', $path or die "cannot write $path: $!";
    print {$out} $body;
    close $out;
}
