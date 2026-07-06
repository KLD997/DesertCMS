package DesertCMS::Analytics;

use strict;
use warnings;
use Encode qw(FB_DEFAULT decode is_utf8);
use DesertCMS::GeoIP;
use DesertCMS::HTTP ();
use DesertCMS::Util qw(escape_html hmac_sha256_hex now);

sub enabled {
    my ($config) = @_;
    my $value = $config->get('analytics_enabled');
    return 1 unless defined $value;
    return $value =~ /\A(?:0|false|no|off)\z/i ? 0 : 1;
}

sub tracking_script {
    my ($config) = @_;
    return '' unless enabled($config);

    return <<'HTML';
  <script>
  (function () {
    if (navigator.doNotTrack === '1' || window.doNotTrack === '1') {
      return;
    }
    var params = new URLSearchParams();
    params.set('path', window.location.pathname || '/');
    params.set('referrer', document.referrer || '');
    var body = params.toString();
    if (navigator.sendBeacon) {
      navigator.sendBeacon('/analytics/collect', new Blob([body], { type: 'application/x-www-form-urlencoded' }));
      return;
    }
    if (window.fetch) {
      fetch('/analytics/collect', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body,
        credentials: 'same-origin',
        keepalive: true
      }).catch(function () {});
    }
  }());
  </script>
HTML
}

