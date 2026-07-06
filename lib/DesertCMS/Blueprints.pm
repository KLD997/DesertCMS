package DesertCMS::Blueprints;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use DesertCMS::SiteTheme;
use DesertCMS::Util qw(now slugify);

my @VERTICAL_CATEGORIES = (
    { id => 'photographer', label => 'Photographer' },
    { id => 'artist-portfolio', label => 'Artist portfolio' },
    { id => 'writer-blog', label => 'Writer/blog' },
    { id => 'small-business', label => 'Small business' },
    { id => 'local-archive', label => 'Local archive' },
    { id => 'event-community-site', label => 'Event/community site' },
    { id => 'shop-catalog', label => 'Shop/catalog' },
    { id => 'documentation-resource-hub', label => 'Docs / Resource Hub' },
);

my %VERTICAL_LABEL = map { $_->{id} => $_->{label} } @VERTICAL_CATEGORIES;

my @BUILTIN_BLUEPRINTS = (
    {
        name => 'Photographer Portfolio',
        slug => 'photographer-portfolio',
        category => 'photographer',
        description => 'Portfolio-first site for photographers with Showcase, map context, writing, and contact pages.',
        module_map_enabled => 1,
        module_shop_enabled => 0,
        module_gallery_enabled => 1,
        module_forms_enabled => 1,
        module_contributor_requests_enabled => 0,
        module_docs_enabled => 0,
        module_directory_enabled => 0,
        module_bookings_enabled => 1,
        module_membership_enabled => 0,
        module_newsletter_enabled => 0,
        module_donations_enabled => 0,
        module_testimonials_enabled => 1,
        theme_default_mode => 'light',
        theme_light_preset => 'light-archive',
        theme_dark_preset => 'dark-archive',
        shop_enabled => 0,
        media_quota_mb => 512,
        post_quota => 100,
        page_quota => 20,
        allow_master_gallery => 1,
        allow_master_posts => 1,
        site_meta_title => '',
        site_meta_description => '',
        default_pages => [
            { title => 'Portfolio', slug => 'portfolio', show_in_nav => 1 },
            { title => 'About', slug => 'about', show_in_nav => 1 },
            { title => 'Contact', slug => 'contact', show_in_nav => 1 },
        ],
        is_default => 1,
    },
    {
        name => 'Artist Portfolio',
        slug => 'artist-portfolio',
        category => 'artist-portfolio',
        description => 'Visual portfolio for artists, illustrators, designers, and makers.',
        module_map_enabled => 0,
        module_shop_enabled => 0,
        module_gallery_enabled => 1,
        module_forms_enabled => 1,
        module_contributor_requests_enabled => 0,
        module_docs_enabled => 0,
        module_directory_enabled => 0,
        module_bookings_enabled => 1,
        module_membership_enabled => 0,
        module_newsletter_enabled => 0,
        module_donations_enabled => 1,
        module_testimonials_enabled => 1,
        theme_default_mode => 'light',
        theme_light_preset => 'light-coast',
        theme_dark_preset => 'dark-forest',
        shop_enabled => 0,
        media_quota_mb => 512,
        post_quota => 60,
        page_quota => 20,
        allow_master_gallery => 1,
        allow_master_posts => 1,
        site_meta_title => '',
        site_meta_description => '',
        default_pages => [
            { title => 'Work', slug => 'work', show_in_nav => 1 },
            { title => 'About', slug => 'about', show_in_nav => 1 },
            { title => 'Contact', slug => 'contact', show_in_nav => 1 },
        ],
    },
    {
        name => 'Writer Blog',
        slug => 'writer-blog',
        category => 'writer-blog',
        description => 'Writing-centered site for essays, journals, newsletters, and personal publishing.',
        module_map_enabled => 0,
        module_shop_enabled => 0,
        module_gallery_enabled => 0,
        module_forms_enabled => 1,
        module_contributor_requests_enabled => 0,
        module_docs_enabled => 0,
        module_directory_enabled => 0,
        module_bookings_enabled => 0,
        module_membership_enabled => 1,
        module_newsletter_enabled => 1,
        module_donations_enabled => 0,
        module_testimonials_enabled => 0,
        theme_default_mode => 'light',
        theme_light_preset => 'light-archive',
        theme_dark_preset => 'dark-archive',
        shop_enabled => 0,
        media_quota_mb => 256,
        post_quota => 500,
        page_quota => 20,
        allow_master_gallery => 0,
        allow_master_posts => 1,
        site_meta_title => '',
        site_meta_description => '',
        default_pages => [
            { title => 'Start Here', slug => 'start-here', show_in_nav => 1 },
            { title => 'Archive', slug => 'archive', show_in_nav => 1 },
            { title => 'Contact', slug => 'contact', show_in_nav => 1 },
        ],
    },
    {
        name => 'Small Business',
        slug => 'small-business',
        category => 'small-business',
        description => 'Simple business site for services, team information, updates, and customer inquiries.',
        module_map_enabled => 1,
        module_shop_enabled => 0,
        module_gallery_enabled => 0,
        module_forms_enabled => 1,
        module_contributor_requests_enabled => 0,
        module_docs_enabled => 0,
        module_directory_enabled => 1,
        module_bookings_enabled => 1,
        module_membership_enabled => 0,
        module_newsletter_enabled => 1,
        module_donations_enabled => 1,
        module_testimonials_enabled => 1,
        theme_default_mode => 'light',
        theme_light_preset => 'light-coast',
        theme_dark_preset => 'dark-forest',
        shop_enabled => 0,
        media_quota_mb => 256,
        post_quota => 100,
        page_quota => 30,
        allow_master_gallery => 0,
        allow_master_posts => 1,
        site_meta_title => '',
        site_meta_description => '',
        default_pages => [
            { title => 'Services', slug => 'services', show_in_nav => 1 },
            { title => 'About', slug => 'about', show_in_nav => 1 },
            { title => 'Contact', slug => 'contact', show_in_nav => 1 },
        ],
    },
    {
        name => 'Local Archive',
        slug => 'local-archive',
        category => 'local-archive',
        description => 'Community archive for collections, locations, stories, and public contribution workflows.',
        module_map_enabled => 1,
        module_shop_enabled => 0,
        module_gallery_enabled => 1,
        module_forms_enabled => 1,
        module_contributor_requests_enabled => 1,
        module_docs_enabled => 0,
        module_directory_enabled => 1,
        module_bookings_enabled => 0,
        module_membership_enabled => 1,
        module_newsletter_enabled => 1,
        module_donations_enabled => 1,
        module_testimonials_enabled => 0,
        theme_default_mode => 'light',
        theme_light_preset => 'light-archive',
        theme_dark_preset => 'dark-archive',
        shop_enabled => 0,
        media_quota_mb => 1024,
        post_quota => 500,
        page_quota => 40,
        allow_master_gallery => 1,
        allow_master_posts => 1,
        site_meta_title => '',
        site_meta_description => '',
        default_pages => [
            { title => 'Collections', slug => 'collections', show_in_nav => 1 },
            { title => 'About', slug => 'about', show_in_nav => 1 },
            { title => 'Contribute', slug => 'contribute', show_in_nav => 1 },
            { title => 'Contact', slug => 'contact', show_in_nav => 1 },
        ],
    },
    {
        name => 'Event Community Site',
        slug => 'event-community-site',
        category => 'event-community-site',
        description => 'Event or community hub for schedules, announcements, location details, and signups.',
        module_map_enabled => 1,
        module_shop_enabled => 0,
        module_gallery_enabled => 1,
        module_forms_enabled => 1,
        module_contributor_requests_enabled => 0,
        module_docs_enabled => 0,
        module_directory_enabled => 1,
        module_bookings_enabled => 1,
        module_membership_enabled => 1,
        module_newsletter_enabled => 1,
        module_donations_enabled => 1,
        module_testimonials_enabled => 1,
        theme_default_mode => 'light',
        theme_light_preset => 'light-coast',
        theme_dark_preset => 'dark-archive',
        shop_enabled => 0,
        media_quota_mb => 512,
        post_quota => 200,
        page_quota => 30,
        allow_master_gallery => 1,
        allow_master_posts => 1,
        site_meta_title => '',
        site_meta_description => '',
        default_pages => [
            { title => 'Schedule', slug => 'schedule', show_in_nav => 1 },
            { title => 'Location', slug => 'location', show_in_nav => 1 },
            { title => 'Contact', slug => 'contact', show_in_nav => 1 },
        ],
    },
    {
        name => 'Shop Catalog',
        slug => 'shop-catalog',
        category => 'shop-catalog',
        description => 'Catalog-first site for products, portfolio samples, editions, or paid downloads.',
        module_map_enabled => 0,
        module_shop_enabled => 1,
        module_gallery_enabled => 1,
        module_forms_enabled => 1,
        module_contributor_requests_enabled => 0,
        module_docs_enabled => 0,
        module_directory_enabled => 1,
        module_bookings_enabled => 0,
        module_membership_enabled => 0,
        module_newsletter_enabled => 1,
        module_donations_enabled => 0,
        module_testimonials_enabled => 1,
        theme_default_mode => 'light',
        theme_light_preset => 'light-coast',
        theme_dark_preset => 'dark-forest',
        shop_enabled => 1,
        media_quota_mb => 1024,
        post_quota => 100,
        page_quota => 30,
        allow_master_gallery => 1,
        allow_master_posts => 1,
        site_meta_title => '',
        site_meta_description => '',
        default_pages => [
            { title => 'Catalog', slug => 'catalog', show_in_nav => 1 },
            { title => 'About', slug => 'about', show_in_nav => 1 },
            { title => 'Contact', slug => 'contact', show_in_nav => 1 },
        ],
    },
    {
        name => 'Docs / Resource Hub',
        slug => 'documentation-resource-hub',
        category => 'documentation-resource-hub',
        description => 'Resource site for documentation, guides, local archives, member materials, FAQs, help-center articles, references, and downloads.',
        module_map_enabled => 0,
        module_shop_enabled => 0,
        module_gallery_enabled => 0,
        module_forms_enabled => 1,
        module_contributor_requests_enabled => 0,
        module_docs_enabled => 1,
        module_directory_enabled => 1,
        module_bookings_enabled => 0,
        module_membership_enabled => 1,
        module_newsletter_enabled => 1,
        module_donations_enabled => 1,
        module_testimonials_enabled => 0,
        theme_default_mode => 'light',
        theme_light_preset => 'light-archive',
        theme_dark_preset => 'dark-archive',
        shop_enabled => 0,
        media_quota_mb => 512,
        post_quota => 150,
        page_quota => 100,
        allow_master_gallery => 0,
        allow_master_posts => 1,
        site_meta_title => '',
        site_meta_description => '',
        default_pages => [
            { title => 'Start Here', slug => 'start-here', show_in_nav => 1 },
            { title => 'Resources', slug => 'resources', show_in_nav => 1 },
            { title => 'Contact', slug => 'contact', show_in_nav => 1 },
        ],
    },
);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub ensure_default {
    my ($self) = @_;
    my $dbh = $self->{db}->dbh;
    my ($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM contributor_blueprints');
    my $ts = now();
    $self->_migrate_legacy_standard_blueprint($ts) if $count;
    $self->_ensure_builtin_blueprints($ts, had_existing => $count ? 1 : 0);

    my ($default_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM contributor_blueprints WHERE is_default = 1');
    return if $default_count;

    my ($id) = $dbh->selectrow_array('SELECT id FROM contributor_blueprints ORDER BY id ASC LIMIT 1');
    $dbh->do('UPDATE contributor_blueprints SET is_default = 1, updated_at = ? WHERE id = ?', undef, $ts, $id)
        if $id;
}

sub vertical_categories {
    return [ map { { %{$_} } } @VERTICAL_CATEGORIES ];
}

sub vertical_label {
    my ($category) = @_;
    $category = _category($category);
    return $VERTICAL_LABEL{$category} || $VERTICAL_LABEL{photographer};
}

sub list {
    my ($self) = @_;
    $self->ensure_default;
    return $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM contributor_blueprints
            ORDER BY is_default DESC, category ASC, name ASC, id ASC
        },
        { Slice => {} }
    );
}

