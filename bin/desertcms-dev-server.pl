#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Spec;
use HTTP::Daemon;
use HTTP::Response;
use HTTP::Status qw(RC_FORBIDDEN RC_FOUND RC_MOVED_PERMANENTLY RC_NOT_FOUND RC_OK);

use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Redirects;

my $host = '127.0.0.1';
my $port = shift @ARGV || 8080;

my $daemon = HTTP::Daemon->new(LocalAddr => $host, LocalPort => $port, ReuseAddr => 1)
    or die "cannot start dev server on $host:$port: $!";

print "DesertCMS dev server listening at " . $daemon->url . "\n";

while (my $conn = $daemon->accept) {
    if (my $request = $conn->get_request) {
        my $path = $request->uri->path || '/';
        if (_dynamic_request($request)) {
            $conn->send_response(_run_cgi($request));
        } else {
            $conn->send_response(_redirect_response($request) || _static_response($request));
        }
    }
    $conn->close;
    undef $conn;
}

sub _run_cgi {
    my ($request) = @_;
    my $body = $request->content || '';
    my $query = defined $request->uri->query ? $request->uri->query : '';
    my $cookie = $request->header('Cookie') || '';

    local %ENV = (%ENV,
        REQUEST_METHOD => $request->method,
        REQUEST_URI    => $request->uri->path_query,
        QUERY_STRING   => $query,
        CONTENT_TYPE   => $request->header('Content-Type') || '',
        CONTENT_LENGTH => length($body),
        HTTP_HOST      => $request->header('Host') || '',
        HTTP_COOKIE    => $cookie,
        HTTP_USER_AGENT => $request->header('User-Agent') || 'desertcms-dev-server',
        HTTP_REFERER   => $request->header('Referer') || '',
        HTTP_DNT       => $request->header('DNT') || '',
        HTTP_STRIPE_SIGNATURE => $request->header('Stripe-Signature') || '',
        REMOTE_ADDR    => '127.0.0.1',
    );

    my $input = $body;
    my $output = '';
    open my $in, '<', \$input or die "cannot open request body: $!";
    open my $out, '>', \$output or die "cannot capture response: $!";
    local *STDIN = $in;
    local *STDOUT = $out;
    DesertCMS::App->new->run;
    close $out;

    return _parse_cgi_response($output);
}

sub _dynamic_request {
    my ($request) = @_;
    my $path = $request->uri->path || '/';
    return 1 if $path =~ m{\A/(?:admin|analytics|comments|ratings|forms|shop|stripe|billing|postmark|events|directory|bookings|members|newsletter|donate|testimonials)(?:/|\z)};
    return 1 if $path eq '/events.ics';

    my $config = eval { DesertCMS::Config->load };
    return 0 unless $config;
    my $shop_host = lc($config->get('shop_domain') || '');
    return 0 unless length $shop_host;
    my $host = lc($request->header('Host') || '');
    $host =~ s/:\d+\z//;
    return $host eq $shop_host ? 1 : 0;
}

sub _parse_cgi_response {
    my ($raw) = @_;
    my ($header_blob, $body) = split /\r?\n\r?\n/, $raw, 2;
    $body = '' unless defined $body;

    my $status = RC_OK;
    my $response = HTTP::Response->new($status);
    for my $line (split /\r?\n/, $header_blob || '') {
        next unless length $line;
        if ($line =~ /^Status:\s*([0-9]+)/i) {
            $status = int($1);
            $response->code($status);
            next;
        }
        my ($name, $value) = split /:\s*/, $line, 2;
        next unless defined $name && defined $value;
        $response->push_header($name => $value);
    }
    $response->content($body);
    return $response;
}

sub _redirect_response {
    my ($request) = @_;
    my $config = DesertCMS::Config->load;
    my $db = DesertCMS::DB->new(config => $config);
    my $rule = eval { DesertCMS::Redirects::match($config, $db, $request->uri->path || '/') };
    return undef if !$rule;

    my $code = int($rule->{status_code} || 301) == 302 ? RC_FOUND : RC_MOVED_PERMANENTLY;
    my $response = HTTP::Response->new($code);
    $response->header(Location => $rule->{target_url});
    $response->content("Redirecting to $rule->{target_url}\n");
    return $response;
}

sub _static_response {
    my ($request) = @_;
    my $config = DesertCMS::Config->load;
    my $root = $config->get('public_root');
    my $path = $request->uri->path || '/';
    $path =~ s{\A/+}{};
    $path = 'index.html' if $path eq '';
    $path .= '/index.html' if $path =~ m{/\z};
    return HTTP::Response->new(RC_FORBIDDEN) if $path =~ m{(?:\A|/)\.\.(?:/|\z)};

    my $file = File::Spec->catfile($root, split m{/}, $path);
    $file = File::Spec->catfile($file, 'index.html') if -d $file;
    return HTTP::Response->new(RC_NOT_FOUND) unless -f $file;

    open my $fh, '<:raw', $file or return HTTP::Response->new(RC_FORBIDDEN);
    local $/;
    my $content = <$fh>;
    close $fh;

    my $response = HTTP::Response->new(RC_OK);
    $response->header('Content-Type' => _content_type($file));
    $response->content($content);
    return $response;
}

sub _content_type {
    my ($file) = @_;
    return 'text/html; charset=utf-8' if $file =~ /\.html?\z/i;
    return 'text/css; charset=utf-8' if $file =~ /\.css\z/i;
    return 'application/javascript; charset=utf-8' if $file =~ /\.js\z/i;
    return 'image/jpeg' if $file =~ /\.jpe?g\z/i;
    return 'image/png' if $file =~ /\.png\z/i;
    return 'image/webp' if $file =~ /\.webp\z/i;
    return 'application/octet-stream';
}
