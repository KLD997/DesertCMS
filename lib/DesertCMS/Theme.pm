package DesertCMS::Theme;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find;
use File::Path qw(make_path);
use File::Spec;

my @ALLOWED_FILES = qw(
    templates/layout.html
    templates/content.html
    templates/index.html
    templates/posts.html
    templates/archive.html
    assets/site.css
    assets/map.js
    assets/comments.js
);
my %ALLOWED = map { $_ => 1 } @ALLOWED_FILES;

sub allowed_files {
    return @ALLOWED_FILES;
}

sub install_default {
    my ($config) = @_;
    my $dest = File::Spec->catdir($config->get('theme_dir'), 'default');
    my $source = _repo_default_theme_dir();
    if (!-d $dest || !-f File::Spec->catfile($dest, 'templates', 'layout.html')) {
        _copy_dir($source, $dest);
        _ensure_map_css($dest);
        _ensure_map_pin_preview_css($dest);
        _ensure_map_locations_css($dest);
        _ensure_map_js_preview($dest);
        _ensure_map_locations_js($dest);
        _ensure_content_ref_css($dest);
        _ensure_resource_card_css($dest);
        _ensure_share_css($dest);
        _ensure_comments_css($dest);
        _ensure_docs_css($dest);
        _ensure_docs_nav_layout_css($dest);
        _ensure_comments_js($dest);
        _ensure_theme_toggle_css($dest);
        _ensure_theme_toggle_template($dest);
        _ensure_theme_style_template($dest);
        _ensure_site_brand_template($dest);
        _ensure_site_layout_template($dest);
        _ensure_mobile_nav_template($dest);
        _ensure_site_layout_css($dest);
        _ensure_logo_fit_css($dest);
        _ensure_mobile_nav_css($dest);
        _ensure_public_form_css($dest);
        _ensure_public_form_template($dest);
        _ensure_public_site_polish_css($dest);
        _ensure_showcase_css($dest);
        _ensure_public_text_wrap_css($dest);
        _ensure_responsive_visual_polish_css($dest);
        _ensure_public_map_tap_target_css($dest);
        _ensure_docs_nav_comfort_css($dest);
        _ensure_docs_resource_hub_css($dest);
        _ensure_events_css($dest);
        _ensure_public_event_ticket_wrap_css($dest);
        _ensure_donations_css($dest);
        _ensure_membership_css($dest);
        return 1;
    }
    _copy_missing($source, $dest);
    _ensure_map_css($dest);
    _ensure_map_pin_preview_css($dest);
    _ensure_map_locations_css($dest);
    _ensure_map_js_preview($dest);
    _ensure_map_locations_js($dest);
    _ensure_content_ref_css($dest);
    _ensure_resource_card_css($dest);
    _ensure_share_css($dest);
    _ensure_comments_css($dest);
    _ensure_docs_css($dest);
    _ensure_docs_nav_layout_css($dest);
    _ensure_comments_js($dest);
    _ensure_theme_toggle_css($dest);
    _ensure_theme_toggle_template($dest);
    _ensure_theme_style_template($dest);
    _ensure_site_brand_template($dest);
    _ensure_site_layout_template($dest);
    _ensure_mobile_nav_template($dest);
    _ensure_site_layout_css($dest);
    _ensure_logo_fit_css($dest);
    _ensure_mobile_nav_css($dest);
    _ensure_public_form_css($dest);
    _ensure_public_form_template($dest);
    _ensure_public_site_polish_css($dest);
    _ensure_showcase_css($dest);
    _ensure_public_text_wrap_css($dest);
    _ensure_responsive_visual_polish_css($dest);
    _ensure_public_map_tap_target_css($dest);
    _ensure_docs_nav_comfort_css($dest);
    _ensure_docs_resource_hub_css($dest);
    _ensure_events_css($dest);
    _ensure_public_event_ticket_wrap_css($dest);
    _ensure_donations_css($dest);
    _ensure_membership_css($dest);
    return 1;
}

sub read_files {
    my ($config) = @_;
    install_default($config);

    my @files;
    for my $rel (@ALLOWED_FILES) {
        my $path = File::Spec->catfile($config->get('theme_dir'), 'default', split m{/}, $rel);
        push @files, {
            path => $rel,
            body => _read_file($path),
        };
    }
    return \@files;
}

sub save_file {
    my ($config, $rel, $body) = @_;
    _assert_allowed($rel);
    install_default($config);

    my $path = File::Spec->catfile($config->get('theme_dir'), 'default', split m{/}, $rel);
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>', $path or die "cannot write theme file $path: $!";
    print {$fh} defined $body ? $body : '';
    close $fh;
}

sub _assert_allowed {
    my ($rel) = @_;
    die "theme path is not editable" unless defined $rel && $ALLOWED{$rel};
}

sub _repo_default_theme_dir {
    my $here = dirname(__FILE__);
    my $path = File::Spec->catdir($here, '..', '..', 'themes', 'default');
    return abs_path($path) || $path;
}

sub _copy_dir {
    my ($source, $dest) = @_;
    die "default theme source missing: $source" unless -d $source;
    find(
        sub {
            return if -d $File::Find::name;
            my $rel = File::Spec->abs2rel($File::Find::name, $source);
            my $target = File::Spec->catfile($dest, $rel);
            return if _same_file($File::Find::name, $target);
            make_path(dirname($target)) unless -d dirname($target);
            copy($File::Find::name, $target) or die "cannot copy theme file: $!";
        },
        $source
    );
}

sub _copy_missing {
    my ($source, $dest) = @_;
    die "default theme source missing: $source" unless -d $source;
    find(
        sub {
            return if -d $File::Find::name;
            my $rel = File::Spec->abs2rel($File::Find::name, $source);
            my $target = File::Spec->catfile($dest, $rel);
            return if -f $target;
            make_path(dirname($target)) unless -d dirname($target);
            copy($File::Find::name, $target) or die "cannot copy theme file: $!";
        },
        $source
    );
}

sub _same_file {
    my ($left, $right) = @_;
    my $left_abs = eval { abs_path($left) } || File::Spec->rel2abs($left);
    my $right_abs = eval { abs_path($right) } || File::Spec->rel2abs($right);
    return defined $left_abs && defined $right_abs && $left_abs eq $right_abs;
}

sub _ensure_map_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.slippy-map-stage\b/ && $body =~ /\.slippy-map-tile\b/;
    open my $fh, '>>', $path or die "cannot update theme css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: single responsive public map viewport. */
