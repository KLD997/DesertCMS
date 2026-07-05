use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP qw(decode_json);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Forms;
use DesertCMS::Settings;

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/admin-assets", "$root/data");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Forms Test
site_url = https://example.test
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

my $forms = DesertCMS::Forms->new(config => $config, db => $db);
my $counts = $forms->counts;
is($counts->{new}, 0, 'forms start with zero new submissions');
is_deeply(
    DesertCMS::Forms::enabled_form_types({ forms_enabled_types => 'contact,quote,application,intake,rsvp' }),
    [qw(contact quote application intake rsvp)],
    'forms support contact, quote, application, intake, and RSVP types'
);

DesertCMS::Settings::set_many($config, $db, {
    module_forms_enabled => 1,
    forms_notification_email => 'forms@example.test',
    forms_uploads_enabled => 1,
    forms_max_upload_mb => 2,
});

my $request = {
    ip_address => '203.0.113.25',
    user_agent => 'Forms test browser',
};
my @sent_notifications;
{
    no warnings 'redefine';
    local *DesertCMS::Forms::send_postmark = sub {
        my ($sent_config, $sent_db, %args) = @_;
        push @sent_notifications, \%args;
        return (1, 'sent');
    };
    my $result = $forms->submit(
        form_key       => 'quote',
        name           => 'Reader',
        email          => 'reader@example.test',
        phone          => '555-0100',
        organization   => 'Reader Studio',
        subject        => 'Project estimate',
        preferred_date => '2026-08-15',
        budget         => '$2,500',
        message        => "Hello\n\nCan we talk about a quote?",
        attachments    => [ _upload('brief.pdf', 'application/pdf', '%PDF-1.4 test brief') ],
        request        => $request,
    );
    ok($result->{ok}, 'quote request submission succeeds');
    ok($result->{id} > 0, 'form submission returns id');
    is($result->{form_key}, 'quote', 'form submission returns selected form type');
    is($result->{upload_count}, 1, 'form submission stores upload count');
    ok($result->{notification_sent}, 'form submission reports sent Postmark notification');
}
is(scalar @sent_notifications, 1, 'form submission sends one Postmark notification');
is($sent_notifications[0]{to}, 'forms@example.test', 'Postmark notification uses configured forms recipient');
is($sent_notifications[0]{email_type}, 'form_submission', 'Postmark notification uses forms email type');
like($sent_notifications[0]{text_body}, qr/Quote Request/, 'Postmark notification identifies form type');

$counts = $forms->counts;
is($counts->{new}, 1, 'new submission count increments');
is($counts->{total}, 1, 'total submission count increments');
is($counts->{by_type}{quote}, 1, 'type counts track quote requests');

my $recent = $forms->recent_submissions(limit => 5);
is(scalar @{$recent}, 1, 'recent submissions returns saved row');
is($recent->[0]{form_key}, 'quote', 'submission stores form type');
is($recent->[0]{email}, 'reader@example.test', 'submission stores email');
is($recent->[0]{phone}, '555-0100', 'submission stores phone');
is($recent->[0]{organization}, 'Reader Studio', 'submission stores organization');
is($recent->[0]{preferred_date}, '2026-08-15', 'submission stores preferred date');
is($recent->[0]{budget}, '$2,500', 'submission stores budget');
is($recent->[0]{message}, "Hello\n\nCan we talk about a quote?", 'submission stores message text');
is($recent->[0]{notification_status}, 'sent', 'submission stores notification status');

my $attachments = DesertCMS::Forms::submission_files($recent->[0]);
is(scalar @{$attachments}, 1, 'submission stores attachment metadata');
is($attachments->[0]{filename}, 'brief.pdf', 'attachment metadata stores original filename');
ok(-f $attachments->[0]{path}, 'attachment is stored privately on disk');
unlike($attachments->[0]{path}, qr/\Q$root\/public\E/, 'attachment is not stored under public root');
my $download = $forms->submission_upload(id => $recent->[0]{id}, index => 0);
is($download->{filename}, 'brief.pdf', 'submission upload download returns original filename');
is($download->{mime}, 'application/pdf', 'submission upload download returns MIME type');

for my $case (
    [ contact     => 'Contact follow-up' ],
    [ application => 'Program application' ],
    [ intake      => 'Client intake' ],
    [ rsvp        => 'Event RSVP' ],
) {
    my ($key, $subject) = @{$case};
    my $result = $forms->submit(
        form_key => $key,
        name => "Tester $key",
        email => "$key\@example.test",
        subject => $subject,
        message => "Details for $subject.",
        settings => {
            forms_enabled_types => 'contact,quote,application,intake,rsvp',
            forms_uploads_enabled => 0,
            forms_notify_postmark_enabled => 0,
        },
        request => {
            ip_address => '198.51.100.' . (20 + length($key)),
            user_agent => 'Forms type test browser',
        },
    );
    ok($result->{ok}, "$key form submission succeeds");
    is($result->{form_key}, $key, "$key form submission stores selected type");
}

