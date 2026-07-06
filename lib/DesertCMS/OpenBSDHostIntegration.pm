package DesertCMS::OpenBSDHostIntegration;

use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Spec;

sub new {
    my ($class, %args) = @_;
    my $app_root = $args{app_root} || getcwd();
    my $staging_root = $args{staging_root} || '/tmp/desertcms-v3-test';
    my $generated_dir = File::Spec->catfile($staging_root, 'local', 'openbsd-v3');
    my $staging_host = _clean_host($args{staging_host} || 'v3-integration.example.test');
    return bless {
        app_root             => $app_root,
        staging_root         => $staging_root,
        staging_host         => $staging_host,
        generated_dir        => $generated_dir,
        config_path          => $args{config_path} || File::Spec->catfile($staging_root, 'local', 'desertcms-v3-test.conf'),
        generated_httpd_path => $args{generated_httpd_path} || File::Spec->catfile($generated_dir, 'httpd.conf'),
        generated_pf_path    => $args{generated_pf_path} || File::Spec->catfile($generated_dir, 'pf.conf'),
        generated_acme_path  => $args{generated_acme_path} || File::Spec->catfile($generated_dir, 'acme-client.conf'),
        generated_slowcgi_path => $args{generated_slowcgi_path} || File::Spec->catfile($generated_dir, 'desertcms_slowcgi'),
        perl                 => $args{perl} || 'perl',
        expected_branch      => exists($args{expected_branch}) ? $args{expected_branch} : 'codex/v3-development',
        branch_reader        => $args{branch_reader},
        runner               => $args{runner},
        mock                 => $args{mock} ? 1 : 0,
    }, $class;
}