sub get {
    my ($self, $id) = @_;
    $self->ensure_default;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM contributor_blueprints WHERE id = ?',
        undef,
        $id
    );
}

sub default_blueprint {
    my ($self) = @_;
    $self->ensure_default;
    return $self->{db}->dbh->selectrow_hashref(
        q{
            SELECT *
            FROM contributor_blueprints
            ORDER BY is_default DESC, id ASC
            LIMIT 1
        }
    );
}

sub select_blueprint {
    my ($self, $id) = @_;
    my $blueprint = $self->get($id);
    return $blueprint if $blueprint;
    return $self->default_blueprint;
}

sub save {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $name = _clean_text($args{name}, 120);
    die "blueprint name is required" unless length $name;
    my $slug = slugify(_clean_text($args{slug}, 120) || $name);
    my $description = _clean_text($args{description}, 500);
    my $category = _category($args{category});
    my $theme_mode = ($args{theme_default_mode} || '') eq 'dark' ? 'dark' : 'light';
    my $light = _theme_preset($args{theme_light_preset}, 'light');
    my $dark = _theme_preset($args{theme_dark_preset}, 'dark');
    my $shop = _bool($args{module_shop_enabled}) || _bool($args{shop_enabled}) ? 1 : 0;
    my $social = _bool($args{module_social_enabled});
    my $accounts = _bool($args{module_accounts_enabled}) || $social ? 1 : 0;
    my $pages_json = exists $args{default_pages_json}
        ? _clean_default_pages_json($args{default_pages_json})
        : encode_json(_parse_default_pages_text($args{default_pages_text}));
    my $ts = now();
    my %values = (
        name => $name,
        slug => $slug,
        description => $description,
        category => $category,
        module_posts_enabled => exists $args{module_posts_enabled} ? _bool($args{module_posts_enabled}) : 1,
        module_map_enabled => _bool($args{module_map_enabled}),
        module_shop_enabled => $shop,
        module_gallery_enabled => _bool($args{module_gallery_enabled}),
        module_forms_enabled => _bool($args{module_forms_enabled}),
        module_contributor_requests_enabled => _bool($args{module_contributor_requests_enabled}),
        module_docs_enabled => _bool($args{module_docs_enabled}),
        module_directory_enabled => _bool($args{module_directory_enabled}),
        module_bookings_enabled => _bool($args{module_bookings_enabled}),
        module_membership_enabled => _bool($args{module_membership_enabled}),
        module_newsletter_enabled => _bool($args{module_newsletter_enabled}),
        module_donations_enabled => _bool($args{module_donations_enabled}),
        module_testimonials_enabled => _bool($args{module_testimonials_enabled}),
        module_accounts_enabled => $accounts,
        module_live_streaming_enabled => _bool($args{module_live_streaming_enabled}),
        module_forums_enabled => _bool($args{module_forums_enabled}),
        module_social_enabled => $social,
        module_notifications_enabled => exists $args{module_notifications_enabled} ? _bool($args{module_notifications_enabled}) : 1,
        module_security_center_enabled => exists $args{module_security_center_enabled} ? _bool($args{module_security_center_enabled}) : 1,
        theme_default_mode => $theme_mode,
        theme_light_preset => $light,
        theme_dark_preset => $dark,
        shop_enabled => $shop,
        media_quota_mb => _quota($args{media_quota_mb}, 512, 1, 102400),
        post_quota => _quota($args{post_quota}, 100, 0, 100000),
        page_quota => _quota($args{page_quota}, 20, 0, 100000),
        allow_master_gallery => _bool($args{allow_master_gallery}),
        allow_master_posts => _bool($args{allow_master_posts}),
        site_meta_title => _clean_text($args{site_meta_title}, 160),
        site_meta_description => _clean_text($args{site_meta_description}, 300),
        default_pages_json => $pages_json,
    );

    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        if ($id > 0 && $self->get($id)) {
            $dbh->do(
                q{
                    UPDATE contributor_blueprints
                    SET name = ?, slug = ?, description = ?, category = ?,
                        module_posts_enabled = ?, module_map_enabled = ?, module_shop_enabled = ?, module_gallery_enabled = ?,
                        module_forms_enabled = ?, module_contributor_requests_enabled = ?, module_docs_enabled = ?,
                        module_directory_enabled = ?, module_bookings_enabled = ?, module_membership_enabled = ?,
                        module_newsletter_enabled = ?, module_donations_enabled = ?, module_testimonials_enabled = ?,
                        module_accounts_enabled = ?, module_live_streaming_enabled = ?, module_forums_enabled = ?,
                        module_social_enabled = ?, module_notifications_enabled = ?, module_security_center_enabled = ?,
                        theme_default_mode = ?, theme_light_preset = ?, theme_dark_preset = ?,
                        shop_enabled = ?, media_quota_mb = ?, post_quota = ?, page_quota = ?,
                        allow_master_gallery = ?, allow_master_posts = ?,
                        site_meta_title = ?, site_meta_description = ?, default_pages_json = ?,
                        updated_at = ?
                    WHERE id = ?
                },
                undef,
                @values{qw(
                    name slug description category
                    module_posts_enabled module_map_enabled module_shop_enabled module_gallery_enabled
                    module_forms_enabled module_contributor_requests_enabled module_docs_enabled
                    module_directory_enabled module_bookings_enabled module_membership_enabled module_newsletter_enabled module_donations_enabled module_testimonials_enabled
                    module_accounts_enabled module_live_streaming_enabled module_forums_enabled module_social_enabled module_notifications_enabled module_security_center_enabled
                    theme_default_mode theme_light_preset theme_dark_preset
                    shop_enabled media_quota_mb post_quota page_quota
                    allow_master_gallery allow_master_posts
                    site_meta_title site_meta_description default_pages_json
                )},
                $ts,
                $id
            );
        } else {
            $dbh->do(
                q{
                    INSERT INTO contributor_blueprints
                        (name, slug, description, category,
                         module_posts_enabled, module_map_enabled, module_shop_enabled, module_gallery_enabled,
                         module_forms_enabled, module_contributor_requests_enabled, module_docs_enabled,
                         module_directory_enabled, module_bookings_enabled, module_membership_enabled, module_newsletter_enabled, module_donations_enabled, module_testimonials_enabled,
                         module_accounts_enabled, module_live_streaming_enabled, module_forums_enabled,
                         module_social_enabled, module_notifications_enabled, module_security_center_enabled,
                         theme_default_mode, theme_light_preset, theme_dark_preset,
                         shop_enabled, media_quota_mb, post_quota, page_quota,
                         allow_master_gallery, allow_master_posts,
                         site_meta_title, site_meta_description, default_pages_json,
                         is_default, created_at, updated_at)
                    VALUES
                        (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                },
                undef,
                @values{qw(
                    name slug description category
                    module_posts_enabled module_map_enabled module_shop_enabled module_gallery_enabled
                    module_forms_enabled module_contributor_requests_enabled module_docs_enabled
                    module_directory_enabled module_bookings_enabled module_membership_enabled module_newsletter_enabled module_donations_enabled module_testimonials_enabled
                    module_accounts_enabled module_live_streaming_enabled module_forums_enabled module_social_enabled module_notifications_enabled module_security_center_enabled
                    theme_default_mode theme_light_preset theme_dark_preset
                    shop_enabled media_quota_mb post_quota page_quota
                    allow_master_gallery allow_master_posts
                    site_meta_title site_meta_description default_pages_json
                )},
                $ts,
                $ts
            );
            $id = int($dbh->sqlite_last_insert_rowid);
        }
        $self->_set_default_locked($id) if _bool($args{is_default});
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown blueprint save failure';
        eval { $dbh->rollback };
        die $err;
    };

    $self->ensure_default;
    return $self->get($id);
}