main:has(.map-page) { width: min(1180px, calc(100% - 32px)); }
.map-page { width: min(1120px, 100%); }
.archive-map, .slippy-map { clear: both; position: relative; width: 100%; height: clamp(500px, 68vh, 720px); min-height: 500px; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; background: var(--field); font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; isolation: isolate; }
.slippy-map-toolbar { position: absolute; top: 14px; left: 14px; right: 14px; z-index: 5; display: flex; justify-content: space-between; gap: 12px; pointer-events: none; }
.slippy-map-layer-tabs, .slippy-map-zoom { display: inline-flex; gap: 6px; padding: 6px; border: 1px solid var(--line); border-radius: 8px; background: color-mix(in srgb, var(--panel) 94%, transparent); box-shadow: 0 10px 28px rgba(16, 32, 51, 0.12); pointer-events: auto; }
.slippy-map button { min-width: 36px; min-height: 34px; border: 1px solid var(--line); border-radius: 6px; padding: 0 11px; background: var(--panel); color: var(--ink); font: 800 13px/1 system-ui, sans-serif; cursor: pointer; }
.slippy-map button:hover, .slippy-map button.is-active { border-color: var(--accent); color: var(--accent); }
.slippy-map-stage { position: absolute; inset: 0; overflow: hidden; cursor: grab; touch-action: none; }
.slippy-map-stage.is-dragging { cursor: grabbing; }
.slippy-map-tiles, .slippy-map-markers { position: absolute; inset: 0; }
.slippy-map-tile { position: absolute; width: 256px; height: 256px; max-width: none; object-fit: cover; user-select: none; }
.slippy-map-crosshair { display: none; }
.map-pin, .map-cluster { position: absolute; z-index: 3; transform: translate(-50%, -100%); }
.slippy-map .map-pin { width: 30px; height: 30px; min-width: 30px; min-height: 30px; border: 2px solid #ffffff; border-radius: 50% 50% 50% 0; padding: 0; background: #d93025; color: #ffffff; box-shadow: 0 10px 24px rgba(16, 32, 51, 0.32); transform: translate(-50%, -100%) rotate(-45deg); }
.slippy-map .map-pin::after { content: ""; position: absolute; left: 50%; top: 50%; width: 10px; height: 10px; transform: translate(-50%, -50%); border-radius: 999px; background: #ffffff; }
.map-cluster { min-width: 34px; min-height: 34px; border-radius: 999px; background: var(--ink); color: var(--panel); box-shadow: 0 8px 22px rgba(16, 32, 51, 0.25); }
.map-popup-wrap { position: absolute; z-index: 4; width: min(260px, calc(100% - 28px)); transform: translate(-50%, calc(-100% - 34px)); }
.map-popup { display: grid; gap: 8px; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); box-shadow: 0 16px 38px rgba(16, 32, 51, 0.18); }
.map-popup-media { display: block; width: 100%; aspect-ratio: 16 / 10; object-fit: cover; border-radius: 6px; background: var(--field); }
.map-popup strong { font-size: 16px; line-height: 1.25; }
.map-popup span { color: var(--muted); font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.08em; }
.map-popup p { margin: 0; color: var(--muted); font-size: 13px; line-height: 1.4; }
.map-popup a { color: var(--support); font-weight: 800; text-decoration: none; }
.slippy-map-attribution { position: absolute; right: 10px; bottom: 8px; z-index: 5; max-width: calc(100% - 20px); padding: 4px 7px; border-radius: 4px; background: color-mix(in srgb, var(--panel) 88%, transparent); color: var(--muted); font: 11px/1.3 system-ui, sans-serif; }
.slippy-map-attribution a { color: var(--support); }
.map-empty { position: absolute; inset: 0; display: grid; place-items: center; padding: 24px; color: var(--muted); text-align: center; font-weight: 800; }
.map-empty--pins { inset: auto 16px 16px 16px; z-index: 4; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
@media (max-width: 820px) { .archive-map, .slippy-map { height: 560px; min-height: 520px; border-left: 0; border-right: 0; border-radius: 0; margin-inline: -14px; } .slippy-map-toolbar { top: 10px; left: 10px; right: 10px; } }
@media (max-width: 430px) { .archive-map, .slippy-map { height: 500px; min-height: 460px; margin-inline: -12px; } .slippy-map-toolbar { display: grid; grid-template-columns: 1fr auto; gap: 8px; } .slippy-map-layer-tabs { min-width: 0; overflow-x: auto; } .map-popup-wrap { width: min(240px, calc(100% - 24px)); } }
CSS
    close $fh;
}

sub _ensure_map_pin_preview_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.map-popup-media\b/ && $body =~ /\.slippy-map\s+\.map-pin\b/;
    open my $fh, '>>', $path or die "cannot update theme css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: red map pins and image previews. */
.slippy-map .map-pin { width: 30px; height: 30px; min-width: 30px; min-height: 30px; border: 2px solid #ffffff; border-radius: 50% 50% 50% 0; padding: 0; background: #d93025; color: #ffffff; box-shadow: 0 10px 24px rgba(16, 32, 51, 0.32); transform: translate(-50%, -100%) rotate(-45deg); }
.slippy-map .map-pin::after { content: ""; position: absolute; left: 50%; top: 50%; width: 10px; height: 10px; transform: translate(-50%, -50%); border-radius: 999px; background: #ffffff; }
.map-popup { gap: 8px; }
.map-popup-media { display: block; width: 100%; aspect-ratio: 16 / 10; object-fit: cover; border-radius: 6px; background: var(--field); }
CSS
    close $fh;
}

sub _ensure_map_locations_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: map location kinds/;

    open my $fh, '>>', $path or die "cannot update theme map location css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: map location kinds. */
.map-popup small { color: var(--accent); font-size: 11px; font-weight: 900; text-transform: uppercase; letter-spacing: 0.08em; }
CSS
    close $fh;
}

sub _ensure_map_js_preview {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'map.js');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /map-popup-media/ && $body =~ /pin\.image/;
    my $original = $body;

    if ($body !~ /image:\s*\^\\\/assets\\\/media/) {
        $body =~ s{(label:\s*pin\.label \|\| pin\.title \|\| 'Location',\s*\n\s*excerpt:\s*pin\.excerpt \|\| '',)}
                  {$1\n      image: /^\\/assets\\/media\\/[0-9a-f]{64}\\.jpg\$/i.test(pin.image || '') ? pin.image : '',}s;
    }
    $body =~ s{(var link = pin\.url \? '<a href="' \+ escapeHtml\(pin\.url\) \+ '">Open (?:story|item)</a>' : '';\s*)return '<div class="map-popup"><strong>' \+ title \+ '</strong><span>' \+ label \+ '</span>' \+ excerpt \+ link \+ '</div>';}
              {$1var image = pin.image ? '<img class="map-popup-media" src="' + escapeHtml(pin.image) + '" alt="' + title + '" loading="lazy">' : '';\n      return '<div class="map-popup">' + image + '<strong>' + title + '</strong><span>' + label + '</span>' + excerpt + link + '</div>';}s;

    return if $body eq $original;
    open my $fh, '>', $path or die "cannot update theme map script $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _ensure_map_locations_js {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'map.js');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /Open item/
        && $body =~ /No mapped locations yet/
        && $body =~ /pin\.kind_label/;
    my $original = $body;

    if ($body !~ /kind_label:\s*pin\.kind_label/) {
        $body =~ s{(type:\s*pin\.type \|\| '',)}
                  {$1\n      kind: pin.kind || 'other',\n      kind_label: pin.kind_label || 'Location',}s;
    }
    if ($body !~ /var kind = pin\.kind_label/) {
        $body =~ s{(var label = escapeHtml\(pin\.label\);\s*)}
                  {$1var kind = pin.kind_label ? '<small>' + escapeHtml(pin.kind_label) + '</small>' : '';\n      }s;
    }
    $body =~ s/Open story/Open item/g;
    $body =~ s/No mapped stories yet/No mapped locations yet/g;
    $body =~ s/stories in this area/locations in this area/g;
    $body =~ s{\+ '<strong>' \+ title \+ '</strong><span>' \+ label}
              {+ '<strong>' + title + '</strong>' + kind + '<span>' + label}g;
    $body =~ s{('<strong>' \+ title \+ '</strong>') \+ '<span>'}{$1 + kind + '<span>'}g;

    return if $body eq $original;
    open my $fh, '>', $path or die "cannot update theme map locations script $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _ensure_content_ref_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.content-ref-card\b/;
    open my $fh, '>>', $path or die "cannot update theme css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: internal page/post reference cards. */
.content-ref-card { clear: both; display: grid; grid-template-columns: minmax(150px, 0.42fr) minmax(0, 1fr); gap: 18px; align-items: stretch; margin: 34px 0; padding: 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); color: var(--ink); text-decoration: none; font-family: system-ui, sans-serif; box-shadow: 0 12px 30px rgba(20, 32, 40, 0.08); }
.content-ref-card:hover { border-color: var(--accent); }
.content-ref-card > div:first-child:last-child { grid-column: 1 / -1; }
.content-ref-card figure { margin: 0; min-height: 100%; }
.content-ref-card img { width: 100%; height: 100%; min-height: 150px; object-fit: cover; border-radius: 6px; }
.content-ref-card div { min-width: 0; display: grid; align-content: center; gap: 8px; }
.content-ref-card span { color: var(--support); font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.08em; }
.content-ref-card strong { font-size: 24px; line-height: 1.15; overflow-wrap: anywhere; }
.content-ref-card p { margin: 0; color: var(--muted); line-height: 1.5; }
.content-ref-card--feature { grid-template-columns: 1fr; padding: 16px; }
.content-ref-card--feature figure { aspect-ratio: 16 / 9; }
.content-ref-card--feature img { min-height: 240px; }
.content-ref-card--feature strong { font-size: 30px; }
@media (max-width: 820px) { .content-ref-card { width: 100%; grid-template-columns: 1fr; gap: 14px; } .content-ref-card img, .content-ref-card--feature img { min-height: 210px; } }
CSS
    close $fh;
}

sub _ensure_resource_card_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: resource download cards/
        || ($body =~ /\.resource-card\s*\{[^}]*grid-template-columns:\s*auto minmax\(0,\s*1fr\) auto/s
            && $body =~ /\.resource-card-action\s*\{/s);

    open my $fh, '>>', $path or die "cannot update theme resource card css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: resource download cards. */
.content-block > .resource-card { width: 100%; }
.resource-card { clear: both; display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 16px; align-items: center; margin: 28px 0; padding: 16px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); box-shadow: var(--site-card-shadow, none); color: var(--ink); text-decoration: none; font-family: var(--site-ui-font, system-ui, sans-serif); }
.resource-card:hover { border-color: var(--accent); }
.resource-card:focus-visible { outline: 3px solid var(--focus-ring); outline-offset: 2px; }
.resource-card-badge { min-width: 58px; min-height: 44px; display: inline-grid; place-items: center; border: 1px solid var(--line); border-radius: 6px; background: var(--field); color: var(--support); font-size: 12px; font-weight: 900; letter-spacing: 0; }
.resource-card div { min-width: 0; display: grid; gap: 6px; }
.resource-card strong { font-family: var(--site-heading-font, Georgia, "Times New Roman", serif); font-size: var(--site-h3-size, 20px); line-height: 1.25; overflow-wrap: anywhere; }
.resource-card p { margin: 0; color: var(--muted); line-height: 1.45; }
.resource-card small { color: var(--muted); font-size: 12px; font-weight: 800; overflow-wrap: anywhere; }
.resource-card-action { min-height: 38px; display: inline-flex; align-items: center; justify-content: center; padding: 0 14px; border-radius: var(--site-button-radius, 6px); background: var(--site-button-bg, var(--accent)); color: var(--site-button-color, var(--button-ink)); font-size: 14px; font-weight: 800; white-space: nowrap; }
@media (max-width: 820px) {
  .resource-card { grid-template-columns: auto minmax(0, 1fr); width: 100%; }
  .resource-card-action { grid-column: 1 / -1; width: 100%; }
}
CSS
    close $fh;
}

sub _ensure_share_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.post-share\b/;
    open my $fh, '>>', $path or die "cannot update theme css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: post share buttons. */
.post-share { clear: both; display: flex; align-items: center; justify-content: space-between; gap: 14px; flex-wrap: wrap; margin: 48px 0 0; padding: 16px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); font-family: system-ui, sans-serif; }
.post-share > span { color: var(--muted); font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.08em; }
.post-share-links { display: flex; align-items: center; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
.post-share-link { min-height: 38px; display: inline-flex; align-items: center; justify-content: center; gap: 8px; padding: 0 12px; border: 1px solid var(--line); border-radius: 6px; background: var(--field); color: var(--ink); text-decoration: none; font-size: 13px; font-weight: 800; }
.post-share-link:hover { border-color: var(--accent); color: var(--accent); }
.post-share-link span { display: inline-grid; place-items: center; }
.post-share-link svg { width: 17px; height: 17px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
@media (max-width: 820px) { .post-share, .post-share-links { align-items: stretch; justify-content: stretch; } .post-share-link { flex: 1 1 132px; } }
CSS
    close $fh;
}

sub _ensure_comments_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.comments-section\b/
        && $body =~ /\.comment-form\s+button\[type="submit"\]/
        && $body =~ /\.module-intro\b/
        && $body =~ /\.public-form\s+button\b/;
    if ($body =~ /\.comments-section\b/) {
        open my $upgrade, '>>', $path or die "cannot update theme css $path: $!";
        print {$upgrade} <<'CSS';

/* DesertCMS component upgrade: integrated comments ratings and modules. */
.rating-section { display: none; }
.comments-section { gap: 12px; margin: 28px 0 0; padding-top: 18px; }
.comments-heading { align-items: flex-start; gap: 12px; }
.comments-heading > div:first-child { display: grid; gap: 4px; }
.comments-heading h2 { font-size: 20px; line-height: 1.15; }
.comment-rating { display: grid; justify-items: end; gap: 3px; min-width: 132px; }
.rating-average, .comments-count { font-size: 12px; }
.rating-status, .comments-status, .comments-help { font-size: 12px; }
.rating-stars { gap: 1px; }
.rating-stars button { width: 22px; height: 22px; min-height: 22px; border: 0; border-radius: 4px; background: transparent; font-size: 17px; }
.rating-stars button:hover, .rating-stars button:focus-visible, .rating-stars button.is-selected { color: var(--accent); background: var(--field); }
.comments-list { gap: 10px; padding-top: 4px; }
.comment { gap: 6px; padding: 8px 0 8px 12px; border: 0; border-left: 2px solid var(--line); border-radius: 0; background: transparent; }
.comment.is-reply { margin-left: 18px; }
.comment-meta { gap: 10px; }
.comment-meta strong { font-size: 13px; }
.comment-meta time { font-size: 11px; }
.comment-body { gap: 6px; font-size: 14px; line-height: 1.45; }
.comment-actions button { min-height: 0; border: 0; border-radius: 0; padding: 0; background: transparent; color: var(--support); font-size: 12px; }
.comment-form button, .comment-reply-mark { min-height: 30px; padding: 0 10px; font-size: 12px; }
.comment-form { gap: 8px; padding: 12px 0 14px; border: 0; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); border-radius: 0; background: transparent; }
.comment-form label { gap: 4px; }
.comment-form label span { font-size: 11px; }
.comment-form input, .comment-form textarea { padding: 7px 9px; font-size: 14px; line-height: 1.4; }
.comment-form textarea { min-height: 78px; }
.comment-form-actions { gap: 8px; }
.comments-replies { gap: 6px; padding: 8px 10px; border-color: var(--line); border-left: 2px solid var(--accent); border-radius: 4px; }
.comments-replies h3 { font-size: 16px; }
.comment-reply-notice { gap: 3px; font-size: 12px; }
.module-page { display: grid; gap: 18px; }
.module-intro { max-width: 72ch; margin: 0 0 10px; color: var(--muted); font: 18px/1.55 system-ui, sans-serif; }
.portfolio-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 18px; margin-top: 10px; }
.portfolio-card { display: grid; gap: 10px; margin: 0; }
.portfolio-card img { width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 6px; background: var(--field); }
.portfolio-card figcaption { display: grid; gap: 3px; }
.portfolio-card strong { font-size: 16px; line-height: 1.25; }
.portfolio-card span, .portfolio-card small, .portfolio-empty { color: var(--muted); font-size: 13px; }
.public-form { display: grid; gap: 14px; width: min(720px, 100%); padding-top: 4px; }
.public-form label { display: grid; gap: 6px; }
.public-form label span { color: var(--muted); font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.08em; }
.public-form input, .public-form textarea { width: 100%; border: 1px solid var(--line); border-radius: 6px; padding: 10px 12px; background: var(--field); color: var(--ink); font: 15px/1.45 system-ui, sans-serif; }
.public-form textarea { resize: vertical; min-height: 150px; }
.public-form button { justify-self: start; min-height: 40px; border: 1px solid var(--accent); border-radius: 6px; padding: 0 16px; background: var(--accent); color: var(--button-ink); font: 800 14px/1 system-ui, sans-serif; cursor: pointer; }
.forms-notice { width: min(720px, 100%); margin: 0; padding: 12px 14px; border: 1px solid var(--line); border-left: 3px solid var(--support); border-radius: 6px; background: var(--field); }
.forms-notice.is-error { border-left-color: #a33a2b; }
@media (max-width: 640px) { .comments-heading, .comment-meta { align-items: start; flex-direction: column; } .comment-rating { justify-items: start; min-width: 0; } .comment.is-reply { margin-left: 10px; } .comment-form-actions button, .public-form button { width: 100%; } }
CSS
        close $upgrade;
        return;
    }
    open my $fh, '>>', $path or die "cannot update theme css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: public comments. */
