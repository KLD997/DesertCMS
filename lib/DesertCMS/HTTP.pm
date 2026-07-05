package DesertCMS::HTTP;

use strict;
use warnings;
use Encode qw(encode_utf8 is_utf8);
use Socket qw(AF_INET AF_INET6 inet_pton);
use DesertCMS::GeoIP ();
use DesertCMS::Util qw(parse_urlencoded url_decode escape_html);

our $SENT_RESPONSE = 0;
my $MAX_REQUEST_BODY_BYTES = 64 * 1024 * 1024;

sub reset_response_state {
    $SENT_RESPONSE = 0;
}

sub response_sent {
    return $SENT_RESPONSE ? 1 : 0;
}

sub read_request {
    my ($class, %args) = @_;

    my $method = uc($ENV{REQUEST_METHOD} || 'GET');
    my $query_string = $ENV{QUERY_STRING} || '';
    my $request_uri = $ENV{REQUEST_URI} || ($ENV{SCRIPT_NAME} || '/');
    my ($path) = split /\?/, $request_uri, 2;
    $path ||= '/';
    $path =~ s{^/cgi-bin/desertcms\.cgi}{};
    $path = '/admin' if $path eq '';
    my $content_length = _content_length($ENV{CONTENT_LENGTH});
    my $max_body = max_request_body_bytes($args{max_body_bytes});
    my $body_too_large = $content_length > $max_body ? 1 : 0;
    my $body = '';
    if ($content_length > 0 && !$body_too_large) {
        read STDIN, $body, $content_length;
    }

    my $content_type = $ENV{CONTENT_TYPE} || '';
    my $form = {};
    if (!$body_too_large && $method eq 'POST' && $content_type =~ m{application/x-www-form-urlencoded}i) {
        $form = parse_urlencoded($body);
    }
    my $uploads = {};
    if (!$body_too_large && $method eq 'POST' && $content_type =~ m{multipart/form-data;\s*boundary=(?:"([^"]+)"|([^;\s]+))}i) {
        my $boundary = defined $1 ? $1 : $2;
        ($form, $uploads) = _parse_multipart($body, $boundary);
    }

    return bless {
        method       => $method,
        path         => $path,
        query        => parse_urlencoded($query_string),
        form         => $form,
        uploads      => $uploads,
        cookies      => _parse_cookies($ENV{HTTP_COOKIE} || ''),
        ip_address   => $ENV{REMOTE_ADDR} || '',
        user_agent   => $ENV{HTTP_USER_AGENT} || '',
        referrer     => $ENV{HTTP_REFERER} || '',
        dnt          => $ENV{HTTP_DNT} || '',
        host         => $ENV{HTTP_HOST} || $ENV{SERVER_NAME} || '',
        stripe_signature => $ENV{HTTP_STRIPE_SIGNATURE} || '',
        forwarded_for => $ENV{HTTP_X_FORWARDED_FOR} || '',
        geo_country_code => $ENV{HTTP_CF_IPCOUNTRY} || $ENV{HTTP_X_GEO_COUNTRY_CODE} || '',
        geo_country  => $ENV{HTTP_X_GEO_COUNTRY} || $ENV{HTTP_CF_IPCOUNTRY} || '',
        geo_region   => $ENV{HTTP_X_GEO_REGION} || '',
        geo_city     => $ENV{HTTP_X_GEO_CITY} || '',
        request_uri  => $request_uri,
        content_type => $content_type,
        body         => $body,
        body_too_large => $body_too_large,
        max_body_bytes => $max_body,
    }, $class;
}

sub max_request_body_bytes {
    my ($configured) = @_;
    my $value = $ENV{DESERTCMS_MAX_REQUEST_BODY_BYTES};
    $value = $configured unless defined $value;
    return $MAX_REQUEST_BODY_BYTES unless defined $value && $value =~ /\A[0-9]+\z/ && $value > 0;
    return int($value);
}

sub client_ip {
    my ($request, $config) = @_;
    return '' unless $request;
    my $remote = DesertCMS::GeoIP::normalize_ip($request->{ip_address} || '');
    return '' unless length $remote;

    if (_trusted_proxy($remote, $config)) {
        my $forwarded = $request->{forwarded_for} || '';
        for my $part (split /,/, $forwarded) {
            my $ip = DesertCMS::GeoIP::normalize_ip($part);
            return $ip if length $ip;
        }
    }

    return $remote;
}