sub steps {
    my ($self) = @_;
    my $config = $self->{config_path};
    return [
        {
            key      => 'branch_guard',
            label    => 'Verify current branch is codex/v3-development',
            internal => 'branch_guard',
        },
        {
            key      => 'stage_branch',
            label    => 'Copy current branch to /tmp/desertcms-v3-test',
            internal => 'stage_workspace',
        },
        {
            key      => 'write_test_config',
            label    => 'Write isolated local v3 test config',
            internal => 'write_test_config',
        },
        {
            key      => 'write_openbsd_test_configs',
            label    => 'Write generated staging httpd, pf, and acme-client configs',
            internal => 'write_openbsd_test_configs',
        },
        {
            key     => 'perl_cgi_syntax',
            label   => 'Compile CGI entrypoint',
            command => [ $self->{perl}, '-Ilib', '-c', 'bin/desertcms.cgi' ],
        },
        {
            key     => 'perl_realtime_syntax',
            label   => 'Compile realtime service',
            command => [ $self->{perl}, '-Ilib', '-c', 'bin/desertcms-realtime.pl' ],
        },
        @{ $self->_v3_module_syntax_steps },
        {
            key     => 'prove_suite',
            label   => 'Run full Perl test suite',
            command => [ 'prove', '-l', 't' ],
        },
        {
            key     => 'schema_migration',
            label   => 'Run schema migration on temp SQLite DB',
            env     => { DESERTCMS_CONFIG => $config },
            command => [
                $self->{perl}, '-Ilib',
                '-MDesertCMS::Config', '-MDesertCMS::DB',
                '-e',
                'my $c=DesertCMS::Config->load($ENV{DESERTCMS_CONFIG}); DesertCMS::DB->new(config=>$c)->migrate; print "schema migration ok\n";',
            ],
        },
        {
            key      => 'httpd_route_shape',
            label    => 'Verify generated/example httpd config forwards v3 dynamic routes',
            internal => 'check_httpd_route_shape',
        },
        {
            key     => 'httpd_syntax',
            label   => 'Run httpd -n against generated staging config',
            command => [ 'httpd', '-n', '-f', _slash($self->{generated_httpd_path}) ],
        },
        {
            key      => 'pf_streaming_shape',
            label    => 'Verify generated/example pf rules document streaming ingress port',
            internal => 'check_pf_streaming_shape',
        },
        {
            key     => 'pf_syntax',
            label   => 'Run pfctl -nf against generated staging rules',
            command => [ 'pfctl', '-nf', _slash($self->{generated_pf_path}) ],
        },
        {
            key      => 'slowcgi_shape',
            label    => 'Verify desertcms_slowcgi rc.d shape',
            internal => 'check_slowcgi_shape',
        },
        {
            key     => 'slowcgi_syntax',
            label   => 'Run sh -n against generated staging slowcgi rc.d script',
            command => [ 'sh', '-n', _slash($self->{generated_slowcgi_path}) ],
        },
        {
            key      => 'acme_client_shape',
            label    => 'Verify acme-client config shape',
            internal => 'check_acme_shape',
        },
        {
            key     => 'security_center_readonly',
            label   => 'Run Security Center read-only checks',
            env     => { DESERTCMS_CONFIG => $config },
            command => [
                $self->{perl}, '-Ilib',
                '-MDesertCMS::Config', '-MDesertCMS::DB', '-MDesertCMS::SecurityCenter',
                '-e',
                'my $c=DesertCMS::Config->load($ENV{DESERTCMS_CONFIG}); my $db=DesertCMS::DB->new(config=>$c); $db->migrate; my $checks=DesertCMS::SecurityCenter->new(config=>$c, db=>$db)->run_checks; die "no checks\n" unless @$checks; print scalar(@$checks)." security checks\n";',
            ],
        },
        {
            key     => 'syspatch_check',
            label   => 'Run syspatch -c read-only base patch check',
            command => [ 'syspatch', '-c' ],
        },
        {
            key     => 'pkg_add_update_check',
            label   => 'Run pkg_add -n -u package update dry-run',
            command => [ 'pkg_add', '-n', '-u' ],
        },
        {
            key     => 'root_worker_queue_dry_run',
            label   => 'Queue a root-worker remediation without applying it',
            env     => { DESERTCMS_CONFIG => $config },
            command => [
                $self->{perl}, '-Ilib',
                '-MDesertCMS::Config', '-MDesertCMS::DB', '-MDesertCMS::SecurityCenter',
                '-e',
                'my $c=DesertCMS::Config->load($ENV{DESERTCMS_CONFIG}); my $db=DesertCMS::DB->new(config=>$c); $db->migrate; my $dbh=$db->dbh; my $ts=time; $dbh->do(q{INSERT INTO admin_users (username, email, role, password_hash, password_algo, created_at, updated_at) VALUES ("v3-integration", "v3-integration@example.test", "owner", "integration-hash", "integration", ?, ?)}, undef, $ts, $ts); my $admin_id=$dbh->sqlite_last_insert_rowid; my $row=DesertCMS::SecurityCenter->new(config=>$c, db=>$db)->queue_fix(check_key=>"integration_harness", action=>"dry_run_only", approved_by_user_id=>$admin_id, details=>{source=>"openbsd-v3-integration"}); die "queue failed\n" unless $row->{id}; print "queued remediation ".$row->{id}."\n";',
            ],
        },
    ];
}

sub _v3_module_syntax_steps {
    my ($self) = @_;
    my @modules = (
        [ accounts                 => 'DesertCMS/Accounts.pm' ],
        [ dashboard                => 'DesertCMS/Dashboard.pm' ],
        [ forums                   => 'DesertCMS/Forums.pm' ],
        [ live_streaming           => 'DesertCMS/LiveStreaming.pm' ],
        [ module_manifest          => 'DesertCMS/ModuleManifest.pm' ],
        [ notifications            => 'DesertCMS/Notifications.pm' ],
        [ openbsd_host_integration => 'DesertCMS/OpenBSDHostIntegration.pm' ],
        [ realtime                 => 'DesertCMS/Realtime.pm' ],
        [ security_center          => 'DesertCMS/SecurityCenter.pm' ],
        [ social                   => 'DesertCMS/Social.pm' ],
    );
    return [
        map {
        my ($key, $file) = @{$_};
        {
            key     => "perl_v3_${key}_syntax",
            label   => "Compile v3 $key module",
            command => [ $self->{perl}, '-Ilib', '-c', "lib/$file" ],
        }
    } @modules
    ];
}