sub set_default {
    my ($self, $id) = @_;
    $id = int($id || 0);
    die "blueprint id is required" unless $id > 0;
    die "blueprint not found" unless $self->get($id);
    my $dbh = $self->{db}->dbh;
    $dbh->begin_work;
    eval {
        $self->_set_default_locked($id);
        $dbh->commit;
        1;
    } or do {
        my $err = $@ || 'unknown default blueprint failure';
        eval { $dbh->rollback };
        die $err;
    };
    return $self->get($id);
}

sub snapshot {
    my ($self, $blueprint) = @_;
    $blueprint ||= $self->default_blueprint;
    die "blueprint is required" unless $blueprint && $blueprint->{id};
    my $pages = eval { decode_json($blueprint->{default_pages_json} || '[]') } || [];
    return {
        schema_version => 1,
        id => int($blueprint->{id}),
        name => $blueprint->{name} || '',
        slug => $blueprint->{slug} || '',
        description => $blueprint->{description} || '',
        category => _category($blueprint->{category}),
        category_label => vertical_label($blueprint->{category}),
        module_posts_enabled => _bool($blueprint->{module_posts_enabled}),
        module_map_enabled => _bool($blueprint->{module_map_enabled}),
        module_shop_enabled => _bool($blueprint->{module_shop_enabled}),
        module_gallery_enabled => _bool($blueprint->{module_gallery_enabled}),
        module_forms_enabled => _bool($blueprint->{module_forms_enabled}),
        module_contributor_requests_enabled => _bool($blueprint->{module_contributor_requests_enabled}),
        module_docs_enabled => _bool($blueprint->{module_docs_enabled}),
        module_directory_enabled => _bool($blueprint->{module_directory_enabled}),
        module_bookings_enabled => _bool($blueprint->{module_bookings_enabled}),
        module_membership_enabled => _bool($blueprint->{module_membership_enabled}),
        module_newsletter_enabled => _bool($blueprint->{module_newsletter_enabled}),
        module_donations_enabled => _bool($blueprint->{module_donations_enabled}),
        module_testimonials_enabled => _bool($blueprint->{module_testimonials_enabled}),
        module_accounts_enabled => _bool($blueprint->{module_accounts_enabled}) || _bool($blueprint->{module_social_enabled}) ? 1 : 0,
        module_live_streaming_enabled => _bool($blueprint->{module_live_streaming_enabled}),
        module_forums_enabled => _bool($blueprint->{module_forums_enabled}),
        module_social_enabled => _bool($blueprint->{module_social_enabled}),
        module_notifications_enabled => _bool($blueprint->{module_notifications_enabled}),
        module_security_center_enabled => _bool($blueprint->{module_security_center_enabled}),
        theme_default_mode => ($blueprint->{theme_default_mode} || '') eq 'dark' ? 'dark' : 'light',
        theme_light_preset => _theme_preset($blueprint->{theme_light_preset}, 'light'),
        theme_dark_preset => _theme_preset($blueprint->{theme_dark_preset}, 'dark'),
        shop_enabled => _bool($blueprint->{shop_enabled}),
        media_quota_mb => _quota($blueprint->{media_quota_mb}, 512, 1, 102400),
        post_quota => _quota($blueprint->{post_quota}, 100, 0, 100000),
        page_quota => _quota($blueprint->{page_quota}, 20, 0, 100000),
        allow_master_gallery => _bool($blueprint->{allow_master_gallery}),
        allow_master_posts => _bool($blueprint->{allow_master_posts}),
        site_meta_title => _clean_text($blueprint->{site_meta_title}, 160),
        site_meta_description => _clean_text($blueprint->{site_meta_description}, 300),
        default_pages => _clean_default_pages($pages),
    };
}

