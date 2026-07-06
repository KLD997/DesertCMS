package DesertCMS::SecurityCenter;

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use DesertCMS::ModuleManifest ();
use DesertCMS::Realtime ();
use DesertCMS::Security qw(security_headers);
use DesertCMS::Settings ();
use DesertCMS::Util qw(now);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config         => $args{config},
        db             => $args{db},
        command_runner => $args{command_runner},
    }, $class;
}

sub run_checks {
    my ($self, %args) = @_;
    my @checks = (
        $self->_platform_check,
        $self->_dns_check,
        $self->_tls_check,
        $self->_command_check('pf', 'pfctl', '/sbin/pfctl', 'OpenBSD packet filter control must be present.'),
        $self->_command_check('httpd', 'httpd', '/usr/sbin/httpd', 'OpenBSD httpd must be present.'),
        $self->_command_check('slowcgi', 'slowcgi', '/usr/sbin/slowcgi', 'slowcgi is required for CGI deployment.'),
        $self->_command_check('acme_client', 'acme-client', '/usr/sbin/acme-client', 'acme-client must be present for TLS renewal.'),
        $self->_command_check('syspatch', 'syspatch', '/usr/sbin/syspatch', 'syspatch -c is used for base system patch visibility.'),
        $self->_command_check('pkg_add', 'pkg_add', '/usr/sbin/pkg_add', 'pkg_add -n -u is used for package update visibility.'),
        $self->_command_check('pkg_info', 'pkg_info', '/usr/sbin/pkg_info', 'pkg_info feeds package inventory and CVE matching.'),
        $self->_path_check('public_root', $self->{config}->get('public_root'), 'Public root should exist and stay under /var/www for httpd chroot compatibility.'),
        $self->_path_check('db_path', $self->{config}->get('db_path'), 'SQLite database path should be inside the DesertCMS data directory.'),
        $self->_path_check('originals_dir', $self->{config}->get('originals_dir'), 'Private source media should be outside the public root.'),
        $self->_path_check('backup_dir', $self->{config}->get('backup_dir'), 'Backups should be writable by the maintenance worker and outside public root.'),
        $self->_headers_check,
        $self->_file_permissions_check,
        $self->_worker_health_check,
        $self->_backups_check,
        $self->_tenant_check,
        $self->_package_update_check,
        $self->_cve_matching_check,
        $self->_provider_webhooks_check,
        $self->_realtime_origin_filter_check,
        $self->_streaming_ports_check,
        $self->_read_only_mode_check($args{allow_mutation}),
    );
    return \@checks;
}

sub queue_fix {
    my ($self, %args) = @_;
    my $check_key = _clean_key($args{check_key});
    my $action = _clean_key($args{action} || $check_key);
    die "security check key is required" unless length $check_key;
    die "security action is required" unless length $action;
    my $details = ref($args{details}) ? $args{details} : {};
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO security_remediation_queue
                (check_key, action, status, approved_by_user_id, details_json, created_at, updated_at)
            VALUES (?, ?, 'queued', ?, ?, ?, ?)
        },
        undef,
        $check_key,
        $action,
        _maybe_int($args{approved_by_user_id}),
        encode_json($details),
        $ts,
        $ts
    );
    my $id = $self->{db}->dbh->last_insert_id('', '', 'security_remediation_queue', '');
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM security_remediation_queue WHERE id = ?',
        undef,
        int($id)
    );
}

sub manifest_checks {
    my ($self) = @_;
    my %checks = map { $_ => 1 } @{ DesertCMS::ModuleManifest::security_checks(config => $self->{config}) };
    return [ sort keys %checks ];
}

sub _platform_check {
    return {
        key        => 'openbsd_base',
        label      => 'OpenBSD Base',
        status     => $^O eq 'openbsd' ? 'ok' : 'warning',
        detail     => $^O eq 'openbsd'
            ? 'Running on OpenBSD.'
            : "Running on $^O; OpenBSD-only checks are reported without mutating the host.",
        fix_action => '',
    };
}

