#!/usr/bin/env perl

use strict;
use warnings;
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempfile);
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::Auth;
use DesertCMS::Blueprints;
use DesertCMS::DB;
use DesertCMS::Email qw(send_postmark);
use DesertCMS::Settings;
use DesertCMS::Util qw(now random_hex slugify);

my %opt = (
    config             => '/etc/desertcms.conf',
    app_root           => '/usr/local/www/desertcms',
    lock_file          => '/var/run/desertcms-site-queue.lock',
    primary_domain     => '',
    shop_domain        => '',
    old_domain         => '',
    max_jobs           => 10,
    quiet              => 0,
    dry_run            => 0,
    install_cron       => 0,
    sync_config         => 0,
    admin_upload_bytes => 67108864,
);
my $www_alias_cache;
my $existing_www_alias_cache;
my $resolved_address_cache;

GetOptionsFromArray(
    \@ARGV,
    'config=s'         => \$opt{config},
    'app-root=s'       => \$opt{app_root},
    'lock-file=s'      => \$opt{lock_file},
    'primary-domain=s' => \$opt{primary_domain},
    'shop-domain=s'    => \$opt{shop_domain},
    'old-domain=s'     => \$opt{old_domain},
    'max-jobs=i'       => \$opt{max_jobs},
    'quiet'            => \$opt{quiet},
    'dry-run'          => \$opt{dry_run},
    'install-cron'     => \$opt{install_cron},
    'sync-config'      => \$opt{sync_config},
) or die usage();

install_cron_and_exit() if $opt{install_cron};
die "this tool must run as root\n" if !$opt{dry_run} && $> != 0;
normalize_global_sync_config();

my $config = DesertCMS::Config->load($opt{config});
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
my $dbh = $db->dbh;

$opt{primary_domain} ||= domain_from_url($config->get('site_url'));
die "primary domain is not configured\n" unless valid_domain($opt{primary_domain});
$opt{shop_domain} ||= dedicated_shop_domain_from_config($config, $opt{primary_domain});
$opt{shop_domain} = safe_site_domain($opt{shop_domain}) if length $opt{shop_domain};
$opt{shop_domain} = '' if $opt{shop_domain} eq $opt{primary_domain};

acquire_lock();
$opt{sync_config} && do {
    sync_webserver();
    exit 0;
};
process_queue();

sub process_queue {
    my $jobs = $dbh->selectall_arrayref(
        q{
            SELECT *
            FROM site_provisioning_queue
            WHERE status = 'queued'
            ORDER BY created_at ASC, id ASC
            LIMIT ?
        },
        { Slice => {} },
        int($opt{max_jobs} || 10)
    );

    log_msg('no queued site work') unless @{$jobs};
    for my $job (@{$jobs}) {
        run_job($job);
    }
}

sub run_job {
    my ($job) = @_;
    my $id = int($job->{id});
    my $site_id = clean_site_id($job->{site_id});
    my $action = $job->{action} || '';
    die "invalid queued action for job $id\n" unless $action =~ /\A(?:create|enable|disable|destroy)\z/;
    $job->{site_id} = $site_id;
    $job->{action} = $action;

    mark_job($id, 'running');
    record_event($job, 'job_started', 'Job started', 'info', "Starting $action for $site_id.");
    eval {
        my $details = decode_details($job->{details_json});
        if ($action eq 'create') {
            apply_create($job, $site_id, $details);
        } elsif ($action eq 'enable') {
            apply_enable($job, $site_id);
        } elsif ($action eq 'disable') {
            apply_disable($job, $site_id);
        } elsif ($action eq 'destroy') {
            apply_destroy($job, $site_id);
        }
        mark_job($id, 'done');
        record_event($job, 'job_done', 'Job completed', 'done', 'All provisioning steps completed.');
        log_msg("job $id $action $site_id done");
        1;
    } or do {
        my $err = $@ || 'unknown queue failure';
        mark_job($id, 'failed', $err);
        record_event($job, 'job_failed', 'Job failed', 'failed', $err);
        log_msg("job $id $action $site_id failed: $err");
    };
}

sub apply_create {
    my ($job, $site_id, $details) = @_;
    my ($site, $domain, $display);
    run_step($job, 'validate_site', 'Validate contributor record', sub {
        $site = site_row($site_id) or die "site not found: $site_id\n";
        $domain = safe_site_domain($site->{domain} || $details->{domain});
        $display = clean_display_name($site->{display_name} || $details->{display_name} || $domain);
    });

    run_step($job, 'provision_files', 'Provision files and database', sub {
        run_cmd('perl', "$opt{app_root}/tools/openbsd-provision-site.pl",
            '--site-id', $site_id,
            '--domain', $domain,
            '--site-name', $display,
            '--source-config', $opt{config},
            '--owner-name', $display,
            '--owner-email', $details->{owner_email} || $site->{owner_email} || '',
        );
    });

    run_step($job, 'store_paths', 'Store OpenBSD paths', sub {
        update_site_paths($site_id, $domain, 'pending_provision');
    });
    run_step($job, 'apply_blueprint', 'Apply contributor blueprint', sub {
        apply_blueprint($site_id, $details);
    });
    run_step($job, 'apply_service_plan', 'Apply service plan limits', sub {
        apply_service_plan($site_id, $details);
    });
    sync_webserver(job => $job, issue_for => $domain);
    run_step($job, 'repair_public_root', 'Repair public root ownership', sub {
        repair_public_root_ownership($site_id);
    });
    run_step($job, 'rebuild_site', 'Rebuild contributor site', sub {
        rebuild_site("/etc/desertcms-$site_id.conf");
    });
    run_step($job, 'send_credentials', 'Send contributor credentials', sub {
        send_contributor_password_setup($site_id, $domain, $details);
    });

    run_step($job, 'activate_site', 'Activate contributor site', sub {
        my $ts = now();
        $dbh->do(
            q{
                UPDATE contributor_sites
                SET status = 'active',
                    config_path = ?,
                    data_dir = ?,
                    public_root = ?,
                    updated_at = ?,
                    provisioned_at = COALESCE(provisioned_at, ?),
                    disabled_at = NULL
                WHERE site_id = ?
            },
            undef,
            "/etc/desertcms-$site_id.conf",
            "/var/desertcms-sites/$site_id",
            "/var/www/htdocs/desertcms-$site_id",
            $ts,
            $ts,
            $site_id
        );
    });
    sync_webserver(job => $job);
}

