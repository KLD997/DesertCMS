use strict;
use warnings;
use Test::More;
use File::Find;

my @files;
find(
    sub {
        return unless /\.pm\z/;
        push @files, $File::Find::name;
    },
    'lib'
);
push @files, sort glob 'bin/*';
push @files, sort glob 'tools/*.pl';

for my $file (@files) {
    open my $pipe, '-|', $^X, '-Ilib', '-c', $file
        or die "cannot run perl syntax check for $file: $!";
    my $output = do { local $/; <$pipe> };
    close $pipe;
    is($?, 0, "$file compiles") or diag $output;
}

done_testing;