sub settings_from_snapshot {
    my ($snapshot) = @_;
    $snapshot ||= {};
    my $shop = _bool($snapshot->{module_shop_enabled}) || _bool($snapshot->{shop_enabled}) ? 1 : 0;
    my $social = _bool($snapshot->{module_social_enabled});
    my $accounts = _bool($snapshot->{module_accounts_enabled}) || $social ? 1 : 0;
    return {
        module_posts_enabled => exists $snapshot->{module_posts_enabled} ? _bool($snapshot->{module_posts_enabled}) : 1,
        module_map_enabled => _bool($snapshot->{module_map_enabled}),
        module_shop_enabled => $shop,
        module_gallery_enabled => _bool($snapshot->{module_gallery_enabled}),
        module_forms_enabled => _bool($snapshot->{module_forms_enabled}),
        module_contributor_requests_enabled => _bool($snapshot->{module_contributor_requests_enabled}),
        module_docs_enabled => _bool($snapshot->{module_docs_enabled}),
        module_directory_enabled => _bool($snapshot->{module_directory_enabled}),
        module_bookings_enabled => _bool($snapshot->{module_bookings_enabled}),
        module_membership_enabled => _bool($snapshot->{module_membership_enabled}),
        module_newsletter_enabled => _bool($snapshot->{module_newsletter_enabled}),
        module_donations_enabled => _bool($snapshot->{module_donations_enabled}),
        module_testimonials_enabled => _bool($snapshot->{module_testimonials_enabled}),
        module_accounts_enabled => $accounts,
        module_live_streaming_enabled => _bool($snapshot->{module_live_streaming_enabled}),
        module_forums_enabled => _bool($snapshot->{module_forums_enabled}),
        module_social_enabled => $social,
        module_notifications_enabled => exists $snapshot->{module_notifications_enabled} ? _bool($snapshot->{module_notifications_enabled}) : 1,
        module_security_center_enabled => exists $snapshot->{module_security_center_enabled} ? _bool($snapshot->{module_security_center_enabled}) : 1,
        shop_enabled => $shop,
        theme_default_mode => ($snapshot->{theme_default_mode} || '') eq 'dark' ? 'dark' : 'light',
        theme_light_preset => _theme_preset($snapshot->{theme_light_preset}, 'light'),
        theme_dark_preset => _theme_preset($snapshot->{theme_dark_preset}, 'dark'),
        theme_preset => ($snapshot->{theme_default_mode} || '') eq 'dark'
            ? _theme_preset($snapshot->{theme_dark_preset}, 'dark')
            : _theme_preset($snapshot->{theme_light_preset}, 'light'),
        site_meta_title => _clean_text($snapshot->{site_meta_title}, 160),
        site_meta_description => _clean_text($snapshot->{site_meta_description}, 300),
        contributor_blueprint_name => _clean_text($snapshot->{name}, 120),
        contributor_blueprint_category => _category($snapshot->{category}),
        contributor_blueprint_label => vertical_label($snapshot->{category}),
        contributor_media_quota_mb => _quota($snapshot->{media_quota_mb}, 512, 1, 102400),
        contributor_post_quota => _quota($snapshot->{post_quota}, 100, 0, 100000),
        contributor_page_quota => _quota($snapshot->{page_quota}, 20, 0, 100000),
    };
}