sub apply_enable {
    my ($job, $site_id) = @_;
    my $site;
    run_step($job, 'validate_site', 'Validate contributor record', sub {
        $site = site_row($site_id) or die "site not found: $site_id\n";
        safe_site_domain($site->{domain});
    });
    run_step($job, 'activate_site', 'Activate contributor site', sub {
        $dbh->do(
            q{
                UPDATE contributor_sites
                SET status = 'active',
                    updated_at = ?,
                    disabled_at = NULL
                WHERE site_id = ?
            },
            undef,
            now(),
            $site_id
        );
    });
    sync_webserver(job => $job, issue_for => $site->{domain});
    run_step($job, 'rebuild_site', 'Rebuild contributor site', sub {
        rebuild_site($site->{config_path} || "/etc/desertcms-$site_id.conf");
    });
}

sub apply_disable {
    my ($job, $site_id) = @_;
    run_step($job, 'validate_site', 'Validate contributor record', sub {
        my $site = site_row($site_id) or die "site not found: $site_id\n";
        safe_site_domain($site->{domain});
    });
    run_step($job, 'disable_site', 'Disable contributor site', sub {
        $dbh->do(
            q{
                UPDATE contributor_sites
                SET status = 'disabled',
                    updated_at = ?,
                    disabled_at = COALESCE(disabled_at, ?)
                WHERE site_id = ?
            },
            undef,
            now(),
            now(),
            $site_id
        );
    });
    sync_webserver(job => $job);
}

sub apply_destroy {
    my ($job, $site_id) = @_;
    my ($site, $domain, $archive);
    run_step($job, 'validate_site', 'Validate contributor record', sub {
        $site = site_row($site_id) or die "site not found: $site_id\n";
        $domain = safe_site_domain($site->{domain});
    });
    run_step($job, 'archive_files', 'Archive contributor files', sub {
        $archive = archive_site_files($site_id, $site);
    });
    run_step($job, 'record_archive', 'Record archived site', sub {
        record_archived_site($site_id, $site, $archive);
    });
    run_step($job, 'erase_site', 'Erase live contributor record', sub {
        my $ts = now();
        $dbh->do(
            q{
                UPDATE contributor_requests
                SET site_id = '',
                    domain = '',
                    public_profile_image_path = '',
                    updated_at = ?
                WHERE site_id = ? OR domain = ?
            },
            undef,
            $ts,
            $site_id,
            $domain
        );
        $dbh->do('DELETE FROM federated_content_reviews WHERE source_site_id = ? OR source_domain = ?', undef, $site_id, $domain);
        remove_public_contributor_profile($site_id);
        $dbh->do(
            'DELETE FROM contributor_sites WHERE site_id = ?',
            undef,
            $site_id
        );
        log_msg("archived $domain to $archive->{path} and erased live contributor record");
    });
    sync_webserver(job => $job);
    run_step($job, 'rebuild_master', 'Rebuild master site', sub {
        rebuild_site($opt{config});
    });
}

sub sync_webserver {
    my (%args) = @_;
    my $job = $args{job};
    if ($job) {
        run_step($job, 'write_acme_config', 'Write ACME config', sub {
            write_acme_config();
        });
        run_step($job, 'write_httpd_config', 'Write httpd config', sub {
            write_httpd_config();
        });
        run_step($job, 'validate_httpd', 'Validate httpd config', sub {
            run_cmd('httpd', '-n');
        });
        run_step($job, 'restart_httpd', 'Restart httpd', sub {
            run_cmd('rcctl', 'restart', 'httpd');
        });

        if ($args{issue_for}) {
            my $domain = safe_site_domain($args{issue_for});
            if (!-f "/etc/ssl/$domain.fullchain.pem") {
                run_step($job, 'issue_tls', 'Issue TLS certificate', sub {
                    run_cmd('acme-client', $domain);
                });
                run_step($job, 'write_httpd_tls_config', 'Write TLS httpd config', sub {
                    write_httpd_config();
                });
                run_step($job, 'validate_httpd_tls', 'Validate TLS httpd config', sub {
                    run_cmd('httpd', '-n');
                });
                run_step($job, 'restart_httpd_tls', 'Restart httpd after TLS', sub {
                    run_cmd('rcctl', 'restart', 'httpd');
                });
            } else {
                record_event($job, 'issue_tls', 'Issue TLS certificate', 'info', "Certificate already exists for $domain.");
            }
        }
        return;
    }

    write_acme_config();
    write_httpd_config();
    run_cmd('httpd', '-n');
    run_cmd('rcctl', 'restart', 'httpd');

    if ($args{issue_for}) {
        my $domain = safe_site_domain($args{issue_for});
        if (!-f "/etc/ssl/$domain.fullchain.pem") {
            run_cmd('acme-client', $domain);
            write_httpd_config();
            run_cmd('httpd', '-n');
            run_cmd('rcctl', 'restart', 'httpd');
        }
    }
}

sub normalize_global_sync_config {
    return unless $opt{sync_config};

    my $global_config = '/etc/desertcms.conf';
    return unless -f $global_config;

    my $requested = _absolute_path($opt{config});
    return if $requested eq _absolute_path($global_config);

    my $global = eval { DesertCMS::Config->load($global_config) };
    return unless $global;

    my $raw = $global->get('standalone_master_configs') || '';
    my %standalone = map { _absolute_path($_) => 1 }
        grep { length } split /[,\s]+/, $raw;
    return unless $standalone{$requested};

    log_msg("using $global_config for global webserver sync; $opt{config} is a standalone master config");
    $opt{config} = $global_config;
}

sub _absolute_path {
    my ($path) = @_;
    $path = '' unless defined $path;
    return File::Spec->rel2abs($path);
}

