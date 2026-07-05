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
use DesertCMS::Bookings;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::Directory;
use DesertCMS::HTTP;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Testimonials;

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public/assets/media", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
_write($config_path, <<"CONF");
site_name = Testimonials Test
site_url = https://testimonials.example.test
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
    body_text => 'Testimonials home.',
);
$content->publish(id => $home->{id});

DesertCMS::Settings::set_many($config, $db, {
    module_testimonials_enabled => 1,
    module_directory_enabled    => 1,
    module_bookings_enabled     => 1,
    testimonials_title          => 'Client Stories',
    testimonials_intro          => 'Reviews from clients, members, customers, and community partners.',
    testimonials_submissions_enabled => 1,
});

my $settings = DesertCMS::Settings::all($config, $db);
ok(DesertCMS::Modules::enabled($settings, 'testimonials'), 'testimonials feature can be enabled independently');
my $catalog = DesertCMS::Modules::catalog($settings, config => $config);
like(_module_catalog_text($catalog), qr/Testimonials \/ Reviews.*approved testimonials, optional ratings, related services or directory entries/s, 'feature catalog describes Testimonials / Reviews');

my $directory = DesertCMS::Directory->new(config => $config, db => $db);
my $entry = $directory->save_entry(
    title   => 'Civic Arts Center',
    slug    => 'civic-arts-center',
    kind    => 'place',
    status  => 'published',
    summary => 'A venue and resource.',
);
my $bookings = DesertCMS::Bookings->new(config => $config, db => $db);
my $service = $bookings->save_service(
    title             => 'Consultation Session',
    slug              => 'consultation-session',
    service_kind      => 'consultation',
    status            => 'published',
    summary           => 'A planning session.',
    availability_text => 'Weekdays by request.',
);

my $testimonials = DesertCMS::Testimonials->new(config => $config, db => $db);
my $published = $testimonials->save_testimonial(
    author_name                => 'Casey Client',
    author_title               => 'Program Director',
    organization               => 'Civic Partner',
    slug                       => 'casey-client',
    status                     => 'published',
    quote                      => 'The site made our resources easier to find and trust.',
    body                       => 'Visitors knew where to start.',
    rating                     => 5,
    source_type                => 'client',
    related_directory_entry_id => $entry->{id},
    related_booking_service_id => $service->{id},
    featured                   => 1,
);
ok($published->{id}, 'published testimonial is saved');
is($published->{rating}, 5, 'testimonial stores optional rating');
is($published->{related_directory_title}, 'Civic Arts Center', 'testimonial joins related directory title');
is($published->{related_booking_title}, 'Consultation Session', 'testimonial joins related booking title');

$content->rebuild_all;
ok(-f File::Spec->catfile($root, 'public', 'testimonials', 'index.html'), 'testimonials index is generated');
ok(-f File::Spec->catfile($root, 'public', 'testimonials', 'submit', 'index.html'), 'testimonial submission page is generated when enabled');

my $home_html = _read(File::Spec->catfile($root, 'public', 'index.html'));
like($home_html, qr{href="/testimonials/"}, 'enabled Testimonials appears in public navigation');
like($home_html, qr{Client Stories}, 'public navigation uses configured Testimonials title');

my $testimonials_html = _read(File::Spec->catfile($root, 'public', 'testimonials', 'index.html'));
like($testimonials_html, qr{Client Stories}, 'testimonials index renders configured title');
like($testimonials_html, qr{The site made our resources easier to find and trust}, 'testimonials index renders approved quote');
like($testimonials_html, qr{5 stars}, 'testimonials index renders rating label');
like($testimonials_html, qr{Civic Partner}, 'testimonials index renders byline organization');
like($testimonials_html, qr{Related to Civic Arts Center}, 'testimonials index renders related directory link label');
like($testimonials_html, qr{Share a testimonial}, 'testimonials index links submission page');

