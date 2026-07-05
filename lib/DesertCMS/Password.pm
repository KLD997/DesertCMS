package DesertCMS::Password;

use strict;
use warnings;
use Digest::SHA qw(hmac_sha256);
use DesertCMS::Util qw(random_hex constant_time_eq);

my $ALGO = 'pbkdf2-sha256';
my $ITERATIONS = 120_000;
my $KEY_BYTES = 32;

sub hash_password {
    my ($password) = @_;
    die "password is required" unless defined $password && length $password;

    my $salt_hex = random_hex(16);
    my $hash_hex = unpack 'H*', _pbkdf2_sha256($password, pack('H*', $salt_hex), $ITERATIONS, $KEY_BYTES);
    return join '$', $ALGO, $ITERATIONS, $salt_hex, $hash_hex;
}

sub verify_password {
    my ($password, $encoded) = @_;
    return 0 unless defined $password && defined $encoded;

    my ($algo, $iterations, $salt_hex, $hash_hex) = split /\$/, $encoded;
    return 0 unless defined $algo && $algo eq $ALGO;
    return 0 unless defined $iterations && $iterations =~ /^\d+$/ && $iterations >= 100_000;
    return 0 unless defined $salt_hex && $salt_hex =~ /^[0-9a-fA-F]{32,}$/;
    return 0 unless defined $hash_hex && $hash_hex =~ /^[0-9a-fA-F]{64}$/;

    my $candidate = unpack 'H*', _pbkdf2_sha256($password, pack('H*', $salt_hex), int($iterations), length(pack('H*', $hash_hex)));
    return constant_time_eq(lc $candidate, lc $hash_hex);
}

sub _pbkdf2_sha256 {
    my ($password, $salt, $iterations, $dk_len) = @_;

    my $hlen = 32;
    my $blocks = int(($dk_len + $hlen - 1) / $hlen);
    my $derived = '';

    for my $block (1 .. $blocks) {
        my $u = hmac_sha256($salt . pack('N', $block), $password);
        my $t = $u;
        for (2 .. $iterations) {
            $u = hmac_sha256($u, $password);
            $t ^= $u;
        }
        $derived .= $t;
    }

    return substr($derived, 0, $dk_len);
}

1;
