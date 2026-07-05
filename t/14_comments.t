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

use DesertCMS::Comments;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Comment Test
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

my $content = DesertCMS::Content->new(config => $config, db => $db);
my $comments = DesertCMS::Comments->new(config => $config, db => $db);

my $post = $content->save(
    type => 'post',
    title => 'Commentable Story',
    slug => 'commentable-story',
    excerpt => 'A story with a conversation.',
    body_json => encode_json([
        { type => 'text', text => 'A place-based story.' },
    ]),
);
$content->publish(id => $post->{id});

my $page = $content->save(
    type => 'page',
    title => 'Static Page',
    slug => 'static-page',
    body_text => 'No public comments here.',
);
$content->publish(id => $page->{id});

my $request_a = bless {
    forwarded_for => '',
    ip_address    => '203.0.113.12',
    user_agent    => 'comment-test-a',
}, 'RequestStub';
my $request_b = bless {
    forwarded_for => '',
    ip_address    => '203.0.113.44',
    user_agent    => 'comment-test-b',
}, 'RequestStub';

my $empty = $comments->thread(content_id => $post->{id});
is($empty->{count}, 0, 'new post has an empty comment thread');
is($empty->{post}{url}, '/posts/commentable-story/', 'thread includes public post URL');

my $created = $comments->create(
    content_id      => $post->{id},
    author_name     => 'Field Reader',
    body            => "First comment\n\nWith a second paragraph.",
    commenter_token => 'a' x 64,
    request         => $request_a,
);
ok($created->{comment}{id}, 'creates root comment');
is($created->{comment}{author_name}, 'Field Reader', 'stores comment display name');
like($created->{comment}{body}, qr/second paragraph/, 'stores comment body');
ok(!$created->{token}, 'does not replace a valid browser token');

my $reply = $comments->create(
    content_id      => $post->{id},
    parent_id       => $created->{comment}{id},
    author_name     => 'Archivist',
    body            => 'Reply from another visitor.',
    commenter_token => 'b' x 64,
    request         => $request_b,
);
is($reply->{comment}{parent_id}, $created->{comment}{id}, 'creates reply against parent comment');

my $thread = $comments->thread(content_id => $post->{id});
is($thread->{count}, 2, 'thread returns root comment and reply');
is($thread->{comments}[1]{parent_id}, $created->{comment}{id}, 'thread preserves reply parent');

my $notices_a = $comments->notifications(commenter_token => 'a' x 64);
is(scalar @{$notices_a->{replies}}, 1, 'original commenter sees reply notification');
is($notices_a->{replies}[0]{post_title}, 'Commentable Story', 'notification includes post title');
is($notices_a->{replies}[0]{post_url}, '/posts/commentable-story/#comment-' . $reply->{comment}{id}, 'notification links to reply anchor');

my $notices_b = $comments->notifications(commenter_token => 'b' x 64);
is(scalar @{$notices_b->{replies}}, 0, 'reply author does not see their own reply as a notification');

my $generated = $comments->create(
    content_id      => $post->{id},
    author_name     => '',
    body            => 'Tokenless visitor gets a server fallback token.',
    commenter_token => 'invalid',
    request         => $request_b,
);
like($generated->{token}, qr/\A[0-9a-f]{64}\z/, 'invalid browser token receives a generated fallback token');
is($generated->{comment}{author_name}, 'Anonymous', 'blank comment name falls back to anonymous');

my $admin_before = $comments->admin_thread(content_id => $post->{id});
is($admin_before->{count}, 3, 'admin thread sees visible comments on the post');
ok((grep { $_->{id} == $created->{comment}{id} && $_->{status} eq 'visible' } @{$admin_before->{comments}}), 'admin thread includes visible status');
is($comments->counts_for_posts($post->{id})->{$post->{id}}, 3, 'post list count includes visible comments before removal');

my $deleted = $comments->delete_comment(id => $created->{comment}{id});
is($deleted->{content_id}, $post->{id}, 'delete returns parent post id for redirect');

my $thread_after_delete = $comments->thread(content_id => $post->{id});
is($thread_after_delete->{count}, 1, 'public thread only returns remaining visible comments after removal');
ok(!(grep { $_->{id} == $created->{comment}{id} } @{$thread_after_delete->{comments}}), 'deleted root comment is absent from public thread');
ok(!(grep { $_->{id} == $reply->{comment}{id} } @{$thread_after_delete->{comments}}), 'reply below deleted comment is absent from public thread');
unlike(join("\n", map { $_->{body} } @{$thread_after_delete->{comments}}), qr/Comment Removed by Author|second paragraph|Reply from another visitor/, 'public thread has no deleted placeholder or deleted bodies');

my $admin_after = $comments->admin_thread(content_id => $post->{id});
is($admin_after->{count}, 1, 'admin thread only returns remaining visible comments after removal');
ok(!(grep { $_->{id} == $created->{comment}{id} } @{$admin_after->{comments}}), 'deleted root comment is absent from admin thread');
ok(!(grep { $_->{id} == $reply->{comment}{id} } @{$admin_after->{comments}}), 'reply below deleted comment is absent from admin thread');
is($comments->counts_for_posts($post->{id})->{$post->{id}}, 1, 'post list count excludes deleted comments and cascaded replies');

eval {
    $comments->create(
        content_id      => $post->{id},
        parent_id       => $created->{comment}{id},
        author_name     => 'Late Reader',
        body            => 'Cannot reply to a removed comment.',
        commenter_token => 'd' x 64,
        request         => $request_a,
    );
};
like($@, qr/parent comment not found/, 'rejects replies to deleted comments');

eval {
    $comments->create(
        content_id      => $page->{id},
        author_name     => 'Reader',
        body            => 'Pages are not comment targets yet.',
        commenter_token => 'c' x 64,
        request         => $request_a,
    );
};
like($@, qr/post not found/, 'rejects comments on pages');

my $post_html = _read(File::Spec->catfile($root, 'public', 'posts', 'commentable-story', 'index.html'));
like($post_html, qr/data-comments data-rating data-content-id="$post->{id}"/, 'published post includes integrated comments and rating mount');
ok(index($post_html, 'data-comment-form') >= 0 && index($post_html, 'data-comment-form') < index($post_html, 'data-comments-list'), 'comment form appears before comments list');
like($post_html, qr{/assets/comments\.js}, 'published post loads comments script');

my $page_html = _read(File::Spec->catfile($root, 'public', 'static-page', 'index.html'));
unlike($page_html, qr/data-comments/, 'published page does not include comments mount');

my ($raw_ip_count) = $db->dbh->selectrow_array("SELECT COUNT(*) FROM comments WHERE ip_hash LIKE '203.%'");
is($raw_ip_count, 0, 'comments table does not store raw IP addresses');

done_testing;

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}