sub seed_default_pages {
    my ($class, $config, $db, $snapshot, %args) = @_;
    my $pages = _clean_default_pages($snapshot->{default_pages} || []);
    return 0 unless @{$pages};

    require DesertCMS::Content;
    require DesertCMS::Renderer;
    my $content = DesertCMS::Content->new(config => $config, db => $db);
    my $existing = $db->dbh->selectall_arrayref(
        q{
            SELECT slug
            FROM content_items
            WHERE type = 'page'
              AND deleted_at IS NULL
        },
        { Slice => {} }
    );
    my %existing = map { ($_->{slug} || '') => 1 } @{$existing};
    my $created = 0;
    for my $page (@{$pages}) {
        next if $existing{$page->{slug}};
        my $body_json = encode_json([
            { type => 'heading', text => $page->{title} },
            { type => 'text', html => '<p>' . _html($page->{title}) . '</p>' },
        ]);
        my $item = $content->save(
            type => 'page',
            title => $page->{title},
            slug => $page->{slug},
            body_json => $body_json,
            show_in_nav => $page->{show_in_nav} ? 1 : 0,
            nav_label => $page->{title},
            nav_order => 100 + $created,
        );
        if ($args{defer_publication}) {
            my $html = DesertCMS::Renderer::render_item($config, $item, $db);
            my $ts = now();
            $db->dbh->do(
                q{
                    UPDATE content_items
                    SET status = 'published', published_at = ?, updated_at = ?, published_html = ?
                    WHERE id = ?
                },
                undef,
                $ts,
                $ts,
                $html,
                $item->{id}
            );
        } else {
            $content->publish(id => $item->{id});
        }
        $existing{$item->{slug}} = 1;
        $created++;
    }
    return $created;
}

