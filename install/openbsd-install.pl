#!/usr/bin/env perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);
use IPC::Open2;
use POSIX qw(strftime);

my $DRY_RUN = 0;
my $ASSUME_YES = 0;
my $CHECK_ASSETS = 0;
my $PLAN_ONLY = 0;
my $WWW_OPTION_SET = 0;
my @REQUIRED_PACKAGES = qw(p5-DBI p5-DBD-SQLite p5-IO-Socket-SSL p5-Net-SSLeay libvips p5-HTTP-Daemon);

my %S = (
    app_user       => '_desertcms',
    app_group      => '_desertcms',
    admin_group    => 'desertcms-admins',
    app_root       => '/usr/local/www/desertcms',
    config_file    => '/etc/desertcms.conf',
    data_dir       => '/var/desertcms',
    public_root_name => 'desertcms-site',
    public_root    => '',
    acme_root      => '/var/www/acme',
    slowcgi_sock   => '/var/www/run/desertcms.sock',
    httpd_conf     => '/etc/httpd.conf',
    acme_conf      => '/etc/acme-client.conf',
    pf_conf        => '/etc/pf.conf',
    doas_conf      => '/etc/doas.conf',
    rc_script      => '/etc/rc.d/desertcms_slowcgi',
    site_name      => 'DesertCMS',
    deprecated_shop_domain => '',
    cms_temp_user  => 'setup-admin',
    ssh_port       => '22',
    ssh_allow      => '',
    include_www    => 1,
    install_pkgs   => 1,
    issue_tls      => 1,
    geoip_refresh  => 1,
    post_install_validate => 1,
    https_enabled  => 0,
    package_repo   => '',
    keep_server_password => 0,
    httpd_max_request_body => 67108864,
);

main() unless caller;

sub main {
    parse_args(@ARGV);
    if ($S{help}) {
        print usage();
        return;
    }
    if ($CHECK_ASSETS) {
        run_local_asset_audit();
        return;
    }

    require_root_openbsd() unless $DRY_RUN || $PLAN_ONLY;
    intro();
    collect_server_admin();
    collect_site_settings();
    preflight_checks();
    show_dns_help();
    confirm_plan();
    if ($PLAN_ONLY) {
        plan_only_report();
        return;
    }

    run_local_asset_audit();
    install_packages() if $S{install_pkgs};
    create_server_admin();
    create_service_user_and_dirs();
    copy_application();
    write_config();
    install_slowcgi_service();
    write_doas_config();
    install_root_workers();
    write_pf_config();
    write_acme_config();
    write_httpd_initial();
    initialize_cms();
    import_geoip_data();
    build_public_site();
    start_services();
    verify_dns();
    if ($S{issue_tls} && issue_certificate()) {
        write_httpd_final();
        $S{https_enabled} = 1;
    } else {
        note('TLS is not active yet. Writing an HTTP-only DesertCMS config so the site and admin remain usable while DNS or certificates are pending.');
        write_httpd_http_only();
    }
    run_post_install_validation();
    final_report();
}

sub intro {
    step('DesertCMS OpenBSD installer');
    my $os = capture_or_empty('uname', '-s');
    chomp $os;
    my $version = capture_or_empty('uname', '-r');
    chomp $version;
    print "This installer targets OpenBSD with httpd, slowcgi, pf, acme-client, SQLite, and Perl.\n";
    if ($os eq 'OpenBSD') {
        print "Detected OpenBSD release: " . ($version || 'unknown') . "\n";
    } else {
        print "Current OS: " . ($os || 'unknown') . "\n";
        print "OpenBSD release will be detected on the target server during install.\n";
    }
    note('Dry-run mode is active. Commands and file writes will be printed, not applied.') if $DRY_RUN;
    note('Plan-only mode is active. The installer will collect settings, show DNS and install details, then exit before system changes.') if $PLAN_ONLY;
    if (!$PLAN_ONLY) {
        note('This script will write system files under /etc, /usr/local/www, /var/desertcms, and /var/www.');
        note('Existing system config files are timestamp-backed up before replacement.');
    }
}

sub collect_server_admin {
    step('1. Server admin account');
    print "Create or update the OpenBSD shell account that manages this CMS deployment.\n";
    while (1) {
        $S{server_admin} = prompt('Server admin username', $S{server_admin} || 'siteadmin');
        last if valid_login($S{server_admin}) && $S{server_admin} !~ /^_/;
        warn_line('Use a normal login name: lowercase letter first, then lowercase letters, numbers, dots, underscores, or hyphens.');
    }
    if ($S{keep_server_password}) {
        note('Keeping the existing server-admin password unchanged.');
    } elsif ($PLAN_ONLY) {
        note('Plan-only mode: no server-admin password is collected or validated.');
    } else {
        $S{server_password} = prompt_secret_confirm('Server admin password');
    }
    $S{ssh_key} = prompt('Optional SSH public key for this admin account', '');

    if (!$S{ssh_allow}) {
        my $from_ssh = $ENV{SSH_CLIENT} ? (split /\s+/, $ENV{SSH_CLIENT})[0] . '/32' : '';
        $S{ssh_allow} = $from_ssh || '0.0.0.0/0';
    }
}

sub collect_site_settings {
    step('2. Site, network, and install settings');
    while (1) {
        $S{domain} = prompt('Primary domain, without https://', $S{domain} || '');
        last if valid_domain($S{domain});
        warn_line('Enter a normal domain such as example.com.');
    }
    $S{include_www} = 0 if !$WWW_OPTION_SET && likely_subdomain($S{domain});
    $S{site_name} = prompt('Public site name', $S{site_name});
    while (1) {
        $S{public_root_name} = prompt('Public webroot directory under /var/www/htdocs', $S{public_root_name});
        last if valid_public_root_name($S{public_root_name});
        warn_line('Use letters, numbers, dots, underscores, or hyphens; do not include slashes.');
    }
    set_public_root_from_name();
    $S{ssh_port} = prompt('SSH port to allow through pf', $S{ssh_port});
    $S{ssh_allow} = prompt('CIDR allowed to reach SSH through pf', $S{ssh_allow});
    $S{include_www} = yes_no("Include www.$S{domain} in httpd and TLS certificate", $S{include_www});
    $S{install_pkgs} = yes_no('Install required packages with pkg_add', $S{install_pkgs});
    $S{issue_tls} = yes_no('Try to issue the TLS certificate during this run', $S{issue_tls});
    $S{geoip_refresh} = yes_no('Try to import DB-IP City Lite GeoIP data during this run', $S{geoip_refresh});
    $S{post_install_validate} = yes_no('Run production validation after installing', $S{post_install_validate});
}

