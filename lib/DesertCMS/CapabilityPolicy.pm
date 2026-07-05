package DesertCMS::CapabilityPolicy;

use strict;
use warnings;

my @CAPABILITY_DEFINITIONS = (
    [ manage_account              => 'Manage account',              'Update the signed-in admin account and first-login setup.' ],
    [ view_home                   => 'View home',                   'Open the main admin or contributor-site home view.' ],
    [ view_settings               => 'View settings',               'Open settings overview pages.' ],
    [ view_content                => 'View content',                'View pages, posts, templates, navigation, redirects, and comments.' ],
    [ edit_content                => 'Edit content',                'Create, update, publish, rebuild, or delete local pages and posts.' ],
    [ view_media                  => 'View media',                  'View the local media library.' ],
    [ upload_media                => 'Upload media',                'Upload media assets and update media metadata.' ],
    [ download_media_sources      => 'Download private source media', 'Download private source files from the local media library.' ],
    [ publish_media_resources     => 'Publish media resources',     'Publish or unpublish private source files as public Resource downloads.' ],
    [ delete_media_assets         => 'Delete media assets',         'Delete unused media assets and run media cleanup actions.' ],
    [ bulk_manage_media           => 'Bulk manage media',           'Run bulk metadata, publishing, unpublishing, or deletion actions in Media.' ],
    [ view_design                 => 'View design',                 'View public-site identity, SEO, theme, layout, and theme files.' ],
    [ customize_theme             => 'Customize theme',             'Change site identity, SEO, theme files, layout, fonts, and indexing settings.' ],
    [ view_features               => 'View features',               'View the local feature or module catalog.' ],
    [ enable_allowed_modules      => 'Enable allowed modules',      'Turn locally allowed modules on or off and save module settings.' ],
    [ manage_billing              => 'Manage billing',              'Start checkout, open the billing portal, or change billing state.' ],
    [ view_usage                  => 'View usage',                  'View plan, quota, billing, and usage information.' ],
    [ manage_provider_settings    => 'Manage provider settings',    'Configure platform provider integrations such as Postmark and contributor domains.' ],
    [ view_master_control         => 'View master control',         'View contributor fleet control-plane status.' ],
    [ run_operations              => 'Run operations',              'Run backups, rebuilds, sitemap submissions, restore tests, and support bundles.' ],
    [ view_operations             => 'View operations',             'View backups, operations, recovery, support bundles, and operational history.' ],
    [ run_upgrades                => 'Run upgrades',                'Stage upgrades or root-worker rollbacks.' ],
    [ view_governance             => 'View governance',             'View roles, admin users, and audit logs.' ],
    [ manage_governance           => 'Manage governance',           'Grant or disable admin access.' ],
    [ view_federated              => 'View federated review',       'View contributor content review queues.' ],
    [ review_federated_content    => 'Review federated content',    'Refresh and approve contributor media or posts for master surfacing.' ],
    [ review_contributors         => 'Review contributors',         'View and decide contributor applications.' ],
    [ view_blueprints             => 'View blueprints',             'View contributor blueprint configuration.' ],
    [ manage_blueprints           => 'Manage blueprints',           'Create or edit contributor blueprints.' ],
    [ view_service_plans          => 'View service plans',          'View hosted contributor plans and fleet usage.' ],
    [ manage_service_plans        => 'Manage service plans',        'Create, edit, assign, or default hosted contributor plans.' ],
    [ manage_contributor_lifecycle => 'Manage contributor lifecycle', 'Queue contributor site enable, disable, destroy, repair, or retry actions.' ],
);

my @CAPABILITY_KEYS = map { $_->[0] } @CAPABILITY_DEFINITIONS;
my %CAPABILITY_DEFINITION = map {
    $_->[0] => {
        key         => $_->[0],
        label       => $_->[1],
        description => $_->[2],
    }
} @CAPABILITY_DEFINITIONS;

