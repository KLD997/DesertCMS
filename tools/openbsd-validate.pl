#!/usr/bin/env perl

use strict;
use warnings;
use File::Find qw(find);
use File::Spec;

my %opt = (
    config   => '/etc/desertcms.conf',
    app_root => '/usr/local/www/desertcms',
    domain   => '',
    allow_pending_tls => 0,
);

while (@ARGV) {
    my $arg = shift @ARGV;
    if ($arg eq '--config') {
        $opt{config} = shift @ARGV || die "--config requires a path\n";
        next;
    }
    if ($arg eq '--app-root') {
        $opt{app_root} = shift @ARGV || die "--app-root requires a path\n";
        next;
    }
    if ($arg eq '--domain') {
        $opt{domain} = shift @ARGV || die "--domain requires a value\n";
        next;
    }
    if ($arg eq '--allow-pending-tls') {
        $opt{allow_pending_tls} = 1;
        next;
    }
    die "usage: $0 [--config /etc/desertcms.conf] [--app-root /usr/local/www/desertcms] [--domain example.com] [--allow-pending-tls]\n";
}

my $failures = 0;
my $warnings = 0;

section('OpenBSD platform');
my $os = chomped(qx(uname -s 2>/dev/null));
my $release = chomped(qx(uname -r 2>/dev/null));
check($os eq 'OpenBSD', "running on OpenBSD", "uname -s returned '$os'");
if ($release =~ /\A\d+\.\d+\z/) {
    pass("OpenBSD release is $release");
} else {
    warn_check("OpenBSD release could not be detected") if $os eq 'OpenBSD';
}

section('Required commands and packages');
for my $cmd (qw(perl pkg_info vips vipsthumbnail vipsheader tar pfctl httpd rcctl acme-client slowcgi doas nc crontab)) {
    check(command_exists($cmd), "command available: $cmd", "missing command: $cmd");
}
for my $pkg (qw(p5-DBI p5-DBD-SQLite p5-IO-Socket-SSL p5-Net-SSLeay libvips p5-HTTP-Daemon)) {
    check(package_stem_installed($pkg), "package installed: $pkg", "missing package: $pkg");
}
check(system('perl', '-MDBI', '-MDBD::SQLite', '-MJSON::PP', '-MHTTP::Tiny', '-MIO::Socket::SSL', '-MNet::SSLeay', '-MMIME::Base64', '-MIO::Uncompress::Gunzip', '-e', '1') == 0, 'required Perl modules load', 'Perl DBI/DBD::SQLite/JSON::PP/HTTP::Tiny/IO::Socket::SSL/Net::SSLeay/MIME::Base64/IO::Uncompress::Gunzip modules did not load');

section('Configuration files');
my %conf = read_config($opt{config});
my $admin_settings = admin_settings();
$opt{domain} ||= site_domain($conf{site_url});
my $shop_domain = dedicated_shop_domain(\%conf, $opt{domain});
for my $file ($opt{config}, '/etc/httpd.conf', '/etc/pf.conf', '/etc/acme-client.conf', '/etc/doas.conf', '/etc/rc.d/desertcms_slowcgi') {
    check(-f $file, "file exists: $file", "missing file: $file");
}
check(system('doas', '-C', '/etc/doas.conf') == 0, 'doas.conf validates', 'doas.conf failed validation');
check(system('pfctl', '-nf', '/etc/pf.conf') == 0, 'pf.conf validates', 'pf.conf failed validation');
check(system('httpd', '-n') == 0, 'httpd.conf validates', 'httpd.conf failed validation');
my $pf_conf = read_file('/etc/pf.conf');
validate_firewall($pf_conf);
my $admin_upload_min = 64 * 1024 * 1024;
my $httpd_body_limit = httpd_max_request_body('/etc/httpd.conf');
check(
    $httpd_body_limit >= $admin_upload_min,
    'httpd permits 64 MB admin upload bodies',
    'httpd max request body is ' . ($httpd_body_limit || 0) . " bytes, expected at least $admin_upload_min"
);
my $httpd_conf = read_file('/etc/httpd.conf');
for my $route (httpd_dynamic_routes()) {
    check(
        $httpd_conf =~ /location\s+"\Q\/$route\E\*"/,
        "httpd forwards the /$route route",
        "httpd is missing the /$route* FastCGI route"
    );
    check(
        $httpd_conf =~ /param\s+SCRIPT_NAME\s+"\Q\/$route\E"/,
        "httpd maps /$route to the CGI prefix",
        "httpd is missing SCRIPT_NAME /$route"
    );
}
if ($shop_domain) {
    check(valid_domain($shop_domain), "shop domain syntax is valid: $shop_domain", "shop_domain is not a valid domain: $shop_domain");
    check($httpd_conf =~ /server\s+"\Q$shop_domain\E"/, "httpd has a shop server block for $shop_domain", "httpd is missing a server block for $shop_domain");
    check($httpd_conf =~ /location\s+"\/stripe\/\*"/, 'httpd forwards the Stripe webhook route', 'httpd is missing the /stripe/* shop FastCGI route');
}
my $commerce_model = $conf{commerce_model} || (($conf{shop_enabled} || '') eq '0' ? 'disabled' : 'master_owned');
if ($commerce_model =~ /\A(?:disabled|master_owned|contributor_owned|marketplace_pending)\z/) {
    pass("commerce model is $commerce_model");
} else {
    warn_check("commerce model is not recognized: $commerce_model");
}
if ($commerce_model eq 'disabled') {
    pass('Stripe keys are optional while commerce is disabled');
} elsif ($commerce_model eq 'marketplace_pending') {
    warn_check('marketplace commerce needs Stripe Connect before direct checkout should be enabled');
} else {
    if (($admin_settings->{stripe_secret_key} || $conf{stripe_secret_key} || '') =~ /\Ask_(?:test|live)_/) {
        pass('Stripe secret key is configured');
    } else {
        warn_check('Stripe secret key is not configured yet');
    }
    if (($admin_settings->{stripe_webhook_secret} || $conf{stripe_webhook_secret} || '') =~ /\Awhsec_/) {
        pass('Stripe webhook secret is configured');
    } else {
        warn_check('Stripe webhook secret is not configured yet');
    }
}