sub show_dns_help {
    step('3. Domain connection checklist');
    my $ip4 = default_ipv4();
    my $ip6 = default_ipv6();
    my ($record_name, $zone_name) = dns_record_name($S{domain});
    my $www_record = $record_name eq '@' ? 'www' : "www.$record_name";

    print "Update DNS wherever your domain is managed. Edit the DNS records for $zone_name.\n";
    print "\nCreate these DNS records:\n";
    printf "  %-5s %-24s %s\n", 'A', $record_name, ($ip4 || 'YOUR_SERVER_IPV4');
    printf "  %-5s %-24s %s\n", 'AAAA', $record_name, $ip6 if $ip6;
    printf "  %-5s %-24s %s\n", 'CNAME', $www_record, $S{domain} if $S{include_www};
    print "\nThe shop is served from the main deployment at https://$S{domain}/shop. Do not create a shop subdomain for the standard install.\n";
    print "\nIf your registrar uses separate nameservers, set those first, then add the records above in the active DNS panel.\n";
    print "The installer can continue before DNS has propagated, but acme-client will not issue TLS until port 80 and DNS are correct.\n";
    pause('Press Enter after reviewing the DNS instructions');
}

sub confirm_plan {
    step('4. Review install plan');
    print <<"PLAN";
Server admin:        $S{server_admin}  (groups: wheel, $S{admin_group})
CMS service user:    $S{app_user}
Domain:              $S{domain}
Shop path:           https://$S{domain}/shop
Site name:           $S{site_name}
App root:            $S{app_root}
Data root:           $S{data_dir}
Public root name:    $S{public_root_name}
Public webroot:      $S{public_root}
Firewall SSH allow:  TCP $S{ssh_port} from $S{ssh_allow}
Public ports:        TCP 80 and 443
GeoIP setup:         @{[$S{geoip_refresh} ? 'try DB-IP City Lite import and backfill' : 'skip automatic import']}
Post-install check:  @{[$S{post_install_validate} ? 'run OpenBSD production validator' : 'skip automatic validation']}
Temporary CMS login: $S{cms_temp_user} with generated password and forced first-login change
PLAN
    print single_install_coverage_report();
    if ($PLAN_ONLY) {
        note('Plan-only mode: no system changes will be applied.');
        return;
    }
    die "Install cancelled.\n" unless $ASSUME_YES || yes_no('Apply this plan', 0);
}

sub single_install_coverage_report {
    my $geoip = $S{geoip_refresh}
        ? 'attempt DB-IP City Lite import and analytics backfill'
        : 'leave GeoIP import for a later maintenance run';
    my $validation = $S{post_install_validate}
        ? 'run production validator before the installer exits'
        : 'print the validator command for manual follow-up';
    my $tls = $S{issue_tls}
        ? 'request ACME TLS when DNS is ready; otherwise keep HTTP routes usable'
        : 'skip ACME this run and keep HTTP routes usable';
    my $dynamic_modules = install_dynamic_module_summary();
    my $static_modules = install_static_module_summary();
    my $provider_hooks = install_provider_hook_summary();
    my $subcms_foundation = install_subcms_foundation_summary();
    return <<"COVERAGE";

Single-install coverage:
  - OpenBSD packages for Perl, SQLite, HTTPS email transport, libvips media processing, and local test tooling.
  - Filesystem layout for app code, private data, private source assets, public generated files, backups, themes, upgrades, and font jobs.
  - OpenBSD services: desertcms_slowcgi, httpd, pf firewall, acme-client config, doas rules, and root-owned worker cron entries.
  - Firewall policy: default deny, outbound state, SSH restricted to the admin allowlist, and public HTTP/HTTPS.
  - Dynamic module routing: $dynamic_modules.
  - Static module output: $static_modules.
  - Provider hooks: $provider_hooks.
  - Hosted SubCMS foundation: $subcms_foundation.
  - CMS initialization: SQLite schema, temporary forced-change CMS login, generated public site, and local runtime asset audit.
  - GeoIP: $geoip.
  - TLS: $tls.
  - Validation: $validation.
COVERAGE
}

sub install_dynamic_module_summary {
    return 'Admin, Analytics, Forms, Shop / Catalog, Events, Directory, Bookings, Membership member portal, Newsletter, Donations, Testimonials, comments, ratings, and checkout dispatch';
}

sub install_static_module_summary {
    return 'pages, posts, Media derivatives, Map / Locations, Showcase, Docs / Resource Hub, Resource downloads, sitemap, robots, redirects, and navigation';
}

sub install_provider_hook_summary {
    return 'Shop / Catalog /stripe/webhook, hosted service billing /billing/stripe/webhook, Events /events/stripe/webhook, Bookings /bookings/stripe/webhook, Donations /donate/stripe/webhook, and tokenized Postmark bounce/spam hooks';
}

sub install_subcms_foundation_summary {
    return 'contributor site queue worker, generated per-site httpd routing, inherited master-provider config conventions, public-root ownership repair, and validator checks for hosted-site files, routes, and queue health';
}

sub preflight_checks {
    step('Preflight checks');
    my $os = capture_or_empty('uname', '-s');
    chomp $os;
    if ($os eq 'OpenBSD') {
        ok('Running on OpenBSD');
    } elsif ($DRY_RUN || $PLAN_ONLY) {
        warn_line("This non-mutating run is not on OpenBSD; system command checks may be incomplete.");
    } else {
        die "This installer is intended for OpenBSD, not $os.\n";
    }

    die "Invalid SSH port: $S{ssh_port}\n" unless $S{ssh_port} =~ /\A[0-9]{1,5}\z/ && $S{ssh_port} >= 1 && $S{ssh_port} <= 65535;
    ok("SSH port is valid: $S{ssh_port}");
    ok("Domain syntax is valid: $S{domain}");
    warn_line('--shop-domain is deprecated and ignored; the shop is served at /shop on the main domain.')
        if length($S{deprecated_shop_domain} || '');
    die "--keep-server-admin-password requires an existing user: $S{server_admin}\n"
        if $S{keep_server_password} && !user_exists($S{server_admin});

    for my $cmd (qw(perl tar pfctl httpd rcctl acme-client slowcgi doas nc crontab)) {
        if (($DRY_RUN || $PLAN_ONLY) && $os ne 'OpenBSD') {
            note("Skipping command check outside OpenBSD: $cmd");
            next;
        }
        command_exists($cmd) ? ok("Command available: $cmd") : warn_line("Command not found yet: $cmd");
    }

    if ($S{install_pkgs} && !$PLAN_ONLY) {
        $S{package_repo} = resolve_package_repo();
        if (length $S{package_repo}) {
            ok("Package repository selected: $S{package_repo}");
        } else {
            ok('Default OpenBSD package repository appears usable');
        }
    }
}