sub write_acme_config {
    my @domains = acme_domains();
    my $body = qq|authority letsencrypt {\n\tapi url "https://acme-v02.api.letsencrypt.org/directory"\n\taccount key "/etc/acme/letsencrypt-privkey.pem"\n}\n\n|;
    for my $domain (@domains) {
        $body .= qq|domain "$domain" {\n|;
        my @alts;
        if ($domain eq $opt{primary_domain} && has_dedicated_shop_domain()) {
            push @alts, $opt{shop_domain};
        }
        push @alts, www_aliases($domain);
        my %seen_alt;
        @alts = grep { valid_domain($_) && $_ ne $domain && !$seen_alt{$_}++ } @alts;
        if (@alts) {
            $body .= "\talternative names { " . join(' ', map { qq{"$_"} } @alts) . " }\n";
        }
        $body .= qq{\tdomain key "/etc/ssl/private/$domain.key"\n};
        $body .= qq{\tdomain full chain certificate "/etc/ssl/$domain.fullchain.pem"\n};
        $body .= qq{\tsign with letsencrypt\n};
        $body .= "}\n\n";
    }
    write_root_file('/etc/acme-client.conf', $body, 0644);
}

sub write_httpd_config {
    my $main_root = chroot_root($config->get('public_root'));
    my $body = qq{# DesertCMS multi-site httpd config generated by tools/openbsd-apply-site-queue.pl.\n\n};
    $body .= qq|types {\n\tinclude "/usr/share/misc/mime.types"\n}\n\n|;
    $body .= tls_app_server($opt{primary_domain}, $main_root, '/etc/desertcms.conf', 'active');
    $body .= tls_www_redirect_servers($opt{primary_domain}, $main_root, "https://$opt{primary_domain}");
    if (has_dedicated_shop_domain() && cert_exists($opt{primary_domain})) {
        $body .= tls_shop_server($opt{shop_domain}, $main_root, '/etc/desertcms.conf');
    }

    for my $site (@{standalone_master_sites()}) {
        my $domain = safe_site_domain($site->{domain});
        my $root = chroot_root($site->{public_root});
        my $cms_config = $site->{config_path};
        $body .= tls_app_server($domain, $root, $cms_config, 'active');
        $body .= tls_www_redirect_servers($domain, $root, "https://$domain");
    }

    for my $site (@{served_sites()}) {
        my $state = $site->{status} eq 'disabled' ? 'disabled' : 'active';
        my $domain = safe_site_domain($site->{domain});
        my $root = chroot_root($site->{public_root} || "/var/www/htdocs/desertcms-$site->{site_id}");
        my $cms_config = $site->{config_path} || "/etc/desertcms-$site->{site_id}.conf";
        $body .= tls_app_server(
            $domain,
            $root,
            $cms_config,
            $state
        );
        $body .= tls_www_redirect_servers($domain, $root, "https://$domain");
    }

    if (valid_domain($opt{old_domain}) && -f "/etc/ssl/$opt{old_domain}.fullchain.pem") {
        $body .= tls_redirect_server($opt{old_domain}, $main_root, "https://$opt{primary_domain}");
    }

    $body .= http_server($opt{primary_domain}, $main_root, "https://$opt{primary_domain}", cert_exists($opt{primary_domain}), 'active');
    if (has_dedicated_shop_domain()) {
        $body .= http_shop_server($opt{shop_domain}, $main_root, cert_exists($opt{primary_domain}));
    }
    for my $site (@{standalone_master_sites()}) {
        my $domain = safe_site_domain($site->{domain});
        $body .= http_server(
            $domain,
            chroot_root($site->{public_root}),
            "https://$domain",
            cert_exists($domain),
            'active'
        );
    }
    for my $site (@{served_sites()}) {
        my $domain = safe_site_domain($site->{domain});
        my $state = $site->{status} eq 'disabled' ? 'disabled' : 'active';
        $body .= http_server(
            $domain,
            chroot_root($site->{public_root} || "/var/www/htdocs/desertcms-$site->{site_id}"),
            "https://$domain",
            cert_exists($domain),
            $state
        );
    }
    if (valid_domain($opt{old_domain})) {
        $body .= http_server($opt{old_domain}, $main_root, "https://$opt{primary_domain}", cert_exists($opt{old_domain}), 'active');
    }

    write_root_file('/etc/httpd.conf', $body, 0644);
}

sub tls_app_server {
    my ($domain, $root, $cms_config, $state) = @_;
    return '' unless cert_exists($domain);
    my $body = qq|server "$domain" {\n|;
    $body .= qq{\tlisten on * tls port 443\n};
    $body .= qq{\troot "$root"\n\n};
    $body .= qq|\tconnection {\n\t\tmax request body $opt{admin_upload_bytes}\n\t}\n\n|;
    $body .= tls_block($domain);
    $body .= qq|\thsts {\n\t\tmax-age 31536000\n\t}\n\n|;
    $body .= acme_location();
    if ($state eq 'disabled') {
        $body .= block_all_location(403);
    } else {
        for my $route (httpd_dynamic_routes()) {
            $body .= fastcgi_location("/$route*", "/$route", $cms_config);
        }
    }
    $body .= "}\n\n";
    return $body;
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

sub tls_shop_server {
    my ($domain, $root, $cms_config) = @_;
    my $body = qq|server "$domain" {\n|;
    $body .= qq{\tlisten on * tls port 443\n};
    $body .= qq{\troot "$root"\n\n};
    $body .= qq|\tconnection {\n\t\tmax request body $opt{admin_upload_bytes}\n\t}\n\n|;
    $body .= qq|\ttls {\n\t\tcertificate "/etc/ssl/$opt{primary_domain}.fullchain.pem"\n\t\tkey "/etc/ssl/private/$opt{primary_domain}.key"\n\t}\n\n|;
    $body .= qq|\thsts {\n\t\tmax-age 31536000\n\t}\n\n|;
    $body .= acme_location();
    $body .= fastcgi_location('/', '/', $cms_config);
    $body .= fastcgi_location('/checkout', '/checkout', $cms_config);
    $body .= fastcgi_location('/success', '/success', $cms_config);
    $body .= fastcgi_location('/cancel', '/cancel', $cms_config);
    $body .= fastcgi_location('/stripe/*', '/stripe', $cms_config);
    $body .= "}\n\n";
    return $body;
}

sub tls_redirect_server {
    my ($domain, $root, $target) = @_;
    my $body = qq|server "$domain" {\n|;
    $body .= server_aliases($domain);
    $body .= qq{\tlisten on * tls port 443\n};
    $body .= qq{\troot "$root"\n\n};
    $body .= tls_block($domain);
    $body .= acme_location();
    $body .= redirect_location($target);
    $body .= "}\n\n";
    return $body;
}

sub tls_www_redirect_servers {
    my ($domain, $root, $target) = @_;
    return '' unless cert_exists($domain);

    my $body = '';
    for my $alias (www_aliases($domain)) {
        $body .= tls_alias_redirect_server($alias, $domain, $root, $target);
    }
    return $body;
}

sub tls_alias_redirect_server {
    my ($alias, $cert_domain, $root, $target) = @_;
    my $body = qq|server "$alias" {\n|;
    $body .= qq{\tlisten on * tls port 443\n};
    $body .= qq{\troot "$root"\n\n};
    $body .= tls_block($cert_domain);
    $body .= qq|\thsts {\n\t\tmax-age 31536000\n\t}\n\n|;
    $body .= acme_location();
    $body .= redirect_location($target);
    $body .= "}\n\n";
    return $body;
}

sub http_server {
    my ($domain, $root, $target, $has_cert, $state) = @_;
    my $body = qq|server "$domain" {\n|;
    $body .= server_aliases($domain);
    $body .= qq{\tlisten on * port 80\n};
    $body .= qq{\troot "$root"\n\n};
    $body .= acme_location();
    if ($state eq 'disabled') {
        $body .= block_all_location(403);
    } elsif ($has_cert) {
        $body .= redirect_location($target);
    } else {
        $body .= block_all_location(503);
    }
    $body .= "}\n\n";
    return $body;
}

sub http_shop_server {
    my ($domain, $root, $has_cert) = @_;
    my $body = qq|server "$domain" {\n|;
    $body .= qq{\tlisten on * port 80\n};
    $body .= qq{\troot "$root"\n\n};
    $body .= acme_location();
    if ($has_cert) {
        $body .= redirect_location("https://$domain");
    } else {
        $body .= block_all_location(503);
    }
    $body .= "}\n\n";
    return $body;
}

sub tls_block {
    my ($domain) = @_;
    return qq|\ttls {\n\t\tcertificate "/etc/ssl/$domain.fullchain.pem"\n\t\tkey "/etc/ssl/private/$domain.key"\n\t}\n\n|;
}

sub acme_location {
    return qq|\tlocation "/.well-known/acme-challenge/*" {\n\t\troot "/acme"\n\t\trequest strip 2\n\t}\n\n|;
}

sub fastcgi_location {
    my ($path, $script_name, $cms_config) = @_;
    return qq|\tlocation "$path" {\n\t\tfastcgi {\n\t\t\tsocket "/run/desertcms.sock"\n\t\t\tparam SCRIPT_FILENAME "$opt{app_root}/bin/desertcms.cgi"\n\t\t\tparam SCRIPT_NAME "$script_name"\n\t\t\tparam DESERTCMS_CONFIG "$cms_config"\n\t\t}\n\t}\n\n|;
}

sub redirect_location {
    my ($target) = @_;
    return qq|\tlocation "/*" {\n\t\tblock return 301 "$target\$REQUEST_URI"\n\t}\n\n|;
}

sub block_all_location {
    my ($status) = @_;
    return qq|\tlocation "/*" {\n\t\tblock return $status\n\t}\n\n|;
}

sub server_aliases {
    my ($domain) = @_;
    my $body = '';
    for my $alias (www_aliases($domain)) {
        $body .= qq{\talias "$alias"\n};
    }
    return $body;
}

sub www_aliases {
    my ($domain) = @_;
    return () unless valid_domain($domain);
    $www_alias_cache ||= {};
    return @{$www_alias_cache->{$domain}} if exists $www_alias_cache->{$domain};

    my $aliases = existing_www_aliases();
    my @aliases;
    push @aliases, $aliases->{$domain} if exists $aliases->{$domain};

    my $www = "www.$domain";
    push @aliases, $www if www_points_to_domain($www, $domain);

    my %seen;
    @aliases = grep { valid_domain($_) && !$seen{$_}++ } @aliases;
    $www_alias_cache->{$domain} = \@aliases;
    return @aliases;
}

sub existing_www_aliases {
    return $existing_www_alias_cache if defined $existing_www_alias_cache;

    my %aliases;
    if (open my $fh, '<', '/etc/acme-client.conf') {
        local $/;
        my $body = <$fh>;
        close $fh;

        while ($body =~ /domain\s+"([^"]+)"\s*\{(.*?)\n\}/sg) {
            my ($domain, $block) = ($1, $2);
            next unless valid_domain($domain);
            my $expected = "www.$domain";

            while ($block =~ /alternative names\s+\{([^}]+)\}/g) {
                my $names = $1;
                while ($names =~ /"([^"]+)"/g) {
                    my $alias = lc($1 || '');
                    $alias =~ s/^\s+|\s+$//g;
                    $aliases{$domain} = $alias
                        if $alias eq $expected && valid_domain($alias);
                }
            }
        }
    }

    $existing_www_alias_cache = \%aliases;
    return $existing_www_alias_cache;
}

sub www_points_to_domain {
    my ($alias, $domain) = @_;
    return 0 unless valid_domain($alias) && valid_domain($domain);

    my @domain_addresses = resolved_addresses($domain);
    my @alias_addresses = resolved_addresses($alias);
    return 0 unless @domain_addresses && @alias_addresses;

    my %domain_address = map { $_ => 1 } @domain_addresses;
    for my $address (@alias_addresses) {
        return 1 if $domain_address{$address};
    }
    return 0;
}

sub resolved_addresses {
    my ($domain) = @_;
    $resolved_address_cache ||= {};
    return @{$resolved_address_cache->{$domain}} if exists $resolved_address_cache->{$domain};

    my @addresses;
    for my $type (qw(A AAAA)) {
        next unless open my $pipe, '-|', 'host', '-t', $type, $domain;
        while (my $line = <$pipe>) {
            push @addresses, $1 if $line =~ /\bhas address\s+([0-9.]+)/i;
            push @addresses, lc($1) if $line =~ /\bhas IPv6 address\s+([0-9a-f:]+)/i;
        }
        close $pipe;
    }

    my %seen;
    @addresses = grep { length && !$seen{$_}++ } @addresses;
    $resolved_address_cache->{$domain} = \@addresses;
    return @addresses;
}

sub acme_domains {
    my %seen;
    my @domains;
    for my $domain ($opt{primary_domain}, $opt{old_domain}) {
        next unless valid_domain($domain);
        next if $seen{$domain}++;
        push @domains, $domain;
    }
    for my $site (@{standalone_master_sites()}) {
        my $domain = safe_site_domain($site->{domain});
        next if has_dedicated_shop_domain() && $domain eq $opt{shop_domain};
        next if $seen{$domain}++;
        push @domains, $domain;
    }
    for my $site (@{served_sites()}) {
        my $domain = safe_site_domain($site->{domain});
        next if has_dedicated_shop_domain() && $domain eq $opt{shop_domain};
        next if $seen{$domain}++;
        push @domains, $domain;
    }
    return @domains;
}

sub served_sites {
    my $rows = $dbh->selectall_arrayref(
        q{
            SELECT *
            FROM contributor_sites
            WHERE status IN ('active', 'disabled', 'pending_provision')
            ORDER BY domain ASC
        },
        { Slice => {} }
    );
    my $root = contributor_domain_root();
    return [
        grep {
            my $domain = safe_site_domain($_->{domain});
            !(has_dedicated_shop_domain() && $domain eq $opt{shop_domain})
                && (!length($root) || domain_is_subdomain($domain, $root))
        } @{$rows}
    ];
}

sub standalone_master_sites {
    my $raw = $config->get('standalone_master_configs') || '';
    my @paths = grep { length } split /[,\s]+/, $raw;
    my (%seen, @sites);
    for my $path (@paths) {
        next unless $path =~ m{\A/etc/desertcms(?:-[a-z0-9-]+)?\.conf\z};
        next unless -f $path;
        my $site_config = eval { DesertCMS::Config->load($path) };
        next unless $site_config;
        my $domain = eval { safe_site_domain(domain_from_url($site_config->get('site_url'))) };
        next unless $domain && !$seen{$domain}++;
        next if $domain eq $opt{primary_domain};
        next if valid_domain($opt{old_domain}) && $domain eq $opt{old_domain};
        next if has_dedicated_shop_domain() && $domain eq $opt{shop_domain};
        my $public_root = $site_config->get('public_root') || '';
        next unless $public_root =~ m{\A/var/www/};
        push @sites, {
            domain      => $domain,
            public_root => $public_root,
            config_path => $path,
        };
    }
    return \@sites;
}

sub contributor_domain_root {
    my $settings = eval { DesertCMS::Settings::all($config, $db) } || {};
    my $root = $settings->{contributor_domain_root} || '';
    if (!length $root) {
        $root = $opt{primary_domain} || domain_from_url($config->get('site_url'));
    }
    $root = lc($root || '');
    $root =~ s{\Ahttps?://}{}i;
    $root =~ s{/.*\z}{};
    $root =~ s/^\.+|\.+$//g;
    return $root =~ /\A[a-z0-9.-]+\.[a-z]{2,}\z/ ? $root : '';
}

sub domain_is_subdomain {
    my ($domain, $root) = @_;
    $domain = lc($domain || '');
    $root = lc($root || '');
    $domain =~ s/^\.+|\.+$//g;
    $root =~ s/^\.+|\.+$//g;
    return 0 unless length $domain && length $root;
    return 0 if $domain eq $root;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+\Q$root\E\z/ ? 1 : 0;
}

sub site_row {
    my ($site_id) = @_;
    return $dbh->selectrow_hashref(
        'SELECT * FROM contributor_sites WHERE site_id = ?',
        undef,
        $site_id
    );
}

sub update_site_paths {
    my ($site_id, $domain, $status) = @_;
    $dbh->do(
        q{
            UPDATE contributor_sites
            SET domain = ?,
                status = ?,
                config_path = ?,
                data_dir = ?,
                public_root = ?,
                updated_at = ?
            WHERE site_id = ?
        },
        undef,
        $domain,
        $status,
        "/etc/desertcms-$site_id.conf",
        "/var/desertcms-sites/$site_id",
        "/var/www/htdocs/desertcms-$site_id",
        now(),
        $site_id
    );
}

sub apply_blueprint {
    my ($site_id, $details) = @_;
    my $snapshot = $details->{blueprint} || {};
    return unless ref $snapshot eq 'HASH' && $snapshot->{schema_version};

    my $config_path = "/etc/desertcms-$site_id.conf";
    return unless -f $config_path;
    my $site_config = DesertCMS::Config->load($config_path);
    my $site_db = DesertCMS::DB->new(config => $site_config);
    $site_db->migrate;
    DesertCMS::Settings::set_many(
        $site_config,
        $site_db,
        DesertCMS::Blueprints::settings_from_snapshot($snapshot)
    );
    DesertCMS::Blueprints->seed_default_pages($site_config, $site_db, $snapshot, defer_publication => 1);
}

sub apply_service_plan {
    my ($site_id, $details) = @_;
    my $snapshot = $details->{service_plan} || {};
    return unless ref $snapshot eq 'HASH' && $snapshot->{schema_version};

    my $config_path = "/etc/desertcms-$site_id.conf";
    return unless -f $config_path;
    my $site_config = DesertCMS::Config->load($config_path);
    my $site_db = DesertCMS::DB->new(config => $site_config);
    $site_db->migrate;
    DesertCMS::Settings::set_many(
        $site_config,
        $site_db,
        {
            contributor_media_quota_mb => int($snapshot->{media_quota_mb} || 0),
            contributor_post_quota     => int($snapshot->{post_quota} || 0),
            contributor_page_quota     => int($snapshot->{page_quota} || 0),
        }
    );
}

sub archive_site_files {
    my ($site_id, $site) = @_;
    my $paths = expected_site_paths($site_id);
    my $domain = safe_site_domain($site->{domain});
    my $archive_root = '/var/desertcms-sites-archive';
    my $stamp = timestamp();
    my $staging_name = "$site_id-$stamp";
    my $staging = File::Spec->catdir($archive_root, $staging_name);
    my $archive_filename = archive_filename_for_site($site_id, $site);
    my $archive_path = unique_archive_path($archive_root, $archive_filename);

    run_cmd('install', '-d', '-o', 'root', '-g', 'wheel', '-m', '700', $archive_root);
    run_cmd('install', '-d', '-o', 'root', '-g', 'wheel', '-m', '700', $staging);

    archive_move($site->{config_path} || $paths->{config_path}, File::Spec->catfile($staging, 'config.conf'), $paths->{config_path});
    archive_move($site->{data_dir} || $paths->{data_dir}, File::Spec->catdir($staging, 'data'), $paths->{data_dir});
    archive_move($site->{public_root} || $paths->{public_root}, File::Spec->catdir($staging, 'public'), $paths->{public_root});
    archive_move("/etc/ssl/$domain.fullchain.pem", File::Spec->catfile($staging, "$domain.fullchain.pem"), "/etc/ssl/$domain.fullchain.pem");
    archive_move("/etc/ssl/private/$domain.key", File::Spec->catfile($staging, "$domain.key"), "/etc/ssl/private/$domain.key");

    run_cmd('tar', '-czf', $archive_path, '-C', $archive_root, $staging_name);
    if (!$opt{dry_run}) {
        remove_tree($staging, { safe => 1 }) if -d $staging;
    }

    return {
        path       => $archive_path,
        filename   => (File::Spec->splitpath($archive_path))[2],
        bytes      => (!$opt{dry_run} && -f $archive_path) ? (-s $archive_path || 0) : 0,
        staged_dir => $staging,
    };
}

sub archive_move {
    my ($source, $dest, $expected) = @_;
    return unless defined $source && length $source && -e $source;
    die "refusing to archive path not bound to queued site: $source\n"
        unless defined $expected && length $expected && $source eq $expected;
    log_msg("archive $source -> $dest");
    return if $opt{dry_run};
    rename $source, $dest or die "cannot archive $source to $dest: $!\n";
}

sub record_archived_site {
    my ($site_id, $site, $archive) = @_;
    die "archive metadata is missing\n" unless $archive && ref $archive eq 'HASH' && ($archive->{path} || '') ne '';
    my $paths = expected_site_paths($site_id);
    my $details = {
        config_path  => $paths->{config_path},
        data_dir     => $paths->{data_dir},
        public_root  => $paths->{public_root},
        domain       => $site->{domain} || '',
        archived_by  => 'site-queue-worker',
    };
    $dbh->do(
        q{
            INSERT INTO archived_sites
                (site_id, domain, display_name, owner_first_name, owner_last_initial, owner_email,
                 archive_path, archive_filename, archive_bytes, details_json, archived_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $site_id,
        $site->{domain} || '',
        $site->{display_name} || '',
        $site->{owner_first_name} || '',
        $site->{owner_last_initial} || '',
        $site->{owner_email} || '',
        $archive->{path},
        $archive->{filename} || '',
        int($archive->{bytes} || 0),
        encode_json($details),
        now()
    );
}

sub expected_site_paths {
    my ($site_id) = @_;
    $site_id = clean_site_id($site_id);
    return {
        config_path => "/etc/desertcms-$site_id.conf",
        data_dir    => "/var/desertcms-sites/$site_id",
        public_root => "/var/www/htdocs/desertcms-$site_id",
    };
}

sub repair_public_root_ownership {
    my ($site_id) = @_;
    $site_id = clean_site_id($site_id);
    die "site id is required\n" unless length $site_id;
    my $paths = expected_site_paths($site_id);
    my $root = $paths->{public_root};
    die "refusing to repair unsafe public root: $root\n"
        unless $root =~ m{\A/var/www/htdocs/desertcms-[a-z0-9][a-z0-9-]{1,62}\z};
    return unless -d $root;
    run_cmd('chown', '-R', '_desertcms:_desertcms', $root);
}

sub archive_filename_for_site {
    my ($site_id, $site) = @_;
    my $label = archive_label_for_site($site_id, $site);
    return $label . '-' . archive_date_stamp() . '.tar.gz';
}

sub archive_label_for_site {
    my ($site_id, $site) = @_;
    my $label = $site->{owner_first_name} || '';
    if ($label !~ /\S/ && ($site->{display_name} || '') =~ /([A-Za-z0-9]+)/) {
        $label = $1;
    }
    $label = $site_id if $label !~ /\S/;
    $label = lc($label);
    $label =~ s/[^a-z0-9]+/-/g;
    $label =~ s/\A-+|-+\z//g;
    return length($label) ? $label : 'site';
}

sub archive_date_stamp {
    my @t = localtime(now());
    return sprintf '%02d%02d%04d',
        $t[4] + 1,
        $t[3],
        $t[5] + 1900;
}

sub unique_archive_path {
    my ($dir, $filename) = @_;
    my ($base, $suffix) = $filename =~ /\A(.+?)(\.tar\.gz)\z/
        ? ($1, $2)
        : ($filename, '');
    my $path = File::Spec->catfile($dir, $filename);
    my $counter = 2;
    while (-e $path) {
        $path = File::Spec->catfile($dir, "$base-$counter$suffix");
        $counter++;
    }
    return $path;
}

sub remove_public_contributor_profile {
    my ($site_id) = @_;
    $site_id = clean_site_id($site_id);
    return unless length $site_id;
    my $public_root = $config->get('public_root') || '';
    return unless $public_root =~ m{\A/var/www/htdocs/};
    for my $ext (qw(jpg jpeg png webp)) {
        my $path = File::Spec->catfile($public_root, 'assets', 'contributors', "$site_id.$ext");
        next unless -f $path;
        die "refusing to remove unsafe contributor profile path: $path\n"
            unless $path =~ m{\A/var/www/htdocs/[^/]+/assets/contributors/[a-z0-9-]+\.(?:jpe?g|png|webp)\z};
        log_msg("remove public contributor profile $path");
        unlink $path or die "cannot remove $path: $!\n" unless $opt{dry_run};
    }
}

sub rebuild_site {
    my ($config_path) = @_;
    return unless defined $config_path && length $config_path && -f $config_path;
    run_cmd('su', '-m', '_desertcms', '-c',
        join(' ', map { shell_quote($_) } (
            'env',
            "DESERTCMS_CONFIG=$config_path",
            'perl',
            "$opt{app_root}/bin/desertcms-maint.pl",
            'rebuild',
        ))
    );
}

sub send_contributor_password_setup {
    my ($site_id, $domain, $details) = @_;
    my $email = normalize_email($details->{owner_email} || '');
    return unless valid_email($email);

    my $site_config_path = "/etc/desertcms-$site_id.conf";
    return unless -f $site_config_path;
    my $site_config = DesertCMS::Config->load($site_config_path);
    my $site_db = DesertCMS::DB->new(config => $site_config);
    $site_db->migrate;
    copy_email_settings_to_site($site_config, $site_db);

    my $username = contributor_username($details, $site_id);
    my $temporary_password = random_hex(12);
    my $auth = DesertCMS::Auth->new(config => $site_config, db => $site_db);
    $auth->grant_admin_access(
        username => $username,
        email    => $email,
        role     => 'contributor',
        password => $temporary_password,
    );
    my $reset = $auth->create_password_reset_token_for_email(
        email       => $email,
        ttl_seconds => 7 * 24 * 60 * 60,
    );
    return unless $reset;

    my $url = "https://$domain/admin/password/reset/$reset->{token}";
    my $admin_url = "https://$domain/admin";
    my $subject = "Set up your $domain admin password";
    my $text = join "\n\n",
        "Your contributor site is ready:",
        "https://$domain/",
        "Admin URL: $admin_url",
        "Username: $username",
        "Temporary password: $temporary_password",
        "Use this link to choose your permanent admin username and password:",
        $url;
    my $html = '<p>Your contributor site is ready:</p><p><a href="https://'
        . html($domain)
        . '/">https://'
        . html($domain)
        . '/</a></p><p><strong>Admin URL:</strong> <a href="'
        . html($admin_url)
        . '">'
        . html($admin_url)
        . '</a><br><strong>Username:</strong> '
        . html($username)
        . '<br><strong>Temporary password:</strong> '
        . html($temporary_password)
        . '</p><p><a href="'
        . html($url)
        . '">Choose your permanent admin username and password</a></p>';

    my ($sent, $reason) = send_postmark(
        $config,
        $db,
        to         => $email,
        email_type => 'contributor_setup',
        subject    => $subject,
        text_body  => $text,
        html_body  => $html,
    );
    die "could not send contributor password setup email: $reason\n" unless $sent;
}

sub copy_email_settings_to_site {
    my ($site_config, $site_db) = @_;
    my $settings = DesertCMS::Settings::all($config, $db);
    DesertCMS::Settings::set_many($site_config, $site_db, {
        postmark_sender_mode  => 'inherit',
        postmark_from_email   => $settings->{postmark_from_email} || '',
        postmark_server_token => $settings->{postmark_server_token} || '',
    });
}

sub contributor_username {
    my ($details, $site_id) = @_;
    my $base = slugify($details->{owner_first_name} || $site_id || 'admin');
    $base =~ s/-/./g;
    $base =~ s/[^a-z0-9._-]//g;
    $base = $site_id if length($base) < 3;
    $base = 'admin' if length($base) < 3;
    return substr($base, 0, 64);
}

sub write_root_file {
    my ($path, $body, $mode) = @_;
    if (-f $path) {
        open my $existing_fh, '<', $path or die "cannot read $path: $!\n";
        local $/;
        my $existing = <$existing_fh>;
        close $existing_fh;
        return if defined $existing && $existing eq $body;
    }

    log_msg("write $path");
    return if $opt{dry_run};

    backup_root_file($path) if $path =~ m{\A/etc/(?:httpd|acme-client)\.conf\z};
    my $tmp = "$path.new.$$";
    open my $fh, '>', $tmp or die "cannot write $tmp: $!\n";
    print {$fh} $body;
    close $fh;
    chmod $mode, $tmp or die "cannot chmod $tmp: $!\n";
    rename $tmp, $path or die "cannot replace $path: $!\n";
}

sub backup_root_file {
    my ($path) = @_;
    return unless -f $path;
    my $backup = "$path.bak." . timestamp();
    open my $in, '<', $path or die "cannot read $path for backup: $!\n";
    open my $out, '>', $backup or die "cannot write backup $backup: $!\n";
    while (my $chunk = <$in>) {
        print {$out} $chunk;
    }
    close $out;
    close $in;
    chmod 0600, $backup if $path eq '/etc/acme-client.conf';
}

sub run_cmd {
    my @cmd = @_;
    my $label = join ' ', map { shell_quote($_) } @cmd;
    log_msg($label);
    return if $opt{dry_run};

    my ($fh, $path) = tempfile('desertcms-cmd-XXXXXX', TMPDIR => 1, UNLINK => 1);
    my $pid = fork();
    die "cannot fork for command: $label: $!\n" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>&', $fh or die "cannot redirect stdout: $!\n";
        open STDERR, '>&', $fh or die "cannot redirect stderr: $!\n";
        exec @cmd or do {
            print STDERR "cannot exec $cmd[0]: $!\n";
            exit 127;
        };
    }
    waitpid($pid, 0);
    my $status = $?;
    seek $fh, 0, 0;
    local $/;
    my $output = <$fh>;
    $output = '' unless defined $output;
    close $fh;
    return if $status == 0;

    my $status_label = command_status_label($status);
    $output =~ s/\s+\z//;
    my $message = "command failed ($status_label): $label";
    $message .= "\n$output" if length $output;
    die "$message\n";
}

sub command_status_label {
    my ($status) = @_;
    return 'exec failed' if $status == -1;
    return 'signal ' . ($status & 127) if $status & 127;
    return 'exit ' . ($status >> 8);
}

sub run_step {
    my ($job, $key, $label, $code) = @_;
    record_event($job, $key, $label, 'running', '');
    my $ok = eval {
        $code->();
        1;
    };
    if (!$ok) {
        my $err = $@ || 'step failed';
        record_event($job, $key, $label, 'failed', $err);
        die $err;
    }
    record_event($job, $key, $label, 'done', '');
}

sub record_event {
    my ($job, $key, $label, $status, $message) = @_;
    return unless $job && int($job->{id} || 0) > 0;
    my $site_id = clean_site_id($job->{site_id});
    return unless length $site_id;
    my $action = $job->{action} || '';
    return unless $action =~ /\A(?:create|enable|disable|destroy)\z/;
    $status = 'info' unless ($status || '') =~ /\A(?:running|done|failed|info)\z/;
    $key = lc($key || 'event');
    $key =~ s/[^a-z0-9_:-]+/_/g;
    $key = substr($key || 'event', 0, 80);
    $label = substr($label || $key, 0, 160);
    $message = substr($message || '', 0, 2000);
    my $ok = eval {
        $dbh->do(
            q{
                INSERT INTO site_provisioning_events
                    (queue_id, site_id, action, step_key, step_label, status, message, created_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            int($job->{id}),
            $site_id,
            $action,
            $key,
            $label,
            $status,
            $message,
            now()
        );
        1;
    };
    log_msg("could not record provisioning event for job $job->{id}: " . ($@ || 'unknown error')) unless $ok;
}

sub mark_job {
    my ($id, $status, $error) = @_;
    my $ts = now();
    if ($status eq 'done') {
        $dbh->do(
            q{UPDATE site_provisioning_queue SET status = ?, updated_at = ?, completed_at = ?, error_text = '' WHERE id = ?},
            undef,
            $status,
            $ts,
            $ts,
            $id
        );
    } elsif ($status eq 'failed') {
        $dbh->do(
            q{UPDATE site_provisioning_queue SET status = ?, updated_at = ?, completed_at = ?, error_text = ? WHERE id = ?},
            undef,
            $status,
            $ts,
            $ts,
            substr($error || 'unknown error', 0, 4000),
            $id
        );
    } else {
        $dbh->do(
            q{UPDATE site_provisioning_queue SET status = ?, updated_at = ?, error_text = '' WHERE id = ?},
            undef,
            $status,
            $ts,
            $id
        );
    }
}

sub acquire_lock {
    return if $opt{dry_run};
    open my $fh, '>', $opt{lock_file} or die "cannot open lock $opt{lock_file}: $!\n";
    if (!flock($fh, LOCK_EX | LOCK_NB)) {
        log_msg('queue applier already running');
        exit 0;
    }
    $SIG{INT} = $SIG{TERM} = sub { close $fh; exit 1 };
}

sub install_cron_and_exit {
    die "--install-cron must run as root\n" if $> != 0;
    my $cmd = "$^X $opt{app_root}/tools/openbsd-apply-site-queue.pl --quiet";
    my $marker = '# DesertCMS site queue worker';
    my $current = qx(crontab -l 2>/dev/null);
    my @lines = grep { $_ !~ /\Q$marker\E/ && $_ !~ /openbsd-apply-site-queue\.pl/ } split /\n/, $current;
    push @lines, $marker, "* * * * * $cmd";
    my $body = join("\n", @lines) . "\n";
    open my $pipe, '|-', 'crontab', '-' or die "cannot install root crontab: $!\n";
    print {$pipe} $body;
    close $pipe or die "crontab install failed\n";
    print "installed root cron worker for DesertCMS site queue\n";
    exit 0;
}

sub cert_exists {
    my ($domain) = @_;
    return -f "/etc/ssl/$domain.fullchain.pem" && -f "/etc/ssl/private/$domain.key";
}

sub chroot_root {
    my ($path) = @_;
    $path ||= '';
    $path =~ s{/+\z}{};
    die "public root must be under /var/www: $path\n" unless $path =~ s{\A/var/www}{};
    return $path || '/';
}

sub safe_site_domain {
    my ($domain) = @_;
    $domain = lc($domain || '');
    $domain =~ s/^\s+|\s+$//g;
    $domain =~ s/^\.+|\.+$//g;
    die "unsafe site domain: $domain\n" unless valid_domain($domain);
    return $domain;
}

sub valid_domain {
    my ($domain) = @_;
    return defined $domain && $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/ ? 1 : 0;
}

sub has_dedicated_shop_domain {
    return valid_domain($opt{shop_domain}) && $opt{shop_domain} ne $opt{primary_domain};
}

sub normalize_email {
    my ($email) = @_;
    $email = lc($email || '');
    $email =~ s/^\s+|\s+$//g;
    return $email;
}

sub valid_email {
    my ($email) = @_;
    return defined $email && $email =~ /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z/ ? 1 : 0;
}

sub clean_site_id {
    my ($site_id) = @_;
    $site_id = lc($site_id || '');
    die "unsafe site id: $site_id\n" unless $site_id =~ /\A[a-z0-9][a-z0-9-]{1,62}\z/;
    return $site_id;
}

sub clean_display_name {
    my ($name) = @_;
    $name = '' unless defined $name;
    $name =~ s/[\r\n\t]+/ /g;
    $name =~ s/^\s+|\s+$//g;
    return substr($name || 'Contributor Site', 0, 120);
}

sub decode_details {
    my ($json) = @_;
    return {} unless defined $json && length $json;
    my $decoded = eval { decode_json($json) };
    return ref $decoded eq 'HASH' ? $decoded : {};
}

sub domain_from_url {
    my ($url) = @_;
    return $1 if defined $url && $url =~ m{\Ahttps?://([^/:/]+)}i;
    return '';
}

sub dedicated_shop_domain_from_config {
    my ($config, $primary_domain) = @_;
    my $domain = $config->get('shop_domain') || '';
    if (length $domain) {
        $domain = safe_site_domain($domain);
        return $domain eq $primary_domain ? '' : $domain;
    }

    my $url = $config->get('shop_url') || '';
    return '' unless $url =~ m{\Ahttps?://([^/:/]+)(?::[0-9]+)?(/[^?#]*)?}i;
    my ($host, $path) = (lc($1), $2 || '');
    $path =~ s{/+\z}{};
    return '' if length $path;
    return $host eq $primary_domain ? '' : $host;
}

sub timestamp {
    my @t = localtime(now());
    return sprintf '%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900,
        $t[4] + 1,
        $t[3],
        $t[2],
        $t[1],
        $t[0];
}

sub shell_quote {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/'/'\\''/g;
    return "'$value'";
}

sub html {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

sub log_msg {
    my ($message) = @_;
    return if $opt{quiet};
    print "$message\n";
}

sub usage {
    return <<"USAGE";
usage: $0 [--config /etc/desertcms.conf] [--shop-domain shop.example.com] [--old-domain legacy.example.com] [--quiet] [--dry-run] [--sync-config] [--install-cron]

--old-domain is optional and only for explicitly preserving an older hostname as a redirect to the primary domain.
USAGE
}