section('Provider hooks and readiness');
validate_postmark_transport();
my $postmark = postmark_settings(\%conf, $admin_settings);
my $postmark_source = $postmark->{source_label} || 'this CMS instance';
if (valid_email_address($postmark->{from_email} || '') && length($postmark->{token} || '')) {
    pass("Postmark sender and server token are configured via $postmark_source");
} else {
    warn_check("Postmark sender or server token is not configured yet for $postmark_source");
}
if (($postmark->{webhook_token} || '') =~ /\A[0-9a-f]{48}\z/i) {
    pass('Postmark bounce/spam webhook token is configured');
} else {
    warn_check('Postmark bounce/spam webhook token is not configured yet');
}
if ($commerce_model eq 'disabled') {
    pass('Stripe checkout webhooks are optional while commerce is disabled');
} elsif (($admin_settings->{stripe_webhook_secret} || $conf{stripe_webhook_secret} || '') =~ /\Awhsec_/) {
    pass('Stripe checkout webhook secret is configured');
} else {
    warn_check('Stripe checkout webhook secret is not configured yet');
}
validate_provider_webhook_endpoints($httpd_conf, $postmark);

section('Filesystem layout');
my $data_dir = required_conf(\%conf, 'data_dir');
my $public_root = required_conf(\%conf, 'public_root');
my $originals_dir = required_conf(\%conf, 'originals_dir');
my $backup_dir = required_conf(\%conf, 'backup_dir');
my $theme_dir = required_conf(\%conf, 'theme_dir');
my $db_path = required_conf(\%conf, 'db_path');
my $upgrade_dir = File::Spec->catdir($data_dir, 'upgrades');
my $font_package_dir = File::Spec->catdir($data_dir, 'font-packages');

check_dir($opt{app_root}, 'root', 'wheel');
check_dir($data_dir, '_desertcms', '_desertcms');
check_dir($originals_dir, '_desertcms', '_desertcms');
check_dir($backup_dir, '_desertcms', '_desertcms');
check_dir($theme_dir, '_desertcms', '_desertcms');
check_dir($upgrade_dir, '_desertcms', '_desertcms');
check_dir($font_package_dir, '_desertcms', '_desertcms');
check_dir($public_root, '_desertcms', '_desertcms');
check_public_root_tree_owner($public_root, '_desertcms', '_desertcms');
check(-x File::Spec->catfile($opt{app_root}, 'bin', 'desertcms.cgi'), 'CGI entrypoint is executable', 'CGI entrypoint is missing or not executable');
check(-x File::Spec->catfile($opt{app_root}, 'bin', 'desertcms-maint.pl'), 'maintenance script is executable', 'maintenance script is missing or not executable');
check(-x File::Spec->catfile($opt{app_root}, 'tools', 'openbsd-apply-site-queue.pl'), 'site queue worker is executable', 'site queue worker is missing or not executable');
check(-x File::Spec->catfile($opt{app_root}, 'tools', 'openbsd-apply-upgrade.pl'), 'upgrade worker is executable', 'upgrade worker is missing or not executable');
check(-x File::Spec->catfile($opt{app_root}, 'tools', 'openbsd-apply-font-packages.pl'), 'font package worker is executable', 'font package worker is missing or not executable');
check(-x File::Spec->catfile($opt{app_root}, 'tools', 'openbsd-operations-worker.pl'), 'operations worker is executable', 'operations worker is missing or not executable');
check(path_outside($originals_dir, $public_root), 'private source assets are outside public webroot', 'originals_dir is under public_root');
my $root_cron = root_crontab();
check($root_cron =~ /openbsd-apply-site-queue\.pl\b.*--quiet/, 'root cron runs the contributor site queue worker', 'root cron is missing the contributor site queue worker');
check($root_cron =~ /openbsd-apply-upgrade\.pl\b.*--quiet/, 'root cron runs the upgrade worker', 'root cron is missing the upgrade worker');
check($root_cron =~ /openbsd-operations-worker\.pl\b.*--quiet/, 'root cron runs the operations worker', 'root cron is missing the operations worker');
if ($root_cron =~ /openbsd-apply-font-packages\.pl\b.*--config\s+\Q$opt{config}\E\b.*--quiet/) {
    pass("root cron runs the font package worker for $opt{config}");
} elsif ($opt{config} eq '/etc/desertcms.conf') {
    fail("root cron is missing the font package worker for $opt{config}");
} else {
    warn_check("root cron does not include a font package worker for $opt{config}");
}

section('Local asset boundary');
my $asset_tool = File::Spec->catfile($opt{app_root}, 'tools', 'check-local-assets.pl');
check(-f $asset_tool, 'local asset audit tool installed', 'missing local asset audit tool');
check(system('perl', $asset_tool, '--quiet') == 0, 'runtime assets have no remote CDN references', 'remote runtime asset reference found');
check(-f File::Spec->catfile($public_root, 'assets', 'site.css'), 'public CSS has been published', 'missing public assets/site.css');

