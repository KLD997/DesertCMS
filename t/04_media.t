use strict;
use warnings;
use Test::More;
use File::Find;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use IO::Compress::Zip qw(zip $ZipError ZIP_CM_STORE);
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(encode_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Media;
use DesertCMS::Modules;
use DesertCMS::Settings;

my $repo = getcwd();
my ($image_tool, $tool_mode) = _find_image_tool($repo);
plan skip_all => 'Image tool not found' unless $image_tool;

$repo =~ s{\\}{/}g;
$image_tool =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/data");

my $source = File::Spec->catfile($root, 'sample.jpg');
my @sample_cmd = $tool_mode eq 'vips'
    ? (_sibling_command($image_tool, 'vips'), 'black', $source, 2400, 1200, '--bands', 3)
    : _image_tool_cmd($image_tool, $tool_mode, 'convert', '-size', '2400x1200', 'gradient:#eeeeee-#333333', $source);
system @sample_cmd;
is($?, 0, 'created sample image');
ok(-f $source, 'sample image exists');

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Media Test
site_url = http://localhost
contributor_site_id = dakota
contributor_domain = dakota.desertarchives.com
contributor_owner_name = Dakota Desert Archives
contributor_owner_email = dakota\@example.com
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
image_public_max_width = 800
image_public_quality = 80
image_tool = $image_tool
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
$db->dbh->do(
    q{
        INSERT INTO admin_users
            (id, username, email, password_hash, password_algo, created_at, updated_at)
        VALUES
            (42, 'dakota', 'dakota@example.com', 'hash', 'test', ?, ?)
    },
    undef,
    time,
    time
);

my $content = _read_binary($source);
my $media = DesertCMS::Media->new(config => $config, db => $db);
DesertCMS::Settings::set_many($config, $db, {
    contributor_media_upload_limit_mb => 1,
});
my $oversize_upload = eval {
    $media->store_upload(
        filename => 'oversize.txt',
        mime_type => 'text/plain',
        content => 'x' x (1024 * 1024 + 1),
        seo_title => 'Oversize',
        seo_description => 'This upload should be blocked by the plan limit.',
    );
    1;
};
ok(!$oversize_upload, 'plan upload limit rejects oversized source asset');
like($@, qr/current plan limit of 1\.0 MB/, 'oversized upload explains current plan limit');
DesertCMS::Settings::set_many($config, $db, {
    contributor_media_upload_limit_mb => 64,
});
my $asset = $media->store_upload(
    filename => 'sample.jpg',
    mime_type => 'image/jpeg',
    content => $content,
    alt_text => 'Sample desert gradient',
    seo_title => 'SEO desert asset',
    seo_description => 'A short searchable description for this desert media asset.',
    category_text => 'Portfolio',
    tags_text => "cactus, Sunset\ncactus",
    collections_text => 'Print Set | 2026 Series | Print Set',
    uploaded_by_user_id => 42,
    uploaded_by_username => 'dakota',
    uploaded_by_email => 'dakota@example.com',
);

ok($asset->{id}, 'stored media row');
is($asset->{alt_text}, 'Sample desert gradient', 'stores default alt text');
is($asset->{seo_title}, 'SEO desert asset', 'stores media search title');
is($asset->{seo_description}, 'A short searchable description for this desert media asset.', 'stores media search description');
is($asset->{category_text}, 'Portfolio', 'stores media category text');
is($asset->{tags_text}, 'cactus, Sunset', 'stores normalized media tags');
is($asset->{collections_text}, 'Print Set, 2026 Series', 'stores normalized media collections');
is(DesertCMS::Media::asset_kind($asset), 'image', 'identifies uploaded asset as an image');
is(DesertCMS::Media::asset_kind('application/pdf'), 'document', 'identifies document source assets for future pipeline expansion');
is(DesertCMS::Media::asset_kind('audio/mpeg'), 'audio', 'identifies audio source assets');
is(DesertCMS::Media::asset_kind('video/mp4'), 'video', 'identifies video source assets');
is(DesertCMS::Media::public_derivative_kind($asset), 'optimized_image', 'identifies public derivative strategy for image assets');
like($asset->{public_path}, qr{\A/assets/media/[0-9a-f]{64}\.jpg\z}, 'public derivative path format');
my $storage_path = $asset->{storage_path};
$storage_path =~ s{\\}{/}g;
ok(index($storage_path, $root . '/originals') == 0, 'original stored outside public root');
ok(index($storage_path, $root . '/public') != 0, 'original is not under public root');

my $public_file = File::Spec->catfile($root, 'public', split m{/}, substr($asset->{public_path}, 1));
ok(-f $public_file, 'public derivative exists');
ok(($asset->{width} || 9999) <= 800, 'derivative width capped');
ok(($asset->{height} || 9999) <= 800, 'derivative height capped');
my $derivatives = decode_json($asset->{derivatives_json} || '{}');
my @sizes = @{$derivatives->{sizes} || []};
ok(@sizes >= 2, 'stores responsive derivative metadata');
ok((grep { ($_->{path} || '') =~ m{/assets/media/[0-9a-f]{64}-480\.jpg\z} } @sizes), 'stores small responsive derivative');
ok((grep { ($_->{path} || '') eq $asset->{public_path} } @sizes), 'stores canonical display derivative in responsive metadata');
my @derivative_files = map {
    File::Spec->catfile($root, 'public', split m{/}, substr($_->{path}, 1))
} grep { ($_->{path} || '') =~ m{\A/assets/media/[0-9a-f]{64}(?:-[0-9]+)?\.jpg\z} } @sizes;
ok((grep { -f $_ } @derivative_files) == @derivative_files, 'all responsive public derivatives exist');
my $quality = $media->asset_quality(asset => $asset);
ok($quality->{ok}, 'media quality check passes with alt, search text, dimensions, and responsive sizes');
is($quality->{responsive_count}, scalar(@sizes), 'quality check counts responsive sizes');
is($asset->{owner_site_id}, 'dakota', 'stores contributor site id on upload');
is($asset->{owner_domain}, 'dakota.desertarchives.com', 'stores contributor domain on upload');
is($asset->{owner_display_name}, 'Dakota Desert Archives', 'stores contributor display name on upload');
is($asset->{owner_email}, 'dakota@example.com', 'stores contributor owner email on upload');
is($asset->{uploaded_by_user_id}, 42, 'stores uploader user id on upload');
is($asset->{uploaded_by_username}, 'dakota', 'stores uploader username on upload');

my ($rows) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM media_assets');
is($rows, 1, 'one media row inserted');

my $updated = $media->update_alt_text(id => $asset->{id}, alt_text => 'Updated accessible description');
is($updated->{alt_text}, 'Updated accessible description', 'updates default alt text');

my $search_updated = $media->update_search_text(
    id => $asset->{id},
    alt_text => 'Search accessible description',
    seo_title => 'Updated media search title',
    seo_description => 'Updated media search description.',
    category_text => 'Archive',
    tags_text => "negative; scanned\nfeatured",
    collections_text => 'Route 66 | Archive Box A | Route 66',
);
is($search_updated->{alt_text}, 'Search accessible description', 'updates media search alt text');
is($search_updated->{seo_title}, 'Updated media search title', 'updates media search title');
is($search_updated->{seo_description}, 'Updated media search description.', 'updates media search description');
is($search_updated->{category_text}, 'Archive', 'updates media category text');
is($search_updated->{tags_text}, 'negative, scanned, featured', 'updates normalized media tags');
is($search_updated->{collections_text}, 'Route 66, Archive Box A', 'updates normalized media collections');

my $ts = time;
$db->dbh->do(
    q{
        INSERT INTO content_items
            (type, title, slug, status, feature_image_path, body_json, created_at, updated_at)
        VALUES
            ('page', 'Uses Media', 'uses-media', 'draft', ?, '[]', ?, ?)
    },
    undef,
    $asset->{public_path},
    $ts,
    $ts
);
my $blocked_delete = eval {
    $media->delete_asset(id => $asset->{id});
    1;
};
ok(!$blocked_delete, 'does not delete media still used by content');
like($@, qr/used by 1 page or post/, 'delete error explains content reference');

$db->dbh->do('UPDATE content_items SET deleted_at = ? WHERE slug = ?', undef, time, 'uses-media');
$db->dbh->do(
    q{
        INSERT INTO shop_listings
            (media_asset_id, title, active, personal_enabled, personal_price_cents, created_at, updated_at)
        VALUES
            (?, 'Sale Asset', 1, 1, 1200, ?, ?)
    },
    undef,
    $asset->{id},
    time,
    time
);
my $deleted = $media->delete_asset(id => $asset->{id});
ok($deleted->{deleted_at}, 'delete returns deleted timestamp');
my ($visible_assets) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM media_assets WHERE deleted_at IS NULL');
is($visible_assets, 0, 'deleted media is hidden from active media list');
is(scalar @{$media->list_assets}, 0, 'deleted media is omitted from media list');

my $transparent_source = File::Spec->catfile($root, 'transparent-logo.png');
my @transparent_cmd = $tool_mode eq 'vips'
    ? (_sibling_command($image_tool, 'vips'), 'black', $transparent_source, 1200, 600, '--bands', 4)
    : _image_tool_cmd($image_tool, $tool_mode, 'convert', '-size', '1200x600', 'xc:none', $transparent_source);
system @transparent_cmd;
is($?, 0, 'created transparent PNG image');
ok(-f $transparent_source, 'transparent PNG source exists');
my $transparent_asset = $media->store_upload(
    filename => 'transparent-logo.png',
    mime_type => 'image/png',
    content => _read_binary($transparent_source),
    alt_text => 'Transparent logo',
    seo_title => 'Transparent campaign logo',
    seo_description => 'A transparent PNG used for module campaign artwork.',
);
like($transparent_asset->{public_path}, qr{\A/assets/media/[0-9a-f]{64}\.png\z}, 'transparent PNG keeps PNG public derivative');
ok(DesertCMS::Media::is_public_image_path($transparent_asset->{public_path}), 'transparent PNG derivative is accepted as public image');
my $transparent_public = File::Spec->catfile($root, 'public', split m{/}, substr($transparent_asset->{public_path}, 1));
ok(-f $transparent_public, 'transparent PNG public derivative exists');
open my $png_fh, '<:raw', $transparent_public or die "cannot read $transparent_public: $!";
read $png_fh, my $png_magic, 8;
close $png_fh;
is($png_magic, "\x89PNG\x0d\x0a\x1a\x0a", 'transparent public derivative is a PNG file');
my $transparent_derivatives = decode_json($transparent_asset->{derivatives_json} || '{}');
my @transparent_sizes = @{$transparent_derivatives->{sizes} || []};
ok((grep { ($_->{path} || '') =~ m{/assets/media/[0-9a-f]{64}-480\.png\z} } @transparent_sizes), 'transparent PNG stores PNG responsive derivative');
ok(!(grep { ($_->{path} || '') =~ /\.jpg\z/ } @transparent_sizes), 'transparent PNG responsive metadata does not point at flattened JPEGs');

my $legacy_hash = 'f' x 64;
my $legacy_old_path = "/assets/media/$legacy_hash.jpg";
my $legacy_new_path = "/assets/media/$legacy_hash.png";
my $legacy_source = File::Spec->catfile($root, 'legacy-transparent.png');
my @legacy_cmd = $tool_mode eq 'vips'
    ? (_sibling_command($image_tool, 'vips'), 'black', $legacy_source, 960, 480, '--bands', 4)
    : _image_tool_cmd($image_tool, $tool_mode, 'convert', '-size', '960x480', 'xc:none', $legacy_source);
system @legacy_cmd;
is($?, 0, 'created legacy transparent PNG source');
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
        VALUES
            (?, ?, ?, ?, ?, ?, 'image/png', 960, 480, ?, ?, ?, ?)
    },
    undef,
    'legacy-transparent.png',
    $legacy_source,
    $legacy_old_path,
    'Legacy transparent art',
    'Legacy transparent art',
    'A legacy transparent PNG flattened to JPG before repair.',
    -s $legacy_source,
    $legacy_hash,
    encode_json({
        sizes => [
            { label => 'w480', path => "/assets/media/$legacy_hash-480.jpg", width => 480, height => 240 },
            { label => 'display', path => $legacy_old_path, width => 960, height => 480 },
        ],
        aspect_ratio => '2.000000',
    }),
    time,
);
my $legacy_media_id = $db->dbh->sqlite_last_insert_rowid;
my $legacy_body_json = encode_json([{ type => 'image', src => $legacy_old_path, alt => 'Legacy transparent art' }]);
$db->dbh->do(
    q{
        INSERT INTO content_items
            (type, title, slug, status, feature_image_path, body_json, created_at, updated_at)
        VALUES
            ('page', 'Legacy Media Page', 'legacy-media-page', 'draft', ?, ?, ?, ?)
    },
    undef,
    $legacy_old_path,
    $legacy_body_json,
    time,
    time
);
$db->dbh->do(
    q{
        INSERT INTO page_templates
            (name, slug, body_json, created_at, updated_at)
        VALUES
            ('Legacy Media Template', 'legacy-media-template', ?, ?, ?)
    },
    undef,
    $legacy_body_json,
    time,
    time
);
$db->dbh->do(
    q{
        INSERT INTO builder_sections
            (name, slug, body_json, created_at, updated_at)
        VALUES
            ('Legacy Media Section', 'legacy-media-section', ?, ?, ?)
    },
    undef,
    $legacy_body_json,
    time,
    time
);
$db->dbh->do(
    q{
        INSERT INTO donation_campaigns
            (title, slug, status, image_path, created_at, updated_at)
        VALUES
            ('Legacy Campaign', 'legacy-campaign', 'draft', ?, ?, ?)
    },
    undef,
    $legacy_old_path,
    time,
    time
);
my $repair = $media->repair_public_image_formats;
is($repair->{checked}, 1, 'legacy public image repair finds flattened PNG row');
is($repair->{repaired}, 1, 'legacy public image repair regenerates PNG derivative');
is($repair->{failed}, 0, 'legacy public image repair has no failures');
ok($repair->{references_updated} >= 4, 'legacy public image repair updates stored public references');
my $legacy_repaired = $db->dbh->selectrow_hashref('SELECT * FROM media_assets WHERE id = ?', undef, $legacy_media_id);
is($legacy_repaired->{public_path}, $legacy_new_path, 'legacy public image repair updates media public path to PNG');
my $legacy_meta = decode_json($legacy_repaired->{derivatives_json} || '{}');
my @legacy_sizes = @{$legacy_meta->{sizes} || []};
ok((grep { ($_->{path} || '') eq "/assets/media/$legacy_hash-480.png" } @legacy_sizes), 'legacy public image repair writes PNG responsive derivative metadata');
ok(!(grep { ($_->{path} || '') =~ /\.jpg\z/ } @legacy_sizes), 'legacy public image repair removes flattened JPEG derivative metadata');
my $legacy_public = File::Spec->catfile($root, 'public', split m{/}, substr($legacy_new_path, 1));
ok(-f $legacy_public, 'legacy public image repair creates PNG public derivative');
my ($legacy_feature, $legacy_body) = $db->dbh->selectrow_array('SELECT feature_image_path, body_json FROM content_items WHERE slug = ?', undef, 'legacy-media-page');
is($legacy_feature, $legacy_new_path, 'legacy public image repair updates content feature image path');
like($legacy_body, qr{\Q$legacy_new_path\E}, 'legacy public image repair updates content body image source');
unlike($legacy_body, qr{\Q$legacy_old_path\E}, 'legacy public image repair removes old content body image source');
my ($legacy_template_body) = $db->dbh->selectrow_array('SELECT body_json FROM page_templates WHERE slug = ?', undef, 'legacy-media-template');
like($legacy_template_body, qr{\Q$legacy_new_path\E}, 'legacy public image repair updates page template image source');
my ($legacy_section_body) = $db->dbh->selectrow_array('SELECT body_json FROM builder_sections WHERE slug = ?', undef, 'legacy-media-section');
like($legacy_section_body, qr{\Q$legacy_new_path\E}, 'legacy public image repair updates builder section image source');
my ($legacy_campaign_image) = $db->dbh->selectrow_array('SELECT image_path FROM donation_campaigns WHERE slug = ?', undef, 'legacy-campaign');
is($legacy_campaign_image, $legacy_new_path, 'legacy public image repair updates donation campaign image path');
$db->dbh->do('UPDATE content_items SET deleted_at = ? WHERE slug = ?', undef, time, 'legacy-media-page');
$db->dbh->do('DELETE FROM page_templates WHERE slug = ?', undef, 'legacy-media-template');
$db->dbh->do('DELETE FROM builder_sections WHERE slug = ?', undef, 'legacy-media-section');
$db->dbh->do('DELETE FROM donation_campaigns WHERE slug = ?', undef, 'legacy-campaign');
ok($media->delete_asset(id => $legacy_media_id)->{deleted_at}, 'legacy repaired PNG test asset deletes cleanly');

