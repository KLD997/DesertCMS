package DesertCMS::GeoIP;

use strict;
use warnings;
use DBI qw(:sql_types);
use Encode qw(decode);
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);
use Socket qw(AF_INET AF_INET6 inet_pton);
use DesertCMS::Util qw(now);

my %COUNTRY_CODE_BY_NAME = (
    'australia' => 'AU',
    'brazil' => 'BR',
    'canada' => 'CA',
    'france' => 'FR',
    'germany' => 'DE',
    'india' => 'IN',
    'italy' => 'IT',
    'japan' => 'JP',
    'mexico' => 'MX',
    'netherlands' => 'NL',
    'new zealand' => 'NZ',
    'spain' => 'ES',
    'united kingdom' => 'GB',
    'uk' => 'GB',
    'united states' => 'US',
    'united states of america' => 'US',
    'us' => 'US',
    'usa' => 'US',
);

sub lookup {
    my ($db, $ip) = @_;
    my ($version, $packed) = _pack_ip($ip);
    return {} unless $version;

    my $sth = $db->dbh->prepare(
        q{
            SELECT end_ip, country_code, country, region, city
            FROM analytics_geoip_ranges
            WHERE ip_version = ? AND start_ip <= ?
            ORDER BY start_ip DESC
            LIMIT 1
        }
    );
    $sth->bind_param(1, $version);
    $sth->bind_param(2, $packed, SQL_BLOB);
    $sth->execute;
    my $row = $sth->fetchrow_hashref;
    return {} unless $row && defined $row->{end_ip};
    return {} if _blob_cmp($row->{end_ip}, $packed) < 0;

    return {
        country_code => _clean_country_code($row->{country_code} || _country_code_from($row->{country})),
        country      => _clean_geo($row->{country}),
        region       => _clean_geo($row->{region}),
        city         => _clean_geo($row->{city}),
    };
}

