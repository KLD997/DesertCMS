package DesertCMS::Operations;

use strict;
use warnings;
use Digest::SHA ();
use File::Basename qw(basename dirname);
use File::Path qw(make_path remove_tree);
use File::Spec;
use HTTP::Tiny;
use JSON::PP qw(encode_json);
use DesertCMS::Backup;
use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::SEO;
use DesertCMS::Settings;
use DesertCMS::Upgrade;
use DesertCMS::Util qw(now);
use DesertCMS::Version;

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
        sites  => $args{sites},
    }, $class;
}

sub managed_sites {
    my ($self, %args) = @_;
    my @sites = ({
        kind        => 'master',
        site_id     => 'master',
        label       => $self->{config}->get('site_name') || 'Master CMS',
        domain      => _domain_from_url($self->{config}->get('site_url')),
        status      => 'active',
        config_path => $self->{config}->get('path') || $ENV{DESERTCMS_CONFIG} || '',
        data_dir    => $self->{config}->get('data_dir') || '',
        public_root => $self->{config}->get('public_root') || '',
    });

    my $rows = $self->{sites} ? $self->{sites}->list_sites : [];
    for my $row (@{$rows}) {
        my $status = $row->{status} || '';
        next if !$args{include_destroyed} && ($status eq 'destroyed' || $status eq 'destroy_pending');
        push @sites, {
            kind        => 'contributor',
            site_id     => $row->{site_id} || '',
            label       => $row->{display_name} || $row->{domain} || $row->{site_id} || 'Contributor site',
            domain      => $row->{domain} || '',
            status      => $status || 'unknown',
            config_path => $row->{config_path} || '',
            data_dir    => $row->{data_dir} || '',
            public_root => $row->{public_root} || '',
        };
    }
    return \@sites;
}

sub health_report {
    my ($self, %args) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $fleet = $self->{sites}
        ? eval { $self->{sites}->fleet_status(check_dns => 0, check_tls => 0, app_version => DesertCMS::Version::current()) }
        : undef;
    $fleet ||= { total => 0, active => 0, alerts => 0, queue_open => 0, queue_failed => 0, sites => [] };
    my $backups = eval { DesertCMS::Backup::list_backups($self->{config}, $self->{db}) } || [];
    my $latest_backup = @{$backups} ? $backups->[0] : undef;
    my $bundle_count = scalar @{ $self->support_bundles };

    return {
        generated_at => now(),
        version      => DesertCMS::Version::current(),
        master       => {
            site_url    => $self->{config}->get('site_url') || '',
            config_path => $self->{config}->get('path') || $ENV{DESERTCMS_CONFIG} || '',
            data_dir    => $self->{config}->get('data_dir') || '',
            public_root => $self->{config}->get('public_root') || '',
            db_path     => $self->{config}->get('db_path') || '',
            backup_dir  => $self->{config}->get('backup_dir') || '',
        },
        backup_schedule => {
            enabled        => _truthy($settings->{operations_backup_schedule_enabled}),
            interval_hours => int($settings->{operations_backup_interval_hours} || 24),
            last_run_at    => int($settings->{operations_backup_last_run_at} || 0),
        },
        offsite_hook => {
            configured => length($settings->{operations_offsite_hook_url} || '') ? 1 : 0,
        },
        upgrade_channel => $settings->{operations_upgrade_channel} || 'stable',
        latest_backup   => $latest_backup,
        support_bundles => $bundle_count,
        fleet           => $fleet,
        upgrade_jobs    => DesertCMS::Upgrade::latest_jobs($self->{config}, limit => 5),
    };
}

sub rebuild_all_sites {
    my ($self) = @_;
    my @results;
    for my $site (@{ $self->managed_sites }) {
        next if $site->{kind} eq 'contributor' && ($site->{status} || '') ne 'active';
        push @results, $self->_run_site_operation($site, sub {
            my ($config, $db) = @_;
            my $content = DesertCMS::Content->new(config => $config, db => $db);
            my $count = $content->rebuild_all;
            return { rebuilt => int($count || 0) };
        });
    }
    return _summary(\@results);
}

sub backup_all_sites {
    my ($self, %args) = @_;
    my @results;
    for my $site (@{ $self->managed_sites }) {
        push @results, $self->_run_site_operation($site, sub {
            my ($config, $db) = @_;
            my $archive = DesertCMS::Backup::create_backup($config, $db, $args{user_id});
            my $hook = $self->_send_offsite_hook($site, $archive);
            return {
                archive => $archive,
                offsite => $hook,
            };
        });
    }
    DesertCMS::Settings::set_many($self->{config}, $self->{db}, {
        operations_backup_last_run_at => now(),
    }) if @results;
    return _summary(\@results);
}

