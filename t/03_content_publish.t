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

use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::Navigation;
use DesertCMS::Redirects;

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Publish Test
site_url = http://localhost
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
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
my $media_ts = time;
for my $fixture (
    [ 'a', 'Block image', 800, 400 ],
    [ 'b', 'Feature image', 1200, 800 ],
) {
    my ($char, $alt, $width, $height) = @{$fixture};
    my $checksum = $char x 64;
    $db->dbh->do(
        q{
            INSERT INTO media_assets
                (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
                 mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
            VALUES
                (?, ?, ?, ?, ?, ?, 'image/jpeg', ?, ?, ?, ?, ?, ?)
        },
        undef,
        "$char.jpg",
        "$root/originals/$char.jpg",
        "/assets/media/$checksum.jpg",
        $alt,
        "$alt title",
        "$alt description.",
        $width,
        $height,
        2048,
        $checksum,
        _media_derivatives_json($checksum, $width, $height),
        $media_ts
    );
}
my $resource_checksum = 'c' x 64;
my $resource_path = "/assets/resources/$resource_checksum.pdf";
make_path(File::Spec->catdir($root, 'public', 'assets', 'resources'));
open my $resource_fh, '>', File::Spec->catfile($root, 'public', 'assets', 'resources', "$resource_checksum.pdf")
    or die "cannot write public resource fixture: $!";
print {$resource_fh} "%PDF-1.4\n% public fixture\n";
close $resource_fh;
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
        VALUES
            ('resource-guide.pdf', ?, ?, '', 'Resource Guide', 'Download the field guide.',
             'application/pdf', NULL, NULL, 28, ?, ?, ?)
    },
    undef,
    "$root/originals/resource-guide.pdf",
    $resource_path,
    $resource_checksum,
    _resource_derivatives_json($resource_path),
    $media_ts
);

my $content = DesertCMS::Content->new(config => $config, db => $db);
DesertCMS::Navigation::replace_from_text($config, $db, "Home | /\nField Notes | /posts/");
DesertCMS::Redirects::replace_from_text($config, $db, "/old-note | /posts/first-field-note/ | 301");

my $home = $content->save(
    type => 'page',
    title => 'Home',
    slug => 'home',
    excerpt => 'Main page',
    body_text => "Welcome <reader>\n\nDesert archive body.",
);
$content->publish(id => $home->{id});

my $gallery = $content->save(
    type => 'page',
    title => 'Gallery',
    slug => 'gallery',
    excerpt => 'Selected work',
    show_in_nav => 1,
    nav_label => 'Gallery',
    nav_order => 20,
    body_text => 'Gallery overview.',
);
$content->publish(id => $gallery->{id});

my $child_page = $content->save(
    type => 'page',
    title => 'Framed Print',
    slug => 'gallery/framed-print',
    parent_id => $gallery->{id},
    excerpt => 'A nested page',
    body_text => 'Nested child page.',
);
$content->publish(id => $child_page->{id});

