#!/usr/bin/env perl

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP qw(encode_json);
use lib "$FindBin::Bin/../lib";

use DesertCMS::Config;
use DesertCMS::Content;
use DesertCMS::DB;
use DesertCMS::Navigation;
use DesertCMS::Renderer;
use DesertCMS::Settings;
use DesertCMS::Version;

my %opt = (
    app_root => $ENV{DESERTCMS_APP_ROOT} || File::Spec->catdir($FindBin::Bin, '..'),
    release  => '',
);

GetOptionsFromArray(
    \@ARGV,
    'app-root=s' => \$opt{app_root},
    'release=s'  => \$opt{release},
) or die "usage: $0 [--app-root /usr/local/www/desertcms] [--release VERSION]\n";

$opt{release} = DesertCMS::Version::from_app_root($opt{app_root}, fallback => '1.0') if !length($opt{release} || '');

my $config = DesertCMS::Config->load;
my $db = DesertCMS::DB->new(config => $config);
$db->migrate;
my $content = DesertCMS::Content->new(config => $config, db => $db);

my $site_url = $config->get('site_url') || 'https://desertcms.com';
$site_url =~ s{/+\z}{};
my $downloads = _build_downloads($config, \%opt);

DesertCMS::Settings::set_many($config, $db, {
    site_name             => 'DesertCMS',
    site_description      => 'An OpenBSD-first CMS for durable publishing, private source assets, static public pages, and practical site operations.',
    site_meta_title       => 'DesertCMS - OpenBSD-first publishing CMS',
    site_meta_description => 'DesertCMS is a static-first Perl CMS for OpenBSD, slowcgi, SQLite, private source assets, simple admin workflows, and practical deployment.',
    theme_default_mode    => 'light',
    module_docs_enabled   => 1,
    module_contributor_requests_enabled => 0,
    docs_title            => 'Documentation',
    docs_intro            => 'Site Management and Technical documentation for running, operating, and extending DesertCMS.',
    docs_source_dir       => '',
});

my $docs = _upsert_page(
    $content,
    slug             => 'documentation',
    title            => 'Documentation',
    excerpt          => 'Site Management and Technical guides for running, operating, and extending DesertCMS.',
    meta_title       => 'DesertCMS Documentation',
    meta_description => 'Site owner guides, contributor-site management, architecture, OpenBSD 7.4 installation, operations, modules, media, and provider guidance for DesertCMS.',
    nav_label        => 'Documentation',
    nav_order        => 20,
    body_json        => _docs_body_json($downloads, $site_url),
);

my $download = _upsert_page(
    $content,
    slug             => 'download',
    title            => 'Download',
    excerpt          => 'Source and OpenBSD-ready runtime downloads for DesertCMS.',
    meta_title       => 'Download DesertCMS',
    meta_description => 'Download DesertCMS source and OpenBSD runtime bundles, with SHA-256 checksums for each release artifact.',
    nav_label        => 'Download',
    nav_order        => 30,
    body_json        => _download_body_json($downloads, $site_url),
);

my $home = _upsert_page(
    $content,
    slug             => 'home',
    title            => 'DesertCMS',
    excerpt          => 'OpenBSD-first CMS software for durable, static-first publishing sites.',
    meta_title       => 'DesertCMS - OpenBSD-first CMS',
    meta_description => 'DesertCMS is built for durable public sites, private source assets, non-technical admin workflows, and OpenBSD operations.',
    nav_label        => 'Home',
    nav_order        => 10,
    body_json        => _home_body_json($download->{id}),
);

DesertCMS::Settings::set_many($config, $db, {
    homepage_content_id  => $home->{id},
    module_docs_enabled => 1,
    module_contributor_requests_enabled => 0,
    docs_title          => 'Documentation',
    docs_intro          => 'Site Management and Technical documentation for running, operating, and extending DesertCMS.',
    docs_source_dir     => '',
});

