package DesertCMS::SEO;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use File::Path qw(make_path);
use File::Spec;
use DesertCMS::Settings;
use DesertCMS::Util qw(now random_hex);

my $GOOGLE_AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
my $GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
my $GOOGLE_WEBMASTERS_SCOPE = 'https://www.googleapis.com/auth/webmasters';
my $GOOGLE_SITEMAP_ENDPOINT = 'https://www.googleapis.com/webmasters/v3/sites';
my $INDEXNOW_ENDPOINT = 'https://api.indexnow.org/indexnow';

sub sitemap_url {
    my ($config) = @_;
    return _absolute_url($config, '/sitemap.xml');
}

sub robots_url {
    my ($config) = @_;
    return _absolute_url($config, '/robots.txt');
}

sub google_redirect_uri {
    my ($config) = @_;
    return _absolute_url($config, '/admin/site-settings/google/callback');
}

sub google_connected {
    my ($settings) = @_;
    return ($settings->{google_oauth_refresh_token} || $settings->{google_oauth_access_token}) ? 1 : 0;
}

sub google_auth_url {
    my ($config, $settings, %args) = @_;
    my $client_id = _trim($settings->{google_oauth_client_id});
    die "Google OAuth client ID is required" unless length $client_id;
    my $state = _trim($args{state});
    die "OAuth state is required" unless length $state;

    my %params = (
        client_id              => $client_id,
        redirect_uri           => google_redirect_uri($config),
        response_type          => 'code',
        scope                  => $GOOGLE_WEBMASTERS_SCOPE,
        access_type            => 'offline',
        include_granted_scopes => 'true',
        prompt                 => 'consent',
        state                  => $state,
    );
    return $GOOGLE_AUTH_URL . '?' . _query_string(\%params);
}

sub exchange_google_code {
    my ($config, $db, %args) = @_;
    my $settings = DesertCMS::Settings::all($config, $db);
    my $client_id = _trim($settings->{google_oauth_client_id});
    my $client_secret = _trim($settings->{google_oauth_client_secret});
    die "Google OAuth client ID is required" unless length $client_id;
    die "Google OAuth client secret is required" unless length $client_secret;

    my $code = _trim($args{code});
    die "Google authorization code is missing" unless length $code;
    my $http = $args{http} || HTTP::Tiny->new(timeout => 20, verify_SSL => 1);
    my $response = $http->post_form($GOOGLE_TOKEN_URL, {
        code          => $code,
        client_id     => $client_id,
        client_secret => $client_secret,
        redirect_uri  => google_redirect_uri($config),
        grant_type    => 'authorization_code',
    });
    my $json = _decode_response($response, 'Google OAuth token exchange failed');
    die "Google did not return an access token" unless length($json->{access_token} || '');

    my %values = (
        google_oauth_access_token => $json->{access_token},
        google_oauth_expires_at   => now() + int($json->{expires_in} || 3600),
        google_oauth_scope        => $json->{scope} || $GOOGLE_WEBMASTERS_SCOPE,
        google_oauth_connected_at => now(),
        google_oauth_last_error   => '',
    );
    $values{google_oauth_refresh_token} = $json->{refresh_token} if length($json->{refresh_token} || '');
    DesertCMS::Settings::set_many($config, $db, \%values);

    return \%values;
}

sub disconnect_google {
    my ($config, $db) = @_;
    DesertCMS::Settings::set_many($config, $db, {
        google_oauth_access_token  => '',
        google_oauth_refresh_token => '',
        google_oauth_expires_at    => '',
        google_oauth_connected_at  => '',
        google_oauth_scope         => '',
        google_oauth_last_error    => '',
    });
    return 1;
}

