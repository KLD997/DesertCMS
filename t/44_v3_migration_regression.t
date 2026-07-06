use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Settings;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/data", "$root/public", "$root/originals", "$root/backups", "$root/themes", "$root/admin-assets");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = V3 Migration Regression
site_url = https://migration.example.test
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

local $ENV{DESERTCMS_CONFIG} = $config_path;
my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
my $dbh = $db->dbh;
my $now = time;

_seed_v2_like_database($dbh, $now);
$db->migrate;

my $post = $dbh->selectrow_hashref('SELECT * FROM content_items WHERE slug = ?', undef, 'legacy-post');
is($post->{type}, 'post', 'v3 migration preserves imported post content type');
is($post->{title}, 'Legacy Post', 'v3 migration preserves imported post title');
is($post->{published_html}, '<p>Legacy post body</p>', 'v3 migration preserves imported post rendered HTML');
ok(_has_column($dbh, 'content_items', 'access_policy'), 'v3 migration adds content access policy column');
is($post->{access_policy}, 'public', 'v3 migration defaults existing content to public access');
ok(_has_column($dbh, 'content_items', 'feature_image_path'), 'v3 migration adds feature image path column for posts module');

my $page = $dbh->selectrow_hashref('SELECT * FROM content_items WHERE slug = ?', undef, 'legacy-page');
is($page->{type}, 'page', 'v3 migration preserves imported page content type');
is($page->{title}, 'Legacy Page', 'v3 migration preserves imported page title');
is($page->{published_html}, '<p>Legacy page body</p>', 'v3 migration preserves imported page rendered HTML');
is($page->{show_in_nav}, 0, 'v3 migration defaults legacy page navigation state safely');

my $revision = $dbh->selectrow_hashref('SELECT * FROM content_revisions WHERE slug = ?', undef, 'legacy-post');
is($revision->{title}, 'Legacy Revision', 'v3 migration preserves imported content revision title');
is($revision->{body_json}, '[{"type":"paragraph","text":"legacy revision body"}]', 'v3 migration preserves imported content revision body');
ok(_has_column($dbh, 'content_revisions', 'author_user_id'), 'v3 migration adds content revision author column');
ok(_has_column($dbh, 'content_revisions', 'access_policy'), 'v3 migration adds content revision access policy column');
ok(_has_column($dbh, 'content_revisions', 'tags_text'), 'v3 migration adds content revision tags column');
is($revision->{access_policy}, 'public', 'v3 migration defaults legacy revisions to public access');
is($revision->{collections_text}, '', 'v3 migration defaults legacy revision collections safely');

my $media = $dbh->selectrow_hashref('SELECT * FROM media_assets WHERE storage_path = ?', undef, 'originals/legacy.jpg');
is($media->{original_name}, 'legacy.jpg', 'v3 migration preserves media records');
ok(_has_column($dbh, 'media_assets', 'owner_site_id'), 'v3 migration adds media SubCMS ownership column');
is($media->{owner_site_id}, '', 'v3 migration defaults legacy media to master-owned');
is($media->{derivatives_json}, '{}', 'v3 migration defaults media derivative metadata');

my $site = $dbh->selectrow_hashref('SELECT * FROM contributor_sites WHERE site_id = ?', undef, 'legacy-site');
is($site->{domain}, 'legacy.example.test', 'v3 migration preserves contributor site domain');
ok(_has_column($dbh, 'contributor_sites', 'blueprint_snapshot_json'), 'v3 migration adds contributor blueprint snapshot column');
ok(_has_column($dbh, 'contributor_sites', 'owner_first_name'), 'v3 migration adds contributor owner first-name column');
ok(_has_column($dbh, 'contributor_sites', 'owner_last_initial'), 'v3 migration adds contributor owner last-initial column');
ok(_has_column($dbh, 'contributor_sites', 'owner_email'), 'v3 migration adds contributor owner email column');
is($site->{billing_status}, 'comped', 'v3 migration defaults legacy contributor billing status safely');
is($site->{media_upload_limit_mb}, 64, 'v3 migration adds contributor media upload limit default');

my $blueprint = $dbh->selectrow_hashref('SELECT * FROM contributor_blueprints WHERE slug = ?', undef, 'legacy-standard');
is($blueprint->{module_posts_enabled}, 1, 'v3 migration preserves legacy Posts module gate');
is($blueprint->{module_accounts_enabled}, 0, 'v3 migration adds Accounts gate disabled by default');
is($blueprint->{module_notifications_enabled}, 1, 'v3 migration adds Notifications gate enabled by default');
is($blueprint->{module_security_center_enabled}, 1, 'v3 migration adds Security Center gate enabled by default');