my %ROLE_CAPABILITIES = (
    master => {
        owner => [qw(
            manage_account view_home view_settings view_content edit_content
            view_media upload_media download_media_sources publish_media_resources delete_media_assets bulk_manage_media
            view_design customize_theme view_features enable_allowed_modules
            manage_billing view_usage manage_provider_settings view_master_control run_operations
            view_operations run_upgrades view_governance manage_governance view_federated
            review_federated_content review_contributors view_blueprints manage_blueprints view_service_plans
            manage_service_plans manage_contributor_lifecycle
        )],
        operator => [qw(
            manage_account view_home view_settings view_content edit_content view_media upload_media
            download_media_sources publish_media_resources delete_media_assets bulk_manage_media
            view_design customize_theme view_features enable_allowed_modules manage_billing view_usage
            manage_provider_settings view_master_control run_operations view_operations view_governance
            view_federated review_federated_content review_contributors view_blueprints manage_blueprints
            view_service_plans manage_service_plans manage_contributor_lifecycle
        )],
        reviewer => [qw(
            manage_account view_home view_settings view_master_control view_governance
            view_federated review_federated_content review_contributors view_blueprints
        )],
        curator => [qw(
            manage_account view_home view_content edit_content view_media upload_media
            download_media_sources publish_media_resources delete_media_assets bulk_manage_media
            view_design customize_theme view_federated review_federated_content
        )],
        support => [qw(
            manage_account view_home view_settings view_content view_media view_usage
            view_master_control view_governance view_federated view_service_plans view_operations
        )],
    },
    contributor => {
        owner => [qw(
            manage_account view_home view_settings view_content edit_content
            view_media upload_media download_media_sources publish_media_resources delete_media_assets bulk_manage_media
            view_design customize_theme view_features enable_allowed_modules
            manage_billing view_usage
        )],
        editor => [qw(
            manage_account view_home view_settings view_content edit_content view_media upload_media
            download_media_sources publish_media_resources bulk_manage_media
            view_design customize_theme view_features enable_allowed_modules manage_billing view_usage
        )],
        contributor => [qw(
            manage_account view_home view_content edit_content view_media upload_media
            manage_billing view_usage
        )],
        support => [qw(
            manage_account view_home view_settings view_content view_media view_design view_usage
        )],
    },
);

for my $scope (keys %ROLE_CAPABILITIES) {
    for my $role (keys %{ $ROLE_CAPABILITIES{$scope} }) {
        for my $capability (@{ $ROLE_CAPABILITIES{$scope}{$role} }) {
            die "unknown capability $capability for $scope/$role"
                unless $CAPABILITY_DEFINITION{$capability};
        }
    }
}

sub capabilities {
    return [ @CAPABILITY_KEYS ];
}

sub capability_definitions {
    return [ map { +{ %{ $CAPABILITY_DEFINITION{$_} } } } @CAPABILITY_KEYS ];
}

sub capability_definition {
    my ($capability) = @_;
    return undef unless defined $capability && exists $CAPABILITY_DEFINITION{$capability};
    return { %{ $CAPABILITY_DEFINITION{$capability} } };
}

sub contributor_product_mode {
    my ($config) = @_;
    return scope($config) eq 'contributor' ? 1 : 0;
}

sub scope {
    my ($config) = @_;
    return 'contributor'
        if $config && length($config->get('contributor_site_id') || '');
    return 'contributor'
        if $config && length($config->get('contributor_domain') || '');
    return 'master';
}

sub capabilities_for_role {
    my ($config, $role) = @_;
    my $scope = _scope_from_config_or_scope($config);
    $role = _normalize_role($scope, $role);
    return {
        map { $_ => 1 } @{ $ROLE_CAPABILITIES{$scope}{$role} || [] }
    };
}

sub role_capabilities {
    my ($config, $role) = @_;
    my $map = capabilities_for_role($config, $role);
    return [ grep { $map->{$_} } @CAPABILITY_KEYS ];
}

sub has {
    my ($config, $role, $capability) = @_;
    return 0 unless defined $capability && length $capability;
    my $caps = capabilities_for_role($config, $role);
    return $caps->{$capability} ? 1 : 0;
}