sub plan_only_report {
    step('Plan review complete');
    print "No system changes were applied.\n";
    print "To install with these settings, rerun without --plan-only";
    print " and keep the same --domain, --site-name, --public-root-name, --server-admin, --ssh-allow, TLS, GeoIP, and validation options.\n";
    print "The real install follows the single-install coverage checklist above: server admin, packages, filesystem, firewall, web server, workers, CMS initialization, GeoIP, dynamic module routes, static module output, provider hooks, hosted SubCMS foundation, and validation.\n";
}

sub run_local_asset_audit {
    step('Local asset audit');
    my $root = repo_root();
    my $tool = File::Spec->catfile($root, 'tools', 'check-local-assets.pl');
    run_readonly($^X, $tool, '--quiet');
    ok('Runtime admin/theme assets are local; no remote script/style/image/font/CDN asset references found.');
}

sub install_packages {
    step('Installing OpenBSD packages');
    my @cmd = ('pkg_add', '-I', @REQUIRED_PACKAGES);
    if (length $S{package_repo}) {
        run('env', "PKG_PATH=$S{package_repo}", @cmd);
    } else {
        run(@cmd);
    }
}

sub create_server_admin {
    step('Creating server admin');
    ensure_group($S{admin_group});

    if (user_exists($S{server_admin})) {
        my @groups = merged_secondary_groups($S{server_admin}, 'wheel', $S{admin_group});
        if ($S{keep_server_password}) {
            run('usermod', '-G', join(',', @groups), '-s', '/bin/ksh', $S{server_admin});
            ok("Updated existing user $S{server_admin} without changing its password");
        } else {
            my $hash = encrypted_password($S{server_password});
            run('usermod', '-G', join(',', @groups), '-p', $hash, '-s', '/bin/ksh', $S{server_admin});
            ok("Updated existing user $S{server_admin}");
        }
    } else {
        my $hash = encrypted_password($S{server_password});
        run('useradd', '-m', '-G', join(',', 'wheel', $S{admin_group}), '-s', '/bin/ksh', '-p', $hash, $S{server_admin});
        ok("Created user $S{server_admin}");
    }

    if (length $S{ssh_key}) {
        my $home = user_home($S{server_admin}) || "/home/$S{server_admin}";
        run('install', '-d', '-o', $S{server_admin}, '-g', $S{server_admin}, '-m', '700', "$home/.ssh");
        append_unique("$home/.ssh/authorized_keys", $S{ssh_key} . "\n");
        run('chown', $S{server_admin} . ':' . $S{server_admin}, "$home/.ssh/authorized_keys");
        run('chmod', '600', "$home/.ssh/authorized_keys");
        ok('Installed SSH authorized key for server admin');
    }
}

sub create_service_user_and_dirs {
    step('Creating service user and filesystem layout');
    ensure_group($S{app_group});
    if (!user_exists($S{app_user})) {
        run('useradd', '-g', $S{app_group}, '-s', '/sbin/nologin', '-d', '/var/empty', $S{app_user});
    }

    run('install', '-d', '-o', 'root', '-g', 'wheel', '-m', '755', $S{app_root});
    run('install', '-d', '-o', $S{app_user}, '-g', $S{app_group}, '-m', '750', $S{data_dir});
    run('install', '-d', '-o', $S{app_user}, '-g', $S{app_group}, '-m', '750', "$S{data_dir}/backups");
    run('install', '-d', '-o', $S{app_user}, '-g', $S{app_group}, '-m', '750', "$S{data_dir}/originals");
    run('install', '-d', '-o', $S{app_user}, '-g', $S{app_group}, '-m', '750', "$S{data_dir}/themes");
    run('install', '-d', '-o', $S{app_user}, '-g', $S{app_group}, '-m', '750', "$S{data_dir}/upgrades");
    run('install', '-d', '-o', $S{app_user}, '-g', $S{app_group}, '-m', '750', "$S{data_dir}/font-packages");
    run('install', '-d', '-o', $S{app_user}, '-g', $S{app_group}, '-m', '755', $S{public_root});
    run('install', '-d', '-o', 'root', '-g', 'wheel', '-m', '755', $S{acme_root});
    run('install', '-d', '-o', 'root', '-g', 'wheel', '-m', '755', '/etc/acme');
    run('install', '-d', '-o', 'root', '-g', 'wheel', '-m', '700', '/etc/ssl/private');
    run('install', '-d', '-o', 'www', '-g', 'www', '-m', '755', '/var/www/run');
}

sub copy_application {
    step('Installing CMS files');
    my $src = repo_root();
    if ($src ne $S{app_root}) {
        my $cmd = join ' ',
            'cd', shell_quote($src), '&&',
            'find .',
            q{\( -path './.*' -o -path './local' -o -path './data' \) -prune -o -print},
            '|', 'pax', '-rw', '-pe', shell_quote($S{app_root});
        sh($cmd);
    }
    run('chown', '-R', 'root:wheel', $S{app_root});
    run('find', $S{app_root}, '-type', 'd', '-exec', 'chmod', '755', '{}', '+');
    run('find', $S{app_root}, '-type', 'f', '-exec', 'chmod', '644', '{}', '+');
    run('chmod', '755', "$S{app_root}/bin/desertcms.cgi", "$S{app_root}/bin/desertcms-maint.pl", "$S{app_root}/tools/check-local-assets.pl", "$S{app_root}/tools/openbsd-validate.pl", "$S{app_root}/tools/openbsd-apply-site-queue.pl", "$S{app_root}/tools/openbsd-apply-upgrade.pl", "$S{app_root}/tools/openbsd-apply-font-packages.pl", "$S{app_root}/tools/openbsd-operations-worker.pl");
}

