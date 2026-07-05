use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DateTimeLite;
use DesertCMS::DB;
use DesertCMS::Directory;
use DesertCMS::Events;
use DesertCMS::HTTP;
use DesertCMS::Modules;
use DesertCMS::Navigation;
use DesertCMS::Newsletter;
use DesertCMS::Settings;

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public/assets/media", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Newsletter Test
site_url = https://newsletter.example.test
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

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
my $content = DesertCMS::Content->new(config => $config, db => $db);

my $home = $content->save(
    type      => 'page',
    title     => 'Home',
    slug      => 'home',
    body_text => 'Newsletter home.',
);
$content->publish(id => $home->{id});

DesertCMS::Settings::set_many($config, $db, {
    module_newsletter_enabled => 1,
    module_events_enabled     => 1,
    module_directory_enabled  => 1,
    module_shop_enabled       => 1,
    newsletter_title          => 'Field Notes',
    newsletter_intro          => 'Announcements, posts, events, directory updates, and catalog notes.',
    newsletter_consent_text   => 'Send me Field Notes updates. I can unsubscribe any time.',
    newsletter_signup_enabled => 1,
    newsletter_default_tags   => 'field-notes',
    commerce_model            => 'disabled',
});

my $settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'newsletter'), 'newsletter feature can be enabled independently');
my $catalog = DesertCMS::Modules::catalog($settings, config => $config);
like(_module_catalog_text($catalog), qr/Newsletter.*subscriber records, tags and segments, announcement drafts, digest generation, Postmark delivery/s, 'feature catalog describes Newsletter');

my $post = $content->save(
    type      => 'post',
    title     => 'Summer Update',
    slug      => 'summer-update',
    excerpt   => 'A seasonal post for subscribers.',
    body_text => 'Recent post body.',
);
$content->publish(id => $post->{id});

my $start = DesertCMS::DateTimeLite->now(time_zone => 'UTC')->add(days => 10)->set(hour => 17, minute => 0, second => 0, nanosecond => 0);
my $event = DesertCMS::Events->new(config => $config, db => $db)->save_event(
    title      => 'Subscriber Meetup',
    slug       => 'subscriber-meetup',
    summary    => 'An event digest item.',
    body       => 'Meet subscribers.',
    status     => 'published',
    timezone   => 'UTC',
    starts_at  => $start->epoch,
    ends_at    => $start->clone->add(hours => 1)->epoch,
);
DesertCMS::Events->new(config => $config, db => $db)->publish_event($event->{id});

my $directory = DesertCMS::Directory->new(config => $config, db => $db);
my $entry = $directory->save_entry(
    title   => 'Archive Partner',
    slug    => 'archive-partner',
    kind    => 'organization',
    status  => 'published',
    summary => 'A directory digest item.',
);
$directory->publish_entry($entry->{id});

my $source_path = "$root/originals/catalog-item.txt";
_write($source_path, "catalog source\n");
$db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             mime_type, width, height, bytes, checksum_sha256, derivatives_json, created_at)
        VALUES
            ('catalog-item.txt', ?, '', '', 'Catalog Item', 'Catalog source.',
             'text/plain', NULL, NULL, 15, ?, '{}', ?)
    },
    undef,
    $source_path,
    'e' x 64,
    time
);
my $media_id = $db->dbh->sqlite_last_insert_rowid;
$db->dbh->do(
    q{
        INSERT INTO shop_listings
            (media_asset_id, title, description, listing_kind, active, created_at, updated_at)
        VALUES (?, 'Resource Packet', 'A catalog digest item.', 'digital', 1, ?, ?)
    },
    undef,
    $media_id,
    time,
    time
);

my $newsletter = DesertCMS::Newsletter->new(config => $config, db => $db);
my $subscriber = $newsletter->subscribe(
    email        => 'reader@example.test',
    display_name => 'Reader One',
    consent_text => 'Test consent',
    ip_address   => '127.0.0.1',
    user_agent   => 'newsletter-test',
);
ok($subscriber->{id}, 'public subscriber record is created');
is($subscriber->{status}, 'active', 'subscriber starts active');
like($subscriber->{tags_text}, qr/field-notes/, 'default signup tag is applied');