ok($media->delete_asset(id => $transparent_asset->{id})->{deleted_at}, 'transparent PNG test asset deletes cleanly');

my ($listing_active, $personal_enabled) = $db->dbh->selectrow_array(
    'SELECT active, personal_enabled FROM shop_listings WHERE media_asset_id = ?',
    undef,
    $asset->{id}
);
is($listing_active, 0, 'delete deactivates shop listing');
is($personal_enabled, 0, 'delete disables shop listing rights');
ok(!-f $public_file, 'delete removes unused public derivative');
ok(!(grep { -f $_ } @derivative_files), 'delete removes unused responsive derivatives');
ok(!-f $storage_path, 'delete removes unused private source asset');

my $pdf_content = "%PDF-1.4\n1 0 obj\n<< /Title (DesertCMS PDF Field Guide) >>\nendobj\n2 0 obj\n<< /Length 64 >>\nstream\nBT (Public PDF body text for extracted preview.) Tj ET\nendstream\nendobj\n%%EOF\n";
my $doc_asset = $media->store_upload(
    filename => 'resource-guide.pdf',
    mime_type => 'application/pdf',
    content => $pdf_content,
    seo_title => 'Resource Guide',
    seo_description => 'A private resource document for admin download.',
    uploaded_by_user_id => 42,
    uploaded_by_username => 'dakota',
    uploaded_by_email => 'dakota@example.com',
);
ok($doc_asset->{id}, 'stored document media row');
is(DesertCMS::Media::asset_kind($doc_asset), 'document', 'identifies uploaded PDF as a document asset');
is($doc_asset->{public_path} || '', '', 'document asset has no public derivative path');
is(DesertCMS::Media::public_policy($doc_asset), 'private_source_only', 'document asset stays private-source only');
is(DesertCMS::Media::public_derivative_kind($doc_asset), '', 'document asset has no public derivative kind');
my $doc_storage_path = $doc_asset->{storage_path};
$doc_storage_path =~ s{\\}{/}g;
ok(index($doc_storage_path, $root . '/originals') == 0, 'document source is stored under private source root');
ok(index($doc_storage_path, $root . '/public') != 0, 'document source is not under public root');
ok(-f $doc_storage_path, 'private document source exists');
my $doc_meta = decode_json($doc_asset->{derivatives_json} || '{}');
is($doc_meta->{version}, 2, 'document derivative policy records enriched metadata version');
is($doc_meta->{public_policy}, 'private_source_only', 'document derivative policy records private source only');
is($doc_meta->{source_access}, 'authenticated_admin_download', 'document derivative policy records admin download access');
is($doc_meta->{preview}{kind}, 'document_card', 'document derivative policy records card preview strategy');
is($doc_meta->{preview}{type_label}, 'PDF document', 'document preview records type label');
is($doc_meta->{preview}{family_label}, 'Document', 'document preview records family label');
is($doc_meta->{preview}{byte_label}, length($pdf_content) . ' B', 'document preview records byte label');
is($doc_meta->{preview}{extraction_source}, 'pdf_literal_text', 'PDF preview records extraction source');
is($doc_meta->{preview}{extraction_status}, 'text_extracted', 'PDF preview records extracted text status');
is($doc_meta->{preview}{text_heading}, 'DesertCMS PDF Field Guide', 'PDF preview extracts metadata title as heading');
like($doc_meta->{preview}{snippet}, qr/Public PDF body text for extracted preview/, 'PDF preview extracts simple text stream snippet');
is($doc_meta->{private_preview}{kind}, 'pdf_page_thumbnail', 'PDF metadata records private thumbnail preview strategy');
ok(($doc_meta->{private_preview}{status} || '') =~ /\A(?:generated|unavailable)\z/, 'PDF thumbnail status is explicit');
is($doc_meta->{preview}{visual_preview_kind}, 'pdf_page_thumbnail', 'PDF card metadata exposes visual preview kind');
my $preview_job_summary = $media->preview_job_summary;
ok(exists $preview_job_summary->{candidates}, 'media preview job summary reports retry candidates');
my $preview_queue = $media->enqueue_private_preview_job(asset => $doc_asset, reason => 'test_retry');
ok($preview_queue->{queued} || ($preview_queue->{reason} || '') =~ /\A(?:private preview is already current|preview job is already queued)\z/, 'PDF preview can be queued for retry or reported current');
my $preview_processed = $media->process_private_preview_jobs(limit => 1);
ok(exists $preview_processed->{checked}, 'media preview job processor returns a checked count');
ok(exists $preview_processed->{done} && exists $preview_processed->{failed} && exists $preview_processed->{skipped}, 'media preview job processor reports outcomes');
if (($doc_meta->{private_preview}{status} || '') eq 'generated') {
    ok(-f $doc_meta->{private_preview}{path}, 'generated PDF thumbnail is stored privately');
    my $pdf_preview = $media->private_preview(id => $doc_asset->{id});
    is($pdf_preview->{mime}, 'image/jpeg', 'admin PDF thumbnail preview is served as an image');
}
is($doc_meta->{document}{filename}, 'resource-guide.pdf', 'document metadata records safe filename');
my $doc_quality = $media->asset_quality(asset => $doc_asset);
ok($doc_quality->{ok}, 'document quality check passes with search title and description');
is($doc_quality->{responsive_count}, 0, 'document quality does not require responsive image sizes');
my $download = $media->source_download(id => $doc_asset->{id});
is($download->{filename}, 'resource-guide.pdf', 'source download keeps safe original filename');
is($download->{mime}, 'application/pdf', 'source download keeps document MIME type');
is($download->{bytes}, length($pdf_content), 'source download reports source byte size');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        resource_publishing => 0,
    }),
    module_resource_publishing_enabled => 1,
});
my $blocked_publish = eval {
    $media->publish_resource(id => $doc_asset->{id});
    1;
};
ok(!$blocked_publish, 'plan-gated resource publishing blocks public resource copy');
like($@, qr/Resource publishing is not included in the current plan/, 'blocked resource publish explains plan entitlement');
DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        resource_publishing => 1,
    }),
});
my $published_doc = $media->publish_resource(id => $doc_asset->{id});
like($published_doc->{public_path}, qr{\A/assets/resources/[0-9a-f]{64}\.pdf\z}, 'published document receives a public resource path');
is(DesertCMS::Media::public_policy($published_doc), 'public_resource_download', 'published document policy records public resource download');
my $public_resource_file = File::Spec->catfile($root, 'public', split m{/}, substr($published_doc->{public_path}, 1));
ok(-f $public_resource_file, 'public resource file exists');
is(_read_binary($public_resource_file), $pdf_content, 'public resource copy matches private source content');
ok(-f $doc_storage_path, 'publishing does not remove private document source');
my $published_meta = decode_json($published_doc->{derivatives_json} || '{}');
is($published_meta->{public_policy}, 'public_resource_download', 'published derivative policy records public resource download');
is($published_meta->{public_resource}{path}, $published_doc->{public_path}, 'published derivative policy stores public resource path');
is($published_meta->{public_resource}{filename}, 'resource-guide.pdf', 'published derivative policy stores visitor filename');
is($published_meta->{public_resource}{mime}, 'application/pdf', 'published derivative policy stores resource MIME');
is($published_meta->{public_resource}{label}, 'PDF document', 'published derivative policy stores visitor resource label');
is($published_meta->{public_resource}{byte_label}, length($pdf_content) . ' B', 'published derivative policy stores visitor byte label');
my $published_quality = $media->asset_quality(asset => $published_doc);
ok($published_quality->{ok}, 'published resource quality still passes');
is($published_quality->{public_policy}, 'public_resource_download', 'quality reports public resource policy');