.rating-section, .comments-section { clear: both; display: grid; gap: 10px; margin: 28px 0 0; padding-top: 18px; border-top: 1px solid var(--line); font-family: system-ui, sans-serif; }
.rating-section { gap: 8px; }
.rating-heading, .comments-heading { display: flex; align-items: end; justify-content: space-between; gap: 12px; }
.rating-heading h2, .comments-heading h2 { margin: 0; font-size: 20px; line-height: 1.15; letter-spacing: 0; }
.rating-average, .comments-count { color: var(--muted); font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.08em; }
.rating-status, .comments-status, .comments-help { margin: 0; color: var(--muted); font-size: 12px; line-height: 1.45; }
.rating-status.is-error, .comments-status.is-error { color: #a33a2b; }
.rating-stars { display: inline-flex; align-items: center; gap: 3px; }
.rating-stars button { width: 28px; height: 28px; min-height: 28px; display: inline-grid; place-items: center; border: 0; border-radius: 4px; padding: 0; background: transparent; color: var(--muted); font: 22px/1 system-ui, sans-serif; cursor: pointer; }
.rating-stars button:hover, .rating-stars button:focus-visible, .rating-stars button.is-selected { color: var(--accent); background: var(--field); }
.comments-list { display: grid; gap: 8px; }
.comment { display: grid; gap: 6px; padding: 8px 0 8px 12px; border: 0; border-left: 2px solid var(--line); border-radius: 0; background: transparent; }
.comment.is-reply { margin-left: 18px; }
.comment-meta { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; flex-wrap: wrap; }
.comment-meta strong { font-size: 13px; overflow-wrap: anywhere; }
.comment-meta time { color: var(--muted); font-size: 11px; font-weight: 700; }
.comment-body { display: grid; gap: 6px; color: var(--ink); font-size: 14px; line-height: 1.45; overflow-wrap: anywhere; }
.comment-body p { margin: 0; }
.comment-actions { display: flex; justify-content: flex-start; }
.comment-actions button { min-height: 0; border: 0; border-radius: 0; padding: 0; background: transparent; color: var(--support); font: 800 12px/1 system-ui, sans-serif; cursor: pointer; }
.comment-form button, .comment-reply-mark { min-height: 30px; border: 1px solid var(--line); border-radius: 6px; padding: 0 10px; background: var(--field); color: var(--ink); font: 800 12px/1 system-ui, sans-serif; cursor: pointer; }
.comment-actions button:hover, .comment-form button:hover, .comment-reply-mark:hover { border-color: var(--accent); color: var(--accent); }
.comment-form { display: grid; gap: 8px; padding: 10px 0 0; border: 0; border-top: 1px solid var(--line); border-radius: 0; background: transparent; }
.comment-form label { display: grid; gap: 4px; }
.comment-form label span { color: var(--muted); font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.08em; }
.comment-form input, .comment-form textarea { width: 100%; border: 1px solid var(--line); border-radius: 6px; padding: 7px 9px; background: var(--field); color: var(--ink); font: 14px/1.4 system-ui, sans-serif; }
.comment-form textarea { resize: vertical; min-height: 78px; }
.comment-form-actions { display: flex; flex-wrap: wrap; gap: 8px; }
.comment-form button[type="submit"] { border-color: var(--accent); background: var(--accent); color: var(--button-ink); }
.comment-honeypot { position: absolute; left: -10000px; width: 1px; height: 1px; overflow: hidden; }
.comments-replies { display: grid; gap: 6px; padding: 8px 10px; border: 1px solid var(--line); border-left: 2px solid var(--accent); border-radius: 4px; background: var(--field); }
.comments-replies h3 { margin: 0; font-size: 16px; }
.comment-reply-notice { display: grid; gap: 3px; color: var(--muted); font-size: 12px; }
.comment-reply-notice a { color: var(--support); font-weight: 800; }
@media (max-width: 640px) { .rating-heading, .comments-heading, .comment-meta { align-items: start; flex-direction: column; } .comment.is-reply { margin-left: 10px; } .comment-form-actions button { width: 100%; } }
CSS
    close $fh;
}

sub _ensure_comments_js {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'comments.js');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /hasMatchingComment/
        && $body !~ /Comment Removed by Author|comment\.removed|is-deleted/
        && $body =~ /average\.textContent = count \? score\.toFixed\(1\) : "Rate"/;

    my $source = File::Spec->catfile(_repo_default_theme_dir(), 'assets', 'comments.js');
    return if _same_file($source, $path);
    copy($source, $path) or die "cannot update comments script $path: $!";
}

sub _ensure_docs_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.docs-index\b/
        && $body =~ /\.docs-card\b/
        && $body =~ /\.docs-markdown\b/;

    my $source = File::Spec->catfile(_repo_default_theme_dir(), 'assets', 'site.css');
    my $source_body = _read_file($source);
    return unless $source_body =~ /(main:has\(\.docs-index\).*)\z/s;

    open my $fh, '>>', $path or die "cannot update theme css $path: $!";
    print {$fh} "\n$1\n";
    close $fh;
}

sub _ensure_docs_nav_layout_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: docs nav layout/;

    open my $fh, '>>', $path or die "cannot update theme docs nav layout css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: docs nav layout. */
.docs-layout { display: grid; grid-template-columns: 1fr; gap: 26px; align-items: start; }
.docs-sidebar { position: static; width: 100%; }
.docs-nav { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; padding: 12px; }
.docs-nav-group { min-width: 0; display: grid; align-content: start; gap: 5px; }
.docs-nav-group + .docs-nav-group { margin-top: 0; padding-top: 0; padding-left: 12px; border-top: 0; border-left: 1px solid var(--line); }
.docs-nav a { display: block; line-height: 1.25; overflow-wrap: anywhere; }
.docs-markdown { width: min(860px, 100%); justify-self: center; }
@media (max-width: 820px) {
  .docs-layout { gap: 18px; }
  .docs-nav { grid-template-columns: 1fr; }
  .docs-nav-group + .docs-nav-group { margin-top: 8px; padding-top: 8px; padding-left: 0; border-top: 1px solid var(--line); border-left: 0; }
  .docs-markdown { width: 100%; }
}
CSS
    close $fh;
}

sub _ensure_docs_nav_comfort_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: docs nav comfort layout/;

    open my $fh, '>>', $path or die "cannot update theme docs nav comfort css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: docs nav comfort layout. */
.docs-nav { grid-template-columns: 1fr; gap: 16px; padding: clamp(14px, 2vw, 18px); }
.docs-nav-group { grid-template-columns: repeat(auto-fit, minmax(min(100%, 220px), 1fr)); gap: 8px; }
.docs-nav-group + .docs-nav-group { margin-top: 0; padding-top: 14px; padding-left: 0; border-top: 1px solid var(--line); border-left: 0; }
.docs-nav-group-title { grid-column: 1 / -1; padding: 0 2px 2px; }
.docs-nav a { min-height: 42px; display: flex; align-items: center; padding: 10px 12px; border: 1px solid var(--line); background: var(--panel); }
.docs-nav a:hover, .docs-nav a.active { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 8%, var(--panel)); }
@media (max-width: 640px) {
  .docs-nav { gap: 12px; padding: 12px; }
  .docs-nav-group { grid-template-columns: 1fr; }
  .docs-nav a { min-height: 40px; }
}
CSS
    close $fh;
}

sub _ensure_docs_resource_hub_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: docs resource hub/;

    open my $fh, '>>', $path or die "cannot update theme docs resource hub css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: docs resource hub. */
.docs-hub-panel { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; }
.docs-hub-stat { display: grid; gap: 4px; min-width: 0; padding: 14px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--field); box-shadow: var(--site-card-shadow, none); }
.docs-hub-stat span { color: var(--muted); font: 800 11px/1.25 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.08em; }
.docs-hub-stat strong { color: var(--ink); font: 900 26px/1 var(--site-ui-font, system-ui, sans-serif); letter-spacing: 0; overflow-wrap: anywhere; }
.docs-hub-strip { display: flex; flex-wrap: wrap; gap: 8px; }
.docs-hub-strip span, .docs-type-pill { display: inline-flex; align-items: center; min-height: 28px; width: fit-content; max-width: 100%; padding: 6px 9px; border: 1px solid var(--site-card-border, var(--line)); border-radius: 999px; background: var(--field); color: var(--accent); font: 900 11px/1.2 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.08em; overflow-wrap: anywhere; }
.docs-card { align-content: start; min-height: 184px; }
.docs-card-meta, .docs-card-tags { display: flex; flex-wrap: wrap; gap: 6px; color: var(--muted); font: 800 11px/1.25 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.06em; }
.docs-card-meta span, .docs-card-tags span { max-width: 100%; overflow-wrap: anywhere; }
.docs-card-tags span { padding: 4px 7px; border: 1px solid var(--site-card-border, var(--line)); border-radius: 999px; background: var(--field); text-transform: none; letter-spacing: 0; }
.docs-meta-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; padding: 12px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--field); }
.docs-meta-strip div { display: grid; gap: 3px; min-width: 0; }
.docs-meta-strip span { color: var(--muted); font: 800 11px/1.25 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.08em; }
.docs-meta-strip strong { color: var(--ink); font: 800 13px/1.3 var(--site-ui-font, system-ui, sans-serif); overflow-wrap: anywhere; }
CSS
    close $fh;
}

sub _ensure_events_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: public events/;

    open my $fh, '>>', $path or die "cannot update theme events css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: public events. */
