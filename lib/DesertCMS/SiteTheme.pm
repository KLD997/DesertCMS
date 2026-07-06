package DesertCMS::SiteTheme;

use strict;
use warnings;
use DesertCMS::FontPackages;

my @PRESETS = (
    {
        id   => 'light-archive',
        name => 'Archive Light',
        mode => 'light',
        vars => {
            ink => '#102033', muted => '#617284', paper => '#eef3f6',
            panel => '#ffffff', field => '#f8fafc', line => '#d9e3ea',
            accent => '#b7791f', accent_dark => '#8b5e16', support => '#0e7490',
            button_ink => '#ffffff',
        },
    },
    {
        id   => 'light-gallery',
        name => 'Showcase White',
        mode => 'light',
        vars => {
            ink => '#18212b', muted => '#66707a', paper => '#f5f7f8',
            panel => '#ffffff', field => '#edf2f5', line => '#d8e0e6',
            accent => '#9a6a24', accent_dark => '#704a18', support => '#187882',
            button_ink => '#ffffff',
        },
    },
    {
        id   => 'light-kinetic',
        name => 'Kinetic Light',
        mode => 'light',
        design_system => 'kinetic',
        recommended_fonts => {
            theme_heading_font => 'bundled:space-grotesk',
            theme_body_font    => 'bundled:space-grotesk',
            theme_ui_font      => 'bundled:space-grotesk',
        },
        vars => {
            ink => '#09090B', muted => '#52525B', paper => '#FAFAFA',
            panel => '#FFFFFF', field => '#F4F4F5', line => '#18181B',
            accent => '#DFE104', accent_dark => '#B8BA00', support => '#09090B',
            button_ink => '#09090B',
        },
    },
    {
        id   => 'light-sage',
        name => 'Sage Field',
        mode => 'light',
        vars => {
            ink => '#18302c', muted => '#64746e', paper => '#eef4ef',
            panel => '#ffffff', field => '#f5faf6', line => '#d5e1da',
            accent => '#b9821d', accent_dark => '#7f5914', support => '#2b7a78',
            button_ink => '#ffffff',
        },
    },
    {
        id   => 'light-clay',
        name => 'Clay Museum',
        mode => 'light',
        vars => {
            ink => '#251f1b', muted => '#756b63', paper => '#f1eee9',
            panel => '#ffffff', field => '#faf7f2', line => '#e0d8cc',
            accent => '#b36b2c', accent_dark => '#81451d', support => '#316f7a',
            button_ink => '#ffffff',
        },
    },
    {
        id   => 'light-coast',
        name => 'Coastal Light',
        mode => 'light',
        vars => {
            ink => '#102a32', muted => '#5f7380', paper => '#edf7f8',
            panel => '#ffffff', field => '#f4fbfb', line => '#d4e7ea',
            accent => '#c29218', accent_dark => '#8a650e', support => '#0c7f8c',
            button_ink => '#ffffff',
        },
    },
    {
        id   => 'dark-archive',
        name => 'Archive Dark',
        mode => 'dark',
        vars => {
            ink => '#f4ead7', muted => '#bac7c2', paper => '#071225',
            panel => '#10213f', field => '#0b1a31', line => '#304563',
            accent => '#f0b92d', accent_dark => '#d8a21b', support => '#56d0c8',
            button_ink => '#071225',
        },
    },
    {
        id   => 'dark-gallery',
        name => 'Showcase Black',
        mode => 'dark',
        vars => {
            ink => '#f6f0e5', muted => '#b5b7b4', paper => '#0c0d0f',
            panel => '#181b1f', field => '#111418', line => '#30353b',
            accent => '#e7af32', accent_dark => '#c89324', support => '#67c5c8',
            button_ink => '#0c0d0f',
        },
    },
    {
        id   => 'dark-kinetic',
        name => 'Kinetic Dark',
        mode => 'dark',
        design_system => 'kinetic',
        recommended_fonts => {
            theme_heading_font => 'bundled:space-grotesk',
            theme_body_font    => 'bundled:space-grotesk',
            theme_ui_font      => 'bundled:space-grotesk',
        },
        vars => {
            ink => '#FAFAFA', muted => '#A1A1AA', paper => '#09090B',
            panel => '#18181B', field => '#111113', line => '#3F3F46',
            accent => '#DFE104', accent_dark => '#B8BA00', support => '#FAFAFA',
            button_ink => '#09090B',
        },
    },
    {
        id   => 'dark-canyon',
        name => 'Canyon Night',
        mode => 'dark',
        vars => {
            ink => '#f7e6d0', muted => '#cab8a2', paper => '#1b120f',
            panel => '#2a1c16', field => '#211611', line => '#574033',
            accent => '#f0b13b', accent_dark => '#cf8830', support => '#72d2c8',
            button_ink => '#1b120f',
        },
    },
    {
        id   => 'dark-navy',
        name => 'Navy Studio',
        mode => 'dark',
        vars => {
            ink => '#eef4f8', muted => '#b6c3ce', paper => '#07101c',
            panel => '#101f34', field => '#0b1727', line => '#2a3f59',
            accent => '#edbd3c', accent_dark => '#c99925', support => '#5fcbd3',
            button_ink => '#07101c',
        },
    },
    {
        id   => 'dark-forest',
        name => 'Forest Dark',
        mode => 'dark',
        vars => {
            ink => '#edf3e7', muted => '#b6c1b1', paper => '#091511',
            panel => '#11251d', field => '#0d1c16', line => '#30463a',
            accent => '#d9a726', accent_dark => '#b1841b', support => '#63c7b6',
            button_ink => '#091511',
        },
    },
);

