package DesertCMS::Config;

use strict;
use warnings;
use File::Path qw(make_path);
use DesertCMS::Util qw(random_hex);

sub load {
    my ($class, $path) = @_;
    $path ||= $ENV{DESERTCMS_CONFIG} || '/etc/desertcms.conf';

    my %config = (
        site_name             => 'DesertCMS',
        site_url              => 'http://localhost',
        data_dir              => '/var/desertcms',
        db_path               => '/var/desertcms/desertcms.sqlite',
        app_secret_file       => '/var/desertcms/app_secret',
        public_root           => '/var/www/htdocs/desertcms-site',
        originals_dir         => '/var/desertcms/originals',
        backup_dir            => '/var/desertcms/backups',
        theme_dir             => '/usr/local/www/desertcms/themes',
        admin_asset_dir       => '/usr/local/www/desertcms/admin/assets',
        session_cookie        => 'desertcms_session',
        member_session_cookie => 'desertcms_member_session',
        session_ttl_seconds   => 7200,
        secure_cookies        => 1,
        login_lockout_seconds => 900,
        login_max_failures    => 5,
        trusted_proxy_cidrs    => '',
        max_request_body_bytes => 67108864,
        image_public_max_width => 1600,
        image_public_quality  => 82,
        image_tool             => 'vips',
        tar_tool               => 'tar',
        analytics_enabled      => 1,
        analytics_retention_days => 365,
        analytics_store_raw_ip => 1,
        contributor_site_id    => '',
        contributor_domain     => '',
        contributor_owner_name => '',
        contributor_owner_email => '',
        master_config_path     => '',
        standalone_master_configs => '',
        module_map_enabled       => 1,
        module_shop_enabled      => '',
        module_gallery_enabled   => 0,
        module_forms_enabled     => 0,
        module_contributor_requests_enabled => 1,
        module_docs_enabled      => 0,
        docs_source_dir          => '',
        shop_domain             => '',
        shop_url                => '',
        commerce_model          => '',
        shop_enabled            => 1,
        shop_require_purchase_token => 1,
        stripe_secret_key       => '',
        stripe_webhook_secret   => '',
        stripe_webhook_tolerance_seconds => 300,
        stripe_api_base         => 'https://api.stripe.com/v1/checkout/sessions',
        postmark_sender_mode    => '',
        postmark_from_email     => '',
        postmark_server_token   => '',
        postmark_webhook_token  => '',
        google_oauth_client_id  => '',
        google_oauth_client_secret => '',
        google_search_console_property => '',
        indexnow_enabled        => 0,
        indexnow_key            => '',
        operations_backup_schedule_enabled => 0,
        operations_backup_interval_hours   => 24,
        operations_offsite_hook_url        => '',
        operations_offsite_hook_token      => '',
        operations_upgrade_channel         => 'stable',
        upgrade_require_signed_releases    => 0,
        upgrade_signify_public_key         => '',
        upgrade_signify_tool               => 'signify',
        font_package_repo                  => '',
    );

    my %seen;
    if (-f $path) {
        open my $fh, '<', $path or die "cannot read config $path: $!";
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s/\r$//;
            $line =~ s/#.*$//;
            next unless $line =~ /\S/;
            die "invalid config line in $path: $line" unless $line =~ /^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/;
            $config{$1} = $2;
            $seen{$1} = 1;
        }
        close $fh;
    }

    my $self = bless {
        path => $path,
        %config,
        _seen => \%seen,
    }, $class;

    return $self;
}

sub get {
    my ($self, $key) = @_;
    return $self->{$key};
}

sub has {
    my ($self, $key) = @_;
    return 0 unless ref $self->{_seen} eq 'HASH';
    return exists $self->{_seen}{$key};
}

sub app_secret {
    my ($self) = @_;
    return $self->{app_secret} if defined $self->{app_secret};

    my $path = $self->get('app_secret_file');
    if (-f $path) {
        open my $fh, '<', $path or die "cannot read app secret $path: $!";
        my $secret = <$fh>;
        close $fh;
        chomp $secret;
        die "app secret is empty: $path" unless length $secret >= 64;
        $self->{app_secret} = $secret;
        return $secret;
    }

    make_path($self->get('data_dir')) unless -d $self->get('data_dir');
    my $secret = random_hex(32);
    open my $fh, '>', $path or die "cannot create app secret $path: $!";
    print {$fh} "$secret\n";
    close $fh;
    chmod 0600, $path;
    $self->{app_secret} = $secret;
    return $secret;
}

sub all {
    my ($self) = @_;
    return { %{$self} };
}

1;