main:has(.events-page) { width: min(1080px, calc(100% - 32px)); }
.events-shell, .event-detail { display: grid; gap: 24px; }
.events-heading { display: grid; gap: 12px; max-width: 820px; }
.events-heading h1, .event-detail h1 { margin: 0; font-size: clamp(38px, 7vw, var(--site-h1-size, 68px)); line-height: 1; letter-spacing: 0; overflow-wrap: anywhere; }
.events-heading p, .event-detail > .module-intro { margin: 0; color: var(--muted); font: 18px/1.6 var(--site-ui-font, system-ui, sans-serif); }
.events-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 300px), 1fr)); gap: 22px; align-items: start; }
.event-card { min-width: 0; display: grid; grid-template-rows: auto 1fr; overflow: hidden; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); box-shadow: var(--site-card-shadow, none); color: var(--ink); text-decoration: none; }
.event-card:hover { border-color: var(--accent); box-shadow: var(--site-card-shadow, 0 12px 28px rgba(16, 32, 51, 0.10)); }
.event-card img, .event-card-date { width: 100%; aspect-ratio: 4 / 3; background: var(--field); }
.event-card img { display: block; object-fit: cover; }
.event-card-date { display: grid; place-items: center; color: var(--accent); font: 900 30px/1 var(--site-ui-font, system-ui, sans-serif); letter-spacing: 0; }
.event-card-body { display: grid; gap: 10px; align-content: start; padding: 18px; }
.event-time { justify-self: start; display: inline-flex; align-items: center; min-height: 26px; padding: 0 9px; border: 1px solid var(--site-card-border, var(--line)); border-radius: 999px; background: var(--field); color: var(--muted); font: 800 12px/1 var(--site-ui-font, system-ui, sans-serif); }
.event-card h2 { margin: 0; font-family: var(--site-heading-font, Georgia, "Times New Roman", serif); font-size: var(--site-h3-size, 25px); line-height: 1.12; letter-spacing: 0; overflow-wrap: anywhere; }
.event-card p, .event-card span:not(.event-time) { margin: 0; color: var(--muted); font: 14px/1.5 var(--site-ui-font, system-ui, sans-serif); overflow-wrap: anywhere; }
.events-empty, .events-notice { margin: 0; padding: 14px 16px; border: 1px dashed var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--field); color: var(--muted); font: 800 14px/1.45 var(--site-ui-font, system-ui, sans-serif); }
.events-notice { border-style: solid; border-left: 3px solid var(--accent); color: var(--ink); }
.events-notice.is-error { border-left-color: var(--danger, #b42318); }
.event-meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 220px), 1fr)); gap: 10px; margin: 0; font-family: var(--site-ui-font, system-ui, sans-serif); }
.event-meta div { min-width: 0; display: grid; gap: 5px; padding: 13px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--field); }
.event-meta dt { color: var(--muted); font-weight: 800; text-transform: uppercase; letter-spacing: 0.08em; font-size: 11px; }
.event-meta dd { display: grid; gap: 4px; margin: 0; color: var(--ink); font-weight: 800; overflow-wrap: anywhere; }
.event-meta small { color: var(--muted); font-size: 12px; font-weight: 700; }
.event-body { max-width: 76ch; }
.event-action-panel { display: grid; gap: 14px; padding: clamp(16px, 3vw, 22px); border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); box-shadow: var(--site-card-shadow, none); }
.event-action-panel h2 { margin: 0; font-family: var(--site-heading-font, Georgia, "Times New Roman", serif); font-size: var(--site-h2-size, 28px); line-height: 1.15; letter-spacing: 0; }
.event-ticket-grid { display: grid; gap: 10px; }
.event-ticket-option { min-width: 0; display: grid; grid-template-columns: minmax(0, 1fr) minmax(220px, auto); gap: 12px; align-items: center; padding: 12px; border: 1px solid var(--line); border-radius: var(--site-card-radius, 8px); background: var(--field); font-family: var(--site-ui-font, system-ui, sans-serif); }
.event-ticket-option div { min-width: 0; display: grid; gap: 5px; }
.event-ticket-option strong { min-width: 0; overflow-wrap: anywhere; }
.event-ticket-option span { color: var(--accent); font-weight: 900; }
.event-ticket-option p { margin: 0; color: var(--muted); font-size: 14px; line-height: 1.45; }
.event-ticket-form { display: grid; grid-template-columns: 92px minmax(150px, 1fr) auto; gap: 8px; align-items: end; }
.event-ticket-form label { display: grid; gap: 5px; margin: 0; color: var(--muted); font: 800 11px/1.2 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.08em; }
.event-ticket-form input { min-height: 40px; border: 1px solid var(--line); border-radius: 6px; padding: 0 10px; background: var(--panel); color: var(--ink); font: 14px/1 var(--site-ui-font, system-ui, sans-serif); }
.event-ticket-form button { min-height: 40px; border: 1px solid var(--site-button-border, var(--accent)); border-radius: var(--site-button-radius, 6px); padding: 0 14px; background: var(--site-button-bg, var(--accent)); color: var(--site-button-color, var(--button-ink)); font: 800 14px/1 var(--site-ui-font, system-ui, sans-serif); cursor: pointer; }
@media (max-width: 640px) {
  .event-ticket-option, .event-ticket-form { grid-template-columns: 1fr; }
  .events-grid { gap: 14px; }
  .event-ticket-form button { width: 100%; }
}
CSS
    close $fh;
}

sub _ensure_public_event_ticket_wrap_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: public event ticket wrapping/;

    open my $fh, '>>', $path or die "cannot update theme event ticket wrapping css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: public event ticket wrapping. */
.module-action-link,
.shop-button,
.rights-option button,
.event-ticket-form button { box-sizing: border-box; min-width: 0; max-width: 100%; min-height: 42px; white-space: normal; overflow-wrap: anywhere; text-align: center; line-height: 1.2; }
.event-ticket-option { grid-template-columns: minmax(0, 1fr) minmax(min(100%, 320px), auto); }
.event-ticket-option span { min-width: 0; overflow-wrap: anywhere; }
.event-ticket-form { min-width: 0; grid-template-columns: minmax(70px, 92px) minmax(0, 1fr) minmax(112px, auto); }
.event-ticket-form > * { min-width: 0; }
.event-ticket-form input { width: 100%; min-width: 0; }
@media (max-width: 760px) {
  .event-ticket-option,
  .event-ticket-form { grid-template-columns: 1fr; }
  .event-ticket-form button { width: 100%; }
}
CSS
    close $fh;
}

sub _ensure_donations_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: public donations/;

    open my $fh, '>>', $path or die "cannot update theme donations css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: public donations. */
main:has(.donations-page) { width: min(1120px, calc(100% - 32px)); }
.donations-shell,
.donation-detail { display: grid; gap: 24px; }
.donations-hero,
.donation-detail-hero { display: grid; grid-template-columns: minmax(0, 1fr) minmax(min(100%, 300px), 360px); gap: clamp(18px, 3vw, 28px); align-items: stretch; }
.donations-hero-copy,
.donation-detail-copy { min-width: 0; display: grid; align-content: center; gap: 12px; }
.donations-hero-copy h1,
.donation-detail-copy h1,
.donation-status-card h1 { margin: 0; font-size: clamp(38px, 7vw, var(--site-h1-size, 68px)); line-height: 1; letter-spacing: 0; overflow-wrap: anywhere; }
.donations-hero-copy p:not(.kicker),
.donation-summary { margin: 0; color: var(--muted); font: 18px/1.6 var(--site-ui-font, system-ui, sans-serif); }
.donations-how-card,
.donation-progress-panel,
.donation-panel,
.donation-status-card { min-width: 0; display: grid; gap: 14px; padding: clamp(16px, 3vw, 22px); border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); box-shadow: var(--site-card-shadow, none); }
.donations-how-card > strong,
.donation-panel-kicker,
.donation-progress-panel span { color: var(--muted); font: 900 11px/1.25 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.08em; }
.donations-steps { display: grid; gap: 12px; margin: 0; padding: 0; list-style: none; }
.donations-steps li { min-width: 0; display: grid; grid-template-columns: 34px minmax(0, 1fr); gap: 10px; align-items: start; }
.donations-steps li > span { display: grid; place-items: center; width: 34px; height: 34px; border: 1px solid var(--site-card-border, var(--line)); border-radius: 999px; background: var(--field); color: var(--accent); font: 900 13px/1 var(--site-ui-font, system-ui, sans-serif); }
.donations-steps p { display: grid; gap: 3px; margin: 0; }
.donations-steps b { color: var(--ink); font: 900 14px/1.25 var(--site-ui-font, system-ui, sans-serif); }
.donations-steps small { color: var(--muted); font: 13px/1.35 var(--site-ui-font, system-ui, sans-serif); }
.donations-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 300px), 1fr)); gap: 22px; align-items: stretch; }
.donation-empty { grid-column: 1 / -1; margin: 0; padding: 18px; border: 1px dashed var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--field); color: var(--muted); font: 900 14px/1.45 var(--site-ui-font, system-ui, sans-serif); }
.donation-card { min-width: 0; display: grid; gap: 13px; align-content: start; min-height: 250px; padding: 18px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); box-shadow: var(--site-card-shadow, none); color: var(--ink); text-decoration: none; }
.donation-card:hover { border-color: var(--accent); box-shadow: var(--site-card-shadow, 0 12px 28px rgba(16, 32, 51, 0.10)); }
.donation-card-kicker { justify-self: start; min-height: 25px; display: inline-flex; align-items: center; padding: 0 9px; border: 1px solid var(--site-card-border, var(--line)); border-radius: 999px; background: var(--field); color: var(--accent); font: 900 11px/1 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.08em; }
.donation-card h2,
.donation-story h2,
.donation-panel h2 { margin: 0; color: var(--ink); font-family: var(--site-heading-font, Georgia, "Times New Roman", serif); font-size: var(--site-h2-size, 28px); line-height: 1.15; letter-spacing: 0; overflow-wrap: anywhere; }
.donation-card h2 { font-size: var(--site-h3-size, 24px); }
.donation-card p,
.donation-panel p,
.donation-progress-panel p { margin: 0; color: var(--muted); font: 14px/1.5 var(--site-ui-font, system-ui, sans-serif); overflow-wrap: anywhere; }
.donation-card-progress { align-self: end; display: grid; gap: 8px; margin-top: auto; }
.donation-card-progress strong,
.donation-progress-panel strong { color: var(--ink); font: 900 18px/1.2 var(--site-ui-font, system-ui, sans-serif); overflow-wrap: anywhere; }
.donation-meter { width: 100%; height: 10px; overflow: hidden; border: 1px solid var(--site-card-border, var(--line)); border-radius: 999px; background: var(--field); }
.donation-meter span { display: block; max-width: 100%; height: 100%; border-radius: inherit; background: var(--accent); }
.donation-card-action,
.donation-return-link { align-self: end; display: inline-flex; align-items: center; justify-content: center; width: fit-content; max-width: 100%; min-height: 38px; padding: 0 13px; border: 1px solid var(--site-button-border, var(--accent)); border-radius: var(--site-button-radius, 6px); background: var(--site-button-bg, var(--accent)); color: var(--site-button-color, var(--button-ink)); font: 900 13px/1.2 var(--site-ui-font, system-ui, sans-serif); text-decoration: none; }
.donation-detail-media { min-width: 0; margin: 0; overflow: hidden; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--field); }
.donation-detail-media img { display: block; width: 100%; height: 100%; min-height: 220px; aspect-ratio: 4 / 3; object-fit: cover; }
.donation-detail-layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(min(100%, 300px), 380px); gap: clamp(18px, 3vw, 28px); align-items: start; }
.donation-story { min-width: 0; display: grid; gap: 14px; }
.donation-body { max-width: 76ch; }
.donation-body p { margin-top: 0; }
.donation-sidebar { min-width: 0; display: grid; gap: 14px; align-content: start; }
.donation-progress-panel div { min-width: 0; display: grid; gap: 4px; }
.donation-progress-panel small { color: var(--muted); font: 800 12px/1.35 var(--site-ui-font, system-ui, sans-serif); }
.donation-panel--unavailable { border-left: 3px solid var(--accent); }
.donation-panel-intro,
.donation-secure-note { color: var(--muted); font: 13px/1.45 var(--site-ui-font, system-ui, sans-serif); }
.donation-form { width: 100%; max-width: none; }
.donation-form *,
.donation-form *::before,
.donation-form *::after { box-sizing: border-box; }
.donation-amounts { min-width: 0; display: grid; gap: 10px; margin: 0; padding: 0; border: 0; }
.donation-amounts legend { padding: 0; color: var(--muted); font: 900 11px/1.25 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.08em; }
.donation-amount-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 106px), 1fr)); gap: 8px; }
.donation-amount-grid > * { min-width: 0; }
.donation-amount-option { position: relative; min-width: 0; display: grid; cursor: pointer; }
.donation-amount-option input { position: absolute; inset: 0; width: 100%; height: 100%; margin: 0; border: 0; padding: 0; opacity: 0; cursor: pointer; }
.donation-amount-option span { min-width: 0; max-width: 100%; display: flex; align-items: center; justify-content: center; min-height: 44px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-button-radius, 6px); padding: 0 10px; background: var(--field); color: var(--ink); font: 900 14px/1.2 var(--site-ui-font, system-ui, sans-serif); text-align: center; text-transform: none; letter-spacing: 0; overflow-wrap: anywhere; }
.donation-amount-option input:checked + span,
.donation-amount-option:focus-within span { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 10%, var(--field)); box-shadow: 0 0 0 3px var(--focus-ring, color-mix(in srgb, var(--accent) 25%, transparent)); }
.donation-custom-amount { grid-column: 1 / -1; min-width: 0; display: grid; gap: 6px; }
.donation-donor-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.donation-form .checkbox-field { min-width: 0; max-width: 100%; display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 8px; align-items: start; }
.donation-form .checkbox-field input[type="checkbox"] { width: 16px; min-width: 16px; height: 16px; min-height: 16px; margin: 1px 0 0; padding: 0; }
.donation-form .checkbox-field span { min-width: 0; overflow-wrap: anywhere; }
.donation-form button { width: 100%; white-space: normal; overflow-wrap: anywhere; }
.donation-back { margin: 0; }
.donation-back a { color: var(--support); font: 900 14px/1.4 var(--site-ui-font, system-ui, sans-serif); text-decoration: none; }
.donation-status-card { max-width: 720px; }
@media (max-width: 820px) {
  main:has(.donations-page) { width: min(100% - 28px, 760px); }
  .donations-hero,
  .donation-detail-hero,
  .donation-detail-layout,
  .donation-donor-grid { grid-template-columns: 1fr; }
}
@media (max-width: 640px) {
  main:has(.donations-page) { width: min(100% - 24px, 760px); }
  .donations-grid { gap: 14px; }
  .donation-card-action,
  .donation-return-link { width: 100%; }
}
CSS
    close $fh;
}