section('Database');
eval {
    require DBI;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", '', '', { RaiseError => 1, PrintError => 0 });
    for my $table (expected_database_tables($opt{app_root})) {
        my ($count) = $dbh->selectrow_array("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", undef, $table);
        check($count, "database table exists: $table", "missing database table: $table");
    }
    my ($admins) = $dbh->selectrow_array('SELECT COUNT(*) FROM admin_users WHERE disabled_at IS NULL');
    my $is_contributor_instance = length($conf{contributor_site_id} || '') || length($conf{contributor_domain} || '');
    check(
        ($admins || 0) >= 1,
        $is_contributor_instance ? 'at least one active contributor site user exists' : 'at least one active CMS admin exists',
        'no active CMS admin users exist'
    );
    my ($forced) = $dbh->selectrow_array('SELECT COUNT(*) FROM admin_users WHERE force_password_change = 1 AND disabled_at IS NULL');
    if ($forced && $forced >= 1) {
        pass('temporary CMS admin is still forced to change credentials on first login');
    } else {
        warn_check('no forced-change CMS admin remains; this is expected after the first login setup is completed');
    }
    my ($geoip_ranges) = $dbh->selectrow_array('SELECT COUNT(*) FROM analytics_geoip_ranges');
    if ($geoip_ranges && $geoip_ranges > 0) {
        pass("GeoIP analytics ranges are imported: $geoip_ranges");
    } else {
        warn_check('GeoIP analytics ranges are not imported yet; run geoip-refresh-dbip-lite or geoip-import to enrich local analytics');
    }
    validate_email_delivery_health($dbh);
    validate_payment_workflow_health($dbh);
    validate_hosted_contributor_sites($dbh, \%conf, $httpd_conf);
    validate_site_provisioning_queue($dbh, \%conf);
    $dbh->disconnect;
    1;
} or do {
    my $err = $@ || 'unknown database validation failure';
    fail("database validation failed: $err");
};

section('Services and ports');
check(system('rcctl', 'check', 'desertcms_slowcgi') == 0, 'desertcms_slowcgi is running', 'desertcms_slowcgi is not running');
check(system('rcctl', 'check', 'httpd') == 0, 'httpd is running', 'httpd is not running');
check(system('nc', '-z', '127.0.0.1', '80') == 0, 'local TCP 80 is listening', 'local TCP 80 is not listening');
if (-f "/etc/ssl/$opt{domain}.fullchain.pem") {
    check(system('nc', '-z', '127.0.0.1', '443') == 0, 'local TCP 443 is listening', 'local TCP 443 is not listening');
} else {
    warn_check('TLS certificate is not present yet, so TCP 443 may not be active');
}

section('DNS and TLS');
if ($opt{domain}) {
    my @addresses = host_addresses($opt{domain});
    if (@addresses) {
        pass("$opt{domain} resolves to " . join(', ', @addresses));
    } else {
        warn_check("$opt{domain} did not return A/AAAA results through host(1)");
    }
    check_tls_file("/etc/ssl/$opt{domain}.fullchain.pem", "TLS certificate exists for $opt{domain}", "missing TLS certificate for $opt{domain}");
    check_tls_file("/etc/ssl/private/$opt{domain}.key", "TLS private key exists for $opt{domain}", "missing TLS private key for $opt{domain}");
} else {
    warn_check('domain is unknown; pass --domain example.com to validate DNS and TLS files');
}
if ($shop_domain) {
    my @shop_addresses = host_addresses($shop_domain);
    if (@shop_addresses) {
        pass("$shop_domain resolves to " . join(', ', @shop_addresses));
    } else {
        warn_check("$shop_domain did not return A/AAAA results through host(1)");
    }
}

section('Summary');
if ($failures) {
    print "FAILED: $failures failure(s), $warnings warning(s)\n";
    exit 1;
}
print "PASSED: 0 failures, $warnings warning(s)\n";
exit 0;

sub section {
    my ($title) = @_;
    print "\n$title\n";
    print '-' x length($title), "\n";
}

sub pass {
    my ($message) = @_;
    print "[PASS] $message\n";
}

sub fail {
    my ($message) = @_;
    ++$failures;
    print "[FAIL] $message\n";
}

sub warn_check {
    my ($message) = @_;
    ++$warnings;
    print "[WARN] $message\n";
}

sub check {
    my ($ok, $good, $bad) = @_;
    $ok ? pass($good) : fail($bad);
}

sub check_tls_file {
    my ($path, $good, $bad) = @_;
    if (-f $path) {
        pass($good);
    } elsif ($opt{allow_pending_tls}) {
        warn_check("$bad; TLS is pending");
    } else {
        fail($bad);
    }
}

sub command_exists {
    my ($cmd) = @_;
    return system('/bin/sh', '-c', 'command -v ' . shell_quote($cmd) . ' >/dev/null 2>&1') == 0;
}

sub package_stem_installed {
    my ($stem) = @_;
    my $out = qx(pkg_info -q 2>/dev/null);
    for my $pkg (split /\n/, $out) {
        return 1 if $pkg =~ /^\Q$stem\E(?:-|$)/;
    }
    return 0;
}

sub check_dir {
    my ($path, $user, $group) = @_;
    check(-d $path, "directory exists: $path", "missing directory: $path");
    return unless -d $path;
    my @st = stat($path);
    my $actual_user = getpwuid($st[4]) || $st[4];
    my $actual_group = getgrgid($st[5]) || $st[5];
    check($actual_user eq $user, "$path owner is $user", "$path owner is $actual_user, expected $user");
    check($actual_group eq $group, "$path group is $group", "$path group is $actual_group, expected $group");
}