sub submit_google_sitemap {
    my ($config, $db, %args) = @_;
    my $settings = DesertCMS::Settings::all($config, $db);
    my $access_token = google_access_token($config, $db, settings => $settings, http => $args{http});
    my $site_property = _trim($settings->{google_search_console_property}) || _url_prefix_property($config);
    my $feedpath = sitemap_url($config);
    my $url = join '/',
        $GOOGLE_SITEMAP_ENDPOINT,
        _uri_escape($site_property),
        'sitemaps',
        _uri_escape($feedpath);

    my $http = $args{http} || HTTP::Tiny->new(timeout => 20, verify_SSL => 1);
    my $response = $http->request('PUT', $url, {
        headers => {
            Authorization => "Bearer $access_token",
            Accept        => 'application/json',
        },
    });
    if (!$response->{success}) {
        my $message = _response_error($response, 'Google sitemap submission failed');
        DesertCMS::Settings::set_many($config, $db, {
            google_sitemap_last_status => 'failed',
            google_sitemap_last_error  => $message,
        });
        die $message;
    }

    DesertCMS::Settings::set_many($config, $db, {
        google_sitemap_last_submitted_at => now(),
        google_sitemap_last_status       => 'submitted',
        google_sitemap_last_error        => '',
    });
    return {
        engine  => 'Google Search Console',
        sitemap => $feedpath,
        status  => int($response->{status} || 0),
    };
}

sub google_access_token {
    my ($config, $db, %args) = @_;
    my $settings = $args{settings} || DesertCMS::Settings::all($config, $db);
    my $token = _trim($settings->{google_oauth_access_token});
    my $expires_at = int($settings->{google_oauth_expires_at} || 0);
    return $token if length $token && $expires_at > now() + 90;

    my $refresh_token = _trim($settings->{google_oauth_refresh_token});
    die "Connect a Google account before submitting the sitemap" unless length $refresh_token;
    my $client_id = _trim($settings->{google_oauth_client_id});
    my $client_secret = _trim($settings->{google_oauth_client_secret});
    die "Google OAuth client ID is required" unless length $client_id;
    die "Google OAuth client secret is required" unless length $client_secret;

    my $http = $args{http} || HTTP::Tiny->new(timeout => 20, verify_SSL => 1);
    my $response = $http->post_form($GOOGLE_TOKEN_URL, {
        client_id     => $client_id,
        client_secret => $client_secret,
        refresh_token => $refresh_token,
        grant_type    => 'refresh_token',
    });
    my $json = _decode_response($response, 'Google token refresh failed');
    die "Google did not return an access token" unless length($json->{access_token} || '');

    DesertCMS::Settings::set_many($config, $db, {
        google_oauth_access_token => $json->{access_token},
        google_oauth_expires_at   => now() + int($json->{expires_in} || 3600),
        google_oauth_last_error   => '',
    });
    return $json->{access_token};
}

sub ensure_indexnow_key {
    my ($config, $db, %args) = @_;
    my $settings = $args{settings} || DesertCMS::Settings::all($config, $db);
    my $key = _trim($settings->{indexnow_key});
    if (!length $key) {
        $key = random_hex(16);
        DesertCMS::Settings::set_many($config, $db, { indexnow_key => $key });
    }
    die "IndexNow key must be 8-128 letters, numbers, or dashes"
        unless $key =~ /\A[A-Za-z0-9-]{8,128}\z/;
    return $key;
}

sub write_indexnow_key_file {
    my ($config, $key) = @_;
    die "IndexNow key is required" unless length($key || '');
    my $public_root = $config->get('public_root');
    make_path($public_root) unless -d $public_root;
    my $path = File::Spec->catfile($public_root, "$key.txt");
    open my $fh, '>:encoding(UTF-8)', $path or die "cannot write IndexNow key file $path: $!";
    print {$fh} $key;
    close $fh;
    return $path;
}

