package DesertCMS::Dashboard;

use strict;
use warnings;
use DesertCMS::ModuleManifest ();
use DesertCMS::Modules ();
use DesertCMS::Settings ();
use DesertCMS::Util qw(now);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub widget_catalog {
    my ($self) = @_;
    my $settings = DesertCMS::Settings::all($self->{config}, $self->{db});
    my @widgets;
    my %seen;
    for my $widget (@{ DesertCMS::ModuleManifest::dashboard_widgets(settings => $settings, config => $self->{config}) }) {
        next unless ref($widget) eq 'HASH';
        my $key = _clean_key($widget->{key});
        next unless length $key;
        next if $seen{$key}++;
        push @widgets, {
            key        => $key,
            label      => _clean_label($widget->{label} || $key),
            size       => _clean_size($widget->{size}),
            capability => _clean_key($widget->{capability} || ''),
            module_key => _clean_key($widget->{module_key} || ''),
        };
    }
    return \@widgets;
}

sub widgets_for_user {
    my ($self, %args) = @_;
    my $user_id = int($args{user_id} || 0);
    my $role = _clean_key($args{role} || '');
    my $catalog = $self->widget_catalog;
    my %catalog = map { $_->{key} => $_ } @{$catalog};
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT *
            FROM admin_dashboard_widgets
            WHERE (user_id = ? OR user_id IS NULL)
              AND (role = ? OR role = '')
            ORDER BY CASE WHEN user_id = ? THEN 0 ELSE 1 END,
                     position ASC, id ASC
        },
        { Slice => {} },
        $user_id || undef,
        $role,
        $user_id || undef,
    );

    my %custom;
    for my $row (@{ $rows || [] }) {
        my $key = $row->{widget_key} || next;
        next unless $catalog{$key};
        next if $custom{$key};
        $custom{$key} = {
            %{ $catalog{$key} },
            position => int($row->{position} || 100),
            size     => _clean_size($row->{size} || $catalog{$key}{size}),
            enabled  => $row->{enabled} ? 1 : 0,
        };
    }

    my @widgets;
    my $position = 10;
    for my $widget (@{$catalog}) {
        if ($custom{$widget->{key}}) {
            push @widgets, $custom{$widget->{key}};
        } else {
            push @widgets, {
                %{$widget},
                position => $position,
                enabled  => _default_enabled($widget->{key}),
            };
        }
        $position += 10;
    }

    return [
        sort {
            ($a->{position} || 100) <=> ($b->{position} || 100)
                || ($a->{label} || '') cmp ($b->{label} || '')
        } @widgets
    ];
}

sub save_widgets {
    my ($self, %args) = @_;
    my $user_id = int($args{user_id} || 0);
    my $role = _clean_key($args{role} || '');
    my $values = $args{values} || {};
    my %enabled = ref($values->{enabled}) eq 'HASH' ? %{ $values->{enabled} } : ();
    my %sizes = ref($values->{sizes}) eq 'HASH' ? %{ $values->{sizes} } : ();
    my %positions = ref($values->{positions}) eq 'HASH' ? %{ $values->{positions} } : ();
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            DELETE FROM admin_dashboard_widgets
            WHERE (user_id = ? OR (user_id IS NULL AND ? IS NULL))
              AND role = ?
        },
        undef,
        $user_id || undef,
        $user_id || undef,
        $role,
    );
    my $position = 10;
    for my $widget (@{ $self->widget_catalog }) {
        my $key = $widget->{key};
        my $enabled = $enabled{$key} ? 1 : 0;
        my $size = _clean_size($sizes{$key} || $widget->{size});
        my $saved_position = int($positions{$key} || $position);
        $self->{db}->dbh->do(
            q{
                INSERT INTO admin_dashboard_widgets
                    (user_id, role, widget_key, module_key, position, size, settings_json, enabled, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, '{}', ?, ?, ?)
            },
            undef,
            $user_id || undef,
            $role,
            $key,
            $widget->{module_key} || '',
            $saved_position,
            $size,
            $enabled,
            $ts,
            $ts,
        );
        $position += 10;
    }
    return $self->widgets_for_user(user_id => $user_id, role => $role);
}

sub _default_enabled {
    my ($key) = @_;
    return 1 if $key =~ /\A(?:analytics_overview|top_pages|top_ips|security_summary|notifications|module_status)\z/;
    return 0;
}

sub _clean_key {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value = lc $value;
    $value =~ s/[^a-z0-9_.:-]+/_/g;
    return substr($value, 0, 120);
}

sub _clean_label {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    $value =~ s/\s+/ /g;
    return substr($value, 0, 120);
}

sub _clean_size {
    my ($value) = @_;
    $value = lc($value || 'medium');
    return $value if $value =~ /\A(?:small|medium|large|wide)\z/;
    return 'medium';
}

1;