my %BY_ID = map { $_->{id} => $_ } @PRESETS;

sub presets {
    return [@PRESETS];
}

sub presets_for_mode {
    my ($mode) = @_;
    $mode = $mode && $mode eq 'dark' ? 'dark' : 'light';
    return [grep { $_->{mode} eq $mode } @PRESETS];
}

sub preset_by_id {
    my ($id) = @_;
    return $BY_ID{$id || ''} || $PRESETS[0];
}

sub is_kinetic {
    my ($site, $mode) = @_;
    $site ||= {};
    if (defined $mode && length $mode) {
        return _preset_is_kinetic(selected_preset_id($site, $mode));
    }
    my $default = default_mode($site);
    return _preset_is_kinetic(selected_preset_id($site, $default));
}

sub recommended_fonts_for_preset {
    my ($id) = @_;
    my $preset = $BY_ID{$id || ''} || return {};
    return { %{ $preset->{recommended_fonts} || {} } };
}

sub selected_preset_id {
    my ($site, $mode) = @_;
    $mode = $mode && $mode eq 'dark' ? 'dark' : 'light';
    my $key = "theme_${mode}_preset";
    my $id = $site->{$key} || '';
    return 'custom' if $id eq 'custom';
    return $id if _preset_matches_mode($id, $mode);

    my $legacy = $site->{theme_preset} || '';
    return 'custom' if $legacy eq 'custom' && (($site->{theme_custom_mode} || 'light') eq $mode);
    return $legacy if _preset_matches_mode($legacy, $mode);

    return $mode eq 'dark' ? 'dark-archive' : 'light-archive';
}

sub default_mode {
    my ($site) = @_;
    return 'dark' if ($site->{theme_default_mode} || '') eq 'dark';
    return 'light' if ($site->{theme_default_mode} || '') eq 'light';

    my $legacy = $site->{theme_preset} || '';
    return 'dark' if $legacy eq 'custom' && ($site->{theme_custom_mode} || '') eq 'dark';
    return _preset_matches_mode($legacy, 'dark') ? 'dark' : 'light';
}

sub style_tag {
    my ($site, %args) = @_;
    my $css = css_vars($site, %args);
    return "<style>\n$css</style>\n";
}

sub css_vars {
    my ($site, %args) = @_;
    my $light = _theme_for_mode($site, 'light');
    my $dark = _theme_for_mode($site, 'dark');
    my $background = _background_value($site);
    my $layout = _layout_vars($site);
    my @kinetic_fonts = (is_kinetic($site, 'light') || is_kinetic($site, 'dark')) ? ('bundled:space-grotesk') : ();
    my $font_faces = $args{config}
        ? DesertCMS::FontPackages::font_face_css($args{config}, $site, include_bundled => \@kinetic_fonts)
        : '';

    return $font_faces
        . ':root,' . "\n" . ':root[data-theme="light"] {' . "\n"
        . _vars_css($light->{vars})
        . _layout_css($layout)
        . "  --site-background-image: $background;\n"
        . "}\n"
        . ':root[data-theme="dark"] {' . "\n"
        . _vars_css($dark->{vars})
        . _layout_css($layout)
        . "  --site-background-image: $background;\n"
        . "}\n";
}

