package DesertCMS::Renderer;

use strict;
use warnings;
use DesertCMS::DateTimeLite;
use Encode qw(encode_utf8);
use File::Path qw(make_path remove_tree);
use File::Spec;
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);
use DesertCMS::Analytics;
use DesertCMS::Bookings;
use DesertCMS::Config;
use DesertCMS::ContributorRequests;
use DesertCMS::DB;
use DesertCMS::Directory;
use DesertCMS::Donations;
use DesertCMS::Docs;
use DesertCMS::Events;
use DesertCMS::Federation;
use DesertCMS::FontPackages;
use DesertCMS::Media;
use DesertCMS::Modules;
use DesertCMS::Navigation;
use DesertCMS::Newsletter;
use DesertCMS::Redirects;
use DesertCMS::RichText qw(rich_paragraphs_html plain_text_from_rich_html);
use DesertCMS::Settings;
use DesertCMS::Shop;
use DesertCMS::SiteTheme;
use DesertCMS::Testimonials;
use DesertCMS::Theme;
use DesertCMS::Util qw(escape_html);

sub render_item {
    my ($config, $item, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $content_template = _read_template($config, 'content.html');
    my $layout_template = _read_template($config, 'layout.html');
    my $type_label = $item->{type} eq 'post' ? 'Post' : 'Page';
    my $metadata = _metadata_for_item($config, $site, $item, $db);
    if ($item->{_render_as_home}) {
        $metadata->{url} = $item->{canonical_url} || _absolute_url($config, '/');
    }
    my $body_html = _render_blocks($item->{body_json}, $db);
    if (($item->{type} || '') eq 'post') {
        $body_html .= _post_share($metadata);
        $body_html .= _comments_mount($item);
    }

    my $content = _fill_template($content_template, {
        type_label => escape_html($type_label),
        title      => escape_html($item->{title}),
        taxonomy   => _taxonomy_html($db, $item),
        body       => $body_html,
    });

    return _fill_template($layout_template, {
        _layout_template_vars($config, $db, $site, context => $item->{_render_as_home} ? 'home' : ($item->{type} || 'page')),
        title           => escape_html($metadata->{title}),
        excerpt         => escape_html($metadata->{description}),
        canonical_url   => escape_html($metadata->{url}),
        social_meta     => _social_meta($metadata),
        content         => $content,
    });
}

sub render_module_page {
    my ($config, $db, $args) = @_;
    $args ||= {};
    my $site = DesertCMS::Settings::all($config, $db);
    my $title = $args->{title} || $site->{site_name} || 'DesertCMS';
    my $description = $args->{description} || $site->{site_description} || '';
    my $path = $args->{path} || '/';
    my $url = $args->{url} || _absolute_url($config, $path);

    return _fill_template(_read_template($config, 'layout.html'), {
        _layout_template_vars($config, $db, $site, context => $args->{context} || 'module'),
        title           => escape_html($title),
        excerpt         => escape_html($description),
        canonical_url   => escape_html($url),
        social_meta     => _social_meta({ title => $title, description => $description, url => $url, image => _absolute_image_url($config, $site->{social_image_path}) }),
        content         => $args->{content} || '',
    });
}

sub publish_item {
    my ($config, $item, $html, $db) = @_;
    my $path = public_path_for($config, $item, $db);
    if (!_content_is_public($item)) {
        _remove_static_file($path);
        _publish_assets($config, $db);
        return $path;
    }
    _write_file($path, $html);
    _publish_assets($config, $db);
    return $path;
}

sub rebuild_indexes {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    _publish_assets($config, $db);
    _write_home($config, $db);
    _write_posts_index($config, $db) unless _published_content_claims_url($db, '/posts/');
    if (DesertCMS::Modules::enabled($site, 'map')) {
        _write_map_data($config, $db);
        _write_map_page($config, $db) unless _published_content_claims_url($db, '/map/');
    } else {
        _remove_map_artifacts($config);
    }
    if (DesertCMS::Modules::enabled($site, 'gallery')) {
        _write_showcase_page($config, $db) unless _published_content_claims_url($db, '/showcase/');
        _write_showcase_legacy_redirect($config) unless _published_content_claims_url($db, '/gallery/');
    } else {
        _remove_showcase_artifacts($config);
    }
    if (DesertCMS::Modules::enabled($site, 'contributor_requests')) {
        _write_contributors_page($config, $db);
        _write_contributor_apply_page($config, $db);
    } else {
        _remove_contributors_artifacts($config);
    }
    if (DesertCMS::Modules::enabled($site, 'docs')) {
        _write_docs_pages($config, $db);
    } else {
        _remove_docs_artifacts($config);
    }
    if (DesertCMS::Modules::enabled($site, 'directory')) {
        _write_directory_pages($config, $db) unless _published_content_claims_url($db, '/directory/');
    } else {
        _remove_directory_artifacts($config);
    }
    if (DesertCMS::Modules::enabled($site, 'bookings')) {
        _write_bookings_pages($config, $db) unless _published_content_claims_url($db, '/bookings/');
    } else {
        _remove_bookings_artifacts($config);
    }
    if (DesertCMS::Modules::enabled($site, 'events')) {
        _write_events_pages($config, $db);
    } else {
        _remove_events_artifacts($config);
    }
    if (DesertCMS::Modules::enabled($site, 'newsletter')) {
        _write_newsletter_page($config, $db) unless _published_content_claims_url($db, '/newsletter/');
    } else {
        _remove_newsletter_artifacts($config);
    }
    if (DesertCMS::Modules::enabled($site, 'donations')) {
        _write_donation_pages($config, $db) unless _published_content_claims_url($db, '/donate/');
    } else {
        _remove_donation_artifacts($config);
    }
    if (DesertCMS::Modules::enabled($site, 'testimonials')) {
        _write_testimonials_pages($config, $db) unless _published_content_claims_url($db, '/testimonials/');
    } else {
        _remove_testimonials_artifacts($config);
    }
    _write_taxonomy_indexes($config, $db);
    _write_discovery_files($config, $db);
    _write_redirect_artifacts($config, $db);
}

sub _published_content_claims_url {
    my ($db, $url) = @_;
    return 0 unless $db && length($url || '');
    my $target = _navigation_url_key($url);
    my $rows = eval {
        $db->dbh->selectall_arrayref(
            q{
                SELECT id, parent_id, type, title, slug
                FROM content_items
                WHERE status = 'published'
                  AND deleted_at IS NULL
                  AND COALESCE(access_policy, 'public') = 'public'
            },
            { Slice => {} }
        );
    } || [];
    for my $item (@{$rows}) {
        return 1 if _navigation_url_key(_public_path_for_url($db, $item)) eq $target;
    }
    return 0;
}

sub public_path_for {
    my ($config, $item, $db) = @_;
    my @parts;
    if ($item->{type} eq 'post') {
        @parts = ('posts', $item->{slug}, 'index.html');
    } elsif ($item->{slug} eq 'home' || $item->{slug} eq 'index') {
        @parts = ('index.html');
    } else {
        @parts = (_page_segments($db, $item), 'index.html');
    }

    return File::Spec->catfile($config->get('public_root'), @parts);
}

sub _write_home {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $home = _selected_homepage($db, $site);
    $home ||= $db->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM content_items
            WHERE type = 'page'
              AND status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') = 'public'
              AND slug IN ('home', 'index')
            ORDER BY CASE slug WHEN 'home' THEN 0 ELSE 1 END
            LIMIT 1
        }
    );

    if ($home) {
        $home->{_render_as_home} = 1;
        my $html = render_item($config, $home, $db);
        _write_file(File::Spec->catfile($config->get('public_root'), 'index.html'), $html);
        return;
    }

    my $template = _read_template($config, 'index.html');
    my $layout = _read_template($config, 'layout.html');
    my $content = _fill_template($template, {
        site_name => escape_html($site->{site_name}),
        body      => '<p>No home page has been published yet.</p>',
    });
    my $title = $site->{site_meta_title} || $site->{site_name};
    my $description = $site->{site_meta_description} || $site->{site_description};
    my $url = _absolute_url($config, '/');
    my $html = _fill_template($layout, {
        _layout_template_vars($config, $db, $site, context => 'home'),
        title         => escape_html($title),
        excerpt       => escape_html($description),
        canonical_url => escape_html($url),
        social_meta   => _social_meta({ title => $title, description => $description, url => $url, image => _absolute_image_url($config, $site->{social_image_path}) }),
        content       => $content,
    });
    _write_file(File::Spec->catfile($config->get('public_root'), 'index.html'), $html);
}

sub _write_posts_index {
    my ($config, $db) = @_;
    my $posts = $db->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM content_items
            WHERE type = 'post'
              AND status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') = 'public'
            ORDER BY published_at DESC, updated_at DESC
        },
        { Slice => {} }
    );

    for my $post (@{$posts}) {
        $post->{url} = '/posts/' . ($post->{slug} || '') . '/';
        $post->{sort_time} = $post->{published_at} || $post->{updated_at} || 0;
    }
    push @{$posts}, @{_contributor_post_items($config, $db)};
    @{$posts} = sort { ($b->{sort_time} || 0) <=> ($a->{sort_time} || 0) || ($b->{id} || 0) <=> ($a->{id} || 0) } @{$posts};

    my $cards = '';
    for my $post (@{$posts}) {
        my $url = escape_html($post->{url} || ('/posts/' . ($post->{slug} || '') . '/'));
        my $title = escape_html($post->{title});
        my $excerpt = escape_html($post->{excerpt});
        my $source = escape_html($post->{owner_display_name} || $post->{owner_domain} || '');
        my $source_html = length $source ? "<span>$source</span>" : '';
        $cards .= qq{<a class="post-card" href="$url">$source_html<h2>$title</h2><p>$excerpt</p></a>\n};
    }
    $cards ||= '<p>No posts have been published yet.</p>';

    my $site = DesertCMS::Settings::all($config, $db);
    my $content = _fill_template(_read_template($config, 'posts.html'), {
        posts => $cards,
    });
    my $url = _absolute_url($config, '/posts/');
    my $title = 'Posts';
    my $description = $site->{site_meta_description} || $site->{site_description};
    my $html = _fill_template(_read_template($config, 'layout.html'), {
        _layout_template_vars($config, $db, $site, context => 'posts'),
        title         => $title,
        excerpt       => escape_html($description),
        canonical_url => escape_html($url),
        social_meta   => _social_meta({ title => $title, description => $description, url => $url, image => _absolute_image_url($config, $site->{social_image_path}) }),
        content       => $content,
    });

    _write_file(File::Spec->catfile($config->get('public_root'), 'posts', 'index.html'), $html);
}

sub _render_blocks {
    my ($body_json, $db) = @_;
    my $blocks = eval { decode_json($body_json || '[]') } || [];
    my $media_assets = _media_asset_map($db, $blocks);
    my $resource_assets = _resource_asset_map($db, $blocks);
    my $html = '';

    for my $block (@{$blocks}) {
        next unless ref $block eq 'HASH';
        my $html_before_block = length($html);
        if (($block->{type} || '') eq 'text') {
            my $align_class = join ' ', _rich_text_align_class($block->{align}), _text_style_class($block->{font}, $block->{text_size});
            $html .= qq{<div class="$align_class">} . rich_paragraphs_html($block->{html}, $block->{text}) . "</div>\n";
        } elsif (($block->{type} || '') eq 'heading') {
            my $level = int($block->{level} || 2);
            $level = 2 unless $level == 2 || $level == 3;
            my $safe = escape_html($block->{text} || '');
            next unless length $safe;
            my $align_class = join ' ', _heading_align_class($block->{align}), _text_style_class($block->{font}, $block->{text_size});
            $html .= qq{<h$level class="$align_class">$safe</h$level>\n};
        } elsif (($block->{type} || '') eq 'quote') {
            my $text = escape_html($block->{text} || '');
            next unless length $text;
            $text =~ s/\n/<br>/g;
            my $citation = escape_html($block->{citation} || '');
            my $cite = length $citation ? "<cite>$citation</cite>" : '';
            my $class = join ' ', _heading_align_class($block->{align}), _text_style_class($block->{font}, $block->{text_size});
            $html .= qq{<blockquote class="$class"><p>$text</p>$cite</blockquote>\n};
        } elsif (($block->{type} || '') eq 'divider') {
            $html .= "<hr>\n";
        } elsif (($block->{type} || '') eq 'code') {
            my $code = escape_html($block->{code} || '');
            next unless length $code;
            my $language = _code_language($block->{language});
            my $class = length $language ? ' class="language-' . escape_html($language) . '"' : '';
            $html .= qq{<pre class="code-block"><code$class>$code</code></pre>\n};
        } elsif (($block->{type} || '') eq 'image') {
            my $src = $block->{src} || '';
            next unless DesertCMS::Media::is_public_image_path($src);
            my $asset = $media_assets->{$src} || {};
            my $alt = $block->{alt} || $asset->{alt_text} || '';
            my $caption = escape_html($block->{caption} || '');
            my $layout = $block->{layout} || 'full';
            my $size = $block->{size} || 'large';
            $layout = 'full' unless $layout =~ /\A(?:full|left|right|center)\z/;
            $size = 'large' unless $size =~ /\A(?:small|medium|large|full)\z/;
            my $class = "media-figure media-figure--$layout media-figure--$size";
            my $image = _media_img_tag($src, $alt, $asset, sizes => _content_image_sizes($layout, $size));
            my $figcaption = length $caption ? "<figcaption>$caption</figcaption>" : '';
            $html .= qq{<figure class="$class">$image$figcaption</figure>\n};
        } elsif (($block->{type} || '') eq 'image_text') {
            my $src = $block->{src} || '';
            if (!DesertCMS::Media::is_public_image_path($src)) {
                my $fallback = rich_paragraphs_html($block->{html}, $block->{text});
                my $align_class = join ' ', _rich_text_align_class($block->{align}), _text_style_class($block->{font}, $block->{text_size});
                if (length plain_text_from_rich_html($fallback)) {
                    $html .= _block_spacing_wrapper($block, qq{<div class="$align_class">$fallback</div>\n});
                }
                next;
            }
            my $asset = $media_assets->{$src} || {};
            my $alt = $block->{alt} || $asset->{alt_text} || '';
            my $caption = escape_html($block->{caption} || '');
            my $side = ($block->{image_side} || 'left') eq 'right' ? 'right' : 'left';
            my $text = rich_paragraphs_html($block->{html}, $block->{text});
            my $figcaption = length $caption ? "<figcaption>$caption</figcaption>" : '';
            my $align_class = join ' ', _rich_text_align_class($block->{align}), _text_style_class($block->{font}, $block->{text_size});
            my $image = _media_img_tag($src, $alt, $asset, sizes => '(max-width: 760px) 100vw, 520px');
            $html .= qq{<section class="image-text image-text--$side"><figure>$image$figcaption</figure><div class="$align_class">$text</div></section>\n};
        } elsif (($block->{type} || '') eq 'video') {
            my $url = _clean_url($block->{url});
            next unless length $url;
            my $title = escape_html($block->{title} || 'Video');
            my $caption = escape_html($block->{caption} || '');
            my $embed = _video_embed_url($url);
            my $caption_html = length $caption ? "<figcaption>$caption</figcaption>" : '';
            if ($embed) {
                my $safe_embed = escape_html($embed);
                $html .= qq{<figure class="video-block"><div class="video-frame"><iframe src="$safe_embed" title="$title" loading="lazy" allowfullscreen></iframe></div>$caption_html</figure>\n};
            } else {
                my $safe_url = escape_html($url);
                $html .= qq{<a class="link-card video-link" href="$safe_url"><span>Video</span><strong>$title</strong></a>\n};
            }
        } elsif (($block->{type} || '') eq 'link') {
            my $url = _clean_url($block->{url});
            next unless length $url;
            my $label = escape_html($block->{label} || $url);
            my $description = escape_html($block->{description} || '');
            my $desc_html = length $description ? "<p>$description</p>" : '';
            my $safe_url = escape_html($url);
            $html .= qq{<a class="link-card" href="$safe_url"><span>Link</span><strong>$label</strong>$desc_html</a>\n};
        } elsif (($block->{type} || '') eq 'resource') {
            my $src = $block->{src} || '';
            next unless $src =~ m{\A/assets/resources/[0-9a-f]{64}\.[a-z0-9]+\z};
            my $asset = $resource_assets->{$src} || {};
            my $title = escape_html($block->{label} || $asset->{seo_title} || $asset->{original_name} || 'Download resource');
            my $description = escape_html($block->{description} || $asset->{seo_description} || '');
            my $button = escape_html($block->{button_label} || 'Download');
            my $ext = escape_html(_resource_extension_label($asset, $src));
            my $meta = _resource_meta_label($asset);
            my $desc_html = length $description ? "<p>$description</p>" : '';
            my $meta_html = length $meta ? '<small>' . escape_html($meta) . '</small>' : '';
            my $safe_url = escape_html($src);
            $html .= qq{<a class="resource-card" href="$safe_url" download><span class="resource-card-badge">$ext</span><div><strong>$title</strong>$desc_html$meta_html</div><span class="resource-card-action">$button</span></a>\n};
        } elsif (($block->{type} || '') eq 'content_ref') {
            $html .= _content_reference_card($db, $block);
        } elsif (($block->{type} || '') eq 'contributor_request') {
            $html .= _contributor_request_form($block);
        } elsif (($block->{type} || '') eq 'social') {
            my $url = _clean_url($block->{url});
            next unless length $url;
            my $platform = lc($block->{platform} || 'website');
            $platform = 'website' unless $platform =~ /\A(?:instagram|x|facebook|youtube|vimeo|website|email)\z/;
            my $safe_platform = escape_html($platform);
            my $label = escape_html(_social_display_label($platform, $block->{label}, $url));
            my $icon = _social_icon_html($platform);
            my $safe_url = escape_html($url);
            $html .= qq{<a class="social-link social-link--$safe_platform" href="$safe_url"><span class="social-icon" aria-hidden="true">$icon</span><strong>$label</strong></a>\n};
        }
        if (length($html) > $html_before_block) {
            my $fragment = substr($html, $html_before_block);
            substr($html, $html_before_block) = _block_spacing_wrapper($block, $fragment);
        }
    }

    return $html || '<p></p>';
}

sub _block_spacing_wrapper {
    my ($block, $html) = @_;
    return '' unless defined $html && length $html;
    my $spacing = _block_spacing($block->{spacing});
    return qq{<section class="content-block content-block--spacing-$spacing">$html</section>\n};
}

sub _block_spacing {
    my ($spacing) = @_;
    $spacing = defined $spacing ? "$spacing" : 'default';
    return $spacing =~ /\A(?:default|compact|spacious|none)\z/ ? $spacing : 'default';
}

sub _content_reference_card {
    my ($db, $block) = @_;
    return '' unless $db && $block;
    my $target_id = int($block->{target_id} || 0);
    return '' unless $target_id > 0;

    my $item = $db->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM content_items
            WHERE id = ?
              AND status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') = 'public'
            LIMIT 1
        },
        undef,
        $target_id
    );
    return '' unless $item;

    my $style = ($block->{style} || 'card') eq 'feature' ? 'feature' : 'card';
    my $url = escape_html(_public_path_for_url($db, $item));
    my $type = escape_html(ucfirst($item->{type} || 'page'));
    my $title = escape_html($item->{title} || 'Untitled');
    my $excerpt = escape_html(_first_content_paragraph($item));
    my $image = _content_card_image($item);
    my $image_html = '';
    if (length $image) {
        my $asset = _media_asset_for_path($db, $image);
        my $image_tag = _media_img_tag($image, $item->{title} || '', $asset, sizes => '(max-width: 760px) 100vw, 520px');
        $image_html = qq{<figure>$image_tag</figure>};
    }
    my $excerpt_html = length $excerpt ? "<p>$excerpt</p>" : '';

    return qq{<a class="content-ref-card content-ref-card--$style" href="$url">$image_html<div><span>$type</span><strong>$title</strong>$excerpt_html</div></a>\n};
}

