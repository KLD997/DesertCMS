use strict;
use warnings;
use Test::More;
use File::Spec;

use FindBin;

my $root = File::Spec->catdir($FindBin::Bin, '..');
my $app_path = File::Spec->catfile($root, 'lib', 'DesertCMS', 'App.pm');
my $http_path = File::Spec->catfile($root, 'lib', 'DesertCMS', 'HTTP.pm');
my $media_path = File::Spec->catfile($root, 'lib', 'DesertCMS', 'Media.pm');
my $security_path = File::Spec->catfile($root, 'lib', 'DesertCMS', 'Security.pm');
my $maint_path = File::Spec->catfile($root, 'bin', 'desertcms-maint.pl');

my $app = _read($app_path);
my $http = _read($http_path);
my $media = _read($media_path);
my $security = _read($security_path);
my $maint = _read($maint_path);

unlike($app, qr{\bonsubmit\s*=\s*["']return\s+confirm}i, 'admin forms do not use inline browser confirm handlers');
unlike($app, qr{\bconfirm\s*\(}, 'admin JavaScript does not call the native confirm dialog');

like($app, qr{function setupAdminNotices\(\)}, 'admin JavaScript initializes notice behavior');
like($app, qr{function applyFormLoading\(form, submitter\)}, 'admin JavaScript initializes submit loading behavior');
like($app, qr{function openConfirm\(options, onConfirm\)}, 'admin JavaScript initializes shared confirmation modal behavior');
like($app, qr{button\.is-loading::before}, 'admin CSS includes loading spinner styling');
like($app, qr{\.confirm-backdrop}, 'admin CSS includes confirmation modal styling');
like($app, qr{\.notice-close}, 'admin CSS includes closeable notice styling');
like($app, qr{data-media-filter-tabs}, 'media library renders dedicated filter tabs');
like($app, qr{Private Source Only}, 'media library exposes private-source filter label');
like($app, qr{media-filter-tabs}, 'admin CSS styles media library filter tabs');
like($app, qr{\[ audio\s+=> 'Audio' \]}, 'media library exposes an Audio filter');
like($app, qr{\[ video\s+=> 'Video' \]}, 'media library exposes a Video filter');
like($app, qr{audio/mpeg}, 'media upload accepts audio MIME types');
like($app, qr{video/mp4}, 'media upload accepts video MIME types');
like($app, qr{asset\.type_label}, 'visual editor resource preview uses resource type labels');
like($app, qr{\.media-document-preview em}, 'admin CSS bounds document preview snippets');
like($app, qr{\.media-document-preview b}, 'admin CSS styles extracted document preview headings');
like($media, qr{Text preview extracted}, 'document metadata records extracted preview status copy');
like($app, qr{data-media-library-search}, 'media library renders server-side search form');
like($app, qr{Search titles, descriptions, filenames, snippets, categories, tags, collections, and file type metadata}, 'media library search copy names indexed metadata fields');
like($app, qr{data-media-picker-search}, 'visual editor media pickers expose search inputs');
like($app, qr{function assetSearchText\(asset\)}, 'visual editor picker search indexes media metadata');
like($app, qr{asset\.category}, 'visual editor picker search indexes media categories');
like($app, qr{asset\.tags}, 'visual editor picker search indexes media tags');
like($app, qr{asset\.collections}, 'visual editor picker search indexes media collections');
like($app, qr{media-picker-control}, 'admin CSS styles visual editor media picker search controls');
like($app, qr{data-media-organization-filters}, 'media library renders organization filters');
like($app, qr{bulk_category_text}, 'media bulk metadata can apply categories');
like($app, qr{name="tags_text"}, 'media metadata forms expose tags');
like($app, qr{name="collections_text"}, 'media metadata forms expose collections');
like($app, qr{media-organization}, 'admin CSS styles media organization chips');
like($app, qr{library_organization_terms}, 'media library can derive organization filter choices');
like($app, qr{library_filter_organization_assets}, 'media library can filter assets by organization metadata');
like($app, qr{/admin/media/\(\[0-9\]\+\)/preview}, 'admin routes private media preview requests');
like($app, qr{_media_private_preview}, 'admin implements authenticated private media preview response');
like($app, qr{media-document-preview--visual}, 'media library styles generated document previews');
like($media, qr{private_preview}, 'media metadata records private preview artifacts');
like($media, qr{pdf_page_thumbnail}, 'media pipeline records PDF thumbnail strategy');
like($media, qr{video_poster}, 'media pipeline records video poster strategy');
like($media, qr{audio_metadata}, 'media pipeline records audio metadata preview strategy');
like($security, qr{media_preview_tool}, 'OpenBSD sandbox can expose optional media preview tooling');
like($app, qr{/admin/media/bulk}, 'media library includes bulk action endpoint');
like($app, qr{data-media-bulk-form}, 'media library initializes bulk selection controls');
like($app, qr{Delete selected unused}, 'media library exposes safe unused delete bulk action');
like($app, qr{Delete selected unused \(not allowed\)}, 'media bulk delete action is disabled when the role lacks delete media capability');
like($app, qr{Only actions allowed by your media permissions are available}, 'media bulk toolbar explains role-limited actions');
like($app, qr{Your role cannot delete media assets}, 'media delete controls explain missing delete capability');
like($app, qr{Your role cannot edit media metadata}, 'bulk metadata handler rejects roles without metadata capability');
like($app, qr{download_media_sources}, 'media library checks private source download capability');
like($app, qr{publish_media_resources}, 'media library checks resource publish capability');
like($app, qr{delete_media_assets}, 'media library checks media delete capability');
like($app, qr{bulk_manage_media}, 'media library checks bulk media capability');
like($app, qr{Blank metadata fields stay unchanged}, 'media bulk metadata action preserves blank fields');
like($app, qr{/admin/media/lifecycle}, 'media library links to lifecycle audit surface');
like($app, qr{Media Lifecycle}, 'media lifecycle page has a dedicated heading');
like($app, qr{Your role can review media lifecycle findings, but cannot clean up or delete media files}, 'media lifecycle cleanup controls respect delete media capability');
like($app, qr{Private Preview Jobs}, 'media lifecycle page shows private preview job status');
like($app, qr{/admin/media/previews/queue}, 'media lifecycle page can queue private preview jobs');
like($app, qr{/admin/media/previews/process}, 'media lifecycle page can process private preview jobs');
like($media, qr{media_preview_jobs}, 'media pipeline persists private preview jobs');
like($media, qr{process_private_preview_jobs}, 'media pipeline can process queued preview jobs');
like($maint, qr{media-preview-jobs}, 'maintenance command can process media preview jobs');
like($app, qr{remove_orphaned_resources}, 'media lifecycle cleanup can remove orphaned public resources');
like($app, qr{remove_stale_derivatives}, 'media lifecycle cleanup can remove stale generated derivatives');
like($app, qr{delete_large_unused}, 'media lifecycle cleanup can delete large unused media');
like($app, qr{Retention Candidates}, 'media lifecycle page reports retention candidates');
like($app, qr{archive_old_unused}, 'media lifecycle cleanup can archive old unused media before deletion');
like($media, qr{media-retention}, 'media retention archives are stored in a dedicated private backup area');
like($app, qr{Current per-file upload limit}, 'media library shows current upload limit');
like($app, qr{media-quota-status}, 'media library renders contributor storage status');
like($app, qr{Media storage is nearly full}, 'media library warns before contributor media quota is exhausted');
like($app, qr{Remaining storage is lower than the per-file upload limit}, 'media library warns when quota remaining is below upload cap');
like($app, qr{Resource Downloads requires a plan upgrade}, 'media library shows locked Resource Downloads copy');
like($app, qr{billing-media-breakdown}, 'billing usage renders media storage breakdown');
like($app, qr{_billing_media_pressure_notice_html}, 'billing usage shares media storage pressure warnings');
like($app, qr{Public resources}, 'billing media breakdown names public resources');
like($app, qr{Upload limit}, 'billing media breakdown names upload limit');
like($app, qr{Resource Downloads}, 'billing media breakdown names Resource Downloads entitlement');

for my $expected (
    'Delete this $kind?',
    'Delete reusable section?',
    'Delete this media file?',
    'Restore this backup?',
    'Disconnect Google Search Console?',
    'Disable this admin user?',
    'Queue this rollback?',
    'Deny this contributor request?',
    'Archive and destroy this contributor site?',
    'Revoke this invite?',
) {
    like($app, qr{\Qdata-confirm-title="$expected"\E}, "confirmation metadata includes $expected");
}

like($app, qr{data-loading-label="Rebuilding\.\.\."}, 'search-engine submit form has a rebuild loading label');
like($app, qr{data-loading-label="Queueing\.\.\."}, 'queue actions can opt into a queueing loading label');
like($http, qr{admin\.css\?v=\$admin_css_version}, 'admin CSS cache key is supplied from rendered site settings');
like($http, qr{editor\.js\?v=20260705c}, 'admin JS cache key is bumped');
like($http, qr{<html lang="en" data-theme="\$default_theme_mode">}, 'admin shell renders default theme without inline bootstrap');
unlike($http, qr{<script>\s*document\.documentElement\.classList\.add\('has-js'\)}s, 'admin shell does not depend on inline has-js bootstrap');
like($app, qr{document\.documentElement\.classList\.add\('has-js'\);}, 'external admin JavaScript marks JS-ready state');
like($app, qr{<table class="content-table admin-card-table">}, 'Docs / Resource Hub catalog uses responsive admin card table markup');
like($app, qr{data-label="Public output"}, 'Docs / Resource Hub catalog rows expose mobile card labels');
unlike($app, qr{<table class="content-table">}, 'admin content tables do not use legacy plain wide markup');
unlike($app, qr{<td>(?:\$|<|[A-Za-z])}, 'admin table cells include explicit mobile labels');
like($app, qr{<table class="content-table compact-table admin-card-table">\s*<thead>\s*<tr><th>Title</th><th>Status</th><th>Public Path</th><th>Updated</th><th></th></tr>}s, 'page and post lists use responsive admin card table markup');
like($app, qr{data-label="Public Path"><code>\$public_path</code>}, 'page and post list rows expose public path labels');
like($app, qr{data-label="Actions" class="row-actions table-actions"}, 'legacy row action cells also opt into mobile action menus');
like($app, qr{<table class="content-table compact-table admin-card-table">\s*<thead>\s*<tr><th>Name</th><th>Description</th><th>Kind</th><th>Updated</th><th></th></tr>}s, 'templates and sections use responsive admin card table markup');
like($app, qr{<table class="content-table compact-table admin-card-table">\s*<thead><tr><th>Created</th><th>Item</th><th>Rights</th><th>Total</th><th>Status</th><th>Email</th></tr></thead>}s, 'Shop / Catalog orders use responsive admin card table markup');
like($app, qr{data-label="Item"><span class="status-pill">\$type</span>.*data-label="Contributor".*data-label="\$time_label".*data-label="Actions" class="table-actions"}s, 'federated review row template exposes mobile table labels');
like($app, qr{data-label="Archive"><code>\$filename</code>}, 'backup rows expose mobile archive labels');
like($app, qr{font-package-table admin-card-table}, 'OpenBSD font package tables use responsive admin card markup');
like($app, qr{data-label="Web font files"}, 'OpenBSD font package rows expose mobile file labels');

done_testing;

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}