sub check_public_root_tree_owner {
    my ($path, $user, $group) = @_;
    return unless -d $path;
    my $uid = getpwnam($user);
    my $gid = getgrnam($group);
    if (!defined $uid || !defined $gid) {
        fail("cannot check public root ownership drift because $user:$group does not resolve");
        return;
    }

    my @drift;
    my $limit = 10;
    my $stop = "__desertcms_public_root_ownership_limit__\n";
    my $ok = eval {
        find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return if @drift >= $limit;
                    my $item = $File::Find::name;
                    my @st = lstat($item);
                    if (!@st) {
                        push @drift, "$item (cannot stat: $!)";
                    } elsif ($st[4] != $uid || $st[5] != $gid) {
                        my $actual_user = getpwuid($st[4]) || $st[4];
                        my $actual_group = getgrgid($st[5]) || $st[5];
                        push @drift, "$item ($actual_user:$actual_group)";
                    }
                    die $stop if @drift >= $limit;
                },
            },
            $path
        );
        1;
    };
    die $@ if !$ok && ($@ || '') ne $stop;

    if (@drift) {
        fail('public root ownership drift detected; expected ' . "$user:$group" . '; examples: ' . join('; ', @drift));
    } else {
        pass("public root tree is owned by $user:$group");
    }
}

sub validate_firewall {
    my ($pf_conf) = @_;
    section('Firewall');
    my $pf_boot = chomped(qx(rcctl get pf 2>/dev/null));
    check($pf_boot =~ /\Apf=YES\z/, 'pf is enabled at boot', 'pf is not enabled at boot');

    my $pf_info = qx(pfctl -s info 2>/dev/null);
    check($pf_info =~ /^Status:\s+Enabled\b/m, 'pf packet filter is currently enabled', 'pf packet filter is not currently enabled');

    check($pf_conf =~ /^\s*table\s+<ssh_admins>\s+persist\s+\{[^}]+\}/m, 'pf.conf defines the SSH admin allowlist table', 'pf.conf is missing the <ssh_admins> allowlist table');
    check($pf_conf =~ /^\s*block\s+log\s+all\b/m, 'pf.conf blocks inbound traffic by default', 'pf.conf is missing the default inbound block rule');
    check($pf_conf =~ /^\s*pass\s+out\s+quick\s+all\s+keep\s+state\b/m, 'pf.conf permits outbound traffic with state', 'pf.conf is missing outbound stateful traffic rule');
    check($pf_conf =~ /from\s+<ssh_admins>.*\bport\s+[0-9]{1,5}\b/s, 'pf.conf restricts SSH to the admin allowlist', 'pf.conf is missing the SSH allowlist rule');
    check($pf_conf =~ /port\s+\{[^}]*\b80\b[^}]*\b443\b[^}]*\}/s, 'pf.conf opens public HTTP and HTTPS ports', 'pf.conf does not open both TCP 80 and 443');

    my $pf_rules = qx(pfctl -s rules 2>/dev/null);
    check($pf_rules =~ /^\s*block\s+drop\s+log\s+all\b/m || $pf_rules =~ /^\s*block\s+log\s+all\b/m, 'loaded pf rules include the default block policy', 'loaded pf rules are missing the default block policy');
    check($pf_rules =~ /pass\s+in\s+quick\s+on\s+\S+\s+proto\s+tcp\s+from\s+<ssh_admins>.*\bport\s+=\s+[0-9]{1,5}\b/s, 'loaded pf rules restrict SSH to the admin allowlist', 'loaded pf rules are missing the SSH allowlist rule');
    check($pf_rules =~ /pass\s+in\s+quick\s+on\s+\S+\s+proto\s+tcp\s+from\s+any.*\bport\s+=\s+80\b/s, 'loaded pf rules allow public HTTP', 'loaded pf rules do not allow TCP 80');
    check($pf_rules =~ /pass\s+in\s+quick\s+on\s+\S+\s+proto\s+tcp\s+from\s+any.*\bport\s+=\s+443\b/s, 'loaded pf rules allow public HTTPS', 'loaded pf rules do not allow TCP 443');
}

sub read_config {
    my ($path) = @_;
    my %config;
    my $fh;
    if (!open $fh, '<', $path) {
        fail("cannot read config $path: $!");
        return %config;
    }
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/#.*$//;
        next unless $line =~ /\S/;
        if ($line =~ /^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/) {
            $config{$1} = $2;
        }
    }
    close $fh;
    return %config;
}

sub admin_settings {
    my $settings = eval {
        unshift @INC, File::Spec->catdir($opt{app_root}, 'lib');
        require DesertCMS::Config;
        require DesertCMS::DB;
        require DesertCMS::Settings;
        my $config = DesertCMS::Config->load($opt{config});
        my $db = DesertCMS::DB->new(config => $config);
        DesertCMS::Settings::all($config, $db);
    };
    return $settings && ref $settings eq 'HASH' ? $settings : {};
}

sub postmark_settings {
    my ($conf, $settings) = @_;
    my $resolved = eval {
        unshift @INC, File::Spec->catdir($opt{app_root}, 'lib');
        require DesertCMS::Config;
        require DesertCMS::DB;
        require DesertCMS::Settings;
        require DesertCMS::Email;
        my $config = DesertCMS::Config->load($opt{config});
        my $db = DesertCMS::DB->new(config => $config);
        my $all = $settings && ref $settings eq 'HASH' && scalar keys %{$settings}
            ? $settings
            : DesertCMS::Settings::all($config, $db);
        DesertCMS::Email::resolved_postmark_settings($config, $db, $all);
    };
    return $resolved if $resolved && ref $resolved eq 'HASH';
    return {
        source_label  => 'configuration file',
        from_email    => $settings->{postmark_from_email} || $conf->{postmark_from_email} || '',
        token         => $settings->{postmark_server_token} || $conf->{postmark_server_token} || '',
        webhook_token => $settings->{postmark_webhook_token} || $conf->{postmark_webhook_token} || '',
    };
}