DesertCMS::Navigation::replace_from_text(
    $config,
    $db,
    "Home | /\nDocumentation | /docs/\nDownload | /download/"
);

_remove_page($config, $db, 'shop');

for my $page ($docs, $download, $home) {
    $content->publish(id => $page->{id});
}
DesertCMS::Renderer::rebuild_indexes($config, $db);
_repair_public_root_ownership($config);

print "seeded DesertCMS marketing site\n";
print "homepage_id=$home->{id}\n";
for my $artifact (@{$downloads}) {
    print "download=$artifact->{url} bytes=$artifact->{bytes} sha256=$artifact->{sha256}\n";
}

sub _upsert_page {
    my ($content, %args) = @_;
    my $dbh = $content->{db}->dbh;
    my $existing = $dbh->selectrow_hashref(
        q{
            SELECT *
            FROM content_items
            WHERE type = 'page'
              AND slug = ?
              AND deleted_at IS NULL
            LIMIT 1
        },
        undef,
        $args{slug}
    );
    my $page = $content->save(
        id               => $existing ? $existing->{id} : undef,
        type             => 'page',
        title            => $args{title},
        slug             => $args{slug},
        excerpt          => $args{excerpt},
        meta_title       => $args{meta_title},
        meta_description => $args{meta_description},
        show_in_nav      => 0,
        nav_label        => $args{nav_label},
        nav_order        => $args{nav_order},
        body_json        => $args{body_json},
    );
    return $page;
}

sub _remove_page {
    my ($config, $db, $slug) = @_;
    my $ts = time;
    $db->dbh->do(
        q{
            UPDATE content_items
            SET status = 'draft',
                show_in_nav = 0,
                deleted_at = COALESCE(deleted_at, ?),
                updated_at = ?
            WHERE type = 'page'
              AND slug = ?
              AND deleted_at IS NULL
        },
        undef,
        $ts,
        $ts,
        $slug
    );

    my $public_root = $config->get('public_root') || '';
    my $path = File::Spec->catdir($public_root, $slug);
    remove_tree($path) if length $public_root && -d $path;
}