sub _contributor_request_form {
    my ($block) = @_;
    my $title = escape_html($block->{title} || 'Request to become a contributor');
    my $intro = escape_html($block->{intro} || 'Submit your contact details and tell us why you want to join.');
    my $button = escape_html($block->{button_label} || 'Submit request');
    my $values = $block->{values} || {};
    my $name = escape_html($values->{name} || '');
    my $email = escape_html($values->{email} || '');
    my $phone = escape_html($values->{phone} || '');
    my $age = escape_html($values->{age} || '');
    my $application_text = escape_html($values->{application_text} || '');
    my $notice = '';
    if (defined $block->{message} && length $block->{message}) {
        my $class = $block->{is_error} ? 'forms-notice is-error' : 'forms-notice';
        my $role = $block->{is_error} ? 'alert' : 'status';
        $notice = '<p class="' . $class . '" role="' . $role . '">' . escape_html($block->{message}) . '</p>';
    }
    return <<"HTML";
<section class="contributor-request-block">
  <h2>$title</h2>
  <p>$intro</p>
  $notice
  <form method="post" action="/forms/contributor-request" enctype="multipart/form-data" class="public-form contributor-request-form">
    <fieldset class="public-form-section">
      <legend>Contact details</legend>
      <div class="public-form-grid">
        <label class="public-field">
          <span>Name</span>
          <input name="name" value="$name" maxlength="120" autocomplete="name" required>
          <small class="field-help">Use your first and last name.</small>
        </label>
        <label class="public-field">
          <span>Email</span>
          <input name="email" type="email" value="$email" maxlength="180" autocomplete="email" required>
          <small class="field-help">We use this for review updates only.</small>
        </label>
        <label class="public-field">
          <span>Phone #</span>
          <input name="phone" value="$phone" maxlength="40" autocomplete="tel" required>
        </label>
        <label class="public-field">
          <span>Age</span>
          <input name="age" type="number" value="$age" min="13" max="120" required>
        </label>
      </div>
    </fieldset>
    <fieldset class="public-form-section">
      <legend>Sample images</legend>
      <p class="field-help public-form-section-help">Optional samples help reviewers understand the work you want to share.</p>
      <div class="public-upload-grid">
        <label class="public-upload-field">
          <span>Sample image (optional)</span>
          <input name="showcase_1" type="file" accept="image/jpeg,image/png,image/webp" data-upload-preview>
          <span class="public-upload-preview" data-upload-preview-output><span class="public-upload-thumb" aria-hidden="true"></span><small>No file selected</small></span>
        </label>
        <label class="public-upload-field">
          <span>Additional sample (optional)</span>
          <input name="showcase_2" type="file" accept="image/jpeg,image/png,image/webp" data-upload-preview>
          <span class="public-upload-preview" data-upload-preview-output><span class="public-upload-thumb" aria-hidden="true"></span><small>No file selected</small></span>
        </label>
        <label class="public-upload-field">
          <span>Additional sample (optional)</span>
          <input name="showcase_3" type="file" accept="image/jpeg,image/png,image/webp" data-upload-preview>
          <span class="public-upload-preview" data-upload-preview-output><span class="public-upload-thumb" aria-hidden="true"></span><small>No file selected</small></span>
        </label>
      </div>
    </fieldset>
    <fieldset class="public-form-section public-form-section--wide">
      <legend>Application response</legend>
      <label class="public-field public-count-field">
        <span>Why do you want to join?</span>
        <textarea name="application_text" rows="7" minlength="150" maxlength="500" required data-character-counter data-counter-min="150" data-counter-max="500">$application_text</textarea>
        <small class="field-counter" data-counter-output>0 / 500 characters</small>
        <small class="field-help">Write 150 to 500 characters about why you want to contribute.</small>
      </label>
    </fieldset>
    <label class="comment-honeypot">
      <span>Website</span>
      <input name="website" tabindex="-1" autocomplete="off">
    </label>
    <button type="submit">$button</button>
  </form>
</section>
HTML
}

sub contributor_request_form_html {
    return _contributor_request_form(@_);
}

sub _content_card_image {
    my ($item) = @_;
    my $feature = $item->{feature_image_path} || '';
    return $feature if DesertCMS::Media::is_public_image_path($feature);

    my $blocks = eval { decode_json($item->{body_json} || '[]') } || [];
    for my $block (@{$blocks}) {
        next unless ref $block eq 'HASH';
        next unless ($block->{type} || '') eq 'image' || ($block->{type} || '') eq 'image_text';
        my $src = $block->{src} || '';
        return $src if DesertCMS::Media::is_public_image_path($src);
    }
    return '';
}

sub _first_content_paragraph {
    my ($item) = @_;
    my $blocks = eval { decode_json($item->{body_json} || '[]') } || [];
    for my $block (@{$blocks}) {
        next unless ref $block eq 'HASH';
        next unless ($block->{type} || '') eq 'text' || ($block->{type} || '') eq 'image_text';
        my $plain = plain_text_from_rich_html($block->{html});
        $plain = $block->{text} || '' unless length $plain;
        my $paragraph = _first_paragraph($plain);
        return _short_excerpt($paragraph) if length $paragraph;
    }
    return _short_excerpt($item->{excerpt} || '');
}

sub _first_paragraph {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/\r\n?/\n/g;
    for my $paragraph (split /\n\s*\n/, $text) {
        $paragraph =~ s/^\s+|\s+$//g;
        $paragraph =~ s/\s+/ /g;
        return $paragraph if length $paragraph;
    }
    $text =~ s/^\s+|\s+$//g;
    $text =~ s/\s+/ /g;
    return $text;
}

sub _short_excerpt {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/^\s+|\s+$//g;
    $text =~ s/\s+/ /g;
    return '' unless length $text;
    return $text if length($text) <= 220;
    $text = substr($text, 0, 217);
    $text =~ s/\s+\S*\z//;
    return $text . '...';
}

sub _paragraphs_html {
    my ($text) = @_;
    my $html = '';
    for my $paragraph (split /\n\s*\n/, $text || '') {
        $paragraph =~ s/^\s+|\s+$//g;
        next unless length $paragraph;
        my $safe = escape_html($paragraph);
        $safe =~ s/\n/<br>/g;
        $html .= "<p>$safe</p>\n";
    }
    return $html || '<p></p>';
}

sub _rich_text_align_class {
    my ($align) = @_;
    $align = 'left' unless defined $align && $align =~ /\A(?:left|center|right)\z/;
    return "rich-text rich-text--$align";
}

sub _heading_align_class {
    my ($align) = @_;
    $align = 'left' unless defined $align && $align =~ /\A(?:left|center|right)\z/;
    return "heading-align heading-align--$align";
}

sub _text_style_class {
    my ($font, $size) = @_;
    $font = 'serif' unless defined $font && $font =~ /\A(?:serif|sans|mono)\z/;
    $size = 'normal' unless defined $size && $size =~ /\A(?:small|normal|large)\z/;
    return "content-font--$font content-size--$size";
}