sub _dns_check {
    my ($self) = @_;
    my ($scheme, $host) = $self->_site_endpoint;
    my $root = $self->{config}->get('contributor_domain_root') || '';
    my @targets = grep { length } ($host, $root);
    my $has_public_host = grep { _is_public_hostname($_) } @targets;
    return {
        key        => 'dns',
        label      => 'DNS',
        status     => $has_public_host ? 'ok' : 'warning',
        detail     => $has_public_host
            ? 'Public host configuration is present; active DNS resolution stays read-only and can be delegated to the OpenBSD worker.'
            : 'Configure site_url or contributor_domain_root with a public host before launch.',
        fix_action => $has_public_host ? '' : 'review_dns_records',
    };
}

sub _tls_check {
    my ($self) = @_;
    my ($scheme, $host) = $self->_site_endpoint;
    my $https = ($scheme || '') eq 'https';
    my $acme = _command_available('acme-client', '/usr/sbin/acme-client');
    my $status = $https && ($acme || $^O ne 'openbsd') ? 'ok' : 'warning';
    my $detail = $https
        ? ($acme ? 'site_url uses HTTPS and acme-client is available.' : 'site_url uses HTTPS; acme-client verification is deferred outside OpenBSD local development.')
        : 'site_url should use HTTPS and renew through acme-client before launch.';
    return {
        key        => 'tls',
        label      => 'TLS',
        status     => $status,
        detail     => length($host) ? $detail : 'No site host is configured for TLS validation.',
        fix_action => $status eq 'ok' ? '' : 'review_acme_client',
    };
}

sub _command_check {
    my ($self, $key, $command, $openbsd_path, $detail) = @_;
    my $found = _command_available($command, $openbsd_path);
    my $status = $found ? 'ok' : ($^O eq 'openbsd' ? 'critical' : 'warning');
    return {
        key        => $key,
        label      => $command,
        status     => $status,
        detail     => $found ? "$command is available." : $detail,
        fix_action => $found ? '' : 'install_or_enable_' . $key,
    };
}

sub _path_check {
    my ($self, $key, $path, $detail) = @_;
    $path ||= '';
    my $exists = length($path) && (-e $path || $path =~ m{\A/var/});
    my $public_root = $self->{config}->get('public_root') || '';
    my $outside_public = 1;
    if (($key eq 'db_path' || $key eq 'originals_dir' || $key eq 'backup_dir') && length($public_root) && length($path)) {
        $outside_public = index($path, $public_root) == 0 ? 0 : 1;
    }
    my $ok = $exists && $outside_public;
    return {
        key        => $key,
        label      => $key,
        status     => $ok ? 'ok' : 'warning',
        detail     => $ok ? "$key is configured as $path." : $detail,
        fix_action => $ok ? '' : 'review_' . $key,
    };
}

sub _file_permissions_check {
    my ($self) = @_;
    my $public_root = $self->{config}->get('public_root') || '';
    my @private_keys = qw(db_path originals_dir backup_dir data_dir);
    my @issues;
    for my $key (@private_keys) {
        my $path = $self->{config}->get($key) || '';
        next unless length $path;
        push @issues, "$key is inside public_root" if _path_under($path, $public_root);
    }
    for my $key (qw(db_path originals_dir backup_dir)) {
        my $path = $self->{config}->get($key) || '';
        next unless length $path;
        next if $path =~ m{\A/var/} || -e $path;
        push @issues, "$key is missing locally";
    }
    return {
        key        => 'file_permissions',
        label      => 'File Permissions',
        status     => @issues ? 'warning' : 'ok',
        detail     => @issues
            ? join('; ', @issues) . '. Private data must stay outside httpd public roots.'
            : 'Private database, originals, data, and backup paths are not under the configured public root.',
        fix_action => @issues ? 'review_file_permissions' : '',
    };
}