sub _build_downloads {
    my ($config, $opt) = @_;
    my $public_root = $config->get('public_root');
    my $downloads_dir = File::Spec->catdir($public_root, 'downloads');
    make_path($downloads_dir) unless -d $downloads_dir;

    my $release = $opt->{release};
    $release =~ s/[^0-9A-Za-z._-]/-/g;
    my $app_root = File::Spec->rel2abs($opt->{app_root});
    my @release_excludes = qw(
        .git .git/* .github .github/*
        .codex .codex/* .agents .agents/* .tools .tools/*
        data data/* dist dist/* local local/*
        *.tar.gz *.tgz *.zip *.sqlite *.sqlite-shm *.sqlite-wal *.log
        *.ps1 *.cmd *.bat *.exe *.dll
        .DS_Store Thumbs.db
    );

    my @artifacts = (
        {
            kind        => 'Source',
            filename    => "desertcms-source-$release.tar.gz",
            description => 'Full source tree with tests, docs, installer examples, templates, themes, and OpenBSD tooling.',
            items       => [qw(.gitignore LICENSE README.md VERSION admin bin docs etc install lib public sql t themes tools)],
            excludes    => \@release_excludes,
        },
        {
            kind        => 'OpenBSD runtime bundle',
            filename    => "desertcms-openbsd-runtime-$release.tar.gz",
            description => 'Ready-to-place application bundle for OpenBSD httpd, slowcgi, SQLite, and the included installer scripts.',
            items       => [qw(
                LICENSE README.md VERSION admin
                bin/desertcms.cgi bin/desertcms-maint.pl
                docs etc install lib public sql themes
                tools/check-local-assets.pl
                tools/openbsd-apply-font-packages.pl
                tools/openbsd-apply-site-queue.pl
                tools/openbsd-apply-upgrade.pl
                tools/openbsd-operations-worker.pl
                tools/openbsd-provision-site.pl
                tools/openbsd-register-existing-site.pl
                tools/openbsd-validate.pl
            )],
            excludes    => \@release_excludes,
        },
    );

    _remove_old_download_artifacts($downloads_dir, [ map { $_->{filename} } @artifacts ]);

    for my $artifact (@artifacts) {
        my $path = File::Spec->catfile($downloads_dir, $artifact->{filename});
        unlink $path if -f $path;
        my @items = grep { -e File::Spec->catfile($app_root, $_) } @{$artifact->{items}};
        die "no app files found under $app_root\n" unless @items;
        _write_release_archive($path, $app_root, \@items, $artifact->{excludes} || []);
        chmod 0644, $path;
        my $sha = _sha256_file($path);
        my $sha_path = "$path.sha256";
        _write_file($sha_path, "$sha  $artifact->{filename}\n");
        chmod 0644, $sha_path;
        $artifact->{path} = $path;
        $artifact->{url} = '/downloads/' . $artifact->{filename};
        $artifact->{sha_url} = $artifact->{url} . '.sha256';
        $artifact->{bytes} = -s $path;
        $artifact->{size_label} = _size_label($artifact->{bytes});
        $artifact->{sha256} = $sha;
    }

    return \@artifacts;
}

sub _remove_old_download_artifacts {
    my ($downloads_dir, $current) = @_;
    my %keep;
    for my $filename (@{$current || []}) {
        next unless defined $filename && length $filename;
        $keep{$filename} = 1;
        $keep{"$filename.sha256"} = 1;
    }
    opendir my $dh, $downloads_dir or die "cannot read downloads directory $downloads_dir: $!\n";
    while (defined(my $entry = readdir $dh)) {
        next if $entry eq '.' || $entry eq '..';
        next if $keep{$entry};
        next unless $entry =~ /\Adesertcms-(?:source|openbsd-runtime)-[0-9A-Za-z._-]+\.tar\.gz(?:\.sha256)?\z/;
        my $path = File::Spec->catfile($downloads_dir, $entry);
        unlink $path or die "cannot remove old download artifact $path: $!\n" if -f $path;
    }
    closedir $dh;
}

sub _write_release_archive {
    my ($path, $app_root, $items, $excludes) = @_;
    my $stage = tempdir('desertcms-release-XXXXXXXX', TMPDIR => 1, CLEANUP => 1);
    for my $item (@{$items || []}) {
        my $source = File::Spec->catfile($app_root, split m{/}, $item);
        next unless -e $source;
        my $target = File::Spec->catfile($stage, split m{/}, $item);
        _copy_release_item($source, $target, _clean_release_member($item), $excludes);
    }
    opendir my $dh, $stage or die "cannot read release staging directory $stage: $!\n";
    my @members = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    die "release archive staging produced no files\n" unless @members;
    system('tar', '-czf', $path, '-C', $stage, @members) == 0
        or die "tar failed for " . File::Spec->abs2rel($path) . "\n";
}

sub _copy_release_item {
    my ($source, $target, $relative, $excludes) = @_;
    return if _release_member_excluded($relative, $excludes);
    return if -l $source;
    if (-d $source) {
        make_path($target) unless -d $target;
        _copy_mode($source, $target);
        find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return if $File::Find::name eq $source;
                    my $child_relative = _clean_release_member(
                        File::Spec->catfile($relative, File::Spec->abs2rel($File::Find::name, $source))
                    );
                    if (_release_member_excluded($child_relative, $excludes)) {
                        $File::Find::prune = 1 if -d $File::Find::name;
                        return;
                    }
                    return if -l $File::Find::name;
                    my $child_target = File::Spec->catfile($target, File::Spec->abs2rel($File::Find::name, $source));
                    if (-d $File::Find::name) {
                        make_path($child_target) unless -d $child_target;
                        _copy_mode($File::Find::name, $child_target);
                    } elsif (-f $File::Find::name) {
                        make_path(dirname($child_target)) unless -d dirname($child_target);
                        copy($File::Find::name, $child_target)
                            or die "cannot copy $File::Find::name to $child_target: $!\n";
                        _copy_mode($File::Find::name, $child_target);
                    }
                },
            },
            $source
        );
    } elsif (-f $source) {
        make_path(dirname($target)) unless -d dirname($target);
        copy($source, $target) or die "cannot copy $source to $target: $!\n";
        _copy_mode($source, $target);
    }
}

sub _copy_mode {
    my ($source, $target) = @_;
    my @stat = stat($source);
    chmod($stat[2] & 07777, $target) if @stat;
}

sub _release_member_excluded {
    my ($relative, $patterns) = @_;
    $relative = _clean_release_member($relative);
    for my $pattern (@{$patterns || []}) {
        my $re = quotemeta(_clean_release_member($pattern));
        $re =~ s/\\\*/.*/g;
        return 1 if $relative =~ /\A$re\z/;
    }
    return 0;
}