sub _ensure_membership_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: public membership/;

    open my $fh, '>>', $path or die "cannot update theme membership css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: public membership. */
.members-page .member-form { display: grid; gap: 14px; max-width: 520px; padding: 16px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); box-shadow: var(--site-card-shadow, none); }
.members-page .member-form label { display: grid; gap: 6px; color: var(--muted); font: 800 12px/1.3 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.06em; }
.members-page .member-form input { width: 100%; min-height: 44px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 6px; background: var(--field); color: var(--ink); font: 15px/1.4 var(--site-ui-font, system-ui, sans-serif); letter-spacing: 0; }
.members-page .member-form button, .members-page .button-link, .members-page button.secondary { width: fit-content; max-width: 100%; min-height: 42px; padding: 10px 14px; border: 1px solid var(--accent); border-radius: 6px; background: var(--accent); color: var(--accent-ink, #fff); font: 900 13px/1.2 var(--site-ui-font, system-ui, sans-serif); letter-spacing: 0; text-decoration: none; cursor: pointer; }
.members-page button.secondary { border-color: var(--line); background: var(--field); color: var(--ink); }
.member-links { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; margin: 0; font: 800 14px/1.35 var(--site-ui-font, system-ui, sans-serif); }
CSS
    close $fh;
}

sub _ensure_theme_toggle_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    if ($body !~ /\.theme-toggle\s+\.theme-icon--moon\b/) {
        open my $fh, '>>', $path or die "cannot update theme css $path: $!";
        print {$fh} <<'CSS';

/* DesertCMS component upgrade: public theme toggle icons. */
.theme-toggle { width: 38px; height: 38px; min-width: 38px; min-height: 38px; display: inline-grid; place-items: center; }
.theme-toggle .theme-icon { display: block; width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.theme-toggle .theme-icon--sun { display: none; }
:root[data-theme="dark"] .theme-toggle .theme-icon--moon { display: none; }
:root[data-theme="dark"] .theme-toggle .theme-icon--sun { display: block; }
:root:not([data-theme="dark"]) .theme-toggle .theme-icon--moon { display: block; }
:root:not([data-theme="dark"]) .theme-toggle .theme-icon--sun { display: none; }
CSS
        close $fh;
        $body = _read_file($path);
    }

    return if $body =~ /\.theme-toggle\s*\{[^}]*border:\s*1px solid var\(--line\)/s
        && $body =~ /\.theme-toggle\s+\.theme-icon\b/;

    return if $body =~ /\.theme-toggle\s*\{[^}]*border:\s*0;/s
        && $body =~ /\.theme-toggle\s+\.theme-icon\b/;
    open my $fh, '>>', $path or die "cannot update theme css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: clean public theme toggle. */
.theme-toggle { width: 34px; height: 34px; min-width: 34px; min-height: 34px; display: inline-grid; place-items: center; border: 0; border-radius: 0; padding: 0; background: transparent; box-shadow: none; color: var(--accent); cursor: pointer; appearance: none; }
.theme-toggle:hover { background: transparent; color: var(--ink); }
.theme-toggle:focus-visible { outline: 2px solid var(--accent); outline-offset: 4px; }
.theme-toggle .theme-icon { width: 20px; height: 20px; }
CSS
    close $fh;
}

sub _ensure_theme_toggle_template {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'templates', 'layout.html');
    return unless -f $path;
    my $body = _read_file($path);
    my $original = $body;

    my $button = <<'HTML';
<button type="button" class="theme-toggle" data-theme-toggle aria-label="Toggle color theme">
        <svg class="theme-icon theme-icon--moon" viewBox="0 0 24 24" aria-hidden="true"><path d="M21 14.5A8.6 8.6 0 0 1 9.5 3a7 7 0 1 0 11.5 11.5Z"/></svg>
        <svg class="theme-icon theme-icon--sun" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
      </button>
HTML
    chomp $button;

    $body =~ s{<button type="button" class="theme-toggle" data-theme-toggle aria-label="Toggle color theme"(?: title="Toggle color theme")?>\s*Mode\s*</button>}{$button}s;
    $body =~ s{(<button type="button" class="theme-toggle" data-theme-toggle aria-label="Toggle color theme") title="Toggle color theme"(>)}{$1$2}g;
    $body =~ s{\s*<span class="sr-only">Toggle color theme</span>}{}g;
    $body =~ s{button\.textContent = next === 'dark' \? 'Light' : 'Dark';}{button.setAttribute('data-theme-state', next);\n        button.setAttribute('aria-label', next === 'dark' ? 'Switch to light mode' : 'Switch to dark mode');}s;
    $body =~ s{\n\s*button\.setAttribute\('title', next === 'dark' \? 'Switch to light mode' : 'Switch to dark mode'\);}{}g;
    $body =~ s{try \{\s*if \(localStorage\.getItem\('desert-theme'\) === 'dark'\) \{\s*document\.documentElement\.setAttribute\('data-theme', 'dark'\);\s*\}\s*\} catch \(error\) \{\}}{try {\n    var defaultTheme = '{{default_theme_mode}}';\n    if (defaultTheme === 'dark') {\n      document.documentElement.setAttribute('data-theme', 'dark');\n    } else {\n      document.documentElement.setAttribute('data-theme', 'light');\n    }\n  } catch (error) {}}s;
    $body =~ s{var storedTheme = localStorage\.getItem\('desert-theme'\);\s*var defaultTheme = '\{\{default_theme_mode\}\}';\s*if \(\(storedTheme \|\| defaultTheme\) === 'dark'\) \{\s*document\.documentElement\.setAttribute\('data-theme', 'dark'\);\s*\} else \{\s*document\.documentElement\.setAttribute\('data-theme', 'light'\);\s*\}}{var defaultTheme = '{{default_theme_mode}}';\n    if (defaultTheme === 'dark') {\n      document.documentElement.setAttribute('data-theme', 'dark');\n    } else {\n      document.documentElement.setAttribute('data-theme', 'light');\n    }}s;
    $body =~ s{try \{\s*localStorage\.setItem\('desert-theme', next\);\s*\} catch \(error\) \{\}\s*}{}g;
    $body =~ s{var stored = 'light';\s*try \{\s*stored = localStorage\.getItem\('desert-theme'\) \|\| 'light';\s*\} catch \(error\) \{\}}{var stored = '{{default_theme_mode}}';}s;
    $body =~ s{var stored = '\{\{default_theme_mode\}\}';\s*try \{\s*stored = localStorage\.getItem\('desert-theme'\) \|\| stored;\s*\} catch \(error\) \{\}}{var stored = '{{default_theme_mode}}';}s;

    return if $body eq $original;
    open my $fh, '>', $path or die "cannot update theme template $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _ensure_theme_style_template {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'templates', 'layout.html');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\{\{theme_style\}\}/;

    my $original = $body;
    $body =~ s{(<link rel="stylesheet" href="/assets/site\.css">\s*)}{$1 . "{{theme_style}}\n"}se;
    return if $body eq $original;

    open my $fh, '>', $path or die "cannot update theme template $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _ensure_site_brand_template {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'templates', 'layout.html');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\{\{site_brand\}\}/;

    my $original = $body;
    $body =~ s{(<a class="(?:site-name|\{\{brand_class\}\})" href="/">)\{\{site_name\}\}(</a>)}{$1 . '{{site_brand}}' . $2}eg;
    return if $body eq $original;

    open my $fh, '>', $path or die "cannot update theme site brand template $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _ensure_site_layout_template {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'templates', 'layout.html');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\{\{body_class\}\}/
        && $body =~ /\{\{header_class\}\}/
        && $body =~ /\{\{footer_brand\}\}/;

    my $original = $body;
    $body =~ s{<body>}{<body class="{{body_class}}">}s;
    $body =~ s{<header class="site-header">}{<header class="{{header_class}}">}s;
    $body =~ s{<a class="site-name" href="/">}{<a class="{{brand_class}}" href="/">}s;
    $body =~ s{<div class="site-actions">}{<div class="{{site_actions_class}}">}s;
    $body =~ s{<nav>\s*\{\{navigation\}\}\s*</nav>}{<nav class="{{nav_class}}">\n        {{navigation}}\n      </nav>}s;
    $body =~ s{<main>}{<main class="{{main_class}}">}s;
    $body =~ s{<footer class="site-footer">\s*<div>\s*<strong>\{\{site_name\}\}</strong>\s*<p>\{\{site_description\}\}</p>\s*</div>\s*<nav>\s*\{\{navigation\}\}\s*</nav>\s*<small>&copy; \{\{year\}\} \{\{site_name\}\}</small>\s*</footer>}{<footer class="{{footer_class}}">\n    {{footer_brand}}\n    {{footer_navigation}}\n    {{footer_credit}}\n  </footer>}s;
    return if $body eq $original;

    open my $fh, '>', $path or die "cannot update theme layout template $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _ensure_mobile_nav_template {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'templates', 'layout.html');
    return unless -f $path;
    my $body = _read_file($path);
    my $original = $body;

    if ($body !~ /classList\.add\('has-js'\)/) {
        $body =~ s{(<script>\s*)}{$1 . "  document.documentElement.classList.add('has-js');\n"}se;
    }
    if ($body !~ /data-site-menu-toggle/) {
        my $button = <<'HTML';
<button type="button" class="site-menu-toggle" data-site-menu-toggle aria-controls="site-primary-nav" aria-expanded="false" aria-label="Open navigation">
        <svg class="site-menu-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg>
      </button>
      
HTML
        chomp $button;
        $body =~ s{(<nav class="\{\{nav_class\}\}")}{$button$1}s;
    }
    $body =~ s{<nav class="\{\{nav_class\}\}">}{<nav id="site-primary-nav" class="{{nav_class}}" data-site-menu>}s
        unless $body =~ /id="site-primary-nav"/;
    if ($body !~ /data-site-menu/) {
        $body =~ s{<nav id="site-primary-nav" class="\{\{nav_class\}\}">}{<nav id="site-primary-nav" class="{{nav_class}}" data-site-menu>}s;
    }
    if ($body !~ /setMenu\(open\)/) {
        $body =~ s{(var button = document\.querySelector\('\[data-theme-toggle\]'\);\s*)}{$1    var menuButton = document.querySelector('[data-site-menu-toggle]');\n    var menu = document.querySelector('[data-site-menu]');\n    var header = menuButton ? menuButton.closest('.site-header') : null;\n}s;
        my $menu_js = <<'JS';
    function setMenu(open) {
      if (!menuButton || !header) {
        return;
      }
      header.classList.toggle('is-menu-open', open);
      menuButton.setAttribute('aria-expanded', open ? 'true' : 'false');
      menuButton.setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
    }
    function normalizePath(path) {
      if (!path) {
        return '/';
      }
      return path.replace(/\/index\.html$/, '/').replace(/\/+$/, '/') || '/';
    }
    if (menu) {
      var current = normalizePath(window.location.pathname);
      Array.prototype.forEach.call(menu.querySelectorAll('a[href]'), function (link) {
        var href = link.getAttribute('href') || '';
        if (/^https?:\/\//i.test(href)) {
          return;
        }
        if (normalizePath(href.split('#')[0].split('?')[0]) === current) {
          link.setAttribute('aria-current', 'page');
          link.classList.add('active');
        }
      });
    }
    if (menuButton) {
      menuButton.addEventListener('click', function () {
        setMenu(!(header && header.classList.contains('is-menu-open')));
      });
      if (menu) {
        menu.addEventListener('click', function (event) {
          if (event.target && event.target.closest('a')) {
            setMenu(false);
          }
        });
      }
      document.addEventListener('keydown', function (event) {
        if (event.key === 'Escape') {
          setMenu(false);
        }
      });
      window.addEventListener('resize', function () {
        if (window.matchMedia('(min-width: 821px)').matches) {
          setMenu(false);
        }
      });
    }
JS
        $body =~ s{(\s*\}\(\)\);\s*</script>)}{\n$menu_js$1}s;
    }

    return if $body eq $original;
    open my $fh, '>', $path or die "cannot update theme mobile nav template $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _ensure_site_layout_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.site-brand-lockup\b/
        && $body =~ /--site-content-width\b/
        && $body =~ /\.site-footer-order--nav-brand-credit\b/;

    open my $fh, '>>', $path or die "cannot update theme css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: site customization layout controls. */