sub submit_all_sitemaps {
    my ($self) = @_;
    my @results;
    for my $site (@{ $self->managed_sites }) {
        next if $site->{kind} eq 'contributor' && ($site->{status} || '') ne 'active';
        push @results, $self->_run_site_operation($site, sub {
            my ($config, $db) = @_;
            my $settings = DesertCMS::Settings::all($config, $db);
            my @engines;
            if (DesertCMS::SEO::google_connected($settings)) {
                my $google = DesertCMS::SEO::submit_google_sitemap($config, $db);
                push @engines, { engine => $google->{engine}, status => 'submitted', sitemap => $google->{sitemap} };
            } else {
                push @engines, { engine => 'Google Search Console', status => 'skipped', message => 'not connected' };
            }
            if (_truthy($settings->{indexnow_enabled})) {
                my $indexnow = DesertCMS::SEO::submit_indexnow($config, $db);
                push @engines, { engine => $indexnow->{engine}, status => 'submitted', urls => $indexnow->{urls} };
            } else {
                push @engines, { engine => 'IndexNow', status => 'skipped', message => 'disabled' };
            }
            return { engines => \@engines };
        });
    }
    return _summary(\@results);
}

sub test_restore {
    my ($self, %args) = @_;
    my $archive;
    if ($args{backup_id}) {
        $archive = DesertCMS::Backup::archive_for_id($self->{config}, $self->{db}, int($args{backup_id}));
        die "backup archive was not found" unless $archive;
    } else {
        $archive = $args{archive};
    }
    return DesertCMS::Backup::test_backup($self->{config}, $archive);
}

sub create_support_bundle {
    my ($self, %args) = @_;
    my $support_dir = $self->support_bundle_dir;
    make_path($support_dir, { mode => 0750 }) unless -d $support_dir;
    my $stamp = _timestamp();
    my $staging = File::Spec->catdir($support_dir, ".staging-$stamp-$$");
    my $archive = File::Spec->catfile($support_dir, "desertcms-support-$stamp.tar.gz");
    remove_tree($staging) if -d $staging;
    make_path($staging);

    eval {
        _write_json(File::Spec->catfile($staging, 'health-report.json'), $self->health_report);
        _write_json(File::Spec->catfile($staging, 'settings.redacted.json'), _redact_value(DesertCMS::Settings::all($self->{config}, $self->{db})));
        _write_json(File::Spec->catfile($staging, 'upgrade-jobs.redacted.json'), _redact_value(DesertCMS::Upgrade::latest_jobs($self->{config}, limit => 50)));
        _write_text(File::Spec->catfile($staging, 'README.txt'), _support_readme($args{created_by_username}));

        my $config_dir = File::Spec->catdir($staging, 'configs');
        for my $site (@{ $self->managed_sites }) {
            my $path = $site->{config_path} || '';
            next unless length $path && -f $path;
            my $name = _safe_bundle_name($site->{site_id} || $site->{domain} || 'site');
            _write_text(File::Spec->catfile($config_dir, "$name.conf.redacted"), _redacted_config_file($path));
        }

        my $tar = $self->{config}->get('tar_tool') || 'tar';
        system $tar, '-czf', $archive, '-C', $staging, '.';
        die "support bundle archive failed with status $?" if $? != 0 || !-f $archive;
        chmod 0600, $archive;
        1;
    } or do {
        my $err = $@ || 'support bundle failed';
        remove_tree($staging) if -d $staging;
        unlink $archive if -f $archive;
        die $err;
    };

    remove_tree($staging) if -d $staging;
    return {
        path     => $archive,
        filename => basename($archive),
        bytes    => -s $archive,
    };
}

sub support_bundle_dir {
    my ($self) = @_;
    return File::Spec->catdir($self->{config}->get('backup_dir'), 'support-bundles');
}

sub support_bundles {
    my ($self) = @_;
    my $dir = $self->support_bundle_dir;
    return [] unless -d $dir;
    opendir my $dh, $dir or return [];
    my @rows;
    for my $file (grep { /\Adesertcms-support-[0-9]{8}-[0-9]{6}\.tar\.gz\z/ } readdir $dh) {
        my $path = File::Spec->catfile($dir, $file);
        next unless -f $path;
        my @st = stat($path);
        push @rows, {
            filename => $file,
            path     => $path,
            bytes    => int($st[7] || 0),
            mtime    => int($st[9] || 0),
        };
    }
    closedir $dh;
    @rows = sort { ($b->{mtime} || 0) <=> ($a->{mtime} || 0) } @rows;
    return \@rows;
}

sub support_bundle_path {
    my ($self, $filename) = @_;
    die "invalid support bundle filename" unless defined $filename && $filename =~ /\Adesertcms-support-[0-9]{8}-[0-9]{6}\.tar\.gz\z/;
    my $path = File::Spec->catfile($self->support_bundle_dir, $filename);
    die "support bundle not found" unless -f $path;
    return $path;
}

sub run_due_scheduled_backups {
    my ($self, %args) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    return { due => 0, reason => 'disabled' } unless _truthy($settings->{operations_backup_schedule_enabled});
    my $interval = int($settings->{operations_backup_interval_hours} || 24);
    $interval = 24 if $interval < 1;
    my $last = int($settings->{operations_backup_last_run_at} || 0);
    my $next = $last + ($interval * 3600);
    return { due => 0, reason => 'not due', next_run_at => $next } if $last && now() < $next;
    my $result = $self->backup_all_sites(user_id => $args{user_id});
    $result->{due} = 1;
    return $result;
}