sub _clean_release_member {
    my ($path) = @_;
    $path = '' unless defined $path;
    $path =~ s{\\}{/}g;
    $path =~ s{/+}{/}g;
    $path =~ s{\A\./}{};
    $path =~ s{/\z}{};
    return $path;
}

sub _home_body_json {
    my ($download_id) = @_;
    return encode_json([
        _text_block('<p><strong>DesertCMS is built for small teams and individual publishers.</strong> It provides a durable public site, a quiet admin experience, and deployment artifacts that make sense on OpenBSD.</p><p>The public side is static-first. The admin side is server-rendered Perl CGI through slowcgi. Source assets stay private; generated public files stay easy to serve, back up, and inspect.</p>', 'sans', 'large'),
        _heading('What It Is For'),
        _text_block('<ul><li>Photography, field archives, research collections, and small product sites that need more care than a generic blog.</li><li>Operators who want simple forms, clear publishing steps, and practical recovery tools instead of plugin-heavy admin sprawl.</li><li>OpenBSD deployments using httpd, slowcgi, SQLite, ACME certificates, pf, and plain filesystem backups.</li></ul>', 'sans', 'normal'),
        _heading('Highlights'),
        _text_block('<ul><li><strong>Static public output:</strong> published pages, discovery files, redirects, assets, and maps are written to the webroot.</li><li><strong>Private media sources:</strong> uploaded source assets live outside the served tree while public image derivatives are generated separately.</li><li><strong>Non-technical editing:</strong> visual page blocks, templates, navigation, redirects, site settings, backups, and media alt text are handled in the admin UI.</li><li><strong>OpenBSD operations:</strong> installer, httpd config, acme-client config, pf rules, rc.d service file, validation script, and queue worker are included.</li><li><strong>First-party features:</strong> analytics, comments, ratings, contributor sites, theme editing, maps, backups, and recovery tools are part of the system.</li></ul>', 'sans', 'normal'),
        _heading('Start Here'),
        { type => 'link', url => '/docs/', label => 'Documentation', description => 'Site Management and Technical guides for running, operating, and extending DesertCMS.' },
        { type => 'content_ref', target_id => int($download_id), style => 'card' },
        { type => 'quote', text => 'A CMS should make publishing safer and operating the site less mysterious.', citation => 'DesertCMS project note', align => 'left', font => 'mono', text_size => 'normal' },
    ]);
}

sub _repair_public_root_ownership {
    my ($config) = @_;
    return unless $> == 0;
    my $public_root = $config->get('public_root') || '';
    return unless length $public_root && -d $public_root;
    my @root_stat = stat($public_root);
    return unless @root_stat;
    my ($uid, $gid) = @root_stat[4, 5];
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                return if -l $path;
                chown $uid, $gid, $path
                    or die "cannot restore public-root ownership for $path: $!\n";
            },
        },
        $public_root
    );
}

