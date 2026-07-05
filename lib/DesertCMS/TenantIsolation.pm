package DesertCMS::TenantIsolation;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use DesertCMS::Config;
use DesertCMS::Governance;
use DesertCMS::Settings;

sub audit {
    my ($config, $db) = @_;
    my @checks;
    my $scope = DesertCMS::Governance::scope($config);
    if ($scope eq 'contributor') {
        my $site_id = $config->get('contributor_site_id') || '';
        my $domain = _clean_domain($config->get('contributor_domain') || _host_from_url($config->get('site_url')));
        _add(\@checks, 1, 'Contributor scope', 'This instance is a contributor subCMS.');
        _add(\@checks, $site_id =~ /\A[a-z0-9][a-z0-9-]{1,62}\z/ ? 1 : 0, 'Contributor site id', 'contributor_site_id should be set to the subCMS site id.');
        _add(\@checks, _safe_domain($domain), 'Contributor domain', length $domain ? $domain : 'contributor_domain or site_url should identify this subCMS.');
        return _result(\@checks, 0);
    }

    _add(\@checks, 1, 'Master scope', 'This instance is a master CMS.');

    my $root = _domain_root($config, $db);
    _add(\@checks, length($root) ? 1 : 0, 'Contributor root', length($root) ? "*.$root" : 'Set contributor_domain_root for contributor subCMS validation.');

    my %master = _master_paths($config);
    my $rows = eval {
        $db->dbh->selectall_arrayref(
            q{
                SELECT *
                FROM contributor_sites
                ORDER BY site_id ASC
            },
            { Slice => {} }
        );
    } || [];

    my %seen;
    for my $site (@{$rows}) {
        _audit_site(\@checks, $config, \%master, \%seen, $root, $site);
    }

    return _result(\@checks, scalar(@{$rows}));
}

sub _result {
    my ($checks, $row_count) = @_;
    my $issues = grep { ($_->{state} || '') eq 'warn' } @{$checks || []};
    return {
        status  => $issues ? 'warn' : 'ok',
        label   => $issues ? 'Needs review' : 'Isolated',
        summary => int($row_count || 0) . ' row(s), ' . int($issues) . ' isolation issue(s)',
        issues  => int($issues),
        checks  => $checks || [],
    };
}

sub _audit_site {
    my ($checks, $config, $master, $seen, $root, $site) = @_;
    my $site_id = $site->{site_id} || '';
    my $label = length $site_id ? "Site $site_id" : 'Site row';
    my $safe_site_id = $site_id =~ /\A[a-z0-9][a-z0-9-]{1,62}\z/ ? 1 : 0;
    _add($checks, $safe_site_id, "$label id", $safe_site_id ? 'Safe site id.' : 'Site id must be lowercase letters, numbers, or hyphens.');

    my $domain = _clean_domain($site->{domain});
    my $domain_ok = length($root) ? _domain_is_subdomain($domain, $root) : _safe_domain($domain);
    _add($checks, $domain_ok, "$label domain", $domain_ok ? $domain : 'Domain is not a strict contributor subdomain.');

    return if ($site->{status} || '') eq 'destroyed';

    for my $kind (qw(config_path data_dir public_root)) {
        my $path = $site->{$kind} || '';
        my $separate = _path_separate_from_master($path, $master);
        _add($checks, length($path) && $separate, "$label $kind", length($path)
            ? ($separate ? $path : 'Path must not reuse a master CMS root.')
            : 'Path is not set.');
        _record_unique_path($checks, $seen, $kind, $path, $label) if length $path;
    }

    my $config_path = $site->{config_path} || '';
    if (length $config_path && -f $config_path && _path_separate_from_master($config_path, $master)) {
        my $site_config = eval { DesertCMS::Config->load($config_path) };
        if ($site_config) {
            my $site_scope = DesertCMS::Governance::scope($site_config);
            _add($checks, $site_scope eq 'contributor', "$label config scope", $site_scope eq 'contributor' ? 'Contributor scope.' : 'Config is not marked as a contributor subCMS.');
            _add($checks, ($site_config->get('contributor_site_id') || '') eq $site_id, "$label config site id", 'contributor_site_id should match the master row.');
            my $configured_domain = _clean_domain($site_config->get('contributor_domain') || _host_from_url($site_config->get('site_url')));
            _add($checks, $configured_domain eq $domain, "$label config domain", $configured_domain eq $domain ? $configured_domain : 'Configured domain does not match the master row.');

            my $site_data = $site_config->get('data_dir') || '';
            my $site_public = $site_config->get('public_root') || '';
            my $site_db = $site_config->get('db_path') || '';
            _add($checks, _same_path($site_data, $site->{data_dir}), "$label data root match", 'Stored data root should match contributor config.');
            _add($checks, _same_path($site_public, $site->{public_root}), "$label public root match", 'Stored public root should match contributor config.');
            _add($checks, _path_under($site_db, $site_data) && _path_separate_from_master($site_db, $master), "$label SQLite path", 'Contributor DB should live under its own data root.');
            _record_unique_path($checks, $seen, 'db_path', $site_db, $label) if length $site_db;
        } else {
            _add($checks, 0, "$label config load", 'Contributor config could not be loaded.');
        }
    } elsif (length $config_path) {
        _add($checks, 0, "$label config file", 'Contributor config path is missing or unsafe.');
    }
}

