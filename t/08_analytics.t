use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use Encode qw(encode);
use IO::Compress::Gzip qw(gzip $GzipError);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Analytics;
use DesertCMS::App;
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::GeoIP;
use DesertCMS::HTTP;

my $repo = getcwd();
$repo =~ s{\\}{/}g;

my $root = tempdir(CLEANUP => 1);
$root =~ s{\\}{/}g;
make_path("$root/public", "$root/originals", "$root/backups", "$root/data");

my $config_path = "$root/desertcms.conf";
open my $fh, '>', $config_path or die "cannot write $config_path: $!";
print {$fh} <<"CONF";
site_name = Analytics Test
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
trusted_proxy_cidrs = 10.0.0.2/32
CONF
close $fh;

local $ENV{DESERTCMS_CONFIG} = $config_path;

my $config = DesertCMS::Config->load;
$config->app_secret;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
my $us_flag = join '', map { chr(0x1F1E6 + ord($_) - ord('A')) } split //, 'US';

my $geoip_path = "$root/data/geoip.tsv";
open my $geoip_fh, '>', $geoip_path or die "cannot write $geoip_path: $!";
print {$geoip_fh} <<"GEOIP";
network\tcountry\tregion\tcity
203.0.113.0/24\tUnited States\tArizona\tFlagstaff
2001:db8::/32\tExampleland\tHigh Desert\tMesa Test
GEOIP
close $geoip_fh;

my $import = DesertCMS::GeoIP::import_file($db, path => $geoip_path, source => 'test geoip');
is($import->{imported}, 2, 'imports local GeoIP ranges');
my $geoip_append_path = "$root/data/geoip-append.tsv";
open my $geoip_append_fh, '>', $geoip_append_path or die "cannot write $geoip_append_path: $!";
print {$geoip_append_fh} <<"GEOIP";
network\tcountry\tregion\tcity
198.51.100.0/24\tCanada\tOntario\tToronto
GEOIP
close $geoip_append_fh;
my $append = DesertCMS::GeoIP::import_file($db, path => $geoip_append_path, source => 'append geoip', append => 1);
is($append->{imported}, 1, 'appends local GeoIP ranges');

my $dbip_path = "$root/data/dbip-city-lite-test.csv.gz";
my $dbip_csv = <<"GEOIP";
0.0.0.0,0.255.255.255,ZZ,ZZ,,,0,0
192.0.2.0,192.0.2.255,NA,US,California,Los Angeles,34.0522,-118.2437
GEOIP
gzip(\$dbip_csv => $dbip_path) or die "cannot write DB-IP fixture: $GzipError";
my $dbip_import = DesertCMS::GeoIP::import_file($db, path => $dbip_path, source => 'DB-IP City Lite test', append => 1);
is($dbip_import->{imported}, 1, 'imports compressed DB-IP City Lite ranges');
my $dbip_geo = DesertCMS::GeoIP::lookup($db, '192.0.2.42');
is($dbip_geo->{country_code}, 'US', 'DB-IP import stores country code');
is($dbip_geo->{country}, 'US', 'DB-IP import stores country code as country label');
is($dbip_geo->{region}, 'California', 'DB-IP import stores state');
is($dbip_geo->{city}, 'Los Angeles', 'DB-IP import stores city');

my $geoip_status = DesertCMS::GeoIP::status($db);
is($geoip_status->{count}, 4, 'reports imported GeoIP range count');
my $ipv6_geo = DesertCMS::GeoIP::lookup($db, '2001:db8::25');
is($ipv6_geo->{city}, 'Mesa Test', 'looks up IPv6 CIDR ranges');
is($ipv6_geo->{country_code}, '', 'unknown country names do not invent a flag code');

my $request = bless {
    form => {
        path     => '/posts/one/?secret=drop',
        referrer => 'https://referrer.example/search?q=hidden',
    },
    query      => {},
    ip_address => '203.0.113.10',
    user_agent => 'Test Browser',
    dnt        => '',
}, 'DesertCMS::HTTP';

ok(DesertCMS::Analytics::record($config, $db, $request), 'records analytics event');