sub custom_settings_defaults {
    my $base = preset_by_id('light-archive');
    return {
        theme_custom_name => 'Custom Theme',
        theme_custom_mode => 'light',
        map { ("theme_custom_$_" => $base->{vars}->{$_}) } _var_names()
    };
}

sub _selected_theme {
    my ($site) = @_;
    my $preset = $site->{theme_preset} || 'light-archive';
    return _custom_theme($site) if $preset eq 'custom';
    return preset_by_id($preset);
}

sub _theme_for_mode {
    my ($site, $mode) = @_;
    my $id = selected_preset_id($site, $mode);
    return _custom_theme($site, $mode) if $id eq 'custom';
    return preset_by_id($id);
}

sub _custom_theme {
    my ($site, $mode) = @_;
    my $defaults = custom_settings_defaults();
    my %vars;
    for my $name (_var_names()) {
        my $key = "theme_custom_$name";
        $vars{$name} = _valid_color($site->{$key}) ? $site->{$key} : $defaults->{$key};
    }
    return {
        id   => 'custom',
        name => $site->{theme_custom_name} || 'Custom Theme',
        mode => $mode && $mode eq 'dark' ? 'dark' : (($site->{theme_custom_mode} || '') eq 'dark' ? 'dark' : 'light'),
        vars => \%vars,
    };
}

sub _preset_matches_mode {
    my ($id, $mode) = @_;
    return 0 unless defined $id && exists $BY_ID{$id};
    return $BY_ID{$id}->{mode} eq $mode ? 1 : 0;
}

sub _preset_is_kinetic {
    my ($id) = @_;
    return 0 unless defined $id && exists $BY_ID{$id};
    return ($BY_ID{$id}->{design_system} || '') eq 'kinetic' ? 1 : 0;
}

sub _vars_css {
    my ($vars) = @_;
    my $css = '';
    for my $name (_var_names()) {
        my $css_name = $name;
        $css_name =~ tr/_/-/;
        my $value = _valid_color($vars->{$name}) ? $vars->{$name} : '#000000';
        $css .= "  --$css_name: $value;\n";
    }
    return $css;
}

sub _background_value {
    my ($site) = @_;
    my $path = $site->{site_background_image_path} || '';
    return 'none' unless $path =~ m{\A/assets/site/background\.jpg\z};
    return 'url("' . $path . '")';
}