sub write_config {
    step('Writing CMS config');
    backup_file($S{config_file});
    write_file($S{config_file}, <<"CONF");
# DesertCMS configuration generated by install/openbsd-install.pl

site_name = $S{site_name}
site_url = https://$S{domain}

data_dir = $S{data_dir}
db_path = $S{data_dir}/desertcms.sqlite
app_secret_file = $S{data_dir}/app_secret
public_root = $S{public_root}
originals_dir = $S{data_dir}/originals
backup_dir = $S{data_dir}/backups
theme_dir = $S{data_dir}/themes
admin_asset_dir = $S{app_root}/admin/assets

session_cookie = desertcms_session
session_ttl_seconds = 7200
secure_cookies = 1
trusted_proxy_cidrs =
max_request_body_bytes = 67108864

login_lockout_seconds = 900
login_max_failures = 5

image_public_max_width = 1600
image_public_quality = 82
image_tool = /usr/local/bin/vips
tar_tool = tar

analytics_enabled = 1
analytics_retention_days = 365
analytics_store_raw_ip = 1

module_map_enabled = 1
module_shop_enabled = 1
module_gallery_enabled = 0
module_forms_enabled = 0
module_contributor_requests_enabled = 1
module_docs_enabled = 0
module_events_enabled = 0
module_directory_enabled = 0
module_bookings_enabled = 0
module_membership_enabled = 0
module_newsletter_enabled = 0
module_donations_enabled = 0
module_testimonials_enabled = 0
docs_source_dir =
shop_domain =
shop_url =
commerce_model = master_owned
shop_enabled = 1
shop_require_purchase_token = 1
stripe_secret_key =
stripe_webhook_secret =
stripe_webhook_tolerance_seconds = 300

postmark_sender_mode = site
postmark_from_email =
postmark_server_token =
postmark_webhook_token =

google_oauth_client_id =
google_oauth_client_secret =
google_search_console_property =
indexnow_enabled = 0
indexnow_key =

operations_backup_schedule_enabled = 0
operations_backup_interval_hours = 24
operations_offsite_hook_url =
operations_offsite_hook_token =
operations_upgrade_channel = stable
upgrade_require_signed_releases = 0
upgrade_signify_public_key =
upgrade_signify_tool = signify
CONF
    run('chown', 'root:' . $S{app_group}, $S{config_file});
    run('chmod', '640', $S{config_file});
}

sub install_slowcgi_service {
    step('Installing slowcgi service');
    backup_file($S{rc_script});
    run('install', '-o', 'root', '-g', 'wheel', '-m', '555', "$S{app_root}/etc/rc.d/desertcms_slowcgi", $S{rc_script});
    run('rcctl', 'enable', 'desertcms_slowcgi');
}

sub write_doas_config {
    step('Configuring doas for server admin group');
    backup_file($S{doas_conf});
    my $existing = '';
    if (-f $S{doas_conf}) {
        if ($DRY_RUN && !-r $S{doas_conf}) {
            note("Dry-run cannot read $S{doas_conf}; rendering managed block against an empty placeholder.");
        } else {
            $existing = slurp($S{doas_conf});
        }
    }
    $existing =~ s/\n?# DesertCMS admin access BEGIN\n.*?# DesertCMS admin access END\n?/\n/s;
    $existing =~ s/\s+\z/\n/s;
    $existing .= "\n" if length($existing) && $existing !~ /\n\z/;
    $existing .= <<"DOAS";
# DesertCMS admin access BEGIN
permit persist :$S{admin_group}
# DesertCMS admin access END
DOAS
    write_file($S{doas_conf}, $existing);
    run('chown', 'root:wheel', $S{doas_conf});
    run('chmod', '600', $S{doas_conf});
    run('doas', '-C', $S{doas_conf});
}

sub install_root_workers {
    step('Installing root background workers');
    run('perl', "$S{app_root}/tools/openbsd-apply-site-queue.pl", '--install-cron');
    run('perl', "$S{app_root}/tools/openbsd-apply-upgrade.pl", '--install-cron');
    run('perl', "$S{app_root}/tools/openbsd-apply-font-packages.pl", '--install-cron');
    run('perl', "$S{app_root}/tools/openbsd-operations-worker.pl", '--install-cron');
}

sub write_pf_config {
    step('Writing pf firewall');
    backup_file($S{pf_conf});
    write_file($S{pf_conf}, <<"PF");
# DesertCMS firewall generated by install/openbsd-install.pl
# Default deny inbound. Public: HTTP/HTTPS. Admin: SSH from <ssh_admins>.

ext_if = "egress"
table <ssh_admins> persist { $S{ssh_allow} }

set block-policy drop
set skip on lo

block log all
match in all scrub (no-df random-id max-mss 1440)

pass out quick all keep state

pass in quick on \$ext_if proto tcp from <ssh_admins> to (\$ext_if) port $S{ssh_port} flags S/SA keep state
pass in quick on \$ext_if proto tcp from any to (\$ext_if) port { 80 443 } flags S/SA keep state
pass in quick on \$ext_if inet proto icmp icmp-type echoreq keep state
pass in quick on \$ext_if inet6 proto icmp6 keep state
PF
    run('pfctl', '-nf', $S{pf_conf});
    run('pfctl', '-f', $S{pf_conf});
    if ($DRY_RUN) {
        print "+ pfctl -e\n";
    } else {
        system('pfctl', '-e') == 0 || 1;
    }
    run('rcctl', 'enable', 'pf');
}

sub write_acme_config {
    step('Writing acme-client config');
    backup_file($S{acme_conf});
    my @alts;
    push @alts, "www.$S{domain}" if $S{include_www};
    my $alt = @alts ? "\talternative names { " . join(' ', map { qq{"$_"} } @alts) . " }\n" : '';
    write_file($S{acme_conf}, <<"ACME");
authority letsencrypt {
	api url "https://acme-v02.api.letsencrypt.org/directory"
	account key "/etc/acme/letsencrypt-privkey.pem"
}

domain "$S{domain}" {
$alt	domain key "/etc/ssl/private/$S{domain}.key"
	domain full chain certificate "/etc/ssl/$S{domain}.fullchain.pem"
	sign with letsencrypt
}
ACME
    run('chown', 'root:wheel', $S{acme_conf});
    run('chmod', '644', $S{acme_conf});
}

sub write_httpd_initial {
    step('Writing HTTP config for ACME challenge');
    backup_file($S{httpd_conf});
    my $alias = $S{include_www} ? qq{\talias "www.$S{domain}"\n} : '';
    my $httpd_root = httpd_public_root();
    write_file($S{httpd_conf}, <<"HTTPD");
# Temporary DesertCMS httpd config for ACME validation.

types {
	include "/usr/share/misc/mime.types"
}

server "$S{domain}" {
	listen on * port 80
	root "$httpd_root"
$alias
	location "/.well-known/acme-challenge/*" {
		root "/acme"
		request strip 2
	}
}
HTTPD
    run('httpd', '-n');
    run('rcctl', 'enable', 'httpd');
    run('rcctl', 'restart', 'httpd');
}

