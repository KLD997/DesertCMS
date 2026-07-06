use strict;
use warnings;
use Test::More;
use File::Find;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP qw(encode_json decode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::Blueprints;
use DesertCMS::App;
use DesertCMS::Content;
use DesertCMS::ContributorRequests;
use DesertCMS::DB;
use DesertCMS::Federation;
use DesertCMS::HTTP;
use DesertCMS::Settings;
use DesertCMS::Sites;

my $repo = getcwd();
$repo =~ s{\\}{/}g;
my ($image_tool, $tool_mode) = _find_image_tool($repo);
plan skip_all => 'Image tool not found' unless $image_tool;
$image_tool =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/themes", "$root/admin-assets", "$root/data");

my $profile_source = File::Spec->catfile($root, 'profile-source.jpg');
my @profile_cmd = $tool_mode eq 'vips'
    ? (_sibling_command($image_tool, 'vips'), 'black', $profile_source, 1600, 900, '--bands', 3)
    : _image_tool_cmd($image_tool, $tool_mode, 'convert', '-size', '1600x900', 'xc:#49707a', $profile_source);
system @profile_cmd;
is($?, 0, 'created contributor profile image fixture');
ok(-f $profile_source, 'contributor profile image fixture exists');
my $profile_image_bytes = _read_binary($profile_source);

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Contributor Requests Test
site_url = https://desertarchives.com
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
image_tool = $image_tool
secure_cookies = 0
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

DesertCMS::Settings::set_many($config, $db, {
    contributor_domain_root => 'desertarchives.com',
    postmark_from_email => 'send@example.com',
    contributor_request_recipient_email => 'review@example.com',
    module_contributor_requests_enabled => 1,
});

my $requests = DesertCMS::ContributorRequests->new(config => $config, db => $db);
my $sites = DesertCMS::Sites->new(config => $config, db => $db);
my $blueprints = DesertCMS::Blueprints->new(config => $config, db => $db);
my $feature_blueprint = $blueprints->save(
    name => 'Featured Contributor',
    slug => 'featured-contributor',
    description => 'Contributor request approval blueprint.',
    module_map_enabled => 1,
    module_gallery_enabled => 1,
    module_shop_enabled => 0,
    media_quota_mb => 256,
    post_quota => 24,
    page_quota => 8,
    allow_master_gallery => 1,
    allow_master_posts => 1,
    site_meta_title => 'Featured Contributor',
    site_meta_description => 'Featured contributor SEO defaults.',
    default_pages_text => "About|about|nav\nPortfolio|portfolio|nav",
);
my $content = DesertCMS::Content->new(config => $config, db => $db);

my $application_text = 'Alex wants to join the archive to share careful field notes from quiet desert places, contribute reliable local context, and help preserve regional stories with useful captions for future readers.';
my $profile_bio = 'Alex documents quiet desert places with careful attention to weather, trail context, and the people who preserve local stories. The public profile focuses on long term archive value and clear captions for future readers.';

my $submitted = $requests->submit(
    name => 'Alex Smith',
    email => 'Alex.Smith@example.com',
    phone => '555-0100',
    age => 31,
    application_text => $application_text,
    application_showcase_uploads => [
        _upload('showcase-one.jpg', 'image/jpeg', 'showcase one bytes'),
        _upload('showcase-two.png', 'image/png', 'showcase two bytes'),
    ],
    request => {
        ip_address => '203.0.113.10',
        user_agent => 'ContributorRequestTest/1.0',
    },
);
ok($submitted->{id}, 'contributor request returns an id');

eval {
    $requests->submit(
        name => 'Alex Smith',
        email => 'alex.smith@example.com',
        phone => '555-0100',
        age => 31,
        application_text => $application_text,
        request => {
            ip_address => '198.51.100.220',
            user_agent => 'ContributorRequestDuplicateTest/1.0',
        },
    );
};
like($@, qr/A contributor request from this email was already submitted recently\. Please wait \d+ days? before trying again\./, 'duplicate contributor request email is blocked by cooldown');

my $row = $requests->request_by_id($submitted->{id});
is($row->{status}, 'new', 'submitted request starts as new');
is($row->{email}, 'alex.smith@example.com', 'email is normalized');
is($row->{application_text}, $application_text, 'application response is stored');
is($row->{profile_photo_path}, '', 'profile photo is not collected before approval');
is(@{DesertCMS::ContributorRequests::application_showcase_files($row)}, 2, 'application sample uploads are recorded privately');
is(@{DesertCMS::ContributorRequests::showcase_files($row)}, 0, 'public profile samples are empty before profile completion');

my $approved = $requests->approve(
    id => $submitted->{id},
    sites => $sites,
    note => 'Approved for test',
    blueprint_id => $feature_blueprint->{id},
);
is($approved->{status}, 'approved', 'request can be approved');
is($approved->{site_id}, 'alexs', 'approved request uses first name and last initial for subdomain');
is($approved->{domain}, 'alexs.desertarchives.com', 'approved request stores contributor domain');
is($approved->{blueprint_id}, $feature_blueprint->{id}, 'approved request stores selected blueprint');
ok($approved->{profile_token}, 'approval creates a profile completion token');
ok($approved->{profile_token_hash}, 'approval stores only the profile token hash');
ok(!-f File::Spec->catfile($root, 'public', 'assets', 'contributors', 'alexs.jpg'), 'approval does not publish a profile photo before profile completion');

my $jobs = $sites->queue_rows;
is(@{$jobs}, 1, 'approval queues one provisioning job');
is($jobs->[0]{site_id}, 'alexs', 'queued provisioning job targets approved contributor site');
is($jobs->[0]{action}, 'create', 'approval queues a create job');
my $approved_site = $sites->site_by_id('alexs');
is($approved_site->{blueprint_id}, $feature_blueprint->{id}, 'approved site stores selected blueprint id');
is($approved_site->{media_quota_mb}, 256, 'approved site stores blueprint quota');
my $queued_details = decode_json($jobs->[0]{details_json});
is($queued_details->{blueprint}{name}, 'Featured Contributor', 'request approval queues blueprint snapshot');

my $app = DesertCMS::App->new;
my $profile_form_html = _capture_response(sub {
    $app->_contributor_profile_form(_request(), $approved->{profile_token});
});
like($profile_form_html, qr/Status: 200 OK/, 'profile completion form renders');
like($profile_form_html, qr{class="public-form contributor-profile-form"}, 'profile completion uses public profile form class');
like($profile_form_html, qr{Public bio}, 'profile completion form groups bio field');
like($profile_form_html, qr{data-character-counter}, 'profile completion form includes bio character counter');
like($profile_form_html, qr{data-upload-preview}, 'profile completion form includes upload previews');
like($profile_form_html, qr{public-onboarding-steps}, 'profile completion form shows onboarding steps');
like($profile_form_html, qr{<script src="/assets/site\.js"></script>}, 'profile completion form uses the public shell script');
unlike($profile_form_html, qr{/admin/assets/admin\.css|href="/admin"}, 'profile completion form does not render admin shell assets or links');

my $failed_email_ts = time;
$db->dbh->do(
    q{
        INSERT INTO email_delivery_logs
            (provider, message_id, email_type, status, from_email, to_email, subject, reason,
             provider_response_json, webhook_event_json, created_at, updated_at, sent_at, last_event_at)
        VALUES
            ('postmark', '', 'contributor_request_approved', 'failed', 'send@example.com', 'alex.smith@example.com',
             'Your contributor request was approved', 'transport failed', '{}', '{}', ?, ?, NULL, NULL)
    },
    undef,
    $failed_email_ts,
    $failed_email_ts
);

my $contributors_admin_html = _capture_response(sub {
    $app->_settings_contributors_page(_request(), { username => 'admin', user_id => 1 }, 'contributors-session');
});
like($contributors_admin_html, qr/class="content-table compact-table admin-card-table"/, 'contributors admin tables use responsive admin card class');
like($contributors_admin_html, qr/data-label="Actions" class="table-actions"/, 'contributor request rows include mobile action label');
like($contributors_admin_html, qr{Contributor Onboarding}, 'contributors admin shows guided onboarding flow');
like($contributors_admin_html, qr{Email delivery needs attention}, 'contributors admin surfaces delivery failure banner');
like($contributors_admin_html, qr{Email needs attention: transport failed}, 'request row surfaces applicant email failure');

my $request_review_html = _capture_response(sub {
    $app->_contributor_request_review_page(_request(), { username => 'admin', user_id => 1 }, 'contributors-session', $submitted->{id});
});
like($request_review_html, qr{Onboarding Progress}, 'request review shows onboarding progress');
like($request_review_html, qr{Waiting for the applicant to complete the emailed profile form\.}, 'request review shows profile pending step');
like($request_review_html, qr{Email Delivery}, 'request review shows applicant email delivery section');
like($request_review_html, qr{transport failed}, 'request review shows applicant email delivery failure detail');
my $billing_flow_html = DesertCMS::App::_billing_onboarding_flow({
    service_plan_name => 'Free Tier',
    billing_status    => 'comped',
    status            => 'active',
});
like($billing_flow_html, qr{onboarding-flow--billing}, 'contributor billing helper renders service-tier flow');
like($billing_flow_html, qr{Your hosted site starts on the free tier}, 'billing onboarding explains the free-tier starting point');
my $billing_cards_html = $app->_billing_plan_cards(
    [
        {
            id => 1,
            name => 'Free Tier',
            description => 'Starter contributor site.',
            monthly_price_cents => 0,
            currency => 'usd',
            media_quota_mb => 512,
            post_quota => 100,
            page_quota => 20,
            allow_master_gallery => 1,
            allow_master_posts => 1,
            is_default => 1,
        },
        {
            id => 2,
            name => 'Studio',
            description => 'More room for an active contributor.',
            monthly_price_cents => 1900,
            currency => 'usd',
            stripe_price_id => 'price_studio',
            media_quota_mb => 2048,
            post_quota => 500,
            page_quota => 80,
            allow_master_gallery => 1,
            allow_master_posts => 1,
        },
        {
            id => 3,
            name => 'Archive',
            description => 'Needs Stripe setup before it can be sold.',
            monthly_price_cents => 3900,
            currency => 'usd',
            stripe_price_id => '',
            media_quota_mb => 4096,
            post_quota => 1000,
            page_quota => 140,
            allow_master_gallery => 1,
            allow_master_posts => 0,
        },
    ],
    {
        service_plan_id => 2,
        billing_status => 'active',
        stripe_customer_id => 'cus_service',
        stripe_subscription_id => 'sub_service',
    },
    'csrf-billing'
);
like($billing_cards_html, qr{billing-plan-card--current}, 'billing card marks the current plan distinctly');
like($billing_cards_html, qr{Current plan}, 'billing card labels the active tier');
like($billing_cards_html, qr{Manage or cancel in Stripe}, 'current paid plan opens Stripe-hosted subscription management');
like($billing_cards_html, qr{Cancel the paid subscription in Stripe to return to this tier\.}, 'free tier explains the safe downgrade path');
like($billing_cards_html, qr{Plan setup needed}, 'paid plans without a Stripe Price ID are blocked clearly');
like($billing_cards_html, qr{Media storage}, 'billing cards render comparable quota rows');
like($billing_cards_html, qr{<li><span>Features</span><strong>}, 'billing cards render comparable feature rows');

my $home = $content->save(
    type => 'page',
    title => 'Home',
    slug => 'home',
    body_json => encode_json([
        {
            type => 'contributor_request',
            title => 'Become a contributor',
            intro => 'Apply to share your work with the archive.',
            button_label => 'Apply now',
        },
    ]),
    show_in_nav => 1,
);
$content->publish(id => $home->{id});

my $home_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($home_html, qr{action="/forms/contributor-request"}, 'published block posts to contributor request route');
like($home_html, qr{enctype="multipart/form-data"}, 'published block supports file uploads');
like($home_html, qr{Apply now}, 'published block uses custom button label');

my $contributors_html = _read(File::Spec->catfile($root, 'public', 'contributors', 'index.html'));
unlike($contributors_html, qr{Alex Smith}, 'contributors page hides approved contributor until profile completion');
like($contributors_html, qr{href="/contributors/apply/"}, 'contributors page links to the application form');

my $custom_contributors_page = $content->save(
    type => 'page',
    title => 'Contributors',
    slug => 'contributors',
    body_json => encode_json([
        { type => 'text', text => 'This should not replace the module directory.', html => '<p>This should not replace the module directory.</p>' },
    ]),
    show_in_nav => 1,
);
$content->publish(id => $custom_contributors_page->{id});
$contributors_html = _read(File::Spec->catfile($root, 'public', 'contributors', 'index.html'));
like($contributors_html, qr{module-page contributors-page}, 'contributors module owns the contributors route');
unlike($contributors_html, qr{This should not replace the module directory\.}, 'custom contributors page does not replace module output');

my $apply_html = _read(File::Spec->catfile($root, 'public', 'contributors', 'apply', 'index.html'));
like($apply_html, qr{Contributor Application}, 'contributor apply page is generated');
like($apply_html, qr{action="/forms/contributor-request"}, 'contributor apply page posts to contributor request route');
like($apply_html, qr{name="name"[^>]+required}, 'contributor apply form requires name');
like($apply_html, qr{name="age"[^>]+required}, 'contributor apply form requires age');
like($apply_html, qr{name="email"[^>]+required}, 'contributor apply form requires email');
like($apply_html, qr{name="phone"[^>]+required}, 'contributor apply form requires phone');
like($apply_html, qr{name="showcase_1"[^>]*type="file"}, 'contributor apply form supports optional sample upload');
unlike($apply_html, qr{name="showcase_1"[^>]+required}, 'contributor apply form does not require a sample');
like($apply_html, qr{name="application_text"[^>]+minlength="150"[^>]+maxlength="500"[^>]+required}, 'contributor apply form enforces application response length');
like($apply_html, qr{Contact details}, 'contributor apply form groups contact fields');
like($apply_html, qr{Sample images}, 'contributor apply form groups sample uploads');
like($apply_html, qr{data-character-counter}, 'contributor apply form includes response character counter');
like($apply_html, qr{data-upload-preview}, 'contributor apply form includes upload preview hooks');
unlike($apply_html, qr{name="gender"}, 'contributor apply form does not ask for gender');
unlike($apply_html, qr{name="photo"}, 'contributor apply form does not ask for portrait');

{
    no warnings 'redefine';
    local *DesertCMS::ContributorRequests::send_request_notification = sub { return (1, 'sent') };
    my $post = bless {
        method => 'POST',
        path   => '/forms/contributor-request',
        form   => {
            name => 'Riley Stone',
            email => 'riley@example.com',
            phone => '555-0102',
            age => 33,
            application_text => 'Riley wants to join the archive to contribute careful images, reliable captions, and a consistent local perspective for future readers, editors, and local historians.',
            website => '',
        },
        uploads => {},
        ip_address => '203.0.113.12',
        user_agent => 'ContributorRequestTest/1.0',
    }, 'DesertCMS::HTTP';
    my $post_response = _capture_response(sub { $app->_dispatch_forms($post) });
    like($post_response, qr/Status: 303 See Other/, 'contributor request POST redirects after successful submit');
    like($post_response, qr{Location: /forms/contributor-request/received}, 'contributor request POST redirects to receipt route');

    my $get = bless {
        method => 'GET',
        path => '/forms/contributor-request/received',
        form => {},
        query => {},
        uploads => {},
    }, 'DesertCMS::HTTP';
    my $receipt_response = _capture_response(sub { $app->_dispatch_forms($get) });
    like($receipt_response, qr/Status: 200 OK/, 'contributor request receipt route renders');
    like($receipt_response, qr/Contributor Request Received/, 'receipt route shows confirmation title');

    my $invalid_post = bless {
        method => 'POST',
        path   => '/forms/contributor-request',
        form   => {
            name => 'Riley Stone',
            email => '',
            phone => '555-0102',
            age => 33,
            application_text => 'Riley wants to join the archive to contribute careful images, reliable captions, and a consistent local perspective for future readers, editors, and local historians.',
            website => '',
        },
        uploads => {},
        ip_address => '203.0.113.13',
        user_agent => 'ContributorRequestTest/1.0',
    }, 'DesertCMS::HTTP';
    my $invalid_response = _capture_response(sub { $app->_dispatch_forms($invalid_post) });
    like($invalid_response, qr/Status: 400 Bad Request/, 'invalid contributor request returns form error status');
    like($invalid_response, qr/Please enter a valid email address\./, 'invalid contributor request shows friendly email message');
    like($invalid_response, qr{name="name" value="Riley Stone"}, 'invalid contributor request preserves text fields');
}

my $completed = $requests->complete_profile(
    token => $approved->{profile_token},
    bio => $profile_bio,
    photo => _upload('alex.jpg', 'image/jpeg', $profile_image_bytes),
    showcase_uploads => [
        _upload('profile-one.jpg', 'image/jpeg', 'profile one bytes'),
        _upload('profile-two.png', 'image/png', 'profile two bytes'),
    ],
);
ok($completed->{profile_completed_at}, 'profile completion timestamp is stored');
is($completed->{bio}, $profile_bio, 'profile completion stores the public bio');
my $public_profile_file = File::Spec->catfile($root, 'public', 'assets', 'contributors', 'alexs.jpg');
ok(-f $public_profile_file, 'completed profile photo is published');
isnt(_read_binary($public_profile_file), $profile_image_bytes, 'published profile photo is a generated derivative');
is(@{DesertCMS::ContributorRequests::showcase_files($completed)}, 2, 'profile samples are recorded after completion');
$content->rebuild_all;
$contributors_html = _read(File::Spec->catfile($root, 'public', 'contributors', 'index.html'));
like($contributors_html, qr{Alex Smith}, 'contributors page lists completed approved contributor');
like($contributors_html, qr{alexs\.desertarchives\.com}, 'contributors page links completed contributor domain');
like($contributors_html, qr{/assets/contributors/alexs\.jpg}, 'contributors page uses completed profile image');

$db->dbh->do(
    q{
        INSERT INTO archived_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             archive_path, archive_filename, archive_bytes, details_json, archived_at)
        VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    'alexs',
    'alexs.desertarchives.com',
    'Alex Smith',
    'Alex',
    'S',
    'alex.smith@example.com',
    "$root/backups/alex-06302026.tar.gz",
    'alex-06302026.tar.gz',
    1024,
    '{}',
    time
);
$db->dbh->do(
    q{
        UPDATE contributor_requests
        SET site_id = '',
            domain = '',
            public_profile_image_path = '',
            updated_at = ?
        WHERE id = ?
    },
    undef,
    time,
    $submitted->{id}
);
$contributors_admin_html = _capture_response(sub {
    $app->_settings_contributors_page(_request(), { username => 'admin', user_id => 1 }, 'contributors-session');
});
like($contributors_admin_html, qr/Alex Smith.*approved - archived site/s, 'archived approved contributor request is not shown as active');
like($contributors_admin_html, qr/0 approved active\/disabled, 1 archived/s, 'contributors summary separates archived approved requests');

my $sitemap_xml = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
like($sitemap_xml, qr{<loc>https://desertarchives\.com/contributors/</loc>}, 'contributors page is added to sitemap');

my $contrib_root = "$root/contributor-site";
make_path("$contrib_root/public/assets/media", "$contrib_root/originals", "$contrib_root/backups", "$contrib_root/themes", "$contrib_root/admin-assets", "$contrib_root/data");
my $contrib_config_path = "$contrib_root/desertcms.conf";
open my $cfh, '>', $contrib_config_path or die "cannot write $contrib_config_path: $!";
print {$cfh} <<"CONF";
site_name = Alex Contributor Site
site_url = https://alexs.desertarchives.com
data_dir = $contrib_root/data
db_path = $contrib_root/data/desertcms.sqlite
app_secret_file = $contrib_root/data/app_secret
public_root = $contrib_root/public
originals_dir = $contrib_root/originals
backup_dir = $contrib_root/backups
theme_dir = $repo/themes
admin_asset_dir = $contrib_root/admin-assets
secure_cookies = 0
contributor_site_id = alexs
contributor_domain = alexs.desertarchives.com
contributor_owner_name = Alex Smith
contributor_owner_email = alex.smith\@example.com
CONF
close $cfh;

my $contrib_config = DesertCMS::Config->load($contrib_config_path);
my $contrib_db = DesertCMS::DB->new(config => $contrib_config);
$contrib_db->migrate;
DesertCMS::Settings::set_many($contrib_config, $contrib_db, {
    contributor_post_quota => 1,
    contributor_page_quota => 2,
    contributor_media_quota_mb => 1,
});
my $contrib_content = DesertCMS::Content->new(config => $contrib_config, db => $contrib_db);
my $contrib_post = $contrib_content->save(
    type => 'post',
    title => 'Contributor Field Note',
    slug => 'contributor-field-note',
    excerpt => 'A public note from the contributor site.',
    body_text => 'This public contributor post should be surfaced on the master posts page.',
);
$contrib_content->publish(id => $contrib_post->{id});
eval {
    $contrib_content->save(
        type => 'post',
        title => 'Second Contributor Note',
        slug => 'second-contributor-note',
        body_text => 'This post should exceed the contributor post quota.',
    );
};
like($@, qr/Post quota reached/, 'contributor post quota is enforced locally');
my $hash = 'c' x 64;
$contrib_db->dbh->do(
    q{
        INSERT INTO media_assets
            (original_name, storage_path, public_path, alt_text, seo_title, seo_description,
             owner_site_id, owner_domain, owner_display_name, owner_email,
             uploaded_by_user_id, uploaded_by_username, uploaded_by_email,
             mime_type, width, height, bytes, checksum_sha256, created_at)
        VALUES
            ('contributor-showcase.jpg', ?, ?, 'Contributor Showcase Image', 'Contributor Showcase Title',
             'A public image from the contributor site.', 'alexs', 'alexs.desertarchives.com', 'Alex Smith',
             'alex.smith@example.com', NULL, 'alex', 'alex.smith@example.com',
             'image/jpeg', 1200, 800, 20, ?, ?)
    },
    undef,
    "$contrib_root/originals/contributor-showcase.jpg",
    "/assets/media/$hash.jpg",
    $hash,
    time
);
$db->dbh->do(
    q{
        UPDATE contributor_sites
        SET status = 'active',
            config_path = ?,
            public_root = ?,
            data_dir = ?,
            updated_at = ?
        WHERE site_id = 'alexs'
    },
    undef,
    $contrib_config_path,
    "$contrib_root/public",
    "$contrib_root/data",
    time
);
$db->dbh->do(
    q{
        INSERT INTO contributor_sites
            (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
             status, config_path, data_dir, public_root, created_at, updated_at)
        VALUES
            ('desertcms', 'desertcms.com', 'DesertCMS', '', '', '',
             'active', ?, ?, ?, ?, ?)
    },
    undef,
    $contrib_config_path,
    "$contrib_root/data",
    "$contrib_root/public",
    time,
    time
);
DesertCMS::Settings::set_many($config, $db, { module_gallery_enabled => 1 });
$content->rebuild_all;

my $federation = DesertCMS::Federation->new(config => $config, db => $db);
my $showcase_html = _read(File::Spec->catfile($root, 'public', 'showcase', 'index.html'));
unlike($showcase_html, qr{https://alexs\.desertarchives\.com/assets/media/$hash\.jpg}, 'platform Showcase holds contributor assets for review');
unlike($showcase_html, qr{https://desertcms\.com/assets/media/$hash\.jpg}, 'platform Showcase excludes standalone master-domain rows');
my $posts_html = _read(File::Spec->catfile($root, 'public', 'posts', 'index.html'));
unlike($posts_html, qr{https://alexs\.desertarchives\.com/posts/contributor-field-note/}, 'master posts index holds contributor posts for review');
unlike($posts_html, qr{https://desertcms\.com/posts/contributor-field-note/}, 'master posts index excludes standalone master-domain rows');
my $pending_rows = $federation->rows(status => 'pending', limit => 20);
my ($pending_media) = grep { $_->{source_type} eq 'media' && $_->{source_site_id} eq 'alexs' } @{$pending_rows};
my ($pending_post) = grep { $_->{source_type} eq 'post' && $_->{source_site_id} eq 'alexs' } @{$pending_rows};
ok($pending_media, 'federated review queues contributor media');
ok($pending_post, 'federated review queues contributor posts');
$federation->review(id => $pending_media->{id}, status => 'approved', reviewed_by_user_id => undef);
$federation->review(id => $pending_post->{id}, status => 'approved', reviewed_by_user_id => undef);
$content->rebuild_all;
$showcase_html = _read(File::Spec->catfile($root, 'public', 'showcase', 'index.html'));
like($showcase_html, qr{https://alexs\.desertarchives\.com/assets/media/$hash\.jpg}, 'platform Showcase renders approved contributor public assets');
like($showcase_html, qr{Contributor Showcase Title}, 'platform Showcase keeps approved contributor asset title');
like($showcase_html, qr{<img src="https://alexs\.desertarchives\.com/assets/media/\Q$hash\E\.jpg" alt="Contributor Showcase Image" loading="lazy" decoding="async" width="1200" height="800" class="public-media-img">}, 'platform Showcase uses shared contained media markup for contributor artwork');
$posts_html = _read(File::Spec->catfile($root, 'public', 'posts', 'index.html'));
like($posts_html, qr{https://alexs\.desertarchives\.com/posts/contributor-field-note/}, 'master posts index links approved contributor posts');
like($posts_html, qr{Contributor Field Note}, 'master posts index surfaces approved contributor post title');

$contrib_db->dbh->do('UPDATE media_assets SET deleted_at = ? WHERE id = ?', undef, time, $pending_media->{source_id});
$contrib_db->dbh->do("UPDATE content_items SET status = 'draft' WHERE id = ?", undef, $pending_post->{source_id});
$content->rebuild_all;
$showcase_html = _read(File::Spec->catfile($root, 'public', 'showcase', 'index.html'));
unlike($showcase_html, qr{https://alexs\.desertarchives\.com/assets/media/$hash\.jpg}, 'platform Showcase hides approved contributor asset when source is deleted');
$posts_html = _read(File::Spec->catfile($root, 'public', 'posts', 'index.html'));
unlike($posts_html, qr{https://alexs\.desertarchives\.com/posts/contributor-field-note/}, 'master posts index hides approved contributor post when source is unpublished');
my ($missing_count) = $db->dbh->selectrow_array(
    q{
        SELECT COUNT(*)
        FROM federated_content_reviews
        WHERE source_site_id = 'alexs'
          AND source_missing_at IS NOT NULL
    }
);
is($missing_count, 2, 'federated review records missing contributor source rows');

$contrib_db->dbh->do('UPDATE media_assets SET deleted_at = NULL WHERE id = ?', undef, $pending_media->{source_id});
$contrib_db->dbh->do("UPDATE content_items SET status = 'published' WHERE id = ?", undef, $pending_post->{source_id});
$content->rebuild_all;
$showcase_html = _read(File::Spec->catfile($root, 'public', 'showcase', 'index.html'));
like($showcase_html, qr{https://alexs\.desertarchives\.com/assets/media/$hash\.jpg}, 'platform Showcase restores approved contributor asset when source returns');
$posts_html = _read(File::Spec->catfile($root, 'public', 'posts', 'index.html'));
like($posts_html, qr{https://alexs\.desertarchives\.com/posts/contributor-field-note/}, 'master posts index restores approved contributor post when source returns');

$db->dbh->do(
    q{
        UPDATE contributor_sites
        SET allow_master_gallery = 0,
            allow_master_posts = 0,
            updated_at = ?
        WHERE site_id = 'alexs'
    },
    undef,
    time
);
$content->rebuild_all;
$showcase_html = _read(File::Spec->catfile($root, 'public', 'showcase', 'index.html'));
unlike($showcase_html, qr{https://alexs\.desertarchives\.com/assets/media/$hash\.jpg}, 'platform Showcase honors disabled contributor asset surfacing');
$posts_html = _read(File::Spec->catfile($root, 'public', 'posts', 'index.html'));
unlike($posts_html, qr{https://alexs\.desertarchives\.com/posts/contributor-field-note/}, 'master posts index honors disabled contributor post surfacing');

my $grant = $sites->grant_access(site_id => 'alexs', email => 'editor@example.com');
is($grant->{username}, 'editor', 'master can grant contributor site access by email');
is($grant->{sent}, 0, 'grant reports unsent email when Postmark token is not configured');
my $granted_user = $contrib_db->dbh->selectrow_hashref(
    'SELECT username, email, role, force_password_change, disabled_at FROM admin_users WHERE email = ?',
    undef,
    'editor@example.com'
);
is($granted_user->{username}, 'editor', 'granted contributor admin is created in contributor site database');
is($granted_user->{role}, 'contributor', 'granted contributor admin has scoped contributor role');
is($granted_user->{force_password_change}, 1, 'granted contributor admin must change temporary password');
ok(!defined $granted_user->{disabled_at}, 'granted contributor admin is active');

my $denied = $requests->submit(
    name => 'Jordan Lee',
    email => 'jordan@example.com',
    phone => '555-0101',
    age => 28,
    application_text => 'Jordan submits a strong application for testing the denial path with enough detail to satisfy the contributor request response limit and keep the review process realistic in the local test suite.',
    application_showcase_uploads => [ _upload('showcase.webp', 'image/webp', 'showcase bytes') ],
    request => {
        ip_address => '203.0.113.11',
        user_agent => 'ContributorRequestTest/1.0',
    },
);
$requests->deny(id => $denied->{id}, note => 'Denied for test');
my $denied_row = $requests->request_by_id($denied->{id});
is($denied_row->{status}, 'denied', 'request can be denied');
my ($denied_sites) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM contributor_sites WHERE owner_email = ?', undef, 'jordan@example.com');
is($denied_sites, 0, 'denied request does not create a contributor site');

done_testing;

sub _upload {
    my ($filename, $mime, $content) = @_;
    return {
        filename => $filename,
        content_type => $mime,
        content => $content,
    };
}

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _request {
    my (%params) = @_;
    return bless {
        method => 'GET',
        path   => '/admin/settings/contributors',
        form   => {},
        query  => \%params,
        uploads => {},
    }, 'DesertCMS::HTTP';
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

sub _read_binary {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
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
