use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP qw(encode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::Ratings;

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Rating Test
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
trusted_proxy_cidrs = 10.0.0.2/32
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

my $content = DesertCMS::Content->new(config => $config, db => $db);
my $ratings = DesertCMS::Ratings->new(config => $config, db => $db);

my $post = $content->save(
    type => 'post',
    title => 'Rated Story',
    slug => 'rated-story',
    excerpt => 'A story with reader ratings.',
    body_json => encode_json([
        { type => 'text', text => 'A place-based story.' },
    ]),
);
$content->publish(id => $post->{id});

my $request_a = bless {
    forwarded_for => '',
    ip_address    => '203.0.113.12',
    user_agent    => 'rating-test-a',
}, 'RequestStub';
my $request_a_with_port = bless {
    forwarded_for => '203.0.113.12:443',
    ip_address    => '10.0.0.2',
    user_agent    => 'rating-test-a',
}, 'RequestStub';
my $request_b = bless {
    forwarded_for => '',
    ip_address    => '198.51.100.44',
    user_agent    => 'rating-test-b',
}, 'RequestStub';

my $empty = $ratings->summary(content_id => $post->{id}, request => $request_a);
is($empty->{count}, 0, 'new post starts with no ratings');
is($empty->{average}, 0, 'new post starts with zero average');

my $first = $ratings->vote(content_id => $post->{id}, rating => 5, request => $request_a);
is($first->{count}, 1, 'first visitor rating creates one vote');
is($first->{average}, 5, 'first visitor rating sets average');
is($first->{viewer_rating}, 5, 'summary returns current visitor rating');

my $updated = $ratings->vote(content_id => $post->{id}, rating => 3, request => $request_a_with_port);
is($updated->{count}, 1, 'same IP with a forwarded port updates instead of duplicating');
is($updated->{average}, 3, 'updated same-IP vote changes average');
is($updated->{viewer_rating}, 3, 'same visitor sees updated rating');

my $second = $ratings->vote(content_id => $post->{id}, rating => 5, request => $request_b);
is($second->{count}, 2, 'different visitor IP creates another vote');
is($second->{average}, 4, 'average includes both unique IP votes');

my ($raw_ip_count) = $db->dbh->selectrow_array("SELECT COUNT(*) FROM post_ratings WHERE ip_hash LIKE '203.%'");
is($raw_ip_count, 0, 'ratings table does not store raw IP addresses');

my $post_html = _read(File::Spec->catfile($root, 'public', 'posts', 'rated-story', 'index.html'));
like($post_html, qr/data-comments data-rating data-content-id="$post->{id}"/, 'published post includes integrated comment rating mount');
unlike($post_html, qr/class="rating-section"/, 'published post no longer renders a separate rating section');
like($post_html, qr{/assets/comments\.js}, 'published post uses shared comment and rating script');

my $page = $content->save(
    type => 'page',
    title => 'Unrated Page',
    slug => 'unrated-page',
    body_text => 'No ratings on pages.',
);
$content->publish(id => $page->{id});

eval {
    $ratings->vote(content_id => $page->{id}, rating => 5, request => $request_a);
};
like($@, qr/post not found/, 'rejects ratings on pages');

done_testing;

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}