sub write_httpd_final {
    step('Writing final HTTPS httpd config');
    my $httpd_root = httpd_public_root();
    my $http_alias = $S{include_www} ? qq{\talias "www.$S{domain}"\n} : '';
    my $fastcgi_routes = httpd_fastcgi_routes($S{app_root}, $S{config_file});
    my $www_tls_server = $S{include_www} ? <<"WWW" : '';

server "www.$S{domain}" {
	listen on * tls port 443
	root "$httpd_root"

	tls {
		certificate "/etc/ssl/$S{domain}.fullchain.pem"
		key "/etc/ssl/private/$S{domain}.key"
	}

	hsts {
		max-age 31536000
	}

	location "/.well-known/acme-challenge/*" {
		root "/acme"
		request strip 2
	}

	location "/*" {
		block return 301 "https://$S{domain}\$REQUEST_URI"
	}
}
WWW
    write_file($S{httpd_conf}, <<"HTTPD");
# DesertCMS httpd config generated by install/openbsd-install.pl

types {
	include "/usr/share/misc/mime.types"
}

server "$S{domain}" {
	listen on * tls port 443
	root "$httpd_root"
	connection {
		max request body $S{httpd_max_request_body}
	}

	tls {
		certificate "/etc/ssl/$S{domain}.fullchain.pem"
		key "/etc/ssl/private/$S{domain}.key"
	}

	hsts {
		max-age 31536000
	}

$fastcgi_routes

	location "/.well-known/acme-challenge/*" {
		root "/acme"
		request strip 2
	}
}
$www_tls_server

server "$S{domain}" {
	listen on * port 80
	root "$httpd_root"
$http_alias
	location "/.well-known/acme-challenge/*" {
		root "/acme"
		request strip 2
	}

	location "/*" {
		block return 301 "https://$S{domain}\$REQUEST_URI"
	}
}
HTTPD
    run('httpd', '-n');
    run('rcctl', 'restart', 'httpd');
}

sub write_httpd_http_only {
    step('Writing HTTP-only DesertCMS config');
    my $httpd_root = httpd_public_root();
    my $alias = $S{include_www} ? qq{\talias "www.$S{domain}"\n} : '';
    my $fastcgi_routes = httpd_fastcgi_routes($S{app_root}, $S{config_file});
    write_file($S{httpd_conf}, <<"HTTPD");
# DesertCMS HTTP config generated by install/openbsd-install.pl.
# TLS is pending; rerun acme-client and switch to the HTTPS config once DNS is ready.

types {
	include "/usr/share/misc/mime.types"
}

server "$S{domain}" {
	listen on * port 80
	root "$httpd_root"
	connection {
		max request body $S{httpd_max_request_body}
	}
$alias
$fastcgi_routes

	location "/.well-known/acme-challenge/*" {
		root "/acme"
		request strip 2
	}
}
HTTPD
    run('httpd', '-n');
    run('rcctl', 'restart', 'httpd');
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
        newsletter
        donate
        testimonials
    );
}

sub httpd_fastcgi_routes {
    my ($app_root, $config_file) = @_;
    my $cgi = "$app_root/bin/desertcms.cgi";
    return join "\n", map {
        my $route = $_;
        <<"ROUTE";
\tlocation "/$route*" {
\t\tfastcgi {
\t\t\tsocket "/run/desertcms.sock"
\t\t\tparam SCRIPT_FILENAME "$cgi"
\t\t\tparam SCRIPT_NAME "/$route"
\t\t\tparam DESERTCMS_CONFIG "$config_file"
\t\t}
\t}
ROUTE
    } httpd_dynamic_routes();
}

sub initialize_cms {
    step('Initializing CMS and temporary admin');
    run_as_app('env', "DESERTCMS_CONFIG=$S{config_file}", 'perl', "$S{app_root}/bin/desertcms-maint.pl", 'init-db');
    if (cms_active_admin_count()) {
        $S{cms_temp_output} = "  existing active CMS admin retained\n";
        note('An active CMS admin already exists; keeping it and skipping temporary admin creation.');
    } else {
        my $cmd = join ' ', map { shell_quote($_) }
            ('env', "DESERTCMS_CONFIG=$S{config_file}", 'perl', "$S{app_root}/bin/desertcms-maint.pl", 'create-admin', $S{cms_temp_user});
        $S{cms_temp_output} = capture_checked('su', '-m', $S{app_user}, '-c', $cmd);
        print $S{cms_temp_output};
    }
    run_as_app('env', "DESERTCMS_CONFIG=$S{config_file}", 'perl', "$S{app_root}/bin/desertcms-maint.pl", 'backup');
}

sub import_geoip_data {
    step('GeoIP analytics data');
    if (!$S{geoip_refresh}) {
        note('Skipping automatic GeoIP import. You can run geoip-refresh-dbip-lite later from the maintenance script.');
        return;
    }

    my @cmd = (
        'env', "DESERTCMS_CONFIG=$S{config_file}",
        'perl', "$S{app_root}/bin/desertcms-maint.pl",
        'geoip-refresh-dbip-lite',
    );
    if (run_as_app_optional(@cmd)) {
        ok('GeoIP City Lite data imported and analytics rows backfilled when possible.');
    } else {
        warn_line('GeoIP refresh did not complete. The CMS remains installed; analytics will show unresolved locations until GeoIP is imported.');
        note("Run later: doas su -m $S{app_user} -c 'env DESERTCMS_CONFIG=$S{config_file} perl $S{app_root}/bin/desertcms-maint.pl geoip-refresh-dbip-lite'");
    }
}

sub build_public_site {
    step('Building public static output');
    my $code = q{my $c=DesertCMS::Config->load; $c->app_secret; my $db=DesertCMS::DB->new(config=>$c); $db->migrate; my $content=DesertCMS::Content->new(config=>$c, db=>$db); my $n=$content->rebuild_all; print "rebuilt $n published items\n";};
    run_as_app(
        'env', "DESERTCMS_CONFIG=$S{config_file}",
        'perl', "-I$S{app_root}/lib",
        '-MDesertCMS::Config', '-MDesertCMS::DB', '-MDesertCMS::Content',
        '-e', $code
    );
}

sub start_services {
    step('Starting services');
    run('rcctl', 'restart', 'desertcms_slowcgi');
    run('rcctl', 'restart', 'httpd');
}

sub verify_dns {
    step('DNS verification');
    my $ip4 = default_ipv4();
    my $found = host_addresses($S{domain});
    print "Expected IPv4: " . ($ip4 || 'unknown') . "\n";
    print "DNS for $S{domain}: " . (@$found ? join(', ', @$found) : 'no A/AAAA results found') . "\n";
    if ($S{include_www}) {
        my $www = host_addresses("www.$S{domain}");
        print "DNS for www.$S{domain}: " . (@$www ? join(', ', @$www) : 'no A/AAAA results found') . "\n";
    }
    if ($ip4 && !grep { $_ eq $ip4 } @$found) {
        warn_line("DNS does not yet resolve $S{domain} to $ip4.");
        $S{issue_tls} = 0 unless yes_no('Try TLS anyway', 0);
    }
}