sub _run_site_operation {
    my ($self, $site, $code) = @_;
    my $result = {
        site_id => $site->{site_id} || '',
        domain  => $site->{domain} || '',
        label   => $site->{label} || '',
        status  => 'ok',
    };
    eval {
        my ($config, $db) = $self->_runtime_for_site($site);
        my $details = $code->($config, $db);
        $result->{details} = $details || {};
        1;
    } or do {
        my $err = $@ || 'operation failed';
        chomp $err;
        $result->{status} = 'failed';
        $result->{error} = $err;
    };
    return $result;
}

sub _runtime_for_site {
    my ($self, $site) = @_;
    if (($site->{kind} || '') eq 'master') {
        $self->{db}->migrate;
        return ($self->{config}, $self->{db});
    }
    my $path = $site->{config_path} || '';
    die "config path is missing" unless length $path;
    die "config file is missing: $path" unless -f $path;
    my $config = DesertCMS::Config->load($path);
    my $db = DesertCMS::DB->new(config => $config);
    $db->migrate;
    return ($config, $db);
}

sub _send_offsite_hook {
    my ($self, $site, $archive) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my $url = _trim($settings->{operations_offsite_hook_url});
    return { status => 'skipped', message => 'not configured' } unless length $url;
    die "offsite backup hook must be http or https" unless $url =~ m{\Ahttps?://}i;

    my $payload = {
        event       => 'desertcms.backup.created',
        created_at  => now(),
        site_id     => $site->{site_id} || '',
        domain      => $site->{domain} || '',
        filename    => basename($archive),
        bytes       => -s $archive,
        sha256      => _sha256_file($archive),
    };
    my %headers = (
        'Content-Type' => 'application/json',
        Accept         => 'application/json',
    );
    my $token = _trim($settings->{operations_offsite_hook_token});
    $headers{Authorization} = "Bearer $token" if length $token;

    my $response = HTTP::Tiny->new(timeout => 15, verify_SSL => 1)->post($url, {
        headers => \%headers,
        content => encode_json($payload),
    });
    die "offsite backup hook failed with HTTP " . int($response->{status} || 0)
        unless $response->{success};
    return { status => 'sent', http_status => int($response->{status} || 0) };
}

sub _summary {
    my ($results) = @_;
    my $ok = 0;
    my $failed = 0;
    for my $result (@{$results}) {
        ($result->{status} || '') eq 'ok' ? $ok++ : $failed++;
    }
    return {
        ok      => $failed ? 0 : 1,
        total   => scalar @{$results},
        ok_count => $ok,
        failed  => $failed,
        results => $results,
    };
}

sub _redacted_config_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read config $path: $!";
    my @lines;
    while (my $line = <$fh>) {
        if ($line =~ /\A(\s*([A-Za-z0-9_]+)\s*=\s*)(.*?)(\s*)\z/) {
            my ($prefix, $key, $value, $suffix) = ($1, $2, $3, $4);
            $line = $prefix . '[redacted]' . $suffix . "\n" if _secret_key($key) && length $value;
        }
        push @lines, $line;
    }
    close $fh;
    return join '', @lines;
}

sub _redact_value {
    my ($value, $key) = @_;
    return '[redacted]' if defined $key && _secret_key($key) && defined $value && length "$value";
    if (ref $value eq 'HASH') {
        return { map { $_ => _redact_value($value->{$_}, $_) } keys %{$value} };
    }
    if (ref $value eq 'ARRAY') {
        return [ map { _redact_value($_, $key) } @{$value} ];
    }
    return $value;
}

sub _secret_key {
    my ($key) = @_;
    return 0 unless defined $key;
    return $key =~ /(?:secret|token|password|private|credential|api[_-]?key|access[_-]?key|webhook[_-]?key)/i ? 1 : 0;
}

sub _write_json {
    my ($path, $value) = @_;
    _write_text($path, encode_json($value));
}

sub _write_text {
    my ($path, $body) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _support_readme {
    my ($user) = @_;
    $user ||= 'admin';
    return "DesertCMS support bundle\nCreated by: $user\nSecrets are redacted from settings and config files.\n";
}

sub _safe_bundle_name {
    my ($name) = @_;
    $name = lc($name || 'site');
    $name =~ s/[^a-z0-9._-]+/-/g;
    $name =~ s/\A[-.]+|[-.]+\z//g;
    return $name || 'site';
}

sub _domain_from_url {
    my ($url) = @_;
    $url ||= '';
    $url =~ s{\Ahttps?://}{}i;
    $url =~ s{/.*\z}{};
    return lc $url;
}

sub _sha256_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    my $ctx = Digest::SHA->new(256);
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
}

sub _timestamp {
    my @t = localtime;
    return sprintf '%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _trim {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return $value;
}

1;
