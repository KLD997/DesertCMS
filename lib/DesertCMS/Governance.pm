package DesertCMS::Governance;

use strict;
use warnings;
use DesertCMS::CapabilityPolicy;

my %ROLE_DEFINITIONS = (
    master => [
        [ owner    => 'Owner',    'Full master CMS control, including governance.' ],
        [ operator => 'Operator', 'Operational control for sites, providers, backups, and settings.' ],
        [ reviewer => 'Reviewer', 'Contributor request review and onboarding decisions.' ],
        [ curator  => 'Curator',  'Content, media, navigation, theme, and publishing work.' ],
        [ support  => 'Support',  'Read-only support access to operational screens.' ],
    ],
    contributor => [
        [ owner       => 'Site Manager', 'Contributor-site management for content, media, design, features, usage, and billing.' ],
        [ editor      => 'Editor',      'Contributor-site content, media, theme, and publishing work.' ],
        [ contributor => 'Contributor', 'Contributor-site content and media work.' ],
        [ support     => 'Support',     'Read-only support access to the contributor subCMS.' ],
    ],
);

my %VALID_ROLE;
for my $scope (keys %ROLE_DEFINITIONS) {
    $VALID_ROLE{$scope} = { map { $_->[0] => 1 } @{ $ROLE_DEFINITIONS{$scope} } };
}

sub scope {
    my ($config) = @_;
    return DesertCMS::CapabilityPolicy::scope($config);
}

sub role_definitions {
    my ($scope) = @_;
    $scope = _clean_scope($scope);
    return [
        map {
            +{
                role        => $_->[0],
                label       => $_->[1],
                description => $_->[2],
                capabilities => DesertCMS::CapabilityPolicy::role_capabilities($scope, $_->[0]),
            }
        } @{ $ROLE_DEFINITIONS{$scope} }
    ];
}

sub normalize_role {
    my ($role, $scope) = @_;
    $scope = _clean_scope($scope);
    $role = lc($role || '');
    $role =~ s/^\s+|\s+\z//g;
    return $role if $VALID_ROLE{$scope}{$role};
    return 'owner';
}

sub role_label {
    my ($role, $scope) = @_;
    $scope = _clean_scope($scope);
    $role = normalize_role($role, $scope);
    for my $definition (@{ $ROLE_DEFINITIONS{$scope} }) {
        return $definition->[1] if $definition->[0] eq $role;
    }
    return 'Owner';
}

sub role_description {
    my ($role, $scope) = @_;
    $scope = _clean_scope($scope);
    $role = normalize_role($role, $scope);
    for my $definition (@{ $ROLE_DEFINITIONS{$scope} }) {
        return $definition->[2] if $definition->[0] eq $role;
    }
    return '';
}

sub allowed {
    my ($config, $role, $method, $path) = @_;
    return DesertCMS::CapabilityPolicy::allowed($config, $role, $method, $path);
}

sub _clean_scope {
    my ($scope) = @_;
    return $scope && $scope eq 'contributor' ? 'contributor' : 'master';
}

1;
