package DesertCMS::DateTimeLite;

use strict;
use warnings;
use POSIX qw(tzset);
use Time::Local qw(timegm timelocal);
use overload
    '<=>'    => sub { _epoch($_[0]) <=> _epoch($_[1]) },
    '0+'     => sub { _epoch($_[0]) },
    fallback => 1;

sub now {
    my ($class, %args) = @_;
    return $class->from_epoch(epoch => time, time_zone => $args{time_zone} || 'UTC');
}

sub from_epoch {
    my ($class, %args) = @_;
    return bless {
        epoch => int($args{epoch} || 0),
        tz    => _timezone($args{time_zone} || 'UTC'),
    }, $class;
}

sub new {
    my ($class, %args) = @_;
    my $tz = _timezone($args{time_zone} || 'UTC');
    my $epoch = _local_epoch(
        int($args{year} || 1970),
        int($args{month} || 1),
        int($args{day} || 1),
        int($args{hour} || 0),
        int($args{minute} || 0),
        int($args{second} || 0),
        $tz,
    );
    return bless { epoch => $epoch, tz => $tz }, $class;
}

sub valid_time_zone {
    my ($class, $value) = @_;
    return length(_timezone($value || '')) ? 1 : 0;
}

sub epoch { return $_[0]->{epoch}; }
sub time_zone { return $_[0]->{tz}; }

sub clone {
    my ($self) = @_;
    return bless { %{$self} }, ref($self);
}

sub year { return _parts($_[0])->{year}; }
sub month { return _parts($_[0])->{month}; }
sub day { return _parts($_[0])->{day}; }
sub hour { return _parts($_[0])->{hour}; }
sub minute { return _parts($_[0])->{minute}; }
sub second { return _parts($_[0])->{second}; }
sub day_of_year { return _parts($_[0])->{yday}; }

sub day_of_week {
    my $wday = _parts($_[0])->{wday};
    return $wday == 0 ? 7 : $wday;
}

sub week_number {
    my ($self) = @_;
    my @local = _localtime_list($self->{epoch}, $self->{tz});
    my $week = strftime('%V', @local);
    return int($week || 0);
}

sub set {
    my ($self, %args) = @_;
    my $p = _parts($self);
    my $year = exists $args{year} ? int($args{year}) : $p->{year};
    my $month = exists $args{month} ? int($args{month}) : $p->{month};
    my $day = exists $args{day} ? int($args{day}) : $p->{day};
    my $hour = exists $args{hour} ? int($args{hour}) : $p->{hour};
    my $minute = exists $args{minute} ? int($args{minute}) : $p->{minute};
    my $second = exists $args{second} ? int($args{second}) : $p->{second};
    $day = _min($day, _days_in_month($year, $month));
    $self->{epoch} = _local_epoch($year, $month, $day, $hour, $minute, $second, $self->{tz});
    return $self;
}

sub add {
    my ($self, %args) = @_;
    my $years = int($args{years} || 0);
    my $months = int($args{months} || 0);
    if ($years || $months) {
        my $p = _parts($self);
        my $month_index = ($p->{year} * 12) + ($p->{month} - 1) + ($years * 12) + $months;
        my $year = int($month_index / 12);
        my $month = ($month_index % 12) + 1;
        my $day = _min($p->{day}, _days_in_month($year, $month));
        $self->{epoch} = _local_epoch($year, $month, $day, $p->{hour}, $p->{minute}, $p->{second}, $self->{tz});
    }
    my $seconds = 0;
    $seconds += int($args{weeks} || 0) * 7 * 86400;
    $seconds += int($args{days} || 0) * 86400;
    $seconds += int($args{hours} || 0) * 3600;
    $seconds += int($args{minutes} || 0) * 60;
    $seconds += int($args{seconds} || 0);
    $self->{epoch} += $seconds if $seconds;
    return $self;
}

sub subtract {
    my ($self, %args) = @_;
    my %neg = map { $_ => -int($args{$_} || 0) } keys %args;
    return $self->add(%neg);
}