.site-name { gap: 10px; }
.site-brand-lockup { min-width: 0; display: inline-flex; align-items: center; gap: 10px; }
.site-brand-text { overflow-wrap: anywhere; }
.site-logo { width: min(var(--site-logo-max-width, 240px), 58vw); height: var(--site-logo-max-height, 52px); object-fit: var(--site-logo-object-fit, contain); object-position: var(--site-logo-object-position, 50% 50%); }
.site-header { padding: var(--site-header-padding-y, 0) var(--site-header-padding-x, 32px); }
.site-header--centered { min-height: 0; flex-direction: column; justify-content: center; text-align: center; padding-top: max(18px, var(--site-header-padding-y, 0px)); padding-bottom: max(18px, var(--site-header-padding-y, 0px)); }
.site-header--centered .site-actions, .site-header--centered nav { justify-content: center; }
.site-header--stacked { min-height: 0; flex-direction: column; align-items: flex-start; padding-top: max(16px, var(--site-header-padding-y, 0px)); padding-bottom: max(16px, var(--site-header-padding-y, 0px)); }
.site-header--stacked .site-actions { width: 100%; justify-content: space-between; }
.site-header--compact { min-height: 58px; gap: 16px; }
.site-logo-size--small .site-logo { width: min(var(--site-logo-max-width, 170px), 52vw); height: var(--site-logo-max-height, 38px); }
.site-logo-size--large .site-logo { width: min(var(--site-logo-max-width, 320px), 64vw); height: var(--site-logo-max-height, 76px); }
.site-nav--underline a { border-bottom: 2px solid transparent; padding-bottom: 4px; }
.site-nav--underline a:hover, .site-nav--underline a:focus-visible { border-color: var(--accent); color: var(--accent); }
.site-nav--pills a, .site-nav--buttons a { min-height: 34px; display: inline-flex; align-items: center; border: 1px solid var(--line); border-radius: 999px; padding: 0 12px; background: var(--field); }
.site-nav--buttons a { border-radius: 6px; background: var(--panel); }
.site-nav--pills a:hover, .site-nav--buttons a:hover, .site-nav--pills a:focus-visible, .site-nav--buttons a:focus-visible { border-color: var(--accent); color: var(--accent); }
.site-main { width: min(var(--site-content-width, 760px), calc(100% - 32px)); margin: var(--site-main-margin, 64px) auto; min-height: 50vh; }
.site-main:has(.map-page) { width: min(1180px, calc(100% - 32px)); }
.site-main--wide { width: min(1040px, calc(100% - 32px)); }
.site-main--full { width: min(1280px, calc(100% - 24px)); }
.site-layout--home.site-home--landing .site-main, .site-layout--home.site-home--gallery .site-main { width: min(1120px, calc(100% - 32px)); }
.site-layout--home.site-home--editorial .site-main { width: min(820px, calc(100% - 32px)); }
.site-layout--home.site-home--landing .content > h1:first-child { font-size: clamp(54px, 8vw, 96px); max-width: 980px; }
.site-footer-brand { order: 1; }
.site-footer-nav { order: 2; display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 14px; }
.site-footer-credit { order: 3; grid-column: 1 / -1; color: var(--muted); }
.site-footer--compact { align-items: center; padding: 20px 32px; }
.site-footer--compact .site-footer-brand p { display: none; }
.site-footer--minimal { grid-template-columns: 1fr; justify-items: center; text-align: center; padding: 22px 24px; }
.site-footer--minimal .site-footer-brand { display: none; }
.site-footer--minimal .site-footer-nav { justify-content: center; }
.site-footer--hidden { display: none; }
.site-footer-order--nav-brand-credit .site-footer-brand { order: 2; }
.site-footer-order--nav-brand-credit .site-footer-nav { order: 1; justify-content: flex-start; }
.site-footer-order--credit-brand-nav .site-footer-credit { order: 1; grid-column: auto; }
.site-footer-order--credit-brand-nav .site-footer-brand { order: 2; }
.site-footer-order--credit-brand-nav .site-footer-nav { order: 3; }
@media (max-width: 820px) { .site-main { width: min(100% - 28px, 760px); margin: 38px auto; } .site-footer, .site-footer-nav { align-items: flex-start; justify-content: flex-start; } }
@media (max-width: 430px) { .site-main { width: min(100% - 24px, 760px); margin: 30px auto; } }
CSS
    close $fh;
}

sub _ensure_logo_fit_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.site-logo\s*\{[^}]*--site-logo-object-fit/s
        && $body =~ /--site-logo-object-position\b/;

    open my $fh, '>>', $path or die "cannot update theme css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: logo fit controls. */
.site-logo { width: min(var(--site-logo-max-width, 240px), 58vw); height: var(--site-logo-max-height, 52px); object-fit: var(--site-logo-object-fit, contain); object-position: var(--site-logo-object-position, 50% 50%); }
.site-logo-size--small .site-logo { width: min(var(--site-logo-max-width, 170px), 52vw); height: var(--site-logo-max-height, 38px); }
.site-logo-size--large .site-logo { width: min(var(--site-logo-max-width, 320px), 64vw); height: var(--site-logo-max-height, 76px); }
@media (max-width: 430px) { .site-logo { width: min(var(--site-logo-max-width, 240px), calc(100vw - 40px)); height: min(var(--site-logo-max-height, 52px), 46px); } }
CSS
    close $fh;
}

sub _ensure_mobile_nav_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.site-menu-toggle\b/
        && $body =~ /\.has-js\s+\.site-header:not\(\.is-menu-open\)\s+nav\b/;

    open my $fh, '>>', $path or die "cannot update theme mobile nav css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: mobile navigation menu. */
.site-header { position: relative; }
.site-menu-toggle { display: none; width: 34px; height: 34px; min-width: 34px; min-height: 34px; place-items: center; border: 0; border-radius: 0; padding: 0; background: transparent; color: var(--accent); cursor: pointer; appearance: none; }
.site-menu-toggle:hover { color: var(--ink); }
.site-menu-toggle:focus-visible { outline: 2px solid var(--accent); outline-offset: 4px; }
.site-menu-icon { width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.site-header nav a.active, .site-header nav a[aria-current="page"] { color: var(--accent); }
@media (max-width: 820px) {
  .site-header { min-height: 0; display: flex; flex-direction: row; flex-wrap: wrap; padding: 14px 16px; align-items: center; justify-content: space-between; gap: 12px; }
  .site-name { flex: 1 1 0; min-width: 0; max-width: calc(100% - 96px); overflow-wrap: anywhere; }
  .site-actions { display: contents; }
  .site-menu-toggle { order: 2; display: inline-grid; }
  .theme-toggle { order: 3; }
  .site-header nav { order: 4; flex: 1 0 100%; min-width: 0; display: grid; grid-template-columns: 1fr; gap: 6px; overflow: visible; padding: 10px; border: 1px solid var(--line); border-radius: 8px; background: var(--field); box-shadow: 0 16px 36px rgba(16, 32, 51, 0.12); }
  .has-js .site-header:not(.is-menu-open) nav { display: none; }
  .site-header nav a { min-height: 44px; display: inline-flex; align-items: center; justify-content: flex-start; border: 1px solid var(--line); border-radius: 6px; padding: 0 14px; background: var(--panel); }
}
CSS
    close $fh;
}