$counts = $forms->counts;
is($counts->{by_type}{contact}, 1, 'type counts track contact forms');
is($counts->{by_type}{application}, 1, 'type counts track applications');
is($counts->{by_type}{intake}, 1, 'type counts track intake forms');
is($counts->{by_type}{rsvp}, 1, 'type counts track RSVPs');

my ($raw_ip_count) = $db->dbh->selectrow_array("SELECT COUNT(*) FROM form_submissions WHERE ip_hash LIKE '203.%'");
is($raw_ip_count, 0, 'form submissions do not store raw IP addresses');

eval {
    $forms->submit(
        name    => 'Reader',
        email   => 'not an email',
        message => 'Message body',
        request => $request,
    );
};
like($@, qr/Please enter a valid email address\./, 'rejects invalid email addresses');

eval {
    $forms->submit(
        name    => 'Reader',
        email   => 'reader@example.test',
        message => '',
        request => { ip_address => '198.51.100.1', user_agent => 'Forms test browser' },
    );
};
like($@, qr/Please enter a message before sending\./, 'requires a message');

eval {
    $forms->submit(
        form_key => 'quote',
        name => 'Reader',
        email => 'reader@example.test',
        message => 'Quote details',
        settings => { forms_enabled_types => 'contact', forms_uploads_enabled => 1, forms_notify_postmark_enabled => 0 },
        request => { ip_address => '198.51.100.2', user_agent => 'Forms test browser' },
    );
};
like($@, qr/That form type is not available right now\./, 'rejects disabled form types');

my $app = DesertCMS::App->new;
my $get = bless {
    method => 'GET',
    path   => '/forms',
    form   => {},
    query  => {},
    uploads => {},
}, 'DesertCMS::HTTP';
my $page_response = _capture_response(sub { $app->_dispatch_forms($get) });
like($page_response, qr/Status: 200 OK/, 'public Forms page renders');
like($page_response, qr/name="form_key"/, 'public Forms page includes request type selector');
like($page_response, qr/Quote Request/, 'public Forms page includes quote request option');
like($page_response, qr/RSVP/, 'public Forms page includes RSVP option');
like($page_response, qr/enctype="multipart\/form-data"/, 'public Forms page enables multipart uploads');
like($page_response, qr/name="attachment_1"/, 'public Forms page includes upload field');
like($page_response, qr/data-upload-preview/, 'public Forms page includes upload preview hooks');

my $admin_response = _capture_response(sub {
    $app->_module_forms_settings_page(
        $get,
        { user_id => 1, username => 'admin', role => 'owner', email => 'admin@example.test' },
        'forms-test-session'
    );
});
like($admin_response, qr/Status: 200 OK/, 'Forms admin settings page renders');
like($admin_response, qr/Form Types/, 'Forms admin settings page exposes type controls');
like($admin_response, qr/Quote Request/, 'Forms admin settings page includes quote request control');
like($admin_response, qr/Allow supporting file uploads/, 'Forms admin settings page exposes upload controls');
like($admin_response, qr/Send Postmark notifications/, 'Forms admin settings page exposes notification controls');
like($admin_response, qr/module-section-nav" aria-label="Forms setup sections".*href="\#forms-status">Status<\/a>.*href="\#forms-types">Form Types<\/a>.*href="\#forms-copy">Page Copy<\/a>.*href="\#forms-delivery">Uploads &amp; Notifications<\/a>.*href="\#forms-submissions">Recent Submissions<\/a>/s, 'Forms admin settings expose local section navigation');
like($admin_response, qr/id="forms-status".*id="forms-types".*id="forms-copy".*id="forms-delivery".*id="forms-submissions"/s, 'Forms admin settings navigation targets stable sections');
like($admin_response, qr{/admin/settings/modules/forms/submissions/[0-9]+/uploads/0}, 'Forms admin inbox links private uploads');
like($admin_response, qr/class="content-table compact-table admin-card-table"/, 'Forms admin inbox uses responsive card table markup');
like($admin_response, qr/data-label="Received".*data-label="Notification".*data-label="Status"/s, 'Forms admin inbox rows expose mobile table labels');

done_testing;

sub _upload {
    my ($filename, $mime, $content) = @_;
    return {
        filename => $filename,
        content_type => $mime,
        content => $content,
    };
}

sub _capture_response {
    my ($code) = @_;
    DesertCMS::HTTP->reset_response_state;
    my $output = '';
    open my $capture, '>', \$output or die "cannot capture response: $!";
    my $old = select $capture;
    $code->();
    select $old;
    close $capture;
    return $output;
}