sub run {
    my ($self, %args) = @_;
    my $dry_run = exists($args{dry_run}) ? $args{dry_run} : 1;
    $self->_assert_non_live_target unless $self->{mock};
    if (!$dry_run && !$self->{mock}) {
        die "real OpenBSD integration requires DESERTCMS_OPENBSD_INTEGRATION=1\n"
            unless ($ENV{DESERTCMS_OPENBSD_INTEGRATION} || '') eq '1';
        die "real OpenBSD integration must run on OpenBSD, not $^O\n"
            unless $^O eq 'openbsd';
    }
    my @results;
    for my $step (@{ $self->steps }) {
        if ($dry_run) {
            push @results, { %{$step}, status => 'planned' };
            next;
        }
        my $result = eval {
            my $step_result;
            if ($step->{internal}) {
                my $method = $step->{internal};
                die "unknown internal step: $method\n" unless $self->can($method);
                my $detail = $self->$method($step);
                $step_result = { %{$step}, status => 'ok', detail => $detail || '' };
            } else {
                $step_result = $self->_run_command($step);
            }
            $step_result;
        };
        if (!$result) {
            push @results, { %{$step}, status => 'failed', detail => $@ || 'unknown failure' };
            last;
        }
        push @results, $result;
    }
    return \@results;
}

sub stage_workspace {
    my ($self) = @_;
    return 'mock stage copy skipped' if $self->{mock};
    my $branch_detail = $self->branch_guard;
    my $source = abs_path($self->{app_root}) || die "cannot resolve app root\n";
    my $target = _assert_staging_root_path($self->{staging_root});
    remove_tree($target) if -e $target;
    make_path($target);
    my %skip_dir = map { $_ => 1 } qw(.git .codex .agents .tools data dist local);
    find(
        {
            wanted => sub {
                my $path = $File::Find::name;
                my $name = $_;
                if (-d $path && $skip_dir{$name}) {
                    $File::Find::prune = 1;
                    return;
                }
                return if $path eq $source;
                my $rel = File::Spec->abs2rel($path, $source);
                return if $rel =~ /\A\.\.|\A\Q$source\E/;
                my $dest = File::Spec->catfile($target, $rel);
                if (-d $path) {
                    make_path($dest) unless -d $dest;
                    return;
                }
                make_path(dirname($dest)) unless -d dirname($dest);
                copy($path, $dest) or die "copy $path to $dest failed: $!\n";
                chmod((stat($path))[2] & 07777, $dest);
            },
            no_chdir => 0,
        },
        $source
    );
    return "$branch_detail; copied $source to $target";
}

sub branch_guard {
    my ($self) = @_;
    my $expected = $self->{expected_branch} || 'codex/v3-development';
    my $branch = $self->_current_git_branch;
    die "OpenBSD v3 integration must run from branch $expected, not $branch\n"
        unless $branch eq $expected;
    return "branch $branch ok";
}

sub write_test_config {
    my ($self) = @_;
    return 'mock config write skipped' if $self->{mock};
    my $path = $self->{config_path};
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>', $path or die "cannot write $path: $!\n";
    print {$fh} $self->config_text;
    close $fh;
    chmod 0600, $path;
    return "wrote $path";
}

sub write_openbsd_test_configs {
    my ($self) = @_;
    return 'mock OpenBSD config writes skipped' if $self->{mock};
    my $dir = $self->{generated_dir};
    make_path($dir) unless -d $dir;
    $self->_write_generated_file($self->{generated_httpd_path}, $self->generated_httpd_config);
    $self->_write_generated_file($self->{generated_pf_path}, $self->generated_pf_config);
    $self->_write_generated_file($self->{generated_acme_path}, $self->generated_acme_config);
    $self->_write_generated_file($self->{generated_slowcgi_path}, $self->generated_slowcgi_config, 0555);
    return 'wrote generated OpenBSD staging configs';
}

sub config_text {
    my ($self) = @_;
    my $root = _slash($self->{staging_root});
    my $host = $self->{staging_host} || 'v3-integration.example.test';
    return join("\n",
        "site_name = DesertCMS v3 Integration",
        "site_url = https://$host",
        "data_dir = $root/local/openbsd-v3/data",
        "db_path = $root/local/openbsd-v3/desertcms.sqlite",
        "app_secret_file = $root/local/openbsd-v3/app_secret",
        "public_root = $root/local/openbsd-v3/public",
        "originals_dir = $root/local/openbsd-v3/originals",
        "backup_dir = $root/local/openbsd-v3/backups",
        "theme_dir = $root/themes",
        "admin_asset_dir = $root/admin/assets",
        "module_accounts_enabled = 1",
        "module_live_streaming_enabled = 1",
        "module_forums_enabled = 1",
        "module_social_enabled = 1",
        "module_notifications_enabled = 1",
        "module_security_center_enabled = 1",
        "realtime_enabled = 1",
        "realtime_bind_host = 127.0.0.1",
        "realtime_port = 8787",
        "realtime_public_url = https://$host/events",
        "realtime_allowed_origins = https://$host",
        "live_hls_public_prefix = /streams",
        "live_hls_output_dir = $root/local/openbsd-v3/public/streams",
        "live_worker_health_path = /live/worker/health",
        "live_chat_account_only = 1",
        '',
    );
}