sub issue_certificate {
    step('Issuing TLS certificate');
    if ($DRY_RUN) {
        note("Would run acme-client for $S{domain}; leaving HTTPS switch disabled in dry-run.");
        return 0;
    }
    if (certificate_present()) {
        note("Existing TLS certificate found for $S{domain}; keeping it.");
        return 1;
    }
    if (system('acme-client', '-v', $S{domain}) == 0 && certificate_present()) {
        return 1;
    }
    if (certificate_present()) {
        note("TLS certificate is present for $S{domain}; continuing even though acme-client did not renew it.");
        return 1;
    }
    warn_line('acme-client failed. This is usually DNS propagation, port 80, a firewall issue, or mismatched A/AAAA records.');
    return 0;
}

sub certificate_present {
    return -f "/etc/ssl/$S{domain}.fullchain.pem"
        && -f "/etc/ssl/private/$S{domain}.key";
}

sub run_post_install_validation {
    step('Running production validation');
    if (!$S{post_install_validate}) {
        note('Skipping automatic validation. Run tools/openbsd-validate.pl before treating this server as production-ready.');
        return;
    }
    my @cmd = (
        'perl',
        "$S{app_root}/tools/openbsd-validate.pl",
        '--config', $S{config_file},
        '--app-root', $S{app_root},
        '--domain', $S{domain},
    );
    push @cmd, '--allow-pending-tls' unless certificate_present();
    run(@cmd);
    $S{post_install_validation_status} = 'passed';
}

sub final_report {
    step('Install complete');
    my $scheme = $S{https_enabled} ? 'https' : 'http';
    print "Open the admin UI:\n";
    print "  $scheme://$S{domain}/admin/login\n";
    print "Open the shop:\n";
    print "  $scheme://$S{domain}/shop\n";
    if (!$S{https_enabled}) {
        print "\nTLS is still pending. The HTTP config forwards DesertCMS admin and module routes so setup can continue.\n";
        print "After DNS is ready, run acme-client and switch to the HTTPS httpd config.\n";
    }
    print "\nTemporary CMS credentials:\n";
    print $S{cms_temp_output} || "  username: $S{cms_temp_user}\n  password: see installer output above\n";
    print "\nOn first CMS login, the application will require you to set the permanent CMS username and password.\n";
    print "\nServer admin account:\n";
    print "  $S{server_admin} can use doas through group $S{admin_group}.\n";
    print "\nImportant files:\n";
    print "  $S{config_file}\n  $S{httpd_conf}\n  $S{acme_conf}\n  $S{pf_conf}\n";
    print "\nInstalled coverage:\n";
    print "  OpenBSD packages, app files, private/public filesystem roots, desertcms_slowcgi, httpd, pf, doas, worker cron, CMS database, public rebuild, and local asset audit were handled by this installer.\n";
    print "  Dynamic modules: " . install_dynamic_module_summary() . ".\n";
    print "  Static output: " . install_static_module_summary() . ".\n";
    print "  Provider hooks: " . install_provider_hook_summary() . ". Configure provider secrets in MasterCMS after install.\n";
    print "  Hosted SubCMS: " . install_subcms_foundation_summary() . ". Contributor sites are created later from MasterCMS plans and blueprints.\n";
    print "  GeoIP: " . ($S{geoip_refresh} ? 'attempted during install.' : 'skipped by option; run the maintenance GeoIP refresh when ready.') . "\n";
    print "  TLS: " . ($S{https_enabled} ? 'active through acme-client.' : 'pending; HTTP admin and module routes remain usable.') . "\n";
    if (($S{post_install_validation_status} || '') eq 'passed') {
        print "\nProduction validation: passed during this installer run.\n";
    } else {
        print "\nRun the production validation check:\n";
        print "  doas perl $S{app_root}/tools/openbsd-validate.pl --domain $S{domain}\n";
    }
}

sub require_root_openbsd {
    die "Run as root, for example: doas perl install/openbsd-install.pl\n" unless $> == 0;
    chomp(my $os = capture('uname', '-s'));
    die "This installer is intended for OpenBSD, not $os.\n" unless $os eq 'OpenBSD';
}

sub encrypted_password {
    my ($password) = @_;
    return 'DRYRUN_PASSWORD_HASH' if $DRY_RUN;
    my $pid = open2(my $out, my $in, 'encrypt', '-b', 'a');
    print {$in} "$password\n";
    close $in;
    my $hash = <$out>;
    waitpid($pid, 0);
    die "encrypt failed\n" if $?;
    chomp($hash ||= '');
    die "encrypt failed to produce a password hash\n" unless length $hash;
    return $hash;
}

sub run_as_app {
    my @cmd = @_;
    run('su', '-m', $S{app_user}, '-c', join(' ', map { shell_quote($_) } @cmd));
}

sub run_as_app_optional {
    my @cmd = @_;
    my @full = ('su', '-m', $S{app_user}, '-c', join(' ', map { shell_quote($_) } @cmd));
    if ($DRY_RUN) {
        print '+ ' . join(' ', map { /\s/ ? shell_quote($_) : $_ } @full) . "\n";
        return 1;
    }
    return system(@full) == 0 ? 1 : 0;
}

sub cms_active_admin_count {
    return 0 if $DRY_RUN;
    my $code = q{
        my $c=DesertCMS::Config->load;
        my $db=DesertCMS::DB->new(config=>$c);
        my ($count)=$db->dbh->selectrow_array("SELECT COUNT(*) FROM admin_users WHERE disabled_at IS NULL");
        exit($count ? 0 : 1);
    };
    my $cmd = join ' ', map { shell_quote($_) }
        ('env', "DESERTCMS_CONFIG=$S{config_file}", 'perl', "-I$S{app_root}/lib", '-MDesertCMS::Config', '-MDesertCMS::DB', '-e', $code);
    return system('su', '-m', $S{app_user}, '-c', $cmd) == 0 ? 1 : 0;
}

sub ensure_group {
    my ($group) = @_;
    return if system('/bin/sh', '-c', '/usr/sbin/groupinfo ' . shell_quote($group) . ' >/dev/null 2>&1') == 0;
    run('groupadd', $group);
}

sub merged_secondary_groups {
    my ($user, @required) = @_;
    chomp(my $primary = capture('id', '-gn', $user));
    my $out = capture('id', '-Gn', $user);
    my %seen;
    my @groups;
    for my $group (split /\s+/, $out) {
        next if !length($group) || $group eq $primary || $seen{$group}++;
        push @groups, $group;
    }
    for my $group (@required) {
        next if $group eq $primary || $seen{$group}++;
        push @groups, $group;
    }
    return @groups;
}