my $settings = DesertCMS::Settings::all($config, $db);
is($settings->{module_posts_enabled}, 1, 'v3 migration preserves Posts module setting');
is($settings->{module_map_enabled}, 0, 'v3 migration preserves existing disabled module settings');

for my $table (qw(
    user_accounts user_account_password_reset_tokens notifications notification_deliveries realtime_sessions
    live_stream_channels live_stream_worker_events live_chat_messages live_chat_presence live_chat_reports forum_categories forum_reports social_profiles social_posts social_replies social_reports
)) {
    ok(_table_exists($dbh, $table), "v3 migration creates $table");
}
ok(_index_exists($dbh, 'idx_user_account_password_reset_tokens_account_status'), 'v3 migration indexes Account password reset tokens by account and status');
ok(_has_column($dbh, 'notifications', 'actor_account_id'), 'v3 migration adds public actor account context to notifications');
ok(_has_column($dbh, 'live_chat_messages', 'ip_address'), 'v3 migration adds Live Streaming chat IP context');
ok(_index_exists($dbh, 'idx_live_chat_messages_ip_time'), 'v3 migration adds Live Streaming chat IP throttle index');
ok(_has_column($dbh, 'forum_categories', 'visibility'), 'v3 migration adds Forum category visibility policy');
ok(_has_column($dbh, 'forum_topics', 'ip_address'), 'v3 migration adds Forum topic IP context');
ok(_has_column($dbh, 'forum_topics', 'moderator_note'), 'v3 migration adds Forum topic moderation notes');
ok(_has_column($dbh, 'forum_posts', 'ip_address'), 'v3 migration adds Forum post IP context');
ok(_has_column($dbh, 'forum_posts', 'moderator_note'), 'v3 migration adds Forum post moderation notes');
ok(_index_exists($dbh, 'idx_forum_posts_ip_time'), 'v3 migration adds Forum post IP throttle index');
ok(_has_column($dbh, 'social_posts', 'ip_address'), 'v3 migration adds Social post IP context');
ok(_has_column($dbh, 'social_replies', 'ip_address'), 'v3 migration adds Social reply IP context');
ok(_index_exists($dbh, 'idx_social_posts_ip_time'), 'v3 migration adds Social post IP throttle index');
ok(_index_exists($dbh, 'idx_social_replies_ip_time'), 'v3 migration adds Social reply IP throttle index');
ok(_has_column($dbh, 'social_reports', 'reply_id'), 'v3 migration adds Social reply report context');

my ($schema_version) = $dbh->selectrow_array('SELECT MAX(version) FROM schema_migrations');
is($schema_version, DesertCMS::DB::CURRENT_SCHEMA_VERSION(), 'v3 migration records current schema version');

done_testing;