my $resource_body = encode_json([
    {
        type => 'resource',
        src => $published_doc->{public_path},
        label => 'Public Resource Guide',
        description => 'Download the public guide.',
        button_label => 'Download PDF',
    }
]);
$db->dbh->do(
    q{
        INSERT INTO content_items
            (type, title, slug, status, feature_image_path, body_json, created_at, updated_at)
        VALUES
            ('page', 'Uses Resource', 'uses-resource', 'draft', '', ?, ?, ?)
    },
    undef,
    $resource_body,
    time,
    time
);
my $resource_usage = $media->usage_for_asset(asset => $published_doc);
is($resource_usage->{content_count}, 1, 'published resource usage counts page/post references');
my $blocked_resource_unpublish = eval {
    $media->unpublish_resource(id => $published_doc->{id});
    1;
};
ok(!$blocked_resource_unpublish, 'does not unpublish a public resource still used by content');
like($@, qr/used by 1 page or post/, 'unpublish error explains content reference');

$db->dbh->do('UPDATE content_items SET deleted_at = ? WHERE slug = ?', undef, time, 'uses-resource');
my $unpublished_doc = $media->unpublish_resource(id => $published_doc->{id});
is($unpublished_doc->{public_path} || '', '', 'unpublished resource clears public path');
is(DesertCMS::Media::public_policy($unpublished_doc), 'private_source_only', 'unpublished resource returns to private-source policy');
ok(!-f $public_resource_file, 'unpublish removes the public resource file');
ok(-f $doc_storage_path, 'unpublish keeps the private source file');

