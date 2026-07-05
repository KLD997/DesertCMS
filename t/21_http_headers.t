use strict;
use warnings;
use Test::More;
use Encode qw(encode);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::HTTP;

my $response = _capture_response(sub {
    DesertCMS::HTTP->reset_response_state;
    DesertCMS::HTTP->response(
        status  => 200,
        headers => {
            'Content-Type'   => 'text/plain; charset=utf-8',
            'Content-Length' => 999,
        },
        body => "ok\n",
    );
});

like($response, qr/\AStatus: 200 OK\r?\n/, 'response starts with CGI status header');
unlike($response, qr/^Content-Length:/mi, 'dynamic CGI responses do not emit Content-Length');
ok(DesertCMS::HTTP->response_sent, 'response_sent tracks emitted responses');

DesertCMS::HTTP->reset_response_state;
ok(!DesertCMS::HTTP->response_sent, 'response state can be reset for the next request');

is(
    DesertCMS::HTTP::client_ip({ ip_address => '10.0.0.2', forwarded_for => '198.51.100.10' }, _config('')),
    '10.0.0.2',
    'forwarded IP is ignored without a trusted proxy'
);
is(
    DesertCMS::HTTP::client_ip({ ip_address => '10.0.0.2', forwarded_for => '198.51.100.10:443, 203.0.113.5' }, _config('10.0.0.2/32')),
    '198.51.100.10',
    'forwarded IP is accepted from a trusted IPv4 proxy'
);
is(
    DesertCMS::HTTP::client_ip({ ip_address => '2001:db8::2', forwarded_for => '2001:db8:ffff::20' }, _config('2001:db8::/64')),
    '2001:db8:ffff::20',
    'forwarded IP is accepted from a trusted IPv6 proxy'
);

{
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{REQUEST_URI} = '/forms';
    local $ENV{QUERY_STRING} = '';
    local $ENV{CONTENT_TYPE} = 'application/x-www-form-urlencoded';
    local $ENV{CONTENT_LENGTH} = 6;
    local $ENV{DESERTCMS_MAX_REQUEST_BODY_BYTES} = 5;
    local $ENV{REMOTE_ADDR} = '203.0.113.9';
    local $ENV{HTTP_COOKIE} = '';
    my $stdin = 'abcdef';
    open my $in, '<', \$stdin or die "cannot open scalar stdin: $!";
    local *STDIN = $in;
    my $request = DesertCMS::HTTP->read_request;
    ok($request->{body_too_large}, 'oversized request body is rejected before parsing');
    is($request->{body}, '', 'oversized request body is not read into memory');
    is_deeply($request->{form}, {}, 'oversized request body is not parsed');
}

{
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{REQUEST_URI} = '/forms';
    local $ENV{QUERY_STRING} = '';
    local $ENV{CONTENT_TYPE} = 'application/x-www-form-urlencoded';
    local $ENV{CONTENT_LENGTH} = 5;
    local $ENV{DESERTCMS_MAX_REQUEST_BODY_BYTES} = 5;
    local $ENV{REMOTE_ADDR} = '203.0.113.9';
    local $ENV{HTTP_COOKIE} = '';
    my $stdin = 'a=b&c';
    open my $in, '<', \$stdin or die "cannot open scalar stdin: $!";
    local *STDIN = $in;
    my $request = DesertCMS::HTTP->read_request;
    ok(!$request->{body_too_large}, 'request at body limit is accepted');
    is($request->param('a'), 'b', 'accepted body is parsed');
}

{
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{REQUEST_URI} = '/admin/pages/create';
    local $ENV{QUERY_STRING} = '';
    local $ENV{CONTENT_TYPE} = 'application/x-www-form-urlencoded; charset=UTF-8';
    local $ENV{DESERTCMS_MAX_REQUEST_BODY_BYTES} = 1024;
    local $ENV{REMOTE_ADDR} = '203.0.113.9';
    local $ENV{HTTP_COOKIE} = '';
    my $stdin = 'title=Caf%C3%A9&blank=%C2%A0&body_json=%5B%7B%22html%22%3A%22%3Cp%3ECaf%C3%A9%C2%A0%3C%2Fp%3E%22%7D%5D';
    local $ENV{CONTENT_LENGTH} = length($stdin);
    open my $in, '<', \$stdin or die "cannot open scalar stdin: $!";
    local *STDIN = $in;
    my $request = DesertCMS::HTTP->read_request;
    is($request->param('title'), "Caf\x{e9}", 'urlencoded form text decodes UTF-8');
    is($request->param('blank'), "\x{a0}", 'urlencoded form keeps non-breaking space as Unicode');
    like($request->param('body_json'), qr/Caf\x{e9}\x{a0}/, 'rich text JSON form data decodes UTF-8 characters');
    unlike($request->param('body_json'), qr/[ÃÂ]/, 'rich text JSON avoids UTF-8 mojibake artifacts');
}

{
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{REQUEST_URI} = '/admin/site-settings/save';
    local $ENV{QUERY_STRING} = '';
    my $boundary = '----DesertCMSBoundary';
    local $ENV{CONTENT_TYPE} = "multipart/form-data; boundary=$boundary";
    local $ENV{DESERTCMS_MAX_REQUEST_BODY_BYTES} = 1024;
    local $ENV{REMOTE_ADDR} = '203.0.113.9';
    local $ENV{HTTP_COOKIE} = '';
    my $value = encode('UTF-8', "Caf\x{e9}\x{a0}");
    my $stdin = "--$boundary\r\nContent-Disposition: form-data; name=\"site_name\"\r\n\r\n$value\r\n--$boundary--\r\n";
    local $ENV{CONTENT_LENGTH} = length($stdin);
    open my $in, '<', \$stdin or die "cannot open scalar stdin: $!";
    local *STDIN = $in;
    my $request = DesertCMS::HTTP->read_request;
    is($request->param('site_name'), "Caf\x{e9}\x{a0}", 'multipart text fields decode UTF-8');
    unlike($request->param('site_name'), qr/[ÃÂ]/, 'multipart fields avoid UTF-8 mojibake artifacts');
}

done_testing;

sub _capture_response {
    my ($code) = @_;
    my $output = '';
    open my $fh, '>', \$output or die "cannot capture output: $!";
    {
        local *STDOUT = $fh;
        $code->();
    }
    close $fh;
    return $output;
}

sub _config {
    my ($trusted_proxy_cidrs) = @_;
    return bless { trusted_proxy_cidrs => $trusted_proxy_cidrs }, 'Local::Config';
}

package Local::Config;

sub get {
    my ($self, $key) = @_;
    return $self->{$key};
}

package main;