my $row = $db->dbh->selectrow_hashref('SELECT * FROM analytics_events LIMIT 1');
is($row->{path}, '/posts/one/', 'stores path without query string');
is($row->{referrer}, 'https://referrer.example/search', 'stores referrer without query string');
isnt($row->{ip_hash}, '203.0.113.10', 'does not store raw IP');
like($row->{ip_hash}, qr/\A[0-9a-f]{64}\z/, 'stores HMAC IP hash');
is($row->{ip_address}, '203.0.113.10', 'stores display IP when configured');
is($row->{country_code}, 'US', 'stores local GeoIP country code');
is($row->{country}, 'United States', 'uses local GeoIP country when headers are absent');
is($row->{region}, 'Arizona', 'uses local GeoIP region when headers are absent');
is($row->{city}, 'Flagstaff', 'uses local GeoIP city when headers are absent');

ok(DesertCMS::Analytics::record($config, $db, bless({
    form => {
        path => '/gallery/',
        referrer => '',
    },
    query => {},
    ip_address => '10.0.0.2',
    forwarded_for => '198.51.100.10:443',
    geo_country => 'US',
    geo_region => 'New Mexico',
    geo_city => 'Santa Fe',
    user_agent => 'Test Browser',
    dnt => '',
}, 'DesertCMS::HTTP')), 'records forwarded IP and geo event');

my $geo_row = $db->dbh->selectrow_hashref("SELECT * FROM analytics_events WHERE path = '/gallery/' LIMIT 1");
is($geo_row->{ip_address}, '198.51.100.10', 'uses first forwarded IP for display');
is($geo_row->{country_code}, 'US', 'stores country code from geo headers');
is($geo_row->{country}, 'US', 'stores country detail');
is($geo_row->{region}, 'New Mexico', 'stores region detail');
is($geo_row->{city}, 'Santa Fe', 'stores city detail');