my $audio_content = "ID3\x03\x00\x00audio fixture";
my $audio_asset = $media->store_upload(
    filename => 'field-interview.mp3',
    mime_type => 'audio/mpeg',
    content => $audio_content,
    seo_title => 'Field Interview',
    seo_description => 'A private audio source asset for oral history.',
);
ok($audio_asset->{id}, 'stored audio media row');
is(DesertCMS::Media::asset_kind($audio_asset), 'audio', 'identifies uploaded MP3 as audio');
is($audio_asset->{public_path} || '', '', 'audio asset stays private by default');
my $audio_storage_path = $audio_asset->{storage_path};
$audio_storage_path =~ s{\\}{/}g;
ok(index($audio_storage_path, $root . '/originals') == 0, 'audio source is stored under private source root');
my $audio_meta = decode_json($audio_asset->{derivatives_json} || '{}');
is($audio_meta->{asset_kind}, 'audio', 'audio metadata records asset kind');
is($audio_meta->{preview}{type_label}, 'MP3 audio', 'audio preview records type label');
is($audio_meta->{preview}{family_label}, 'Audio', 'audio preview records family label');
is($audio_meta->{private_preview}{kind}, 'audio_metadata', 'audio preview records metadata strategy');
is($audio_meta->{private_preview}{status}, 'metadata', 'audio preview records metadata-only status');
is($audio_meta->{preview}{technical_label}, 'MP3 audio metadata', 'audio preview exposes technical metadata label');
is($audio_meta->{document}{filename}, 'field-interview.mp3', 'audio metadata records safe filename');
my $audio_preview_dir = File::Spec->catdir($root, 'originals', 'previews', 'test');
make_path($audio_preview_dir);
my $audio_preview_path = File::Spec->catfile($audio_preview_dir, 'audio-preview.jpg');
_write_binary($audio_preview_path, "\xff\xd8\xff\xd9");
$audio_meta->{private_preview} = {
    kind   => 'audio_waveform',
    status => 'generated',
    label  => 'Audio waveform',
    detail => 'Generated test preview.',
    path   => $audio_preview_path,
    mime   => 'image/jpeg',
};
$db->dbh->do(
    'UPDATE media_assets SET derivatives_json = ? WHERE id = ?',
    undef,
    encode_json($audio_meta),
    $audio_asset->{id}
);
my $audio_admin_preview = $media->private_preview(id => $audio_asset->{id});
is($audio_admin_preview->{mime}, 'image/jpeg', 'admin private preview returns displayable image MIME');
is($audio_admin_preview->{path}, $audio_preview_path, 'admin private preview uses private preview path');
my $published_audio = $media->publish_resource(id => $audio_asset->{id});
like($published_audio->{public_path}, qr{\A/assets/resources/[0-9a-f]{64}\.mp3\z}, 'published audio receives a public resource path');
my $public_audio_file = File::Spec->catfile($root, 'public', split m{/}, substr($published_audio->{public_path}, 1));
ok(-f $public_audio_file, 'public audio resource file exists');
is(_read_binary($public_audio_file), $audio_content, 'public audio resource copy matches private source content');
my $published_audio_meta = decode_json($published_audio->{derivatives_json} || '{}');
is($published_audio_meta->{public_resource}{label}, 'MP3 audio', 'published audio stores visitor resource label');
is($published_audio_meta->{private_preview}{kind}, 'audio_waveform', 'publishing preserves private preview metadata');
my $unpublished_audio = $media->unpublish_resource(id => $published_audio->{id});
is($unpublished_audio->{public_path} || '', '', 'unpublished audio resource clears public path');
ok(!-f $public_audio_file, 'unpublish removes the public audio resource file');
ok($media->delete_asset(id => $audio_asset->{id})->{deleted_at}, 'audio delete returns deleted timestamp');
ok(!-f $audio_storage_path, 'audio delete removes unused private source asset');
ok(!-f $audio_preview_path, 'audio delete removes unused private preview artifact');