sub _layout_vars {
    my ($site) = @_;
    my $width = _choice($site->{site_content_width}, 'standard', qw(narrow standard wide full));
    my $spacing = _choice($site->{site_spacing_scale}, 'comfortable', qw(compact comfortable spacious));
    my $logo = _choice($site->{site_logo_size}, 'medium', qw(small medium large));
    my $logo_fit = _choice($site->{site_logo_fit}, 'contain', qw(contain cover));
    my $heading_font = DesertCMS::FontPackages::clean_font_id($site->{theme_heading_font}, 'serif');
    my $body_font = DesertCMS::FontPackages::clean_font_id($site->{theme_body_font}, 'serif');
    my $ui_font = DesertCMS::FontPackages::clean_font_id($site->{theme_ui_font}, 'sans');
    my $heading_scale = _choice($site->{theme_heading_scale}, 'standard', qw(compact standard large));
    my $body_scale = _choice($site->{theme_body_scale}, 'standard', qw(compact standard large));
    my $button_style = _choice($site->{theme_button_style}, 'solid', qw(solid outline soft));
    my $button_radius = _choice($site->{theme_button_radius}, 'soft', qw(square soft pill));
    my $card_style = _choice($site->{theme_card_style}, 'outlined', qw(flat outlined raised));
    my $card_radius = _choice($site->{theme_card_radius}, 'soft', qw(square soft round));
    my $background_effect = _choice($site->{theme_background_effect}, 'none', qw(none wash grain vignette));
    my $motion_effect = _choice($site->{theme_motion_effect}, 'none', qw(none subtle lift));
    my $lighting_effect = _choice($site->{theme_lighting_effect}, 'none', qw(none soft glow));
    my $box_shape = _choice($site->{theme_box_shape}, 'soft', qw(square soft round pill));
    my $gradient_style = _choice($site->{theme_gradient_style}, 'none', qw(none accent split sheen));
    my $box_transparency = _percent_int($site->{theme_box_transparency}, 0, 0, 80);
    my $outline_transparency = _percent_int($site->{theme_outline_transparency}, 0, 0, 80);

    my %widths = (
        narrow   => '660px',
        standard => '760px',
        wide     => '1040px',
        full     => '1280px',
    );
    my %spacing_values = (
        compact     => { main => '38px', section => '24px', header_y => '10px', header_x => '24px' },
        comfortable => { main => '64px', section => '36px', header_y => '0px',  header_x => '32px' },
        spacious    => { main => '86px', section => '52px', header_y => '12px', header_x => '42px' },
    );
    my %logos = (
        small  => { width => '170px', height => '38px' },
        medium => { width => '240px', height => '52px' },
        large  => { width => '320px', height => '76px' },
    );
    my %heading_sizes = (
        compact  => { h1 => '52px', h2 => '30px', h3 => '23px', hero => '72px' },
        standard => { h1 => '64px', h2 => '34px', h3 => '26px', hero => '96px' },
        large    => { h1 => '76px', h2 => '42px', h3 => '32px', hero => '112px' },
    );
    my %body_sizes = (
        compact  => { body => '18px', intro => '18px', line => '1.58', ui => '14px' },
        standard => { body => '20px', intro => '20px', line => '1.65', ui => '14px' },
        large    => { body => '22px', intro => '22px', line => '1.72', ui => '15px' },
    );
    my %button_styles = (
        solid => {
            bg     => 'var(--accent)',
            hover  => 'var(--accent-dark)',
            border => 'var(--accent)',
            color  => 'var(--button-ink)',
            shadow => 'none',
        },
        outline => {
            bg     => 'transparent',
            hover  => 'color-mix(in srgb, var(--accent) 10%, transparent)',
            border => 'var(--accent)',
            color  => 'var(--accent)',
            shadow => 'none',
        },
        soft => {
            bg     => 'color-mix(in srgb, var(--accent) 15%, var(--panel))',
            hover  => 'color-mix(in srgb, var(--accent) 24%, var(--panel))',
            border => 'color-mix(in srgb, var(--accent) 36%, var(--line))',
            color  => 'var(--accent-dark)',
            shadow => '0 8px 22px rgba(16, 32, 51, 0.10)',
        },
    );
    my %button_radii = (
        square => '0px',
        soft   => '6px',
        pill   => '999px',
    );
    my %card_styles = (
        flat => {
            bg     => 'var(--panel)',
            border => 'transparent',
            shadow => 'none',
        },
        outlined => {
            bg     => 'var(--panel)',
            border => 'var(--line)',
            shadow => 'none',
        },
        raised => {
            bg     => 'var(--panel)',
            border => 'color-mix(in srgb, var(--line) 76%, transparent)',
            shadow => '0 14px 34px rgba(16, 32, 51, 0.12)',
        },
    );
    my %card_radii = (
        square => '0px',
        soft   => '8px',
        round  => '16px',
    );
    my %box_radii = (
        square => '0px',
        soft   => '8px',
        round  => '18px',
        pill   => '28px',
    );
    my %background_effects = (
        none => {
            overlay => 'none',
            blend   => 'normal',
        },
        wash => {
            overlay => 'linear-gradient(135deg, color-mix(in srgb, var(--accent) 10%, transparent), transparent 42%, color-mix(in srgb, var(--support) 8%, transparent))',
            blend   => 'normal',
        },
        grain => {
            overlay => 'repeating-linear-gradient(135deg, color-mix(in srgb, var(--ink) 4%, transparent) 0 1px, transparent 1px 7px)',
            blend   => 'normal',
        },
        vignette => {
            overlay => 'radial-gradient(ellipse at center, transparent 42%, color-mix(in srgb, var(--ink) 16%, transparent) 100%)',
            blend   => 'normal',
        },
    );
    my %motion_effects = (
        none   => { duration => '0ms',   transform => 'none' },
        subtle => { duration => '160ms', transform => 'translateY(-1px)' },
        lift   => { duration => '240ms', transform => 'translateY(-3px)' },
    );
    my %lighting_effects = (
        none => {
            shadow => $card_styles{$card_style}{shadow},
        },
        soft => {
            shadow => '0 18px 42px rgba(16, 32, 51, 0.14)',
        },
        glow => {
            shadow => '0 18px 48px color-mix(in srgb, var(--accent) 22%, transparent)',
        },
    );
    my %gradient_styles = (
        none => {
            bg     => 'none',
            accent => 'var(--accent)',
        },
        accent => {
            bg     => 'linear-gradient(135deg, color-mix(in srgb, var(--accent) 18%, transparent), color-mix(in srgb, var(--support) 12%, transparent))',
            accent => 'linear-gradient(135deg, var(--accent), var(--support))',
        },
        split => {
            bg     => 'linear-gradient(90deg, color-mix(in srgb, var(--accent) 14%, transparent), transparent 50%, color-mix(in srgb, var(--support) 12%, transparent))',
            accent => 'linear-gradient(90deg, var(--accent), var(--support))',
        },
        sheen => {
            bg     => 'linear-gradient(120deg, transparent, color-mix(in srgb, var(--panel) 36%, transparent), transparent)',
            accent => 'linear-gradient(120deg, var(--accent-dark), var(--accent), var(--support))',
        },
    );
    my $logo_width = _optional_px($site->{site_logo_max_width_px}, $logos{$logo}{width}, 80, 640);
    my $logo_height = _optional_px($site->{site_logo_max_height_px}, $logos{$logo}{height}, 24, 180);
    my $logo_position = _percent($site->{site_logo_focal_x}, 50) . '% '
        . _percent($site->{site_logo_focal_y}, 50) . '%';
    my $card_bg = _transparent_mix($card_styles{$card_style}{bg}, 100 - $box_transparency);
    my $card_border = $card_styles{$card_style}{border};
    $card_border = _transparent_mix($card_border, 100 - $outline_transparency)
        unless $card_border eq 'transparent';

    return {
        content_width => $widths{$width},
        main_margin   => $spacing_values{$spacing}{main},
        section_gap   => $spacing_values{$spacing}{section},
        header_y      => $spacing_values{$spacing}{header_y},
        header_x      => $spacing_values{$spacing}{header_x},
        logo_width    => $logo_width,
        logo_height   => $logo_height,
        logo_fit      => $logo_fit,
        logo_position => $logo_position,
        heading_font  => DesertCMS::FontPackages::css_stack_for_font_id($heading_font, 'serif'),
        body_font     => DesertCMS::FontPackages::css_stack_for_font_id($body_font, 'serif'),
        ui_font       => DesertCMS::FontPackages::css_stack_for_font_id($ui_font, 'sans'),
        h1_size       => $heading_sizes{$heading_scale}{h1},
        h2_size       => $heading_sizes{$heading_scale}{h2},
        h3_size       => $heading_sizes{$heading_scale}{h3},
        hero_size     => $heading_sizes{$heading_scale}{hero},
        body_size     => $body_sizes{$body_scale}{body},
        intro_size    => $body_sizes{$body_scale}{intro},
        body_line     => $body_sizes{$body_scale}{line},
        ui_size       => $body_sizes{$body_scale}{ui},
        button_bg     => $button_styles{$button_style}{bg},
        button_hover  => $button_styles{$button_style}{hover},
        button_border => $button_styles{$button_style}{border},
        button_color  => $button_styles{$button_style}{color},
        button_shadow => $button_styles{$button_style}{shadow},
        button_radius => $button_radii{$button_radius},
        card_bg       => $card_bg,
        card_border   => $card_border,
        card_shadow   => $card_styles{$card_style}{shadow},
        card_radius   => $card_radii{$card_radius},
        background_overlay => $background_effects{$background_effect}{overlay},
        background_blend   => $background_effects{$background_effect}{blend},
        motion_duration    => $motion_effects{$motion_effect}{duration},
        hover_transform    => $motion_effects{$motion_effect}{transform},
        lighting_shadow    => $lighting_effects{$lighting_effect}{shadow},
        box_radius         => $box_radii{$box_shape},
        gradient_bg        => $gradient_styles{$gradient_style}{bg},
        accent_gradient    => $gradient_styles{$gradient_style}{accent},
        box_alpha          => (100 - $box_transparency) . '%',
        outline_alpha      => (100 - $outline_transparency) . '%',
    };
}