sub _code_language {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/^\s+|\s+$//g;
    return $value if $value =~ /\A[a-z0-9_+#.-]{1,32}\z/;
    return '';
}

sub _media_asset_map {
    my ($db, $blocks) = @_;
    return {} unless $db && ref $blocks eq 'ARRAY';
    my %paths;
    for my $block (@{$blocks}) {
        next unless ref $block eq 'HASH' && (($block->{type} || '') eq 'image' || ($block->{type} || '') eq 'image_text');
        my $src = $block->{src} || '';
        next unless DesertCMS::Media::is_public_image_path($src);
        $paths{$src} = 1;
    }
    return {} unless %paths;

    my @paths = sort keys %paths;
    my $placeholders = join ',', map { '?' } @paths;
    my $rows = $db->dbh->selectall_arrayref(
        "SELECT public_path, alt_text, seo_title, seo_description, width, height, derivatives_json FROM media_assets WHERE deleted_at IS NULL AND public_path IN ($placeholders)",
        { Slice => {} },
        @paths
    );
    return { map { $_->{public_path} => $_ } @{$rows} };
}

sub _resource_asset_map {
    my ($db, $blocks) = @_;
    return {} unless $db && ref $blocks eq 'ARRAY';
    my %paths;
    for my $block (@{$blocks}) {
        next unless ref $block eq 'HASH' && (($block->{type} || '') eq 'resource');
        my $src = $block->{src} || '';
        next unless $src =~ m{\A/assets/resources/[0-9a-f]{64}\.[a-z0-9]+\z};
        $paths{$src} = 1;
    }
    return {} unless %paths;

    my @paths = sort keys %paths;
    my $placeholders = join ',', map { '?' } @paths;
    my $rows = $db->dbh->selectall_arrayref(
        "SELECT original_name, public_path, seo_title, seo_description, mime_type, bytes, derivatives_json FROM media_assets WHERE deleted_at IS NULL AND public_path IN ($placeholders)",
        { Slice => {} },
        @paths
    );
    return { map { $_->{public_path} => $_ } @{$rows} };
}

sub _media_asset_for_path {
    my ($db, $path) = @_;
    return {} unless $db && DesertCMS::Media::is_public_image_path($path);
    return $db->dbh->selectrow_hashref(
        q{
            SELECT public_path, alt_text, seo_title, seo_description, width, height, derivatives_json
            FROM media_assets
            WHERE deleted_at IS NULL
              AND public_path = ?
            LIMIT 1
        },
        undef,
        $path
    ) || {};
}

sub _media_img_tag {
    my ($src, $alt, $asset, %opts) = @_;
    $alt = $asset->{alt_text} || '' if $asset && (!defined $alt || !length $alt);
    my @attrs = (
        'src="' . escape_html($src || '') . '"',
        'alt="' . escape_html($alt || '') . '"',
        'loading="' . escape_html($opts{loading} || 'lazy') . '"',
        'decoding="async"',
    );
    if ($asset && int($asset->{width} || 0) > 0 && int($asset->{height} || 0) > 0) {
        push @attrs, 'width="' . int($asset->{width}) . '"';
        push @attrs, 'height="' . int($asset->{height}) . '"';
    }
    my $srcset = _media_srcset($asset);
    if (length $srcset) {
        push @attrs, 'srcset="' . escape_html($srcset) . '"';
        push @attrs, 'sizes="' . escape_html($opts{sizes} || '(max-width: 760px) 100vw, 1120px') . '"';
    }
    return '<img ' . join(' ', @attrs) . '>';
}

sub _media_srcset {
    my ($asset) = @_;
    return '' unless $asset && defined $asset->{derivatives_json} && length $asset->{derivatives_json};
    my $derivatives = eval { decode_json($asset->{derivatives_json}) } || {};
    my $sizes = ref $derivatives->{sizes} eq 'ARRAY' ? $derivatives->{sizes} : [];
    my %seen;
    my @entries;
    for my $size (sort { int($a->{width} || 0) <=> int($b->{width} || 0) } grep { ref $_ eq 'HASH' } @{$sizes}) {
        my $path = $size->{path} || '';
        my $width = int($size->{width} || 0);
        next unless DesertCMS::Media::is_public_image_variant_path($path);
        next unless $width > 0;
        next if $seen{$width}++;
        push @entries, "$path ${width}w";
    }
    return @entries > 1 ? join(', ', @entries) : '';
}

sub _content_image_sizes {
    my ($layout, $size) = @_;
    return '(max-width: 760px) 100vw, 420px' if ($layout || '') =~ /\A(?:left|right)\z/ || ($size || '') eq 'small';
    return '(max-width: 760px) 100vw, 720px' if ($size || '') eq 'medium' || ($layout || '') eq 'center';
    return '(max-width: 760px) 100vw, 1120px';
}

sub _resource_extension_label {
    my ($asset, $src) = @_;
    my $preview = _resource_preview_meta($asset);
    my $ext = $preview->{extension} || '';
    if (!length $ext) {
        ($ext) = ($src || $asset->{original_name} || '') =~ /\.([A-Za-z0-9]+)\z/;
        $ext = uc($ext || 'FILE');
    }
    $ext =~ s/[^A-Za-z0-9]+//g;
    return uc(substr($ext || 'FILE', 0, 10));
}

sub _resource_meta_label {
    my ($asset) = @_;
    return '' unless $asset;
    my $preview = _resource_preview_meta($asset);
    my $filename = $preview->{filename} || $asset->{original_name} || '';
    my $bytes = int($preview->{bytes} || $asset->{bytes} || 0);
    my @parts;
    push @parts, $preview->{type_label} if length($preview->{type_label} || '');
    push @parts, $filename if length $filename;
    push @parts, ($preview->{byte_label} || _format_bytes($bytes)) if $bytes > 0 || length($preview->{byte_label} || '');
    return join ' - ', @parts;
}

sub _resource_preview_meta {
    my ($asset) = @_;
    $asset ||= {};
    my $meta = eval { decode_json($asset->{derivatives_json} || '{}') } || {};
    my $resource = ref $meta->{public_resource} eq 'HASH' ? $meta->{public_resource} : {};
    my $preview = ref $meta->{preview} eq 'HASH' ? $meta->{preview} : {};
    my $document = ref $meta->{document} eq 'HASH' ? $meta->{document} : {};
    return {
        extension  => $resource->{extension} || $preview->{extension} || $document->{extension} || '',
        type_label => $resource->{label} || $preview->{type_label} || $preview->{label} || $document->{type_label} || '',
        filename   => $resource->{filename} || $document->{filename} || '',
        bytes      => int($resource->{bytes} || $document->{bytes} || $asset->{bytes} || 0),
        byte_label => $resource->{byte_label} || $preview->{byte_label} || $document->{byte_label} || '',
    };
}

sub _format_bytes {
    my ($bytes) = @_;
    $bytes = int($bytes || 0);
    return '' unless $bytes > 0;
    return $bytes . ' B' if $bytes < 1024;
    return sprintf('%.1f KB', $bytes / 1024) if $bytes < 1024 * 1024;
    return sprintf('%.1f MB', $bytes / (1024 * 1024)) if $bytes < 1024 * 1024 * 1024;
    return sprintf('%.1f GB', $bytes / (1024 * 1024 * 1024));
}

sub _clean_url {
    my ($url) = @_;
    $url = '' unless defined $url;
    $url =~ s/^\s+|\s+$//g;
    return '' if $url =~ /[\r\n<>"\\]/;
    return $url if $url =~ m{\Ahttps://[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]+\z};
    return $url if $url =~ m{\Amailto:[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z};
    return '';
}

sub _social_display_label {
    my ($platform, $label, $url) = @_;
    $platform ||= 'website';
    $label = '' unless defined $label;
    $label =~ s/^\s+|\s+$//g;

    if (!length $label && $platform eq 'email' && $url =~ /\Amailto:([^?#]+)\z/i) {
        $label = $1;
    }
    if (!length $label && $url =~ m{\Ahttps://(?:www\.)?[^/]+/([^?#]+)}i) {
        my @parts = grep { length $_ } split m{/}, $1;
        $label = $parts[-1] || '';
    }
    if (!length $label && $url =~ m{\Ahttps://(?:www\.)?([^/?#]+)}i) {
        $label = $1;
        $label =~ s/\Awww\.//i;
    }

    $label =~ s{\A/+}{};
    return 'Website' if !length $label && $platform eq 'website';
    return ucfirst($platform || 'social') unless length $label;
    return $label if $platform eq 'website' || $platform eq 'email' || $label =~ /\A@/ || $label =~ /\s/;
    return '@' . $label;
}

sub _social_icon_html {
    my ($platform) = @_;
    my %icons = (
        instagram => '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="16" height="16" rx="5"></rect><circle cx="12" cy="12" r="3.5"></circle><path d="M17 7h.01"></path></svg>',
        x         => '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4l16 16"></path><path d="M20 4 4 20"></path></svg>',
        facebook  => '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 8h2V5h-2a4 4 0 0 0-4 4v2H8v3h2v7h3v-7h2.5l.5-3h-3V9a1 1 0 0 1 1-1Z"></path></svg>',
        youtube   => '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M22 12s0-4-1-5-9-1-9-1-8 0-9 1-1 5-1 5 0 4 1 5 9 1 9 1 8 0 9-1 1-5 1-5Z"></path><path d="m10 9 5 3-5 3Z"></path></svg>',
        vimeo     => '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 10c2-2 3-2 4 1l2 6c1 2 2 2 4 0l4-6c2-3 1-6-2-6-2 0-3 1-4 4"></path></svg>',
        website   => '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle><path d="M2 12h20"></path><path d="M12 2a15 15 0 0 1 0 20"></path><path d="M12 2a15 15 0 0 0 0 20"></path></svg>',
        email     => '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2"></rect><path d="m3 7 9 6 9-6"></path></svg>',
    );
    return $icons{$platform || 'website'} || $icons{website};
}

sub _video_embed_url {
    my ($url) = @_;
    if ($url =~ m{\Ahttps://(?:www\.)?youtube\.com/watch\?v=([A-Za-z0-9_-]{6,})}i) {
        return "https://www.youtube-nocookie.com/embed/$1";
    }
    if ($url =~ m{\Ahttps://youtu\.be/([A-Za-z0-9_-]{6,})}i) {
        return "https://www.youtube-nocookie.com/embed/$1";
    }
    if ($url =~ m{\Ahttps://(?:www\.)?vimeo\.com/([0-9]{4,})}i) {
        return "https://player.vimeo.com/video/$1";
    }
    return '';
}

sub _taxonomy_html {
    my ($db, $item) = @_;
    return '' unless $db && $item && $item->{id};

    my $tags = _terms_for_item($db, $item->{id}, 'tags');
    my $collections = _terms_for_item($db, $item->{id}, 'collections');
    my $html = '';
    if (@{$collections}) {
        $html .= '<div class="taxonomy-row"><span>Collections</span>';
        $html .= join '', map {
            '<a href="/collections/' . escape_html($_->{slug}) . '/">' . escape_html($_->{name}) . '</a>'
        } @{$collections};
        $html .= "</div>\n";
    }
    if (@{$tags}) {
        $html .= '<div class="taxonomy-row"><span>Tags</span>';
        $html .= join '', map {
            '<a href="/tags/' . escape_html($_->{slug}) . '/">' . escape_html($_->{name}) . '</a>'
        } @{$tags};
        $html .= "</div>\n";
    }
    return length $html ? qq{<div class="taxonomy">$html</div>\n} : '';
}

sub _terms_for_item {
    my ($db, $content_id, $kind) = @_;
    my %map = (
        tags => {
            table      => 'tags',
            join_table => 'content_tags',
            id_column  => 'tag_id',
        },
        collections => {
            table      => 'collections',
            join_table => 'content_collections',
            id_column  => 'collection_id',
        },
    );
    my $taxonomy = $map{$kind} or return [];
    return $db->dbh->selectall_arrayref(
        qq{
            SELECT t.name, t.slug
            FROM $taxonomy->{table} t
            JOIN $taxonomy->{join_table} ct ON ct.$taxonomy->{id_column} = t.id
            WHERE ct.content_id = ?
            ORDER BY t.name ASC
        },
        { Slice => {} },
        $content_id
    );
}

sub _metadata_for_item {
    my ($config, $site, $item, $db) = @_;
    my $title = $item->{meta_title} || $item->{title};
    my $description = $item->{meta_description}
        || $item->{excerpt}
        || $site->{site_meta_description}
        || $site->{site_description}
        || '';
    my $path = _public_path_for_url($db, $item);
    my $url = $item->{canonical_url} || _absolute_url($config, $path);
    my $image = $item->{feature_image_path} || $site->{social_image_path} || '';
    $image = _absolute_image_url($config, $image);

    return {
        title       => $title,
        description => $description,
        url         => $url,
        image       => $image,
    };
}

sub public_url_for {
    my ($db, $item) = @_;
    return _public_path_for_url($db, $item);
}

sub _public_path_for_url {
    my ($db, $item) = @_;
    return '/' if $item->{type} eq 'page' && ($item->{slug} eq 'home' || $item->{slug} eq 'index');
    return '/posts/' . $item->{slug} . '/' if $item->{type} eq 'post';
    my @segments = _page_segments($db, $item);
    return '/' . join('/', @segments) . '/';
}

sub _page_segments {
    my ($db, $item) = @_;
    return () unless $item && ($item->{type} || 'page') eq 'page';
    return () if ($item->{slug} || '') =~ /\A(?:home|index)\z/;

    my @segments;
    my %seen;
    my $current = $item;
    while ($current) {
        my $id = int($current->{id} || 0);
        last if $id && $seen{$id}++;

        my $slug = _safe_slug_segment($current->{slug});
        unshift @segments, $slug if length $slug && $slug !~ /\A(?:home|index)\z/;

        my $parent_id = int($current->{parent_id} || 0);
        last unless $parent_id && $db;
        $current = $db->dbh->selectrow_hashref(
            q{
                SELECT id, parent_id, type, slug
                FROM content_items
                WHERE id = ?
                  AND type = 'page'
                  AND deleted_at IS NULL
            },
            undef,
            $parent_id
        );
    }

    return @segments ? @segments : ('untitled');
}

sub _safe_slug_segment {
    my ($slug) = @_;
    $slug = lc($slug || '');
    $slug =~ s/[^a-z0-9-]+/-/g;
    $slug =~ s/^-+//;
    $slug =~ s/-+\z//;
    return $slug || 'untitled';
}

sub _absolute_url {
    my ($config, $path) = @_;
    my $base = $config->get('site_url') || '';
    $base =~ s{/+\z}{};
    $path = '/' . $path unless $path =~ m{\A/};
    return $base ? $base . $path : $path;
}

sub _absolute_image_url {
    my ($config, $image) = @_;
    return '' unless $image;
    return $image if $image =~ m{\Ahttps?://}i;
    return _absolute_url($config, $image);
}

sub _favicon_link {
    my ($site, $site_images) = @_;
    return '' unless $site->{favicon_path};
    my $href = escape_html($site->{favicon_path});
    my $meta = _site_image_meta_for_path($site_images, $site->{favicon_path});
    my $sizes = '';
    if ($meta && int($meta->{width} || 0) > 0 && int($meta->{height} || 0) > 0) {
        $sizes = ' sizes="' . int($meta->{width}) . 'x' . int($meta->{height}) . '"';
    }
    return qq{  <link rel="icon" href="$href"$sizes>\n};
}

sub _layout_template_vars {
    my ($config, $db, $site, %args) = @_;
    my $context = _layout_choice($args{context}, 'page', qw(home page post posts module map archive));
    my $header = _layout_choice($site->{site_header_layout}, 'split', qw(split centered stacked compact));
    my $brand = _layout_choice($site->{site_brand_display}, 'auto', qw(auto logo logo-name name));
    my $logo_size = _layout_choice($site->{site_logo_size}, 'medium', qw(small medium large));
    my $nav_style = _layout_choice($site->{site_nav_style}, 'plain', qw(plain underline pills buttons));
    my $home = _layout_choice($site->{site_homepage_layout}, 'standard', qw(standard editorial gallery landing));
    my $width = _layout_choice($site->{site_content_width}, 'standard', qw(narrow standard wide full));
    my $spacing = _layout_choice($site->{site_spacing_scale}, 'comfortable', qw(compact comfortable spacious));
    my $footer = _layout_choice($site->{site_footer_layout}, 'standard', qw(standard compact minimal hidden));
    my $footer_order = _layout_choice($site->{site_footer_order}, 'brand-nav-credit', qw(brand-nav-credit nav-brand-credit credit-brand-nav));
    my $site_images = DesertCMS::Settings::site_image_manifest($config);
    my $navigation = _navigation_html($config, $db);
    my $year = strftime('%Y', localtime);

    my @body = (
        'site-layout',
        "site-layout--$context",
        "site-home--$home",
        "site-width--$width",
        "site-spacing--$spacing",
        "site-header-layout--$header",
        "site-nav-style--$nav_style",
        "site-footer-layout--$footer",
    );
    my @header_class = ('site-header', "site-header--$header", "site-logo-size--$logo_size");
    my @brand_class = ('site-name', "site-brand--$brand");
    my @actions_class = ('site-actions', "site-actions--$header");
    my @nav_class = ('site-nav', "site-nav--$nav_style");
    my @main_class = ('site-main', "site-main--$context", "site-main--$width");
    my @footer_class = ('site-footer', "site-footer--$footer", "site-footer-order--$footer_order");

    return (
        body_class         => join(' ', @body),
        header_class       => join(' ', @header_class),
        brand_class        => join(' ', @brand_class),
        site_actions_class => join(' ', @actions_class),
        nav_class          => join(' ', @nav_class),
        main_class         => join(' ', @main_class),
        footer_class       => join(' ', @footer_class),
        site_name          => escape_html($site->{site_name}),
        site_brand         => _site_brand_html($site, $site_images),
        site_description   => escape_html($site->{site_description}),
        year               => $year,
        navigation         => $navigation,
        footer_brand       => _footer_brand_html($site),
        footer_navigation  => _footer_navigation_html($site, $navigation),
        footer_credit      => _footer_credit_html($site, $year),
        favicon_link       => _favicon_link($site, $site_images),
        theme_style        => DesertCMS::SiteTheme::style_tag($site, config => $config),
        default_theme_mode => DesertCMS::SiteTheme::default_mode($site),
        analytics_enabled  => DesertCMS::Analytics::enabled($config) ? 1 : 0,
        analytics_script   => DesertCMS::Analytics::tracking_script($config),
    );
}

sub _site_brand_html {
    my ($site, $site_images) = @_;
    my $name = escape_html($site->{site_name} || 'DesertCMS');
    my $logo = _site_logo_src($site);
    my $display = _layout_choice($site->{site_brand_display}, 'auto', qw(auto logo logo-name name));
    return $name if $display eq 'name';
    return $name unless length $logo;
    my $src = escape_html($logo);
    my $dimension_attrs = _site_image_dimension_attrs(_site_image_meta_for_path($site_images, $logo));
    my $image = qq{<img class="site-logo" src="$src" alt="$name" decoding="async"$dimension_attrs>};
    return qq{<span class="site-brand-lockup">$image<span class="site-brand-text">$name</span></span>}
        if $display eq 'logo-name';
    return $image;
}

sub _site_image_meta_for_path {
    my ($manifest, $path) = @_;
    return undef unless ref $manifest eq 'HASH' && defined $path && length $path;
    for my $kind (values %{$manifest}) {
        next unless ref $kind eq 'HASH';
        for my $meta (values %{$kind}) {
            next unless ref $meta eq 'HASH';
            return $meta if ($meta->{path} || '') eq $path;
        }
    }
    return undef;
}

sub _site_image_dimension_attrs {
    my ($meta) = @_;
    return '' unless $meta && int($meta->{width} || 0) > 0 && int($meta->{height} || 0) > 0;
    return ' width="' . int($meta->{width}) . '" height="' . int($meta->{height}) . '"';
}

sub _site_logo_src {
    my ($site) = @_;
    for my $path ($site->{site_logo_nav_path}, $site->{site_logo_path}) {
        next unless defined $path && length $path;
        return $path if $path =~ m{\A/assets/site/logo(?:-nav)?\.png\z};
    }
    return '';
}

sub _footer_brand_html {
    my ($site) = @_;
    my $name = escape_html($site->{site_name} || 'DesertCMS');
    my $description = '';
    if ($site->{site_footer_description_enabled}) {
        my $safe = escape_html($site->{site_description} || '');
        $description = "<p>$safe</p>" if length $safe;
    }
    return qq{<div class="site-footer-brand"><strong>$name</strong>$description</div>};
}

sub _footer_navigation_html {
    my ($site, $navigation) = @_;
    return '' unless $site->{site_footer_nav_enabled};
    return '' unless length($navigation || '');
    return qq{<nav class="site-footer-nav">$navigation</nav>};
}

sub _footer_credit_html {
    my ($site, $year) = @_;
    my $name = $site->{site_name} || 'DesertCMS';
    my $credit = $site->{site_footer_credit} || '';
    $credit =~ s/^\s+|\s+$//g;
    if (length $credit) {
        $credit =~ s/\{\{year\}\}/$year/g;
        $credit =~ s/\{\{site_name\}\}/$name/g;
        return '<small class="site-footer-credit">' . escape_html($credit) . '</small>';
    }
    return '<small class="site-footer-credit">&copy; ' . escape_html("$year $name") . '</small>';
}

sub _layout_choice {
    my ($value, $fallback, @allowed) = @_;
    for my $allowed (@allowed) {
        return $allowed if defined $value && $value eq $allowed;
    }
    return $fallback;
}

sub _comments_mount {
    my ($item) = @_;
    my $id = int($item->{id} || 0);
    return '' unless $id;
    my $title = escape_html($item->{title} || 'this post');
    return <<"HTML";
<section class="comments-section" data-comments data-rating data-content-id="$id" aria-labelledby="comments-title">
  <div class="comments-heading">
    <div>
      <h2 id="comments-title">Comments</h2>
      <span class="comments-count" data-comments-count>Loading...</span>
    </div>
    <div class="comment-rating" aria-label="Rate this post">
      <strong class="rating-average" data-rating-average>...</strong>
      <div class="rating-stars rating-stars--compact" role="group" aria-label="Rate this post from 1 to 5 stars">
        <button type="button" data-rating-value="1" aria-label="Rate 1 star">&#9733;</button>
        <button type="button" data-rating-value="2" aria-label="Rate 2 stars">&#9733;</button>
        <button type="button" data-rating-value="3" aria-label="Rate 3 stars">&#9733;</button>
        <button type="button" data-rating-value="4" aria-label="Rate 4 stars">&#9733;</button>
        <button type="button" data-rating-value="5" aria-label="Rate 5 stars">&#9733;</button>
      </div>
      <span class="rating-status" data-rating-status>Loading rating...</span>
    </div>
  </div>
  <div class="comments-replies" data-comment-notifications hidden></div>
  <form class="comment-form" data-comment-form>
    <input type="hidden" name="content_id" value="$id">
    <input type="hidden" name="parent_id" value="">
    <label>
      <span>Name</span>
      <input name="author_name" data-comment-name maxlength="40" autocomplete="nickname" placeholder="Display name">
    </label>
    <label>
      <span>Comment</span>
      <textarea name="body" rows="4" maxlength="2000" required placeholder="Add a comment on $title"></textarea>
    </label>
    <label class="comment-honeypot">
      <span>Website</span>
      <input name="website" tabindex="-1" autocomplete="off">
    </label>
    <div class="comment-form-actions">
      <button type="submit">Post comment</button>
      <button type="button" class="comment-cancel" data-comment-cancel hidden>Cancel reply</button>
    </div>
  </form>
  <div class="comments-status" data-comments-status>Loading comments...</div>
  <div class="comments-list" data-comments-list></div>
</section>
<script src="/assets/comments.js" defer></script>
HTML
}

sub _post_share {
    my ($metadata) = @_;
    my $url = $metadata->{url} || '';
    return '' unless length $url;

    my $title = $metadata->{title} || 'Post';
    my $encoded_url = _url_encode($url);
    my $encoded_title = _url_encode($title);
    my @links = (
        {
            id       => 'facebook',
            label    => 'Facebook',
            href     => "https://www.facebook.com/sharer/sharer.php?u=$encoded_url",
            external => 1,
        },
        {
            id       => 'x',
            label    => 'X',
            href     => "https://twitter.com/intent/tweet?url=$encoded_url&text=$encoded_title",
            external => 1,
        },
        {
            id       => 'linkedin',
            label    => 'LinkedIn',
            href     => "https://www.linkedin.com/sharing/share-offsite/?url=$encoded_url",
            external => 1,
        },
        {
            id       => 'reddit',
            label    => 'Reddit',
            href     => "https://www.reddit.com/submit?url=$encoded_url&title=$encoded_title",
            external => 1,
        },
        {
            id    => 'email',
            label => 'Email',
            href  => "mailto:?subject=$encoded_title&body=$encoded_url",
        },
    );

    my $buttons = '';
    for my $link (@links) {
        my $id = $link->{id};
        my $label = escape_html($link->{label});
        my $href = escape_html($link->{href});
        my $external = $link->{external} ? ' target="_blank" rel="noopener noreferrer"' : '';
        my $icon = _share_icon_html($id);
        $buttons .= qq{<a class="post-share-link post-share-link--$id" href="$href"$external aria-label="Share on $label"><span aria-hidden="true">$icon</span><strong>$label</strong></a>};
    }

    return qq{<section class="post-share" aria-label="Share this post"><span>Share</span><div class="post-share-links">$buttons</div></section>\n};
}

sub _social_meta {
    my ($metadata) = @_;
    my $title = escape_html($metadata->{title} || '');
    my $description = escape_html($metadata->{description} || '');
    my $url = escape_html($metadata->{url} || '');
    my $image = escape_html($metadata->{image} || '');
    my $html = <<"HTML";
  <meta property="og:title" content="$title">
  <meta property="og:description" content="$description">
  <meta property="og:type" content="website">
  <meta property="og:url" content="$url">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="$title">
  <meta name="twitter:description" content="$description">
HTML
    if ($image) {
        $html .= qq{  <meta property="og:image" content="$image">\n};
        $html .= qq{  <meta name="twitter:image" content="$image">\n};
    }
    return $html;
}

sub _navigation_html {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my @items = @{DesertCMS::Navigation::list_items($config, $db)};
    if (!@items) {
        @items = (
            { label => 'Home', url => '/' },
        );
    }
    @items = _filter_disabled_module_navigation($site, @items);

    my $shop_item = _shop_navigation_item($config, $db);
    if ($shop_item && !_navigation_has_shop(\@items, $shop_item)) {
        my $insert_at = 0;
        for my $i (0 .. $#items) {
            my $label = lc($items[$i]{label} || '');
            my $url = _navigation_url_key($items[$i]{url});
            if ($label eq 'home' || $url eq '/') {
                $insert_at = $i + 1;
                last;
            }
        }
        splice @items, $insert_at, 0, $shop_item;
    }

    my %seen_url = map { (_navigation_url_key($_->{url}) => 1) } @items;
    my $pages = $db->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM content_items
            WHERE type = 'page'
              AND status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') = 'public'
              AND show_in_nav = 1
            ORDER BY nav_order ASC, title ASC, id ASC
        },
        { Slice => {} }
    );
    for my $page (@{$pages}) {
        my $url = _public_path_for_url($db, $page);
        next if $seen_url{_navigation_url_key($url)}++;
        push @items, {
            label => $page->{nav_label} || $page->{title},
            url   => $url,
        };
    }
    if (DesertCMS::Modules::enabled($site, 'gallery')) {
        my $label = $site->{gallery_title} || 'Showcase';
        push @items, { label => $label, url => '/showcase/' } unless $seen_url{_navigation_url_key('/showcase/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'forms')) {
        my $label = $site->{forms_title} || 'Contact';
        push @items, { label => $label, url => '/forms/' } unless $seen_url{_navigation_url_key('/forms/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'contributor_requests')) {
        push @items, { label => 'Contributors', url => '/contributors/' } unless $seen_url{_navigation_url_key('/contributors/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'docs')) {
        my $label = $site->{docs_title} || 'Resource Hub';
        push @items, { label => $label, url => '/docs/' } unless $seen_url{_navigation_url_key('/docs/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'directory')) {
        my $label = $site->{directory_title} || 'Directory';
        push @items, { label => $label, url => '/directory/' } unless $seen_url{_navigation_url_key('/directory/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'bookings')) {
        my $label = $site->{bookings_title} || 'Bookings';
        push @items, { label => $label, url => '/bookings/' } unless $seen_url{_navigation_url_key('/bookings/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'events')) {
        my $label = $site->{events_title} || 'Events';
        push @items, { label => $label, url => '/events/' } unless $seen_url{_navigation_url_key('/events/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'membership')) {
        my $label = $site->{membership_title} || 'Members';
        push @items, { label => $label, url => '/members/' } unless $seen_url{_navigation_url_key('/members/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'newsletter')) {
        my $label = $site->{newsletter_title} || 'Newsletter';
        push @items, { label => $label, url => '/newsletter/' } unless $seen_url{_navigation_url_key('/newsletter/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'donations')) {
        my $label = $site->{donations_title} || 'Donate';
        push @items, { label => $label, url => '/donate/' } unless $seen_url{_navigation_url_key('/donate/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'testimonials')) {
        my $label = $site->{testimonials_title} || 'Testimonials';
        push @items, { label => $label, url => '/testimonials/' } unless $seen_url{_navigation_url_key('/testimonials/')}++;
    }
    if (DesertCMS::Modules::enabled($site, 'map')) {
        push @items, { label => 'Locations', url => '/map/' } unless $seen_url{_navigation_url_key('/map/')}++;
    }

    return join "\n", map {
        '<a href="' . escape_html($_->{url}) . '">' . escape_html($_->{label}) . '</a>'
    } @items;
}

sub _filter_disabled_module_navigation {
    my ($site, @items) = @_;
    my %reserved = (
        '/map'             => 'map',
        '/shop'            => 'shop',
        '/gallery'         => 'gallery',
        '/showcase'        => 'gallery',
        '/forms'           => 'forms',
        '/contributors'    => 'contributor_requests',
        '/contributors/apply' => 'contributor_requests',
        '/docs'            => 'docs',
        '/directory'       => 'directory',
        '/bookings'        => 'bookings',
        '/events'          => 'events',
        '/members'         => 'membership',
        '/newsletter'      => 'newsletter',
        '/donate'          => 'donations',
        '/testimonials'    => 'testimonials',
    );
    return grep {
        my $key = _navigation_url_key($_->{url});
        my $module = $reserved{$key};
        !$module || DesertCMS::Modules::enabled($site, $module);
    } @items;
}

sub _shop_navigation_item {
    my ($config, $db) = @_;
    my $shop = DesertCMS::Shop->new(config => $config, db => $db);
    return undef unless $shop->catalog_enabled;
    my $url = $shop->shop_url('/');
    return undef unless length $url;
    return { label => 'Shop / Catalog', url => $url };
}

sub _navigation_has_shop {
    my ($items, $shop_item) = @_;
    my $shop_url = _navigation_url_key($shop_item->{url});
    for my $item (@{$items}) {
        return 1 if lc($item->{label} || '') eq 'shop';
        return 1 if lc($item->{label} || '') eq 'shop / catalog';
        return 1 if lc($item->{label} || '') eq 'catalog';
        return 1 if _navigation_url_key($item->{url}) eq $shop_url;
    }
    return 0;
}

sub _navigation_url_key {
    my ($url) = @_;
    $url = '' unless defined $url;
    $url =~ s/^\s+|\s+$//g;
    return '/' if $url eq '/';
    $url =~ s{/+\z}{};
    return lc($url);
}

sub _write_showcase_page {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $title = $site->{gallery_title} || 'Showcase';
    my $description = $site->{gallery_intro} || 'A curated showcase of published assets, collections, products, archives, artwork, venues, and samples.';
    my $safe_title = escape_html($title);
    my $safe_description = escape_html($description);
    my $cards = _showcase_cards(_showcase_items($config, $db));
    my $content = <<"HTML";
<article class="content module-page showcase-page">
  <p class="kicker">Showcase</p>
  <h1>$safe_title</h1>
  <p class="module-intro">$safe_description</p>
  <section class="portfolio-grid showcase-grid" aria-label="$safe_title">
    $cards
  </section>
</article>
HTML
    my $html = render_module_page($config, $db, {
        title       => $title,
        description => $description,
        path        => '/showcase/',
        content     => $content,
    });
    _write_file(File::Spec->catfile($config->get('public_root'), 'showcase', 'index.html'), $html);
}

sub _write_showcase_legacy_redirect {
    my ($config) = @_;
    my $target = escape_html(_absolute_url($config, '/showcase/'));
    my $content = <<"HTML";
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="robots" content="noindex">
  <meta http-equiv="refresh" content="0; url=$target">
  <link rel="canonical" href="$target">
  <title>Showcase</title>
</head>
<body class="showcase-legacy-redirect">
  <p>This page moved to <a href="$target">Showcase</a>.</p>
</body>
</html>
HTML
    _write_file(File::Spec->catfile($config->get('public_root'), 'gallery', 'index.html'), $content);
}

sub _remove_showcase_artifacts {
    my ($config) = @_;
    for my $artifact (
        [ 'showcase', qr/\bmodule-page\s+showcase-page\b/ ],
        [ 'gallery',  qr/(?:\bmodule-page\s+gallery-page\b|\bshowcase-legacy-redirect\b)/ ],
    ) {
        my ($dirname, $marker) = @{$artifact};
        my $dir = File::Spec->catdir($config->get('public_root'), $dirname);
        my $index = File::Spec->catfile($dir, 'index.html');
        if (-f $index) {
            my $body = eval { _read_file($index) } || '';
            unlink $index if $body =~ $marker;
        }
        rmdir $dir if -d $dir;
    }
}

sub _write_contributors_page {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $title = 'Contributors';
    my $description = 'Approved contributors and their DesertCMS sites.';
    my $profiles = DesertCMS::ContributorRequests->new(config => $config, db => $db)->approved_profiles;
    my $cards = _contributor_profile_cards($profiles);
    my $content = <<"HTML";
<article class="content module-page contributors-page">
  <p class="kicker">Contributors</p>
  <h1>$title</h1>
  <p class="module-intro">$description</p>
  <p><a class="module-action-link" href="/contributors/apply/">Apply to become a contributor</a></p>
  <section class="contributors-grid" aria-label="Approved contributors">
    $cards
  </section>
</article>
HTML
    my $html = render_module_page($config, $db, {
        title       => $title,
        description => $description,
        path        => '/contributors/',
        content     => $content,
    });
    _write_file(File::Spec->catfile($config->get('public_root'), 'contributors', 'index.html'), $html);
}

sub _write_contributor_apply_page {
    my ($config, $db) = @_;
    my $title = 'Apply To Become A Contributor';
    my $description = 'Submit your contributor request for review.';
    my $form = _contributor_request_form({
        title        => 'Contributor Application',
        intro        => 'Send your contact details, optional sample images, and a short note about why you want to join.',
        button_label => 'Submit application',
    });
    my $content = <<"HTML";
<article class="content module-page contributor-apply-page">
  <p class="kicker">Contributors</p>
  <h1>$title</h1>
  <p class="module-intro">$description</p>
  $form
</article>
HTML
    my $html = render_module_page($config, $db, {
        title       => $title,
        description => $description,
        path        => '/contributors/apply/',
        content     => $content,
    });
    _write_file(File::Spec->catfile($config->get('public_root'), 'contributors', 'apply', 'index.html'), $html);
}

sub _remove_contributors_artifacts {
    my ($config) = @_;
    my $dir = File::Spec->catdir($config->get('public_root'), 'contributors');
    my $apply_dir = File::Spec->catdir($dir, 'apply');
    my $apply_index = File::Spec->catfile($apply_dir, 'index.html');
    if (-f $apply_index) {
        my $body = eval { _read_file($apply_index) } || '';
        unlink $apply_index if $body =~ /\bmodule-page\s+contributor-apply-page\b/;
    }
    rmdir $apply_dir if -d $apply_dir;
    my $index = File::Spec->catfile($dir, 'index.html');
    if (-f $index) {
        my $body = eval { _read_file($index) } || '';
        unlink $index if $body =~ /\bmodule-page\s+contributors-page\b/;
    }
    rmdir $dir if -d $dir;
}

sub _contributor_profile_cards {
    my ($profiles) = @_;
    return '<p class="portfolio-empty">No contributors have been approved yet.</p>'
        unless @{$profiles || []};

    my $cards = '';
    for my $profile (@{$profiles}) {
        my $name = escape_html($profile->{name} || $profile->{first_name} || 'Contributor');
        my $bio = escape_html($profile->{bio} || '');
        my $domain = escape_html($profile->{domain} || '');
        my $href = $domain ? "https://$domain/" : '#';
        my $image = $profile->{public_profile_image_path} || '';
        my $image_html = '';
        my $media_class = 'contributor-card-media';
        if ($image =~ m{\A/assets/contributors/[a-z0-9-]+\.(?:jpg|png|webp)\z}) {
            my $safe_src = escape_html($image);
            $image_html = qq{<img src="$safe_src" alt="$name" loading="lazy" decoding="async">};
        } else {
            $media_class .= ' contributor-card-media--empty';
            $image_html = '<span aria-hidden="true">' . escape_html(_contributor_initials($profile)) . '</span>';
        }
        my $link = $domain ? qq{<a href="$href">$domain</a>} : '';
        $cards .= <<"HTML";
<article class="contributor-card">
  <figure class="$media_class">$image_html</figure>
  <div>
    <h2>$name</h2>
    <p>$bio</p>
    $link
  </div>
</article>
HTML
    }
    return $cards || '<p class="portfolio-empty">No contributors have been approved yet.</p>';
}

sub _contributor_initials {
    my ($profile) = @_;
    my $name = $profile->{name} || $profile->{first_name} || 'Contributor';
    my @parts = grep { length } split /\s+/, $name;
    my $initials = '';
    for my $part (@parts[0 .. (@parts > 1 ? 1 : 0)]) {
        $initials .= uc substr($part, 0, 1);
    }
    $initials =~ s/[^A-Z0-9]//g;
    return $initials || 'C';
}

sub _showcase_items {
    my ($config, $db) = @_;
    my $items = $db->dbh->selectall_arrayref(
        q{
            SELECT id, original_name, public_path, alt_text, seo_title, seo_description, mime_type, width, height, bytes, derivatives_json,
                   owner_site_id, owner_domain, owner_display_name, created_at
            FROM media_assets
            WHERE deleted_at IS NULL
              AND (
                    public_path LIKE '/assets/media/%'
                 OR public_path LIKE '/assets/resources/%'
              )
            ORDER BY created_at DESC, id DESC
        },
        { Slice => {} }
    );
    push @{$items}, @{_contributor_showcase_items($config, $db)};
    @{$items} = sort { ($b->{created_at} || 0) <=> ($a->{created_at} || 0) || ($b->{id} || 0) <=> ($a->{id} || 0) } @{$items};
    return $items;
}

sub _showcase_cards {
    my ($items) = @_;
    return '<p class="portfolio-empty showcase-empty">No showcase assets have been published yet.</p>'
        unless @{$items || []};

    my $cards = '';
    for my $item (@{$items}) {
        my $src = $item->{image_url} || $item->{public_path} || '';
        if (_safe_showcase_image_src($src)) {
            $cards .= _showcase_image_card($item, $src);
        } elsif (_safe_showcase_resource_src($src)) {
            $cards .= _showcase_resource_card($item, $src);
        }
    }
    return $cards || '<p class="portfolio-empty showcase-empty">No showcase assets have been published yet.</p>';
}

sub _showcase_image_card {
    my ($item, $src) = @_;
    my $title = _showcase_item_title($item);
    my $safe_title = escape_html($title);
    my $description = escape_html($item->{seo_description} || '');
    my $description_html = length $description ? "<p>$description</p>" : '';
    my $meta = _showcase_item_meta($item);
    my $meta_html = length $meta ? '<span>' . escape_html($meta) . '</span>' : '';
    my $dimensions = '';
    if ($item->{width} && $item->{height}) {
        $dimensions = '<small>' . escape_html(int($item->{width}) . ' x ' . int($item->{height})) . '</small>';
    }
    my $image = _media_img_tag($src, $item->{alt_text} || $title, $item, sizes => '(max-width: 760px) 100vw, 360px');
    return <<"HTML";
<figure class="portfolio-card showcase-card showcase-card--image">
  $image
  <figcaption>
    <strong>$safe_title</strong>
    $description_html
    $meta_html
    $dimensions
  </figcaption>
</figure>
HTML
}

sub _showcase_resource_card {
    my ($item, $src) = @_;
    my $title = _showcase_item_title($item);
    my $safe_title = escape_html($title);
    my $description = _showcase_resource_description($item);
    my $description_html = length $description ? '<p>' . escape_html($description) . '</p>' : '';
    my $meta = _resource_meta_label($item) || _showcase_item_meta($item);
    my $meta_html = length $meta ? '<span>' . escape_html($meta) . '</span>' : '';
    my $badge = escape_html(_resource_extension_label($item, $src));
    my $safe_src = escape_html($src);
    return <<"HTML";
<article class="portfolio-card showcase-card showcase-card--resource">
  <div class="showcase-resource-badge" aria-hidden="true"><span>$badge</span></div>
  <div class="showcase-resource-body">
    <strong>$safe_title</strong>
    $description_html
    $meta_html
    <a class="module-action-link" href="$safe_src" download>Download</a>
  </div>
</article>
HTML
}

sub _showcase_resource_description {
    my ($item) = @_;
    return $item->{seo_description} if length($item->{seo_description} || '');
    my $meta = eval { decode_json($item->{derivatives_json} || '{}') } || {};
    my $preview = ref $meta->{preview} eq 'HASH' ? $meta->{preview} : {};
    return $preview->{snippet} || '';
}

sub _contributor_showcase_items {
    my ($config, $db) = @_;
    return DesertCMS::Federation->new(config => $config, db => $db)->approved_media_items;
}

sub _contributor_post_items {
    my ($config, $db) = @_;
    return DesertCMS::Federation->new(config => $config, db => $db)->approved_post_items;
}

sub _gallery_cards {
    my ($items) = @_;
    return _showcase_cards($items);
}

sub _gallery_items {
    return _showcase_items(@_);
}

sub _contributor_gallery_items {
    return _contributor_showcase_items(@_);
}

sub _active_contributor_site_sources {
    my ($config, $db, $surface) = @_;
    return [] unless $db;
    my $rows = eval {
        $db->dbh->selectall_arrayref(
            q{
                SELECT site_id, domain, display_name, config_path,
                       allow_master_gallery, allow_master_posts
                FROM contributor_sites
                WHERE status = 'active'
                  AND config_path <> ''
                ORDER BY display_name ASC, site_id ASC
            },
            { Slice => {} }
        );
    } || [];
    my $root = _contributor_domain_root($config, $db);
    my @filtered = @{$rows};
    if (length $root) {
        @filtered = grep { _domain_is_subdomain($_->{domain}, $root) } @filtered;
    }
    if (($surface || '') eq 'gallery') {
        @filtered = grep { $_->{allow_master_gallery} ? 1 : 0 } @filtered;
    } elsif (($surface || '') eq 'posts') {
        @filtered = grep { $_->{allow_master_posts} ? 1 : 0 } @filtered;
    }
    return \@filtered;
}

sub _open_contributor_db {
    my ($site) = @_;
    return undef unless $site && _safe_contributor_domain($site->{domain});
    my $path = $site->{config_path} || '';
    return undef unless length $path && -f $path;
    my $config = eval { DesertCMS::Config->load($path) };
    return undef unless $config;
    return eval { DesertCMS::DB->new(config => $config) };
}

sub _safe_showcase_image_src {
    my ($src) = @_;
    $src = '' unless defined $src;
    return 1 if DesertCMS::Media::is_public_image_path($src);
    return 1 if $src =~ m{\Ahttps://([a-z0-9.-]+)/assets/media/[0-9a-f]{64}\.(?:jpg|png|webp)\z} && _safe_contributor_domain($1);
    return 0;
}

sub _safe_showcase_resource_src {
    my ($src) = @_;
    $src = '' unless defined $src;
    return $src =~ m{\A/assets/resources/[0-9a-f]{64}\.[a-z0-9]+\z} ? 1 : 0;
}

sub _safe_gallery_image_src {
    return _safe_showcase_image_src(@_);
}

sub _safe_contributor_domain {
    my ($domain) = @_;
    $domain = lc($domain || '');
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+[a-z]{2,}\z/ ? 1 : 0;
}

sub _contributor_domain_root {
    my ($config, $db) = @_;
    my $settings = eval { DesertCMS::Settings::all($config, $db) } || {};
    my $root = $settings->{contributor_domain_root} || '';
    if (!length $root && $config) {
        $root = $config->get('site_url') || '';
        $root =~ s{\Ahttps?://}{}i;
        $root =~ s{/.*\z}{};
    }
    $root = lc($root || '');
    $root =~ s{\Ahttps?://}{}i;
    $root =~ s{/.*\z}{};
    $root =~ s/^\.+|\.+$//g;
    return $root =~ /\A[a-z0-9.-]+\.[a-z]{2,}\z/ ? $root : '';
}

sub _domain_is_subdomain {
    my ($domain, $root) = @_;
    $domain = lc($domain || '');
    $root = lc($root || '');
    $domain =~ s/^\.+|\.+$//g;
    $root =~ s/^\.+|\.+$//g;
    return 0 unless length $domain && length $root;
    return 0 if $domain eq $root;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+\Q$root\E\z/ ? 1 : 0;
}

sub _showcase_item_title {
    my ($item) = @_;
    return $item->{seo_title} if defined $item->{seo_title} && length $item->{seo_title};
    return $item->{alt_text} if defined $item->{alt_text} && length $item->{alt_text};
    my $name = $item->{original_name} || 'Showcase asset';
    $name =~ s{\.[A-Za-z0-9]{2,5}\z}{};
    $name =~ s{[_-]+}{ }g;
    $name =~ s{\s+}{ }g;
    $name =~ s{^\s+|\s+\z}{}g;
    return length $name ? $name : 'Showcase asset';
}

sub _showcase_item_meta {
    my ($item) = @_;
    return $item->{owner_display_name} if defined $item->{owner_display_name} && length $item->{owner_display_name};
    return $item->{owner_domain} if defined $item->{owner_domain} && length $item->{owner_domain};
    return $item->{owner_site_id} if defined $item->{owner_site_id} && length $item->{owner_site_id};
    return '';
}

sub _gallery_item_title {
    return _showcase_item_title(@_);
}

sub _gallery_item_meta {
    return _showcase_item_meta(@_);
}

sub _write_docs_pages {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $docs = DesertCMS::Docs->new(config => $config);
    my $items = _docs_public_items($docs->documents(settings => $site));
    _remove_generated_docs_artifacts($config);
    my $title = $site->{docs_title} || 'Resource Hub';
    my $description = $site->{docs_intro} || 'Guides, documentation, local archive resources, FAQs, and help-center articles.';
    my $safe_title = escape_html($title);
    my $safe_description = escape_html($description);
    my $cards = _docs_cards($items);
    my $hub_summary = _docs_hub_summary($items);
    my $content = <<"HTML";
<article class="content module-page docs-index">
  <p class="kicker">Resource Hub</p>
  <h1>$safe_title</h1>
  <p class="module-intro">$safe_description</p>
  <section class="docs-hub-panel" aria-label="Resource hub summary">
    $hub_summary
  </section>
  <section class="docs-hub-strip" aria-label="Resource hub use cases">
    <span>Guides</span>
    <span>Local archives</span>
    <span>Member resources</span>
    <span>FAQs</span>
    <span>Help centers</span>
  </section>
  <section class="docs-sections" aria-label="$safe_title">
    $cards
  </section>
</article>
HTML
    unless (_published_content_claims_url($db, '/docs/')) {
        my $index_html = render_module_page($config, $db, {
            title       => $title,
            description => $description,
            path        => '/docs/',
            content     => $content,
        });
        _write_file(File::Spec->catfile($config->get('public_root'), 'docs', 'index.html'), $index_html);
    }

    for my $doc (@{$items}) {
        my $safe_doc_title = escape_html($doc->{title});
        my $safe_doc_summary = escape_html($doc->{summary});
        my $safe_doc_type = escape_html($doc->{resource_type} || 'Resource');
        my $meta_strip = _docs_meta_strip($doc);
        my $nav = _docs_nav($items, $doc->{slug});
        my $article = <<"HTML";
<article class="content module-page docs-page">
  <p class="kicker">$safe_doc_type</p>
  <h1>$safe_doc_title</h1>
  <p class="module-intro">$safe_doc_summary</p>
  $meta_strip
  <div class="docs-layout">
    <aside class="docs-sidebar" aria-label="Resource hub pages">
      $nav
    </aside>
    <div class="docs-markdown">
      $doc->{html}
    </div>
  </div>
</article>
HTML
        my $html = render_module_page($config, $db, {
            title       => $doc->{title},
            description => $doc->{summary},
            path        => $doc->{url},
            content     => $article,
        });
        _write_file(File::Spec->catfile($config->get('public_root'), 'docs', split(m{/}, $doc->{slug}), 'index.html'), $html);
    }
}

sub _remove_docs_artifacts {
    my ($config) = @_;
    my $dir = File::Spec->catdir($config->get('public_root'), 'docs');
    my $index = File::Spec->catfile($dir, 'index.html');
    return unless -d $dir;
    if (-f $index) {
        my $body = eval { _read_file($index) } || '';
        remove_tree($dir) if $body =~ /\bdocs-index\b/;
    }
}

sub _remove_generated_docs_artifacts {
    my ($config) = @_;
    my $dir = File::Spec->catdir($config->get('public_root'), 'docs');
    return unless -d $dir;
    my $index = File::Spec->catfile($dir, 'index.html');
    if (-f $index) {
        my $body = eval { _read_file($index) } || '';
        if ($body =~ /\bdocs-index\b/) {
            remove_tree($dir);
            return;
        }
    }
    _remove_generated_docs_children($dir);
}

sub _remove_generated_docs_children {
    my ($dir) = @_;
    opendir my $dh, $dir or return;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    for my $entry (@entries) {
        my $path = File::Spec->catdir($dir, $entry);
        next unless -d $path;
        _remove_generated_docs_children($path);
        my $index = File::Spec->catfile($path, 'index.html');
        next unless -f $index;
        my $body = eval { _read_file($index) } || '';
        remove_tree($path) if $body =~ /\bdocs-page\b/ || $body =~ /\bdocs-index\b/;
    }
}

sub _docs_hub_summary {
    my ($items) = @_;
    my @items = @{$items || []};
    my %types;
    my %sections;
    for my $doc (@items) {
        $types{$doc->{resource_type} || 'Documentation'} = 1;
        $sections{$doc->{audience} || 'General'} = 1;
    }
    my $resource_count = scalar @items;
    my $section_count = scalar keys %sections;
    my $type_count = scalar keys %types;
    my $resource_label = $resource_count == 1 ? 'Resource' : 'Resources';
    my $section_label = $section_count == 1 ? 'Section' : 'Sections';
    my $type_label = $type_count == 1 ? 'Resource type' : 'Resource types';
    return <<"HTML";
<div class="docs-hub-stat"><span>$resource_label</span><strong>$resource_count</strong></div>
<div class="docs-hub-stat"><span>$section_label</span><strong>$section_count</strong></div>
<div class="docs-hub-stat"><span>$type_label</span><strong>$type_count</strong></div>
HTML
}

sub _docs_public_items {
    my ($items) = @_;
    return [ grep { $_->{public_access} } @{$items || []} ];
}

sub _docs_cards {
    my ($items) = @_;
    return '<p class="docs-empty">No public resource files were found.</p>'
        unless @{$items || []};

    my $html = '';
    for my $group (_docs_grouped_items($items)) {
        my ($audience, $docs) = @{$group};
        my $safe_audience = escape_html($audience);
        my $cards = '';
        for my $doc (@{$docs}) {
            my $title = escape_html($doc->{title});
            my $summary = escape_html($doc->{summary});
            my $url = escape_html($doc->{url});
            my $type = escape_html($doc->{resource_type} || 'Documentation');
            my $meta = _docs_card_meta($doc);
            my $tags = _docs_tag_row($doc);
            $cards .= <<"HTML";
<a class="docs-card" href="$url">
  <span class="docs-type-pill">$type</span>
  <strong>$title</strong>
  <p>$summary</p>
  $meta
  $tags
</a>
HTML
        }
        $html .= <<"HTML";
<section class="docs-audience-group" aria-label="$safe_audience resources">
  <h2 class="docs-audience-heading">$safe_audience</h2>
  <div class="docs-grid">
    $cards
  </div>
</section>
HTML
    }
    return $html;
}

sub _docs_card_meta {
    my ($doc) = @_;
    my @items = (
        $doc->{audience} || 'General',
        $doc->{access} || 'Public',
    );
    push @items, 'Updated ' . $doc->{updated} if length($doc->{updated} || '');
    my $html = join '', map { '<span>' . escape_html($_) . '</span>' } @items;
    return qq{<div class="docs-card-meta">$html</div>};
}

sub _docs_tag_row {
    my ($doc) = @_;
    return '' unless @{$doc->{tags} || []};
    my $html = join '', map { '<span>' . escape_html($_) . '</span>' } @{$doc->{tags}};
    return qq{<div class="docs-card-tags">$html</div>};
}

sub _docs_meta_strip {
    my ($doc) = @_;
    my @items = (
        [ 'Section', $doc->{audience} || 'General' ],
        [ 'Access',  $doc->{access} || 'Public' ],
    );
    push @items, [ 'Updated', $doc->{updated} ] if length($doc->{updated} || '');
    push @items, [ 'Tags', $doc->{tags_label} ] if length($doc->{tags_label} || '');
    my $html = '';
    for my $item (@items) {
        my ($label, $value) = @{$item};
        $html .= '<div><span>' . escape_html($label) . '</span><strong>' . escape_html($value) . '</strong></div>';
    }
    return qq{<div class="docs-meta-strip" aria-label="Resource details">$html</div>};
}

sub _docs_nav {
    my ($items, $active_slug) = @_;
    return '' unless @{$items || []};
    my $html = '<nav class="docs-nav">';
    for my $group (_docs_grouped_items($items)) {
        my ($audience, $docs) = @{$group};
        my $safe_audience = escape_html($audience);
        $html .= qq{<div class="docs-nav-group"><span class="docs-nav-group-title">$safe_audience</span>};
        for my $doc (@{$docs}) {
            my $title = escape_html($doc->{title});
            my $url = escape_html($doc->{url});
            my $class = ($doc->{slug} || '') eq ($active_slug || '') ? ' class="active"' : '';
            $html .= qq{<a$class href="$url">$title</a>};
        }
        $html .= '</div>';
    }
    $html .= '</nav>';
    return $html;
}

sub _docs_grouped_items {
    my ($items) = @_;
    my %groups;
    my %seen;
    for my $doc (@{$items || []}) {
        my $audience = $doc->{audience} || 'General';
        push @{ $groups{$audience} }, $doc;
        $seen{$audience} = 1;
    }
    my @order = grep { $seen{$_} } ('Site Management', 'Technical', 'General');
    my %ordered = map { $_ => 1 } @order;
    push @order, sort { lc($a) cmp lc($b) } grep { !$ordered{$_} } keys %groups;
    return map { [ $_, $groups{$_} || [] ] } @order;
}

sub _write_directory_pages {
    my ($config, $db) = @_;
    my $directory_dir = File::Spec->catdir($config->get('public_root'), 'directory');
    remove_tree($directory_dir) if -d $directory_dir;

    my $directory = DesertCMS::Directory->new(config => $config, db => $db);
    my $site = DesertCMS::Settings::all($config, $db);
    my $title = $site->{directory_title} || 'Directory';
    my $intro = $site->{directory_intro} || 'People, businesses, artists, contributors, vendors, members, places, organizations, and resources.';
    my $safe_title = escape_html($title);
    my $safe_intro = escape_html($intro);
    my $submit = $site->{directory_submissions_enabled}
        ? '<a class="module-action-link" href="/directory/submit/">Suggest a listing</a>'
        : '';
    my $cards = '';
    for my $entry (@{ $directory->published_entries(limit => 500) }) {
        $cards .= _directory_static_card($entry);
        _write_directory_detail_page($config, $db, $entry);
    }
    $cards ||= '<p class="events-empty">No directory entries yet.</p>';
    my $index_content = <<"HTML";
<article class="content module-page directory-page directory-shell">
  <header class="events-heading">
    <p class="kicker">Directory</p>
    <h1>$safe_title</h1>
    <p class="module-intro">$safe_intro</p>
    $submit
  </header>
  <section class="events-grid directory-grid" aria-label="Directory entries">
    $cards
  </section>
</article>
HTML
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'directory', 'index.html'),
        render_module_page($config, $db, {
            title       => $title,
            description => $intro,
            path        => '/directory/',
            content     => $index_content,
            context     => 'module',
        })
    );
    _write_directory_submit_page($config, $db) if $site->{directory_submissions_enabled};
}

sub _write_directory_detail_page {
    my ($config, $db, $entry) = @_;
    my $title = escape_html($entry->{title} || 'Directory entry');
    my $summary = escape_html($entry->{summary} || '');
    my $kind = escape_html(DesertCMS::Directory::kind_label($entry->{kind}));
    my $body = escape_html($entry->{body} || '');
    $body =~ s/\n/<br>/g;
    my $image = escape_html($entry->{image_path} || '');
    my $image_html = length $image ? qq{<img class="directory-detail-image" src="$image" alt="">} : '';
    my $contact = _directory_static_contact_html($entry);
    my $location = _directory_static_location_html($entry);
    my $terms = _directory_static_terms_html($entry);
    my $slug = _safe_slug_segment($entry->{slug} || 'entry');
    my $content = <<"HTML";
<article class="content module-page directory-page directory-detail">
  <p class="kicker">$kind</p>
  <h1>$title</h1>
  <p class="module-intro">$summary</p>
  $image_html
  <div class="body directory-body"><p>$body</p></div>
  $contact
  $location
  $terms
  <p><a href="/directory/">Back to directory</a></p>
</article>
HTML
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'directory', $slug, 'index.html'),
        render_module_page($config, $db, {
            title       => $entry->{title} || 'Directory entry',
            description => $entry->{summary} || '',
            path        => '/directory/' . $slug . '/',
            content     => $content,
            context     => 'module',
        })
    );
}

sub _write_directory_submit_page {
    my ($config, $db) = @_;
    my $kind_options = _directory_static_kind_options();
    my $location_options = _directory_static_location_options();
    my $content = <<"HTML";
<article class="content module-page directory-page directory-submit">
  <p class="kicker">Directory</p>
  <h1>Suggest a Listing</h1>
  <p class="module-intro">Share a person, business, artist, vendor, member, place, organization, or resource for review.</p>
  <form method="post" action="/directory/submit/" class="public-form">
    <div class="public-form-grid">
      <label class="public-field"><span>Name</span><input name="title" required maxlength="180"></label>
      <label class="public-field"><span>Type</span><select name="kind">$kind_options</select></label>
      <label class="public-field"><span>Email</span><input name="email" type="email" maxlength="180"></label>
      <label class="public-field"><span>Website</span><input name="website_url" type="url" maxlength="500"></label>
    </div>
    <label class="public-field public-field--full"><span>Summary</span><textarea name="summary" rows="3" maxlength="500"></textarea></label>
    <label class="public-field public-field--full"><span>Notes for review</span><textarea name="submission_note" rows="4" maxlength="1000"></textarea></label>
    <fieldset class="public-field public-field--full">
      <legend>Optional location</legend>
      <label><input type="checkbox" name="location_enabled" value="1"> Include on Map / Locations</label>
      <div class="public-form-grid">
        <label class="public-field"><span>Location label</span><input name="location_label" maxlength="300"></label>
        <label class="public-field"><span>Location type</span><select name="location_kind">$location_options</select></label>
        <label class="public-field"><span>Latitude</span><input name="location_lat" inputmode="decimal"></label>
        <label class="public-field"><span>Longitude</span><input name="location_lng" inputmode="decimal"></label>
      </div>
    </fieldset>
    <label class="comment-honeypot"><span>Website</span><input name="website" tabindex="-1" autocomplete="off"></label>
    <button type="submit">Submit for review</button>
  </form>
</article>
HTML
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'directory', 'submit', 'index.html'),
        render_module_page($config, $db, {
            title       => 'Suggest a Listing',
            description => 'Suggest a directory listing for review.',
            path        => '/directory/submit/',
            content     => $content,
            context     => 'module',
        })
    );
}

sub _remove_directory_artifacts {
    my ($config) = @_;
    my $root = $config->get('public_root');
    my $directory_dir = File::Spec->catdir($root, 'directory');
    remove_tree($directory_dir) if -d $directory_dir;
}

sub _directory_static_card {
    my ($entry) = @_;
    my $slug = escape_html($entry->{slug} || '');
    my $title = escape_html($entry->{title} || 'Directory entry');
    my $summary = escape_html($entry->{summary} || '');
    my $kind = escape_html(DesertCMS::Directory::kind_label($entry->{kind}));
    my $image = escape_html($entry->{image_path} || '');
    my $image_html = length $image ? qq{<img src="$image" alt="" loading="lazy">} : '<div class="event-card-date" aria-hidden="true">' . substr($kind, 0, 1) . '</div>';
    my $location = escape_html($entry->{location_label} || '');
    my $location_html = length $location ? qq{<span>$location</span>} : '';
    return <<"HTML";
<a class="event-card directory-card" href="/directory/$slug/">
  $image_html
  <div class="event-card-body">
    <span class="event-time">$kind</span>
    <h2>$title</h2>
    <p>$summary</p>
    $location_html
  </div>
</a>
HTML
}

sub _directory_static_contact_html {
    my ($entry) = @_;
    my @items;
    push @items, [ 'Email', '<a href="mailto:' . escape_html($entry->{email}) . '">' . escape_html($entry->{email}) . '</a>' ] if length($entry->{email} || '');
    push @items, [ 'Phone', escape_html($entry->{phone}) ] if length($entry->{phone} || '');
    push @items, [ 'Website', '<a href="' . escape_html($entry->{website_url}) . '">' . escape_html($entry->{website_url}) . '</a>' ] if length($entry->{website_url} || '');
    push @items, [ 'Social', '<a href="' . escape_html($entry->{social_url}) . '">' . escape_html($entry->{social_url}) . '</a>' ] if length($entry->{social_url} || '');
    return '' unless @items;
    my $rows = join '', map { '<div><dt>' . escape_html($_->[0]) . '</dt><dd>' . $_->[1] . '</dd></div>' } @items;
    return qq{<dl class="event-meta directory-meta">$rows</dl>};
}

sub _directory_static_location_html {
    my ($entry) = @_;
    my @items;
    push @items, [ 'Address', escape_html($entry->{address}) ] if length($entry->{address} || '');
    push @items, [ 'Location', escape_html($entry->{location_label}) ] if length($entry->{location_label} || '');
    if ($entry->{location_enabled} && defined $entry->{location_lat} && defined $entry->{location_lng}) {
        push @items, [ 'Map', '<a href="/map/">View location</a><small>' . escape_html($entry->{location_lat}) . ', ' . escape_html($entry->{location_lng}) . '</small>' ];
    }
    return '' unless @items;
    my $rows = join '', map { '<div><dt>' . escape_html($_->[0]) . '</dt><dd>' . $_->[1] . '</dd></div>' } @items;
    return qq{<dl class="event-meta directory-meta">$rows</dl>};
}

sub _directory_static_terms_html {
    my ($entry) = @_;
    my @terms = grep { length } ($entry->{categories_text} || '', $entry->{tags_text} || '');
    return '' unless @terms;
    my $html = join '', map { '<span>' . escape_html($_) . '</span>' } map { split /\s*,\s*/, $_ } @terms;
    return qq{<div class="docs-card-tags directory-tags">$html</div>};
}

sub _directory_static_kind_options {
    return join '', map {
        '<option value="' . escape_html($_) . '">' . escape_html(DesertCMS::Directory::kind_label($_)) . '</option>'
    } @{ DesertCMS::Directory::kinds() };
}

sub _directory_static_location_options {
    my @options = (
        [ store           => 'Store' ],
        [ venue           => 'Venue' ],
        [ project         => 'Project location' ],
        [ historical_site => 'Historical site' ],
        [ event_location  => 'Event location' ],
        [ service_area    => 'Service area' ],
        [ other           => 'Other location' ],
    );
    return join '', map {
        '<option value="' . escape_html($_->[0]) . '">' . escape_html($_->[1]) . '</option>'
    } @options;
}

sub _write_bookings_pages {
    my ($config, $db) = @_;
    my $bookings_dir = File::Spec->catdir($config->get('public_root'), 'bookings');
    remove_tree($bookings_dir) if -d $bookings_dir;

    my $bookings = DesertCMS::Bookings->new(config => $config, db => $db);
    my $site = DesertCMS::Settings::all($config, $db);
    my $title = $site->{bookings_title} || 'Bookings';
    my $intro = $site->{bookings_intro} || 'Request appointments, consultations, service sessions, venue time, or project meetings.';
    my $safe_title = escape_html($title);
    my $safe_intro = escape_html($intro);
    my $cards = '';
    for my $service (@{ $bookings->published_services(limit => 500) }) {
        $cards .= _booking_static_card($service);
        _write_booking_detail_page($config, $db, $bookings, $service, $site);
    }
    $cards ||= '<p class="events-empty">No booking services are available yet.</p>';
    my $index_content = <<"HTML";
<article class="content module-page bookings-page bookings-shell">
  <header class="events-heading">
    <p class="kicker">Bookings</p>
    <h1>$safe_title</h1>
    <p class="module-intro">$safe_intro</p>
  </header>
  <section class="events-grid bookings-grid" aria-label="Booking services">
    $cards
  </section>
</article>
HTML
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'bookings', 'index.html'),
        render_module_page($config, $db, {
            title       => $title,
            description => $intro,
            path        => '/bookings/',
            content     => $index_content,
            context     => 'module',
        })
    );
}

sub _write_booking_detail_page {
    my ($config, $db, $bookings, $service, $site) = @_;
    my $title = escape_html($service->{title} || 'Booking service');
    my $summary = escape_html($service->{summary} || '');
    my $kind = escape_html(DesertCMS::Bookings::service_kind_label($service->{service_kind}));
    my $body = escape_html($service->{body} || '');
    $body =~ s/\n/<br>/g;
    my $availability = escape_html($service->{availability_text} || '');
    $availability =~ s/\n/<br>/g;
    my $availability_html = length $availability
        ? qq{<section class="event-action-panel"><h2>Availability</h2><p>$availability</p></section>}
        : '';
    my $image = escape_html($service->{image_path} || '');
    my $image_html = length $image ? qq{<img class="directory-detail-image" src="$image" alt="">} : '';
    my $meta = _booking_static_meta($bookings, $service);
    my $form = _booking_static_request_form($bookings, $service, $site);
    my $slug = _safe_slug_segment($service->{slug} || 'service');
    my $content = <<"HTML";
<article class="content module-page bookings-page booking-detail">
  <p class="kicker">$kind</p>
  <h1>$title</h1>
  <p class="module-intro">$summary</p>
  $image_html
  $meta
  <div class="body directory-body"><p>$body</p></div>
  $availability_html
  $form
  <p><a href="/bookings/">Back to bookings</a></p>
</article>
HTML
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'bookings', $slug, 'index.html'),
        render_module_page($config, $db, {
            title       => $service->{title} || 'Booking service',
            description => $service->{summary} || '',
            path        => '/bookings/' . $slug . '/',
            content     => $content,
            context     => 'module',
        })
    );
}

sub _remove_bookings_artifacts {
    my ($config) = @_;
    my $root = $config->get('public_root');
    my $bookings_dir = File::Spec->catdir($root, 'bookings');
    remove_tree($bookings_dir) if -d $bookings_dir;
}

sub _booking_static_card {
    my ($service) = @_;
    my $slug = escape_html($service->{slug} || '');
    my $title = escape_html($service->{title} || 'Booking service');
    my $summary = escape_html($service->{summary} || '');
    my $kind = escape_html(DesertCMS::Bookings::service_kind_label($service->{service_kind}));
    my $image = escape_html($service->{image_path} || '');
    my $image_html = length $image ? qq{<img src="$image" alt="" loading="lazy">} : '<div class="event-card-date" aria-hidden="true">' . substr($kind, 0, 1) . '</div>';
    my $location = escape_html($service->{location_label} || '');
    my $location_html = length $location ? qq{<span>$location</span>} : '';
    return <<"HTML";
<a class="event-card booking-card" href="/bookings/$slug/">
  $image_html
  <div class="event-card-body">
    <span class="event-time">$kind</span>
    <h2>$title</h2>
    <p>$summary</p>
    $location_html
  </div>
</a>
HTML
}

sub _booking_static_meta {
    my ($bookings, $service) = @_;
    my @items;
    push @items, [ 'Duration', int($service->{duration_minutes}) . ' minutes' ] if int($service->{duration_minutes} || 0) > 0;
    push @items, [ 'Pricing', escape_html($service->{price_note}) ] if length($service->{price_note} || '');
    push @items, [ 'Location', escape_html($service->{location_label}) ] if length($service->{location_label} || '');
    if ($service->{location_enabled} && defined $service->{location_lat} && defined $service->{location_lng}) {
        push @items, [ 'Map', '<a href="/map/">View location</a><small>' . escape_html($service->{location_lat}) . ', ' . escape_html($service->{location_lng}) . '</small>' ];
    }
    if ($service->{deposit_enabled} && int($service->{deposit_amount_cents} || 0) > 0) {
        push @items, [ 'Deposit', escape_html(DesertCMS::Bookings::price_label($service->{deposit_amount_cents}, $service->{deposit_currency})) ];
    }
    return '' unless @items;
    my $rows = join '', map { '<div><dt>' . escape_html($_->[0]) . '</dt><dd>' . $_->[1] . '</dd></div>' } @items;
    return qq{<dl class="event-meta directory-meta booking-meta">$rows</dl>};
}

sub _booking_static_request_form {
    my ($bookings, $service, $site) = @_;
    return '<section class="event-action-panel"><h2>Request Booking</h2><p class="events-empty">Booking requests are paused right now.</p></section>'
        unless $site->{bookings_requests_enabled};
    my $slug = escape_html($service->{slug} || '');
    my $deposit_copy = '';
    my $button = 'Send booking request';
    if ($service->{deposit_enabled} && int($service->{deposit_amount_cents} || 0) > 0) {
        my $price = escape_html(DesertCMS::Bookings::price_label($service->{deposit_amount_cents}, $service->{deposit_currency}));
        if ($bookings->checkout_ready) {
            $deposit_copy = qq{<p class="muted">This service requests a $price deposit through Stripe after the request form is submitted.</p>};
            $button = 'Request booking and pay deposit';
        } else {
            $deposit_copy = qq{<p class="events-notice">A $price deposit is configured, but online deposits are not available on this plan or payment setup. Submit the request and the site owner can follow up.</p>};
        }
    }
    my $safe_button = escape_html($button);
    return <<"HTML";
<section class="event-action-panel">
  <h2>Request Booking</h2>
  $deposit_copy
  <form method="post" action="/bookings/$slug/request" class="public-form booking-request-form">
    <div class="public-form-grid">
      <label class="public-field"><span>Name</span><input name="name" maxlength="120" autocomplete="name" required></label>
      <label class="public-field"><span>Email</span><input name="email" type="email" maxlength="180" autocomplete="email" required></label>
      <label class="public-field"><span>Phone</span><input name="phone" maxlength="80" autocomplete="tel"></label>
      <label class="public-field"><span>Organization</span><input name="organization" maxlength="160" autocomplete="organization"></label>
      <label class="public-field"><span>Requested date</span><input name="requested_date" type="date" required></label>
      <label class="public-field"><span>Requested time</span><input name="requested_time" type="time"></label>
      <label class="public-field"><span>Preferred window</span><input name="preferred_window" maxlength="120" placeholder="Morning, afternoon, flexible"></label>
      <label class="public-field"><span>Party size</span><input name="party_size" type="number" min="1" max="100000"></label>
      <label class="public-field public-field--full"><span>Budget</span><input name="budget" maxlength="80" placeholder="Optional"></label>
    </div>
    <label class="public-field public-field--full"><span>Notes</span><textarea name="notes" rows="5" maxlength="3000" required></textarea></label>
    <label class="comment-honeypot"><span>Website</span><input name="website" tabindex="-1" autocomplete="off"></label>
    <button type="submit">$safe_button</button>
  </form>
</section>
HTML
}

sub _write_events_pages {
    my ($config, $db) = @_;
    my $events_dir = File::Spec->catdir($config->get('public_root'), 'events');
    remove_tree($events_dir) if -d $events_dir;
    my $ics = File::Spec->catfile($config->get('public_root'), 'events.ics');
    unlink $ics if -f $ics;

    my $events = DesertCMS::Events->new(config => $config, db => $db);
    my $site = DesertCMS::Settings::all($config, $db);
    my $title = $site->{events_title} || 'Events';
    my $intro = $site->{events_intro} || 'Upcoming events, calendars, RSVP opportunities, tickets, and location details.';
    my $safe_title = escape_html($title);
    my $safe_intro = escape_html($intro);
    my $cards = '';
    for my $row (@{ $events->upcoming_occurrences(limit => 80) }) {
        my $event = {
            title => $row->{title},
            slug => $row->{slug},
            timezone => $row->{timezone},
            all_day => $row->{all_day},
            feature_image_path => $row->{feature_image_path},
        };
        my $key = $row->{occurrence_key} || DesertCMS::Events::occurrence_key($event, $row->{starts_at});
        my $url = '/events/' . ($row->{slug} || '') . "/$key/";
        my $event_title = escape_html($row->{title} || 'Event');
        my $summary = escape_html($row->{summary} || '');
        my $time = escape_html(DesertCMS::Events::format_time_label($event, $row->{starts_at}, $row->{ends_at}));
        my $location = escape_html($row->{location_label} || '');
        my $location_html = length $location ? qq{<span>$location</span>} : '';
        my $image = escape_html($row->{feature_image_path} || '');
        my $image_html = length $image ? qq{<img src="$image" alt="" loading="lazy">} : '<div class="event-card-date" aria-hidden="true">' . escape_html($key) . '</div>';
        $cards .= <<"HTML";
<a class="event-card" href="$url">
  $image_html
  <div class="event-card-body">
    <span class="event-time">$time</span>
    <h2>$event_title</h2>
    <p>$summary</p>
    $location_html
  </div>
</a>
HTML
    }
    $cards ||= '<p class="events-empty">No upcoming events yet.</p>';
    my $index_content = <<"HTML";
<article class="content module-page events-page events-shell">
  <header class="events-heading">
    <p class="kicker">Events</p>
    <h1>$safe_title</h1>
    <p class="module-intro">$safe_intro</p>
    <a class="module-action-link" href="/events.ics">Subscribe with calendar</a>
  </header>
  <section class="events-grid" aria-label="Upcoming events">
    $cards
  </section>
</article>
HTML
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'events', 'index.html'),
        render_module_page($config, $db, {
            title       => $title,
            description => $intro,
            path        => '/events/',
            content     => $index_content,
            context     => 'events',
        })
    );

    for my $event (@{ $events->published_events }) {
        my $occurrences = $events->occurrences_for_event($event->{id}, limit => 500);
        my $first = $occurrences->[0];
        _write_event_detail_page($config, $db, $events, $event, $first, '/events/' . ($event->{slug} || '') . '/')
            if $first;
        for my $occurrence (@{$occurrences}) {
            my $key = $occurrence->{occurrence_key} || DesertCMS::Events::occurrence_key($event, $occurrence->{starts_at});
            _write_event_detail_page($config, $db, $events, $event, $occurrence, '/events/' . ($event->{slug} || '') . "/$key/");
        }
    }
    _write_events_ics($config, $db, $events);
}

sub _write_event_detail_page {
    my ($config, $db, $events, $event, $occurrence, $path) = @_;
    return unless $event && $occurrence;
    my $key = $occurrence->{occurrence_key} || DesertCMS::Events::occurrence_key($event, $occurrence->{starts_at});
    my $title = escape_html($event->{title} || 'Event');
    my $summary = escape_html($event->{summary} || '');
    my $body = escape_html($event->{body} || '');
    $body =~ s/\n/<br>/g;
    my $time = escape_html(DesertCMS::Events::format_time_label($event, $occurrence->{starts_at}, $occurrence->{ends_at}));
    my $recurrence = escape_html(DesertCMS::Events::recurrence_summary($event));
    my $location = escape_html($event->{location_label} || '');
    my $location_html = length $location ? qq{<div><dt>Location</dt><dd>$location</dd></div>} : '';
    my $map_link = '';
    if ($event->{location_enabled} && defined $event->{location_lat} && defined $event->{location_lng}) {
        my $lat = escape_html($event->{location_lat});
        my $lng = escape_html($event->{location_lng});
        $map_link = qq{<div><dt>Map</dt><dd><a href="/map/">View location</a><small>$lat, $lng</small></dd></div>};
    }
    my $rsvp_form = '';
    if ($event->{rsvp_enabled}) {
        my $action = '/events/' . escape_html($event->{slug}) . '/' . escape_html($key) . '/rsvp';
        $rsvp_form = <<"HTML";
<section class="event-action-panel">
  <h2>RSVP</h2>
  <form method="post" action="$action" class="public-form event-rsvp-form">
    <div class="public-form-grid">
      <label class="public-field"><span>Name</span><input name="name" maxlength="100" required></label>
      <label class="public-field"><span>Email</span><input name="email" type="email" maxlength="180" required></label>
      <label class="public-field"><span>Guest count</span><input name="guest_count" type="number" min="1" max="100" value="1"></label>
    </div>
    <label class="public-field public-field--full"><span>Notes</span><textarea name="notes" rows="4" maxlength="1000"></textarea></label>
    <label class="comment-honeypot"><span>Website</span><input name="website" tabindex="-1" autocomplete="off"></label>
    <button type="submit">Send RSVP</button>
  </form>
</section>
HTML
    }
    my $ticket_panel = _event_static_ticket_panel($events, $event, $occurrence, $key);
    my $schema = _event_schema_json($config, $event, $occurrence);
    my $content = <<"HTML";
<article class="content module-page events-page event-detail">
  <p class="kicker">Events</p>
  <h1>$title</h1>
  <p class="module-intro">$summary</p>
  <dl class="event-meta">
    <div><dt>When</dt><dd>$time</dd></div>
    <div><dt>Repeats</dt><dd>$recurrence</dd></div>
    $location_html
    $map_link
  </dl>
  <div class="body event-body"><p>$body</p></div>
  $rsvp_form
  $ticket_panel
  <p><a href="/events/">Back to events</a></p>
  <script type="application/ld+json">$schema</script>
</article>
HTML
    my @parts = grep { length } split m{/}, $path;
    _write_file(
        File::Spec->catfile($config->get('public_root'), @parts, 'index.html'),
        render_module_page($config, $db, {
            title       => $event->{title},
            description => $event->{summary},
            path        => $path,
            content     => $content,
            context     => 'events',
        })
    );
}

sub _event_static_ticket_panel {
    my ($events, $event, $occurrence, $key) = @_;
    return '' unless $event->{ticketing_enabled};
    my $tickets = $events->ticket_types($event->{id}, active_only => 1);
    return '<section class="event-action-panel"><h2>Tickets</h2><p class="events-empty">No tickets are available yet.</p></section>' unless @{$tickets};
    my $checkout_ready = $events->checkout_ready;
    my $action = '/events/' . escape_html($event->{slug}) . '/' . escape_html($key) . '/checkout';
    my $rows = '';
    for my $ticket (@{$tickets}) {
        my $id = int($ticket->{id});
        my $name = escape_html($ticket->{name} || 'Ticket');
        my $description = escape_html($ticket->{description} || '');
        my $price = escape_html(DesertCMS::Events::price_label($ticket->{price_cents}, $ticket->{currency}));
        my $button = '';
        if ($checkout_ready && int($ticket->{price_cents} || 0) > 0) {
            $button = <<"HTML";
<form method="post" action="$action" class="event-ticket-form">
  <input type="hidden" name="ticket_type_id" value="$id">
  <label><span>Quantity</span><input name="quantity" type="number" min="1" max="20" value="1"></label>
  <label><span>Email</span><input name="customer_email" type="email" maxlength="180"></label>
  <button type="submit">Buy ticket</button>
</form>
HTML
        } elsif (int($ticket->{price_cents} || 0) > 0) {
            $button = '<p class="events-notice">Paid tickets are not available on this plan or payment setup.</p>';
        } else {
            $button = '<p class="muted">Free ticket. Use RSVP above to reserve a spot.</p>';
        }
        $rows .= <<"HTML";
<article class="event-ticket-option">
  <div><strong>$name</strong><span>$price</span><p>$description</p></div>
  $button
</article>
HTML
    }
    return qq{<section class="event-action-panel"><h2>Tickets</h2><div class="event-ticket-grid">$rows</div></section>};
}

sub _write_events_ics {
    my ($config, $db, $events) = @_;
    my $site_url = $config->get('site_url') || '';
    $site_url =~ s{/+\z}{};
    my $body = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//DesertCMS//Events//EN\r\nCALSCALE:GREGORIAN\r\n";
    for my $row (@{ $events->upcoming_occurrences(limit => 500) }) {
        my $event = { title => $row->{title}, slug => $row->{slug}, timezone => $row->{timezone}, all_day => $row->{all_day} };
        my $key = $row->{occurrence_key} || DesertCMS::Events::occurrence_key($event, $row->{starts_at});
        my $url = $site_url . '/events/' . ($row->{slug} || '') . "/$key/";
        $body .= "BEGIN:VEVENT\r\n";
        $body .= 'UID:event-' . int($row->{id}) . '@desertcms' . "\r\n";
        $body .= 'DTSTAMP:' . _ics_utc(time) . "\r\n";
        if ($row->{all_day}) {
            $body .= 'DTSTART;VALUE=DATE:' . _ics_date($row->{starts_at}, $row->{timezone}) . "\r\n";
            $body .= 'DTEND;VALUE=DATE:' . _ics_date($row->{ends_at}, $row->{timezone}) . "\r\n";
        } else {
            $body .= 'DTSTART:' . _ics_utc($row->{starts_at}) . "\r\n";
            $body .= 'DTEND:' . _ics_utc($row->{ends_at}) . "\r\n";
        }
        $body .= 'SUMMARY:' . _ics_text($row->{title} || 'Event') . "\r\n";
        $body .= 'DESCRIPTION:' . _ics_text($row->{summary} || '') . "\r\n" if length($row->{summary} || '');
        $body .= 'LOCATION:' . _ics_text($row->{location_label} || '') . "\r\n" if length($row->{location_label} || '');
        $body .= 'URL:' . _ics_text($url) . "\r\n";
        $body .= "END:VEVENT\r\n";
    }
    $body .= "END:VCALENDAR\r\n";
    _write_file(File::Spec->catfile($config->get('public_root'), 'events.ics'), $body);
}

sub _remove_events_artifacts {
    my ($config) = @_;
    my $root = $config->get('public_root');
    remove_tree(File::Spec->catdir($root, 'events')) if -d File::Spec->catdir($root, 'events');
    my $ics = File::Spec->catfile($root, 'events.ics');
    unlink $ics if -f $ics;
}

sub _write_newsletter_page {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $newsletter = DesertCMS::Newsletter->new(config => $config, db => $db);
    my $title = $site->{newsletter_title} || 'Newsletter';
    my $intro = $site->{newsletter_intro} || 'Subscribe for announcements, recent posts, events, resources, and site updates.';
    my $consent = $site->{newsletter_consent_text} || 'I agree to receive email updates from this site. I can unsubscribe at any time.';
    my $subscriber_count = scalar @{ $newsletter->active_subscribers(limit => 100000) };
    my $safe_title = escape_html($title);
    my $safe_intro = escape_html($intro);
    my $safe_consent = escape_html($consent);
    my $signup = ($site->{newsletter_signup_enabled} || '') =~ /\A(?:1|true|yes|on)\z/i
        ? <<"HTML"
  <section class="event-action-panel newsletter-signup-panel">
    <h2>Subscribe</h2>
    <form method="post" action="/newsletter/subscribe" class="public-form newsletter-form">
      <div class="public-form-grid">
        <label class="public-field"><span>Email</span><input name="email" type="email" maxlength="254" autocomplete="email" required></label>
        <label class="public-field"><span>Name</span><input name="display_name" maxlength="140" autocomplete="name"></label>
      </div>
      <label class="public-field public-field--full"><span>Consent</span><span class="newsletter-consent">$safe_consent</span></label>
      <input type="hidden" name="consent_text" value="$safe_consent">
      <label class="comment-honeypot"><span>Website</span><input name="website" tabindex="-1" autocomplete="off"></label>
      <button type="submit">Subscribe</button>
    </form>
  </section>
HTML
        : '<section class="event-action-panel newsletter-signup-panel"><h2>Subscribe</h2><p class="events-empty">Newsletter signup is paused right now.</p></section>';
    my $delivery = $newsletter->delivery_readiness;
    my $delivery_note = escape_html($delivery->{send_ready}
        ? 'Delivery is ready through Postmark.'
        : 'Signup and export are available. Sends are blocked until Postmark is ready.');
    my $count_label = $subscriber_count == 1 ? '1 active subscriber' : "$subscriber_count active subscribers";
    my $content = <<"HTML";
<article class="content module-page newsletter-page events-shell">
  <header class="events-heading">
    <p class="kicker">Newsletter</p>
    <h1>$safe_title</h1>
    <p class="module-intro">$safe_intro</p>
  </header>
  <dl class="event-meta newsletter-meta">
    <div><dt>Subscribers</dt><dd>@{[escape_html($count_label)]}</dd></div>
    <div><dt>Delivery</dt><dd>@{[escape_html($delivery->{label})]}<small>$delivery_note</small></dd></div>
  </dl>
  $signup
</article>
HTML
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'newsletter', 'index.html'),
        render_module_page($config, $db, {
            title       => $title,
            description => $intro,
            path        => '/newsletter/',
            content     => $content,
            context     => 'newsletter',
        })
    );
}

sub _remove_newsletter_artifacts {
    my ($config) = @_;
    my $root = $config->get('public_root');
    remove_tree(File::Spec->catdir($root, 'newsletter')) if -d File::Spec->catdir($root, 'newsletter');
}

sub _write_donation_pages {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $donations_dir = File::Spec->catdir($config->get('public_root'), 'donate');
    remove_tree($donations_dir) if -d $donations_dir;
    my $donations = DesertCMS::Donations->new(config => $config, db => $db);
    my $title = $site->{donations_title} || 'Donate';
    my $intro = $site->{donations_intro} || 'Support current campaigns, community projects, events, archives, artists, and public work.';
    my $safe_title = escape_html($title);
    my $safe_intro = escape_html($intro);
    my $cards = '';
    for my $campaign (@{ $donations->published_campaigns(limit => 500) }) {
        $cards .= _donation_static_card($db, $campaign);
        _write_donation_detail_page($config, $db, $donations, $campaign);
    }
    $cards ||= '<p class="donation-empty">No fundraising campaigns yet.</p>';
    my $content = <<"HTML";
<article class="content module-page donations-page donations-shell">
  <header class="donations-hero">
    <div class="donations-hero-copy">
      <p class="kicker">Donations / Fundraising</p>
      <h1>$safe_title</h1>
      <p class="donations-hero-intro">$safe_intro</p>
      <div class="donations-hero-actions">
        <a class="donation-primary-link" href="#donation-campaigns">View campaigns</a>
        <span>Secure checkout opens from each campaign page.</span>
      </div>
    </div>
    <aside class="donations-how-card" aria-label="How donations work">
      <span class="donations-card-label">How to give</span>
      <div class="donations-steps" role="list">
        <div role="listitem"><span>1</span><p><b>Choose a campaign</b><small>Pick the fund or project you want to support.</small></p></div>
        <div role="listitem"><span>2</span><p><b>Select an amount</b><small>Use a suggested amount or enter a custom gift.</small></p></div>
        <div role="listitem"><span>3</span><p><b>Donate securely</b><small>Checkout opens through the configured Stripe payment flow.</small></p></div>
      </div>
    </aside>
  </header>
  <section class="donations-campaigns" id="donation-campaigns" aria-label="Fundraising campaigns">
    <div class="donations-section-heading">
      <p class="kicker">Active campaigns</p>
      <h2>Choose where your support goes</h2>
    </div>
    <div class="donations-grid">
      $cards
    </div>
  </section>
</article>
HTML
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'donate', 'index.html'),
        render_module_page($config, $db, {
            title       => $title,
            description => $intro,
            path        => '/donate/',
            content     => $content,
            context     => 'donations',
        })
    );
}

sub _write_donation_detail_page {
    my ($config, $db, $donations, $campaign) = @_;
    my $slug = $campaign->{slug} || '';
    return unless length $slug;
    my $title = escape_html($campaign->{title} || 'Donation campaign');
    my $summary = escape_html($campaign->{summary} || '');
    my $body = DesertCMS::Donations::campaign_body_html($campaign->{body} || $campaign->{summary} || '');
    my $image = $campaign->{image_path} || '';
    my $image_html = '';
    if (DesertCMS::Media::is_public_image_path($image)) {
        my $asset = _media_asset_for_path($db, $image);
        if ($asset->{public_path}) {
            my $img = _media_img_tag($image, '', $asset, sizes => '(max-width: 760px) 100vw, 460px', loading => 'eager');
            $image_html = qq{<figure class="donation-detail-media">$img</figure>};
        }
    }
    my $progress = _donation_static_progress($campaign);
    my $form = _donation_static_form($donations, $campaign);
    my $content = <<"HTML";
<article class="content module-page donations-page donation-detail">
  <header class="donation-detail-hero">
    <div class="donation-detail-copy">
      <p class="kicker">Donations / Fundraising</p>
      <h1>$title</h1>
      <p class="donation-summary">$summary</p>
    </div>
    $image_html
  </header>
  <section class="donation-priority" aria-label="Donate to $title">
    <div class="donation-priority-copy">
      <p class="kicker">Give now</p>
      <h2>Support this campaign</h2>
      <p>Choose a suggested amount or enter a custom donation, then continue through secure Stripe checkout.</p>
    </div>
    <div class="donation-priority-actions">
      $form
      $progress
    </div>
  </section>
  <section class="donation-story" aria-labelledby="donation-story-heading">
    <div class="donation-story-heading">
      <p class="kicker">Campaign story</p>
      <h2 id="donation-story-heading">Where your donation goes</h2>
    </div>
    <div class="body donation-body">$body</div>
  </section>
  <p class="donation-back"><a href="/donate/">Back to all campaigns</a></p>
</article>
HTML
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'donate', $slug, 'index.html'),
        render_module_page($config, $db, {
            title       => $campaign->{title} || 'Donation campaign',
            description => $campaign->{summary} || '',
            path        => '/donate/' . $slug . '/',
            content     => $content,
            context     => 'donations',
        })
    );
}

sub _remove_donation_artifacts {
    my ($config) = @_;
    my $root = $config->get('public_root');
    remove_tree(File::Spec->catdir($root, 'donate')) if -d File::Spec->catdir($root, 'donate');
}

sub _donation_static_card {
    my ($db, $campaign) = @_;
    my $slug = escape_html($campaign->{slug} || '');
    my $title = escape_html($campaign->{title} || 'Campaign');
    my $summary = escape_html($campaign->{summary} || '');
    my $raised = escape_html(DesertCMS::Donations::price_label($campaign->{raised_cents}, $campaign->{currency}));
    my $goal = int($campaign->{goal_amount_cents} || 0);
    my $goal_label = $goal > 0 && $campaign->{show_goal}
        ? ' of ' . escape_html(DesertCMS::Donations::price_label($goal, $campaign->{currency}))
        : '';
    my $pct = $goal > 0 && $campaign->{show_goal} ? DesertCMS::Donations::progress_percent($campaign) : 0;
    my $meter = $goal > 0 && $campaign->{show_goal}
        ? qq{<div class="donation-meter" aria-hidden="true"><span style="width: $pct%"></span></div>}
        : '';
    my $image = $campaign->{image_path} || '';
    my $image_html;
    if (DesertCMS::Media::is_public_image_path($image)) {
        my $asset = _media_asset_for_path($db, $image);
        if ($asset->{public_path}) {
            my $img = _media_img_tag($image, '', $asset, sizes => '(max-width: 760px) 100vw, 360px');
            $image_html = qq{<span class="donation-card-media">$img</span>};
        }
    } else {
        $image_html = qq{<span class="donation-card-media donation-card-media--empty" aria-hidden="true"><span>Give</span></span>};
    }
    $image_html ||= qq{<span class="donation-card-media donation-card-media--empty" aria-hidden="true"><span>Give</span></span>};
    return <<"HTML";
<a class="donation-card" href="/donate/$slug/">
  $image_html
  <div class="donation-card-body">
    <span class="donation-card-top"><span class="donation-card-kicker">Campaign</span><span class="donation-card-open">Open campaign</span></span>
    <h3>$title</h3>
    <p>$summary</p>
    <span class="donation-card-progress">
      <strong>$raised raised$goal_label</strong>
      $meter
    </span>
    <span class="donation-card-action">Give to this campaign</span>
  </div>
</a>
HTML
}

sub _donation_static_progress {
    my ($campaign) = @_;
    my $raised = escape_html(DesertCMS::Donations::price_label($campaign->{raised_cents}, $campaign->{currency}));
    my $goal = int($campaign->{goal_amount_cents} || 0);
    my $show_goal = $goal > 0 && $campaign->{show_goal} ? 1 : 0;
    my $goal_label = $show_goal ? escape_html(DesertCMS::Donations::price_label($goal, $campaign->{currency})) : '';
    my $pct = DesertCMS::Donations::progress_percent($campaign);
    my $count = int($campaign->{paid_donation_count} || 0);
    my $donation_count = $count == 1 ? '1 donation recorded' : "$count donations recorded";
    my $goal_text = $show_goal ? "of $goal_label goal" : 'raised so far';
    my $meter = $show_goal
        ? qq{<div class="donation-meter" role="progressbar" aria-label="Donation progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow="$pct"><span style="width: $pct%"></span></div><small>$pct% funded</small>}
        : '';
    return <<"HTML";
<section class="donation-progress-panel" aria-label="Campaign progress">
  <div>
    <span>Raised</span>
    <strong>$raised</strong>
    <small>$goal_text</small>
  </div>
  $meter
  <p>$donation_count</p>
</section>
HTML
}

sub _donation_static_form {
    my ($donations, $campaign) = @_;
    my $readiness = $donations->payment_readiness;
    return '<section class="donation-panel donation-panel--unavailable"><p class="donation-panel-kicker">Online giving</p><h2>Online donations are not available</h2><p>'
        . escape_html($readiness->{summary})
        . '</p></section>' unless $readiness->{checkout_enabled};
    my $slug = escape_html($campaign->{slug} || '');
    my $amount_options = '';
    my $first = 1;
    for my $amount (@{ DesertCMS::Donations::suggested_amounts($campaign) }) {
        my $value = escape_html(sprintf('%.2f', $amount / 100));
        my $label = escape_html(DesertCMS::Donations::price_label($amount, $campaign->{currency}));
        my $checked = $first ? 'checked' : '';
        $first = 0;
        $amount_options .= qq{<label class="donation-amount-option"><input type="radio" name="amount" value="$value" $checked><span>$label</span></label>};
    }
    if ($campaign->{allow_custom_amount}) {
        $amount_options .= qq{<label class="donation-custom-amount"><span>Custom amount</span><input name="custom_amount" inputmode="decimal" placeholder="25.00"></label>};
    }
    $amount_options ||= qq{<label class="donation-custom-amount"><span>Amount</span><input name="custom_amount" inputmode="decimal" placeholder="25.00" required></label>};
    my $message_field = $campaign->{donor_message_enabled}
        ? '<label class="public-field public-field--full"><span>Message optional</span><textarea name="donor_message" rows="3"></textarea></label>'
        : '';
    return <<"HTML";
<section class="donation-panel">
  <p class="donation-panel-kicker">Donate online</p>
  <h2>Choose an amount</h2>
  <p class="donation-panel-intro">Use secure Stripe checkout for this campaign. You can review the donation before payment.</p>
  <form method="post" action="/donate/$slug/checkout" class="public-form donation-form">
    <fieldset class="donation-amounts">
      <legend>Donation amount</legend>
      <div class="donation-amount-grid">$amount_options</div>
    </fieldset>
    <div class="donation-donor-grid">
      <label><span>Name optional</span><input name="donor_name" maxlength="160"></label>
      <label><span>Email optional</span><input name="donor_email" type="email" maxlength="180"></label>
    </div>
    $message_field
    <label class="checkbox-field public-field--full"><input type="checkbox" name="anonymous" value="1"><span>Show my donation as anonymous</span></label>
    <button type="submit">Donate securely with Stripe</button>
    <p class="donation-secure-note">Your payment is processed by Stripe; DesertCMS records the campaign, amount, and receipt status.</p>
  </form>
</section>
HTML
}

sub _write_testimonials_pages {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $dir = File::Spec->catdir($config->get('public_root'), 'testimonials');
    remove_tree($dir) if -d $dir;
    make_path($dir);
    my $testimonials = DesertCMS::Testimonials->new(config => $config, db => $db);
    my $title = $site->{testimonials_title} || 'Testimonials';
    my $intro = $site->{testimonials_intro} || 'Reviews, recommendations, client stories, customer feedback, and community praise.';
    my $safe_title = escape_html($title);
    my $safe_intro = escape_html($intro);
    my $cards = join '', map { _testimonial_static_card($_) } @{ $testimonials->published_testimonials(limit => 500) };
    $cards ||= '<p class="events-empty">No testimonials yet.</p>';
    my $submit = _truthy($site->{testimonials_submissions_enabled})
        ? '<a class="module-action-link" href="/testimonials/submit/">Share a testimonial</a>'
        : '';
    my $content = <<"HTML";
<article class="content module-page testimonials-page directory-shell">
  <header class="events-heading">
    <p class="kicker">Testimonials / Reviews</p>
    <h1>$safe_title</h1>
    <p class="module-intro">$safe_intro</p>
    $submit
  </header>
  <section class="events-grid directory-grid testimonials-grid" aria-label="Testimonials and reviews">
    $cards
  </section>
</article>
HTML
    _write_file(
        File::Spec->catfile($dir, 'index.html'),
        render_module_page($config, $db, {
            title       => $title,
            description => $intro,
            path        => '/testimonials/',
            content     => $content,
            context     => 'testimonials',
        })
    );
    _write_testimonials_submit_page($config, $db) if _truthy($site->{testimonials_submissions_enabled});
}

sub _write_testimonials_submit_page {
    my ($config, $db) = @_;
    my $dir = File::Spec->catdir($config->get('public_root'), 'testimonials', 'submit');
    make_path($dir);
    my $rating_options = _testimonial_static_rating_options();
    my $content = <<"HTML";
<article class="content module-page testimonials-page testimonial-submit">
  <p class="kicker">Testimonials / Reviews</p>
  <h1>Share a Testimonial</h1>
  <p class="module-intro">Send a review, recommendation, client story, customer comment, or community note for approval.</p>
  <form method="post" action="/testimonials/submit/" class="public-form">
    <div class="public-form-grid">
      <label class="public-field"><span>Name</span><input name="author_name" required maxlength="180"></label>
      <label class="public-field"><span>Email optional</span><input name="email" type="email" maxlength="180"></label>
      <label class="public-field"><span>Title or role optional</span><input name="author_title" maxlength="180"></label>
      <label class="public-field"><span>Organization optional</span><input name="organization" maxlength="180"></label>
      <label class="public-field"><span>Rating optional</span><select name="rating">$rating_options</select></label>
    </div>
    <label class="public-field public-field--full"><span>Short testimonial</span><textarea name="quote" rows="4" maxlength="1200" required></textarea></label>
    <label class="public-field public-field--full"><span>Additional notes optional</span><textarea name="body" rows="4" maxlength="4000"></textarea></label>
    <label class="comment-honeypot"><span>Website</span><input name="website" tabindex="-1" autocomplete="off"></label>
    <button type="submit">Submit for review</button>
  </form>
</article>
HTML
    _write_file(
        File::Spec->catfile($dir, 'index.html'),
        render_module_page($config, $db, {
            title       => 'Share a Testimonial',
            description => 'Submit a testimonial for approval.',
            path        => '/testimonials/submit/',
            content     => $content,
            context     => 'testimonials',
        })
    );
}

sub _remove_testimonials_artifacts {
    my ($config) = @_;
    my $root = $config->get('public_root');
    remove_tree(File::Spec->catdir($root, 'testimonials')) if -d File::Spec->catdir($root, 'testimonials');
}

sub _testimonial_static_card {
    my ($row) = @_;
    my $author = escape_html($row->{author_name} || 'Reviewer');
    my $quote = escape_html($row->{quote} || '');
    my $body = escape_html($row->{body} || '');
    $body =~ s/\n/<br>/g;
    my $body_html = length $body ? "<p>$body</p>" : '';
    my $byline = _testimonial_static_byline($row);
    my $rating = _testimonial_static_rating_html($row->{rating});
    my $source = escape_html(DesertCMS::Testimonials::source_type_label($row->{source_type}));
    my $related = escape_html($row->{related_directory_title} || $row->{related_booking_title} || '');
    my $related_html = length $related ? "<small>Related to $related</small>" : '';
    my $image = escape_html($row->{image_path} || '');
    my $image_html = length $image ? qq{<img src="$image" alt="" loading="lazy">} : '<div class="event-card-date" aria-hidden="true">"' . substr($author, 0, 1) . '</div>';
    return <<"HTML";
<article class="event-card directory-card testimonial-card">
  $image_html
  <div class="event-card-body">
    <span class="event-time">$source</span>
    <blockquote>$quote</blockquote>
    $body_html
    $rating
    <h2>$author</h2>
    $byline
    $related_html
  </div>
</article>
HTML
}

sub _testimonial_static_byline {
    my ($row) = @_;
    my @parts = grep { length } ($row->{author_title} || '', $row->{organization} || '');
    return '' unless @parts;
    return '<p class="muted">' . escape_html(join ', ', @parts) . '</p>';
}

sub _testimonial_static_rating_html {
    my ($rating) = @_;
    my $label = DesertCMS::Testimonials::rating_label($rating);
    return '' unless length $label;
    return '<p class="event-time testimonial-rating">' . escape_html($label) . '</p>';
}

sub _testimonial_static_rating_options {
    my $html = '<option value="">No rating</option>';
    for my $rating (1 .. 5) {
        $html .= '<option value="' . $rating . '">' . escape_html(DesertCMS::Testimonials::rating_label($rating)) . '</option>';
    }
    return $html;
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _event_schema_json {
    my ($config, $event, $occurrence) = @_;
    my $base = $config->get('site_url') || '';
    $base =~ s{/+\z}{};
    my $key = $occurrence->{occurrence_key} || DesertCMS::Events::occurrence_key($event, $occurrence->{starts_at});
    my $data = {
        '@context' => 'https://schema.org',
        '@type'    => 'Event',
        name       => $event->{title} || 'Event',
        description => $event->{summary} || '',
        startDate  => _schema_datetime($occurrence->{starts_at}, $event->{timezone}, $event->{all_day}),
        endDate    => _schema_datetime($occurrence->{ends_at}, $event->{timezone}, $event->{all_day}),
        eventStatus => 'https://schema.org/EventScheduled',
        eventAttendanceMode => 'https://schema.org/OfflineEventAttendanceMode',
        url        => $base . '/events/' . ($event->{slug} || '') . "/$key/",
    };
    if ($event->{location_label} || $event->{location_enabled}) {
        $data->{location} = {
            '@type' => 'Place',
            name    => $event->{location_label} || 'Event location',
        };
        if (defined $event->{location_lat} && defined $event->{location_lng}) {
            $data->{location}{geo} = {
                '@type' => 'GeoCoordinates',
                latitude => 0 + $event->{location_lat},
                longitude => 0 + $event->{location_lng},
            };
        }
    }
    my $json = encode_json($data);
    $json =~ s{<}{\\u003c}g;
    $json =~ s{>}{\\u003e}g;
    $json =~ s{&}{\\u0026}g;
    return $json;
}

sub _schema_datetime {
    my ($epoch, $timezone, $all_day) = @_;
    my $dt = DesertCMS::DateTimeLite->from_epoch(epoch => int($epoch || 0), time_zone => $timezone || 'UTC');
    return sprintf('%04d-%02d-%02d', $dt->year, $dt->month, $dt->day) if $all_day;
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d%s',
        $dt->year, $dt->month, $dt->day, $dt->hour, $dt->minute, $dt->second, $dt->strftime('%z'));
}

sub _ics_utc {
    my ($epoch) = @_;
    my @t = gmtime(int($epoch || 0));
    return sprintf('%04d%02d%02dT%02d%02d%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _ics_date {
    my ($epoch, $timezone) = @_;
    my $dt = DesertCMS::DateTimeLite->from_epoch(epoch => int($epoch || 0), time_zone => $timezone || 'UTC');
    return sprintf('%04d%02d%02d', $dt->year, $dt->month, $dt->day);
}

sub _ics_text {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/\\/\\\\/g;
    $text =~ s/\r?\n/\\n/g;
    $text =~ s/,/\\,/g;
    $text =~ s/;/\\;/g;
    return $text;
}

sub _write_map_data {
    my ($config, $db) = @_;
    my $data = {
        generated_at => time,
        pins         => _map_pins($config, $db),
    };
    _write_file(
        File::Spec->catfile($config->get('public_root'), 'assets', 'map-pins.json'),
        encode_json($data)
    );
}

sub _write_map_page {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $pins = _map_pins($config, $db);
    my $pin_count = scalar @{$pins};
    my $title = 'Locations';
    my $location_scope = 'Browse mapped locations for stores, venues, project locations, historical sites, event locations, and service areas.';
    my $description = $pin_count
        ? "$pin_count mapped location" . ($pin_count == 1 ? ' is' : 's are') . " available. $location_scope"
        : $location_scope;
    my $url = _absolute_url($config, '/map/');
    my $map_config = _json_script({
        pins_url => '/assets/map-pins.json',
        fit_pins => 1,
        center => {
            lat => 0 + ($site->{map_default_lat} || 34.5),
            lng => 0 + ($site->{map_default_lng} || -112),
        },
        zoom => int($site->{map_default_zoom} || 5),
        default_layer => ($site->{map_default_layer} || 'satellite') eq 'street' ? 'street' : 'satellite',
        layers => _map_layers($site),
    });
    my $content = <<"HTML";
<article class="content map-page">
  <p class="kicker">Locations</p>
  <h1>Locations</h1>
  <p class="archive-description">$description</p>
  <section class="archive-map" data-desert-map>
    <script type="application/json" data-map-config>$map_config</script>
    <div class="map-loading">Loading map...</div>
    <noscript><p>Enable JavaScript to view the interactive map.</p></noscript>
  </section>
  <script src="/assets/map.js" defer></script>
</article>
HTML
    my $html = _fill_template(_read_template($config, 'layout.html'), {
        _layout_template_vars($config, $db, $site, context => 'map'),
        title         => $title,
        excerpt       => escape_html($description),
        canonical_url => escape_html($url),
        social_meta   => _social_meta({ title => $title, description => $description, url => $url, image => _absolute_image_url($config, $site->{social_image_path}) }),
        content       => $content,
    });
    _write_file(File::Spec->catfile($config->get('public_root'), 'map', 'index.html'), $html);
}

sub _remove_map_artifacts {
    my ($config) = @_;
    my $root = $config->get('public_root');
    my $map_json = File::Spec->catfile($root, 'assets', 'map-pins.json');
    unlink $map_json if -f $map_json;
    my $map_dir = File::Spec->catdir($root, 'map');
    remove_tree($map_dir) if -d $map_dir;
}

sub _map_pins {
    my ($config, $db) = @_;
    my $rows = $db->dbh->selectall_arrayref(
        q{
            SELECT id, parent_id, type, title, slug, excerpt, feature_image_path, body_json,
                   location_lat, location_lng,
                   location_kind,
                   location_label, published_at, updated_at
            FROM content_items
            WHERE status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') = 'public'
              AND location_enabled = 1
              AND location_lat IS NOT NULL
              AND location_lng IS NOT NULL
            ORDER BY published_at DESC, updated_at DESC, id DESC
        },
        { Slice => {} }
    );
    my @pins;
    for my $item (@{$rows}) {
        my $kind = _location_kind($item->{location_kind});
        push @pins, {
            id      => int($item->{id}),
            type    => $item->{type} || 'page',
            kind    => $kind,
            kind_label => _location_kind_label($kind),
            title   => $item->{title} || 'Untitled',
            url     => _public_path_for_url($db, $item),
            excerpt => $item->{excerpt} || '',
            image   => _content_card_image($item),
            label   => $item->{location_label} || $item->{title} || 'Location',
            lat     => 0 + $item->{location_lat},
            lng     => 0 + $item->{location_lng},
            updated_at => int($item->{updated_at} || $item->{published_at} || time),
        };
    }

    my $site = DesertCMS::Settings::all($config, $db);
    if (DesertCMS::Modules::enabled($site, 'events')) {
        my $events = DesertCMS::Events->new(config => $config, db => $db);
        for my $row (@{ $events->all_published_occurrences(limit => 2000) }) {
            next unless $row->{location_enabled};
            next unless defined $row->{location_lat} && defined $row->{location_lng};
            my $kind = _location_kind($row->{location_kind} || 'event_location');
            my $event = {
                title    => $row->{title},
                slug     => $row->{slug},
                timezone => $row->{timezone},
                all_day  => $row->{all_day},
            };
            my $key = $row->{occurrence_key}
                || DesertCMS::Events::occurrence_key($event, $row->{starts_at});
            push @pins, {
                id      => 'event-' . int($row->{id}),
                type    => 'event',
                kind    => $kind,
                kind_label => _location_kind_label($kind),
                title   => $row->{title} || 'Event',
                url     => '/events/' . ($row->{slug} || '') . "/$key/",
                excerpt => $row->{summary} || '',
                image   => $row->{feature_image_path} || '',
                label   => $row->{location_label} || $row->{title} || 'Event location',
                lat     => 0 + $row->{location_lat},
                lng     => 0 + $row->{location_lng},
                updated_at => int($row->{event_updated_at} || $row->{starts_at} || time),
            };
        }
    }
    if (DesertCMS::Modules::enabled($site, 'directory')) {
        my $directory = DesertCMS::Directory->new(config => $config, db => $db);
        for my $entry (@{ $directory->published_entries(limit => 2000) }) {
            next unless $entry->{location_enabled};
            next unless defined $entry->{location_lat} && defined $entry->{location_lng};
            my $kind = _location_kind($entry->{location_kind} || 'other');
            push @pins, {
                id      => 'directory-' . int($entry->{id}),
                type    => 'directory',
                kind    => $kind,
                kind_label => _location_kind_label($kind),
                title   => $entry->{title} || 'Directory entry',
                url     => '/directory/' . ($entry->{slug} || '') . '/',
                excerpt => $entry->{summary} || '',
                image   => $entry->{image_path} || '',
                label   => $entry->{location_label} || $entry->{title} || 'Directory location',
                lat     => 0 + $entry->{location_lat},
                lng     => 0 + $entry->{location_lng},
                updated_at => int($entry->{updated_at} || $entry->{published_at} || time),
            };
        }
    }
    if (DesertCMS::Modules::enabled($site, 'bookings')) {
        my $bookings = DesertCMS::Bookings->new(config => $config, db => $db);
        for my $service (@{ $bookings->published_services(limit => 2000) }) {
            next unless $service->{location_enabled};
            next unless defined $service->{location_lat} && defined $service->{location_lng};
            my $kind = _location_kind($service->{location_kind} || 'service_area');
            push @pins, {
                id      => 'booking-' . int($service->{id}),
                type    => 'booking',
                kind    => $kind,
                kind_label => _location_kind_label($kind),
                title   => $service->{title} || 'Booking service',
                url     => '/bookings/' . ($service->{slug} || '') . '/',
                excerpt => $service->{summary} || '',
                image   => $service->{image_path} || '',
                label   => $service->{location_label} || $service->{title} || 'Booking location',
                lat     => 0 + $service->{location_lat},
                lng     => 0 + $service->{location_lng},
                updated_at => int($service->{updated_at} || $service->{published_at} || time),
            };
        }
    }
    return \@pins;
}

sub _location_kind {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/[-\s]+/_/g;
    return $value if $value =~ /\A(?:store|venue|project|historical_site|event_location|service_area|other)\z/;
    return 'other';
}

sub _location_kind_label {
    my ($kind) = @_;
    my %labels = (
        store           => 'Store',
        venue           => 'Venue',
        project         => 'Project location',
        historical_site => 'Historical site',
        event_location  => 'Event location',
        service_area    => 'Service area',
        other           => 'Location',
    );
    return $labels{_location_kind($kind)} || 'Location';
}

sub _map_layers {
    my ($site) = @_;
    my $street_url = _clean_tile_url(
        $site->{map_street_tile_url},
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
    );
    my $satellite_url = _clean_tile_url(
        $site->{map_satellite_tile_url},
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
    );
    return {
        street => {
            label       => 'Map',
            url         => $street_url,
            attribution => $site->{map_street_attribution} || '&copy; OpenStreetMap contributors',
        },
        satellite => {
            label       => 'Satellite',
            url         => $satellite_url,
            attribution => $site->{map_satellite_attribution} || 'Imagery &copy; Esri and its data providers',
        },
    };
}

sub _clean_tile_url {
    my ($url, $fallback) = @_;
    $url = '' unless defined $url;
    $url =~ s/^\s+|\s+$//g;
    return $fallback unless $url =~ /\{z\}/ && $url =~ /\{x\}/ && $url =~ /\{y\}/;
    return $url if $url =~ m{\Ahttps://[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%{}\-,]+\z};
    return $url if $url =~ m{\A/[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%{}\-,]+\z};
    return $fallback;
}

sub _json_script {
    my ($data) = @_;
    my $json = encode_json($data);
    $json =~ s{<}{\\u003c}g;
    $json =~ s{>}{\\u003e}g;
    $json =~ s{&}{\\u0026}g;
    $json =~ s{\x{2028}}{\\u2028}g;
    $json =~ s{\x{2029}}{\\u2029}g;
    return $json;
}

sub _url_encode {
    my ($value) = @_;
    $value = '' unless defined $value;
    my $bytes = encode_utf8($value);
    $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/eg;
    return $bytes;
}

sub _share_icon_html {
    my ($id) = @_;
    my %icons = (
        facebook => '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 8h2V5h-2a4 4 0 0 0-4 4v2H8v3h2v7h3v-7h2.5l.5-3h-3V9a1 1 0 0 1 1-1Z"></path></svg>',
        x        => '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4l16 16"></path><path d="M20 4 4 20"></path></svg>',
        linkedin => '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9v10"></path><path d="M6 5v.01"></path><path d="M11 19v-5.5a3.5 3.5 0 0 1 7 0V19"></path><path d="M11 9v10"></path></svg>',
        reddit   => '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="8" cy="13" r="1"></circle><circle cx="16" cy="13" r="1"></circle><path d="M8.5 17c2.2 1.4 4.8 1.4 7 0"></path><path d="M12 7.5 13.5 3l4 1"></path><path d="M5 11a8 8 0 0 1 14 0"></path><path d="M5 11a2.5 2.5 0 1 0 1.5 4.5"></path><path d="M19 11a2.5 2.5 0 1 1-1.5 4.5"></path><path d="M6.5 15.5a8 8 0 0 0 11 0"></path></svg>',
        email    => '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2"></rect><path d="m3 7 9 6 9-6"></path></svg>',
    );
    return $icons{$id || ''} || $icons{email};
}

sub _write_taxonomy_indexes {
    my ($config, $db) = @_;
    _write_term_indexes($config, $db, 'tags', 'content_tags', 'tag_id', 'Tag', 'tags');
    _write_term_indexes($config, $db, 'collections', 'content_collections', 'collection_id', 'Collection', 'collections');
}

sub _write_term_indexes {
    my ($config, $db, $table, $join_table, $id_column, $label, $base_path) = @_;
    my $terms = $db->dbh->selectall_arrayref(
        qq{
            SELECT DISTINCT t.id, t.name, t.slug
            FROM $table t
            JOIN $join_table ct ON ct.$id_column = t.id
            JOIN content_items c ON c.id = ct.content_id
            WHERE c.status = 'published'
              AND c.deleted_at IS NULL
              AND COALESCE(c.access_policy, 'public') = 'public'
            ORDER BY t.name ASC
        },
        { Slice => {} }
    );

    for my $term (@{$terms}) {
        my $items = $db->dbh->selectall_arrayref(
            qq{
                SELECT c.*
                FROM content_items c
                JOIN $join_table ct ON ct.content_id = c.id
                WHERE ct.$id_column = ?
                  AND c.status = 'published'
                  AND c.deleted_at IS NULL
                  AND COALESCE(c.access_policy, 'public') = 'public'
                ORDER BY c.published_at DESC, c.updated_at DESC
            },
            { Slice => {} },
            $term->{id}
        );
        my $path = File::Spec->catfile($config->get('public_root'), $base_path, $term->{slug}, 'index.html');
        my $html = _archive_html($config, $db, {
            title       => $term->{name},
            label       => $label,
            url_path    => '/' . $base_path . '/' . $term->{slug} . '/',
            description => "$label archive for $term->{name}.",
            items       => $items,
        });
        _write_file($path, $html);
    }
}

sub _archive_html {
    my ($config, $db, $args) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my $title = $args->{title} || 'Archive';
    my $description = $args->{description} || '';
    my $url = _absolute_url($config, $args->{url_path} || '/');
    my $content = _fill_template(_read_template($config, 'archive.html'), {
        archive_type => escape_html($args->{label} || 'Archive'),
        title        => escape_html($title),
        description  => escape_html($description),
        items        => _listing_cards($db, $args->{items} || []),
    });

    return _fill_template(_read_template($config, 'layout.html'), {
        _layout_template_vars($config, $db, $site, context => 'archive'),
        title         => escape_html($title),
        excerpt       => escape_html($description),
        canonical_url => escape_html($url),
        social_meta   => _social_meta({ title => $title, description => $description, url => $url, image => _absolute_image_url($config, $site->{social_image_path}) }),
        content       => $content,
    });
}

sub _listing_cards {
    my ($db, $items) = @_;
    my $cards = '';
    for my $item (@{$items}) {
        my $url = escape_html(_public_path_for_url($db, $item));
        my $title = escape_html($item->{title});
        my $excerpt = escape_html($item->{excerpt});
        my $type = escape_html($item->{type});
        $cards .= qq{<a class="post-card" href="$url"><span>$type</span><h2>$title</h2><p>$excerpt</p></a>\n};
    }
    return $cards || '<p>No published items are assigned here yet.</p>';
}

sub _write_discovery_files {
    my ($config, $db) = @_;
    my $site = DesertCMS::Settings::all($config, $db);
    my @urls;
    for my $item (@{_published_items($db)}) {
        push @urls, {
            loc     => _absolute_url($config, _public_path_for_url($db, $item)),
            lastmod => _date($item->{updated_at} || $item->{published_at}),
        };
    }
    push @urls, {
        loc     => _absolute_url($config, '/posts/'),
        lastmod => _date(time),
    };
    if (DesertCMS::Modules::enabled($site, 'map')) {
        push @urls, {
            loc     => _absolute_url($config, '/map/'),
            lastmod => _date(time),
        };
    }
    if (DesertCMS::Modules::enabled($site, 'gallery')) {
        push @urls, {
            loc     => _absolute_url($config, '/showcase/'),
            lastmod => _date(time),
        };
    }
    if (DesertCMS::Modules::enabled($site, 'forms')) {
        push @urls, {
            loc     => _absolute_url($config, '/forms/'),
            lastmod => _date(time),
        };
    }
    if (DesertCMS::Modules::enabled($site, 'contributor_requests')) {
        push @urls, {
            loc     => _absolute_url($config, '/contributors/'),
            lastmod => _date(time),
        };
    }
    if (DesertCMS::Modules::enabled($site, 'docs')) {
        push @urls, {
            loc     => _absolute_url($config, '/docs/'),
            lastmod => _date(time),
        };
        my $docs = DesertCMS::Docs->new(config => $config);
        for my $doc (@{_docs_public_items($docs->documents(settings => $site))}) {
            push @urls, {
                loc     => _absolute_url($config, $doc->{url}),
                lastmod => _date((stat($doc->{source_path}))[9] || time),
            };
        }
    }
    if (DesertCMS::Modules::enabled($site, 'directory')) {
        push @urls, {
            loc     => _absolute_url($config, '/directory/'),
            lastmod => _date(time),
        };
        push @urls, {
            loc     => _absolute_url($config, '/directory/submit/'),
            lastmod => _date(time),
        } if $site->{directory_submissions_enabled};
        my $directory = DesertCMS::Directory->new(config => $config, db => $db);
        for my $entry (@{ $directory->published_entries(limit => 5000) }) {
            push @urls, {
                loc     => _absolute_url($config, '/directory/' . ($entry->{slug} || '') . '/'),
                lastmod => _date($entry->{updated_at} || $entry->{published_at} || time),
            };
        }
    }
    if (DesertCMS::Modules::enabled($site, 'bookings')) {
        push @urls, {
            loc     => _absolute_url($config, '/bookings/'),
            lastmod => _date(time),
        };
        my $bookings = DesertCMS::Bookings->new(config => $config, db => $db);
        for my $service (@{ $bookings->published_services(limit => 5000) }) {
            push @urls, {
                loc     => _absolute_url($config, '/bookings/' . ($service->{slug} || '') . '/'),
                lastmod => _date($service->{updated_at} || $service->{published_at} || time),
            };
        }
    }
    if (DesertCMS::Modules::enabled($site, 'events')) {
        push @urls, {
            loc     => _absolute_url($config, '/events/'),
            lastmod => _date(time),
        };
        my $events = DesertCMS::Events->new(config => $config, db => $db);
        for my $event (@{ $events->published_events }) {
            push @urls, {
                loc     => _absolute_url($config, '/events/' . ($event->{slug} || '') . '/'),
                lastmod => _date($event->{updated_at} || time),
            };
        }
        for my $occurrence (@{ $events->all_published_occurrences(limit => 5000) }) {
            my $event = {
                title    => $occurrence->{title},
                slug     => $occurrence->{slug},
                timezone => $occurrence->{timezone},
                all_day  => $occurrence->{all_day},
            };
            my $key = $occurrence->{occurrence_key}
                || DesertCMS::Events::occurrence_key($event, $occurrence->{starts_at});
            push @urls, {
                loc     => _absolute_url($config, '/events/' . ($occurrence->{slug} || '') . "/$key/"),
                lastmod => _date($occurrence->{event_updated_at} || $occurrence->{starts_at} || time),
            };
        }
    }
    if (DesertCMS::Modules::enabled($site, 'membership')) {
        push @urls, {
            loc     => _absolute_url($config, '/members/'),
            lastmod => _date(time),
        };
    }
    if (DesertCMS::Modules::enabled($site, 'newsletter')) {
        push @urls, {
            loc     => _absolute_url($config, '/newsletter/'),
            lastmod => _date(time),
        };
    }
    if (DesertCMS::Modules::enabled($site, 'donations')) {
        push @urls, {
            loc     => _absolute_url($config, '/donate/'),
            lastmod => _date(time),
        };
        my $donations = DesertCMS::Donations->new(config => $config, db => $db);
        for my $campaign (@{ $donations->published_campaigns(limit => 5000) }) {
            push @urls, {
                loc     => _absolute_url($config, '/donate/' . ($campaign->{slug} || '') . '/'),
                lastmod => _date($campaign->{updated_at} || time),
            };
        }
    }
    if (DesertCMS::Modules::enabled($site, 'testimonials')) {
        push @urls, {
            loc     => _absolute_url($config, '/testimonials/'),
            lastmod => _date(time),
        };
        if (_truthy($site->{testimonials_submissions_enabled})) {
            push @urls, {
                loc     => _absolute_url($config, '/testimonials/submit/'),
                lastmod => _date(time),
            };
        }
    }
    for my $archive (@{_published_archives($db, 'tags', 'content_tags', 'tag_id', '/tags/')}) {
        push @urls, {
            loc     => _absolute_url($config, $archive->{path}),
            lastmod => _date($archive->{updated_at}),
        };
    }
    for my $archive (@{_published_archives($db, 'collections', 'content_collections', 'collection_id', '/collections/')}) {
        push @urls, {
            loc     => _absolute_url($config, $archive->{path}),
            lastmod => _date($archive->{updated_at}),
        };
    }

    my $xml = qq{<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n};
    for my $url (@urls) {
        $xml .= "  <url>\n";
        $xml .= '    <loc>' . _xml_escape($url->{loc}) . "</loc>\n";
        $xml .= '    <lastmod>' . _xml_escape($url->{lastmod}) . "</lastmod>\n";
        $xml .= "  </url>\n";
    }
    $xml .= "</urlset>\n";
    _write_file(File::Spec->catfile($config->get('public_root'), 'sitemap.xml'), $xml);

    my $sitemap_url = _absolute_url($config, '/sitemap.xml');
    my $robots = "User-agent: *\nDisallow: /admin/\nAllow: /\nSitemap: $sitemap_url\n";
    _write_file(File::Spec->catfile($config->get('public_root'), 'robots.txt'), $robots);
}

sub _published_items {
    my ($db) = @_;
    return $db->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM content_items
            WHERE status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') = 'public'
            ORDER BY type ASC, slug ASC
        },
        { Slice => {} }
    );
}

sub _selected_homepage {
    my ($db, $site) = @_;
    my $id = int($site->{homepage_content_id} || 0);
    return undef unless $id;
    return $db->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM content_items
            WHERE id = ?
              AND type = 'page'
              AND status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') = 'public'
            LIMIT 1
        },
        undef,
        $id
    );
}

sub _published_archives {
    my ($db, $table, $join_table, $id_column, $base) = @_;
    return $db->dbh->selectall_arrayref(
        qq{
            SELECT t.slug, MAX(c.updated_at) AS updated_at, ? || t.slug || '/' AS path
            FROM $table t
            JOIN $join_table ct ON ct.$id_column = t.id
            JOIN content_items c ON c.id = ct.content_id
            WHERE c.status = 'published'
              AND c.deleted_at IS NULL
              AND COALESCE(c.access_policy, 'public') = 'public'
            GROUP BY t.id, t.slug
            ORDER BY t.slug ASC
        },
        { Slice => {} },
        $base
    );
}

sub _write_redirect_artifacts {
    my ($config, $db) = @_;
    my $rules = DesertCMS::Redirects::list_rules($config, $db);
    my $conf = "# Generated by DesertCMS. Include these location blocks inside the OpenBSD httpd server block.\n";
    for my $rule (@{$rules}) {
        my $source = $rule->{source_path};
        my $target = $rule->{target_url};
        my $status = int($rule->{status_code} || 301);
        $conf .= qq{location "$source" {\n\tblock return $status "$target"\n}\n\n};
        _write_redirect_stub($config, $source, $target);
    }
    _write_file(File::Spec->catfile($config->get('public_root'), 'redirects.httpd.conf'), $conf);
}

sub _write_redirect_stub {
    my ($config, $source, $target) = @_;
    return unless $source && $source =~ m{\A/};
    my $safe_target = escape_html($target);
    my $html = <<"HTML";
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="robots" content="noindex">
  <meta http-equiv="refresh" content="0; url=$safe_target">
  <link rel="canonical" href="$safe_target">
  <title>Redirecting</title>
</head>
<body>
  <p>Redirecting to <a href="$safe_target">$safe_target</a>.</p>
</body>
</html>
HTML
    my $path = _redirect_stub_path($config, $source);
    _write_file($path, $html);
}

sub _redirect_stub_path {
    my ($config, $source) = @_;
    $source =~ s{\A/+}{};
    $source =~ s{/+\z}{};
    my @parts = split m{/}, $source;
    push @parts, 'index.html';
    return File::Spec->catfile($config->get('public_root'), @parts);
}

sub _date {
    my ($epoch) = @_;
    $epoch ||= time;
    return strftime('%Y-%m-%d', gmtime($epoch));
}

sub _xml_escape {
    my ($value) = @_;
    return escape_html($value);
}

sub _publish_assets {
    my ($config, $db) = @_;
    DesertCMS::Theme::install_default($config);
    my $site = $db ? DesertCMS::Settings::all($config, $db) : {};
    DesertCMS::FontPackages::publish_selected_fonts($config, $site);
    for my $asset (qw(site.css site.js map.js comments.js)) {
        my $source = File::Spec->catfile($config->get('theme_dir'), 'default', 'assets', $asset);
        my $dest = File::Spec->catfile($config->get('public_root'), 'assets', $asset);
        open my $in, '<', $source or die "cannot read theme asset $source: $!";
        local $/;
        my $body = <$in>;
        close $in;
        _write_file($dest, $body);
    }
}

sub _read_template {
    my ($config, $name) = @_;
    DesertCMS::Theme::install_default($config);
    my $path = File::Spec->catfile($config->get('theme_dir'), 'default', 'templates', $name);
    open my $fh, '<', $path or die "cannot read template $path: $!";
    local $/;
    my $template = <$fh>;
    close $fh;
    return $template;
}

sub _fill_template {
    my ($template, $vars) = @_;
    $template =~ s/\{\{([a-zA-Z0-9_]+)\}\}/exists $vars->{$1} ? $vars->{$1} : ''/eg;
    return $template;
}

sub _write_file {
    my ($path, $body) = @_;
    my (undef, $dir) = File::Spec->splitpath($path);
    make_path($dir) unless -d $dir;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _remove_static_file {
    my ($path) = @_;
    return unless defined $path && length $path;
    unlink $path if -f $path;
}

sub _content_is_public {
    my ($item) = @_;
    return 1 unless $item && ref $item eq 'HASH';
    return ($item->{access_policy} || 'public') eq 'public' ? 1 : 0;
}

sub _read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return defined $body ? $body : '';
}

1;
