use strict;
use warnings;
use Test::More;
use IPC::Open3;
use Symbol qw(gensym);

use FindBin;

my $installer = "$FindBin::Bin/../install/openbsd-install.pl";
my $legacy_installer = "$FindBin::Bin/../install/openbsd-vultr-install.ksh";
my $dev_server = "$FindBin::Bin/../bin/desertcms-dev-server.pl";
my @dynamic_routes = qw(
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
my @fresh_install_module_defaults = qw(
    module_map_enabled
    module_shop_enabled
    module_gallery_enabled
    module_forms_enabled
    module_contributor_requests_enabled
    module_docs_enabled
    module_events_enabled
    module_directory_enabled
    module_bookings_enabled
    module_membership_enabled
    module_newsletter_enabled
    module_donations_enabled
    module_testimonials_enabled
);

my ($help_out, $help_err, $help_status) = _run_capture($^X, $installer, '--help');
is($help_status, 0, 'installer help exits cleanly');
like($help_out, qr/--dry-run/, 'help documents dry-run');
like($help_out, qr/--plan-only/, 'help documents plan-only review mode');
like($help_out, qr/doas perl install\/openbsd-install\.pl --domain example\.com --public-root-name example-site/, 'help documents fast single-server install command');
like($help_out, qr/--no-install-packages/, 'help documents package skip');
like($help_out, qr/--keep-server-admin-password/, 'help documents existing admin password preservation');
like($help_out, qr/--public-root-name/, 'help documents public root name setting');
like($help_out, qr/--no-geoip-refresh/, 'help documents optional GeoIP refresh skip');
like($help_out, qr/--no-post-install-validate/, 'help documents optional post-install validation skip');
is($help_err, '', 'help does not write stderr');

my $source = _read($installer);
my $legacy_source = _read($legacy_installer);
my $dev_source = _read($dev_server);
my $app_source = _read("$FindBin::Bin/../lib/DesertCMS/App.pm");
my $readme = _read("$FindBin::Bin/../README.md");
my $openbsd_install_doc = _read("$FindBin::Bin/../docs/OPENBSD_74_INSTALL.md");
like($source, qr/my \@REQUIRED_PACKAGES = qw\(p5-DBI p5-DBD-SQLite p5-IO-Socket-SSL p5-Net-SSLeay libvips p5-HTTP-Daemon\)/, 'installer uses OpenBSD packages for SQLite, HTTPS, libvips, and local development');
for my $route (@dynamic_routes) {
    like($dev_source, qr/\b\Q$route\E\b/, "dev server forwards /$route as a dynamic route");
}
like($dev_source, qr{/events\.ics}, 'dev server forwards events calendar feed dynamically');
like($source, qr/sub resolve_package_repo/, 'installer has package repository fallback');
like($source, qr/return if \$DRY_RUN;/, 'installer command wrapper honors dry-run');
like($source, qr/my \$PLAN_ONLY = 0;/, 'installer has a non-mutating plan-only mode');
like($source, qr/plan_only_report\(\);\s+return;/, 'installer exits after plan review in plan-only mode');
like($source, qr/Plan-only mode: no server-admin password is collected or validated/, 'plan-only mode does not collect a real server-admin password');
like($source, qr/\[dry-run\] write/, 'installer marks dry-run file writes');
like($source, qr/Updated existing user .* without changing its password/, 'installer can preserve existing server admin password');
like($source, qr/find', \$S\{app_root\}, '-type', 'd', '-exec', 'chmod', '755'/, 'installer normalizes copied app directory permissions');
like($source, qr/chmod', '755', "\$S\{app_root\}\/bin\/desertcms\.cgi"/, 'installer restores CGI entrypoint executable mode');
like($source, qr/\$S\{data_dir\}\/upgrades/, 'installer creates private upgrade staging directory');
like($source, qr/upgrade_require_signed_releases = 0/, 'installer documents compatible unsigned upgrade mode by default');
like($source, qr/upgrade_signify_public_key =/, 'installer writes optional release signing public key setting');
like($source, qr/upgrade_signify_tool = signify/, 'installer defaults release signature verification to OpenBSD signify');
like($source, qr/\$S\{data_dir\}\/font-packages/, 'installer creates private font package state directory');
like($source, qr/openbsd-apply-upgrade\.pl/, 'installer installs the upgrade worker');
like($source, qr/openbsd-apply-font-packages\.pl/, 'installer installs the font package worker');
like($source, qr/openbsd-operations-worker\.pl/, 'installer installs the operations worker');
like($source, qr/sub install_root_workers/, 'installer configures root background workers');
like($source, qr/sub write_pf_config/, 'installer has a first-class pf firewall step');
like($source, qr/rcctl', 'enable', 'pf'/, 'installer enables pf at boot');
like($source, qr/pass in quick on \\\$ext_if proto tcp from <ssh_admins>.*port \$S\{ssh_port\}/s, 'installer restricts SSH to the configured admin allowlist');
like($source, qr/pass in quick on \\\$ext_if proto tcp from any.*port \{ 80 443 \}/s, 'installer opens public HTTP and HTTPS ports');
like($source, qr/geoip_refresh\s+=>\s+1/, 'installer enables GeoIP import attempt by default');
like($source, qr/post_install_validate\s+=>\s+1/, 'installer runs production validation by default');
like($source, qr/sub single_install_coverage_report/, 'installer has a single-install coverage summary');
like($source, qr/Current OS: /, 'installer intro labels non-OpenBSD plan reviews as the current OS');
like($source, qr/OpenBSD release will be detected on the target server during install/, 'installer intro does not mislabel non-OpenBSD uname output as an OpenBSD release');
like($source, qr/Firewall policy: default deny, outbound state, SSH restricted to the admin allowlist, and public HTTP\/HTTPS/, 'installer coverage summary names firewall policy');
like($source, qr/sub install_dynamic_module_summary/, 'installer centralizes the dynamic module install handoff');
like($source, qr/Admin, Analytics, Forms, Shop \/ Catalog, Events, Directory, Bookings, Membership member portal, Newsletter, Donations, Testimonials/, 'installer coverage summary names dynamic first-party module routes');
like($source, qr/sub install_static_module_summary/, 'installer centralizes the static module install handoff');
like($source, qr/Map \/ Locations, Showcase, Docs \/ Resource Hub, Resource downloads/, 'installer coverage summary names static/generated module output');
like($source, qr/sub install_provider_hook_summary/, 'installer centralizes the provider-hook install handoff');
like($source, qr/Shop \/ Catalog \/stripe\/webhook, hosted service billing \/billing\/stripe\/webhook, Events \/events\/stripe\/webhook, Bookings \/bookings\/stripe\/webhook, Donations \/donate\/stripe\/webhook, and tokenized Postmark bounce\/spam hooks/, 'installer coverage summary names concrete provider hook paths');
like($source, qr/sub install_subcms_foundation_summary/, 'installer centralizes the hosted SubCMS install handoff');
like($source, qr/contributor site queue worker, generated per-site httpd routing, inherited master-provider config conventions, public-root ownership repair, and validator checks/, 'installer coverage summary names hosted SubCMS deployment foundation without claiming sites are created during install');
like($source, qr/CMS initialization: SQLite schema, temporary forced-change CMS login, generated public site, and local runtime asset audit/, 'installer coverage summary names CMS initialization path');
like($source, qr/Configure provider secrets in MasterCMS after install/, 'installer final report keeps provider secrets as post-install setup');
like($source, qr/Contributor sites are created later from MasterCMS plans and blueprints/, 'installer final report avoids claiming SubCMS tenants are created during base install');
like($source, qr/Try to import DB-IP City Lite GeoIP data during this run/, 'installer prompts for GeoIP refresh');
like($source, qr/Run production validation after installing/, 'installer prompts for post-install validation');
like($source, qr/sub import_geoip_data/, 'installer has a first-class GeoIP import step');
like($source, qr/geoip-refresh-dbip-lite/, 'installer refreshes DB-IP City Lite GeoIP data');
like($source, qr/sub run_as_app_optional/, 'installer can keep going when optional GeoIP refresh fails');
like($source, qr/--no-geoip-refresh/, 'installer exposes a no-GeoIP refresh flag');
like($source, qr/--no-post-install-validate/, 'installer exposes a no-validation flag');
like($source, qr/sub run_post_install_validation/, 'installer has a first-class post-install validation step');
like($source, qr/openbsd-validate\.pl.*--config/s, 'installer runs the OpenBSD validator with the installed config');
like($source, qr/--allow-pending-tls/, 'installer allows pending TLS during first-run validation when certificates are missing');
like($source, qr/sub httpd_dynamic_routes/, 'installer has a single dynamic httpd route list');
like($readme, qr/rcctl enable desertcms_slowcgi/, 'README manual setup uses the DesertCMS slowcgi rc service');
like($readme, qr/rcctl start desertcms_slowcgi/, 'README manual setup starts the DesertCMS slowcgi rc service');
unlike($readme, qr/rcctl (?:enable|start|restart|check) slowcgi\b/, 'README does not tell operators to manage the disabled base slowcgi service');
like($openbsd_install_doc, qr/provider warnings mean the operator still needs to finish MasterCMS provider setup before enabling email sends, billing checkout, or site payments/, 'OpenBSD install guide distinguishes successful install validation from provider activation');
like($openbsd_install_doc, qr/The generated `httpd` configuration forwards.*through `desertcms_slowcgi`/s, 'OpenBSD install guide names desertcms_slowcgi for dynamic provider routes');
for my $route (@dynamic_routes) {
    like($source, qr/\b\Q$route\E\b/, "installer includes /$route in the dynamic route list");
}
like($source, qr/fastcgi \{\s+\\t\\t\\tsocket "\/run\/desertcms\.sock"\s+\\t\\t\\tparam SCRIPT_FILENAME "\$cgi"/s, 'installer uses OpenBSD nested fastcgi block syntax');
like($source, qr/httpd_max_request_body\s+=>\s+67108864/, 'installer sets 64 MB OpenBSD httpd upload body limit');
like($source, qr/max request body \$S\{httpd_max_request_body\}/, 'installer writes httpd max request body directive');
like($source, qr/image_tool = \/usr\/local\/bin\/vips/, 'installer writes absolute OpenBSD vips path');
like($source, qr/site_name\s+=>\s+'DesertCMS'/, 'installer uses DesertCMS as the default site name');
like($source, qr/public_root_name\s+=>\s+'desertcms-site'/, 'installer uses a generic DesertCMS public root name');
like($source, qr/sub valid_public_root_name/, 'installer validates the public root path component');
like($source, qr/\$S\{public_root\} = "\/var\/www\/htdocs\/\$S\{public_root_name\}"/, 'installer derives public_root from public root name');
like($source, qr/return "\/htdocs\/\$S\{public_root_name\}"/, 'installer derives OpenBSD httpd chroot root from public root name');
unlike($source, qr/root "\/htdocs\/desertcms-site"/, 'installer does not hardcode the default public root in httpd templates');
like($source, qr/session_cookie = desertcms_session/, 'installer writes generic DesertCMS session cookie');
like($source, qr/trusted_proxy_cidrs =/, 'installer leaves trusted proxy CIDRs empty by default');
like($source, qr/max_request_body_bytes = 67108864/, 'installer writes the CGI request body cap');
for my $setting (@fresh_install_module_defaults) {
    like($source, qr/\b\Q$setting\E = [01]\b/, "installer writes fresh-install module default $setting");
}
like($source, qr/module_contributor_requests_enabled = 1/, 'installer enables contributor requests by default');
unlike($source, qr/Desert Archive/, 'primary installer does not use old product placeholders');
unlike($source, qr/desert-archive/, 'primary installer does not use old public root placeholder');
like($source, qr/An active CMS admin already exists; keeping it/, 'installer skips temporary admin creation on rerun');
like($source, qr/sub certificate_present/, 'installer can detect an existing TLS certificate');
like($source, qr/Existing TLS certificate found/, 'installer reuses an existing TLS certificate on rerun');
like($source, qr/sub write_httpd_http_only/, 'installer writes a usable HTTP-only config when TLS is pending');
like($source, qr/TLS is pending; rerun acme-client and switch to the HTTPS config/, 'HTTP-only config explains pending TLS state');
like($source, qr/TLS is not active yet\. Writing an HTTP-only DesertCMS config/, 'installer does not leave an ACME-only config when TLS is pending');
unlike($source, qr/Shop domain, without https/, 'primary installer does not prompt for a shop subdomain');
like($source, qr/shop_domain =\nshop_url =/, 'primary installer leaves shop host config blank for /shop');
like($source, qr/Deprecated and ignored\. The shop is served at \/shop/, 'installer help marks --shop-domain as deprecated');
like($legacy_source, qr/Legacy compatibility wrapper/, 'legacy Vultr installer is now only a compatibility wrapper');
like($legacy_source, qr/openbsd-install\.pl/, 'legacy Vultr installer delegates to the supported OpenBSD installer');
like($legacy_source, qr/exec perl "\$installer" "\$@"/, 'legacy Vultr installer execs the maintained installer with original arguments');
unlike($legacy_source, qr/SHOP_DOMAIN|Shop domain|shop\.\$DOMAIN|location "\/checkout"|location "\/stripe/, 'legacy Vultr installer no longer carries stale shop-subdomain routing');
unlike($legacy_source, qr/location "\/(?:admin|analytics|comments|ratings)\*"/, 'legacy Vultr installer no longer carries a divergent httpd route list');
like($app_source, qr/\$path eq '\/stripe'.*_dispatch_shop\(\$request, ''\)/s, 'app dispatches main-domain Stripe webhook traffic to Shop / Catalog');

my $queue_applier = _read("$FindBin::Bin/../tools/openbsd-apply-site-queue.pl");
like($queue_applier, qr/sub httpd_dynamic_routes/, 'site queue applier has a single dynamic httpd route list');
for my $route (@dynamic_routes) {
    like($queue_applier, qr/\b\Q$route\E\b/, "site queue applier includes /$route in generated CMS server blocks");
}
like($queue_applier, qr/sub tls_www_redirect_servers/, 'site queue applier writes HTTPS www redirect servers');
like($queue_applier, qr/sub www_points_to_domain/, 'site queue applier only enables DNS-ready www aliases');
like($queue_applier, qr/old_domain\s+=>\s+''/, 'site queue applier does not default to a legacy production hostname');
like($queue_applier, qr/--old-domain is optional/, 'site queue applier documents optional legacy redirects');
unlike($queue_applier, qr/desertarchive\.kldhosting\.com/, 'site queue applier has no hardcoded old production domain');
like($queue_applier, qr/sub expected_site_paths/, 'site queue applier derives destroy archive paths from site id');
like($queue_applier, qr/refusing to archive path not bound to queued site/, 'site queue applier refuses unbound destroy archive paths');
my $upgrade_applier = _read("$FindBin::Bin/../tools/openbsd-apply-upgrade.pl");
like($upgrade_applier, qr/sub backup_current_app/, 'upgrade applier backs up the current app before replacement');
like($upgrade_applier, qr/sub apply_rollback_job/, 'upgrade applier can process rollback jobs');
like($upgrade_applier, qr/sub migrate_and_rebuild_instances/, 'upgrade applier migrates and rebuilds configured instances');
like($upgrade_applier, qr/repair_instance_public_root_ownership\(\$conf\).*desertcms-maint\.pl'\), 'init-db'.*desertcms-maint\.pl'\), 'rebuild'/s, 'upgrade applier repairs public-root ownership before rebuilding instances');
like($upgrade_applier, qr/sub repair_instance_public_root_ownership/, 'upgrade applier has a public-root ownership repair step');
like($upgrade_applier, qr/refusing to repair unsafe public root/, 'upgrade applier refuses unsafe public-root repair paths');
like($upgrade_applier, qr/sub safe_public_root/, 'upgrade applier centralizes public-root safety checks');
like($upgrade_applier, qr/chown', '-R', "\$opt\{app_user\}:\$opt\{app_user\}", \$public_root/, 'upgrade applier restores generated public files to the app user');
like($upgrade_applier, qr/File::Spec->catfile\(\$opt\{app_root\}, 'bin', 'desertcms\.cgi'\)/, 'upgrade applier restores CGI entrypoint executable mode');
my $provisioner = _read("$FindBin::Bin/../tools/openbsd-provision-site.pl");
like($provisioner, qr/COALESCE\(role, 'owner'\)\s*=\s*'owner'/, 'provisioner seeds only active master owners into contributor subCMS admin');
like($provisioner, qr/sub sql_quote/, 'provisioner SQL-quotes source database paths before attaching');
my $operations_worker = _read("$FindBin::Bin/../tools/openbsd-operations-worker.pl");
like($operations_worker, qr/run_due_scheduled_backups/, 'operations worker runs scheduled backups');
like($operations_worker, qr/openbsd-operations-worker\.pl --quiet/, 'operations worker installs a quiet cron entry');
my $font_worker = _read("$FindBin::Bin/../tools/openbsd-apply-font-packages.pl");
like($font_worker, qr/apply_queued_jobs/, 'font package worker applies queued package jobs');
like($font_worker, qr/openbsd-apply-font-packages\.pl --config .* --quiet/, 'font package worker installs a quiet cron entry');

my $marketing_seed = _read("$FindBin::Bin/../tools/seed-desertcms-marketing-site.pl");
like($marketing_seed, qr/use File::Find qw\(find\)/, 'marketing seeder can repair generated public-root ownership');
like($marketing_seed, qr/sub _repair_public_root_ownership/, 'marketing seeder has a public-root ownership repair step');
like($marketing_seed, qr/return unless \$> == 0;/, 'marketing seeder only repairs ownership when run as root');
like($marketing_seed, qr/chown \$uid, \$gid, \$path/, 'marketing seeder restores generated files to the public-root owner and group');

my $slowcgi_rc = _read("$FindBin::Bin/../etc/rc.d/desertcms_slowcgi");
like($slowcgi_rc, qr/daemon_flags="-p \/ -u _desertcms -s \/var\/www\/run\/desertcms\.sock"/, 'slowcgi runs CGI as service user while keeping socket connectable by httpd');
unlike($slowcgi_rc, qr/-U _desertcms/, 'slowcgi socket owner is not moved away from www');

my $httpd_example = _read("$FindBin::Bin/../etc/httpd.conf.example");
like($httpd_example, qr/max request body 67108864/, 'httpd example allows 64 MB uploads');
for my $route (@dynamic_routes) {
    like($httpd_example, qr/location "\/\Q$route\E\*"/, "httpd example forwards /$route");
    like($httpd_example, qr/param SCRIPT_NAME "\/\Q$route\E"/, "httpd example maps /$route to the CGI prefix");
}
like($httpd_example, qr/server "www\.example\.com".*block return 301 "https:\/\/example\.com\$REQUEST_URI"/s, 'httpd example redirects HTTPS www to canonical host');

my $config_example = _read("$FindBin::Bin/../etc/desertcms.conf.example");
like($config_example, qr/trusted_proxy_cidrs =/, 'config example documents trusted proxy default');
like($config_example, qr/max_request_body_bytes = 67108864/, 'config example documents CGI request body cap');
for my $setting (@fresh_install_module_defaults) {
    like($config_example, qr/\b\Q$setting\E = [01]\b/, "config example documents module default $setting");
}

my $validator = _read("$FindBin::Bin/../tools/openbsd-validate.pl");
like($validator, qr/sub httpd_dynamic_routes/, 'OpenBSD validator has a shared dynamic route checklist');
for my $route (@dynamic_routes) {
    like($validator, qr/\b\Q$route\E\b/, "OpenBSD validator checks /$route forwarding");
}
like($validator, qr/IO::Uncompress::Gunzip/, 'OpenBSD validator checks compressed GeoIP import support');
like($validator, qr/sub expected_database_tables/, 'OpenBSD validator derives expected database tables from the installed schema');
like($validator, qr/sql', 'schema\.sql'/, 'OpenBSD validator reads the installed schema file');
like($validator, qr/CREATE\\s\+TABLE\\s\+/, 'OpenBSD validator parses CREATE TABLE declarations');
like($validator, qr/GeoIP analytics ranges are imported/, 'OpenBSD validator reports GeoIP import readiness');
like($validator, qr/use File::Find qw\(find\)/, 'OpenBSD validator can inspect generated public trees');
like($validator, qr/check_public_root_tree_owner\(\$public_root, '_desertcms', '_desertcms'\)/, 'OpenBSD validator checks nested public-root ownership');
like($validator, qr/public root ownership drift detected/, 'OpenBSD validator reports nested public-root ownership drift');
like($validator, qr/allow_pending_tls/, 'OpenBSD validator supports TLS-pending installs');
like($validator, qr/sub check_tls_file/, 'OpenBSD validator can warn instead of fail for pending TLS files');
like($validator, qr/sub root_crontab/, 'OpenBSD validator reads the root crontab');
like($validator, qr/sub validate_firewall/, 'OpenBSD validator has a dedicated firewall runtime check');
like($validator, qr/rcctl get pf/, 'OpenBSD validator checks pf boot enablement');
like($validator, qr/pfctl -s info/, 'OpenBSD validator checks that pf is currently enabled');
like($validator, qr/pfctl -s rules/, 'OpenBSD validator checks loaded pf rules');
like($validator, qr/pf\.conf opens public HTTP and HTTPS ports/, 'OpenBSD validator checks configured public HTTP and HTTPS firewall ports');
like($validator, qr/loaded pf rules allow public HTTP/, 'OpenBSD validator checks loaded HTTP firewall rule');
like($validator, qr/loaded pf rules allow public HTTPS/, 'OpenBSD validator checks loaded HTTPS firewall rule');
like($validator, qr/loaded pf rules restrict SSH to the admin allowlist/, 'OpenBSD validator checks loaded SSH allowlist rule');
like($validator, qr/root cron runs the contributor site queue worker/, 'OpenBSD validator checks site queue worker cron');
like($validator, qr/root cron runs the upgrade worker/, 'OpenBSD validator checks upgrade worker cron');
like($validator, qr/root cron runs the operations worker/, 'OpenBSD validator checks operations worker cron');
like($validator, qr/root cron runs the font package worker for/, 'OpenBSD validator checks config-specific font worker cron');
like($validator, qr/Provider hooks and readiness/, 'OpenBSD validator reports provider hook readiness');
like($validator, qr/sub validate_postmark_transport/, 'OpenBSD validator has a dedicated Postmark HTTPS transport readiness check');
like($validator, qr/Postmark HTTPS transport is available to DesertCMS/, 'OpenBSD validator reports current Postmark HTTPS transport readiness');
like($validator, qr/Postmark HTTPS transport is not ready for DesertCMS/, 'OpenBSD validator explains current Postmark HTTPS transport failures');
like($validator, qr/Postmark sender and server token/, 'OpenBSD validator checks Postmark sender readiness');
like($validator, qr/Postmark bounce\/spam webhook token/, 'OpenBSD validator checks Postmark webhook readiness');
like($validator, qr/Stripe checkout webhook secret/, 'OpenBSD validator checks Stripe webhook readiness');
like($validator, qr/Provider webhook endpoints/, 'OpenBSD validator reports provider webhook endpoint routing');
like($validator, qr/sub validate_provider_webhook_endpoints/, 'OpenBSD validator has a dedicated provider endpoint check');
like($validator, qr/Email delivery health/, 'OpenBSD validator reports recent email delivery health');
like($validator, qr/sub validate_email_delivery_health/, 'OpenBSD validator has a dedicated email delivery health check');
like($validator, qr/email_delivery_logs/, 'OpenBSD validator reads the email delivery log');
like($validator, qr/no failed, bounced, spam, or complaint email delivery events in the last 7 days/, 'OpenBSD validator reports clean recent email delivery health');
like($validator, qr/recent email delivery issues need review/, 'OpenBSD validator surfaces recent email delivery failures and webhooks');
like($validator, qr/sub email_delivery_issue_examples/, 'OpenBSD validator summarizes recent email delivery issues');
like($validator, qr/Payment workflow health/, 'OpenBSD validator reports Stripe/payment workflow health');
like($validator, qr/sub validate_payment_workflow_health/, 'OpenBSD validator has a dedicated payment workflow health check');
like($validator, qr/payment workflow tables are readable; no payment attempts recorded yet/, 'OpenBSD validator reports empty payment workflow tables cleanly');
like($validator, qr/stale pending payment records need webhook or checkout review/, 'OpenBSD validator surfaces stale pending payment records');
like($validator, qr/recent failed, canceled, refunded, or ignored payment records need review/, 'OpenBSD validator surfaces recent payment issue states');
like($validator, qr/sub payment_workflow_specs/, 'OpenBSD validator centralizes payment workflow table specs');
like($validator, qr/service_plan_checkout_sessions/, 'OpenBSD validator checks hosted service billing checkout sessions');
like($validator, qr/shop_orders/, 'OpenBSD validator checks Shop / Catalog payment records');
like($validator, qr/event_ticket_orders/, 'OpenBSD validator checks Events ticket payment records');
like($validator, qr/booking_payments/, 'OpenBSD validator checks Bookings deposit payment records');
like($validator, qr/membership_payments/, 'OpenBSD validator checks Membership payment records');
like($validator, qr/donations/, 'OpenBSD validator checks Donations payment records');
like($validator, qr/httpd forwards \$label at \$path/, 'OpenBSD validator reports provider endpoint routing by label and path');
like($validator, qr/Shop \/ Catalog checkout webhook/, 'OpenBSD validator checks Shop / Catalog webhook routing');
like($validator, qr/\/stripe\/webhook/, 'OpenBSD validator checks Shop / Catalog webhook path');
like($validator, qr/hosted service billing webhook/, 'OpenBSD validator checks service billing webhook routing');
like($validator, qr/\/billing\/stripe\/webhook/, 'OpenBSD validator checks service billing webhook path');
like($validator, qr/Events ticket webhook/, 'OpenBSD validator checks Events webhook routing');
like($validator, qr/\/events\/stripe\/webhook/, 'OpenBSD validator checks Events webhook path');
like($validator, qr/Bookings deposit webhook/, 'OpenBSD validator checks Bookings webhook routing');
like($validator, qr/\/bookings\/stripe\/webhook/, 'OpenBSD validator checks Bookings webhook path');
like($validator, qr/Donations webhook/, 'OpenBSD validator checks Donations webhook routing');
like($validator, qr/\/donate\/stripe\/webhook/, 'OpenBSD validator checks Donations webhook path');
like($validator, qr/application dispatches tokenized Postmark bounce\/spam webhook endpoint/, 'OpenBSD validator checks Postmark webhook dispatch');
like($validator, qr/sub httpd_forwards_prefix/, 'OpenBSD validator centralizes provider endpoint prefix checks');
like($validator, qr/Hosted contributor sites/, 'OpenBSD validator reports hosted contributor site readiness');
like($validator, qr/sub validate_hosted_contributor_sites/, 'OpenBSD validator has a dedicated hosted contributor site check');
like($validator, qr/contributor instance inherits hosted-site deployment from its master CMS/, 'OpenBSD validator skips fleet checks inside contributor instances');
like($validator, qr/hosted contributor site registry is readable/, 'OpenBSD validator reads the contributor site registry');
like($validator, qr/Hosted contributor provisioning queue/, 'OpenBSD validator reports hosted contributor provisioning queue health');
like($validator, qr/sub validate_site_provisioning_queue/, 'OpenBSD validator has a dedicated hosted contributor queue check');
like($validator, qr/contributor instance inherits provisioning queue from its master CMS/, 'OpenBSD validator skips queue checks inside contributor instances');
like($validator, qr/site_provisioning_queue/, 'OpenBSD validator reads the contributor provisioning queue');
like($validator, qr/no failed or stale contributor provisioning jobs/, 'OpenBSD validator reports clean contributor queue health');
like($validator, qr/failed contributor provisioning jobs need retry/, 'OpenBSD validator surfaces failed contributor provisioning jobs');
like($validator, qr/stale contributor provisioning jobs need worker attention/, 'OpenBSD validator surfaces stale queued or running contributor jobs');
like($validator, qr/sub failed_job_blocks_current_state/, 'OpenBSD validator only reports failed queue jobs that still block current site state');
like($validator, qr/action eq 'create' && \$site_status eq 'pending_provision'/, 'OpenBSD validator treats failed create jobs as blocking only while a site is pending provisioning');
like($validator, qr/action eq 'destroy' && \$site_status eq 'destroy_pending'/, 'OpenBSD validator treats failed destroy jobs as blocking only while destroy is pending');
like($validator, qr/hosted site .* config path matches OpenBSD convention/, 'OpenBSD validator checks hosted site config paths');
like($validator, qr/hosted site .* data path matches OpenBSD convention/, 'OpenBSD validator checks hosted site data paths');
like($validator, qr/hosted site .* public root matches OpenBSD convention/, 'OpenBSD validator checks hosted site public roots');
like($validator, qr/hosted site .* config records contributor_site_id/, 'OpenBSD validator checks hosted site contributor_site_id inheritance');
like($validator, qr/hosted site .* config records contributor_domain/, 'OpenBSD validator checks hosted site contributor_domain inheritance');
like($validator, qr/hosted site .* inherits master config path/, 'OpenBSD validator checks hosted site master_config_path inheritance');
like($validator, qr/httpd has a hosted site server block/, 'OpenBSD validator checks hosted site httpd server blocks');
like($validator, qr/httpd routes .* to \$config_path/, 'OpenBSD validator checks hosted site FastCGI config routing');
like($validator, qr/httpd blocks disabled hosted site/, 'OpenBSD validator checks disabled hosted site httpd blocking');

my $acme_example = _read("$FindBin::Bin/../etc/acme-client.conf.example");
unlike($acme_example, qr/"shop\.example\.com"/, 'ACME example does not require a shop subdomain');

my ($plan_out, $plan_err, $plan_status) = _run_capture(
    $^X,
    $installer,
    '--plan-only',
    '--yes',
    '--domain', 'plan.example.com',
    '--site-name', 'Plan Site',
    '--public-root-name', 'plan-public',
    '--server-admin', 'siteadmin',
    '--ssh-allow', '127.0.0.1/32',
    '--no-install-packages',
    '--no-issue-tls',
    '--no-geoip-refresh',
    '--no-post-install-validate',
);
is($plan_status, 0, 'plan-only review exits cleanly');
is($plan_err, '', 'plan-only review stderr is clean');
like($plan_out, qr/Plan-only mode is active/, 'plan-only announces non-mutating mode');
if ($^O eq 'openbsd') {
    like($plan_out, qr/Detected OpenBSD release: \d/, 'plan-only on OpenBSD reports the detected OpenBSD release');
} else {
    like($plan_out, qr/Current OS: /, 'plan-only off OpenBSD reports the current OS truthfully');
    like($plan_out, qr/OpenBSD release will be detected on the target server during install/, 'plan-only off OpenBSD defers OpenBSD release detection to the target server');
    unlike($plan_out, qr/Detected OpenBSD release: 10\.0/, 'plan-only off OpenBSD does not mislabel workstation uname output as OpenBSD');
}
like($plan_out, qr/Plan-only mode: no server-admin password is collected or validated/, 'plan-only avoids password collection');
like($plan_out, qr/Public webroot:\s+\/var\/www\/htdocs\/plan-public/, 'plan-only prints selected public webroot');
like($plan_out, qr/Single-install coverage:/, 'plan-only prints single-install coverage checklist');
like($plan_out, qr/OpenBSD services: desertcms_slowcgi, httpd, pf firewall, acme-client config, doas rules, and root-owned worker cron entries/, 'plan-only coverage includes OpenBSD services');
unlike($plan_out, qr/OpenBSD services: slowcgi,/, 'plan-only coverage names the managed DesertCMS slowcgi rc service, not the base service');
like($plan_out, qr/Dynamic module routing: Admin, Analytics, Forms, Shop \/ Catalog, Events, Directory, Bookings, Membership member portal, Newsletter, Donations, Testimonials, comments, ratings, and checkout dispatch/, 'plan-only coverage includes dynamic module routes');
like($plan_out, qr/Static module output: pages, posts, Media derivatives, Map \/ Locations, Showcase, Docs \/ Resource Hub, Resource downloads, sitemap, robots, redirects, and navigation/, 'plan-only coverage includes generated static module output');
like($plan_out, qr/Provider hooks: Shop \/ Catalog \/stripe\/webhook, hosted service billing \/billing\/stripe\/webhook, Events \/events\/stripe\/webhook, Bookings \/bookings\/stripe\/webhook, Donations \/donate\/stripe\/webhook, and tokenized Postmark bounce\/spam hooks/, 'plan-only coverage includes concrete provider hook paths');
like($plan_out, qr/Hosted SubCMS foundation: contributor site queue worker, generated per-site httpd routing, inherited master-provider config conventions, public-root ownership repair, and validator checks/, 'plan-only coverage includes hosted SubCMS foundation without creating tenants');
like($plan_out, qr/Validation: print the validator command for manual follow-up/, 'plan-only coverage reflects skipped automatic validation');
like($plan_out, qr/Plan review complete/, 'plan-only exits after review');
like($plan_out, qr/No system changes were applied/, 'plan-only reports that nothing changed');
like($plan_out, qr/keep the same --domain, --site-name, --public-root-name, --server-admin, --ssh-allow, TLS, GeoIP, and validation options/, 'plan-only handoff names actual reusable install options');
like($plan_out, qr/dynamic module routes, static module output, provider hooks, hosted SubCMS foundation, and validation/, 'plan-only handoff echoes the concrete install coverage areas');
unlike($plan_out, qr/\bpkg_add\b|\[dry-run\] write|openbsd-apply-site-queue\.pl --install-cron|rcctl restart|pfctl -f|geoip-refresh-dbip-lite/, 'plan-only does not render mutating install commands');

SKIP: {
    skip 'OpenBSD dry-run check only runs on OpenBSD', 8 unless $^O eq 'openbsd';

    my ($out, $err, $status) = _run_capture(
        $^X,
        $installer,
        '--dry-run',
        '--yes',
        '--domain', 'archive.example.com',
        '--site-name', 'DesertArchiveDryRun',
        '--public-root-name', 'dryrun-public',
        '--server-admin', 'siteadmin',
        '--server-password', 'DryRunPassword123',
        '--ssh-allow', '127.0.0.1/32',
        '--no-issue-tls',
    );

    is($status, 0, 'OpenBSD dry-run exits cleanly');
    is($err, '', 'OpenBSD dry-run stderr is clean');
    like($out, qr/Dry-run mode is active/, 'dry-run announces non-mutating mode');
    like($out, qr/(?:Package repository selected|Default OpenBSD package repository appears usable)/, 'dry-run validates package repository');
    like($out, qr/pkg_add -I .*p5-DBI.*p5-DBD-SQLite.*libvips.*p5-HTTP-Daemon/s, 'dry-run renders package install command');
    like($out, qr/\[dry-run\] write \/etc\/desertcms\.conf/, 'dry-run renders config write without applying it');
    like($out, qr/Public webroot:\s+\/var\/www\/htdocs\/dryrun-public/, 'dry-run plan includes selected public webroot');
    like($out, qr/GeoIP setup:\s+try DB-IP City Lite import and backfill/, 'dry-run plan includes GeoIP setup');
    like($out, qr/geoip-refresh-dbip-lite/, 'dry-run renders the GeoIP refresh command');
    like($out, qr/Update DNS wherever your domain is managed\. Edit the DNS records for example\.com/, 'dry-run prints DNS zone guidance');
    like($out, qr/A\s+archive\s+\d+\.\d+\.\d+\.\d+/, 'dry-run prints subdomain A record');
}

done_testing;

sub _run_capture {
    my @cmd = @_;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @cmd);
    close $in;
    my $stdout = do { local $/; <$out> };
    my $stderr = do { local $/; <$err> };
    waitpid($pid, 0);
    my $status = $? == -1 ? 255 : (($? >> 8) || 0);
    return ($stdout || '', $stderr || '', $status);
}

sub _read {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return defined $body ? $body : '';
}