sub allowed {
    my ($config, $role, $method, $path) = @_;
    my $scope = scope($config);
    $role = _normalize_role($scope, $role);
    $method = uc($method || 'GET');
    $path = _clean_path($path);
    my $caps = capabilities_for_role($config, $role);

    return 1 if _matches($path, qr{\A/admin/logout\z}, qr{\A/admin/account/setup\z});
    return 1 if _matches($path, qr{\A/admin/settings/account\z}, qr{\A/admin/settings/admin-account\z})
        && $caps->{manage_account};

    if ($scope eq 'contributor') {
        return 0 if _contributor_master_managed_route($path);
    }

    return _allowed_by_capability($caps, $method, $path);
}

sub route_capability {
    my ($method, $path) = @_;
    $method = uc($method || 'GET');
    $path = _clean_path($path);
    return _route_capability($method, $path);
}

sub _allowed_by_capability {
    my ($caps, $method, $path) = @_;
    my $capability = _route_capability($method, $path);
    return 0 unless length $capability;
    return $caps->{$capability} ? 1 : 0;
}

sub _route_capability {
    my ($method, $path) = @_;

    return 'view_home' if _matches($path, qr{\A/admin\z});
    return 'view_home' if _matches($path, qr{\A/admin/help\z});
    return 'manage_account' if _matches(
        $path,
        qr{\A/admin/account/setup\z},
        qr{\A/admin/settings/account\z},
        qr{\A/admin/settings/admin-account\z}
    );
    return _read_or_write($method, 'view_content', 'edit_content') if _matches(
        $path,
        qr{\A/admin/editor\z},
        qr{\A/admin/pages(?:/|\z)},
        qr{\A/admin/posts(?:/|\z)},
        qr{\A/admin/templates(?:/|\z)},
        qr{\A/admin/sections(?:/|\z)},
        qr{\A/admin/content(?:/|\z)},
        qr{\A/admin/comments(?:/|\z)},
        qr{\A/admin/navigation(?:/|\z)},
        qr{\A/admin/redirects(?:/|\z)},
        qr{\A/admin/rebuild\z}
    );
    return 'view_media' if _matches($path, qr{\A/admin/media\z});
    return 'upload_media' if _matches($path, qr{\A/admin/media/upload\z}, qr{\A/admin/media/[0-9]+/alt\z});
    return 'bulk_manage_media' if _matches($path, qr{\A/admin/media/bulk\z}, qr{\A/admin/media/previews/(?:queue|process)\z});
    return 'view_media' if _matches($path, qr{\A/admin/media/lifecycle\z}, qr{\A/admin/media/[0-9]+/preview\z});
    return 'delete_media_assets' if _matches($path, qr{\A/admin/media/lifecycle/cleanup\z}, qr{\A/admin/media/[0-9]+/delete\z});
    return 'download_media_sources' if _matches($path, qr{\A/admin/media/[0-9]+/download\z});
    return 'publish_media_resources' if _matches($path, qr{\A/admin/media/[0-9]+/(?:publish|unpublish)\z});
    return _read_or_write($method, 'view_design', 'customize_theme') if _matches(
        $path,
        qr{\A/admin/theme(?:/|\z)},
        qr{\A/admin/site-settings(?:/|\z)}
    );
    return _read_or_write($method, 'view_features', 'enable_allowed_modules') if _matches(
        $path,
        qr{\A/admin/settings/modules(?:/|\z)},
        qr{\A/admin/shop(?:/|\z)}
    );
    return _read_or_write($method, 'view_usage', 'manage_billing') if _matches(
        $path,
        qr{\A/admin/billing(?:/|\z)}
    );
    return 'manage_provider_settings' if _matches($path, qr{\A/admin/settings/save\z});
    return 'view_settings' if _matches($path, qr{\A/admin/settings\z});
    return _read_or_write($method, 'view_master_control', 'manage_contributor_lifecycle') if _matches(
        $path,
        qr{\A/admin/settings/master-control(?:/|\z)}
    );
    return _read_or_write($method, 'view_master_control', 'manage_provider_settings') if _matches(
        $path,
        qr{\A/admin/settings/payments(?:/|\z)}
    );
    return 'review_contributors' if _matches(
        $path,
        qr{\A/admin/settings/contributors/requests/[0-9]+(?:/(?:approve|deny))?\z}
    );
    return _read_or_write($method, 'review_contributors', 'manage_provider_settings') if _matches(
        $path,
        qr{\A/admin/settings/contributors(?:/|\z)},
        qr{\A/admin/settings/invites(?:/|\z)}
    );
    return _read_or_write($method, 'view_blueprints', 'manage_blueprints') if _matches(
        $path,
        qr{\A/admin/settings/blueprints(?:/|\z)}
    );
    return _read_or_write($method, 'view_service_plans', 'manage_service_plans') if _matches(
        $path,
        qr{\A/admin/settings/plans(?:/|\z)}
    );
    return _read_or_write($method, 'manage_contributor_lifecycle', 'manage_contributor_lifecycle') if _matches(
        $path,
        qr{\A/admin/settings/sites(?:/|\z)}
    );
    return _read_or_write($method, 'view_federated', 'review_federated_content') if _matches(
        $path,
        qr{\A/admin/settings/federation(?:/|\z)}
    );
    return _read_or_write($method, 'view_governance', 'manage_governance') if _matches(
        $path,
        qr{\A/admin/settings/governance(?:/|\z)}
    );
    return 'run_upgrades' if _matches(
        $path,
        qr{\A/admin/settings/upgrade(?:/|\z)},
        qr{\A/admin/settings/operations/rollback\z}
    );
    return _read_or_write($method, 'view_operations', 'run_operations') if _matches(
        $path,
        qr{\A/admin/settings/operations(?:/|\z)}
    );
    return _read_or_write($method, 'view_operations', 'run_operations') if _matches(
        $path,
        qr{\A/admin/backups(?:/|\z)}
    );

    return '';
}

