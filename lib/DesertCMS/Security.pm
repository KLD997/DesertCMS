package DesertCMS::Security;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use Exporter 'import';

our @EXPORT_OK = qw(security_headers apply_openbsd_sandbox);
my $OPENBSD_SANDBOX_APPLIED = 0;

sub security_headers {
    my (%args) = @_;
    my $img_src = "img-src 'self' data:";
    if ($args{img_src} && ref $args{img_src} eq 'ARRAY') {
        my %seen;
        for my $source (@{$args{img_src}}) {
            next unless defined $source && $source =~ m{\Ahttps://[A-Za-z0-9.-]+(?::[0-9]+)?\z};
            next if $seen{$source}++;
            $img_src .= " $source";
        }
    }
    my $form_action = "form-action 'self' https://checkout.stripe.com https://billing.stripe.com https://connect.stripe.com";
    return (
        'Content-Security-Policy' => "default-src 'self'; $img_src; style-src 'self' 'unsafe-inline'; script-src 'self'; frame-ancestors 'none'; base-uri 'self'; $form_action",
        'X-Content-Type-Options'  => 'nosniff',
        'X-Frame-Options'         => 'DENY',
        'Referrer-Policy'         => 'same-origin',
        'Cache-Control'           => 'no-store',
    );
}

sub apply_openbsd_sandbox {
    my ($config, $db) = @_;
    return if $OPENBSD_SANDBOX_APPLIED;

    my $unveiled = 0;
    eval {
        require OpenBSD::Unveil;
        OpenBSD::Unveil->import(qw(unveil));
        my $master_paths = _master_config_paths_to_unveil($config);
        my $contributor_paths = _contributor_paths_to_unveil($config, $db);
        _unveil(_app_root(), 'r');
        _unveil($config->get('data_dir'), 'rwc');
        _unveil($config->get('public_root'), 'rwc');
        _unveil($config->get('theme_dir'), 'rwc');
        _unveil($config->get('originals_dir'), 'rwc');
        _unveil($config->get('backup_dir'), 'rwc');
        _unveil($config->get('admin_asset_dir'), _under_tmp($config->get('admin_asset_dir')) ? 'rwc' : 'r');
        _unveil_tool_group($config->get('image_tool') || 'vips', qw(vips vipsthumbnail vipsheader));
        _unveil_tool_group($config->get('media_preview_tool') || 'ffmpeg', qw(ffmpeg));
        _unveil_tool_group($config->get('tar_tool') || 'tar', qw(tar));
        _unveil_tool_group('', qw(pkg_info pkg_add fc-cache));
        _unveil('/dev/urandom', 'r');
        _unveil('/etc/ssl', 'r');
        _unveil('/etc/ssl/cert.pem', 'r');
        _unveil('/etc/resolv.conf', 'r');
        _unveil('/etc/hosts', 'r');
        _unveil('/etc/installurl', 'r');
        _unveil('/var/db/pkg', 'r');
        _unveil('/usr/local/share/fonts', 'r');
        _unveil('/usr/X11R6/lib/X11/fonts', 'r');
        _unveil_prechecked_paths($master_paths);
        _unveil_prechecked_paths($contributor_paths);
        _unveil('/usr/lib', 'r');
        _unveil('/usr/libdata', 'r');
        _unveil('/usr/local/lib', 'r');
        _unveil('/usr/local/libdata', 'r');
        _unveil('/usr/libexec/ld.so', 'rx');
        _unveil('/tmp', 'rwc');
        unveil();
        $unveiled = 1;
        1;
    };

    my $pledged = 0;
    eval {
        require OpenBSD::Pledge;
        OpenBSD::Pledge->import(qw(pledge));
        pledge(qw(stdio rpath wpath cpath fattr flock inet dns unix proc exec prot_exec));
        $pledged = 1;
        1;
    };

    $OPENBSD_SANDBOX_APPLIED = 1 if $unveiled || $pledged;
}

sub _master_config_paths_to_unveil {
    my ($config) = @_;
    return [] unless $config && (length($config->get('contributor_site_id') || '') || length($config->get('contributor_domain') || ''));
    my $path = $config->get('master_config_path') || '';
    $path = '/etc/desertcms.conf' if !length $path && -f '/etc/desertcms.conf';
    return [] unless length $path && -f $path;
    my @paths = ({ path => $path, permissions => 'r' });
    my $master = eval {
        require DesertCMS::Config;
        DesertCMS::Config->load($path);
    };
    if ($master) {
        push @paths, { path => $master->get('data_dir'), permissions => 'r' }
            if length($master->get('data_dir') || '') && -d $master->get('data_dir');
        push @paths, { path => $master->get('db_path'), permissions => 'r' }
            if length($master->get('db_path') || '') && -f $master->get('db_path');
    }
    return \@paths;
}

sub _app_root {
    my $root = File::Spec->catdir(dirname(__FILE__), '..', '..');
    return abs_path($root) || $root;
}

sub _unveil {
    my ($path, $permissions) = @_;
    return unless defined $path && length $path;
    unveil($path, $permissions);
}

sub _contributor_paths_to_unveil {
    my ($config, $db) = @_;
    return [] unless $db;
    my $root = _contributor_domain_root($config, $db);
    my $rows = eval {
        $db->dbh->selectall_arrayref(
            q{
                SELECT domain, config_path, data_dir, public_root
                FROM contributor_sites
                WHERE config_path <> ''
                   OR data_dir <> ''
                   OR public_root <> ''
            },
            { Slice => {} }
        );
    } || [];
    my @paths;
    for my $row (@{$rows}) {
        next if length $root && !_domain_is_subdomain($row->{domain}, $root);
        push @paths, { path => $row->{config_path}, permissions => 'r' }
            if defined $row->{config_path} && length $row->{config_path} && -f $row->{config_path};
        push @paths, { path => $row->{data_dir}, permissions => 'rwc' }
            if defined $row->{data_dir} && length $row->{data_dir} && -d $row->{data_dir};
        push @paths, { path => $row->{public_root}, permissions => 'rwc' }
            if defined $row->{public_root} && length $row->{public_root} && -d $row->{public_root};
    }
    return \@paths;
}

sub _unveil_prechecked_paths {
    my ($paths) = @_;
    my %seen;
    for my $entry (@{$paths || []}) {
        my $path = $entry->{path} || '';
        my $permissions = $entry->{permissions} || 'r';
        next unless length $path;
        next if $seen{"$permissions\0$path"}++;
        _unveil($path, $permissions);
    }
}

sub _contributor_domain_root {
    my ($config, $db) = @_;
    my $root = '';
    eval {
        require DesertCMS::Settings;
        my $settings = DesertCMS::Settings::all($config, $db);
        $root = $settings->{contributor_domain_root} || '';
        1;
    };
    if (!length $root) {
        $root = $config->get('site_url') || '';
        $root =~ s{\Ahttps?://}{}i;
        $root =~ s{/.*\z}{};
    }
    $root = lc($root || '');
    $root =~ s{\Ahttps?://}{}i;
    $root =~ s{/.*\z}{};
    $root =~ s/^\.+|\.+\z//g;
    return $root =~ /\A[a-z0-9.-]+\.[a-z]{2,}\z/ ? $root : '';
}

sub _domain_is_subdomain {
    my ($domain, $root) = @_;
    $domain = lc($domain || '');
    $root = lc($root || '');
    $domain =~ s/^\.+|\.+\z//g;
    $root =~ s/^\.+|\.+\z//g;
    return 0 unless length $domain && length $root;
    return 0 if $domain eq $root;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+\Q$root\E\z/ ? 1 : 0;
}

sub _unveil_tool_group {
    my ($configured, @commands) = @_;
    my %paths;
    for my $command (@commands) {
        $paths{$_} = 1 for _tool_candidates($configured, $command);
    }
    for my $path (sort keys %paths) {
        _unveil(dirname($path), 'rx') if $path =~ m{/};
        _unveil($path, 'rx') if -e $path;
    }
}

sub _under_tmp {
    my ($path) = @_;
    return 0 unless defined $path && length $path;
    my $abs = abs_path($path) || $path;
    $abs =~ s{\\}{/}g;
    return $abs eq '/tmp' || $abs =~ m{\A/tmp/};
}

sub _tool_candidates {
    my ($configured, $command) = @_;
    my $suffix = ($configured || '') =~ /\.exe\z/i ? '.exe' : '';
    my @candidates;

    if (($configured || '') =~ m{[\\/]}) {
        my ($volume, $dir) = File::Spec->splitpath($configured);
        push @candidates, File::Spec->catpath($volume, $dir, $command . $suffix);
    }

    push @candidates, map { File::Spec->catfile($_, $command . $suffix) }
        qw(/bin /usr/bin /usr/sbin /sbin /usr/local/bin /usr/local/sbin /usr/X11R6/bin);
    return @candidates;
}

1;
