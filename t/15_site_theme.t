use strict;
use warnings;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::SiteTheme;

my $site = {
    theme_light_preset => 'light-coast',
    theme_dark_preset  => 'dark-forest',
    theme_default_mode => 'dark',
    site_content_width => 'wide',
    site_spacing_scale => 'spacious',
    site_logo_size     => 'large',
    site_logo_fit      => 'cover',
    site_logo_focal_x  => '20',
    site_logo_focal_y  => '80',
    site_logo_max_width_px => '360',
    site_logo_max_height_px => '90',
    theme_heading_font => 'sans',
    theme_body_font    => 'sans',
    theme_ui_font      => 'serif',
    theme_heading_scale => 'large',
    theme_body_scale   => 'compact',
    theme_button_style => 'soft',
    theme_button_radius => 'pill',
    theme_card_style   => 'raised',
    theme_card_radius  => 'round',
};

is(DesertCMS::SiteTheme::selected_preset_id($site, 'light'), 'light-coast', 'selects explicit light preset');
is(DesertCMS::SiteTheme::selected_preset_id($site, 'dark'), 'dark-forest', 'selects explicit dark preset');
is(DesertCMS::SiteTheme::default_mode($site), 'dark', 'uses explicit default mode');

my $style = DesertCMS::SiteTheme::style_tag($site);
like($style, qr/:root,\n:root\[data-theme="light"\] \{[^}]*--paper: #edf7f8;/s, 'light CSS uses selected light palette');
like($style, qr/:root\[data-theme="dark"\] \{[^}]*--paper: #091511;/s, 'dark CSS uses selected dark palette');

my $vars = DesertCMS::SiteTheme::css_vars($site);
like($vars, qr/:root,\n:root\[data-theme="light"\] \{[^}]*--support: #0c7f8c;/s, 'raw CSS vars expose selected light theme');
like($vars, qr/:root\[data-theme="dark"\] \{[^}]*--support: #63c7b6;/s, 'raw CSS vars expose selected dark theme');
like($vars, qr/--site-content-width: 1040px;/, 'raw CSS vars expose selected content width token');
like($vars, qr/--site-main-margin: 86px;/, 'raw CSS vars expose selected spacing token');
like($vars, qr/--site-logo-max-width: 360px;/, 'raw CSS vars expose custom logo width token');
like($vars, qr/--site-logo-max-height: 90px;/, 'raw CSS vars expose custom logo height token');
like($vars, qr/--site-logo-object-fit: cover;/, 'raw CSS vars expose selected logo fit token');
like($vars, qr/--site-logo-object-position: 20% 80%;/, 'raw CSS vars expose selected logo focal token');
like($vars, qr/--site-heading-font: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;/, 'raw CSS vars expose selected heading font token');
like($vars, qr/--site-body-font: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;/, 'raw CSS vars expose selected body font token');
like($vars, qr/--site-ui-font: Georgia, "Times New Roman", serif;/, 'raw CSS vars expose selected interface font token');
like($vars, qr/--site-h1-size: 76px;/, 'raw CSS vars expose selected heading scale token');
like($vars, qr/--site-body-size: 18px;/, 'raw CSS vars expose selected body scale token');
like($vars, qr/--site-button-bg: color-mix\(in srgb, var\(--accent\) 15%, var\(--panel\)\);/, 'raw CSS vars expose selected button style token');
like($vars, qr/--site-button-radius: 999px;/, 'raw CSS vars expose selected button radius token');
like($vars, qr/--site-card-shadow: 0 14px 34px rgba\(16, 32, 51, 0\.12\);/, 'raw CSS vars expose selected card style token');
like($vars, qr/--site-card-radius: 16px;/, 'raw CSS vars expose selected card radius token');
unlike($vars, qr/<style>/, 'raw CSS vars omit style wrapper');

my $legacy_dark = {
    theme_preset      => 'dark-canyon',
    theme_custom_mode => 'light',
};
is(DesertCMS::SiteTheme::selected_preset_id($legacy_dark, 'dark'), 'dark-canyon', 'legacy dark preset seeds dark slot');
is(DesertCMS::SiteTheme::selected_preset_id($legacy_dark, 'light'), 'light-archive', 'legacy dark preset keeps default light slot');
is(DesertCMS::SiteTheme::default_mode($legacy_dark), 'dark', 'legacy dark preset keeps dark default');

my $legacy_light = {
    theme_preset => 'light-sage',
};
is(DesertCMS::SiteTheme::selected_preset_id($legacy_light, 'light'), 'light-sage', 'legacy light preset seeds light slot');
is(DesertCMS::SiteTheme::selected_preset_id($legacy_light, 'dark'), 'dark-archive', 'legacy light preset keeps default dark slot');
is(DesertCMS::SiteTheme::default_mode($legacy_light), 'light', 'legacy light preset keeps light default');

done_testing;