$content->rebuild_all;
ok(-f File::Spec->catfile($root, 'public', 'newsletter', 'index.html'), 'newsletter index is generated');
my $index_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($index_html, qr{href="/newsletter/"}, 'enabled Newsletter appears in public navigation');
like($index_html, qr{Field Notes}, 'public navigation uses configured Newsletter title');
my $newsletter_html = _read(File::Spec->catfile($root, 'public', 'newsletter', 'index.html'));
like($newsletter_html, qr{Send me Field Notes updates}, 'generated newsletter page renders consent text');
my $sitemap = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
like($sitemap, qr{https://newsletter\.example\.test/newsletter/</loc>}, 'sitemap includes newsletter route');

my $app = DesertCMS::App->new;
my $public_response = _capture_response(sub {
    $app->_dispatch_newsletter(_newsletter_request('/newsletter'));
});
like($public_response, qr{Field Notes}, 'dynamic /newsletter route renders public page');

my $subscribe_response = _capture_response(sub {
    $app->_dispatch_newsletter(_newsletter_request('/newsletter/subscribe', 'POST', {
        email        => 'second@example.test',
        display_name => 'Second Reader',
        consent_text => 'Second consent',
    }));
});
like($subscribe_response, qr{You are subscribed}, 'public subscribe route confirms capture');
ok($newsletter->subscriber_by_email('second@example.test'), 'public subscribe route stores subscriber');

my $second = $newsletter->subscriber_by_email('second@example.test');
my $unsubscribe_response = _capture_response(sub {
    $app->_dispatch_newsletter(_newsletter_request('/newsletter/unsubscribe/' . $second->{id} . '/' . $second->{unsubscribe_token}));
});
like($unsubscribe_response, qr{unsubscribed}, 'unsubscribe link updates subscriber status');
is($newsletter->subscriber_by_id($second->{id})->{status}, 'unsubscribed', 'subscriber is marked unsubscribed');

my $announcement = $newsletter->save_announcement(
    title            => 'Weekly Dispatch',
    subject          => 'This week from Field Notes',
    status           => 'ready',
    manual_body      => "Opening note for subscribers.",
    source_posts     => 1,
    source_events    => 1,
    source_directory => 1,
    source_shop      => 1,
);
like($announcement->{preview_text}, qr/Summer Update/, 'digest includes recent posts');
like($announcement->{preview_text}, qr/Subscriber Meetup/, 'digest includes events');
like($announcement->{preview_text}, qr/Archive Partner/, 'digest includes directory entries');
like($announcement->{preview_text}, qr/Resource Packet/, 'digest includes shop/catalog listings');

my $csv = $newsletter->csv_export;
like($csv, qr/reader\@example\.test/, 'subscriber CSV export includes subscribers');
like($csv, qr/field-notes/, 'subscriber CSV export includes tags');

my $admin_html = _capture_response(sub {
    $app->_module_newsletter_settings_page(undef, { username => 'admin', role => 'owner' }, 'newsletter-session');
});
like($admin_html, qr/<h1>Newsletter<\/h1>/, 'admin Newsletter surface renders');
like($admin_html, qr/module-section-nav" aria-label="Newsletter setup sections".*href="\#module-settings">Settings<\/a>.*href="\#module-subscribers">Subscribers<\/a>.*href="\#module-announcements">Announcements<\/a>.*href="\#module-history">Send History<\/a>/s, 'admin Newsletter surface exposes local section navigation');
like($admin_html, qr{<code>/newsletter/</code>}, 'admin Newsletter surface shows public path');
like($admin_html, qr{reader\@example\.test}, 'admin Newsletter surface lists subscribers');
like($admin_html, qr{Weekly Dispatch}, 'admin Newsletter surface lists announcement drafts');
like($admin_html, qr{Export CSV}, 'admin Newsletter surface exposes subscriber export');
like($admin_html, qr/content-table compact-table admin-card-table/, 'admin Newsletter tables use responsive card markup');
like($admin_html, qr/data-label="Subscriber".*data-label="Announcement"/s, 'admin Newsletter populated rows expose mobile card labels');
like($admin_html, qr/<th>Message<\/th>/, 'admin Newsletter send history table keeps responsive history headers for empty states');
like($admin_html, qr/module-section-nav" aria-label="Newsletter settings editor sections".*href="\#newsletter-status">Status<\/a>.*href="\#newsletter-public-copy">Public Copy<\/a>/s, 'admin Newsletter settings expose local form navigation');
like($admin_html, qr/id="newsletter-status".*id="newsletter-public-copy"/s, 'admin Newsletter settings navigation targets stable anchors');
like($admin_html, qr/module-section-nav" aria-label="Newsletter announcement editor sections".*href="\#newsletter-announcement-content">Content<\/a>.*href="\#newsletter-announcement-sources">Digest Sources<\/a>.*href="\#newsletter-announcement-status">Status<\/a>/s, 'admin Newsletter announcement editor exposes local form navigation');
like($admin_html, qr/id="newsletter-announcement-content".*id="newsletter-announcement-sources".*id="newsletter-announcement-status"/s, 'admin Newsletter announcement editor navigation targets stable anchors');

my $readiness = $newsletter->delivery_readiness;
ok(!$readiness->{send_ready}, 'Postmark newsletter delivery is not ready without sender token');
like($readiness->{summary}, qr/Postmark|sender|token|transport|HTTPS/i, 'readiness explains missing Postmark setup');
my $send_error = eval { $newsletter->send_announcement(id => $announcement->{id}); 1 } ? '' : $@;
like($send_error, qr/Newsletter delivery is not ready/, 'newsletter send is blocked until Postmark is ready');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        newsletter => 0,
        events     => 1,
        directory  => 1,
    }),
});
my $contrib_config_path = "$root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Newsletter
site_url = https://newsletter-site.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
contributor_site_id = newsletter-site
contributor_domain = newsletter-site.example.test
secure_cookies = 0
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
my $locked_catalog = DesertCMS::Modules::catalog(DesertCMS::Settings::all($config, $db), config => $contrib_config);
my %feature_by_key = map { $_->{key} => $_ } @{$locked_catalog};
ok($feature_by_key{newsletter}{locked_by_plan}, 'contributor feature catalog can lock Newsletter by plan');
ok(!$feature_by_key{newsletter}{enabled}, 'locked Newsletter is not effectively enabled');

done_testing;

sub _newsletter_request {
    my ($path, $method, $form) = @_;
    return bless {
        method => $method || 'GET',
        path   => $path || '/newsletter',
        host   => 'newsletter.example.test',
        form   => $form || {},
        query  => $form || {},
        cookies => {},
        ip_address => '127.0.0.1',
        remote_addr => '127.0.0.1',
        user_agent => 'newsletter-test',
    }, 'DesertCMS::HTTP';
}

sub _module_catalog_text {
    my ($catalog) = @_;
    return join "\n", map {
        join ' ', $_->{label} || '', $_->{description} || '', $_->{public_path} || ''
    } @{$catalog || []};
}

sub _write {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _capture_response {
    my ($code) = @_;
    my $output = '';
    open my $fh, '>', \$output or die "cannot capture output: $!";
    {
        local *STDOUT = $fh;
        DesertCMS::HTTP::reset_response_state();
        $code->();
    }
    return $output;
}
