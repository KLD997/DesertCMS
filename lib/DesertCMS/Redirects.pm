package DesertCMS::Redirects;

use strict;
use warnings;
use DesertCMS::Util qw(now);

sub list_rules {
    my ($config, $db) = @_;
    return $db->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM redirects
            ORDER BY source_path ASC
        },
        { Slice => {} }
    );
}

sub as_text {
    my ($config, $db) = @_;
    my $rules = list_rules($config, $db);
    return join "\n", map { $_->{source_path} . ' | ' . $_->{target_url} . ' | ' . $_->{status_code} } @{$rules};
}

sub replace_from_text {
    my ($config, $db, $text) = @_;
    my $rules = _parse($text);
    my $dbh = $db->dbh;
    my $ts = now();

    $dbh->begin_work;
    eval {
        $dbh->do('DELETE FROM redirects');
        for my $rule (@{$rules}) {
            $dbh->do(
                q{
                    INSERT INTO redirects (source_path, target_url, status_code, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                },
                undef,
                $rule->{source_path},
                $rule->{target_url},
                $rule->{status_code},
                $ts,
                $ts
            );
        }
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'redirect save failed';
        eval { $dbh->rollback };
        die $err;
    };

    return scalar @{$rules};
}

sub match {
    my ($config, $db, $path) = @_;
    $path ||= '/';
    my $normalized = _normalize_source($path);
    return undef unless length $normalized;
    return $db->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM redirects
            WHERE source_path = ?
            LIMIT 1
        },
        undef,
        $normalized
    );
}

sub _parse {
    my ($text) = @_;
    my @rules;
    my %seen;
    for my $line (split /\r?\n/, $text || '') {
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;
        my ($source, $target, $status) = split /\s*\|\s*/, $line, 3;
        $source = _normalize_source($source);
        $target = _clean_target($target);
        $status = defined $status && $status =~ /\A302\z/ ? 302 : 301;
        next unless length $source && length $target;
        next if $seen{$source}++;
        push @rules, {
            source_path => $source,
            target_url  => $target,
            status_code => $status,
        };
    }
    return \@rules;
}

sub _normalize_source {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return '' if $value eq '' || $value eq '/';
    return '' unless $value =~ m{\A/[A-Za-z0-9._~!\$&'()*+,;=:@%/-]*\z};
    return '' if $value =~ m{(?:\A|/)\.\.(?:/|\z)};
    return '' if $value =~ m{\A/admin(?:/|\z)};
    $value =~ s{/+\z}{} unless $value eq '/';
    return substr($value, 0, 500);
}

sub _clean_target {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return '' if $value =~ /[\r\n"<>]/;
    return '' unless $value =~ m{\A(?:/[A-Za-z0-9._~!\$&'()*+,;=:@%/?#-]*|https?://[^\s]+)\z}i;
    return substr($value, 0, 1000);
}

1;