sub validate_postmark_transport {
    my $status = eval {
        unshift @INC, File::Spec->catdir($opt{app_root}, 'lib');
        require DesertCMS::Email;
        DesertCMS::Email::postmark_https_transport_status();
    };
    if ($status && ref $status eq 'HASH' && $status->{ok}) {
        pass('Postmark HTTPS transport is available to DesertCMS');
        return;
    }
    my $detail = $status && ref $status eq 'HASH'
        ? ($status->{detail} || $status->{install_hint} || 'unknown transport issue')
        : ($@ || 'DesertCMS::Email could not be loaded');
    $detail =~ s/\s+/ /g;
    warn_check("Postmark HTTPS transport is not ready for DesertCMS: $detail");
}

sub validate_provider_webhook_endpoints {
    my ($httpd_conf, $postmark) = @_;
    section('Provider webhook endpoints');

    my $app_source = read_file(File::Spec->catfile($opt{app_root}, 'lib', 'DesertCMS', 'App.pm'));
    my @stripe_endpoints = (
        [ '/stripe/webhook',          '/stripe',   'Shop / Catalog checkout webhook' ],
        [ '/billing/stripe/webhook',  '/billing',  'hosted service billing webhook' ],
        [ '/events/stripe/webhook',   '/events',   'Events ticket webhook' ],
        [ '/bookings/stripe/webhook', '/bookings', 'Bookings deposit webhook' ],
        [ '/donate/stripe/webhook',   '/donate',   'Donations webhook' ],
    );

    for my $endpoint (@stripe_endpoints) {
        my ($path, $prefix, $label) = @{$endpoint};
        check(
            httpd_forwards_prefix($httpd_conf, $prefix),
            "httpd forwards $label at $path",
            "httpd does not forward $label at $path"
        );
        check(
            $app_source =~ /\Q$path\E/,
            "application dispatches $label at $path",
            "application does not dispatch $label at $path"
        );
    }

    check(
        httpd_forwards_prefix($httpd_conf, '/postmark'),
        'httpd forwards Postmark bounce/spam webhook endpoint',
        'httpd does not forward Postmark bounce/spam webhook endpoint'
    );
    check(
        $app_source =~ m{postmark/webhook/\(\[0-9a-fA-F\]\{48\}\)},
        'application dispatches tokenized Postmark bounce/spam webhook endpoint',
        'application does not dispatch tokenized Postmark bounce/spam webhook endpoint'
    );
    if (($postmark->{webhook_token} || '') =~ /\A[0-9a-f]{48}\z/i) {
        pass('Postmark tokenized webhook endpoint can be configured in Postmark');
    } else {
        warn_check('Postmark tokenized webhook endpoint is routed but cannot be used until a webhook token is configured');
    }
}

sub validate_email_delivery_health {
    my ($dbh) = @_;
    section('Email delivery health');

    my $rows = eval {
        $dbh->selectall_arrayref(
            q{
                SELECT id, status, email_type, to_email, reason, updated_at
                FROM email_delivery_logs
                WHERE status IN ('failed', 'bounced', 'spam', 'complaint')
                  AND updated_at >= ?
                ORDER BY updated_at DESC, id DESC
                LIMIT 5
            },
            { Slice => {} },
            time - 7 * 24 * 60 * 60
        );
    };
    if (!$rows) {
        fail('could not read email_delivery_logs for delivery health validation: ' . ($@ || 'unknown error'));
        return;
    }

    my ($total) = eval {
        $dbh->selectrow_array('SELECT COUNT(*) FROM email_delivery_logs');
    };
    if (!$total) {
        pass('email delivery log is readable; no delivery attempts recorded yet');
        return;
    }

    if (!@{$rows}) {
        pass('no failed, bounced, spam, or complaint email delivery events in the last 7 days');
        return;
    }

    my ($count) = eval {
        $dbh->selectrow_array(
            q{
                SELECT COUNT(*)
                FROM email_delivery_logs
                WHERE status IN ('failed', 'bounced', 'spam', 'complaint')
                  AND updated_at >= ?
            },
            undef,
            time - 7 * 24 * 60 * 60
        );
    };
    $count ||= scalar @{$rows};
    warn_check('recent email delivery issues need review: ' . int($count) . ' (' . email_delivery_issue_examples(@{$rows}) . ')');
}