my $post = $content->save(
    type => 'post',
    title => 'First Field Note',
    slug => 'first-field-note',
    excerpt => 'A short note',
    meta_title => 'Custom SEO Field Note',
    meta_description => 'A search description for the field note.',
    canonical_url => 'https://example.test/canonical-field-note/',
    feature_image_path => '/assets/media/' . ('b' x 64) . '.jpg',
    location_enabled => 1,
    location_lat => '34.101234',
    location_lng => '-112.202345',
    location_label => 'Desert wash',
    location_kind => 'service_area',
    tags_text => 'Field Work, Prints',
    collections_text => 'Portfolio',
    body_json => encode_json([
        { type => 'heading', text => 'Chapter One', level => 2, align => 'center', font => 'sans', text_size => 'large' },
        { type => 'text', text => 'Post body' },
        {
            type  => 'text',
            text  => 'Rich formatting block',
            html  => '<p>Rich <strong>bold</strong> <em>italic</em> <u>underline</u> <s>strike</s> <a href="https://example.test/article">link</a> <span style="color: var(--accent)">accent words</span><script>alert(1)</script><a href="javascript:alert(1)">bad link</a></p><ul><li>Point one</li></ul>',
            align => 'center',
            font => 'mono',
            text_size => 'large',
        },
        {
            type     => 'code',
            language => 'perl',
            code     => "use strict;\nprint \"desert\";\n",
        },
        {
            type => 'image',
            src => '/assets/media/' . ('a' x 64) . '.jpg',
            alt => 'Desert print',
            caption => 'Display derivative only',
            layout => 'left',
            size => 'small',
        },
        { type => 'text', text => 'Text wraps around the small image.' },
        {
            type       => 'image_text',
            src        => '/assets/media/' . ('a' x 64) . '.jpg',
            alt        => 'Side by side print',
            caption    => 'Side-by-side caption',
            text       => 'Text sits beside a smaller image.',
            html       => '<p>Text sits beside a smaller image. <em>Formatted</em></p>',
            align      => 'right',
            font       => 'sans',
            text_size  => 'small',
            image_side => 'right',
        },
        {
            type    => 'video',
            url     => 'https://youtu.be/abc123DEF45',
            title   => 'Studio walkthrough',
            caption => 'Embedded video caption',
        },
        {
            type        => 'link',
            url         => 'https://example.test/prints',
            label       => 'Print catalog',
            description => 'Browse available editions.',
        },
        {
            type         => 'resource',
            src          => $resource_path,
            label        => 'Field Guide',
            description  => 'Download the public field guide.',
            button_label => 'Download PDF',
        },
        {
            type     => 'social',
            platform => 'instagram',
            url      => 'https://instagram.com/desertarchive',
            label    => 'desertarchive',
        },
        { type => 'quote', text => 'The desert keeps its own archive.', citation => 'Field note', align => 'right', font => 'mono', text_size => 'small' },
        { type => 'divider' },
    ]),
);
$content->publish(id => $post->{id});

my $featured_page = $content->save(
    type => 'page',
    title => 'Featured Story',
    slug => 'featured-story',
    excerpt => 'A page that links to internal work',
    body_json => encode_json([
        {
            type      => 'content_ref',
            target_id => $post->{id},
            style     => 'feature',
        },
    ]),
);
$content->publish(id => $featured_page->{id});

my $index_path = File::Spec->catfile($root, 'public', 'index.html');
my $gallery_path = File::Spec->catfile($root, 'public', 'gallery', 'index.html');
my $child_path = File::Spec->catfile($root, 'public', 'gallery', 'framed-print', 'index.html');
my $featured_path = File::Spec->catfile($root, 'public', 'featured-story', 'index.html');
my $post_path = File::Spec->catfile($root, 'public', 'posts', 'first-field-note', 'index.html');
my $posts_index_path = File::Spec->catfile($root, 'public', 'posts', 'index.html');
my $tag_index_path = File::Spec->catfile($root, 'public', 'tags', 'field-work', 'index.html');
my $collection_index_path = File::Spec->catfile($root, 'public', 'collections', 'portfolio', 'index.html');
my $map_path = File::Spec->catfile($root, 'public', 'map', 'index.html');
my $map_data_path = File::Spec->catfile($root, 'public', 'assets', 'map-pins.json');
my $sitemap_path = File::Spec->catfile($root, 'public', 'sitemap.xml');
my $robots_path = File::Spec->catfile($root, 'public', 'robots.txt');
my $redirect_conf_path = File::Spec->catfile($root, 'public', 'redirects.httpd.conf');
my $redirect_stub_path = File::Spec->catfile($root, 'public', 'old-note', 'index.html');
my $asset_path = File::Spec->catfile($root, 'public', 'assets', 'site.css');
my $map_asset_path = File::Spec->catfile($root, 'public', 'assets', 'map.js');
my $comments_asset_path = File::Spec->catfile($root, 'public', 'assets', 'comments.js');