sub _ensure_public_form_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.public-form-section\b/
        && $body =~ /\.public-upload-preview\b/
        && $body =~ /\.field-counter\b/;

    open my $fh, '>>', $path or die "cannot update theme public form css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: public form groups, counters, and upload previews. */
.public-form label > span, .public-form-section legend { color: var(--muted); font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.08em; }
.public-form-section { min-width: 0; display: grid; gap: 12px; margin: 0; padding: 14px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--field); }
.public-form-section legend { padding: 0 6px; }
.public-form-section--wide { width: 100%; }
.public-field, .public-count-field, .public-upload-field { min-width: 0; }
.public-field--full { grid-column: 1 / -1; }
.field-help, .field-counter { color: var(--muted); font: 12px/1.35 var(--site-ui-font, system-ui, sans-serif); }
.field-counter { justify-self: end; padding: 2px 0; font-weight: 800; }
.public-count-field.is-under-limit .field-counter, .public-count-field.is-over-limit .field-counter { color: #a33a2b; }
.public-count-field textarea:focus + .field-counter, .public-count-field textarea:focus ~ .field-counter { color: var(--support); }
.public-form-section-help { margin: -2px 0 0; }
.public-upload-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; }
.public-upload-field { display: grid; align-content: start; gap: 8px; padding: 12px; border: 1px solid var(--line); border-radius: var(--site-card-radius, 8px); background: var(--panel); }
.public-upload-preview { min-height: 58px; display: grid; grid-template-columns: 44px minmax(0, 1fr); align-items: center; gap: 10px; padding: 8px; border: 1px dashed var(--line); border-radius: 6px; background: var(--field); }
.public-upload-preview small { min-width: 0; overflow-wrap: anywhere; color: var(--muted); font: 12px/1.35 var(--site-ui-font, system-ui, sans-serif); text-transform: none; letter-spacing: 0; }
.public-form label .public-upload-preview, .public-form label .public-upload-thumb { text-transform: none; letter-spacing: 0; }
.public-upload-thumb { width: 44px; height: 44px; border-radius: 6px; background: var(--panel); background-position: center; background-size: cover; border: 1px solid var(--line); }
.public-upload-thumb.has-image { border-color: var(--support); }
@media (max-width: 640px) { .public-form { width: 100%; } .public-form-section { padding: 12px; } .public-form-grid, .public-upload-grid { grid-template-columns: 1fr; } .field-counter { justify-self: start; } .public-upload-field { padding: 10px; } }
CSS
    close $fh;
}

sub _ensure_public_site_polish_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.shop-shell\b/
        && $body =~ /\.contributor-card-media\b/
        && $body =~ /\.site-footer-nav a\b/
        && $body =~ /main:has\(\.contributors-page\)/;

    open my $fh, '>>', $path or die "cannot update theme public site polish css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: public site polish. */
body { overflow-x: hidden; }
.site-header { position: relative; z-index: 10; }
.site-name { min-width: 0; max-width: min(100%, 560px); min-height: 40px; display: inline-flex; align-items: center; gap: 10px; overflow-wrap: anywhere; }
.site-brand-lockup { min-width: 0; max-width: 100%; display: inline-flex; align-items: center; gap: 10px; }
.site-brand-text { min-width: 0; line-height: 1.15; overflow-wrap: anywhere; }
.site-logo { flex: 0 0 auto; display: block; width: min(var(--site-logo-max-width, 240px), 58vw); max-width: 100%; height: var(--site-logo-max-height, 52px); object-fit: var(--site-logo-object-fit, contain); object-position: var(--site-logo-object-position, 50% 50%); }
.site-header nav, .site-actions { min-width: 0; }
.site-nav--plain a, .site-nav--underline a { min-height: 34px; display: inline-flex; align-items: center; }
.site-footer { min-width: 0; gap: 18px; }
.site-footer-brand, .site-footer-nav, .site-footer-credit { min-width: 0; max-width: 100%; }
.site-footer-brand p, .site-footer-credit { overflow-wrap: anywhere; }
.site-footer-nav { display: flex; flex-wrap: wrap; gap: 10px 14px; }
.site-footer-nav a { min-height: 36px; display: inline-flex; align-items: center; color: var(--muted); text-decoration: none; }
.module-page { display: grid; gap: clamp(14px, 2vw, 24px); }
.module-page > .kicker { margin-bottom: -4px; }
.module-page > h1 { max-width: 13ch; }
.module-intro { max-width: 72ch; margin: 0; color: var(--muted); font: var(--site-intro-size, 18px)/1.55 var(--site-ui-font, system-ui, sans-serif); }
main:has(.contributors-page),
main:has(.contributor-request-block),
main:has(.forms-page),
main:has(.shop-page) { width: min(1080px, calc(100% - 32px)); }
.portfolio-grid, .contributors-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 260px), 1fr)); gap: 20px; margin-top: 6px; }
.portfolio-card, .contributor-card, .shop-card { display: grid; grid-template-rows: auto 1fr; overflow: hidden; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); box-shadow: var(--site-card-shadow, none); }
.portfolio-card { margin: 0; }
.portfolio-card img, .contributor-card img, .shop-card img { display: block; width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 0; background: var(--field); }
.portfolio-card figcaption, .contributor-card div, .shop-card-body { display: grid; gap: 9px; align-content: start; padding: 16px; }
.portfolio-card strong, .contributor-card h2, .shop-card h2 { margin: 0; color: var(--ink); font-family: var(--site-heading-font, Georgia, "Times New Roman", serif); font-size: var(--site-h3-size, 21px); line-height: 1.2; letter-spacing: 0; overflow-wrap: anywhere; }
.portfolio-card p, .contributor-card p, .shop-card p { margin: 0; color: var(--muted); font: 14px/1.5 var(--site-ui-font, system-ui, sans-serif); }
.portfolio-card span, .portfolio-card small, .portfolio-empty, .shop-empty { color: var(--muted); font-size: 13px; }
.portfolio-empty, .shop-empty { grid-column: 1 / -1; margin: 0; padding: 18px; border: 1px dashed var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--field); font: 800 14px/1.45 var(--site-ui-font, system-ui, sans-serif); }
.module-action-link { display: inline-flex; align-items: center; justify-content: center; min-height: 42px; width: max-content; max-width: 100%; padding: 0 16px; border: 1px solid var(--site-button-border, var(--accent)); border-radius: var(--site-button-radius, 6px); background: var(--site-button-bg, var(--accent)); color: var(--site-button-color, var(--button-ink)); box-shadow: var(--site-button-shadow, none); font: 800 var(--site-ui-size, 14px)/1 var(--site-ui-font, system-ui, sans-serif); text-decoration: none; }
.contributor-request-block { display: grid; gap: 18px; margin: 10px 0 24px; padding: clamp(16px, 3vw, 24px); border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); box-shadow: var(--site-card-shadow, none); }
.contributor-request-block h2 { margin: 0; font-family: var(--site-heading-font, Georgia, "Times New Roman", serif); font-size: var(--site-h2-size, 30px); line-height: 1.15; letter-spacing: 0; }
.contributor-request-block > p { margin: 0; max-width: 66ch; color: var(--muted); font: 16px/1.55 var(--site-ui-font, system-ui, sans-serif); }
.contributor-request-form, .public-form { width: 100%; }
.public-form { max-width: 820px; }
.public-form-grid { display: grid; grid-template-columns: repeat(2, minmax(min(100%, 220px), 1fr)); gap: 14px; }
.public-form input, .public-form textarea, .public-form select { max-width: 100%; }
.public-form input[type="file"] { min-height: 44px; padding: 8px 10px; }
.contributor-card figure { margin: 0; background: var(--field); }
.contributor-card-media { display: grid; place-items: center; aspect-ratio: 4 / 3; }
.contributor-card-media--empty { color: var(--accent); background: linear-gradient(135deg, color-mix(in srgb, var(--accent) 16%, var(--field)), var(--panel)); }
.contributor-card-media--empty span { width: 62px; height: 62px; display: inline-grid; place-items: center; border: 1px solid color-mix(in srgb, var(--accent) 42%, var(--line)); border-radius: 999px; background: var(--panel); color: var(--accent); font: 900 20px/1 var(--site-ui-font, system-ui, sans-serif); }
.contributor-card a { align-self: end; color: var(--support); font: 800 13px/1.3 var(--site-ui-font, system-ui, sans-serif); overflow-wrap: anywhere; text-decoration: none; }
.shop-shell { display: grid; gap: 24px; }
.shop-heading { display: grid; gap: 12px; max-width: 820px; }
.shop-heading h1, .shop-message h1 { margin: 0; font-size: clamp(38px, 7vw, var(--site-h1-size, 68px)); line-height: 1; letter-spacing: 0; }
.shop-heading p, .shop-message p { margin: 0; color: var(--muted); font: 18px/1.6 var(--site-ui-font, system-ui, sans-serif); }
.shop-assurance { padding: 13px 15px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--field); color: var(--ink) !important; }
.shop-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 300px), 1fr)); gap: 22px; align-items: start; }
.shop-card-body { gap: 14px; padding: 18px; }
.shop-kind { justify-self: start; min-height: 24px; display: inline-flex; align-items: center; border: 1px solid var(--site-card-border, var(--line)); border-radius: 999px; padding: 0 9px; background: var(--field); color: var(--muted); font: 800 12px/1 var(--site-ui-font, system-ui, sans-serif); text-transform: uppercase; letter-spacing: 0.08em; }
.rights-grid { display: grid; gap: 10px; }
.rights-option { min-width: 0; display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 5px 12px; align-items: center; margin: 0; padding: 12px; border: 1px solid var(--line); border-radius: var(--site-card-radius, 8px); background: var(--field); font-family: var(--site-ui-font, system-ui, sans-serif); }
.rights-option--full { border-color: color-mix(in srgb, var(--accent) 55%, var(--line)); background: color-mix(in srgb, var(--accent) 8%, var(--field)); }
.rights-option strong { min-width: 0; font-size: 15px; overflow-wrap: anywhere; }
.rights-option span { font-weight: 800; color: var(--accent); white-space: nowrap; }
.rights-option small { grid-column: 1 / -1; color: var(--muted); line-height: 1.35; }
.rights-option button, .shop-button { min-height: 42px; border: 1px solid var(--site-button-border, var(--accent)); border-radius: var(--site-button-radius, 6px); padding: 0 14px; background: var(--site-button-bg, var(--accent)); color: var(--site-button-color, var(--button-ink)); box-shadow: var(--site-button-shadow, none); font: 800 14px/1 var(--site-ui-font, system-ui, sans-serif); text-decoration: none; cursor: pointer; }
.shop-button--catalog { display: inline-flex; align-items: center; justify-content: center; width: fit-content; }
.shop-button--muted { border-color: var(--site-card-border, var(--line)); background: var(--field); color: var(--muted); cursor: default; }
.shop-notice { margin: 0; padding: 12px 14px; border: 1px solid var(--accent); border-left-width: 3px; border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); color: var(--ink); font-family: var(--site-ui-font, system-ui, sans-serif); }
.shop-message { max-width: 780px; }
.shop-summary { display: grid; gap: 10px; margin: 20px 0; font-family: var(--site-ui-font, system-ui, sans-serif); }
.shop-summary div { display: grid; grid-template-columns: 130px minmax(0, 1fr); gap: 14px; padding: 12px; border: 1px solid var(--site-card-border, var(--line)); border-radius: var(--site-card-radius, 8px); background: var(--site-card-bg, var(--panel)); }
@media (max-width: 820px) {
  .site-header { min-height: 0; flex-direction: row; flex-wrap: wrap; padding: 14px 16px; align-items: center; justify-content: space-between; gap: 12px; }
  .site-name { flex: 1 1 0; max-width: calc(100% - 96px); }
  .site-brand-lockup { max-width: 100%; }
  .site-brand-text { max-width: 48vw; }
  .site-actions { display: contents; }
  .site-main { width: min(100% - 28px, 760px); margin: 38px auto; }
  .site-footer { grid-template-columns: 1fr; justify-items: start; padding: 26px 18px; }
  .site-footer-nav { justify-content: flex-start; }
}
@media (max-width: 640px) {
  .module-action-link, .rights-option button, .shop-button { width: 100%; }
  .contributor-request-block { padding: 16px; }
  .public-form, main:has(.contributors-page), main:has(.contributor-request-block), main:has(.forms-page), main:has(.shop-page) { width: min(100% - 24px, 760px); }
  .public-form-grid, .public-upload-grid, .rights-option, .shop-summary div { grid-template-columns: 1fr; }
  .field-counter { justify-self: start; }
  .public-upload-field { padding: 10px; }
}
@media (max-width: 430px) {
  .site-logo { width: min(var(--site-logo-max-width, 240px), calc(100vw - 40px)); height: min(var(--site-logo-max-height, 52px), 46px); }
  .site-brand--logo-name .site-logo { width: min(var(--site-logo-max-width, 170px), 44vw); }
  .site-brand--logo-name .site-brand-text { font-size: 14px; }
  .site-main { width: min(100% - 24px, 760px); margin: 30px auto; }
  .content h1 { font-size: min(var(--site-h1-size, 36px), 36px); }
  .body { font-size: min(var(--site-body-size, 17px), 17px); }
  .site-footer { padding: 24px 14px; }
}
CSS
    close $fh;
}

