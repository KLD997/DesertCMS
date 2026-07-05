package DesertCMS::Backup;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname basename);
use File::Copy qw(copy);
use File::Find;
use File::Path qw(make_path remove_tree);
use File::Spec;
use JSON::PP qw(encode_json decode_json);
use DesertCMS::Util qw(now);

sub create_backup {
    my ($config, $db, $user_id) = @_;
    my $backup_dir = $config->get('backup_dir');
    make_path($backup_dir) unless -d $backup_dir;

    my $stamp = _timestamp();
    my ($staging, $archive) = _unique_backup_paths($backup_dir, $stamp);
    remove_tree($staging) if -d $staging;
    make_path($staging);

    eval {
        _copy_database($db, File::Spec->catfile($staging, 'db', 'desertcms.sqlite'));
        _copy_dir($config->get('originals_dir'), File::Spec->catdir($staging, 'originals'));
        _copy_dir($config->get('public_root'), File::Spec->catdir($staging, 'public'));
        _copy_dir($config->get('theme_dir'), File::Spec->catdir($staging, 'themes'));

        my $manifest = {
            version => 1,
            created_at => now(),
            site_name => $config->get('site_name'),
            files => _checksums($staging),
        };
        _write_file(File::Spec->catfile($staging, 'manifest.json'), encode_json($manifest));
        _tar_create($config, $archive, $staging);

        my $dbh = $db->dbh;
        $dbh->do(
            q{
                INSERT INTO backups
                    (filename, manifest_json, created_by_user_id, created_at)
                VALUES
                    (?, ?, ?, ?)
            },
            undef,
            basename($archive),
            encode_json($manifest),
            $user_id,
            now()
        );
        1;
    } or do {
        my $err = $@ || 'backup failed';
        remove_tree($staging) if -d $staging;
        unlink $archive if -f $archive;
        die $err;
    };

    remove_tree($staging) if -d $staging;
    return $archive;
}

sub restore_backup {
    my ($config, $db, $archive, $user_id) = @_;
    die "backup archive is required" unless defined $archive && length $archive;
    die "backup archive not found: $archive" unless -f $archive;

    my $backup_dir = $config->get('backup_dir');
    make_path($backup_dir) unless -d $backup_dir;
    my $stamp = _timestamp();
    my $staging = File::Spec->catdir($backup_dir, ".restore-$stamp");
    remove_tree($staging) if -d $staging;
    make_path($staging);

    eval {
        _tar_extract($config, $archive, $staging);
        _verify_manifest($staging);

        create_backup($config, $db, $user_id);

        if ($db->{dbh}) {
            $db->{dbh}->disconnect;
            $db->{dbh} = undef;
        }
        _copy_file(File::Spec->catfile($staging, 'db', 'desertcms.sqlite'), $config->get('db_path'));
        _replace_dir(File::Spec->catdir($staging, 'originals'), $config->get('originals_dir'));
        _replace_dir(File::Spec->catdir($staging, 'public'), $config->get('public_root'));
        _replace_dir(File::Spec->catdir($staging, 'themes'), $config->get('theme_dir'));
        1;
    } or do {
        my $err = $@ || 'restore failed';
        remove_tree($staging) if -d $staging;
        die $err;
    };

    remove_tree($staging) if -d $staging;
    return 1;
}

sub test_backup {
    my ($config, $archive) = @_;
    die "backup archive is required" unless defined $archive && length $archive;
    die "backup archive not found: $archive" unless -f $archive;

    my $backup_dir = $config->get('backup_dir');
    make_path($backup_dir) unless -d $backup_dir;
    my $stamp = _timestamp();
    my $staging = File::Spec->catdir($backup_dir, ".restore-test-$stamp-$$");
    remove_tree($staging) if -d $staging;
    make_path($staging);

    my $result;
    eval {
        _tar_extract($config, $archive, $staging);
        my $manifest = _verify_manifest($staging);
        my $db_path = File::Spec->catfile($staging, 'db', 'desertcms.sqlite');
        die "backup database missing" unless -f $db_path;
        my $integrity = _sqlite_integrity_check($db_path);
        $result = {
            ok           => 1,
            archive      => $archive,
            filename     => basename($archive),
            site_name    => $manifest->{site_name} || '',
            created_at   => $manifest->{created_at} || '',
            file_count   => scalar keys %{ $manifest->{files} || {} },
            db_integrity => $integrity,
        };
        1;
    } or do {
        my $err = $@ || 'restore test failed';
        remove_tree($staging) if -d $staging;
        die $err;
    };

    remove_tree($staging) if -d $staging;
    return $result;
}

