package DesertCMS::Util;

use strict;
use warnings;
use Digest::SHA qw(hmac_sha256 sha256_hex);
use Exporter 'import';

our @EXPORT_OK = qw(
    now random_hex sha256_hexstr hmac_sha256_hex constant_time_eq
    escape_html url_decode parse_urlencoded slugify
);

sub now {
    return time;
}

sub random_hex {
    my ($bytes) = @_;
    $bytes ||= 32;

    my $buf = '';
    if (open my $fh, '<:raw', '/dev/urandom') {
        my $read = read $fh, $buf, $bytes;
        close $fh;
        die "could not read secure random bytes" unless defined $read && $read == $bytes;
    } else {
        eval {
            require Crypt::URandom;
            $buf = Crypt::URandom::urandom($bytes);
            1;
        } or die "secure random source is unavailable";
    }

    return unpack 'H*', $buf;
}

sub sha256_hexstr {
    my ($value) = @_;
    $value = '' unless defined $value;
    return sha256_hex($value);
}

sub hmac_sha256_hex {
    my ($data, $key) = @_;
    return unpack 'H*', hmac_sha256($data, $key);
}

sub constant_time_eq {
    my ($left, $right) = @_;
    return 0 unless defined $left && defined $right;
    return 0 unless length($left) == length($right);

    my $diff = 0;
    for my $i (0 .. length($left) - 1) {
        $diff |= ord(substr($left, $i, 1)) ^ ord(substr($right, $i, 1));
    }

    return $diff == 0 ? 1 : 0;
}

sub escape_html {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

sub url_decode {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ tr/+/ /;
    $value =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
    return $value;
}

sub parse_urlencoded {
    my ($body) = @_;
    my %params;
    return \%params unless defined $body && length $body;

    for my $pair (split /&/, $body) {
        my ($key, $value) = split /=/, $pair, 2;
        $key = url_decode($key);
        $value = url_decode($value);
        next unless length $key;
        $params{$key} = $value;
    }

    return \%params;
}

sub slugify {
    my ($value) = @_;
    $value = lc($value || '');
    $value =~ s/[^a-z0-9]+/-/g;
    $value =~ s/^-+//;
    $value =~ s/-+$//;
    return $value || 'untitled';
}

1;