sub user_exists {
    my ($user) = @_;
    return system('/bin/sh', '-c', 'id -u ' . shell_quote($user) . ' >/dev/null 2>&1') == 0;
}

sub user_home {
    my ($user) = @_;
    open my $fh, '<', '/etc/passwd' or return undef;
    while (my $line = <$fh>) {
        my @parts = split /:/, $line;
        return $parts[5] if @parts >= 6 && $parts[0] eq $user;
    }
    return undef;
}

sub valid_login {
    my ($value) = @_;
    return defined $value && $value =~ /\A[a-z][a-z0-9._-]{0,30}\z/;
}

sub valid_domain {
    my ($value) = @_;
    return defined $value
        && $value =~ /\A(?=.{1,253}\z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\z/;
}

sub valid_public_root_name {
    my ($value) = @_;
    return defined $value
        && $value =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z/
        && $value !~ /\.\./;
}

sub set_public_root_from_name {
    die "invalid public root name\n" unless valid_public_root_name($S{public_root_name});
    $S{public_root} = "/var/www/htdocs/$S{public_root_name}";
}

sub httpd_public_root {
    set_public_root_from_name() unless length($S{public_root} || '');
    return "/htdocs/$S{public_root_name}";
}

sub likely_subdomain {
    my ($domain) = @_;
    return 0 unless defined $domain;
    my @labels = split /\./, $domain;
    return @labels > 2 ? 1 : 0;
}

sub dns_record_name {
    my ($domain) = @_;
    my @labels = split /\./, $domain || '';
    return ('@', $domain || '') if @labels <= 2;
    my $zone = join '.', @labels[-2, -1];
    my $name = join '.', @labels[0 .. $#labels - 2];
    return ($name, $zone);
}

sub default_ipv4 {
    return first_line(qw(ifconfig egress), qr/\binet\s+([0-9.]+)/);
}

sub default_ipv6 {
    my $out = capture_or_empty(qw(ifconfig egress));
    for my $line (split /\n/, $out) {
        return $1 if $line =~ /\binet6\s+([0-9a-f:]+)/i && $1 !~ /^fe80:/i;
    }
    return '';
}

sub host_addresses {
    my ($name) = @_;
    my @addresses;
    return [] unless command_exists('host');
    my $out = capture('host', $name);
    for my $line (split /\n/, $out) {
        push @addresses, $1 if $line =~ / has address ([0-9.]+)/;
        push @addresses, $1 if $line =~ / has IPv6 address ([0-9a-f:]+)/i;
    }
    return \@addresses;
}

sub first_line {
    my (@cmd_and_pattern) = @_;
    my $pattern = pop @cmd_and_pattern;
    my $out = capture_or_empty(@cmd_and_pattern);
    for my $line (split /\n/, $out) {
        return $1 if $line =~ $pattern;
    }
    return '';
}

sub command_exists {
    my ($cmd) = @_;
    return system('command', '-v', $cmd, '>/dev/null', '2>&1') == 0 if 0;
    return system('/bin/sh', '-c', 'command -v ' . shell_quote($cmd) . ' >/dev/null 2>&1') == 0;
}

sub repo_root {
    my $script_dir = dirname(abs_path($0));
    return abs_path(File::Spec->catdir($script_dir, '..'));
}

sub parse_args {
    my @args = @_;
    GetOptionsFromArray(
        \@args,
        'help|h'              => \$S{help},
        'dry-run'             => \$DRY_RUN,
        'plan-only'           => \$PLAN_ONLY,
        'yes|y'               => \$ASSUME_YES,
        'check-assets'        => \$CHECK_ASSETS,
        'domain=s'            => \$S{domain},
        'shop-domain=s'       => \$S{deprecated_shop_domain},
        'site-name=s'         => \$S{site_name},
        'public-root-name=s'  => \$S{public_root_name},
        'server-admin=s'      => \$S{server_admin},
        'server-password=s'   => \$S{server_password},
        'keep-server-admin-password' => \$S{keep_server_password},
        'ssh-key=s'           => \$S{ssh_key},
        'ssh-allow=s'         => \$S{ssh_allow},
        'ssh-port=s'          => \$S{ssh_port},
        'package-repo=s'      => \$S{package_repo},
        'www!'                => sub {
            my (undef, $value) = @_;
            $S{include_www} = $value ? 1 : 0;
            $WWW_OPTION_SET = 1;
        },
        'install-packages!'   => \$S{install_pkgs},
        'install-pkgs!'       => \$S{install_pkgs},
        'issue-tls!'          => \$S{issue_tls},
        'tls!'                => \$S{issue_tls},
        'geoip-refresh!'      => \$S{geoip_refresh},
        'post-install-validate!' => \$S{post_install_validate},
    ) or die usage();
    die usage() if @args;
    if (!length($S{server_password} || '') && length($ENV{DESERTCMS_INSTALL_PASSWORD} || '')) {
        $S{server_password} = $ENV{DESERTCMS_INSTALL_PASSWORD};
    }
    set_public_root_from_name();
}

sub usage {
    return <<"USAGE";
Usage:
  doas perl install/openbsd-install.pl
  doas perl install/openbsd-install.pl --domain example.com --public-root-name example-site
  perl install/openbsd-install.pl --dry-run
  perl install/openbsd-install.pl --plan-only --yes --domain example.com

Options:
  --dry-run                 Print intended system changes without applying them.
  --plan-only               Show DNS guidance and the install plan, then exit
                            before packages, users, files, firewall, services,
                            GeoIP import, or validation are changed.
  --yes                     Accept prompts using provided/default values.
  --domain example.com      Primary site domain.
  --shop-domain shop.example.com
                            Deprecated and ignored. The shop is served at /shop.
  --site-name "Name"        Public site name.
  --public-root-name NAME   Directory name under /var/www/htdocs for generated public files.
  --server-admin siteadmin  OpenBSD admin account to create or update.
  --keep-server-admin-password
                            For an existing server-admin user, do not change
                            its password during install.
  --ssh-allow CIDR          CIDR allowed to reach SSH through pf.
  --ssh-port PORT           SSH port to allow through pf.
  --package-repo URL        Override PKG_PATH for pkg_add.
  --no-install-packages     Skip pkg_add.
  --no-issue-tls            Skip acme-client during this run.
  --no-geoip-refresh        Skip the DB-IP City Lite GeoIP import attempt.
  --no-post-install-validate
                            Skip the automatic OpenBSD production validator.
  --no-www                  Do not include www.domain in httpd/TLS config.
  --check-assets            Only run the local runtime-asset audit.
  --help                    Show this help.

For unattended dry-runs only, DESERTCMS_INSTALL_PASSWORD can provide the
temporary server-admin password used by the prompts. Plan-only mode does not
collect or validate the server-admin password.
USAGE
}

sub resolve_package_repo {
    return $S{package_repo} if length $S{package_repo};
    return '' if package_available('libvips', '');

    my $release = capture_or_empty('uname', '-r');
    chomp $release;
    my $arch = capture_or_empty('uname', '-m');
    chomp $arch;
    return '' unless length $release && length $arch;

    my @bases = installurl_bases();
    push @bases,
        'https://ftp.eu.openbsd.org/pub/OpenBSD',
        'https://archive.openbsd.org/pub/OpenBSD';

    my %seen;
    for my $base (@bases) {
        next unless length $base;
        $base =~ s{/+\z}{};
        next if $seen{$base}++;
        my $repo = "$base/$release/packages/$arch/";
        return $repo if package_available('libvips', $repo);
    }

    warn_line('Could not verify a package repository for libvips. pkg_add may fail until /etc/installurl or --package-repo is corrected.');
    return '';
}

sub installurl_bases {
    my @bases;
    if (open my $fh, '<', '/etc/installurl') {
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s/#.*$//;
            $line =~ s/^\s+|\s+$//g;
            push @bases, $line if length $line;
        }
        close $fh;
    }
    return @bases;
}

sub package_available {
    my ($stem, $repo) = @_;
    return 0 unless command_exists('pkg_info');
    my @cmd = length($repo)
        ? ('env', "PKG_PATH=$repo", 'pkg_info', '-Q', $stem)
        : ('pkg_info', '-Q', $stem);
    my ($out, $ok) = capture_status('/bin/sh', '-c', join(' ', map { shell_quote($_) } @cmd) . ' 2>/dev/null');
    return $ok && $out =~ /^\Q$stem\E-\S+/m;
}

sub backup_file {
    my ($file) = @_;
    return unless -f $file;
    my $stamp = strftime('%Y%m%d%H%M%S', localtime);
    run('cp', '-p', $file, "$file.desertcms.$stamp.bak");
    ok("Backed up $file");
}

sub append_unique {
    my ($file, $line) = @_;
    if ($DRY_RUN) {
        note("Would append unique line to $file");
        return;
    }
    my $body = -f $file ? slurp($file) : '';
    return if index($body, $line) >= 0;
    open my $fh, '>>', $file or die "cannot write $file: $!";
    print {$fh} $line;
    close $fh;
}

sub write_file {
    my ($file, $body) = @_;
    if ($DRY_RUN) {
        print "+ [dry-run] write $file (" . length($body) . " bytes)\n";
        return;
    }
    open my $fh, '>', $file or die "cannot write $file: $!";
    print {$fh} $body;
    close $fh;
}

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "cannot read $file: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub prompt {
    my ($label, $default) = @_;
    print $label;
    print " [$default]" if defined $default && length $default;
    print ': ';
    if ($ASSUME_YES) {
        print "\n";
        return $default || '';
    }
    chomp(my $answer = <STDIN>);
    return length($answer) ? $answer : ($default || '');
}