sub param {
    my ($self, $key) = @_;
    return $self->{form}{$key} if exists $self->{form}{$key};
    return $self->{query}{$key} if exists $self->{query}{$key};
    return undef;
}

sub cookie {
    my ($self, $key) = @_;
    return $self->{cookies}{$key};
}

sub upload {
    my ($self, $key) = @_;
    return $self->{uploads}{$key};
}

sub _parse_cookies {
    my ($header) = @_;
    my %cookies;
    for my $part (split /;\s*/, $header) {
        my ($key, $value) = split /=/, $part, 2;
        next unless defined $key && defined $value && length $key;
        $cookies{$key} = url_decode($value);
    }
    return \%cookies;
}

sub _content_length {
    my ($value) = @_;
    return 0 unless defined $value && $value =~ /\A[0-9]+\z/;
    return int($value);
}

sub _trusted_proxy {
    my ($remote, $config) = @_;
    return 0 unless $config;
    my $raw = eval { $config->get('trusted_proxy_cidrs') } || '';
    return 0 unless length $raw;
    for my $spec (grep { length } split /[\s,]+/, $raw) {
        return 1 if _ip_matches_spec($remote, $spec);
    }
    return 0;
}

sub _ip_matches_spec {
    my ($ip, $spec) = @_;
    $spec =~ s/\A\s+|\s+\z//g;
    return 0 unless length $ip && length $spec;
    if ($spec !~ m{/}) {
        return DesertCMS::GeoIP::normalize_ip($spec) eq $ip ? 1 : 0;
    }

    my ($network, $bits) = split m{/}, $spec, 2;
    return 0 unless defined $bits && $bits =~ /\A[0-9]+\z/;
    my ($ip_packed, $ip_bits) = _packed_ip($ip);
    my ($network_packed, $network_bits) = _packed_ip($network);
    return 0 unless defined $ip_packed && defined $network_packed && $ip_bits == $network_bits;
    return 0 if $bits < 0 || $bits > $ip_bits;

    my $full_bytes = int($bits / 8);
    my $remaining = $bits % 8;
    return 0 if $full_bytes && substr($ip_packed, 0, $full_bytes) ne substr($network_packed, 0, $full_bytes);
    if ($remaining) {
        my $mask = (0xff << (8 - $remaining)) & 0xff;
        return 0 if ((ord(substr($ip_packed, $full_bytes, 1)) & $mask) != (ord(substr($network_packed, $full_bytes, 1)) & $mask));
    }
    return 1;
}

sub _packed_ip {
    my ($ip) = @_;
    $ip = DesertCMS::GeoIP::normalize_ip($ip);
    return (undef, 0) unless length $ip;
    if (index($ip, ':') >= 0) {
        my $packed = inet_pton(AF_INET6, $ip);
        return (defined $packed ? $packed : undef, 128);
    }
    my $packed = inet_pton(AF_INET, $ip);
    return (defined $packed ? $packed : undef, 32);
}

sub _parse_multipart {
    my ($body, $boundary) = @_;
    my (%form, %uploads);
    return (\%form, \%uploads) unless defined $boundary && length $boundary;

    my $marker = '--' . $boundary;
    for my $part (split /\Q$marker\E/, $body) {
        next if $part =~ /\A--/;
        $part =~ s/\A\r?\n//;
        $part =~ s/\r?\n\z//;
        next unless $part =~ /\S/;

        my ($raw_headers, $content) = split /\r?\n\r?\n/, $part, 2;
        next unless defined $raw_headers && defined $content;
        $content =~ s/\r?\n\z//;

        my %headers;
        for my $line (split /\r?\n/, $raw_headers) {
            my ($key, $value) = split /:\s*/, $line, 2;
            next unless defined $key && defined $value;
            $headers{lc $key} = $value;
        }

        my $disposition = $headers{'content-disposition'} || '';
        next unless $disposition =~ /name="([^"]+)"/;
        my $name = $1;

        if ($disposition =~ /filename="([^"]*)"/) {
            my $filename = $1;
            next unless length $filename;
            $uploads{$name} = {
                filename => $filename,
                content_type => $headers{'content-type'} || 'application/octet-stream',
                content => $content,
            };
        } else {
            $form{$name} = $content;
        }
    }

    return (\%form, \%uploads);
}