sub _docs_body_json {
    my ($downloads, $site_url) = @_;
    return encode_json([
        _text_block('<p>Documentation is split into Site Management guides for people running sites and Technical guides for operators and developers. The generated /docs/ index shows both tracks.</p>', 'sans', 'large'),
        _heading('Site Management'),
        _text_block('<ul><li><a href="/docs/site-owner-guide/">Site Owner Guide</a> explains contributor product mode, pages, posts, media, design, features, billing, and Account / Help.</li><li><a href="/docs/content-design-and-media/">Content, Design, And Media</a> covers editing workflows, public design, private source assets, Resource Downloads, previews, search, and retention.</li><li><a href="/docs/managing-contributor-sites/">Managing Contributor Sites</a> covers requests, hosted sites, blueprints, service plans, provider inheritance, governance, and federated review.</li></ul>', 'sans', 'normal'),
        _heading('Technical'),
        _text_block('<ul><li><a href="/docs/technical-architecture/">Technical Architecture</a> explains the engine, storage, static renderer, capability policy, modules, media pipeline, and contributor mode.</li><li><a href="/docs/openbsd-74-install/">OpenBSD 7.4 Installation</a> is the supported production install path.</li><li><a href="/docs/creating-modules/">Creating Modules</a> explains first-party module definition, plan gates, capabilities, rendering, routes, schema, media, and tests.</li></ul>', 'sans', 'normal'),
        _heading('Quick Install'),
        _mono("perl install/openbsd-install.pl --dry-run --domain example.com --public-root-name example-site\n\ndoas perl install/openbsd-install.pl --domain example.com\n\ndoas perl /usr/local/www/desertcms/tools/openbsd-validate.pl --domain example.com"),
        _heading('Runtime Layout'),
        _mono("/usr/local/www/desertcms/          application code\n/etc/desertcms.conf                main instance config\n/var/desertcms/                    main instance data\n/var/desertcms/originals/          private source assets\n/var/desertcms/backups/            backup archives\n/var/www/htdocs/desertcms-site/    generated public site\n/var/www/acme/                     ACME challenge root\n/var/www/run/desertcms.sock        slowcgi socket"),
        _heading('Operations Cheat Sheet'),
        _mono("doas rcctl restart desertcms_slowcgi\n\ndoas httpd -n && doas rcctl reload httpd\n\ndoas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl rebuild'\n\ndoas su -m _desertcms -c 'env DESERTCMS_CONFIG=/etc/desertcms.conf perl /usr/local/www/desertcms/bin/desertcms-maint.pl backup'"),
        _heading('Downloads'),
        _text_block('<p>Use the Download page for release archives and checksums. The source archive is best for development. The OpenBSD runtime bundle is the operational package for a server install.</p>', 'sans', 'normal'),
        _download_link_block($downloads->[0], $site_url),
        _download_link_block($downloads->[1], $site_url),
    ]);
}

sub _download_body_json {
    my ($downloads, $site_url) = @_;
    my $runtime_filename = $downloads->[1]{filename};
    return encode_json([
        _text_block('<p>Download the current DesertCMS release artifacts. Source is available for development and review; the OpenBSD runtime bundle is the practical server-side install and admin-upgrade artifact.</p><p>DesertCMS is a Perl CGI application. The runtime bundle packages the app, scripts, default theme, docs, and OpenBSD operational files for server installs and admin upgrades.</p>', 'sans', 'large'),
        _heading('Release Artifacts'),
        _artifact_text($downloads->[0]),
        _download_link_block($downloads->[0], $site_url),
        _checksum_link_block($downloads->[0], $site_url),
        _artifact_text($downloads->[1]),
        _download_link_block($downloads->[1], $site_url),
        _checksum_link_block($downloads->[1], $site_url),
        _heading('Install Path'),
        _mono("Initial install:\n\ntar -xzf $runtime_filename\n\ncd desertcms\n\nperl install/openbsd-install.pl --dry-run --domain example.com --public-root-name example-site\n\nExisting install:\n\nAdmin Settings > Upgrade DesertCMS > upload this runtime tar.gz"),
        _text_block('<p>Always run the dry-run first. It prints the DNS, TLS, firewall, filesystem, package, service, and CMS initialization work before touching the server.</p>', 'sans', 'normal'),
    ]);
}