sub _master_paths {
    my ($config) = @_;
    return map { $_ => _norm_path($config->get($_) || '') } qw(path data_dir db_path public_root originals_dir backup_dir);
}

sub _path_separate_from_master {
    my ($path, $master) = @_;
    return 0 unless length($path || '');
    my $norm = _norm_path($path);
    for my $master_path (values %{$master || {}}) {
        next unless length $master_path;
        return 0 if _paths_overlap($norm, $master_path);
    }
    return 1;
}

sub _record_unique_path {
    my ($checks, $seen, $kind, $path, $label) = @_;
    my $norm = _norm_path($path);
    return unless length $norm;
    for my $existing (keys %{ $seen->{$kind} || {} }) {
        if ($norm eq $existing) {
            _add($checks, 0, "$label $kind uniqueness", "$kind is already used by $seen->{$kind}{$existing}.");
            return;
        }
        if (_paths_overlap($norm, $existing)) {
            _add($checks, 0, "$label $kind nesting", "$kind overlaps $seen->{$kind}{$existing}.");
            return;
        }
    }
    $seen->{$kind}{$norm} = $label;
}

sub _add {
    my ($checks, $ok, $label, $detail) = @_;
    push @{$checks}, {
        state  => $ok ? 'ok' : 'warn',
        label  => $label || 'Check',
        detail => $detail || '',
    };
}

sub _same_path {
    my ($left, $right) = @_;
    return 0 unless length($left || '') && length($right || '');
    return _norm_path($left) eq _norm_path($right);
}

sub _path_under {
    my ($path, $root) = @_;
    return 0 unless length($path || '') && length($root || '');
    my $norm_path = _norm_path($path);
    my $norm_root = _norm_path($root);
    return $norm_path eq $norm_root || index($norm_path, "$norm_root/") == 0;
}

sub _paths_overlap {
    my ($left, $right) = @_;
    return 0 unless length($left || '') && length($right || '');
    return 1 if $left eq $right;
    return 1 if index($left, "$right/") == 0;
    return 1 if index($right, "$left/") == 0;
    return 0;
}

sub _norm_path {
    my ($path) = @_;
    $path = '' unless defined $path;
    $path =~ s{\\}{/}g;
    $path =~ s{/+\z}{};
    return '' unless length $path;
    my $abs = abs_path($path);
    $abs = File::Spec->rel2abs($path) unless defined $abs && length $abs;
    $abs =~ s{\\}{/}g;
    $abs =~ s{/+\z}{};
    return $^O eq 'MSWin32' ? lc $abs : $abs;
}

sub _domain_root {
    my ($config, $db) = @_;
    my $settings = eval { DesertCMS::Settings::all($config, $db) } || {};
    my $root = $settings->{contributor_domain_root} || '';
    if (!length $root) {
        $root = _host_from_url($config->get('site_url'));
    }
    return _clean_domain($root);
}

sub _host_from_url {
    my ($url) = @_;
    return '' unless defined $url;
    return lc($1) if $url =~ m{\Ahttps?://([^/:]+)}i;
    return '';
}

sub _clean_domain {
    my ($domain) = @_;
    $domain = lc($domain || '');
    $domain =~ s{\Ahttps?://}{}i;
    $domain =~ s{/.*\z}{};
    $domain =~ s/^\.+|\.+\z//g;
    return $domain;
}

sub _safe_domain {
    my ($domain) = @_;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+[a-z]{2,}\z/ ? 1 : 0;
}

sub _domain_is_subdomain {
    my ($domain, $root) = @_;
    $domain = _clean_domain($domain);
    $root = _clean_domain($root);
    return 0 unless _safe_domain($domain) && _safe_domain($root);
    return 0 if $domain eq $root;
    return $domain =~ /\A[a-z0-9](?:[a-z0-9-]{0,62}\.)+\Q$root\E\z/ ? 1 : 0;
}

1;