sub _layout_css {
    my ($vars) = @_;
    return ''
        . "  --site-content-width: $vars->{content_width};\n"
        . "  --site-main-margin: $vars->{main_margin};\n"
        . "  --site-section-gap: $vars->{section_gap};\n"
        . "  --site-header-padding-y: $vars->{header_y};\n"
        . "  --site-header-padding-x: $vars->{header_x};\n"
        . "  --site-logo-max-width: $vars->{logo_width};\n"
        . "  --site-logo-max-height: $vars->{logo_height};\n"
        . "  --site-logo-object-fit: $vars->{logo_fit};\n"
        . "  --site-logo-object-position: $vars->{logo_position};\n"
        . "  --site-heading-font: $vars->{heading_font};\n"
        . "  --site-body-font: $vars->{body_font};\n"
        . "  --site-ui-font: $vars->{ui_font};\n"
        . "  --site-h1-size: $vars->{h1_size};\n"
        . "  --site-h2-size: $vars->{h2_size};\n"
        . "  --site-h3-size: $vars->{h3_size};\n"
        . "  --site-hero-title-size: $vars->{hero_size};\n"
        . "  --site-body-size: $vars->{body_size};\n"
        . "  --site-intro-size: $vars->{intro_size};\n"
        . "  --site-body-line-height: $vars->{body_line};\n"
        . "  --site-ui-size: $vars->{ui_size};\n"
        . "  --site-button-bg: $vars->{button_bg};\n"
        . "  --site-button-hover-bg: $vars->{button_hover};\n"
        . "  --site-button-border: $vars->{button_border};\n"
        . "  --site-button-color: $vars->{button_color};\n"
        . "  --site-button-shadow: $vars->{button_shadow};\n"
        . "  --site-button-radius: $vars->{button_radius};\n"
        . "  --site-card-bg: $vars->{card_bg};\n"
        . "  --site-card-border: $vars->{card_border};\n"
        . "  --site-card-shadow: $vars->{card_shadow};\n"
        . "  --site-card-radius: $vars->{card_radius};\n"
        . "  --site-background-overlay: $vars->{background_overlay};\n"
        . "  --site-background-blend-mode: $vars->{background_blend};\n"
        . "  --site-motion-duration: $vars->{motion_duration};\n"
        . "  --site-hover-transform: $vars->{hover_transform};\n"
        . "  --site-lighting-shadow: $vars->{lighting_shadow};\n"
        . "  --site-box-radius: $vars->{box_radius};\n"
        . "  --site-gradient-bg: $vars->{gradient_bg};\n"
        . "  --site-accent-gradient: $vars->{accent_gradient};\n"
        . "  --site-box-alpha: $vars->{box_alpha};\n"
        . "  --site-outline-alpha: $vars->{outline_alpha};\n";
}

