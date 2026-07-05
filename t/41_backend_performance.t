use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);

use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::DB;

my $root = tempdir(CLEANUP => 1);
my $config = bless {
    db_path => File::Spec->catfile($root, 'desertcms.sqlite'),
}, 'Local::Config';

my $db = DesertCMS::DB->new(config => $config);

ok(!$db->schema_current, 'fresh database is not marked schema-current');
ok($db->migrate_if_needed, 'first guarded migration initializes the database');
ok($db->schema_current, 'migration records the current schema version');

my $migrate_calls = 0;
{
    no warnings 'redefine';
    local *DesertCMS::DB::migrate = sub {
        $migrate_calls++;
        die "migrate should be skipped when schema is current";
    };
    is($db->migrate_if_needed, 0, 'guard skips full migration when schema is current');
}
is($migrate_calls, 0, 'schema-current requests avoid the full migration path');

done_testing;

package Local::Config;

sub get {
    my ($self, $key) = @_;
    return $self->{$key};
}

package main;
