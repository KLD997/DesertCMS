use strict;
use warnings;
use Test::More;

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