sub list_backups {
    my ($config, $db) = @_;
    return $db->dbh->selectall_arrayref(
        'SELECT * FROM backups ORDER BY created_at DESC, id DESC',
        { Slice => {} }
    );
}

sub archive_for_id {
    my ($config, $db, $id) = @_;
    my $row = $db->dbh->selectrow_hashref('SELECT * FROM backups WHERE id = ?', undef, $id);
    return undef unless $row;
    my $path = File::Spec->catfile($config->get('backup_dir'), $row->{filename});
    return -f $path ? $path : undef;
}

sub _copy_database {
    my ($db, $dest) = @_;
    make_path(dirname($dest)) unless -d dirname($dest);
    my $dbh = $db->dbh;
    if ($dbh->can('sqlite_backup_to_file')) {
        $dbh->sqlite_backup_to_file($dest);
        return;
    }
    _copy_file($db->{config}->get('db_path'), $dest);
}

sub _copy_dir {
    my ($source, $dest) = @_;
    return unless -d $source;
    find(
        sub {
            return if -d $File::Find::name;
            my $rel = File::Spec->abs2rel($File::Find::name, $source);
            my $target = File::Spec->catfile($dest, $rel);
            _copy_file($File::Find::name, $target);
        },
        $source
    );
}

sub _replace_dir {
    my ($source, $dest) = @_;
    die "restore source directory missing: $source" unless -d $source;
    remove_tree($dest) if -d $dest;
    make_path($dest);
    _copy_dir($source, $dest);
}

sub _copy_file {
    my ($source, $dest) = @_;
    die "source file missing: $source" unless -f $source;
    make_path(dirname($dest)) unless -d dirname($dest);
    copy($source, $dest) or die "cannot copy $source to $dest: $!";
}

sub _write_file {
    my ($path, $body) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _checksums {
    my ($root) = @_;
    my %files;
    find(
        sub {
            return if -d $File::Find::name;
            my $rel = File::Spec->abs2rel($File::Find::name, $root);
            $rel =~ s{\\}{/}g;
            return if $rel eq 'manifest.json';
            $files{$rel} = _sha256_file($File::Find::name);
        },
        $root
    );
    return \%files;
}

sub _verify_manifest {
    my ($staging) = @_;
    my $manifest_path = File::Spec->catfile($staging, 'manifest.json');
    open my $fh, '<', $manifest_path or die "cannot read manifest: $!";
    local $/;
    my $manifest = decode_json(<$fh>);
    close $fh;

    die "unsupported backup manifest" unless ($manifest->{version} || 0) == 1;
    my $files = $manifest->{files} || {};
    for my $rel (sort keys %{$files}) {
        die "invalid backup path: $rel" if $rel =~ m{(?:\A|/)\.\.(?:/|\z)};
        my $path = File::Spec->catfile($staging, split m{/}, $rel);
        die "backup file missing: $rel" unless -f $path;
        my $actual = _sha256_file($path);
        die "backup checksum mismatch: $rel" unless lc($actual) eq lc($files->{$rel});
    }
    return $manifest;
}

sub _sqlite_integrity_check {
    my ($path) = @_;
    require DBI;
    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$path",
        '',
        '',
        {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            sqlite_unicode => 1,
        }
    );
    my ($result) = $dbh->selectrow_array('PRAGMA integrity_check');
    $dbh->disconnect;
    die "backup database integrity check failed: $result" unless defined $result && $result eq 'ok';
    return $result;
}

sub _sha256_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    my $ctx = Digest::SHA->new(256);
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
}

sub _tar_create {
    my ($config, $archive, $staging) = @_;
    my $tar = $config->get('tar_tool') || 'tar';
    system $tar, '-czf', $archive, '-C', $staging, '.';
    die "tar create failed with status $?" if $? != 0 || !-f $archive;
}

sub _tar_extract {
    my ($config, $archive, $staging) = @_;
    my $tar = $config->get('tar_tool') || 'tar';
    system $tar, '-xzf', $archive, '-C', $staging;
    die "tar extract failed with status $?" if $? != 0;
}

sub _timestamp {
    my @t = localtime;
    return sprintf '%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

sub _unique_backup_paths {
    my ($backup_dir, $stamp) = @_;
    my $suffix = '';
    my $i = 1;
    while (1) {
        my $staging = File::Spec->catdir($backup_dir, ".staging-$stamp$suffix");
        my $archive = File::Spec->catfile($backup_dir, "desertcms-$stamp$suffix.tar.gz");
        return ($staging, $archive) if !-e $archive && !-d $staging;
        $i++;
        $suffix = "-$i";
    }
}

1;