sub _seed_v2_like_database {
    my ($dbh, $now) = @_;
    $dbh->do(q{
        CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        )
    });
    $dbh->do(q{
        CREATE TABLE content_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            slug TEXT NOT NULL UNIQUE,
            status TEXT NOT NULL DEFAULT 'draft',
            excerpt TEXT NOT NULL DEFAULT '',
            body_json TEXT NOT NULL DEFAULT '[]',
            published_html TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            published_at INTEGER,
            deleted_at INTEGER
        )
    });
    $dbh->do(q{
        CREATE TABLE content_revisions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content_id INTEGER NOT NULL,
            title TEXT NOT NULL,
            slug TEXT NOT NULL,
            status TEXT NOT NULL,
            excerpt TEXT NOT NULL DEFAULT '',
            body_json TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )
    });
    $dbh->do(q{
        CREATE TABLE media_assets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            original_name TEXT NOT NULL,
            storage_path TEXT NOT NULL,
            public_path TEXT,
            mime_type TEXT NOT NULL,
            width INTEGER,
            height INTEGER,
            bytes INTEGER NOT NULL,
            checksum_sha256 TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            deleted_at INTEGER
        )
    });
    $dbh->do(q{
        CREATE TABLE contributor_blueprints (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            slug TEXT NOT NULL UNIQUE,
            description TEXT NOT NULL DEFAULT '',
            module_posts_enabled INTEGER NOT NULL DEFAULT 1,
            module_map_enabled INTEGER NOT NULL DEFAULT 1,
            module_shop_enabled INTEGER NOT NULL DEFAULT 0,
            module_gallery_enabled INTEGER NOT NULL DEFAULT 1,
            module_forms_enabled INTEGER NOT NULL DEFAULT 0,
            module_contributor_requests_enabled INTEGER NOT NULL DEFAULT 0,
            module_docs_enabled INTEGER NOT NULL DEFAULT 0,
            theme_default_mode TEXT NOT NULL DEFAULT 'light',
            theme_light_preset TEXT NOT NULL DEFAULT 'light-archive',
            theme_dark_preset TEXT NOT NULL DEFAULT 'dark-archive',
            shop_enabled INTEGER NOT NULL DEFAULT 0,
            media_quota_mb INTEGER NOT NULL DEFAULT 512,
            post_quota INTEGER NOT NULL DEFAULT 100,
            page_quota INTEGER NOT NULL DEFAULT 20,
            features_json TEXT NOT NULL DEFAULT '{}',
            allow_master_gallery INTEGER NOT NULL DEFAULT 1,
            allow_master_posts INTEGER NOT NULL DEFAULT 1,
            site_meta_title TEXT NOT NULL DEFAULT '',
            site_meta_description TEXT NOT NULL DEFAULT '',
            default_pages_json TEXT NOT NULL DEFAULT '[]',
            is_default INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
    });
    $dbh->do(q{
        CREATE TABLE contributor_sites (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            site_id TEXT NOT NULL UNIQUE,
            domain TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            status TEXT NOT NULL,
            config_path TEXT NOT NULL DEFAULT '',
            data_dir TEXT NOT NULL DEFAULT '',
            public_root TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            provisioned_at INTEGER,
            disabled_at INTEGER,
            destroyed_at INTEGER
        )
    });
    $dbh->do(
        q{INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?), (?, ?, ?)},
        undef,
        'module_posts_enabled', 1, $now,
        'module_map_enabled', 0, $now
    );
    $dbh->do(
        q{
            INSERT INTO content_items
                (type, title, slug, status, excerpt, body_json, published_html, created_at, updated_at, published_at)
            VALUES
                ('post', 'Legacy Post', 'legacy-post', 'published', 'Imported post', '[]', '<p>Legacy post body</p>', ?, ?, ?)
        },
        undef,
        $now,
        $now,
        $now
    );
    my ($post_id) = $dbh->selectrow_array(q{SELECT id FROM content_items WHERE slug = ?}, undef, 'legacy-post');
    $dbh->do(
        q{
            INSERT INTO content_revisions
                (content_id, title, slug, status, excerpt, body_json, created_at)
            VALUES
                (?, 'Legacy Revision', 'legacy-post', 'published', 'Imported revision', '[{"type":"paragraph","text":"legacy revision body"}]', ?)
        },
        undef,
        $post_id,
        $now
    );
    $dbh->do(
        q{
            INSERT INTO content_items
                (type, title, slug, status, excerpt, body_json, published_html, created_at, updated_at, published_at)
            VALUES
                ('page', 'Legacy Page', 'legacy-page', 'published', 'Imported page', '[]', '<p>Legacy page body</p>', ?, ?, ?)
        },
        undef,
        $now,
        $now,
        $now
    );
    $dbh->do(
        q{
            INSERT INTO media_assets
                (original_name, storage_path, public_path, mime_type, width, height, bytes, checksum_sha256, created_at)
            VALUES
                ('legacy.jpg', 'originals/legacy.jpg', '/assets/legacy.jpg', 'image/jpeg', 1200, 800, 1024, 'abc123', ?)
        },
        undef,
        $now
    );
    $dbh->do(
        q{
            INSERT INTO contributor_blueprints
                (name, slug, description, module_posts_enabled, module_map_enabled, module_shop_enabled, module_gallery_enabled, is_default, created_at, updated_at)
            VALUES
                ('Legacy Standard', 'legacy-standard', 'Legacy blueprint before v3 module gates.', 1, 1, 0, 1, 1, ?, ?)
        },
        undef,
        $now,
        $now
    );
    $dbh->do(
        q{
            INSERT INTO contributor_sites
                (site_id, domain, display_name, status, config_path, data_dir, public_root, created_at, updated_at, provisioned_at)
            VALUES
                ('legacy-site', 'legacy.example.test', 'Legacy Site', 'active', '/var/desertcms/sites/legacy.conf', '/var/desertcms/sites/legacy', '/var/www/htdocs/legacy', ?, ?, ?)
        },
        undef,
        $now,
        $now,
        $now
    );
}

sub _table_exists {
    my ($dbh, $table) = @_;
    my ($exists) = $dbh->selectrow_array(
        q{SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?},
        undef,
        $table
    );
    return $exists ? 1 : 0;
}

sub _has_column {
    my ($dbh, $table, $column) = @_;
    my $columns = $dbh->selectall_arrayref("PRAGMA table_info($table)", { Slice => {} });
    return scalar grep { ($_->{name} || '') eq $column } @{$columns};
}

sub _index_exists {
    my ($dbh, $index) = @_;
    my ($exists) = $dbh->selectrow_array(
        q{SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?},
        undef,
        $index
    );
    return $exists ? 1 : 0;
}

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}