sub default_pages_text {
    my ($blueprint) = @_;
    my $pages = eval { decode_json($blueprint->{default_pages_json} || '[]') } || [];
    my @lines;
    for my $page (@{_clean_default_pages($pages)}) {
        push @lines, join('|', $page->{title}, $page->{slug}, $page->{show_in_nav} ? 'nav' : 'hidden');
    }
    return join "\n", @lines;
}

sub _ensure_builtin_blueprints {
    my ($self, $ts, %args) = @_;
    my $dbh = $self->{db}->dbh;
    my $had_existing = $args{had_existing} ? 1 : 0;
    my $rows = $dbh->selectall_arrayref('SELECT slug, category FROM contributor_blueprints', { Slice => {} });
    my %existing = map { ($_->{slug} || '') => 1 } @{$rows};
    my %existing_category = map { ($_->{slug} || '') => ($_->{category} || '') } @{$rows};
    for my $preset (@BUILTIN_BLUEPRINTS) {
        my $slug = $preset->{slug};
        my $category = _category($preset->{category});
        if ($existing{$slug}) {
            if (!$existing_category{$slug}) {
                $dbh->do(
                    'UPDATE contributor_blueprints SET category = ?, updated_at = ? WHERE slug = ?',
                    undef,
                    $category,
                    $ts,
                    $slug
                );
            }
            next;
        }
        $dbh->do(
            q{
                INSERT INTO contributor_blueprints
                    (name, slug, description, category,
                     module_map_enabled, module_shop_enabled, module_gallery_enabled,
                     module_forms_enabled, module_contributor_requests_enabled, module_docs_enabled,
                     module_directory_enabled, module_bookings_enabled, module_membership_enabled, module_newsletter_enabled, module_donations_enabled, module_testimonials_enabled,
                     theme_default_mode, theme_light_preset, theme_dark_preset,
                     shop_enabled, media_quota_mb, post_quota, page_quota,
                     allow_master_gallery, allow_master_posts,
                     site_meta_title, site_meta_description, default_pages_json,
                     is_default, created_at, updated_at)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            @{$preset}{qw(
                name slug description category
                module_map_enabled module_shop_enabled module_gallery_enabled
                module_forms_enabled module_contributor_requests_enabled module_docs_enabled
                module_directory_enabled module_bookings_enabled module_membership_enabled module_newsletter_enabled module_donations_enabled module_testimonials_enabled
                theme_default_mode theme_light_preset theme_dark_preset
                shop_enabled media_quota_mb post_quota page_quota
                allow_master_gallery allow_master_posts
                site_meta_title site_meta_description
            )},
            encode_json(_clean_default_pages($preset->{default_pages} || [])),
            (!$had_existing && _bool($preset->{is_default})) ? 1 : 0,
            $ts,
            $ts
        );
    }
}

sub _migrate_legacy_standard_blueprint {
    my ($self, $ts) = @_;
    my $dbh = $self->{db}->dbh;
    my $legacy = $dbh->selectrow_hashref(
        q{
            SELECT *
            FROM contributor_blueprints
            WHERE slug = 'standard-contributor'
              AND name = 'Standard Contributor'
              AND description = 'Default contributor subCMS profile with gallery and master surfacing enabled.'
            LIMIT 1
        }
    ) or return;
    my $preset = $BUILTIN_BLUEPRINTS[0];
    my ($slug_conflict) = $dbh->selectrow_array(
        'SELECT id FROM contributor_blueprints WHERE slug = ? AND id <> ? LIMIT 1',
        undef,
        $preset->{slug},
        $legacy->{id}
    );
    my ($name_conflict) = $dbh->selectrow_array(
        'SELECT id FROM contributor_blueprints WHERE name = ? AND id <> ? LIMIT 1',
        undef,
        $preset->{name},
        $legacy->{id}
    );
    if ($slug_conflict || $name_conflict) {
        $dbh->do(
            'UPDATE contributor_blueprints SET category = ?, updated_at = ? WHERE id = ?',
            undef,
            $preset->{category},
            $ts,
            $legacy->{id}
        );
        return;
    }
    $dbh->do(
        q{
            UPDATE contributor_blueprints
            SET name = ?, slug = ?, description = ?, category = ?,
                module_map_enabled = ?, module_shop_enabled = ?, module_gallery_enabled = ?,
                module_forms_enabled = ?, module_contributor_requests_enabled = ?, module_docs_enabled = ?,
                module_directory_enabled = ?, module_bookings_enabled = ?, module_membership_enabled = ?,
                module_newsletter_enabled = ?, module_donations_enabled = ?, module_testimonials_enabled = ?,
                theme_default_mode = ?, theme_light_preset = ?, theme_dark_preset = ?,
                shop_enabled = ?, media_quota_mb = ?, post_quota = ?, page_quota = ?,
                allow_master_gallery = ?, allow_master_posts = ?,
                site_meta_title = ?, site_meta_description = ?, default_pages_json = ?,
                updated_at = ?
            WHERE id = ?
        },
        undef,
        @{$preset}{qw(
            name slug description category
            module_map_enabled module_shop_enabled module_gallery_enabled
            module_forms_enabled module_contributor_requests_enabled module_docs_enabled
            module_directory_enabled module_bookings_enabled module_membership_enabled module_newsletter_enabled module_donations_enabled module_testimonials_enabled
            theme_default_mode theme_light_preset theme_dark_preset
            shop_enabled media_quota_mb post_quota page_quota
            allow_master_gallery allow_master_posts
            site_meta_title site_meta_description
        )},
        encode_json(_clean_default_pages($preset->{default_pages} || [])),
        $ts,
        $legacy->{id}
    );
}

sub _set_default_locked {
    my ($self, $id) = @_;
    my $ts = now();
    $self->{db}->dbh->do('UPDATE contributor_blueprints SET is_default = 0 WHERE is_default <> 0');
    $self->{db}->dbh->do(
        'UPDATE contributor_blueprints SET is_default = 1, updated_at = ? WHERE id = ?',
        undef,
        $ts,
        $id
    );
}

sub _clean_default_pages_json {
    my ($json) = @_;
    my $pages = eval { decode_json($json || '[]') } || [];
    return encode_json(_clean_default_pages($pages));
}

sub _parse_default_pages_text {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/\r\n?/\n/g;
    my @pages;
    for my $line (split /\n/, $text) {
        $line =~ s/^\s+|\s+\z//g;
        next unless length $line;
        my ($title, $slug, $nav) = map { defined $_ ? $_ : '' } split /\|/, $line, 3;
        $title = _clean_text($title, 120);
        next unless length $title;
        $slug = slugify(_clean_text($slug, 120) || $title);
        push @pages, {
            title => $title,
            slug => $slug,
            show_in_nav => (!length($nav) || $nav =~ /\A(?:nav|yes|true|1)\z/i) ? 1 : 0,
        };
    }
    return _clean_default_pages(\@pages);
}

sub _clean_default_pages {
    my ($pages) = @_;
    return [] unless ref $pages eq 'ARRAY';
    my (@clean, %seen);
    for my $page (@{$pages}) {
        next unless ref $page eq 'HASH';
        my $title = _clean_text($page->{title}, 120);
        next unless length $title;
        my $slug = slugify(_clean_text($page->{slug}, 120) || $title);
        next if $seen{$slug}++;
        push @clean, {
            title => $title,
            slug => $slug,
            show_in_nav => _bool($page->{show_in_nav}),
        };
        last if @clean >= 12;
    }
    return \@clean;
}

sub _theme_preset {
    my ($value, $mode) = @_;
    $mode = $mode && $mode eq 'dark' ? 'dark' : 'light';
    for my $preset (@{DesertCMS::SiteTheme::presets_for_mode($mode)}) {
        return $preset->{id} if defined $value && $value eq $preset->{id};
    }
    return $mode eq 'dark' ? 'dark-archive' : 'light-archive';
}

sub _category {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    $value =~ s/_/-/g;
    $value = lc $value;
    return $value if $VERTICAL_LABEL{$value};
    return 'photographer';
}

sub _quota {
    my ($value, $default, $min, $max) = @_;
    return $default unless defined $value && "$value" =~ /\A[0-9]+\z/;
    my $int = int($value);
    $int = $min if $int < $min;
    $int = $max if $int > $max;
    return $int;
}

sub _bool {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _clean_text {
    my ($value, $max) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\x00-\x1f\x7f]+/ /g;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+\z//g;
    return substr($value, 0, $max || 255);
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

1;
