package DesertCMS::Version;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

sub current {
    my (%args) = @_;
    return from_app_root(default_app_root(), %args);
}

sub from_app_root {
    my ($app_root, %args) = @_;
    my $fallback = exists $args{fallback} ? $args{fallback} : 'unknown';
    return from_file(version_file($app_root), fallback => $fallback);
}

sub from_file {
    my ($path, %args) = @_;
    my $fallback = exists $args{fallback} ? $args{fallback} : 'unknown';
    return $fallback unless defined $path && length $path && -f $path;
    open my $fh, '<', $path or return $fallback;
    my $version = <$fh>;
    close $fh;
    $version = '' unless defined $version;
    $version =~ s/^\s+|\s+$//g;
    return length $version ? $version : $fallback;
}

sub version_file {
    my ($app_root) = @_;
    $app_root = default_app_root() unless defined $app_root && length $app_root;
    return File::Spec->catfile($app_root, 'VERSION');
}

sub default_app_root {
    return File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..', '..'));
}

1;