$db->dbh->do(
    q{
        INSERT INTO analytics_events
            (path, ip_hash, ip_address, user_agent_hash, referrer, country, region, city, occurred_at)
        VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    '/legacy/',
    'legacy-ip-hash',
    '203.0.113.77',
    'legacy-ua-hash',
    '',
    '',
    '',
    '',
    time
);
my $backfill = DesertCMS::GeoIP::backfill_events($db);
is($backfill->{updated}, 1, 'backfills old unknown analytics rows from local GeoIP');
my $backfilled = $db->dbh->selectrow_hashref("SELECT country_code, country, region, city FROM analytics_events WHERE path = '/legacy/' LIMIT 1");
is($backfilled->{country_code}, 'US', 'backfill stores country code');

ok(!DesertCMS::Analytics::record($config, $db, bless({
    form => { path => '/admin' },
    query => {},
    ip_address => '203.0.113.11',
    user_agent => 'Test Browser',
    dnt => '',
}, 'DesertCMS::HTTP')), 'does not record admin path');

ok(!DesertCMS::Analytics::record($config, $db, bless({
    form => { path => '/posts/two/' },
    query => {},
    ip_address => '203.0.113.12',
    user_agent => 'Test Browser',
    dnt => '1',
}, 'DesertCMS::HTTP')), 'respects do not track');

my $summary = DesertCMS::Analytics::summary($config, $db, days => 30);
is($summary->{visits}, 3, 'summary counts visits');
is($summary->{unique_ips}, 3, 'summary counts unique IP hashes');
ok((grep { $_->{path} eq '/posts/one/' } @{$summary->{top_pages}}), 'summary includes popular page');
is($summary->{top_ips}[0]{visits}, 1, 'summary counts visits by IP hash');
ok((grep { $_->{country} eq 'US' } @{$summary->{locations}}), 'summary groups locations');
ok((grep { $_->{location_label} eq "$us_flag Flagstaff, Arizona" } @{$summary->{city_locations}}), 'summary includes city-level locations with country flag');
ok((grep { $_->{location_label} eq "$us_flag Santa Fe, New Mexico" } @{$summary->{recent}}), 'summary labels visit location with country flag');
is($summary->{geo_known_visits}, 3, 'summary counts resolved locations');
is($summary->{geo_unknown_visits}, 0, 'summary counts unresolved locations');
is($summary->{daily}[-1]{visits}, 3, 'summary includes daily chart data');
my $trend_html = DesertCMS::App::_trend_chart([
    { day => _day_key(time - 86400), visits => 2, unique_ips => 1 },
    { day => _day_key(time), visits => 4, unique_ips => 2 },
], 'No visits.');
like($trend_html, qr/class="trend-day" style="--bar-height: 50%"/, 'trend chart renders proportional half-height bar');
like($trend_html, qr/class="trend-day" style="--bar-height: 100%"/, 'trend chart renders proportional full-height bar');
like(
    DesertCMS::App::_trend_chart([], 'No visits.'),
    qr/class="dashboard-empty".*Waiting for data.*No visits\./s,
    'trend chart renders designed empty state'
);
my $rank_html = DesertCMS::App::_rank_chart([
    { path => '/small/', visits => 1 },
    { path => '/large/', visits => 4 },
], sub { $_[0]->{path} }, sub { $_[0]->{visits} }, 'No ranks.');
like($rank_html, qr/class="rank-track"><b style="width: 25%"><\/b>/, 'rank chart renders proportional quarter-width fill');
like($rank_html, qr/class="rank-track"><b style="width: 100%"><\/b>/, 'rank chart renders proportional full-width fill');
like(
    DesertCMS::App::_metric_card('Geo coverage', '80%', '2 unresolved visits', 'warn'),
    qr/class="metric-card metric-card--warn".*Geo coverage.*80%.*2 unresolved visits/s,
    'metric card renders warning state'
);
like(
    DesertCMS::App::_dashboard_alerts(
        {
            analytics_enabled => 0,
            geoip_state       => 'warn',
            geoip_alert       => 'GeoIP data has not been imported.',
            sitemap_present   => 0,
            robots_present    => 1,
            backup_count      => 0,
        },
        { visits => 10, geo_unknown_visits => 2 }
    ),
    qr/class="dashboard-alerts".*Analytics collection is disabled.*2 visit\(s\) do not have a resolved location.*No backups/s,
    'dashboard alerts render distinct warning strip'
);
like(
    DesertCMS::App::_table_rows([{ path => '/one/', visits => 2 }], [
        { label => 'Path', value => 'path' },
        { label => 'Visits', value => 'visits' },
    ], 'No rows.'),
    qr/<td data-label="Path">\/one\/<\/td><td data-label="Visits">2<\/td>/,
    'dashboard table rows include mobile labels'
);

my ($count) = $db->dbh->selectrow_array('SELECT COUNT(*) FROM analytics_events');
is($count, 3, 'only valid events persisted');

$db->dbh->do(
    q{
        INSERT INTO analytics_events
            (path, ip_hash, ip_address, user_agent_hash, referrer, country, region, city, occurred_at)
        VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    '/dbip-observed/',
    'observed-ip-hash',
    '192.0.2.77',
    'observed-ua-hash',
    '',
    '',
    '',
    '',
    time
);
my $observed_import = DesertCMS::GeoIP::import_dbip_observed_ranges($db, path => $dbip_path, source => 'DB-IP observed test');
is($observed_import->{observed}, 4, 'observed import sees stored public IPv4 addresses');
is($observed_import->{matched}, 1, 'observed import matches only DB-IP-backed observed ranges');
is($observed_import->{imported}, 1, 'observed import stores matched DB-IP range');
my $observed_backfill = DesertCMS::GeoIP::backfill_events($db);
is($observed_backfill->{updated}, 1, 'observed import backfills matching analytics row');
my $observed_row = $db->dbh->selectrow_hashref("SELECT country_code, region, city FROM analytics_events WHERE path = '/dbip-observed/' LIMIT 1");
is($observed_row->{country_code}, 'US', 'observed import stores country code');
is($observed_row->{region}, 'California', 'observed import stores region');
is($observed_row->{city}, 'Los Angeles', 'observed import stores city');

my $fr_flag = join '', map { chr(0x1F1E6 + ord($_) - ord('A')) } split //, 'FR';
my $ile_de_france = chr(0x00CE) . 'le-de-France';
is(
    DesertCMS::Analytics::location_label({
        country_code => 'FR',
        city         => 'Paris',
        region       => encode('UTF-8', $ile_de_france),
    }),
    "$fr_flag Paris, $ile_de_france",
    'location label decodes UTF-8 bytes before adding country flag'
);

done_testing;

sub _day_key {
    my ($ts) = @_;
    my ($mday, $mon, $year) = (localtime($ts))[3, 4, 5];
    return sprintf('%04d-%02d-%02d', $year + 1900, $mon + 1, $mday);
}