sub email_delivery_issue_examples {
    my (@rows) = @_;
    my @labels;
    for my $row (@rows[0 .. (@rows > 3 ? 2 : $#rows)]) {
        next unless $row;
        my $id = int($row->{id} || 0);
        my $status = $row->{status} || 'unknown';
        my $type = $row->{email_type} || 'email';
        my $to = $row->{to_email} || 'unknown-recipient';
        my $reason = $row->{reason} || '';
        $reason =~ s/\s+/ /g;
        $reason = substr($reason, 0, 80);
        my $label = "#$id $status/$type to $to";
        $label .= ": $reason" if length $reason;
        push @labels, $label;
    }
    push @labels, '...' if @rows > 3;
    return join('; ', @labels);
}

sub validate_payment_workflow_health {
    my ($dbh) = @_;
    section('Payment workflow health');

    my $stale_cutoff = time - 24 * 60 * 60;
    my $issue_cutoff = time - 7 * 24 * 60 * 60;
    my (@stale, @issues);
    my $total_records = 0;

    for my $spec (payment_workflow_specs()) {
        my ($total) = eval {
            $dbh->selectrow_array("SELECT COUNT(*) FROM $spec->{table}");
        };
        if ($@) {
            fail("could not read $spec->{table} for payment workflow validation: " . ($@ || 'unknown error'));
            next;
        }
        $total_records += int($total || 0);

        push @stale, @{ payment_workflow_rows(
            $dbh,
            $spec,
            where    => 'status = ? AND created_at < ?',
            bind     => [ 'pending', $stale_cutoff ],
            order_by => 'created_at ASC',
            limit    => 5,
        ) };

        my @statuses = @{ $spec->{issue_statuses} || [] };
        next unless @statuses;
        my $placeholders = join ',', map { '?' } @statuses;
        push @issues, @{ payment_workflow_rows(
            $dbh,
            $spec,
            where    => "status IN ($placeholders) AND $spec->{issue_time_col} >= ?",
            bind     => [ @statuses, $issue_cutoff ],
            order_by => "$spec->{issue_time_col} DESC",
            limit    => 5,
        ) };
    }

    if (!$total_records) {
        pass('payment workflow tables are readable; no payment attempts recorded yet');
        return;
    }

    if (@stale) {
        warn_check('stale pending payment records need webhook or checkout review: ' . scalar(@stale) . ' (' . payment_workflow_examples(@stale) . ')');
    }
    if (@issues) {
        warn_check('recent failed, canceled, refunded, or ignored payment records need review: ' . scalar(@issues) . ' (' . payment_workflow_examples(@issues) . ')');
    }
    if (!@stale && !@issues) {
        pass('no stale pending or recent failed, canceled, refunded, or ignored payment records');
    }
}

sub payment_workflow_specs {
    return (
        {
            label          => 'Service billing',
            table          => 'service_plan_checkout_sessions',
            id_expr        => 'stripe_checkout_session_id',
            subject_expr   => 'site_id',
            issue_time_col => 'created_at',
            issue_statuses => [ 'ignored' ],
        },
        {
            label          => 'Shop / Catalog',
            table          => 'shop_orders',
            id_expr        => 'id',
            subject_expr   => "COALESCE(NULLIF(customer_email, ''), 'unknown customer')",
            issue_time_col => 'updated_at',
            issue_statuses => [ 'failed', 'canceled' ],
        },
        {
            label          => 'Events',
            table          => 'event_ticket_orders',
            id_expr        => 'id',
            subject_expr   => "COALESCE(NULLIF(customer_email, ''), 'unknown attendee')",
            issue_time_col => 'updated_at',
            issue_statuses => [ 'failed', 'canceled' ],
        },
        {
            label          => 'Bookings',
            table          => 'booking_payments',
            id_expr        => 'id',
            subject_expr   => "COALESCE(NULLIF(customer_email, ''), 'unknown requester')",
            issue_time_col => 'updated_at',
            issue_statuses => [ 'failed', 'canceled' ],
        },
        {
            label          => 'Membership',
            table          => 'membership_payments',
            id_expr        => 'id',
            subject_expr   => "COALESCE(NULLIF(stripe_customer_id, ''), 'membership payment')",
            issue_time_col => 'updated_at',
            issue_statuses => [ 'failed', 'canceled', 'refunded' ],
        },
        {
            label          => 'Donations',
            table          => 'donations',
            id_expr        => 'id',
            subject_expr   => "COALESCE(NULLIF(donor_email, ''), 'anonymous donor')",
            issue_time_col => 'updated_at',
            issue_statuses => [ 'failed', 'canceled', 'refunded' ],
        },
    );
}

sub payment_workflow_rows {
    my ($dbh, $spec, %args) = @_;
    my $limit = int($args{limit} || 5);
    my $rows = eval {
        $dbh->selectall_arrayref(
            qq{
                SELECT '$spec->{label}' AS workflow,
                       $spec->{id_expr} AS id,
                       status,
                       $spec->{subject_expr} AS subject,
                       amount_cents,
                       currency,
                       created_at
                FROM $spec->{table}
                WHERE $args{where}
                ORDER BY $args{order_by}, id ASC
                LIMIT $limit
            },
            { Slice => {} },
            @{ $args{bind} || [] }
        );
    };
    if (!$rows) {
        fail("could not inspect $spec->{table} payment workflow records: " . ($@ || 'unknown error'));
        return [];
    }
    return $rows;
}

sub payment_workflow_examples {
    my (@rows) = @_;
    my @labels;
    for my $row (@rows[0 .. (@rows > 3 ? 2 : $#rows)]) {
        next unless $row;
        my $workflow = $row->{workflow} || 'Payment';
        my $id = $row->{id} || 'unknown';
        my $status = $row->{status} || 'unknown';
        my $subject = $row->{subject} || 'unknown';
        my $amount = int($row->{amount_cents} || 0);
        my $currency = lc($row->{currency} || 'usd');
        my $label = "$workflow #$id $status for $subject";
        $label .= " $currency $amount" if $amount > 0;
        $label =~ s/\s+/ /g;
        push @labels, substr($label, 0, 140);
    }
    push @labels, '...' if @rows > 3;
    return join('; ', @labels);
}

sub httpd_forwards_prefix {
    my ($httpd_conf, $prefix) = @_;
    return 0 unless defined $prefix && length $prefix;
    return $httpd_conf =~ /location\s+"\Q$prefix\E\*"/
        && $httpd_conf =~ /param\s+SCRIPT_NAME\s+"\Q$prefix\E"/
        ? 1
        : 0;
}

sub valid_email_address {
    my ($email) = @_;
    return defined $email && $email =~ /\A[^\s\@]+@[^\s\@]+\.[^\s\@]+\z/;
}

sub httpd_max_request_body {
    my ($path) = @_;
    my $body = read_file($path);
    my $max = 0;
    while ($body =~ /\bmax\s+request\s+body\s+([0-9]+)/g) {
        $max = $1 if $1 > $max;
    }
    return $max;
}

sub httpd_dynamic_routes {
    return qw(
        admin
        analytics
        comments
        ratings
        forms
        shop
        stripe
        billing
        postmark
        events
        directory
        bookings
        members
        account
        forums
        social
        live
        newsletter
        donate
        testimonials
    );
}

sub expected_database_tables {
    my ($app_root) = @_;
    my $schema = File::Spec->catfile($app_root, 'sql', 'schema.sql');
    my $body = read_file($schema);
    my @tables;
    while ($body =~ /^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z0-9_]+)/gmi) {
        push @tables, $1;
    }
    if (!@tables) {
        fail("could not derive expected database tables from $schema");
    }
    return @tables;
}

sub validate_hosted_contributor_sites {
    my ($dbh, $conf, $httpd_conf) = @_;
    section('Hosted contributor sites');

    if (length($conf->{contributor_site_id} || '') || length($conf->{contributor_domain} || '')) {
        pass('contributor instance inherits hosted-site deployment from its master CMS');
        return;
    }

    my $rows = eval {
        $dbh->selectall_arrayref(
            q{
                SELECT *
                FROM contributor_sites
                WHERE status IN ('pending_provision', 'active', 'disabled')
                ORDER BY domain ASC, site_id ASC
            },
            { Slice => {} }
        );
    };
    if (!$rows) {
        fail('could not read contributor_sites for hosted-site validation: ' . ($@ || 'unknown error'));
        return;
    }

    if (!@{$rows}) {
        pass('no active or pending hosted contributor sites are registered');
        return;
    }

    pass('hosted contributor site registry is readable: ' . scalar(@{$rows}) . ' site(s)');
    for my $site (@{$rows}) {
        validate_hosted_contributor_site($site, $httpd_conf);
    }
}

sub validate_site_provisioning_queue {
    my ($dbh, $conf) = @_;
    section('Hosted contributor provisioning queue');

    if (length($conf->{contributor_site_id} || '') || length($conf->{contributor_domain} || '')) {
        pass('contributor instance inherits provisioning queue from its master CMS');
        return;
    }

    my $rows = eval {
        $dbh->selectall_arrayref(
            q{
                SELECT q.id, q.site_id, q.action, q.status, q.created_at, q.updated_at, q.error_text,
                       c.domain, c.status AS site_status
                FROM site_provisioning_queue q
                LEFT JOIN contributor_sites c ON c.site_id = q.site_id
                WHERE q.status IN ('queued', 'running', 'failed')
                ORDER BY
                    CASE q.status WHEN 'failed' THEN 0 WHEN 'running' THEN 1 ELSE 2 END,
                    q.updated_at ASC,
                    q.id ASC
            },
            { Slice => {} }
        );
    };
    if (!$rows) {
        fail('could not read site_provisioning_queue for hosted-site validation: ' . ($@ || 'unknown error'));
        return;
    }

    if (!@{$rows}) {
        pass('no failed or open contributor provisioning jobs');
        return;
    }

    my $now = time;
    my $queued_stale_after = 30 * 60;
    my $running_stale_after = 15 * 60;
    my (@failed, @stale, @open);
    for my $job (@{$rows}) {
        my $status = $job->{status} || '';
        if ($status eq 'failed') {
            next unless failed_job_blocks_current_state($job);
            push @failed, $job;
            next;
        }
        my $age = $now - int($job->{updated_at} || $job->{created_at} || $now);
        if (($status eq 'queued' && $age > $queued_stale_after)
            || ($status eq 'running' && $age > $running_stale_after)) {
            push @stale, $job;
        } else {
            push @open, $job;
        }
    }

    if (@failed) {
        warn_check('failed contributor provisioning jobs need retry: ' . scalar(@failed) . ' (' . queue_job_examples(@failed) . ')');
    }
    if (@stale) {
        warn_check('stale contributor provisioning jobs need worker attention: ' . scalar(@stale) . ' (' . queue_job_examples(@stale) . ')');
    }
    if (!@failed && !@stale) {
        pass('no failed or stale contributor provisioning jobs');
    }
    if (@open) {
        pass('open contributor provisioning jobs are recent: ' . scalar(@open));
    }
}

sub validate_hosted_contributor_site {
    my ($site, $httpd_conf) = @_;
    my $site_id = $site->{site_id} || '';
    my $domain = $site->{domain} || '';
    my $status = $site->{status} || '';
    my $label = length($site_id) ? $site_id : $domain || 'unknown site';

    check($site_id =~ /\A[a-z0-9][a-z0-9-]{1,62}\z/, "hosted site id is safe: $site_id", "hosted site id is unsafe for $label");
    check(valid_domain($domain), "hosted site domain is valid: $domain", "hosted site domain is invalid for $label");

    my $expected_config = length($site_id) ? "/etc/desertcms-$site_id.conf" : '';
    my $expected_data = length($site_id) ? "/var/desertcms-sites/$site_id" : '';
    my $expected_public = length($site_id) ? "/var/www/htdocs/desertcms-$site_id" : '';
    my $config_path = $site->{config_path} || $expected_config;
    my $data_dir = $site->{data_dir} || $expected_data;
    my $public_root = $site->{public_root} || $expected_public;
    my $db_path = length($data_dir) ? File::Spec->catfile($data_dir, 'desertcms.sqlite') : '';

    check($config_path eq $expected_config, "hosted site $site_id config path matches OpenBSD convention", "hosted site $site_id config path is $config_path, expected $expected_config");
    check($data_dir eq $expected_data, "hosted site $site_id data path matches OpenBSD convention", "hosted site $site_id data path is $data_dir, expected $expected_data");
    check($public_root eq $expected_public, "hosted site $site_id public root matches OpenBSD convention", "hosted site $site_id public root is $public_root, expected $expected_public");

    if ($status eq 'pending_provision') {
        warn_check("hosted site $site_id is still pending provisioning");
        return;
    }

    check(-f $config_path, "hosted site $site_id config file exists", "missing hosted site config file: $config_path");
    check(-d $data_dir, "hosted site $site_id data directory exists", "missing hosted site data directory: $data_dir");
    check(-d $public_root, "hosted site $site_id public root exists", "missing hosted site public root: $public_root");
    check(-f $db_path, "hosted site $site_id SQLite database exists", "missing hosted site SQLite database: $db_path");
    check(path_outside($data_dir, $public_root), "hosted site $site_id private data is outside public root", "hosted site $site_id data_dir is inside public_root");

    if (-f $config_path) {
        my %site_conf = read_config($config_path);
        check(($site_conf{contributor_site_id} || '') eq $site_id, "hosted site $site_id config records contributor_site_id", "hosted site $site_id config contributor_site_id does not match");
        check(($site_conf{contributor_domain} || '') eq $domain, "hosted site $site_id config records contributor_domain", "hosted site $site_id config contributor_domain does not match");
        check(($site_conf{master_config_path} || '') eq $opt{config}, "hosted site $site_id inherits master config path", "hosted site $site_id master_config_path is not $opt{config}");
        check(($site_conf{public_root} || '') eq $public_root, "hosted site $site_id config public_root matches registry", "hosted site $site_id config public_root does not match registry");
        check(($site_conf{data_dir} || '') eq $data_dir, "hosted site $site_id config data_dir matches registry", "hosted site $site_id config data_dir does not match registry");
        check(($site_conf{db_path} || '') eq $db_path, "hosted site $site_id config db_path matches registry", "hosted site $site_id config db_path does not match registry");
    }

    check(
        $httpd_conf =~ /server\s+"\Q$domain\E"\s*\{/,
        "httpd has a hosted site server block for $domain",
        "httpd is missing a hosted site server block for $domain"
    );
    if ($status eq 'active') {
        check(
            $httpd_conf =~ /param\s+DESERTCMS_CONFIG\s+"\Q$config_path\E"/,
            "httpd routes $domain to $config_path",
            "httpd does not route $domain to $config_path"
        );
        check(
            $httpd_conf =~ /param\s+SCRIPT_NAME\s+"\/admin"/,
            "httpd exposes admin route for hosted site $site_id",
            "httpd is missing hosted site admin FastCGI route"
        );
    } elsif ($status eq 'disabled') {
        check(
            $httpd_conf =~ /server\s+"\Q$domain\E"[\s\S]*?block\s+return\s+403/,
            "httpd blocks disabled hosted site $domain",
            "httpd does not block disabled hosted site $domain"
        );
    }
}

sub queue_job_examples {
    my (@jobs) = @_;
    my @labels;
    for my $job (@jobs[0 .. (@jobs > 3 ? 2 : $#jobs)]) {
        next unless $job;
        my $id = int($job->{id} || 0);
        my $site_id = $job->{site_id} || 'unknown-site';
        my $action = $job->{action} || 'unknown-action';
        my $status = $job->{status} || 'unknown-status';
        my $detail = "#$id $site_id $action/$status";
        if (($job->{error_text} || '') ne '') {
            my $error = $job->{error_text};
            $error =~ s/\s+/ /g;
            $error = substr($error, 0, 80);
            $detail .= ": $error";
        }
        push @labels, $detail;
    }
    push @labels, '...' if @jobs > 3;
    return join('; ', @labels);
}

sub failed_job_blocks_current_state {
    my ($job) = @_;
    my $action = $job->{action} || '';
    my $site_status = $job->{site_status} || '';
    return 1 if $action eq 'create' && $site_status eq 'pending_provision';
    return 1 if $action eq 'enable' && length($site_status) && $site_status ne 'active';
    return 1 if $action eq 'disable' && length($site_status) && $site_status ne 'disabled';
    return 1 if $action eq 'destroy' && $site_status eq 'destroy_pending';
    return 0;
}

sub root_crontab {
    my $body = qx(crontab -l 2>/dev/null);
    return defined $body ? $body : '';
}

sub read_file {
    my ($path) = @_;
    my $fh;
    if (!open $fh, '<', $path) {
        fail("cannot read $path: $!");
        return '';
    }
    local $/;
    my $body = <$fh>;
    close $fh;
    return defined $body ? $body : '';
}

sub required_conf {
    my ($conf, $key) = @_;
    my $value = $conf->{$key} || '';
    check(length $value, "config has $key", "config missing $key");
    return $value;
}

sub path_outside {
    my ($candidate, $root) = @_;
    $candidate =~ s{/+\z}{};
    $root =~ s{/+\z}{};
    return index($candidate . '/', $root . '/') != 0;
}

sub site_domain {
    my ($url) = @_;
    return '' unless defined $url;
    return $1 if $url =~ m{\Ahttps?://([^/:]+)}i;
    return '';
}

sub dedicated_shop_domain {
    my ($conf, $primary_domain) = @_;
    my $domain = $conf->{shop_domain} || '';
    return $domain if length($domain) && $domain ne ($primary_domain || '');

    my $url = $conf->{shop_url} || '';
    return '' unless $url =~ m{\Ahttps?://([^/:]+)(?::[0-9]+)?(/[^?#]*)?}i;
    my ($host, $path) = ($1, $2 || '');
    $path =~ s{/+\z}{};
    return '' if length $path;
    return $host eq ($primary_domain || '') ? '' : $host;
}

sub valid_domain {
    my ($domain) = @_;
    return defined $domain && $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/i ? 1 : 0;
}

sub host_addresses {
    my ($domain) = @_;
    return () unless command_exists('host');
    my $out = qx(host "$domain" 2>/dev/null);
    my @addresses;
    for my $line (split /\n/, $out) {
        push @addresses, $1 if $line =~ / has address ([0-9.]+)/;
        push @addresses, $1 if $line =~ / has IPv6 address ([0-9a-f:]+)/i;
    }
    return @addresses;
}

sub shell_quote {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/'/'\\''/g;
    return "'$value'";
}

sub chomped {
    my ($value) = @_;
    chomp($value);
    return $value;
}