sub _read_or_write {
    my ($method, $read_capability, $write_capability) = @_;
    return $method eq 'GET' ? $read_capability : $write_capability;
}

sub _contributor_master_managed_route {
    my ($path) = @_;
    return _matches(
        $path,
        qr{\A/admin/theme(?:/|\z)},
        qr{\A/admin/site-settings/fonts/(?:refresh|install)\z},
        qr{\A/admin/backups(?:/|\z)},
        qr{\A/admin/settings/master-control(?:/|\z)},
        qr{\A/admin/settings/contributors(?:/|\z)},
        qr{\A/admin/settings/sites(?:/|\z)},
        qr{\A/admin/settings/blueprints(?:/|\z)},
        qr{\A/admin/settings/plans(?:/|\z)},
        qr{\A/admin/settings/federation(?:/|\z)},
        qr{\A/admin/settings/governance(?:/|\z)},
        qr{\A/admin/settings/upgrade(?:/|\z)},
        qr{\A/admin/settings/operations(?:/|\z)},
        qr{\A/admin/settings/invites(?:/|\z)}
    );
}

sub _matches {
    my ($path, @patterns) = @_;
    for my $pattern (@patterns) {
        return 1 if $path =~ $pattern;
    }
    return 0;
}

sub _clean_path {
    my ($path) = @_;
    $path ||= '/admin';
    $path =~ s/\?.*\z//;
    $path =~ s{/+\z}{};
    return $path eq '' ? '/admin' : $path;
}

sub _scope_from_config_or_scope {
    my ($config) = @_;
    return _clean_scope($config) unless ref $config;
    return scope($config);
}

sub _clean_scope {
    my ($scope) = @_;
    return $scope && $scope eq 'contributor' ? 'contributor' : 'master';
}

sub _normalize_role {
    my ($scope, $role) = @_;
    $scope = _clean_scope($scope);
    $role = lc($role || '');
    $role =~ s/^\s+|\s+\z//g;
    return $role if $ROLE_CAPABILITIES{$scope}{$role};
    return 'owner';
}

1;