sub generated_httpd_config {
    my ($self) = @_;
    my $script = _slash(File::Spec->catfile($self->{staging_root}, 'bin', 'desertcms.cgi'));
    my $config = _slash($self->{config_path});
    my $host = $self->{staging_host} || 'v3-integration.example.test';
    my $root = '/htdocs/desertcms-v3-test';
    my $socket = '/run/desertcms-v3-test.sock';
    my @routes = qw(admin analytics comments ratings forms shop stripe billing postmark events directory bookings members account forums social live newsletter donate testimonials);
    my $routes = '';
    for my $route (@routes) {
        $routes .= <<"ROUTE";
\tlocation "/$route*" {
\t\tfastcgi {
\t\t\tsocket "$socket"
\t\t\tparam SCRIPT_FILENAME "$script"
\t\t\tparam SCRIPT_NAME "/$route"
\t\t\tparam DESERTCMS_CONFIG "$config"
\t\t}
\t}

ROUTE
    }
    return <<"HTTPD";
# DesertCMS v3 OpenBSD integration httpd config.
# Generated under /tmp/desertcms-v3-test for syntax checks only.

types {
\tinclude "/usr/share/misc/mime.types"
}

server "$host" {
\tlisten on * port 80
\troot "$root"

\tconnection {
\t\tmax request body 67108864
\t}

\tlocation "/streams/*" {
\t\troot "$root"
\t}

$routes\tlocation "/.well-known/acme-challenge/*" {
\t\troot "/acme"
\t\trequest strip 2
\t}
}
HTTPD
}

sub generated_pf_config {
    return <<'PF';
# DesertCMS v3 OpenBSD integration pf rules.
# Generated under /tmp/desertcms-v3-test for pfctl -nf syntax checks only.

ext_if = "egress"
table <ssh_admins> persist { 203.0.113.10/32 }

set block-policy drop
set skip on lo

block log all
match in all scrub (no-df random-id max-mss 1440)

pass out quick all keep state

pass in quick on $ext_if proto tcp from <ssh_admins> to ($ext_if) port 22 flags S/SA keep state
pass in quick on $ext_if proto tcp from any to ($ext_if) port { 80 443 } flags S/SA keep state
# Optional Live Streaming OBS ingest. Enable only after the streaming worker and SubCMS gates are configured.
# pass in quick on $ext_if proto tcp from any to ($ext_if) port 1935 flags S/SA keep state
pass in quick on $ext_if inet proto icmp icmp-type echoreq keep state
pass in quick on $ext_if inet6 proto icmp6 keep state
PF
}

sub generated_acme_config {
    my ($self) = @_;
    my $host = $self->{staging_host} || 'v3-integration.example.test';
    return <<"ACME";
# DesertCMS v3 OpenBSD integration acme-client config.
# Generated under /tmp/desertcms-v3-test for shape checks only.

authority letsencrypt {
	api url "https://acme-v02.api.letsencrypt.org/directory"
	account key "/etc/acme/letsencrypt-privkey.pem"
}

domain "$host" {
	domain key "/etc/ssl/private/$host.key"
	domain full chain certificate "/etc/ssl/$host.fullchain.pem"
	sign with letsencrypt
}
ACME
}

sub generated_slowcgi_config {
    my ($self) = @_;
    return <<'SLOWCGI';
#!/bin/ksh
#
# DesertCMS v3 OpenBSD integration slowcgi rc.d script.
# Generated under /tmp/desertcms-v3-test for staging syntax checks only.

daemon="/usr/sbin/slowcgi"
daemon_flags="-p / -u _desertcms -s /var/www/run/desertcms-v3-test.sock"

. /etc/rc.d/rc.subr

rc_reload=NO

rc_cmd $1
SLOWCGI
}