sub strftime {
    my ($self, $format) = @_;
    $format = '' unless defined $format;
    my @local = _localtime_list($self->{epoch}, $self->{tz});
    my $out = POSIX::strftime($format, @local);
    if ($format =~ /%z/) {
        my $offset = _offset_seconds($self->{epoch}, $self->{tz});
        my $sign = $offset < 0 ? '-' : '+';
        $offset = abs($offset);
        my $hh = int($offset / 3600);
        my $mm = int(($offset % 3600) / 60);
        my $zone = sprintf('%s%02d%02d', $sign, $hh, $mm);
        $out =~ s/[+-][0-9]{4}/$zone/ if defined $out;
    }
    return $out;
}

sub _epoch {
    my ($value) = @_;
    return ref($value) ? int($value->{epoch} || 0) : int($value || 0);
}

sub _parts {
    my ($self) = @_;
    my @t = _localtime_list($self->{epoch}, $self->{tz});
    return {
        second => $t[0],
        minute => $t[1],
        hour   => $t[2],
        day    => $t[3],
        month  => $t[4] + 1,
        year   => $t[5] + 1900,
        wday   => $t[6],
        yday   => $t[7] + 1,
    };
}

sub _localtime_list {
    my ($epoch, $tz) = @_;
    $tz = _timezone($tz || 'UTC');
    return gmtime($epoch) if _is_utc($tz);
    return _with_tz($tz, sub { localtime($epoch) });
}

sub _local_epoch {
    my ($year, $month, $day, $hour, $minute, $second, $tz) = @_;
    die "invalid month" if $month < 1 || $month > 12;
    die "invalid day" if $day < 1 || $day > _days_in_month($year, $month);
    if (_is_utc($tz)) {
        return timegm($second, $minute, $hour, $day, $month - 1, $year);
    }
    return _with_tz($tz, sub { timelocal($second, $minute, $hour, $day, $month - 1, $year) });
}

sub _offset_seconds {
    my ($epoch, $tz) = @_;
    return 0 if _is_utc($tz);
    my @local = _localtime_list($epoch, $tz);
    my $as_utc = timegm($local[0], $local[1], $local[2], $local[3], $local[4], $local[5] + 1900);
    return $as_utc - $epoch;
}

sub _with_tz {
    my ($tz, $code) = @_;
    my $had_tz = exists $ENV{TZ};
    my $old_tz = $ENV{TZ};
    $ENV{TZ} = $tz;
    tzset();
    my $wantarray = wantarray;
    my @result;
    my $error;
    if ($wantarray) {
        @result = eval { $code->() };
        $error = $@;
    } else {
        my $result = eval { $code->() };
        $error = $@;
        @result = ($result);
    }
    if ($had_tz) {
        $ENV{TZ} = $old_tz;
    } else {
        delete $ENV{TZ};
    }
    tzset();
    die $error if $error;
    return $wantarray ? @result : $result[0];
}

sub _timezone {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    return 'UTC' if $value eq '' || uc($value) eq 'Z';
    return 'UTC' if _is_utc($value);
    return '' if length($value) > 80;
    return '' if $value =~ m{(^/|/\.\.?/|\.\.|[\x00-\x20])};
    return '' unless $value =~ /\A[A-Za-z0-9_+.\-\/:]+\z/;
    return $value;
}

sub _is_utc {
    my ($tz) = @_;
    return uc($tz || '') =~ /\A(?:UTC|GMT|ETC\/UTC|ETC\/GMT)\z/ ? 1 : 0;
}

sub _days_in_month {
    my ($year, $month) = @_;
    return 31 if $month =~ /\A(?:1|3|5|7|8|10|12)\z/;
    return 30 if $month =~ /\A(?:4|6|9|11)\z/;
    return _leap_year($year) ? 29 : 28;
}

sub _leap_year {
    my ($year) = @_;
    return 1 if $year % 400 == 0;
    return 0 if $year % 100 == 0;
    return $year % 4 == 0 ? 1 : 0;
}

sub _min {
    my ($a, $b) = @_;
    return $a < $b ? $a : $b;
}

1;