my $video_content = "\x00\x00\x00\x18ftypmp42video fixture";
my $video_asset = $media->store_upload(
    filename => 'studio-tour.mp4',
    mime_type => 'video/mp4',
    content => $video_content,
    seo_title => 'Studio Tour',
    seo_description => 'A private video source asset.',
);
ok($video_asset->{id}, 'stored video media row');
is(DesertCMS::Media::asset_kind($video_asset), 'video', 'identifies uploaded MP4 as video');
is($video_asset->{public_path} || '', '', 'video asset stays private by default');
my $video_meta = decode_json($video_asset->{derivatives_json} || '{}');
is($video_meta->{asset_kind}, 'video', 'video metadata records asset kind');
is($video_meta->{preview}{type_label}, 'MP4 video', 'video preview records type label');
is($video_meta->{preview}{family_label}, 'Video', 'video preview records family label');
is($video_meta->{private_preview}{kind}, 'video_poster', 'video metadata records private poster strategy');
ok(($video_meta->{private_preview}{status} || '') =~ /\A(?:generated|unavailable)\z/, 'video poster status is explicit');
is($video_meta->{preview}{visual_preview_kind}, 'video_poster', 'video card metadata exposes visual preview kind');
ok($media->delete_asset(id => $video_asset->{id})->{deleted_at}, 'video delete returns deleted timestamp');

my $bad_upload = eval {
    $media->store_upload(
        filename => 'script.html',
        mime_type => 'text/html',
        content => '<script>alert(1)</script>',
    );
    1;
};
ok(!$bad_upload, 'rejects unsupported document-like upload types');

my $deleted_doc = $media->delete_asset(id => $doc_asset->{id});
ok($deleted_doc->{deleted_at}, 'document delete returns deleted timestamp');
ok(!-f $doc_storage_path, 'document delete removes unused private source asset');
ok(!($doc_meta->{private_preview}{path} || '') || !-f $doc_meta->{private_preview}{path}, 'document delete removes generated private preview artifact when present');
is(scalar @{$media->list_assets}, 0, 'deleted document is omitted from media list');

my $markdown_content = "# Field Notes\n\nA safe public-facing preview line.\nSecond line.\n";
my $markdown_asset = $media->store_upload(
    filename => 'field-notes.md',
    mime_type => 'text/markdown',
    content => $markdown_content,
    seo_title => 'Field Notes',
    seo_description => 'A private markdown resource with preview metadata.',
);
my $markdown_meta = decode_json($markdown_asset->{derivatives_json} || '{}');
is($markdown_meta->{document}{family}, 'text', 'markdown metadata records text family');
is($markdown_meta->{preview}{text_heading}, 'Field Notes', 'markdown preview extracts first heading');
like($markdown_meta->{preview}{snippet}, qr/Safe public-facing preview line/i, 'markdown preview stores a safe text snippet');
ok(int($markdown_meta->{preview}{line_count} || 0) >= 3, 'markdown preview records line count');
my $deleted_markdown = $media->delete_asset(id => $markdown_asset->{id});
ok($deleted_markdown->{deleted_at}, 'markdown document delete returns deleted timestamp');

my $docx_asset = $media->store_upload(
    filename => 'office-field-guide.docx',
    mime_type => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    content => _zip_member(
        'word/document.xml',
        '<w:document><w:body><w:p><w:r><w:t>Office Field Guide</w:t></w:r></w:p><w:p><w:r><w:t>Mesa notes from a Word document.</w:t></w:r></w:p></w:body></w:document>'
    ),
    seo_title => 'Office Field Guide',
    seo_description => 'A private Word resource with extracted preview text.',
);
my $docx_meta = decode_json($docx_asset->{derivatives_json} || '{}');
is($docx_meta->{document}{family}, 'document', 'docx metadata records document family');
is($docx_meta->{preview}{extraction_source}, 'office_open_xml', 'docx preview records Office extraction source');
is($docx_meta->{preview}{extraction_status}, 'text_extracted', 'docx preview records extracted text status');
is($docx_meta->{preview}{text_heading}, 'Office Field Guide', 'docx preview extracts first paragraph heading');
like($docx_meta->{preview}{snippet}, qr/Mesa notes from a Word document/, 'docx preview extracts document text snippet');
ok($media->delete_asset(id => $docx_asset->{id})->{deleted_at}, 'docx document delete returns deleted timestamp');