sub record {
    my ($config, $db, $request) = @_;
    return 0 unless enabled($config);
    return 0 if ($request->{dnt} || '') eq '1';

    my $path = _clean_path($request->param('path'));
    return 0 unless length $path;
    return 0 if $path =~ m{\A/(?:admin|analytics)(?:/|\z)};

    my $ip = DesertCMS::HTTP::client_ip($request, $config);
    return 0 unless length $ip;
    my $user_agent = $request->{user_agent} || '';
    my $referrer = _clean_referrer($request->param('referrer') || $request->{referrer});
    my $geo = _geo_details($db, $request, $ip);
    my $ts = now();

    $db->dbh->do(
        q{
            INSERT INTO analytics_events
                (path, ip_hash, ip_address, user_agent_hash, referrer,
                 country_code, country, region, city, occurred_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $path,
        _hash($config, "ip\0$ip"),
        _display_ip($config, $ip),
        _hash($config, "ua\0$user_agent"),
        $referrer,
        $geo->{country_code},
        $geo->{country},
        $geo->{region},
        $geo->{city},
        $ts
    );
    prune($config, $db, now => $ts);

    return 1;
}

sub prune {
    my ($config, $db, %args) = @_;
    my $days = int($config->get('analytics_retention_days') || 365);
    return 0 if $days <= 0;
    $days = 3650 if $days > 3650;
    my $cutoff = ($args{now} || now()) - ($days * 86400);
    my $rv = $db->dbh->do(
        'DELETE FROM analytics_events WHERE occurred_at < ?',
        undef,
        $cutoff
    );
    return $rv || 0;
}

sub summary {
    my ($config, $db, %args) = @_;
    my $days = int($args{days} || 30);
    $days = 30 if $days < 1 || $days > 366;
    my $limit = int($args{limit} || 8);
    $limit = 8 if $limit < 1 || $limit > 50;

    my $since = now() - ($days * 86400);
    my $since_24h = now() - 86400;
    my $dbh = $db->dbh;

    my ($visits) = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM analytics_events WHERE occurred_at >= ?',
        undef,
        $since
    );
    my ($unique_ips) = $dbh->selectrow_array(
        'SELECT COUNT(DISTINCT ip_hash) FROM analytics_events WHERE occurred_at >= ?',
        undef,
        $since
    );
    my ($visits_24h) = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM analytics_events WHERE occurred_at >= ?',
        undef,
        $since_24h
    );
    my ($unique_ips_24h) = $dbh->selectrow_array(
        'SELECT COUNT(DISTINCT ip_hash) FROM analytics_events WHERE occurred_at >= ?',
        undef,
        $since_24h
    );
    my ($geo_known_visits) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM analytics_events
            WHERE occurred_at >= ?
              AND (country <> '' OR region <> '' OR city <> '')
        },
        undef,
        $since
    );
    my $geo_unknown_visits = int($visits || 0) - int($geo_known_visits || 0);
    $geo_unknown_visits = 0 if $geo_unknown_visits < 0;

    my $top_pages = $dbh->selectall_arrayref(
        q{
            SELECT path, COUNT(*) AS visits, COUNT(DISTINCT ip_hash) AS unique_ips
            FROM analytics_events
            WHERE occurred_at >= ?
            GROUP BY path
            ORDER BY visits DESC, path ASC
            LIMIT ?
        },
        { Slice => {} },
        $since,
        $limit
    );

    my $top_ips = $dbh->selectall_arrayref(
        q{
            SELECT ip_hash, MAX(ip_address) AS ip_address,
                   MAX(country_code) AS country_code, MAX(country) AS country,
                   MAX(region) AS region, MAX(city) AS city,
                   COUNT(*) AS visits, COUNT(DISTINCT path) AS pages,
                   MIN(occurred_at) AS first_seen, MAX(occurred_at) AS last_seen
            FROM analytics_events
            WHERE occurred_at >= ?
            GROUP BY ip_hash
            ORDER BY visits DESC, last_seen DESC
            LIMIT ?
        },
        { Slice => {} },
        $since,
        $limit
    );

    my $referrers = $dbh->selectall_arrayref(
        q{
            SELECT referrer, COUNT(*) AS visits
            FROM analytics_events
            WHERE occurred_at >= ?
              AND referrer <> ''
            GROUP BY referrer
            ORDER BY visits DESC, referrer ASC
            LIMIT ?
        },
        { Slice => {} },
        $since,
        $limit
    );

    my $locations = $dbh->selectall_arrayref(
        q{
            SELECT
                CASE WHEN country_code <> '' THEN country_code ELSE '' END AS country_code,
                CASE WHEN country <> '' THEN country ELSE 'Unknown' END AS country,
                COUNT(*) AS visits,
                COUNT(DISTINCT ip_hash) AS unique_ips
            FROM analytics_events
            WHERE occurred_at >= ?
            GROUP BY
                CASE WHEN country_code <> '' THEN country_code ELSE '' END,
                CASE WHEN country <> '' THEN country ELSE 'Unknown' END
            ORDER BY visits DESC, country ASC
            LIMIT ?
        },
        { Slice => {} },
        $since,
        $limit
    );

    my $city_locations = $dbh->selectall_arrayref(
        q{
            SELECT
                country_code,
                country,
                region,
                city,
                COUNT(*) AS visits,
                COUNT(DISTINCT ip_hash) AS unique_ips
            FROM analytics_events
            WHERE occurred_at >= ?
              AND (country <> '' OR region <> '' OR city <> '')
            GROUP BY country_code, country, region, city
            ORDER BY visits DESC, country ASC, region ASC, city ASC
            LIMIT ?
        },
        { Slice => {} },
        $since,
        $limit
    );

    my $daily_days = int($args{daily_days} || ($days > 30 ? 30 : $days));
    $daily_days = 7 if $daily_days < 1;
    $daily_days = 90 if $daily_days > 90;
    my $daily = $dbh->selectall_arrayref(
        q{
            SELECT strftime('%Y-%m-%d', occurred_at, 'unixepoch') AS day,
                   COUNT(*) AS visits,
                   COUNT(DISTINCT ip_hash) AS unique_ips
            FROM analytics_events
            WHERE occurred_at >= ?
            GROUP BY day
            ORDER BY day ASC
        },
        { Slice => {} },
        now() - ($daily_days * 86400)
    );

    my $recent = $dbh->selectall_arrayref(
        q{
            SELECT path, ip_hash, ip_address, country_code, country, region, city, occurred_at
            FROM analytics_events
            ORDER BY occurred_at DESC
            LIMIT ?
        },
        { Slice => {} },
        $limit
    );

    for my $row (@{$top_ips}, @{$recent}, @{$city_locations}) {
        $row->{ip_label} = $row->{ip_address} || ip_label($row->{ip_hash});
        $row->{location_label} = location_label($row);
    }

    return {
        days            => $days,
        visits          => int($visits || 0),
        unique_ips      => int($unique_ips || 0),
        visits_24h      => int($visits_24h || 0),
        unique_ips_24h  => int($unique_ips_24h || 0),
        geo_known_visits => int($geo_known_visits || 0),
        geo_unknown_visits => $geo_unknown_visits,
        top_pages       => $top_pages,
        top_ips         => $top_ips,
        referrers       => $referrers,
        locations       => $locations,
        city_locations  => $city_locations,
        daily           => $daily,
        daily_days      => $daily_days,
        recent          => $recent,
        enabled         => enabled($config),
    };
}

sub ip_label {
    my ($hash) = @_;
    $hash ||= '';
    return length $hash >= 12 ? substr($hash, 0, 12) : $hash;
}

sub location_label {
    my ($row) = @_;
    my $flag = country_flag($row);
    my @place = grep { defined $_ && length $_ } map { _display_text($_) } ($row->{city}, $row->{region});
    my $label = @place ? join(', ', @place) : _display_text($row->{country} || '');
    return length $label ? join(' ', grep { length $_ } ($flag, $label)) : 'Unknown';
}