sub status {
    my ($db) = @_;
    my ($count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM analytics_geoip_ranges');
    my $meta = $db->dbh->selectall_arrayref(
        'SELECT key, value FROM analytics_geoip_meta',
        { Slice => {} }
    );
    my %meta = map { $_->{key} => $_->{value} } @{$meta};
    return {
        count       => int($count || 0),
        source      => $meta{source} || '',
        imported_at => int($meta{imported_at} || 0),
        format      => $meta{format} || '',
    };
}

sub import_file {
    my ($db, %args) = @_;
    return import_maxmind_city($db, %args) if $args{blocks} || $args{locations};
    my $path = $args{path} || $args{file} || die "geoip import path is required\n";
    return import_custom($db, path => $path, source => $args{source}, append => $args{append});
}

sub refresh_dbip_city_lite {
    my ($config, $db, %args) = @_;
    my @urls = $args{url} ? ($args{url}) : _dbip_city_lite_urls();
    my $data_dir = $args{data_dir} || File::Spec->catdir($config->get('data_dir'), 'geoip');
    make_path($data_dir) unless -d $data_dir;

    my ($url, $path);
    my @errors;
    for my $candidate (@urls) {
        my $name = basename($candidate);
        next unless length $name;
        my $target = File::Spec->catfile($data_dir, $name);
        my $ok = eval {
            _download_file($candidate, $target);
            1;
        };
        if ($ok) {
            ($url, $path) = ($candidate, $target);
            last;
        }
        push @errors, "$candidate: " . ($@ || 'download failed');
    }
    die "could not download DB-IP City Lite GeoIP data: " . join('; ', @errors) . "\n"
        unless $path;

    my $month = $url =~ /dbip-city-lite-(\d{4}-\d{2})\.csv\.gz\z/ ? $1 : strftime('%Y-%m', gmtime);
    my $source = _clean_meta($args{source} || "DB-IP City Lite $month");
    my $import = $args{observed_only}
        ? import_dbip_observed_ranges($db, path => $path, source => "$source observed ranges")
        : import_file($db, path => $path, source => $source);
    my $backfill = $args{no_backfill} ? { checked => 0, updated => 0, skipped => 0 } : backfill_events($db);

    return {
        %{$import},
        url      => $url,
        path     => $path,
        backfill => $backfill,
    };
}

sub import_dbip_observed_ranges {
    my ($db, %args) = @_;
    my $path = $args{path} || die "geoip import path is required\n";
    my $source = _clean_meta($args{source} || basename($path) . ' observed ranges');
    my $targets = _observed_ipv4_targets($db);
    my $matches = _dbip_city_lite_matches($path, $targets);

    my $dbh = $db->dbh;
    my $count = 0;
    _prepare_bulk_import($dbh);
    $dbh->begin_work;
    eval {
        _reset_store($dbh, drop_index => 1);
        my $insert = _insert_statement($dbh);
        my %seen;
        for my $match (@{$matches}) {
            my $key = join '|', @{$match}{qw(start end country_code region city)};
            next if $seen{$key}++;
            $count += _insert_range(
                $insert,
                _range_from_bounds($match->{start}, $match->{end}),
                $match->{country},
                $match->{region},
                $match->{city},
                $source,
                $match->{country_code}
            );
        }
        _write_meta($dbh, source => $source, count => $count, format => 'dbip-city-lite-observed');
        _ensure_geoip_index($dbh);
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown observed GeoIP import error';
        eval { $dbh->rollback };
        die $err;
    };

    return {
        imported => $count,
        observed => scalar(@{$targets}),
        matched  => scalar(@{$matches}),
        source   => $source,
        format   => 'dbip-city-lite-observed',
    };
}

sub import_custom {
    my ($db, %args) = @_;
    my $path = $args{path} || die "geoip import path is required\n";
    my $fh = _open_geoip_file($path);

    my $first = _read_geoip_line($fh);
    die "GeoIP file is empty: $path\n" unless defined $first;
    my $sep = _separator_for($first);
    my @first = _parse_delimited($first, $sep);
    my $has_header = _looks_like_header(\@first);
    my %map = $has_header ? _header_map(\@first) : ();
    my $row_map = $has_header ? \%map : undef;
    my $source = _clean_meta($args{source} || basename($path));

    my $dbh = $db->dbh;
    my $count = 0;
    _prepare_bulk_import($dbh);
    $dbh->begin_work;
    eval {
        _reset_store($dbh, drop_index => !$args{append}) unless $args{append};
        my $insert = _insert_statement($dbh);
        if (!$has_header) {
            $count += _insert_custom_row($insert, \@first, undef, $source);
        }
        while (my $line = _read_geoip_line($fh)) {
            next unless $line =~ /\S/;
            my @row = _parse_delimited($line, $sep);
            $count += _insert_custom_row($insert, \@row, $row_map, $source);
        }
        _write_meta($dbh, source => $source, count => $count, format => $args{append} ? 'custom-append' : 'custom');
        _ensure_geoip_index($dbh) unless $args{append};
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown GeoIP import error';
        eval { $dbh->rollback };
        close $fh;
        die $err;
    };
    close $fh;

    return { imported => $count, source => $source, format => $args{append} ? 'custom-append' : 'custom' };
}

sub import_maxmind_city {
    my ($db, %args) = @_;
    my $blocks = $args{blocks} || die "GeoLite2 blocks CSV is required\n";
    my $locations = $args{locations} || die "GeoLite2 locations CSV is required\n";
    my $source = _clean_meta($args{source} || basename($blocks));

    my $location_by_id = _read_maxmind_locations($locations);
    my $fh = _open_geoip_file($blocks);
    my $header_line = _read_geoip_line($fh);
    die "GeoLite2 blocks file is empty: $blocks\n" unless defined $header_line;
    my $sep = _separator_for($header_line);
    my @headers = _parse_delimited($header_line, $sep);
    my %map = _header_map(\@headers);

    my $dbh = $db->dbh;
    my $count = 0;
    _prepare_bulk_import($dbh);
    $dbh->begin_work;
    eval {
        _reset_store($dbh, drop_index => !$args{append}) unless $args{append};
        my $insert = _insert_statement($dbh);
        while (my $line = _read_geoip_line($fh)) {
            next unless $line =~ /\S/;
            my @row = _parse_delimited($line, $sep);
            my $network = _value(\%map, \@row, qw(network));
            my $geoname_id = _value(
                \%map,
                \@row,
                qw(geoname_id registered_country_geoname_id represented_country_geoname_id)
            );
            my $location = $location_by_id->{$geoname_id} || {};
            $count += _insert_range(
                $insert,
                _range_from_network($network),
                $location->{country},
                $location->{region},
                $location->{city},
                $source,
                $location->{country_code}
            );
        }
        _write_meta($dbh, source => $source, count => $count, format => $args{append} ? 'maxmind-city-csv-append' : 'maxmind-city-csv');
        _ensure_geoip_index($dbh) unless $args{append};
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown GeoLite2 import error';
        eval { $dbh->rollback };
        close $fh;
        die $err;
    };
    close $fh;

    return { imported => $count, source => $source, format => $args{append} ? 'maxmind-city-csv-append' : 'maxmind-city-csv' };
}

sub backfill_events {
    my ($db, %args) = @_;
    my $limit = int($args{limit} || 0);
    my $sql = q{
        SELECT id, ip_address
        FROM analytics_events
        WHERE ip_address <> ''
          AND country = ''
        ORDER BY occurred_at DESC
    };
    $sql .= ' LIMIT ' . $limit if $limit > 0;

    my $rows = $db->dbh->selectall_arrayref($sql, { Slice => {} });
    my $updated = 0;
    my $skipped = 0;
    my $update = $db->dbh->prepare(
        'UPDATE analytics_events SET country_code = ?, country = ?, region = ?, city = ? WHERE id = ?'
    );

    for my $row (@{$rows}) {
        my $ip = _ip_from_display($row->{ip_address});
        my $geo = is_private_ip($ip)
            ? { country => 'Private', region => 'Local network', city => 'Local' }
            : lookup($db, $ip);
        if (_has_geo($geo)) {
            $update->execute(
                _clean_country_code($geo->{country_code} || _country_code_from($geo->{country})),
                $geo->{country} || '',
                $geo->{region} || '',
                $geo->{city} || '',
                $row->{id}
            );
            $updated++;
        } else {
            $skipped++;
        }
    }

    return { checked => scalar(@{$rows}), updated => $updated, skipped => $skipped };
}

sub is_private_ip {
    my ($ip) = @_;
    my ($version, $packed) = _pack_ip($ip);
    return 0 unless $version;
    my @b = unpack('C*', $packed);

    if ($version == 4) {
        return 1 if $b[0] == 10;
        return 1 if $b[0] == 127;
        return 1 if $b[0] == 169 && $b[1] == 254;
        return 1 if $b[0] == 172 && $b[1] >= 16 && $b[1] <= 31;
        return 1 if $b[0] == 192 && $b[1] == 168;
        return 0;
    }

    return 1 if !grep { $_ != 0 } @b[0 .. 14] && $b[15] == 1;
    return 1 if ($b[0] & 0xfe) == 0xfc;
    return 1 if $b[0] == 0xfe && ($b[1] & 0xc0) == 0x80;
    return 0;
}

sub _observed_ipv4_targets {
    my ($db) = @_;
    my $rows = $db->dbh->selectall_arrayref(
        q{
            SELECT DISTINCT ip_address
            FROM analytics_events
            WHERE ip_address <> ''
        },
        { Slice => {} }
    );
    my %targets;
    for my $row (@{$rows}) {
        my $ip = normalize_ip($row->{ip_address});
        next unless length $ip && $ip =~ /\A\d+\.\d+\.\d+\.\d+\z/;
        next if is_private_ip($ip);
        my $int = _ip4_to_int($ip);
        next unless defined $int;
        $targets{$ip} ||= { ip => $ip, int => $int };
    }
    return [ sort { $a->{int} <=> $b->{int} } values %targets ];
}

sub _dbip_city_lite_matches {
    my ($path, $targets) = @_;
    return [] unless @{$targets || []};

    my $fh = _open_geoip_file($path);
    my @matches;
    my $idx = 0;
    while (my $line = _read_geoip_line($fh)) {
        last if $idx >= @{$targets};
        my ($start, $end, $country_code, $region, $city) = _dbip_city_lite_fields($line);
        next unless defined $start && defined $end;
        my $start_int = _ip4_to_int($start);
        my $end_int = _ip4_to_int($end);
        next unless defined $start_int && defined $end_int;

        while ($idx < @{$targets} && $targets->[$idx]{int} < $start_int) {
            $idx++;
        }
        my $scan = $idx;
        while ($scan < @{$targets} && $targets->[$scan]{int} <= $end_int) {
            push @matches, {
                start        => $start,
                end          => $end,
                country_code => $country_code,
                country      => $country_code,
                region       => $region,
                city         => $city,
            };
            $scan++;
        }
        $idx = $scan if $scan > $idx;
    }
    close $fh;
    return \@matches;
}

sub _dbip_city_lite_fields {
    my ($line) = @_;
    $line = '' unless defined $line;
    $line =~ s/\r?\n\z//;
    return unless $line =~ /\A([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),("(?:[^"]|"")*"|[^,]*)/;
    return (
        _clean_dbip_csv_value($1),
        _clean_dbip_csv_value($2),
        _clean_country_code($4),
        _clean_geo(_clean_dbip_csv_value($5)),
        _clean_geo(_clean_dbip_csv_value($6)),
    );
}

sub _clean_dbip_csv_value {
    my ($value) = @_;
    $value = _trim($value);
    if ($value =~ /\A"(.*)"\z/s) {
        $value = $1;
        $value =~ s/""/"/g;
    }
    return _trim($value);
}

sub _ip4_to_int {
    my ($ip) = @_;
    return undef unless defined $ip && $ip =~ /\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z/;
    my @parts = ($1, $2, $3, $4);
    return undef if grep { $_ > 255 } @parts;
    return ($parts[0] << 24) + ($parts[1] << 16) + ($parts[2] << 8) + $parts[3];
}

sub _dbip_city_lite_urls {
    my %seen;
    my @urls;
    for my $offset_days (0, 35, 70) {
        my $month = strftime('%Y-%m', gmtime(time - ($offset_days * 86400)));
        next if $seen{$month}++;
        push @urls, "https://download.db-ip.com/free/dbip-city-lite-$month.csv.gz";
    }
    return @urls;
}

sub _download_file {
    my ($url, $path) = @_;
    require HTTP::Tiny;
    my $tmp = "$path.tmp";
    unlink $tmp if -f $tmp;
    my $response = HTTP::Tiny->new(timeout => 120, verify_SSL => 1)->mirror($url, $tmp);
    if ($response->{success}) {
        rename $tmp, $path or die "cannot move GeoIP download into place at $path: $!";
        return;
    }

    my $http_error = "HTTP " . ($response->{status} || 0) . " " . ($response->{reason} || '');
    unlink $tmp if -f $tmp;
    my $ftp_status = system('ftp', '-M', '-V', '-o', $tmp, $url);
    if ($ftp_status == 0 && -s $tmp) {
        rename $tmp, $path or die "cannot move GeoIP download into place at $path: $!";
        return;
    }
    unlink $tmp if -f $tmp;
    die "$http_error; ftp fallback failed with exit " . ($ftp_status >> 8) . "\n";
}

sub _read_maxmind_locations {
    my ($path) = @_;
    my $fh = _open_geoip_file($path);
    my $header_line = _read_geoip_line($fh);
    die "GeoLite2 locations file is empty: $path\n" unless defined $header_line;
    my $sep = _separator_for($header_line);
    my @headers = _parse_delimited($header_line, $sep);
    my %map = _header_map(\@headers);
    my %locations;

    while (my $line = _read_geoip_line($fh)) {
        next unless $line =~ /\S/;
        my @row = _parse_delimited($line, $sep);
        my $id = _value(\%map, \@row, qw(geoname_id));
        next unless defined $id && length $id;
        $locations{$id} = {
            country_code => _value(\%map, \@row, qw(country_iso_code)),
            country      => _value(\%map, \@row, qw(country_name country_iso_code)),
            region       => _value(\%map, \@row, qw(subdivision_1_name subdivision_1_iso_code)),
            city         => _value(\%map, \@row, qw(city_name)),
        };
    }
    close $fh;
    return \%locations;
}

sub _insert_custom_row {
    my ($insert, $row, $map, $source) = @_;
    my ($range, $country_code, $country, $region, $city);

    if ($map) {
        my $network = _value($map, $row, qw(network cidr));
        if (defined $network && length $network) {
            $range = [ _range_from_network($network) ];
        } else {
            my $start = _value($map, $row, qw(start_ip ip_start first_ip from_ip start));
            my $end = _value($map, $row, qw(end_ip ip_end last_ip to_ip end));
            $range = [ _range_from_bounds($start, $end) ];
        }
        $country_code = _value($map, $row, qw(country_code country_iso_code iso_code));
        $country = _value($map, $row, qw(country_name country));
        $country = $country_code unless length $country;
        $region = _value($map, $row, qw(region_name region subdivision state state_name));
        $city = _value($map, $row, qw(city_name city));
    } else {
        my $first = $row->[0] || '';
        if ($first =~ m{/}) {
            $range = [ _range_from_network($first) ];
            $country = $row->[1];
            $region = $row->[2];
            $city = $row->[3];
        } else {
            $range = [ _range_from_bounds($row->[0], $row->[1]) ];
            my $dbip_format = _dbip_city_row_format($row);
            if ($dbip_format eq 'lite') {
                $country_code = $row->[3];
                $country = _clean_country_code($row->[3]);
                $region = $row->[4];
                $city = $row->[5];
            } elsif ($dbip_format eq 'extended') {
                $country_code = $row->[4];
                $country = $row->[6] || _clean_country_code($row->[4]);
                $region = $row->[7];
                $city = $row->[8];
            } elsif (@{$row} >= 6) {
                $country_code = $row->[2];
                $country = $row->[3] || $row->[2];
                $region = $row->[4];
                $city = $row->[5];
            } else {
                $country = $row->[2];
                $region = $row->[3];
                $city = $row->[4];
            }
        }
    }

    return _insert_range($insert, @{$range}, $country, $region, $city, $source, $country_code);
}

sub _dbip_city_row_format {
    my ($row) = @_;
    if (@{$row} >= 8
        && (defined $row->[2] ? $row->[2] : '') =~ /\A[A-Z]{2}\z/
        && (defined $row->[3] ? $row->[3] : '') =~ /\A[A-Z]{2}\z/
        && (defined $row->[6] ? $row->[6] : '') =~ /\A-?\d+(?:\.\d+)?\z/
        && (defined $row->[7] ? $row->[7] : '') =~ /\A-?\d+(?:\.\d+)?\z/) {
        return 'lite';
    }
    if (@{$row} >= 9
        && (defined $row->[2] ? $row->[2] : '') =~ /\A[A-Z]{2}\z/
        && (defined $row->[4] ? $row->[4] : '') =~ /\A[A-Z]{2}\z/
        && (defined $row->[5] ? $row->[5] : '') =~ /\A(?:0|1)\z/) {
        return 'extended';
    }
    return '';
}

sub _insert_range {
    my ($insert, $version, $start, $end, $country, $region, $city, $source, $country_code) = @_;
    return 0 unless $version && defined $start && defined $end;
    return 0 if _blob_cmp($start, $end) > 0;
    $country_code = _clean_country_code($country_code || _country_code_from($country));
    $country = _clean_geo($country);
    $region = _clean_geo($region);
    $city = _clean_geo($city);
    return 0 unless length($country) || length($region) || length($city);

    $insert->bind_param(1, $version);
    $insert->bind_param(2, $start, SQL_BLOB);
    $insert->bind_param(3, $end, SQL_BLOB);
    $insert->bind_param(4, $country_code);
    $insert->bind_param(5, $country);
    $insert->bind_param(6, $region);
    $insert->bind_param(7, $city);
    $insert->bind_param(8, _clean_meta($source));
    $insert->bind_param(9, now());
    $insert->execute;
    return 1;
}

sub _insert_statement {
    my ($dbh) = @_;
    return $dbh->prepare(
        q{
            INSERT INTO analytics_geoip_ranges
                (ip_version, start_ip, end_ip, country_code, country, region, city, source, imported_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?)
        }
    );
}

sub _prepare_bulk_import {
    my ($dbh) = @_;
    for my $pragma (
        'PRAGMA journal_mode = MEMORY',
        'PRAGMA synchronous = OFF',
        'PRAGMA temp_store = MEMORY',
        'PRAGMA cache_size = -200000',
    ) {
        eval { $dbh->do($pragma); 1 };
    }
}

sub _reset_store {
    my ($dbh, %opts) = @_;
    $dbh->do('DROP INDEX IF EXISTS idx_analytics_geoip_range') if $opts{drop_index};
    $dbh->do('DELETE FROM analytics_geoip_ranges');
    $dbh->do('DELETE FROM analytics_geoip_meta');
}

sub _ensure_geoip_index {
    my ($dbh) = @_;
    $dbh->do(
        q{
            CREATE INDEX IF NOT EXISTS idx_analytics_geoip_range
                ON analytics_geoip_ranges(ip_version, start_ip)
        }
    );
}

sub _open_geoip_file {
    my ($path) = @_;
    if ($path =~ /\.gz\z/i) {
        require IO::Uncompress::Gunzip;
        my $fh = IO::Uncompress::Gunzip->new($path, MultiStream => 1);
        if (!$fh) {
            my $error = do { no warnings 'once'; $IO::Uncompress::Gunzip::GunzipError };
            die "cannot read compressed GeoIP file $path: $error";
        }
        return $fh;
    }
    open my $fh, '<:raw', $path or die "cannot read GeoIP file $path: $!";
    return $fh;
}

sub _read_geoip_line {
    my ($fh) = @_;
    my $line = <$fh>;
    return undef unless defined $line;
    return decode('UTF-8', $line);
}

sub _write_meta {
    my ($dbh, %args) = @_;
    my $ts = now();
    my %values = (
        source      => $args{source} || '',
        imported_at => $ts,
        range_count => int($args{count} || 0),
        format      => $args{format} || '',
    );
    my $sth = $dbh->prepare(
        q{
            INSERT INTO analytics_geoip_meta (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
        }
    );
    for my $key (sort keys %values) {
        $sth->execute($key, $values{$key}, $ts);
    }
}

sub _range_from_network {
    my ($network) = @_;
    $network = _trim($network);
    return unless length $network;
    my ($ip, $prefix) = split m{/}, $network, 2;
    my ($version, $packed) = _pack_ip($ip);
    return unless $version;
    my $max = $version == 4 ? 32 : 128;
    $prefix = $max unless defined $prefix && length $prefix;
    return unless $prefix =~ /\A\d+\z/ && $prefix >= 0 && $prefix <= $max;

    my @bytes = unpack('C*', $packed);
    my (@start, @end);
    my $remaining = int($prefix);
    for my $byte (@bytes) {
        if ($remaining >= 8) {
            push @start, $byte;
            push @end, $byte;
            $remaining -= 8;
        } elsif ($remaining > 0) {
            my $mask = (0xff << (8 - $remaining)) & 0xff;
            my $start_byte = $byte & $mask;
            push @start, $start_byte;
            push @end, $start_byte | (0xff ^ $mask);
            $remaining = 0;
        } else {
            push @start, 0;
            push @end, 255;
        }
    }

    return ($version, pack('C*', @start), pack('C*', @end));
}

sub _range_from_bounds {
    my ($start_ip, $end_ip) = @_;
    my ($start_version, $start) = _pack_ip($start_ip);
    my ($end_version, $end) = _pack_ip($end_ip);
    return unless $start_version && $end_version && $start_version == $end_version;
    return ($start_version, $start, $end);
}

sub _pack_ip {
    my ($ip) = @_;
    $ip = normalize_ip($ip);
    return unless length $ip;
    my $packed = inet_pton(AF_INET, $ip);
    return (4, $packed) if defined $packed;
    $packed = inet_pton(AF_INET6, $ip);
    return (6, $packed) if defined $packed;
    return;
}

sub _ip_from_display {
    my ($ip) = @_;
    return normalize_ip($ip);
}

sub normalize_ip {
    my ($ip) = @_;
    $ip = _trim($ip);
    return '' unless length $ip && length($ip) <= 120;
    $ip =~ s/\Afor=//i;
    $ip =~ s/\A"|"\z//g;
    $ip =~ s/\A'|'\z//g;
    $ip =~ s{/\d+\z}{};

    if ($ip =~ /\A\[([0-9A-Fa-f:.]+)\](?::\d+)?\z/) {
        $ip = $1;
    } elsif ($ip =~ /\A(\d{1,3}(?:\.\d{1,3}){3}):\d+\z/) {
        $ip = $1;
    }

    if ($ip =~ /\A::ffff:(\d{1,3}(?:\.\d{1,3}){3})\z/i) {
        $ip = $1;
    }

    return $ip if defined inet_pton(AF_INET, $ip);
    return lc $ip if defined inet_pton(AF_INET6, $ip);
    return '';
}

sub _separator_for {
    my ($line) = @_;
    return "\t" if defined $line && $line =~ /\t/;
    return ',';
}

sub _parse_delimited {
    my ($line, $sep) = @_;
    $line = '' unless defined $line;
    $line =~ s/\r?\n\z//;
    return map { _trim($_) } split /\Q$sep\E/, $line, -1
        if index($line, '"') < 0;
    my @fields;
    my $field = '';
    my $quoted = 0;
    my @chars = split //, $line;
    while (@chars) {
        my $char = shift @chars;
        if ($quoted) {
            if ($char eq '"') {
                if (@chars && $chars[0] eq '"') {
                    $field .= shift @chars;
                } else {
                    $quoted = 0;
                }
            } else {
                $field .= $char;
            }
            next;
        }
        if ($char eq '"') {
            $quoted = 1;
            next;
        }
        if ($char eq $sep) {
            push @fields, _trim($field);
            $field = '';
            next;
        }
        $field .= $char;
    }
    push @fields, _trim($field);
    return @fields;
}

sub _looks_like_header {
    my ($fields) = @_;
    my $joined = lc join ',', @{$fields};
    return 1 if $joined =~ /\b(?:network|cidr|start_ip|ip_start|first_ip|country|city|geoname_id)\b/;
    return 0;
}

sub _header_map {
    my ($headers) = @_;
    my %map;
    for my $i (0 .. $#{$headers}) {
        my $key = lc($headers->[$i] || '');
        $key =~ s/^\s+|\s+$//g;
        $key =~ s/[^a-z0-9]+/_/g;
        $key =~ s/^_+|_+$//g;
        $map{$key} = $i if length $key;
    }
    return %map;
}

sub _value {
    my ($map, $row, @names) = @_;
    for my $name (@names) {
        next unless exists $map->{$name};
        my $value = $row->[$map->{$name}];
        return $value if defined $value && length $value;
    }
    return '';
}

sub _has_geo {
    my ($geo) = @_;
    return 0 unless $geo;
    for my $key (qw(country region city)) {
        return 1 if defined $geo->{$key} && length $geo->{$key};
    }
    return 0;
}

sub _country_code_from {
    my ($country) = @_;
    $country = _trim($country);
    return _clean_country_code($country) if $country =~ /\A[A-Za-z]{2}\z/;
    my $key = lc $country;
    $key =~ s/[._-]+/ /g;
    $key =~ s/\s+/ /g;
    return $COUNTRY_CODE_BY_NAME{$key} || '';
}

sub country_code_for {
    my ($country) = @_;
    return _country_code_from($country);
}

sub _clean_country_code {
    my ($value) = @_;
    $value = uc _trim($value);
    return '' unless $value =~ /\A[A-Z]{2}\z/;
    return '' if $value =~ /\A(?:XX|ZZ|T1|A1|A2|O1)\z/;
    return $value;
}

sub _clean_geo {
    my ($value) = @_;
    $value = _trim($value);
    $value =~ s/\s+/ /g;
    return '' if $value =~ /[\r\n<>"\\]/;
    return substr($value, 0, 120);
}

sub _clean_meta {
    my ($value) = @_;
    $value = _trim($value);
    $value =~ s/\s+/ /g;
    return '' if $value =~ /[\r\n<>"\\]/;
    return substr($value, 0, 180);
}

sub _trim {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

sub _blob_cmp {
    my ($left, $right) = @_;
    $left = '' unless defined $left;
    $right = '' unless defined $right;
    use bytes;
    return $left cmp $right;
}

1;