sub _ensure_showcase_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: showcase resource cards/
        || $body =~ /\.showcase-resource-badge\b/;

    open my $fh, '>>', $path or die "cannot update theme showcase css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: showcase resource cards. */
.showcase-card--resource { grid-template-rows: auto 1fr; }
.showcase-resource-badge { display: grid; place-items: center; min-height: 180px; aspect-ratio: 4 / 3; border-bottom: 1px solid var(--site-card-border, var(--line)); background: var(--field); color: var(--accent); font: 900 clamp(24px, 7vw, 42px)/1 var(--site-ui-font, system-ui, sans-serif); letter-spacing: 0; }
.showcase-resource-badge span { display: inline-grid; place-items: center; min-width: 82px; min-height: 82px; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
.showcase-resource-body { display: grid; gap: 9px; align-content: start; padding: 16px; }
.showcase-resource-body strong { margin: 0; color: var(--ink); font-family: var(--site-heading-font, Georgia, "Times New Roman", serif); font-size: var(--site-h3-size, 21px); line-height: 1.2; letter-spacing: 0; overflow-wrap: anywhere; }
.showcase-resource-body p { margin: 0; color: var(--muted); font: 14px/1.5 var(--site-ui-font, system-ui, sans-serif); }
.showcase-resource-body span { color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }
.showcase-resource-body .module-action-link { margin-top: 4px; }
CSS
    close $fh;
}

sub _ensure_public_text_wrap_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: public long text wrapping/
        || ($body =~ /\.rich-text p\b[^}]*overflow-wrap:\s*anywhere/s
            && $body =~ /\.content-block p\b[^}]*overflow-wrap:\s*anywhere/s);

    open my $fh, '>>', $path or die "cannot update theme public text wrapping css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: public long text wrapping. */
.body, .content-block, .rich-text { min-width: 0; max-width: 100%; }
.rich-text, .rich-text p, .rich-text li, .content-block p { overflow-wrap: anywhere; }
CSS
    close $fh;
}

sub _ensure_responsive_visual_polish_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /DesertCMS component upgrade: responsive visual polish/
        || (
            $body =~ /--focus-ring:\s*color-mix/s
            && $body =~ /\.site-menu-toggle\s*\{[^}]*border:\s*1px solid var\(--line\)/s
            && $body =~ /\.theme-toggle\s*\{[^}]*border:\s*1px solid var\(--line\)/s
            && $body =~ /\.docs-table\s*\{[^}]*overflow-x:\s*auto/s
            && $body =~ /\.public-upload-preview\s*\{[^}]*grid-template-columns:\s*38px minmax\(0,\s*1fr\)/s
        );

    open my $fh, '>>', $path or die "cannot update theme responsive visual polish css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: responsive visual polish. */
:root { --focus-ring: color-mix(in srgb, var(--accent) 28%, transparent); --site-card-shadow: 0 10px 28px rgba(20, 32, 40, 0.07); }
:root[data-theme="dark"] { --focus-ring: color-mix(in srgb, var(--accent) 32%, transparent); }
.site-header { padding: max(12px, var(--site-header-padding-y, 12px)) var(--site-header-padding-x, 32px); }
.site-header nav { justify-content: flex-end; gap: 8px 14px; }
.site-actions { flex: 1 1 auto; gap: 12px; }
.site-menu-toggle, .theme-toggle { width: 38px; height: 38px; min-width: 38px; min-height: 38px; border: 1px solid var(--line); border-radius: 6px; background: var(--field); }
.site-menu-toggle:hover, .theme-toggle:hover { border-color: var(--accent); background: var(--panel); color: var(--ink); }
.site-menu-toggle:focus-visible, .theme-toggle:focus-visible, .site-header nav a:focus-visible, .site-footer a:focus-visible, .link-card:focus-visible, .content-ref-card:focus-visible, .social-link:focus-visible, .module-action-link:focus-visible, .contributor-card a:focus-visible, .shop-button:focus-visible, .rights-option button:focus-visible, .public-form button:focus-visible, .comment-form button:focus-visible, .docs-nav a:focus-visible { outline: 3px solid var(--focus-ring); outline-offset: 2px; }
.site-nav--plain a, .site-nav--underline a { border-radius: 6px; padding: 0 6px; line-height: 1.2; }
.link-card:hover, .content-ref-card:hover, .social-link:hover, .module-action-link:hover, .contributor-card:hover, .shop-card:hover, .docs-card:hover { border-color: var(--accent); }
.public-form input:focus, .public-form textarea:focus, .public-form select:focus { border-color: var(--accent); outline: 3px solid var(--focus-ring); outline-offset: 0; }
.public-form button, .rights-option button, .shop-button { transition: background 140ms ease, border-color 140ms ease, color 140ms ease, box-shadow 140ms ease; }
.public-form-section { padding: clamp(12px, 2.4vw, 16px); }
.public-upload-field { overflow: hidden; }
@media (max-width: 820px) {
  .site-header nav a { overflow-wrap: anywhere; }
  .site-header nav a.active, .site-header nav a[aria-current="page"] { border-color: color-mix(in srgb, var(--accent) 44%, var(--line)); background: color-mix(in srgb, var(--accent) 9%, var(--panel)); }
  .docs-table { display: block; max-width: 100%; overflow-x: auto; white-space: nowrap; }
}
@media (max-width: 640px) {
  .public-upload-preview { grid-template-columns: 38px minmax(0, 1fr); }
  .contributors-grid, .shop-grid, .docs-grid { gap: 14px; }
}
@media (max-width: 430px) {
  .docs-grid, .docs-nav { grid-template-columns: 1fr; }
  .docs-card { min-height: 0; }
  .docs-markdown h1 { font-size: 30px; }
  .docs-markdown h2 { font-size: 24px; }
}
CSS
    close $fh;
}

sub _ensure_public_form_template {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'templates', 'layout.html');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /data-character-counter/ && $body =~ /updateUploadPreview/;

    my $form_js = <<'JS';
    function updateCounter(field) {
      var container = field.closest ? field.closest('.public-count-field') : field.parentNode;
      var output = container ? container.querySelector('[data-counter-output]') : null;
      if (!output) {
        return;
      }
      var count = field.value.length;
      var min = parseInt(field.getAttribute('data-counter-min') || '0', 10);
      var max = parseInt(field.getAttribute('data-counter-max') || field.getAttribute('maxlength') || '0', 10);
      var text = max ? count + ' / ' + max + ' characters' : count + ' characters';
      if (min && count > 0 && count < min) {
        text += ' (' + (min - count) + ' more minimum)';
      }
      output.textContent = text;
      if (container) {
        container.classList.toggle('is-under-limit', !!(min && count > 0 && count < min));
        container.classList.toggle('is-over-limit', !!(max && count > max));
      }
    }
    function formatFileSize(bytes) {
      if (!bytes && bytes !== 0) {
        return '';
      }
      if (bytes >= 1048576) {
        return (bytes / 1048576).toFixed(1).replace(/\.0$/, '') + ' MB';
      }
      if (bytes >= 1024) {
        return Math.ceil(bytes / 1024) + ' KB';
      }
      return bytes + ' bytes';
    }
    function updateUploadPreview(field) {
      var container = field.closest ? field.closest('.public-upload-field') : field.parentNode;
      var output = container ? container.querySelector('[data-upload-preview-output]') : null;
      if (!output) {
        return;
      }
      var file = field.files && field.files[0] ? field.files[0] : null;
      output.textContent = '';
      var thumb = document.createElement('span');
      thumb.className = 'public-upload-thumb';
      thumb.setAttribute('aria-hidden', 'true');
      var label = document.createElement('small');
      if (!file) {
        label.textContent = 'No file selected';
        output.appendChild(thumb);
        output.appendChild(label);
        return;
      }
      label.textContent = file.name + ' (' + formatFileSize(file.size) + ')';
      output.appendChild(thumb);
      output.appendChild(label);
      if (/^image\//.test(file.type || '') && window.FileReader) {
        var reader = new FileReader();
        reader.onload = function (event) {
          thumb.style.backgroundImage = 'url("' + event.target.result + '")';
          thumb.classList.add('has-image');
        };
        reader.readAsDataURL(file);
      }
    }
    Array.prototype.forEach.call(document.querySelectorAll('[data-character-counter]'), function (field) {
      updateCounter(field);
      field.addEventListener('input', function () { updateCounter(field); });
    });
    Array.prototype.forEach.call(document.querySelectorAll('[data-upload-preview]'), function (field) {
      updateUploadPreview(field);
      field.addEventListener('change', function () { updateUploadPreview(field); });
    });
JS
    my $original = $body;
    $body =~ s{(\s*\}\(\)\);\s*</script>)}{\n$form_js$1}s;
    return if $body eq $original;
    open my $fh, '>', $path or die "cannot update theme public form template $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _ensure_public_map_tap_target_css {
    my ($dest) = @_;
    my $path = File::Spec->catfile($dest, 'assets', 'site.css');
    return unless -f $path;
    my $body = _read_file($path);
    return if $body =~ /\.slippy-map button\s*\{[^}]*min-width:\s*36px/s;

    open my $fh, '>>', $path or die "cannot update theme map tap target css $path: $!";
    print {$fh} <<'CSS';

/* DesertCMS component upgrade: public map tap targets. */
.slippy-map button { min-width: 36px; }
CSS
    close $fh;
}

sub _read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read theme file $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

1;