sub _choice {
    my ($value, $fallback, @allowed) = @_;
    for my $allowed (@allowed) {
        return $allowed if defined $value && $value eq $allowed;
    }
    return $fallback;
}

sub _optional_px {
    my ($value, $fallback, $min, $max) = @_;
    return $fallback unless defined $value && "$value" =~ /\A[0-9]+\z/;
    my $int = int($value);
    return $fallback if $int < $min || $int > $max;
    return $int . 'px';
}

sub _percent {
    my ($value, $fallback) = @_;
    return $fallback unless defined $value && "$value" =~ /\A[0-9]+\z/;
    my $int = int($value);
    return $fallback if $int < 0 || $int > 100;
    return $int;
}

sub _percent_int {
    my ($value, $fallback, $min, $max) = @_;
    return $fallback unless defined $value && "$value" =~ /\A[0-9]+\z/;
    my $int = int($value);
    return $fallback if $int < $min || $int > $max;
    return $int;
}

sub _transparent_mix {
    my ($base, $alpha) = @_;
    $base ||= 'var(--panel)';
    $alpha = 100 unless defined $alpha && "$alpha" =~ /\A[0-9]+\z/;
    $alpha = 100 if $alpha > 100;
    $alpha = 0 if $alpha < 0;
    return $base if $alpha >= 100 || $base eq 'transparent';
    return "color-mix(in srgb, $base $alpha%, transparent)";
}

sub _valid_color {
    my ($value) = @_;
    return defined $value && $value =~ /\A#[0-9a-fA-F]{6}\z/;
}

sub _var_names {
    return qw(ink muted paper panel field line accent accent_dark support button_ink);
}

1;
