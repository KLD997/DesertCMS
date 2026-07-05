package DesertCMS::Maintenance;

use strict;
use warnings;
use DesertCMS::Auth;
use DesertCMS::Util qw(random_hex);

sub create_admin {
    my ($config, $db, @args) = @_;

    my $username = shift @args || die "usage: create-admin USERNAME [--password PASSWORD]\n";
    my $password;
    while (@args) {
        my $arg = shift @args;
        if ($arg eq '--password') {
            $password = shift @args;
            next;
        }
        die "unknown argument: $arg\n";
    }

    my $generated = 0;
    if (!defined $password || !length $password) {
        $password = random_hex(9);
        $generated = 1;
    }

    my $auth = DesertCMS::Auth->new(config => $config, db => $db);
    my $id = $auth->create_admin(
        username => $username,
        password => $password,
        force_password_change => $generated,
    );

    print "created admin user $username with id $id\n";
    if ($generated) {
        print "temporary password: $password\n";
        print "this temporary account must be changed after first login\n";
    }
}

sub reset_admin {
    my ($config, $db, @args) = @_;

    my $username = shift @args || die "usage: reset-admin USERNAME [--password PASSWORD]\n";
    my $password;
    while (@args) {
        my $arg = shift @args;
        if ($arg eq '--password') {
            $password = shift @args;
            next;
        }
        die "unknown argument: $arg\n";
    }

    my $generated = 0;
    if (!defined $password || !length $password) {
        $password = random_hex(9);
        $generated = 1;
    }

    my $auth = DesertCMS::Auth->new(config => $config, db => $db);
    my $id = $auth->reset_single_admin(
        username => $username,
        password => $password,
    );

    print "reset recovery owner admin user $username with id $id\n";
    if ($generated) {
        print "temporary password: $password\n";
    } else {
        print "temporary password: provided on command line\n";
    }
    print "this temporary account must be changed after first login\n";
}

1;