sub _artifact_text {
    my ($artifact) = @_;
    return _text_block(
        '<p><strong>' . _html($artifact->{kind}) . ':</strong> '
        . _html($artifact->{description})
        . ' Size: '
        . _html($artifact->{size_label})
        . '. SHA-256: '
        . _html($artifact->{sha256})
        . '</p>',
        'sans',
        'normal'
    );
}

sub _download_link_block {
    my ($artifact, $site_url) = @_;
    return {
        type => 'link',
        url => $site_url . $artifact->{url},
        label => 'Download ' . $artifact->{kind},
        description => $artifact->{filename} . ' - ' . $artifact->{size_label},
    };
}

sub _checksum_link_block {
    my ($artifact, $site_url) = @_;
    return {
        type => 'link',
        url => $site_url . $artifact->{sha_url},
        label => 'SHA-256 checksum for ' . $artifact->{kind},
        description => $artifact->{filename} . '.sha256',
    };
}

sub _heading {
    my ($text) = @_;
    return {
        type      => 'heading',
        text      => $text,
        level     => 2,
        align     => 'left',
        font      => 'sans',
        text_size => 'normal',
    };
}

sub _text_block {
    my ($html, $font, $size) = @_;
    return {
        type      => 'text',
        text      => _plain($html),
        html      => $html,
        align     => 'left',
        font      => $font || 'sans',
        text_size => $size || 'normal',
    };
}

sub _mono {
    my ($text) = @_;
    return {
        type      => 'text',
        text      => $text,
        html      => _plain_to_html($text),
        align     => 'left',
        font      => 'mono',
        text_size => 'small',
    };
}

sub _plain_to_html {
    my ($text) = @_;
    $text = '' unless defined $text;
    my @paras;
    for my $paragraph (split /\n\s*\n/, $text) {
        $paragraph =~ s/^\s+|\s+$//g;
        next unless length $paragraph;
        my $safe = _html($paragraph);
        $safe =~ s/\n/<br>/g;
        push @paras, "<p>$safe</p>";
    }
    return join '', @paras;
}

sub _plain {
    my ($html) = @_;
    $html = '' unless defined $html;
    $html =~ s{<br\s*/?>}{\n}gi;
    $html =~ s{</(?:p|li|h[1-6])>}{\n}gi;
    $html =~ s{<[^>]+>}{ }g;
    $html =~ s/&lt;/</g;
    $html =~ s/&gt;/>/g;
    $html =~ s/&quot;/"/g;
    $html =~ s/&#39;/'/g;
    $html =~ s/&amp;/&/g;
    $html =~ s/[ \t]+/ /g;
    $html =~ s/\n\s+/\n/g;
    $html =~ s/\n{3,}/\n\n/g;
    $html =~ s/^\s+|\s+$//g;
    return $html;
}

sub _sha256_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    my $ctx = Digest::SHA->new(256);
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
}

sub _write_file {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!\n";
    print {$fh} $body;
    close $fh;
}

sub _size_label {
    my ($bytes) = @_;
    $bytes ||= 0;
    return sprintf('%.1f MB', $bytes / 1_048_576) if $bytes >= 1_048_576;
    return sprintf('%.1f KB', $bytes / 1024) if $bytes >= 1024;
    return "$bytes bytes";
}

sub _html {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}