sub country_flag {
    my ($row) = @_;
    my $code = _country_code($row);
    return '' unless length $code;
    return join '', map { chr(0x1F1E6 + ord($_) - ord('A')) } split //, $code;
}

sub _display_ip {
    my ($config, $ip) = @_;
    return $ip if ($config->get('analytics_store_raw_ip') || '') !~ /\A(?:0|false|no|off)\z/i;
    return _mask_ip($ip);
}

sub _mask_ip {
    my ($ip) = @_;
    if ($ip =~ /\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}\z/) {
        return "$1.$2.$3.0/24";
    }
    if ($ip =~ /:/) {
        my @parts = split /:/, $ip;
        return join(':', @parts[0 .. ($#parts < 2 ? $#parts : 2)]) . '::/48';
    }
    return '';
}

sub _geo_details {
    my ($db, $request, $ip) = @_;
    my $country_code = _clean_country_code($request->{geo_country_code});
    my $country = _clean_geo($request->{geo_country});
    my $region = _clean_geo($request->{geo_region});
    my $city = _clean_geo($request->{geo_city});
    $country_code ||= _clean_country_code($country);
    $country ||= $country_code;

    if (!_has_geo($country, $region, $city) && DesertCMS::GeoIP::is_private_ip($ip)) {
        $country_code = '';
        $country = 'Private';
        $region = 'Local network';
        $city = 'Local';
    } elsif (!_has_geo($country, $region, $city)) {
        my $geo = DesertCMS::GeoIP::lookup($db, $ip);
        $country_code = _clean_country_code($geo->{country_code});
        $country = _clean_geo($geo->{country});
        $region = _clean_geo($geo->{region});
        $city = _clean_geo($geo->{city});
        $country_code ||= DesertCMS::GeoIP::country_code_for($country);
    }

    return {
        country_code => $country_code,
        country      => $country,
        region       => $region,
        city         => $city,
    };
}

sub _has_geo {
    for my $value (@_) {
        return 1 if defined $value && length $value;
    }
    return 0;
}

sub _clean_geo {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s+/ /g;
    return '' if $value =~ /[\r\n<>"\\]/;
    return substr($value, 0, 120);
}

sub _country_code {
    my ($row) = @_;
    my $code = _clean_country_code($row->{country_code});
    return $code if length $code;
    return DesertCMS::GeoIP::country_code_for($row->{country} || '');
}

sub _display_text {
    my ($value) = @_;
    $value = '' unless defined $value;
    return $value if is_utf8($value);
    return decode('UTF-8', $value, FB_DEFAULT);
}

sub _clean_country_code {
    my ($value) = @_;
    $value = uc(_clean_geo($value));
    return '' unless $value =~ /\A[A-Z]{2}\z/;
    return '' if $value =~ /\A(?:XX|ZZ)\z/;
    return $value;
}

sub _hash {
    my ($config, $value) = @_;
    return hmac_sha256_hex($value || '', $config->app_secret);
}

sub _clean_path {
    my ($path) = @_;
    $path = '/' unless defined $path && length $path;
    $path =~ s/[?#].*\z//;
    $path = '/' . $path unless $path =~ m{\A/};
    return '' if $path =~ m{(?:\A|/)\.\.(?:/|\z)};
    return '' if $path =~ /[\r\n<>"\\]/;
    $path =~ s{//+}{/}g;
    $path =~ s{/+\z}{/} if $path ne '/';
    return substr($path, 0, 500);
}

sub _clean_referrer {
    my ($referrer) = @_;
    $referrer = '' unless defined $referrer;
    $referrer =~ s/[?#].*\z//;
    return '' if $referrer =~ /[\r\n<>"\\]/;
    return '' unless $referrer =~ m{\A(?:https?://[^/\s]+(?:/[^\s]*)?|/[A-Za-z0-9._~!\$&'()*+,;=:@%/-]*)\z}i;
    return substr($referrer, 0, 500);
}

sub table_rows {
    my ($rows, $columns, $empty) = @_;
    return '<tr><td colspan="' . int(@{$columns}) . '" class="muted">' . escape_html($empty || 'No data yet.') . '</td></tr>'
        unless @{$rows};

    my $html = '';
    for my $row (@{$rows}) {
        $html .= '<tr>';
        for my $column (@{$columns}) {
            my $value = ref $column->{value} eq 'CODE' ? $column->{value}->($row) : $row->{$column->{value}};
            $html .= '<td>' . escape_html($value) . '</td>';
        }
        $html .= '</tr>';
    }
    return $html;
}

1;