sub _worker_health_check {
    my ($self) = @_;
    my $failed_provisioning = $self->_count_where('site_provisioning_queue', "status = 'failed'");
    my $failed_security = $self->_count_where('security_remediation_queue', "status = 'failed'");
    my $running_security = $self->_count_where('security_remediation_queue', "status = 'running'");
    my $queued_security = $self->_count_where('security_remediation_queue', "status = 'queued'");
    my @issues;
    push @issues, "$failed_provisioning failed provisioning job(s)" if $failed_provisioning;
    push @issues, "$failed_security failed security remediation job(s)" if $failed_security;
    my $detail = @issues
        ? join('; ', @issues)
        : "$queued_security queued and $running_security running security remediation job(s).";
    return {
        key        => 'worker_health',
        label      => 'Worker Health',
        status     => @issues ? 'critical' : 'ok',
        detail     => $detail,
        fix_action => @issues ? 'review_root_worker' : '',
    };
}

sub _backups_check {
    my ($self) = @_;
    my $db_count = $self->_count_where('backups', '1 = 1');
    my ($file_count, $latest) = $self->_backup_archive_state;
    my $count = $db_count || $file_count;
    return {
        key        => 'backups',
        label      => 'Backups',
        status     => $count ? 'ok' : 'warning',
        detail     => $count
            ? "$count backup record(s) or archive(s) found" . ($latest ? ' in the configured backup directory.' : '.')
            : 'No backups were found in the database or configured backup directory.',
        fix_action => $count ? '' : 'create_backup',
    };
}

sub _headers_check {
    my %headers = security_headers();
    my @required = qw(Content-Security-Policy X-Content-Type-Options Referrer-Policy Permissions-Policy);
    my @missing = grep { !length($headers{$_} || '') } @required;
    return {
        key        => 'security_headers',
        label      => 'Security Headers',
        status     => @missing ? 'critical' : 'ok',
        detail     => @missing ? 'Missing: ' . join(', ', @missing) : 'CSP and baseline security headers are configured.',
        fix_action => @missing ? 'repair_security_headers' : '',
    };
}

sub _tenant_check {
    my ($self) = @_;
    my $site_id = $self->{config}->get('contributor_site_id') || '';
    my $master = $self->{config}->get('master_config_path') || '';
    return {
        key        => 'tenant_isolation',
        label      => 'Tenant Isolation',
        status     => length($site_id) || length($master) ? 'ok' : 'warning',
        detail     => length($site_id)
            ? 'Contributor instance has an explicit tenant id.'
            : 'Master instance should keep contributor data paths explicit before provisioning.',
        fix_action => length($site_id) || length($master) ? '' : 'review_tenant_paths',
    };
}

sub _package_update_check {
    my ($self) = @_;
    my $syspatch = $self->_readonly_command('syspatch_check', 'syspatch', '-c');
    my $pkg_add = $self->_readonly_command('pkg_add_update_check', 'pkg_add', '-n', '-u');
    my @base_updates = _command_lines($syspatch->{output});
    my @package_updates = _command_lines($pkg_add->{output});
    my $commands_ready = $syspatch->{available} && $pkg_add->{available};
    my $command_failed = ($syspatch->{ran} && int($syspatch->{exit} || 0) != 0)
        || ($pkg_add->{ran} && int($pkg_add->{exit} || 0) != 0);
    my $has_updates = @base_updates || @package_updates;
    my $status = !$commands_ready
        ? ($^O eq 'openbsd' ? 'critical' : 'warning')
        : ($command_failed || $has_updates ? 'warning' : 'ok');
    my $detail = !$commands_ready
        ? 'Security Center expects syspatch -c and pkg_add -n -u on the deployed OpenBSD host.'
        : ($command_failed
            ? 'One or more read-only package visibility commands returned a non-zero exit status.'
            : ($has_updates
                ? scalar(@base_updates) . ' base syspatch candidate(s) and ' . scalar(@package_updates) . ' package update line(s) were reported.'
                : 'No base syspatch candidates or package update dry-run output were reported.'));
    return {
        key        => 'package_updates',
        label      => 'Package Updates',
        status     => $status,
        detail     => $detail,
        fix_action => $status eq 'ok' ? '' : 'review_openbsd_package_updates',
        details    => {
            syspatch_command     => $syspatch->{command},
            pkg_add_command      => $pkg_add->{command},
            syspatch_lines       => [ _limited_list(@base_updates) ],
            package_update_lines => [ _limited_list(@package_updates) ],
            syspatch_error       => $syspatch->{error} || '',
            pkg_add_error        => $pkg_add->{error} || '',
        },
    };
}