my $xlsx_asset = $media->store_upload(
    filename => 'archive-budget.xlsx',
    mime_type => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    content => _zip_member(
        'xl/sharedStrings.xml',
        '<sst><si><t>Archive Budget</t></si><si><t>Equipment costs and storage estimates</t></si></sst>'
    ),
    seo_title => 'Archive Budget',
    seo_description => 'A private spreadsheet resource with extracted preview text.',
);
my $xlsx_meta = decode_json($xlsx_asset->{derivatives_json} || '{}');
is($xlsx_meta->{document}{family}, 'spreadsheet', 'xlsx metadata records spreadsheet family');
is($xlsx_meta->{preview}{text_heading}, 'Archive Budget', 'xlsx preview extracts first shared string heading');
like($xlsx_meta->{preview}{snippet}, qr/Equipment costs and storage estimates/, 'xlsx preview extracts shared string snippet');
ok($media->delete_asset(id => $xlsx_asset->{id})->{deleted_at}, 'xlsx document delete returns deleted timestamp');

my $pptx_asset = $media->store_upload(
    filename => 'community-talk.pptx',
    mime_type => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    content => _zip_member(
        'ppt/slides/slide1.xml',
        '<p:sld><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Community Talk</a:t></a:r></a:p><a:p><a:r><a:t>Slides about the local archive plan.</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
    ),
    seo_title => 'Community Talk',
    seo_description => 'A private presentation resource with extracted preview text.',
);
my $pptx_meta = decode_json($pptx_asset->{derivatives_json} || '{}');
is($pptx_meta->{document}{family}, 'presentation', 'pptx metadata records presentation family');
is($pptx_meta->{preview}{text_heading}, 'Community Talk', 'pptx preview extracts slide heading');
like($pptx_meta->{preview}{snippet}, qr/local archive plan/, 'pptx preview extracts slide text snippet');
ok($media->delete_asset(id => $pptx_asset->{id})->{deleted_at}, 'pptx document delete returns deleted timestamp');

make_path("$root/public/assets/resources", "$root/public/assets/media");
my $orphan_resource_path = "$root/public/assets/resources/" . ('d' x 64) . ".pdf";
_write_binary($orphan_resource_path, "orphan public resource\n");
my $stale_derivative_path = "$root/public/assets/media/" . ('e' x 64) . "-480.jpg";
_write_binary($stale_derivative_path, "stale generated derivative\n");

my $missing_source_path = "$root/originals/missing-source.pdf";
my $large_unused_path = "$root/originals/large-unused.pdf";
my $old_unused_path = "$root/originals/old-unused.txt";
my $old_used_resource_source_path = "$root/originals/old-used-resource.pdf";
my $old_used_resource_public_rel = '/assets/resources/' . ('9' x 64) . '.pdf';
my $old_used_resource_public_path = File::Spec->catfile($root, 'public', split m{/}, substr($old_used_resource_public_rel, 1));
_write_binary($large_unused_path, 'x' x 2048);
_write_binary($old_unused_path, 'old unused private source asset');
_write_binary($old_used_resource_source_path, 'old used resource private source');
_write_binary($old_used_resource_public_path, 'old used public resource');
my $large_unused_checksum = 'f' x 64;
my $now = time;
my $old_created_at = $now - (120 * 86400);
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             owner_site_id, owner_domain, owner_display_name, owner_email,
             uploaded_by_username, uploaded_by_email, mime_type, width, height, bytes,
             checksum_sha256, derivatives_json, created_at)
        VALUES
            ('missing-source.pdf', ?, '', '', 'Missing Source', 'Lifecycle test missing source',
             'dakota', 'dakota.desertarchives.com', 'Dakota Desert Archives', 'dakota@example.com',
             'dakota', 'dakota@example.com', 'application/pdf', NULL, NULL, 512,
             ?, ?, ?)
    },
    undef,
    $missing_source_path,
    'a' x 64,
    encode_json({ version => 2, public_policy => 'private_source_only' }),
    $now
);
my $missing_source_id = $db->dbh->sqlite_last_insert_rowid;
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             owner_site_id, owner_domain, owner_display_name, owner_email,
             uploaded_by_username, uploaded_by_email, mime_type, width, height, bytes,
             checksum_sha256, derivatives_json, created_at)
        VALUES
            ('large-unused.pdf', ?, '', '', 'Large Unused', 'Lifecycle test large unused',
             'dakota', 'dakota.desertarchives.com', 'Dakota Desert Archives', 'dakota@example.com',
             'dakota', 'dakota@example.com', 'application/pdf', NULL, NULL, 2048,
             ?, ?, ?)
    },
    undef,
    $large_unused_path,
    $large_unused_checksum,
    encode_json({ version => 2, public_policy => 'private_source_only' }),
    $now
);
my $large_unused_id = $db->dbh->sqlite_last_insert_rowid;
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             owner_site_id, owner_domain, owner_display_name, owner_email,
             uploaded_by_username, uploaded_by_email, mime_type, width, height, bytes,
             checksum_sha256, derivatives_json, created_at)
        VALUES
            ('old-unused.txt', ?, '', '', 'Old Unused', 'Retention test old unused private source',
             'dakota', 'dakota.desertarchives.com', 'Dakota Desert Archives', 'dakota@example.com',
             'dakota', 'dakota@example.com', 'text/plain', NULL, NULL, 31,
             ?, ?, ?)
    },
    undef,
    $old_unused_path,
    '8' x 64,
    encode_json({ version => 2, public_policy => 'private_source_only' }),
    $old_created_at
);
my $old_unused_id = $db->dbh->sqlite_last_insert_rowid;
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             owner_site_id, owner_domain, owner_display_name, owner_email,
             uploaded_by_username, uploaded_by_email, mime_type, width, height, bytes,
             checksum_sha256, derivatives_json, created_at)
        VALUES
            ('old-used-resource.pdf', ?, ?, '', 'Old Used Resource', 'Retention test old used public resource',
             'dakota', 'dakota.desertarchives.com', 'Dakota Desert Archives', 'dakota@example.com',
             'dakota', 'dakota@example.com', 'application/pdf', NULL, NULL, 32,
             ?, ?, ?)
    },
    undef,
    $old_used_resource_source_path,
    $old_used_resource_public_rel,
    '9' x 64,
    encode_json({ version => 2, public_policy => 'public_resource_download' }),
    $old_created_at
);
my $old_used_resource_id = $db->dbh->sqlite_last_insert_rowid;
$db->dbh->do(
    q{
        INSERT INTO content_items
            (type, title, slug, status, feature_image_path, body_json, created_at, updated_at)
        VALUES
            ('page', 'Uses Old Resource', 'uses-old-resource', 'draft', '', ?, ?, ?)
    },
    undef,
    encode_json([{ type => 'resource', src => $old_used_resource_public_rel }]),
    $now,
    $now
);