sub response {
    my ($class, %args) = @_;
    my $status = $args{status} || 200;
    my $headers = $args{headers} || {};
    my $body = defined $args{body} ? $args{body} : '';
    my $raw_body = is_utf8($body) ? encode_utf8($body) : $body;

    binmode STDOUT, ':raw';
    $SENT_RESPONSE = 1;
    my $status_text = _status_text($status);
    print "Status: $status $status_text\r\n";
    while (my ($key, $value) = each %{$headers}) {
        next if lc($key) eq 'content-length';
        if (ref $value eq 'ARRAY') {
            print "$key: $_\r\n" for @{$value};
        } else {
            print "$key: $value\r\n";
        }
    }
    print "\r\n";
    print $raw_body;
}

sub redirect {
    my ($class, $location, $headers) = @_;
    $headers ||= {};
    $headers->{Location} = $location;
    $headers->{'Content-Type'} ||= 'text/html; charset=utf-8';
    $headers->{'Cache-Control'} ||= 'no-store';
    my $safe_location = escape_html($location || '/');
    my $body = <<"HTML";
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="robots" content="noindex">
  <title>Redirecting</title>
</head>
<body>
  <p>Redirecting to <a href="$safe_location">$safe_location</a>.</p>
</body>
</html>
HTML
    return $class->response(
        status  => 303,
        headers => $headers,
        body    => $body,
    );
}

sub cookie_header {
    my ($class, %args) = @_;
    my $name = $args{name};
    my $value = defined $args{value} ? $args{value} : '';
    my @parts = ("$name=$value", 'Path=/admin', 'HttpOnly', 'SameSite=Strict');
    push @parts, 'Secure' if $args{secure};
    push @parts, 'Max-Age=' . int($args{max_age}) if defined $args{max_age};
    return join '; ', @parts;
}

sub html_page {
    my ($class, %args) = @_;
    my $title = escape_html($args{title} || 'DesertCMS');
    my $body = $args{body} || '';
    my $user_nav = $args{user_nav} || '';
    my $brand = $args{brand} || 'DesertCMS';
    my $default_theme_mode = ($args{default_theme_mode} || '') eq 'dark' ? 'dark' : 'light';
    my $product_mode = ($args{product_mode} || '') eq 'contributor' ? 'contributor' : 'master';
    my $topbar_class = $product_mode eq 'contributor' ? 'topbar contributor-topbar' : 'topbar';
    my $topbar_actions_class = $product_mode eq 'contributor' ? 'topbar-actions contributor-topbar-actions' : 'topbar-actions';
    my $admin_menu_toggle = length($user_nav)
        ? q{<button type="button" class="admin-menu-toggle" data-admin-menu-toggle aria-controls="admin-primary-nav" aria-expanded="false" aria-label="Open admin navigation" title="Open admin navigation"><svg class="admin-menu-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg></button>}
        : '';

    return <<"HTML";
<!doctype html>
<html lang="en" data-theme="$default_theme_mode">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$title</title>
  <link rel="stylesheet" href="/admin/assets/admin.css?v=20260705a">
  <script src="/admin/assets/map.js?v=20260703l" defer></script>
  <script src="/admin/assets/editor.js?v=20260705a" defer></script>
</head>
<body class="admin-product-mode--$product_mode">
  <header class="$topbar_class">
    <a class="brand" href="/admin">$brand</a>
    $admin_menu_toggle
    <div class="$topbar_actions_class">
      $user_nav
      <button type="button" class="theme-toggle" data-theme-toggle aria-label="Toggle color theme" title="Toggle color theme">
        <svg class="theme-icon theme-icon--moon" viewBox="0 0 24 24" aria-hidden="true"><path d="M21 14.5A8.6 8.6 0 0 1 9.5 3a7 7 0 1 0 11.5 11.5Z"/></svg>
        <svg class="theme-icon theme-icon--sun" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
      </button>
    </div>
  </header>
  <main class="shell">
    $body
  </main>
</body>
</html>
HTML
}

sub _status_text {
    my ($status) = @_;
    return {
        200 => 'OK',
        204 => 'No Content',
        303 => 'See Other',
        400 => 'Bad Request',
        401 => 'Unauthorized',
        403 => 'Forbidden',
        404 => 'Not Found',
        405 => 'Method Not Allowed',
        413 => 'Content Too Large',
        429 => 'Too Many Requests',
        500 => 'Internal Server Error',
    }->{$status} || 'OK';
}

1;