sub submit_indexnow {
    my ($config, $db, %args) = @_;
    my $settings = DesertCMS::Settings::all($config, $db);
    die "IndexNow is disabled" unless _truthy($settings->{indexnow_enabled});

    my $key = ensure_indexnow_key($config, $db, settings => $settings);
    write_indexnow_key_file($config, $key);
    my $site_url = _site_url($config);
    my $host = _host_for($site_url);
    my @urls = @{sitemap_urls($config)};
    die "sitemap does not contain public URLs yet" unless @urls;
    @urls = @urls[0 .. 9999] if @urls > 10000;

    my $payload = {
        host        => $host,
        key         => $key,
        keyLocation => _absolute_url($config, "/$key.txt"),
        urlList     => \@urls,
    };
    my $http = $args{http} || HTTP::Tiny->new(timeout => 20, verify_SSL => 1);
    my $response = $http->post($INDEXNOW_ENDPOINT, {
        headers => {
            'Content-Type' => 'application/json; charset=utf-8',
            Accept         => 'application/json',
        },
        content => encode_json($payload),
    });
    if (!$response->{success}) {
        my $message = _response_error($response, 'IndexNow submission failed');
        DesertCMS::Settings::set_many($config, $db, {
            indexnow_last_status => 'failed',
            indexnow_last_error  => $message,
        });
        die $message;
    }

    DesertCMS::Settings::set_many($config, $db, {
        indexnow_last_submitted_at => now(),
        indexnow_last_url_count    => scalar(@urls),
        indexnow_last_status       => 'submitted',
        indexnow_last_error        => '',
    });
    return {
        engine => 'IndexNow',
        urls   => scalar(@urls),
        status => int($response->{status} || 0),
    };
}

sub sitemap_urls {
    my ($config) = @_;
    my $path = File::Spec->catfile($config->get('public_root'), 'sitemap.xml');
    return [] unless -f $path;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read sitemap $path: $!";
    local $/;
    my $xml = <$fh>;
    close $fh;
    my @urls;
    while ($xml =~ m{<loc>(.*?)</loc>}sg) {
        my $url = _xml_unescape($1);
        push @urls, $url if $url =~ m{\Ahttps?://}i;
    }
    return \@urls;
}

sub _url_prefix_property {
    my ($config) = @_;
    my $url = _site_url($config);
    $url .= '/' unless $url =~ m{/\z};
    return $url;
}

sub _absolute_url {
    my ($config, $path) = @_;
    my $base = _site_url($config);
    $path = '/' . ($path || '') unless ($path || '') =~ m{\A/};
    return $base . $path;
}

sub _site_url {
    my ($config) = @_;
    my $base = $config->get('site_url') || 'http://localhost';
    $base =~ s{/+\z}{};
    return $base;
}

sub _host_for {
    my ($url) = @_;
    return $1 if ($url || '') =~ m{\Ahttps?://([^/]+)}i;
    die "site_url must include http:// or https://";
}

sub _decode_response {
    my ($response, $fallback) = @_;
    die _response_error($response, $fallback) unless $response->{success};
    my $json = eval { decode_json($response->{content} || '{}') };
    die "$fallback: invalid JSON response" if $@ || ref $json ne 'HASH';
    return $json;
}

sub _response_error {
    my ($response, $fallback) = @_;
    my $status = defined $response->{status} ? int($response->{status}) : 0;
    my $reason = $response->{reason} || '';
    my $message = "$fallback";
    $message .= " ($status" . ($reason ? " $reason" : '') . ')' if $status;
    my $json = eval { decode_json($response->{content} || '{}') };
    if (!$@ && ref $json eq 'HASH') {
        my $error = $json->{error};
        if (ref $error eq 'HASH') {
            $message .= ': ' . ($error->{message} || $error->{status} || $error->{code} || '');
        } elsif (defined $error && length $error) {
            $message .= ": $error";
        }
    }
    return $message;
}

sub _query_string {
    my ($params) = @_;
    return join '&', map { _uri_escape($_) . '=' . _uri_escape($params->{$_}) } sort keys %{$params};
}

sub _uri_escape {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/([^A-Za-z0-9\-\._~])/sprintf('%%%02X', ord($1))/eg;
    return $value;
}

sub _xml_unescape {
    my ($value) = @_;
    $value =~ s/&lt;/</g;
    $value =~ s/&gt;/>/g;
    $value =~ s/&quot;/"/g;
    $value =~ s/&apos;/'/g;
    $value =~ s/&amp;/&/g;
    return $value;
}

sub _trim {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/\A\s+|\s+\z//g;
    return $value;
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value && length $value;
    return 0 if $value =~ /\A(?:0|false|no|off)\z/i;
    return 1;
}

1;
