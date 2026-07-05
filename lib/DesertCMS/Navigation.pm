package DesertCMS::Navigation;

use strict;
use warnings;
use DesertCMS::Util qw(now);

sub list_items {
    my ($config, $db) = @_;
    return $db->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM navigation_items
            ORDER BY sort_order ASC, id ASC
        },
        { Slice => {} }
    );
}

sub as_text {
    my ($config, $db) = @_;
    my $items = list_items($config, $db);
    return join "\n", map { $_->{label} . ' | ' . $_->{url} } @{$items};
}

sub replace_from_text {
    my ($config, $db, $text) = @_;
    my $items = _parse($text);
    my $dbh = $db->dbh;
    my $ts = now();

    $dbh->begin_work;
    eval {
        $dbh->do('DELETE FROM navigation_items');
        my $order = 0;
        for my $item (@{$items}) {
            $dbh->do(
                q{
                    INSERT INTO navigation_items (label, url, sort_order, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                },
                undef,
                $item->{label},
                $item->{url},
                $order++,
                $ts,
                $ts
            );
        }
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'navigation save failed';
        eval { $dbh->rollback };
        die $err;
    };

    return scalar @{$items};
}

sub _parse {
    my ($text) = @_;
    my @items;
    my %seen;
    for my $line (split /\r?\n/, $text || '') {
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;
        my ($label, $url) = split /\s*\|\s*/, $line, 2;
        $label = _clean_label($label);
        $url = _clean_url($url);
        next unless length $label && length $url;
        next if $seen{$url}++;
        push @items, { label => $label, url => $url };
    }
    return \@items;
}

sub _clean_label {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s+/ /g;
    return substr($value, 0, 80);
}

sub _clean_url {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return '' if $value =~ /[\r\n"<>]/;
    return '' unless $value =~ m{\A(?:/[A-Za-z0-9._~!\$&'()*+,;=:@%/-]*|https?://[^\s]+)\z}i;
    return substr($value, 0, 500);
}

1;