sub _cve_matching_check {
    my ($self) = @_;
    my $pkg_info = $self->_readonly_command('pkg_info_inventory', 'pkg_info', '-q');
    my $feed = $self->{config}->get('security_cve_feed_path') || '';
    my $feed_ready = length($feed) && (-e $feed || $feed =~ m{\A/var/});
    my @packages = _package_inventory($pkg_info->{output});
    my @matches = $feed_ready && @packages ? _cve_matches($feed, \@packages) : ();
    my $status = (!$pkg_info->{available} || !$feed_ready)
        ? 'warning'
        : (@matches ? 'critical' : 'ok');
    my $detail = !$pkg_info->{available}
        ? 'CVE matching needs pkg_info inventory plus a configured local advisory/feed source.'
        : (!$feed_ready
            ? 'CVE matching needs a configured local advisory/feed source.'
            : (@matches
                ? scalar(@matches) . ' installed package CVE advisory match(es) were found.'
                : 'Package inventory and local CVE feed were checked with no advisory matches.'));
    return {
        key        => 'cve_matching',
        label      => 'CVE Matching',
        status     => $status,
        detail     => $detail,
        fix_action => $status eq 'ok' ? '' : 'configure_cve_matching',
        details    => {
            pkg_info_command => $pkg_info->{command},
            package_count    => scalar(@packages),
            feed_path        => $feed,
            matches          => [ _limited_list(map { $_->{summary} } @matches) ],
            pkg_info_error   => $pkg_info->{error} || '',
        },
    };
}

sub _provider_webhooks_check {
    my ($self) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my @issues;
    my $postmark_enabled = _truthy($settings->{forms_notify_postmark_enabled})
        || _truthy($settings->{events_notify_postmark_enabled})
        || _truthy($settings->{bookings_notify_postmark_enabled})
        || _truthy($settings->{membership_notify_postmark_enabled});
    push @issues, 'Postmark webhook token is missing'
        if $postmark_enabled && !length($settings->{postmark_webhook_token} || $self->{config}->get('postmark_webhook_token') || '');
    my $stripe_key = $settings->{stripe_secret_key} || $self->{config}->get('stripe_secret_key') || '';
    push @issues, 'Stripe webhook secret is missing'
        if length($stripe_key) && !length($settings->{stripe_webhook_secret} || $self->{config}->get('stripe_webhook_secret') || '');
    return {
        key        => 'provider_webhooks',
        label      => 'Provider Webhooks',
        status     => @issues ? 'warning' : 'ok',
        detail     => @issues
            ? join('; ', @issues) . '.'
            : 'Configured provider webhook secrets are present for enabled provider integrations.',
        fix_action => @issues ? 'review_provider_webhooks' : '',
    };
}

sub _realtime_origin_filter_check {
    my ($self) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $enabled = _truthy($settings->{realtime_enabled});
    my $raw = $settings->{realtime_allowed_origins} || $self->{config}->get('realtime_allowed_origins') || '';
    my @issues;
    my $normalized = eval { DesertCMS::Realtime->normalize_allowed_origins($raw) };
    push @issues, 'Realtime allowed origins contain invalid entries' if $@;
    my $bind_host = $settings->{realtime_bind_host} || $self->{config}->get('realtime_bind_host') || '127.0.0.1';
    if ($enabled && !_loopback_host($bind_host) && !length($normalized || '')) {
        push @issues, 'Non-loopback realtime bind should declare explicit allowed origins';
    }
    my $origin_config = {
        site_url                 => $self->{config}->get('site_url') || '',
        realtime_enabled         => $enabled,
        realtime_bind_host       => $bind_host,
        realtime_port            => $settings->{realtime_port} || $self->{config}->get('realtime_port') || 8787,
        realtime_allowed_origins => $raw,
    };
    my $origins = DesertCMS::Realtime->allowed_origins($origin_config);
    return {
        key        => 'realtime_origin_filter',
        label      => 'Realtime Origin Filter',
        status     => @issues ? 'warning' : 'ok',
        detail     => @issues
            ? join('; ', @issues) . '.'
            : ($enabled
                ? 'Realtime SSE/WebSocket browser origins are restricted to configured site and allowed-origin values.'
                : 'Realtime is disabled; browser origin policy is ready before activation.'),
        fix_action => @issues ? 'review_realtime_origins' : '',
        details    => {
            enabled           => $enabled ? 1 : 0,
            bind_host         => $bind_host,
            effective_origins => $origins,
        },
    };
}