ok(-f $index_path, 'published home index');
ok(-f $gallery_path, 'published nav page');
ok(-f $child_path, 'published nested child page');
ok(-f $featured_path, 'published internal reference page');
ok(-f $post_path, 'published post page');
ok(-f $posts_index_path, 'published posts index');
ok(-f $tag_index_path, 'published tag archive');
ok(-f $collection_index_path, 'published collection archive');
ok(-f $map_path, 'published map page');
ok(-f $map_data_path, 'published map pin data');
ok(-f $sitemap_path, 'published sitemap');
ok(-f $robots_path, 'published robots file');
ok(-f $redirect_conf_path, 'published httpd redirect include');
ok(-f $redirect_stub_path, 'published static redirect fallback');
ok(-f $asset_path, 'published theme asset');
ok(-f $map_asset_path, 'published map asset');
ok(-f $comments_asset_path, 'published comments asset');

my $index_html = _read($index_path);
like($index_html, qr/Welcome &lt;reader&gt;/, 'escapes home body');
like($index_html, qr/Publish Test/, 'uses site name');
like($index_html, qr/Field Notes/, 'uses configured navigation');
like($index_html, qr{href="/">Home</a>\s*<a href="http://localhost/shop">Shop / Catalog</a>\s*<a href="/posts/">Field Notes</a>}, 'navigation inserts shop module after home on /shop');
like($index_html, qr{href="/gallery/"}, 'checked page appears in navigation');
like($index_html, qr{href="/map/"}, 'navigation includes map page');
like($index_html, qr/class="[^"]*\bsite-footer\b[^"]*"/, 'renders public footer');
like($index_html, qr/data-theme-toggle/, 'renders public theme toggle');
like($index_html, qr/data-site-menu-toggle/, 'renders public mobile navigation toggle');
like($index_html, qr/<nav id="site-primary-nav" class="[^"]*\bsite-nav\b[^"]*" data-site-menu>/, 'renders public navigation menu target');
unlike($index_html, qr/<span class="sr-only">Toggle color theme<\/span>/, 'public theme toggle has no visible text fallback');
unlike($index_html, qr/title="Toggle color theme"/, 'public theme toggle avoids browser tooltip text');
like($index_html, qr{/analytics/collect}, 'injects analytics collector beacon');

my $child_html = _read($child_path);
like($child_html, qr/Framed Print/, 'renders nested child page title');
like($child_html, qr{<link rel="canonical" href="http://localhost/gallery/framed-print/">}, 'nested child canonical URL uses parent path');