sub check_httpd_route_shape {
    my ($self) = @_;
    my $body = $self->_read_generated_or_app_file($self->{generated_httpd_path}, 'etc/httpd.conf.example');
    for my $route (qw(admin account forums social live)) {
        die "httpd config missing /$route route\n" unless $body =~ /location\s+"\Q\/$route\E\*"/;
        die "httpd config missing SCRIPT_NAME /$route\n" unless $body =~ /param\s+SCRIPT_NAME\s+"\Q\/$route\E"/;
    }
    die "httpd config missing static HLS /streams route\n" unless $body =~ /location\s+"\/streams\/\*"\s+\{\s+root\s+"/s;
    die "httpd config does not use a desertcms slowcgi socket\n" unless $body =~ m{/run/desertcms(?:-v3-test)?\.sock};
    return 'httpd v3 route shape ok';
}

sub check_pf_streaming_shape {
    my ($self) = @_;
    my $body = $self->_read_generated_or_app_file($self->{generated_pf_path}, 'etc/pf.conf.example');
    die "pf rules missing HTTP/HTTPS public rule\n" unless $body =~ /port\s+\{\s*80\s+443\s*\}/;
    die "pf rules missing opt-in OBS ingest port 1935 note\n" unless $body =~ /port\s+1935/;
    return 'pf streaming shape ok';
}

sub check_slowcgi_shape {
    my ($self) = @_;
    my $body = $self->_read_generated_or_app_file($self->{generated_slowcgi_path}, 'etc/rc.d/desertcms_slowcgi');
    die "slowcgi rc.d does not use /usr/sbin/slowcgi\n" unless $body =~ m{daemon="/usr/sbin/slowcgi"};
    die "slowcgi rc.d does not run as _desertcms\n" unless $body =~ /-u\s+_desertcms/;
    die "slowcgi rc.d socket is not under /var/www/run\n" unless $body =~ m{/var/www/run/desertcms(?:-v3-test)?\.sock};
    return 'slowcgi rc.d shape ok';
}

sub check_acme_shape {
    my ($self) = @_;
    my $body = $self->_read_generated_or_app_file($self->{generated_acme_path}, 'etc/acme-client.conf.example');
    die "acme-client config missing letsencrypt authority\n" unless $body =~ /authority\s+letsencrypt/;
    die "acme-client config missing account key\n" unless $body =~ /account key/;
    die "acme-client config missing domain key\n" unless $body =~ /domain key/;
    die "acme-client config missing full chain certificate\n" unless $body =~ /domain full chain certificate/;
    return 'acme-client shape ok';
}

sub command_line {
    my ($self, $step) = @_;
    return '[internal] ' . ($step->{internal} || '') if $step->{internal};
    return join ' ', map { _shell_quote($_) } @{ $step->{command} || [] };
}

sub _run_command {
    my ($self, $step) = @_;
    if ($self->{mock}) {
        if (ref($self->{runner}) eq 'CODE') {
            $self->{runner}->($step);
        }
        return { %{$step}, status => 'ok', detail => 'mock command skipped' };
    }
    my $cwd = $step->{cwd} || $self->{staging_root};
    my $old = getcwd();
    chdir $cwd or die "cannot chdir to $cwd: $!\n";
    local %ENV = (%ENV, %{ $step->{env} || {} });
    my @cmd = @{ $step->{command} || [] };
    my $status = system { $cmd[0] } @cmd;
    my $exit = $status == -1 ? 127 : ($status >> 8);
    chdir $old;
    die "command failed ($exit): " . $self->command_line($step) . "\n" unless $exit == 0;
    return { %{$step}, status => 'ok', detail => 'exit 0' };
}

sub _read_app_file {
    my ($self, $rel) = @_;
    my @parts = split m{/}, $rel;
    my $staged_path = File::Spec->catfile($self->{staging_root}, @parts);
    my $path = -e $staged_path
        ? $staged_path
        : File::Spec->catfile($self->{app_root}, @parts);
    open my $fh, '<', $path or die "cannot read $path: $!\n";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _read_generated_or_app_file {
    my ($self, $generated_path, $fallback_rel) = @_;
    if (length($generated_path || '') && -e $generated_path) {
        open my $fh, '<', $generated_path or die "cannot read $generated_path: $!\n";
        local $/;
        my $body = <$fh>;
        close $fh;
        return $body;
    }
    return $self->_read_app_file($fallback_rel);
}

sub _write_generated_file {
    my ($self, $path, $body, $mode) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>', $path or die "cannot write $path: $!\n";
    print {$fh} $body;
    close $fh;
    chmod($mode || 0600, $path);
}

sub _assert_non_live_target {
    my ($self) = @_;
    _assert_staging_host($self->{staging_host});
    my $target = _assert_staging_root_path($self->{staging_root});
    _assert_staging_child_path($self->{config_path}, $target, 'config path');
    for my $path ($self->{generated_httpd_path}, $self->{generated_pf_path}, $self->{generated_acme_path}, $self->{generated_slowcgi_path}) {
        _assert_staging_child_path($path, $target, 'generated OpenBSD integration files');
    }
}

sub _assert_staging_root_path {
    my ($path) = @_;
    my $target = _slash($path);
    die "staging root must be under /tmp/desertcms-v3-test\n"
        if _path_has_parent_segment($target);
    die "staging root must be under /tmp/desertcms-v3-test\n"
        unless $target =~ m{\A/tmp/desertcms-v3-test(?:/|\z)};
    return $target;
}

sub _assert_staging_child_path {
    my ($path, $target, $label) = @_;
    my $child = _slash($path);
    die "$label must stay under the staging root\n"
        if _path_has_parent_segment($child);
    die "$label must stay under the staging root\n"
        unless $child eq $target || index($child, "$target/") == 0;
    return $child;
}

sub _path_has_parent_segment {
    my ($path) = @_;
    return scalar grep { $_ eq '..' } split m{/+}, _slash($path || '');
}

sub _assert_staging_host {
    my ($host) = @_;
    $host = _clean_host($host || '');
    die "OpenBSD integration host must be a staging-only example.test hostname\n"
        unless length($host) && $host =~ /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\.example\.test\z/;
    die "OpenBSD integration host must not target live DesertCMS domains\n"
        if $host =~ /(?:^|\.)desertarchives\.com\z/ || $host =~ /(?:^|\.)desertcms\.com\z/;
}

sub _current_git_branch {
    my ($self) = @_;
    if (ref($self->{branch_reader}) eq 'CODE') {
        my $branch = $self->{branch_reader}->($self);
        chomp($branch) if defined $branch;
        die "cannot determine current git branch\n" unless length($branch || '');
        return $branch;
    }
    if ($self->{mock}) {
        return $self->{expected_branch} || 'codex/v3-development';
    }
    my $root = $self->{app_root};
    my $marker = File::Spec->catfile($root, '.desertcms-v3-branch');
    if (!-d File::Spec->catdir($root, '.git') && -f $marker) {
        open my $mf, '<', $marker or die "cannot read branch marker: $!\n";
        my $marked_branch = <$mf>;
        close $mf;
        chomp($marked_branch) if defined $marked_branch;
        $marked_branch =~ s{\A\s+|\s+\z}{}g if defined $marked_branch;
        return $marked_branch if length($marked_branch || '');
    }
    open my $fh, '-|', 'git', '-C', $root, 'branch', '--show-current'
        or die "cannot run git branch guard: $!\n";
    my $branch = <$fh>;
    my $ok = close $fh;
    chomp($branch) if defined $branch;
    return $branch if $ok && length($branch || '');
    if (-f $marker) {
        open my $mf, '<', $marker or die "cannot read branch marker: $!\n";
        my $marked_branch = <$mf>;
        close $mf;
        chomp($marked_branch) if defined $marked_branch;
        $marked_branch =~ s{\A\s+|\s+\z}{}g if defined $marked_branch;
        return $marked_branch if length($marked_branch || '');
    }
    die "cannot determine current git branch\n";
}

sub _slash {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s{\\}{/}g;
    return $value;
}

sub _clean_host {
    my ($host) = @_;
    $host = lc($host || '');
    $host =~ s{\Ahttps?://}{};
    $host =~ s{/.*\z}{};
    $host =~ s{:\d+\z}{};
    $host =~ s{\A\s+|\s+\z}{}g;
    return $host;
}

sub _shell_quote {
    my ($value) = @_;
    $value = '' unless defined $value;
    return "''" if $value eq '';
    return $value if $value =~ /\A[A-Za-z0-9_\-.\/:=]+\z/;
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

1;