sub _streaming_ports_check {
    my ($self) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $enabled = _truthy($settings->{module_live_streaming_enabled});
    my $pf = _command_available('pfctl', '/sbin/pfctl');
    my $worker_events = $self->_streaming_worker_event_state(
        window_seconds => $settings->{live_worker_event_window_seconds}
            || $self->{config}->get('live_worker_event_window_seconds')
            || 900
    );
    my @issues;
    push @issues, 'pfctl is not available for streaming port validation' if $enabled && !$pf;
    push @issues, 'worker event telemetry is unavailable' if $enabled && !$worker_events->{available};
    push @issues, "$worker_events->{auth_rejected} rejected worker auth attempt(s)" if $enabled && $worker_events->{auth_rejected};
    push @issues, "$worker_events->{unhealthy_events} unhealthy worker event(s)" if $enabled && $worker_events->{unhealthy_events};
    my $status = 'ok';
    if (@issues) {
        $status = ($worker_events->{unhealthy_events} || ($enabled && !$pf && $^O eq 'openbsd')) ? 'critical' : 'warning';
    }
    my $worker_event_issue = !$worker_events->{available} || $worker_events->{auth_rejected} || $worker_events->{unhealthy_events};
    my $fix_action = @issues ? ($worker_event_issue ? 'review_streaming_worker_events' : 'review_streaming_pf_rules') : '';
    my @detail = ($enabled
        ? 'Live Streaming is enabled; OBS ingest, HLS output, and chat presence ports must be represented in pf rules.'
        : 'Live Streaming is disabled; pf streaming ports stay inactive until the module is enabled.'
    );
    push @detail, @issues if @issues;
    push @detail, "latest worker event: $worker_events->{latest_event_type}/$worker_events->{latest_status}"
        if $enabled && $worker_events->{latest_event_id};
    return {
        key        => 'streaming_ports',
        label      => 'Streaming Ports',
        status     => $status,
        detail     => join(' ', @detail),
        fix_action => $fix_action,
        details    => {
            enabled       => $enabled ? 1 : 0,
            pf_available  => $pf ? 1 : 0,
            worker_events => $worker_events,
        },
    };
}