my $featured_html = _read($featured_path);
like($featured_html, qr{<a class="content-ref-card content-ref-card--feature" href="/posts/first-field-note/">}, 'renders internal featured content card');
like($featured_html, qr{<img src="/assets/media/b{64}\.jpg" alt="First Field Note" loading="lazy" decoding="async" width="1200" height="800" srcset="[^"]*b{64}-480\.jpg 480w[^"]*b{64}-800\.jpg 800w[^"]*b{64}\.jpg 1200w" sizes="\(max-width: 760px\) 100vw, 520px">}, 'internal content card uses responsive target feature image');
like($featured_html, qr{<span>Post</span><strong>First Field Note</strong><p>Post body</p>}, 'internal content card uses target type, title, and first paragraph');
unlike($featured_html, qr{Browse available editions}, 'internal content card does not reuse external link description');

my $post_html = _read($post_path);
like($post_html, qr/First Field Note/, 'renders post title');
like($post_html, qr/<title>Custom SEO Field Note<\/title>/, 'renders custom meta title');
like($post_html, qr/<meta name="description" content="A search description for the field note\.">/, 'renders custom meta description');
like($post_html, qr/<link rel="canonical" href="https:\/\/example\.test\/canonical-field-note\/">/, 'renders canonical URL');
like($post_html, qr/<meta property="og:title" content="Custom SEO Field Note">/, 'renders og title');
like($post_html, qr/<meta property="og:image" content="http:\/\/localhost\/assets\/media\/b{64}\.jpg">/, 'renders absolute feature image social URL');
like($post_html, qr/<h2 class="heading-align heading-align--center content-font--sans content-size--large">Chapter One<\/h2>/, 'renders heading block with alignment and typography');
like($post_html, qr/Post body/, 'renders post body');
like($post_html, qr{<div class="rich-text rich-text--center content-font--mono content-size--large"><p>Rich <strong>bold</strong> <em>italic</em> <u>underline</u> <s>strike</s> <a href="https://example\.test/article">link</a> <span style="color: var\(--accent\)">accent words</span>bad link</p><ul><li>Point one</li></ul></div>}, 'renders sanitized rich text with alignment, typography, and color');
unlike($post_html, qr/alert\(1\)|javascript:/, 'strips unsafe rich text content');
like($post_html, qr{<pre class="code-block"><code class="language-perl">use strict;\nprint &quot;desert&quot;;\n</code></pre>}, 'renders escaped code block');
like($post_html, qr/<figure class="media-figure media-figure--left media-figure--small"><img src="\/assets\/media\/a{64}\.jpg" alt="Desert print" loading="lazy" decoding="async" width="800" height="400" srcset="[^"]*a{64}-480\.jpg 480w[^"]*a{64}\.jpg 800w" sizes="\(max-width: 760px\) 100vw, 420px">/, 'renders responsive floated image block');
like($post_html, qr/Display derivative only/, 'renders image caption');
like($post_html, qr/Text wraps around the small image/, 'renders text after floated image');
like($post_html, qr/class="image-text image-text--right"/, 'renders image and text block');
like($post_html, qr{<div class="rich-text rich-text--right content-font--sans content-size--small"><p>Text sits beside a smaller image\. <em>Formatted</em></p></div>}, 'renders side-by-side rich text with alignment and typography');
like($post_html, qr{youtube-nocookie\.com/embed/abc123DEF45}, 'renders safe video embed');
like($post_html, qr/Embedded video caption/, 'renders video caption');
like($post_html, qr{<a class="link-card" href="https://example\.test/prints"><span>Link</span><strong>Print catalog</strong><p>Browse available editions\.</p></a>}, 'renders link card');
like($post_html, qr{<a class="resource-card" href="/assets/resources/c{64}\.pdf" download><span class="resource-card-badge">PDF</span><div><strong>Field Guide</strong><p>Download the public field guide\.</p><small>PDF document - resource-guide\.pdf - 28 B</small></div><span class="resource-card-action">Download PDF</span></a>}, 'renders public resource download card with file type metadata');
like($post_html, qr{<a class="social-link social-link--instagram" href="https://instagram\.com/desertarchive"><span class="social-icon" aria-hidden="true">.*?</span><strong>\@desertarchive</strong></a>}s, 'renders social link');
like($post_html, qr/<blockquote class="heading-align heading-align--right content-font--mono content-size--small"><p>The desert keeps its own archive\.<\/p><cite>Field note<\/cite><\/blockquote>/, 'renders quote block with alignment and typography');
like($post_html, qr/<hr>/, 'renders divider block');
like($post_html, qr{/tags/field-work/}, 'renders tag links');
like($post_html, qr{/collections/portfolio/}, 'renders collection links');
like($post_html, qr{<section class="post-share" aria-label="Share this post">}, 'post page renders social share section');
like($post_html, qr{https://www\.facebook\.com/sharer/sharer\.php\?u=https%3A%2F%2Fexample\.test%2Fcanonical-field-note%2F}, 'post share includes Facebook URL');
like($post_html, qr{https://twitter\.com/intent/tweet\?url=https%3A%2F%2Fexample\.test%2Fcanonical-field-note%2F&amp;text=Custom%20SEO%20Field%20Note}, 'post share includes X URL');
like($post_html, qr{mailto:\?subject=Custom%20SEO%20Field%20Note&amp;body=https%3A%2F%2Fexample\.test%2Fcanonical-field-note%2F}, 'post share includes email URL');
like($post_html, qr{data-comments data-rating data-content-id="$post->{id}"}, 'post page renders integrated comments and rating mount');
like($post_html, qr{/assets/comments\.js}, 'post page loads local comments script');

my $gallery_html = _read($gallery_path);
unlike($gallery_html, qr{data-comments}, 'page output does not render post comments');

my $posts_html = _read($posts_index_path);
like($posts_html, qr/first-field-note/, 'posts index links to post');
like($posts_html, qr/A short note/, 'posts index renders excerpt');

my $tag_html = _read($tag_index_path);
like($tag_html, qr/First Field Note/, 'tag archive lists post');

my $collection_html = _read($collection_index_path);
like($collection_html, qr/First Field Note/, 'collection archive lists post');

my $map_html = _read($map_path);
like($map_html, qr/data-desert-map/, 'map page renders interactive map mount');
like($map_html, qr/<h1>Locations<\/h1>/, 'map page uses generalized Locations title');
like($map_html, qr/service areas/, 'map page describes general location uses');
unlike($map_html, qr/stories/i, 'map page avoids story-specific copy');
like($map_html, qr{/assets/map\.js}, 'map page loads local map script');
like($map_html, qr{/assets/map-pins\.json}, 'map page references local pin data');
my $map_asset = _read($map_asset_path);
like($map_asset, qr/Open item/, 'map popup links use generic item language');
like($map_asset, qr/No mapped locations yet/, 'map empty state uses generic location language');
unlike($map_asset, qr/Open story|No mapped stories|stories in this area/, 'map script avoids story-specific copy');

my $map_data = decode_json(_read($map_data_path));
is(scalar @{$map_data->{pins}}, 1, 'map data includes one pinned item');
is($map_data->{pins}[0]{title}, 'First Field Note', 'map pin includes title');
is($map_data->{pins}[0]{label}, 'Desert wash', 'map pin includes location label');
is($map_data->{pins}[0]{kind}, 'service_area', 'map pin includes location kind');
is($map_data->{pins}[0]{kind_label}, 'Service area', 'map pin includes location kind label');
is($map_data->{pins}[0]{url}, '/posts/first-field-note/', 'map pin links to post');
is($map_data->{pins}[0]{image}, '/assets/media/' . ('b' x 64) . '.jpg', 'map pin includes preview image');
is(sprintf('%.6f', $map_data->{pins}[0]{lat}), '34.101234', 'map pin includes latitude');
is(sprintf('%.6f', $map_data->{pins}[0]{lng}), '-112.202345', 'map pin includes longitude');

my $sitemap_xml = _read($sitemap_path);
like($sitemap_xml, qr{<loc>http://localhost/posts/first-field-note/</loc>}, 'sitemap includes post');
like($sitemap_xml, qr{<loc>http://localhost/map/</loc>}, 'sitemap includes map page');
like($sitemap_xml, qr{<loc>http://localhost/gallery/framed-print/</loc>}, 'sitemap includes nested page');
like($sitemap_xml, qr{<loc>http://localhost/featured-story/</loc>}, 'sitemap includes internal reference page');
like($sitemap_xml, qr{<loc>http://localhost/tags/field-work/</loc>}, 'sitemap includes tag archive');
like($sitemap_xml, qr{<loc>http://localhost/collections/portfolio/</loc>}, 'sitemap includes collection archive');

my $robots_txt = _read($robots_path);
like($robots_txt, qr{Disallow: /admin/}, 'robots disallows admin');
like($robots_txt, qr{Sitemap: http://localhost/sitemap\.xml}, 'robots links sitemap');

my $redirect_conf = _read($redirect_conf_path);
like($redirect_conf, qr{location "/old-note"}, 'httpd include contains redirect source');
like($redirect_conf, qr{block return 301 "/posts/first-field-note/"}, 'httpd include contains redirect target');

my $redirect_html = _read($redirect_stub_path);
like($redirect_html, qr{url=/posts/first-field-note/}, 'static redirect fallback points to target');

my ($revision_count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM content_revisions');
ok($revision_count >= 5, 'save and publish create revisions');
my ($nav_snapshot) = $db->dbh->selectrow_array('SELECT show_in_nav FROM content_revisions WHERE content_id = ? ORDER BY id DESC LIMIT 1', undef, $gallery->{id});
is($nav_snapshot, 1, 'revision snapshots navigation flag');
my ($revision_tags) = $db->dbh->selectrow_array('SELECT tags_text FROM content_revisions WHERE content_id = ? ORDER BY id DESC LIMIT 1', undef, $post->{id});
like($revision_tags, qr/Field Work/, 'revision snapshots tags');
my ($revision_location) = $db->dbh->selectrow_array('SELECT location_label FROM content_revisions WHERE content_id = ? ORDER BY id DESC LIMIT 1', undef, $post->{id});
is($revision_location, 'Desert wash', 'revision snapshots location');

DesertCMS::Navigation::replace_from_text($config, $db, '');
$content->rebuild_all;
my $home_only_nav_html = _read($index_path);
like($home_only_nav_html, qr{href="/"}, 'empty manual navigation falls back to home');
like($home_only_nav_html, qr{href="/">Home</a>\s*<a href="http://localhost/shop">Shop / Catalog</a>}, 'fallback navigation keeps shop module after home');
unlike($home_only_nav_html, qr{href="/posts/"}, 'empty manual navigation does not add posts to nav');

my $blocked_parent_delete = eval { $content->delete_item(id => $gallery->{id}) };
ok(!$blocked_parent_delete, 'does not delete a page that still has child pages');
like($@, qr/delete child pages first/, 'parent delete error explains child-page blocker');

my $deleted_child = $content->delete_item(id => $child_page->{id});
ok($deleted_child->{deleted_at}, 'delete returns deleted timestamp for child page');
ok(!$content->get($child_page->{id}), 'deleted child page is hidden from content get');
ok(!-f $child_path, 'delete removes generated child page file');
ok(!(grep { $_->{id} == $child_page->{id} } @{$content->list_items(type => 'page')}), 'deleted page is hidden from admin page list');

my $deleted_post = $content->delete_item(id => $post->{id});
ok($deleted_post->{deleted_at}, 'delete returns deleted timestamp for post');
ok(!$content->get($post->{id}), 'deleted post is hidden from content get');
ok(!-f $post_path, 'delete removes generated post file');
ok(!(grep { $_->{id} == $post->{id} } @{$content->list_items(type => 'post')}), 'deleted post is hidden from admin post list');

my $deleted_sitemap = _read($sitemap_path);
unlike($deleted_sitemap, qr{<loc>http://localhost/posts/first-field-note/</loc>}, 'deleted post is removed from sitemap');
unlike($deleted_sitemap, qr{<loc>http://localhost/gallery/framed-print/</loc>}, 'deleted page is removed from sitemap');

my $map_after_delete = decode_json(_read($map_data_path));
is(scalar @{$map_after_delete->{pins}}, 0, 'deleted post is removed from map data');

done_testing;

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _media_derivatives_json {
    my ($checksum, $width, $height) = @_;
    my @sizes = (
        { label => 'w480', path => "/assets/media/$checksum-480.jpg", width => 480, height => int(480 * $height / $width) },
    );
    push @sizes, { label => 'w800', path => "/assets/media/$checksum-800.jpg", width => 800, height => int(800 * $height / $width) }
        if $width > 800;
    push @sizes, { label => 'display', path => "/assets/media/$checksum.jpg", width => $width, height => $height };
    return encode_json({ version => 1, sizes => \@sizes, aspect_ratio => sprintf('%.6f', $width / $height) });
}

sub _resource_derivatives_json {
    my ($path) = @_;
    return encode_json({
        version => 2,
        asset_kind => 'document',
        public_policy => 'public_resource_download',
        source_access => 'authenticated_admin_download',
        document => {
            type_label => 'PDF document',
            family => 'document',
            family_label => 'Document',
            extension => 'PDF',
            mime => 'application/pdf',
            bytes => 28,
            byte_label => '28 B',
            filename => 'resource-guide.pdf',
        },
        preview => {
            kind => 'document_card',
            label => 'PDF document',
            type_label => 'PDF document',
            family => 'document',
            family_label => 'Document',
            extension => 'PDF',
            mime => 'application/pdf',
            byte_label => '28 B',
            detail => 'Document - 28 B',
        },
        public_resource => {
            path => $path,
            mime => 'application/pdf',
            filename => 'resource-guide.pdf',
            extension => 'PDF',
            bytes => 28,
            label => 'PDF document',
            byte_label => '28 B',
        },
        bytes => 28,
    });
}