my $submit_html = _read(File::Spec->catfile($root, 'public', 'testimonials', 'submit', 'index.html'));
like($submit_html, qr{Submit for review}, 'static submission page renders form');
like($submit_html, qr{Rating optional}, 'static submission page renders optional rating field');

my $sitemap = _read(File::Spec->catfile($root, 'public', 'sitemap.xml'));
like($sitemap, qr{https://testimonials\.example\.test/testimonials/</loc>}, 'sitemap includes testimonials index');
like($sitemap, qr{https://testimonials\.example\.test/testimonials/submit/</loc>}, 'sitemap includes testimonials submission page');

my $app = DesertCMS::App->new;
my $public_index = _capture_response(sub {
    $app->_dispatch_testimonials(_testimonial_request('/testimonials'));
});
like($public_index, qr{Client Stories}, 'dynamic /testimonials route renders public page');

my ($before_honeypot) = $db->dbh->selectrow_array(q{SELECT COUNT(*) FROM testimonials});
my $honeypot = _capture_response(sub {
    $app->_dispatch_testimonials(_testimonial_request('/testimonials/submit', 'POST', {
        author_name => 'Bot Reviewer',
        quote       => 'Ignore this.',
        website     => 'https://spam.example.test',
    }));
});
like($honeypot, qr{received for review}, 'honeypot submission gets neutral success response');
my ($after_honeypot) = $db->dbh->selectrow_array(q{SELECT COUNT(*) FROM testimonials});
is($after_honeypot, $before_honeypot, 'honeypot submission does not create a testimonial');

my $submit_response = _capture_response(sub {
    $app->_dispatch_testimonials(_testimonial_request('/testimonials/submit', 'POST', {
        author_name  => 'Morgan Member',
        author_title => 'Member',
        organization => 'Local Group',
        email        => 'morgan@example.test',
        quote        => 'The member resources are exactly where we need them.',
        body         => 'The new hub saved time.',
        rating       => 4,
    }));
});
like($submit_response, qr{received for review}, 'public testimonial submission confirms moderation');
my ($pending_count) = $db->dbh->selectrow_array(
    q{SELECT COUNT(*) FROM testimonials WHERE status = 'pending' AND source_type = 'public_submission'}
);
is($pending_count, 1, 'public submission creates pending testimonial');

my $pending = $db->dbh->selectrow_hashref(
    q{SELECT * FROM testimonials WHERE status = 'pending' AND source_type = 'public_submission' LIMIT 1}
);
ok($pending->{ip_hash}, 'public submission stores hashed IP metadata');
ok($pending->{user_agent_hash}, 'public submission stores hashed user-agent metadata');
$testimonials->publish_testimonial($pending->{id});
is($testimonials->get($pending->{id})->{status}, 'published', 'pending testimonial can be approved');
my $rejected = $testimonials->save_testimonial(
    author_name => 'Rejected Reviewer',
    status      => 'pending',
    quote       => 'Do not show publicly.',
);
$testimonials->reject_testimonial($rejected->{id});
is($testimonials->get($rejected->{id})->{status}, 'rejected', 'testimonial can be rejected');
$testimonials->archive_testimonial($published->{id});
is($testimonials->get($published->{id})->{status}, 'archived', 'testimonial can be archived');

my $admin_html = _capture_response(sub {
    $app->_module_testimonials_settings_page(undef, { username => 'admin', role => 'owner' }, 'testimonials-session');
});
like($admin_html, qr/<h1>Testimonials \/ Reviews<\/h1>/, 'admin Testimonials surface renders');
like($admin_html, qr/module-section-nav" aria-label="Testimonials setup sections".*href="\#module-settings">Settings<\/a>.*href="\#module-testimonials">Testimonials<\/a>/s, 'admin Testimonials surface exposes local section navigation');
like($admin_html, qr{<code>/testimonials/</code>}, 'admin Testimonials surface shows public path');
like($admin_html, qr{Morgan Member}, 'admin Testimonials table lists public submissions');
like($admin_html, qr{Export CSV}, 'admin Testimonials surface exposes CSV export');
like($admin_html, qr{Approve}, 'admin Testimonials surface exposes approval action');
like($admin_html, qr/content-table compact-table admin-card-table/, 'admin Testimonials table uses responsive card markup');
like($admin_html, qr/data-label="Testimonial".*data-label="Actions"/s, 'admin Testimonials rows expose mobile card labels');
my $testimonial_form_html = _capture_response(sub {
    $app->_testimonial_form(undef, { username => 'admin', role => 'owner' }, 'testimonials-session', $published->{id});
});
like($testimonial_form_html, qr/module-section-nav" aria-label="Testimonial editor sections".*href="\#testimonial-content">Testimonial<\/a>.*href="\#testimonial-review">Review State<\/a>.*href="\#testimonial-related">Related Surface<\/a>.*href="\#testimonial-display">Display<\/a>/s, 'admin Testimonial editor exposes local section navigation');
like($testimonial_form_html, qr/id="testimonial-content".*id="testimonial-review".*id="testimonial-related".*id="testimonial-display"/s, 'admin Testimonial editor section navigation targets stable form anchors');

my $csv = $testimonials->csv_export;
like($csv, qr/Casey Client/, 'testimonial CSV export includes manual testimonial');
like($csv, qr/Morgan Member/, 'testimonial CSV export includes public submission');
like($csv, qr/Civic Arts Center/, 'testimonial CSV export includes related directory title');

my $contrib_config_path = "$root/contributor.conf";
_write($contrib_config_path, <<"CONF");
site_name = Contributor Testimonials
site_url = https://testimonials-site.example.test
data_dir = $root/data
db_path = $root/data/desertcms.sqlite
app_secret_file = $root/data/app_secret
public_root = $root/public
originals_dir = $root/originals
backup_dir = $root/backups
theme_dir = $repo/themes
admin_asset_dir = $root/admin-assets
contributor_site_id = testimonials-site
contributor_domain = testimonials-site.example.test
secure_cookies = 0
CONF
my $contrib_config = DesertCMS::Config->load($contrib_config_path);
DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({
        testimonials => 0,
        directory    => 1,
        bookings     => 1,
    }),
    module_testimonials_enabled => 1,
});
$settings = DesertCMS::Settings::all($config, $db);
my $feature_catalog = DesertCMS::Modules::catalog($settings, config => $contrib_config);
my %feature_by_key = map { $_->{key} => $_ } @{$feature_catalog};
ok($feature_by_key{testimonials}{locked_by_plan}, 'contributor feature catalog can lock Testimonials by plan');
ok(!$feature_by_key{testimonials}{enabled}, 'locked Testimonials is not effectively enabled');

local $app->{config} = $contrib_config;
my $feature_catalog_html = _capture_response(sub {
    $app->_settings_modules_page(undef, { username => 'admin', role => 'owner' }, 'modules-session');
});
like($feature_catalog_html, qr/data-feature-key="testimonials"[^>]+data-feature-locked-by-plan="1"/, 'feature catalog renders Testimonials locked-by-plan state');
unlike($feature_catalog_html, qr/master CMS|contributor CMS/, 'contributor feature catalog avoids backend CMS terminology');

DesertCMS::Settings::set_many($config, $db, {
    contributor_plan_features_json => DesertCMS::Modules::features_json({ testimonials => 1 }),
    module_testimonials_enabled => 0,
});
$content->rebuild_all;
ok(!-e File::Spec->catfile($root, 'public', 'testimonials', 'index.html'), 'disabled Testimonials removes generated index');

done_testing;

sub _testimonial_request {
    my ($path, $method, $form) = @_;
    return bless {
        method     => $method || 'GET',
        path       => $path || '/testimonials',
        host       => 'testimonials.example.test',
        form       => $form || {},
        query      => $form || {},
        ip_address => '127.0.0.1',
        user_agent => 'testimonials-test',
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