sub _streaming_worker_event_state {
    my ($self, %args) = @_;
    my $window = $args{window_seconds};
    $window = 900 unless defined($window) && "$window" =~ /\A[0-9]+\z/ && int($window) > 0;
    $window = int($window);
    my $cutoff = now() - $window;
    my %state = (
        available        => 0,
        window_seconds   => $window,
        cutoff           => $cutoff,
        total_events     => 0,
        auth_authorized  => 0,
        auth_rejected    => 0,
        heartbeat_events => 0,
        unhealthy_events => 0,
        latest_event_id  => 0,
        latest_event_at  => 0,
        latest_event_type => '',
        latest_status    => '',
        latest_worker_id => '',
        error            => '',
    );
    return \%state unless $self->_table_exists('live_stream_worker_events');
    my $dbh = $self->{db}->dbh;
    my $row = eval {
        $dbh->selectrow_hashref(
            q{
                SELECT
                    COUNT(*) AS total_events,
                    COALESCE(SUM(CASE WHEN event_type = 'auth' AND status = 'authorized' THEN 1 ELSE 0 END), 0) AS auth_authorized,
                    COALESCE(SUM(CASE WHEN event_type = 'auth' AND status = 'rejected' THEN 1 ELSE 0 END), 0) AS auth_rejected,
                    COALESCE(SUM(CASE WHEN event_type = 'heartbeat' THEN 1 ELSE 0 END), 0) AS heartbeat_events,
                    COALESCE(SUM(CASE WHEN LOWER(status) IN ('failed', 'error', 'unhealthy') THEN 1 ELSE 0 END), 0) AS unhealthy_events,
                    COALESCE(MAX(created_at), 0) AS latest_event_at
                FROM live_stream_worker_events
                WHERE created_at >= ?
            },
            undef,
            $cutoff
        );
    };
    if ($@) {
        $state{error} = _clean_text($@, 300);
        return \%state;
    }
    for my $key (qw(total_events auth_authorized auth_rejected heartbeat_events unhealthy_events latest_event_at)) {
        $state{$key} = int(($row && defined $row->{$key}) ? $row->{$key} : 0);
    }
    my $latest = eval {
        $dbh->selectrow_hashref(
            q{
                SELECT id, event_type, status, worker_id, created_at
                FROM live_stream_worker_events
                WHERE created_at >= ?
                ORDER BY created_at DESC, id DESC
                LIMIT 1
            },
            undef,
            $cutoff
        );
    };
    if ($@) {
        $state{error} = _clean_text($@, 300);
        return \%state;
    }
    $state{available} = 1;
    if ($latest) {
        $state{latest_event_id} = int($latest->{id} || 0);
        $state{latest_event_type} = $latest->{event_type} || '';
        $state{latest_status} = $latest->{status} || '';
        $state{latest_worker_id} = $latest->{worker_id} || '';
        $state{latest_event_at} = int($latest->{created_at} || $state{latest_event_at} || 0);
    }
    return \%state;
}

sub _read_only_mode_check {
    my ($self, $allow_mutation) = @_;
    return {
        key        => 'read_only_default',
        label      => 'Read-only Checks',
        status     => $allow_mutation ? 'warning' : 'ok',
        detail     => $allow_mutation
            ? 'Mutation was requested; fixes must still be queued through the root worker after approval.'
            : 'Security Center checks run read-only by default.',
        fix_action => '',
    };
}

sub _command_available {
    my ($command, $openbsd_path) = @_;
    return 1 if length($openbsd_path || '') && -x $openbsd_path;
    for my $dir (split /;/, $ENV{PATH} || '') {
        next unless length $dir;
        return 1 if -x "$dir/$command" || -x "$dir/$command.exe";
    }
    for my $dir (split /:/, $ENV{PATH} || '') {
        next unless length $dir;
        return 1 if -x "$dir/$command";
    }
    return 0;
}