my $lifecycle = $media->lifecycle_audit(large_min_bytes => 1024, retention_days => 90);
is($lifecycle->{summary}{missing_sources_count}, 1, 'lifecycle audit reports missing private source files');
is($lifecycle->{missing_sources}[0]{id}, $missing_source_id, 'missing source audit identifies the affected media row');
is($lifecycle->{summary}{orphaned_resources_count}, 1, 'lifecycle audit reports orphaned public resource files');
is($lifecycle->{orphaned_resources}[0]{rel}, '/assets/resources/' . ('d' x 64) . '.pdf', 'orphaned resource audit reports public resource path');
is($lifecycle->{summary}{stale_derivatives_count}, 1, 'lifecycle audit reports stale generated derivatives');
is($lifecycle->{stale_derivatives}[0]{rel}, '/assets/media/' . ('e' x 64) . '-480.jpg', 'stale derivative audit reports public derivative path');
is($lifecycle->{summary}{large_unused_count}, 1, 'lifecycle audit reports large unused media');
is($lifecycle->{large_unused}[0]{id}, $large_unused_id, 'large unused audit identifies the affected media row');
is($lifecycle->{summary}{retention_unused_count}, 1, 'lifecycle audit reports old unused retention candidates');
is($lifecycle->{retention_unused}[0]{id}, $old_unused_id, 'retention audit identifies the old unused private source');
is($lifecycle->{summary}{retention_days}, 90, 'retention audit records selected retention window');

my $resource_cleanup = $media->cleanup_lifecycle(action => 'remove_orphaned_resources', large_min_bytes => 1024);
is($resource_cleanup->{changed}, 1, 'lifecycle cleanup removes orphaned public resource file');
ok(!-f $orphan_resource_path, 'orphaned public resource file is removed from disk');
my $derivative_cleanup = $media->cleanup_lifecycle(action => 'remove_stale_derivatives', large_min_bytes => 1024);
is($derivative_cleanup->{changed}, 1, 'lifecycle cleanup removes stale public derivative file');
ok(!-f $stale_derivative_path, 'stale public derivative file is removed from disk');
my $unused_cleanup = $media->cleanup_lifecycle(action => 'delete_large_unused', large_min_bytes => 1024);
is($unused_cleanup->{changed}, 1, 'lifecycle cleanup deletes large unused media through media delete path');
ok(!-f $large_unused_path, 'large unused private source file is removed from disk');
my ($large_unused_visible) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM media_assets WHERE id = ? AND deleted_at IS NULL', undef, $large_unused_id);
is($large_unused_visible, 0, 'large unused media row is no longer active after cleanup');
my $retention_cleanup = $media->cleanup_lifecycle(action => 'archive_old_unused', large_min_bytes => 1024, retention_days => 90);
is($retention_cleanup->{changed}, 1, 'retention cleanup archives and deletes old unused media');
ok(-f $retention_cleanup->{archive_path}, 'retention cleanup creates a private archive');
like(_tar_list($config, $retention_cleanup->{archive_path}), qr{(?:^|\n)(?:\./)?sources/$old_unused_id-old-unused\.txt(?:\n|\z)}, 'retention archive includes the private source asset');
ok(!-f $old_unused_path, 'retention cleanup removes old unused private source after archiving');
my ($old_unused_visible) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM media_assets WHERE id = ? AND deleted_at IS NULL', undef, $old_unused_id);
is($old_unused_visible, 0, 'old unused media row is no longer active after retention cleanup');
my ($old_used_resource_visible) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM media_assets WHERE id = ? AND deleted_at IS NULL', undef, $old_used_resource_id);
is($old_used_resource_visible, 1, 'used public resource is not removed by retention cleanup');
ok(-f $old_used_resource_public_path, 'used public resource file remains published after retention cleanup');
my $post_cleanup_lifecycle = $media->lifecycle_audit(large_min_bytes => 1024, retention_days => 90);
is($post_cleanup_lifecycle->{summary}{orphaned_resources_count}, 0, 'orphaned resources stay clean after cleanup');
is($post_cleanup_lifecycle->{summary}{stale_derivatives_count}, 0, 'stale derivatives stay clean after cleanup');
is($post_cleanup_lifecycle->{summary}{large_unused_count}, 0, 'large unused assets stay clean after cleanup');
is($post_cleanup_lifecycle->{summary}{retention_unused_count}, 0, 'retention candidates stay clean after archive-first cleanup');
is($post_cleanup_lifecycle->{summary}{missing_sources_count}, 1, 'missing source remains report-only after cleanup actions');
is($post_cleanup_lifecycle->{missing_sources}[0]{id}, $missing_source_id, 'report-only missing source row remains visible for review');

