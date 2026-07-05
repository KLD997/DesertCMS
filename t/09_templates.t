use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::Renderer;

{
    package Local::TemplateRequest;
    sub new {
        my ($class, $form) = @_;
        return bless { form => $form || {} }, $class;
    }
    sub param {
        my ($self, $key) = @_;
        return $self->{form}{$key};
    }
}

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/themes", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Template Test
site_url = http://localhost
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
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;

my $content = DesertCMS::Content->new(config => $config, db => $db);
my $app = DesertCMS::App->new;
$app->{db}->migrate;
my $legacy_template_ts = time;
$app->{db}->dbh->do(
    q{
        INSERT INTO page_templates
            (name, slug, description, body_json, system_default, created_at, updated_at)
        VALUES
            ('Photo Gallery', 'photo-gallery',
             'A gallery-style page with image placeholders and captions ready to fill.',
             '[]', 1, ?, ?)
    },
    undef,
    $legacy_template_ts,
    $legacy_template_ts
);
$app->_ensure_default_templates;
$app->_ensure_default_sections;

my ($builder_sections_table) = $app->{db}->dbh->selectrow_array(
    q{SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'builder_sections'}
);
is($builder_sections_table, 'builder_sections', 'migration creates builder sections table');

my $templates = $app->_template_rows;
ok(@{$templates} >= 4, 'seeds starter templates');
ok((grep { $_->{slug} eq 'homepage' } @{$templates}), 'seeds homepage template');
ok((grep { $_->{slug} eq 'about-us' } @{$templates}), 'seeds about us template');
ok((grep { $_->{slug} eq 'contact-us' } @{$templates}), 'seeds contact us template');
ok((grep { $_->{slug} eq 'media-showcase' } @{$templates}), 'seeds media showcase template');
ok(!(grep { $_->{slug} eq 'photo-gallery' } @{$templates}), 'migrates legacy photo gallery template slug');
ok(!(grep { $_->{slug} eq 'media-gallery' } @{$templates}), 'migrates legacy media gallery template slug');

my $body_json = encode_json([
    { type => 'image', src => '', alt => '', caption => 'Placeholder', layout => 'full', size => 'large' },
    { type => 'image_text', src => '', alt => '', caption => '', text => 'Text beside a future image.', image_side => 'right' },
    { type => 'link', url => 'javascript:alert(1)', label => 'Unsafe URL becomes blank', description => 'Kept as a placeholder.' },
    { type => 'social', platform => 'instagram', url => '', label => 'Social placeholder' },
]);
my $clean = decode_json($content->normalize_body_json($body_json, ''));
is($clean->[0]{type}, 'image', 'keeps blank image placeholder');
is($clean->[0]{src}, '', 'blank image src remains blank');
is($clean->[1]{type}, 'image_text', 'keeps blank image and text placeholder');
is($clean->[2]{type}, 'link', 'keeps link placeholder');
is($clean->[2]{url}, '', 'unsafe link URL is stripped');
is($clean->[3]{type}, 'social', 'keeps social placeholder');

my $request = Local::TemplateRequest->new({
    name        => 'Landing Offer',
    description => 'Reusable landing page layout',
    body_json   => $body_json,
});
my $saved = $app->_template_save(undef, $request);
ok($saved->{id}, 'saves custom template');
is($saved->{slug}, 'landing-offer', 'creates template slug');
like($saved->{body_json}, qr/Text beside a future image/, 'stores normalized template body');

my $sections = $app->_section_rows;
ok(@{$sections} >= 4, 'seeds starter builder sections');
ok((grep { $_->{slug} eq 'intro-with-action' } @{$sections}), 'seeds intro section');
ok((grep { $_->{slug} eq 'photo-feature' } @{$sections}), 'seeds photo feature section');
ok((grep { $_->{slug} eq 'contributor-callout' } @{$sections}), 'seeds contributor callout section');

my $section_json = $app->_builder_sections_json;
like($section_json, qr/Reusable|Intro With Action/, 'builder sections are available as editor JSON');

my $section_request = Local::TemplateRequest->new({
    name        => 'Proof Block',
    description => 'Reusable proof section',
    body_json   => encode_json([
        { type => 'heading', text => 'Proof', level => 2, spacing => 'compact' },
        { type => 'text', text => 'Reusable body.', spacing => 'spacious' },
    ]),
});
my $saved_section = $app->_section_save(undef, $section_request);
ok($saved_section->{id}, 'saves custom builder section');
is($saved_section->{slug}, 'proof-block', 'creates section slug');
my $saved_section_blocks = decode_json($saved_section->{body_json});
is($saved_section_blocks->[1]{spacing}, 'spacious', 'stores section block spacing');

my $spacing_json = encode_json([
    { type => 'text', text => 'Tight text', spacing => 'compact' },
    { type => 'heading', text => 'Wide heading', level => 2, spacing => 'spacious' },
    { type => 'divider', spacing => 'invalid' },
]);
my $spacing_clean = decode_json($content->normalize_body_json($spacing_json, ''));
is($spacing_clean->[0]{spacing}, 'compact', 'keeps compact block spacing');
is($spacing_clean->[1]{spacing}, 'spacious', 'keeps spacious block spacing');
is($spacing_clean->[2]{spacing}, 'default', 'invalid block spacing falls back to default');

my $rendered_spacing = DesertCMS::Renderer::_render_blocks(
    encode_json([{ type => 'text', text => 'Tight text', spacing => 'compact' }]),
    $db
);
like($rendered_spacing, qr/content-block--spacing-compact/, 'renderer emits block spacing class');

done_testing;