sub prompt_secret_confirm {
    my ($label) = @_;
    if (length($S{server_password} || '')) {
        die "$label must be at least 12 characters.\n" unless length($S{server_password}) >= 12;
        return $S{server_password};
    }
    if ($ASSUME_YES && $DRY_RUN) {
        return 'DryRunPassword123!';
    }
    die "$label is required when --yes is used. Set DESERTCMS_INSTALL_PASSWORD or omit --yes.\n" if $ASSUME_YES;
    while (1) {
        my $first = prompt_secret($label);
        my $second = prompt_secret('Confirm ' . lc($label));
        return $first if length($first) >= 12 && $first eq $second;
        warn_line('Passwords must match and be at least 12 characters.');
    }
}

sub prompt_secret {
    my ($label) = @_;
    print "$label: ";
    system('stty', '-echo');
    chomp(my $answer = <STDIN>);
    system('stty', 'echo');
    print "\n";
    return $answer;
}

sub yes_no {
    my ($label, $default) = @_;
    return $default ? 1 : 0 if $ASSUME_YES;
    my $suffix = $default ? '[Y/n]' : '[y/N]';
    print "$label $suffix: ";
    chomp(my $answer = <STDIN>);
    return $default ? 1 : 0 unless length $answer;
    return $answer =~ /\A(?:y|yes)\z/i ? 1 : 0;
}

sub pause {
    my ($message) = @_;
    if ($ASSUME_YES || $DRY_RUN || $PLAN_ONLY) {
        print "$message [skipped]\n";
        return;
    }
    print "$message ";
    scalar <STDIN>;
}

sub run {
    my @cmd = @_;
    print '+ ', join(' ', map { /\s/ ? shell_quote($_) : $_ } @cmd), "\n";
    return if $DRY_RUN;
    system(@cmd) == 0 or die "command failed: @cmd\n";
}

sub run_readonly {
    my @cmd = @_;
    print '+ ', join(' ', map { /\s/ ? shell_quote($_) : $_ } @cmd), "\n";
    system(@cmd) == 0 or die "command failed: @cmd\n";
}

sub sh {
    my ($cmd) = @_;
    print "+ $cmd\n";
    return if $DRY_RUN;
    system('/bin/sh', '-c', $cmd) == 0 or die "command failed: $cmd\n";
}

sub capture_or_empty {
    my @cmd = @_;
    my ($out) = capture_status(@cmd);
    return $out;
}

sub capture {
    my @cmd = @_;
    open my $fh, '-|', @cmd or die "cannot run @cmd: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined $out ? $out : '';
}

sub capture_status {
    my @cmd = @_;
    open my $fh, '-|', @cmd or return ('', 0);
    local $/;
    my $out = <$fh>;
    my $ok = close $fh;
    return (defined $out ? $out : '', $ok ? 1 : 0);
}

sub capture_checked {
    my @cmd = @_;
    if ($DRY_RUN) {
        return "  username: $S{cms_temp_user}\n  password: DRY-RUN-NOT-GENERATED\n";
    }
    open my $fh, '-|', @cmd or die "cannot run @cmd: $!";
    local $/;
    my $out = <$fh>;
    close $fh or die "command failed: @cmd\n";
    return defined $out ? $out : '';
}

sub shell_quote {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/'/'\\''/g;
    return "'$value'";
}

sub step {
    my ($title) = @_;
    print "\n";
    print '=' x 72, "\n";
    print "$title\n";
    print '=' x 72, "\n";
}

sub ok {
    my ($message) = @_;
    print "[ok] $message\n";
}

sub note {
    my ($message) = @_;
    print "[note] $message\n";
}

sub warn_line {
    my ($message) = @_;
    print "[warn] $message\n";
}
