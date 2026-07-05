#!/usr/bin/env perl

use strict;
use warnings;
use File::Find;
use File::Spec;
use FindBin;

my $quiet = grep { $_ eq '--quiet' } @ARGV;
my $root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
my @scan_roots = (
    File::Spec->catdir($root, 'admin'),
    File::Spec->catdir($root, 'public'),
    File::Spec->catdir($root, 'themes', 'default', 'assets'),
    File::Spec->catdir($root, 'themes', 'default', 'templates'),
    File::Spec->catfile($root, 'lib', 'DesertCMS', 'App.pm'),
    File::Spec->catfile($root, 'lib', 'DesertCMS', 'HTTP.pm'),
);

my @problems;
for my $path (@scan_roots) {
    next unless -e $path;
    if (-d $path) {
        find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return unless -f $_;
                    _scan_file($_);
                },
            },
            $path
        );
    } else {
        _scan_file($path);
    }
}

if (@problems) {
    print "Remote asset references were found:\n";
    print "  $_\n" for @problems;
    exit 1;
}

print "All runtime assets are local.\n" unless $quiet;
exit 0;

sub _scan_file {
    my ($file) = @_;
    return unless $file =~ /\.(?:css|html|js|pm|svg|txt)\z/i || $file =~ /(?:App|HTTP)\.pm\z/;
    open my $fh, '<', $file or die "cannot read $file: $!";
    my $line_no = 0;
    while (my $line = <$fh>) {
        ++$line_no;
        chomp $line;
        _problem($file, $line_no, 'remote element asset', $line)
            if $line =~ /<(?:script|img|link|source|iframe)\b[^>]+(?:src|href)\s*=\s*["']https?:\/\//i;
        _problem($file, $line_no, 'remote css import', $line)
            if $line =~ /\@import\s+(?:url\()?["']?https?:\/\//i;
        _problem($file, $line_no, 'remote css url', $line)
            if $line =~ /url\(\s*["']?https?:\/\//i;
        _problem($file, $line_no, 'known CDN domain', $line)
            if $line =~ /\b(?:googleapis|gstatic|cdnjs|unpkg|jsdelivr|bootstrapcdn|fontawesome)\.(?:com|net)\b/i;
    }
    close $fh;
}

sub _problem {
    my ($file, $line_no, $kind, $line) = @_;
    $line =~ s/^\s+|\s+$//g;
    my $rel = File::Spec->abs2rel($file, $root);
    push @problems, "$rel:$line_no $kind: $line";
}