my @filter_assets = (
    {
        id => 101,
        original_name => 'sunset-print.jpg',
        alt_text => 'Alt text for a cactus bloom image',
        seo_title => 'Sunset Print',
        seo_description => 'Warm image from the west ridge.',
        category_text => 'Portfolio',
        tags_text => 'sunset, cyanotype',
        collections_text => 'West Ridge',
        mime_type => 'image/jpeg',
        public_path => '/assets/media/' . ('1' x 64) . '.jpg',
        derivatives_json => encode_json({ sizes => [] }),
    },
    {
        id => 102,
        original_name => 'zoning-permit.pdf',
        alt_text => 'Internal source note',
        seo_title => 'Permit Packet',
        seo_description => 'Local archive planning document.',
        category_text => 'Archive',
        tags_text => 'zoning, variance',
        collections_text => 'Permit Box',
        mime_type => 'application/pdf',
        public_path => '',
        derivatives_json => encode_json({
            preview => {
                type_label => 'PDF document',
                family_label => 'Document',
                snippet => 'Variance request for archive storage.',
            },
            document => {
                filename => 'zoning-permit.pdf',
                type_label => 'PDF document',
            },
        }),
    },
    {
        id => 103,
        original_name => 'rainfall.csv',
        alt_text => '',
        seo_title => 'Rainfall Table',
        seo_description => 'Annual wash readings.',
        category_text => 'Data',
        tags_text => 'rainfall, csv',
        collections_text => 'Field Tables',
        mime_type => 'application/pdf',
        public_path => '/assets/resources/' . ('2' x 64) . '.pdf',
        derivatives_json => encode_json({
            preview => {
                type_label => 'CSV data file',
                family_label => 'Data',
                snippet => 'Annual rainfall totals and wash readings.',
            },
            public_resource => {
                filename => 'rainfall.csv',
                label => 'CSV data file',
                extension => 'CSV',
            },
        }),
    },
    {
        id => 104,
        original_name => 'oral-history.mp3',
        alt_text => 'Interview source note',
        seo_title => 'Oral History',
        seo_description => 'Recorded interview about studio setup.',
        category_text => 'Audio',
        tags_text => 'interview, oral history',
        collections_text => 'Oral Histories',
        mime_type => 'audio/mpeg',
        public_path => '',
        derivatives_json => encode_json({
            preview => {
                type_label => 'MP3 audio',
                family_label => 'Audio',
            },
        }),
    },
    {
        id => 105,
        original_name => 'studio-tour.mp4',
        alt_text => '',
        seo_title => 'Studio Tour',
        seo_description => 'Private video walkthrough.',
        category_text => 'Video',
        tags_text => 'walkthrough, tour',
        collections_text => 'Studio Tours',
        mime_type => 'video/mp4',
        public_path => '',
        derivatives_json => encode_json({
            preview => {
                type_label => 'MP4 video',
                family_label => 'Video',
            },
        }),
    },
);
my %filter_usage = (
    101 => { content_count => 1, shop_listing_count => 0, shop_order_count => 0 },
    102 => { content_count => 0, shop_listing_count => 0, shop_order_count => 0 },
    103 => { content_count => 0, shop_listing_count => 0, shop_order_count => 0 },
    104 => { content_count => 0, shop_listing_count => 0, shop_order_count => 0 },
    105 => { content_count => 0, shop_listing_count => 0, shop_order_count => 0 },
);
my $filter_counts = DesertCMS::Media::library_filter_counts(\@filter_assets, \%filter_usage);
is($filter_counts->{all}, 5, 'media library counts all assets');
is($filter_counts->{images}, 1, 'media library counts image assets');
is($filter_counts->{documents}, 2, 'media library counts document/resource assets');
is($filter_counts->{audio}, 1, 'media library counts audio assets');
is($filter_counts->{video}, 1, 'media library counts video assets');
is($filter_counts->{resources}, 1, 'media library counts public resources');
is($filter_counts->{unused}, 4, 'media library counts unused assets');
is($filter_counts->{published}, 2, 'media library counts public derivative and resource assets');
is($filter_counts->{private}, 3, 'media library counts private-source-only assets');
is(DesertCMS::Media::library_filter_key('../../bad'), 'all', 'unknown media library filters fall back to all');
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_filter_assets(\@filter_assets, 'documents', \%filter_usage) } ],
    [ 102, 103 ],
    'media library document filter returns documents and resource files'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_filter_assets(\@filter_assets, 'resources', \%filter_usage) } ],
    [ 103 ],
    'media library resource filter returns public resources'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_filter_assets(\@filter_assets, 'audio', \%filter_usage) } ],
    [ 104 ],
    'media library audio filter returns audio assets'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_filter_assets(\@filter_assets, 'video', \%filter_usage) } ],
    [ 105 ],
    'media library video filter returns video assets'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_filter_assets(\@filter_assets, 'unused', \%filter_usage) } ],
    [ 102, 103, 104, 105 ],
    'media library unused filter excludes referenced assets'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_filter_assets(\@filter_assets, 'private', \%filter_usage) } ],
    [ 102, 104, 105 ],
    'media library private-source filter returns private assets'
);
is(DesertCMS::Media::library_search_query("  cactus\tbloom\n"), 'cactus bloom', 'media library search query normalizes whitespace');
is_deeply(
    [ DesertCMS::Media::media_organization_terms("Field Tables | Permit Box, field tables") ],
    [ 'Field Tables', 'Permit Box', 'field tables' ],
    'media organization terms split comma, pipe, and newline separators'
);
is_deeply(
    DesertCMS::Media::library_organization_terms(\@filter_assets, 'category_text'),
    [ 'Archive', 'Audio', 'Data', 'Portfolio', 'Video' ],
    'media library derives category filter choices'
);
is_deeply(
    DesertCMS::Media::library_organization_terms(\@filter_assets, 'collections_text'),
    [ 'Field Tables', 'Oral Histories', 'Permit Box', 'Studio Tours', 'West Ridge' ],
    'media library derives collection filter choices'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_filter_organization_assets(\@filter_assets, category => 'Archive') } ],
    [ 102 ],
    'media library filters assets by category'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_filter_organization_assets(\@filter_assets, collection => 'oral histories') } ],
    [ 104 ],
    'media library filters assets by collection case-insensitively'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_filter_organization_assets(\@filter_assets, category => 'Data', collection => 'Field Tables') } ],
    [ 103 ],
    'media library combines category and collection filters'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_search_assets(\@filter_assets, 'sunset') } ],
    [ 101 ],
    'media library search matches media search title'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_search_assets(\@filter_assets, 'west ridge') } ],
    [ 101 ],
    'media library search matches media search description with multiple terms'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_search_assets(\@filter_assets, 'zoning permit') } ],
    [ 102 ],
    'media library search matches original filenames'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_search_assets(\@filter_assets, 'variance archive') } ],
    [ 102 ],
    'media library search matches stored document snippets'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_search_assets(\@filter_assets, 'csv rainfall') } ],
    [ 103 ],
    'media library search matches type metadata and snippets'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_search_assets(\@filter_assets, 'mp3 interview') } ],
    [ 104 ],
    'media library search matches audio type metadata'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_search_assets(\@filter_assets, 'mp4 walkthrough') } ],
    [ 105 ],
    'media library search matches video type metadata'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_search_assets(\@filter_assets, 'cyanotype') } ],
    [ 101 ],
    'media library search matches media tags'
);
is_deeply(
    [ map { $_->{id} } @{ DesertCMS::Media::library_search_assets(\@filter_assets, 'permit box') } ],
    [ 102 ],
    'media library search matches media collections'
);

my $relative_thumb = DesertCMS::Media::_sibling_command('vips', 'vipsthumbnail');
ok($relative_thumb eq 'vipsthumbnail' || $relative_thumb =~ m{(?:^|[\\/])vipsthumbnail(?:\.exe)?\z}, 'relative vips helper resolves to an executable name or path');
_openbsd_sandbox_media_check($config_path, $source) if $^O eq 'openbsd' && $tool_mode eq 'vips';

done_testing;

sub _read_binary {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _write_binary {
    my ($path, $body) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _tar_list {
    my ($config, $archive) = @_;
    my $tar = $config->get('tar_tool') || 'tar';
    open my $pipe, '-|', $tar, '-tzf', $archive
        or die "cannot list retention archive: $!";
    local $/;
    my $out = <$pipe>;
    close $pipe;
    die "retention archive list failed" if $? != 0;
    return $out || '';
}

sub _zip_member {
    my ($name, $body) = @_;
    my $zip = '';
    zip(\$body => \$zip, Name => $name, Method => ZIP_CM_STORE) or die "zip fixture failed: $ZipError";
    return $zip;
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

sub _openbsd_sandbox_media_check {
    my ($config_path, $source_path) = @_;
    my $code = <<'PERL';
use strict;
use warnings;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Media;
use DesertCMS::Security qw(apply_openbsd_sandbox);
my ($config_path, $source_path) = @ARGV;
my $config = DesertCMS::Config->load($config_path);
$config->{image_tool} = 'vips';
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
open my $fh, '<:raw', $source_path or die "cannot read source image: $!";
local $/;
my $content = <$fh>;
close $fh;
apply_openbsd_sandbox($config);
my $media = DesertCMS::Media->new(config => $config, db => $db);
$media->store_upload(filename => 'sandbox.jpg', mime_type => 'image/jpeg', content => $content, alt_text => 'Sandbox check');
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
    is($status, 0, 'media derivative processing works after OpenBSD pledge/unveil with relative vips config');
}