sub _readonly_command {
    my ($self, $key, @command) = @_;
    my $command = $command[0] || '';
    my $resolved = _resolved_command_path($command);
    my $available = length($resolved) ? 1 : 0;
    my $command_label = join ' ', @command;

    if (ref($self->{command_runner}) eq 'CODE') {
        my $result = eval { $self->{command_runner}->($key, @command) };
        return _normalize_command_result(
            $result,
            command   => $command_label,
            available => $@ ? 0 : 1,
            error     => $@ || '',
            ran       => $@ ? 0 : 1,
        );
    }

    return {
        command   => $command_label,
        available => $available,
        ran       => 0,
        exit      => undef,
        output    => '',
        error     => $available ? 'deferred outside OpenBSD' : 'command unavailable',
    } unless $^O eq 'openbsd';

    return {
        command   => $command_label,
        available => 0,
        ran       => 0,
        exit      => undef,
        output    => '',
        error     => 'command unavailable',
    } unless $available;

    my @argv = ($resolved, @command[1 .. $#command]);
    my $output = '';
    my $ok = eval {
        open my $fh, '-|', @argv or die "cannot run $command: $!";
        local $/;
        $output = <$fh> || '';
        close $fh;
        1;
    };
    my $exit = $? == -1 ? 127 : ($? >> 8);
    return {
        command   => $command_label,
        available => 1,
        ran       => 1,
        exit      => $ok ? $exit : 127,
        output    => _clean_text($output, 8000),
        error     => $ok ? '' : _clean_text($@ || 'command failed', 500),
    };
}

sub _normalize_command_result {
    my ($result, %defaults) = @_;
    if (ref($result) eq 'HASH') {
        return {
            command   => $result->{command} || $defaults{command} || '',
            available => exists($result->{available}) ? ($result->{available} ? 1 : 0) : ($defaults{available} ? 1 : 0),
            ran       => exists($result->{ran}) ? ($result->{ran} ? 1 : 0) : ($defaults{ran} ? 1 : 0),
            exit      => defined($result->{exit}) ? int($result->{exit}) : 0,
            output    => _clean_text($result->{output}, 8000),
            error     => _clean_text($result->{error} || $defaults{error}, 500),
        };
    }
    return {
        command   => $defaults{command} || '',
        available => $defaults{available} ? 1 : 0,
        ran       => $defaults{ran} ? 1 : 0,
        exit      => 0,
        output    => _clean_text($result, 8000),
        error     => _clean_text($defaults{error}, 500),
    };
}

sub _resolved_command_path {
    my ($command) = @_;
    my %openbsd_path = (
        syspatch => '/usr/sbin/syspatch',
        pkg_add  => '/usr/sbin/pkg_add',
        pkg_info => '/usr/sbin/pkg_info',
        pfctl    => '/sbin/pfctl',
        httpd    => '/usr/sbin/httpd',
        slowcgi  => '/usr/sbin/slowcgi',
        'acme-client' => '/usr/sbin/acme-client',
    );
    my $path = $openbsd_path{$command} || '';
    return $path if length($path) && -x $path;
    for my $dir (split /;/, $ENV{PATH} || '') {
        next unless length $dir;
        return "$dir/$command.exe" if -x "$dir/$command.exe";
        return "$dir/$command" if -x "$dir/$command";
    }
    for my $dir (split /:/, $ENV{PATH} || '') {
        next unless length $dir;
        return "$dir/$command" if -x "$dir/$command";
    }
    return '';
}

sub _command_lines {
    my ($output) = @_;
    my @lines;
    for my $line (split /\r?\n/, $output || '') {
        $line =~ s/^\s+|\s+\z//g;
        next unless length $line;
        push @lines, _clean_text($line, 500);
    }
    return @lines;
}

sub _package_inventory {
    my ($output) = @_;
    my @packages;
    my %seen;
    for my $line (_command_lines($output)) {
        my ($full) = split /\s+/, $line, 2;
        next unless length($full || '');
        my $name = lc $full;
        $name =~ s/-[0-9][^-]*\z//;
        $name = lc $full if !length $name;
        my $key = lc $full;
        next if $seen{$key}++;
        push @packages, { full => $full, name => $name };
    }
    return @packages;
}

sub _cve_matches {
    my ($feed, $packages) = @_;
    my $items = _read_cve_feed($feed);
    my %installed;
    for my $pkg (@{$packages || []}) {
        $installed{lc($pkg->{full} || '')} = $pkg;
        $installed{lc($pkg->{name} || '')} ||= $pkg;
    }
    my @matches;
    for my $item (@{$items}) {
        next unless ref($item) eq 'HASH';
        my $package = lc($item->{package} || $item->{name} || '');
        my @affected = _array_values($item->{affected}, $item->{affected_versions}, $item->{packages});
        my $matched;
        if (length($package) && $installed{$package}) {
            $matched = $installed{$package};
        }
        for my $affected (@affected) {
            my $key = lc($affected || '');
            if ($installed{$key}) {
                $matched = $installed{$key};
                last;
            }
        }
        next unless $matched;
        my $id = _clean_text($item->{cve} || $item->{cve_id} || $item->{id} || 'CVE advisory', 80);
        my $summary = _clean_text($id . ' affects ' . ($matched->{full} || $matched->{name}), 200);
        push @matches, {
            id      => $id,
            package => $matched->{full} || $matched->{name},
            summary => $summary,
        };
    }
    return @matches;
}

sub _read_cve_feed {
    my ($feed) = @_;
    return [] unless length($feed || '') && -e $feed;
    open my $fh, '<', $feed or return [];
    local $/;
    my $body = <$fh> || '';
    close $fh;
    my $decoded = eval { decode_json($body) };
    return [] unless $decoded;
    return $decoded if ref($decoded) eq 'ARRAY';
    for my $key (qw(advisories vulnerabilities cves items)) {
        return $decoded->{$key} if ref($decoded) eq 'HASH' && ref($decoded->{$key}) eq 'ARRAY';
    }
    return [];
}

sub _array_values {
    my @values;
    for my $value (@_) {
        if (ref($value) eq 'ARRAY') {
            push @values, @{$value};
        } elsif (defined $value && length $value) {
            push @values, $value;
        }
    }
    return @values;
}

sub _limited_list {
    my @items = @_;
    splice @items, 10 if @items > 10;
    return @items;
}

sub _site_endpoint {
    my ($self) = @_;
    my $url = $self->{config}->get('site_url') || '';
    $url =~ s/^\s+|\s+\z//g;
    if ($url =~ m{\A(https?)://([^/:?#]+)}i) {
        return (lc($1), lc($2));
    }
    if ($url =~ m{\A([^/:?#]+\.[^/:?#]+)}i) {
        return ('', lc($1));
    }
    return ('', '');
}

sub _is_public_hostname {
    my ($host) = @_;
    $host = lc($host || '');
    $host =~ s/^\.+|\.+\z//g;
    return 0 unless $host =~ /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/;
    return 0 if $host =~ /\A(?:localhost|127\.|10\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[0-1])\.)/;
    return 1;
}

sub _path_under {
    my ($path, $root) = @_;
    $path = _slash_path($path);
    $root = _slash_path($root);
    return 0 unless length($path) && length($root);
    $root =~ s{/+\z}{};
    return 0 unless length $root;
    return $path eq $root || index($path, "$root/") == 0 ? 1 : 0;
}

sub _slash_path {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s{\\}{/}g;
    return $value;
}

sub _table_exists {
    my ($self, $table) = @_;
    my ($exists) = eval {
        $self->{db}->dbh->selectrow_array(
            q{SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?},
            undef,
            $table
        );
    };
    return $exists ? 1 : 0;
}

sub _count_where {
    my ($self, $table, $where) = @_;
    return 0 unless _clean_sql_identifier($table) && $self->_table_exists($table);
    $where ||= '1 = 1';
    return 0 unless $where =~ /\A[-_ a-zA-Z0-9='".()]+\z/;
    my ($count) = $self->{db}->dbh->selectrow_array("SELECT COUNT(*) FROM $table WHERE $where");
    return int($count || 0);
}

sub _backup_archive_state {
    my ($self) = @_;
    my $dir = $self->{config}->get('backup_dir') || '';
    return (0, 0) unless length($dir) && -d $dir;
    my ($count, $latest) = (0, 0);
    if (opendir my $dh, $dir) {
        while (defined(my $entry = readdir $dh)) {
            next unless $entry =~ /\Adesertcms-.*\.tar\.gz\z/;
            my $path = "$dir/$entry";
            next unless -f $path;
            $count++;
            my $mtime = (stat $path)[9] || 0;
            $latest = $mtime if $mtime > $latest;
        }
        closedir $dh;
    }
    return ($count, $latest);
}

sub _clean_sql_identifier {
    my ($value) = @_;
    return defined($value) && $value =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/ ? 1 : 0;
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _loopback_host {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    $value =~ s/:\d+\z//;
    return 1 if $value eq '127.0.0.1' || lc($value) eq 'localhost' || $value eq '::1' || $value eq '[::1]';
    return 0;
}

sub _clean_text {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\r\n\t]+/ /g;
    $value =~ s/^\s+|\s+\z//g;
    $max ||= 500;
    return substr($value, 0, $max);
}

sub _clean_key {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value = lc $value;
    $value =~ s/[^a-z0-9_.:-]+/_/g;
    return substr($value, 0, 120);
}

sub _maybe_int {
    my ($value) = @_;
    return undef unless defined $value && "$value" =~ /\A[0-9]+\z/;
    return int($value);
}

1;
