package DesertCMS::Newsletter;

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use DesertCMS::Email qw(send_postmark resolved_postmark_settings postmark_https_transport_status);
use DesertCMS::Events;
use DesertCMS::Modules;
use DesertCMS::Settings;
use DesertCMS::Util qw(escape_html hmac_sha256_hex now random_hex sha256_hexstr slugify);

my %SUBSCRIBER_STATUS = map { $_ => 1 } qw(active unsubscribed bounced complained archived);
my %ANNOUNCEMENT_STATUS = map { $_ => 1 } qw(draft ready sent archived);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    die "db is required" unless $args{db};
    return bless {
        config => $args{config},
        db     => $args{db},
    }, $class;
}

sub clear_settings_cache {
    my ($self) = @_;
    delete $self->{_settings};
}

sub enabled {
    my ($self) = @_;
    return DesertCMS::Modules::enabled(_settings($self), 'newsletter');
}

sub signup_enabled {
    my ($self) = @_;
    my $settings = _settings($self);
    return $self->enabled && _truthy($settings->{newsletter_signup_enabled}) ? 1 : 0;
}

sub delivery_readiness {
    my ($self) = @_;
    my $settings = _settings($self);
    my $enabled = $self->enabled;
    my $resolved = resolved_postmark_settings($self->{config}, $self->{db}, $settings);
    my $transport = postmark_https_transport_status();
    my $from_ok = _valid_email($resolved->{from_email} || '');
    my $token_ok = length($resolved->{token} || '') ? 1 : 0;

    my ($state, $label, $summary) = ('neutral', 'Newsletter disabled', 'Enable Newsletter before sending announcements.');
    if (!$enabled) {
        ($state, $label, $summary) = ('neutral', 'Newsletter disabled', 'Enable Newsletter before sending announcements.');
    } elsif (!$transport->{ok}) {
        ($state, $label, $summary) = ('warn', 'Postmark transport missing', $transport->{detail} || 'Install the HTTPS Perl modules required for Postmark.');
    } elsif (!$from_ok) {
        ($state, $label, $summary) = ('warn', 'Sender missing', 'Save a verified Postmark sender address before newsletter sends.');
    } elsif (!$token_ok) {
        ($state, $label, $summary) = ('warn', 'Server token missing', 'Save a Postmark server token before newsletter sends.');
    } else {
        ($state, $label, $summary) = ('ok', 'Ready', 'Newsletter delivery can use the inherited or site-level Postmark sender.');
    }

    return {
        state       => $state,
        label       => $label,
        summary     => $summary,
        send_ready  => ($enabled && $transport->{ok} && $from_ok && $token_ok) ? 1 : 0,
        source      => $resolved->{source_label} || $resolved->{source} || '',
        from_email  => $resolved->{from_email} || '',
    };
}

sub subscribers {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 250, 1, 5000);
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT *
            FROM newsletter_subscribers
            ORDER BY CASE status WHEN 'active' THEN 0 WHEN 'unsubscribed' THEN 1 ELSE 2 END,
                     updated_at DESC,
                     lower(email)
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub active_subscribers {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 5000, 1, 100000);
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT *
            FROM newsletter_subscribers
            WHERE status = 'active'
            ORDER BY lower(email)
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub subscriber_by_id {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM newsletter_subscribers WHERE id = ?',
        undef,
        $id
    );
}

sub subscriber_by_email {
    my ($self, $email) = @_;
    $email = _email($email);
    return undef unless length $email;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM newsletter_subscribers WHERE lower(email) = ?',
        undef,
        $email
    );
}

sub subscribe {
    my ($self, %args) = @_;
    die "newsletter signup is not enabled" unless $self->signup_enabled;
    return $self->save_subscriber(
        email       => $args{email},
        display_name => $args{display_name},
        status      => 'active',
        tags_text   => _merge_terms(_settings($self)->{newsletter_default_tags}, $args{tags_text}),
        segments_text => $args{segments_text},
        consent_text => $args{consent_text} || _settings($self)->{newsletter_consent_text},
        source      => 'public_signup',
        ip_hash     => length($args{ip_address} || '') ? sha256_hexstr($args{ip_address}) : '',
        user_agent_hash => length($args{user_agent} || '') ? sha256_hexstr($args{user_agent}) : '',
        confirmed_at => now(),
    );
}

sub save_subscriber {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $email = _email($args{email});
    die "subscriber email is invalid" unless _valid_email($email);
    my $status = _subscriber_status($args{status});
    my $display = _text($args{display_name}, 140);
    my $tags = _terms($args{tags_text});
    my $segments = _terms($args{segments_text});
    my $consent = _text($args{consent_text}, 500);
    my $source = _source($args{source});
    my $token = _text($args{unsubscribe_token}, 96) || random_hex(24);
    my $ts = now();
    my $confirmed_at = int($args{confirmed_at} || 0) || ($status eq 'active' ? $ts : undef);
    my $dbh = $self->{db}->dbh;
    my $existing = $id ? $self->subscriber_by_id($id) : $self->subscriber_by_email($email);

    if ($existing) {
        $id = int($existing->{id});
        $token = $existing->{unsubscribe_token} if length($existing->{unsubscribe_token} || '') && !$args{rotate_token};
        $dbh->do(
            q{
                UPDATE newsletter_subscribers
                SET email = ?, display_name = ?, status = ?, tags_text = ?, segments_text = ?,
                    consent_text = ?, source = ?, unsubscribe_token = ?,
                    ip_hash = CASE WHEN ? = '' THEN ip_hash ELSE ? END,
                    user_agent_hash = CASE WHEN ? = '' THEN user_agent_hash ELSE ? END,
                    confirmed_at = CASE WHEN ? = 'active' THEN COALESCE(confirmed_at, ?) ELSE confirmed_at END,
                    unsubscribed_at = CASE WHEN ? = 'unsubscribed' THEN COALESCE(unsubscribed_at, ?) ELSE NULL END,
                    updated_at = ?
                WHERE id = ?
            },
            undef,
            $email, $display, $status, $tags, $segments, $consent, $source, $token,
            ($args{ip_hash} || ''), ($args{ip_hash} || ''),
            ($args{user_agent_hash} || ''), ($args{user_agent_hash} || ''),
            $status, $confirmed_at || $ts,
            $status, $ts,
            $ts, $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO newsletter_subscribers
                    (email, display_name, status, tags_text, segments_text, consent_text, source,
                     unsubscribe_token, ip_hash, user_agent_hash, created_at, updated_at, confirmed_at, unsubscribed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $email, $display, $status, $tags, $segments, $consent, $source, $token,
            ($args{ip_hash} || ''), ($args{user_agent_hash} || ''),
            $ts, $ts, $confirmed_at, $status eq 'unsubscribed' ? $ts : undef
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->subscriber_by_id($id);
}

sub unsubscribe {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $token = _text($args{token}, 128);
    my $subscriber = $self->subscriber_by_id($id) or return 0;
    return 0 unless length($token) && length($subscriber->{unsubscribe_token} || '');
    return 0 unless $token eq ($subscriber->{unsubscribe_token} || '');
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            UPDATE newsletter_subscribers
            SET status = 'unsubscribed', unsubscribed_at = COALESCE(unsubscribed_at, ?), updated_at = ?
            WHERE id = ?
        },
        undef,
        $ts, $ts, $id
    );
    return 1;
}

sub csv_export {
    my ($self) = @_;
    my @headers = qw(id email display_name status tags segments source created_at updated_at confirmed_at unsubscribed_at);
    my $csv = join(',', @headers) . "\n";
    for my $row (@{ $self->subscribers(limit => 100000) }) {
        my %export = %{$row};
        $export{tags} = $row->{tags_text} || '';
        $export{segments} = $row->{segments_text} || '';
        $csv .= join(',', map { _csv($export{$_} // '') } @headers) . "\n";
    }
    return $csv;
}

sub announcements {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 100, 1, 1000);
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT *
            FROM newsletter_announcements
            ORDER BY CASE status WHEN 'ready' THEN 0 WHEN 'draft' THEN 1 WHEN 'sent' THEN 2 ELSE 3 END,
                     updated_at DESC,
                     id DESC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub announcement_by_id {
    my ($self, $id) = @_;
    $id = int($id || 0);
    return undef unless $id > 0;
    return $self->{db}->dbh->selectrow_hashref(
        'SELECT * FROM newsletter_announcements WHERE id = ?',
        undef,
        $id
    );
}

sub save_announcement {
    my ($self, %args) = @_;
    my $id = int($args{id} || 0);
    my $title = _text($args{title}, 180);
    die "announcement title is required" unless length $title;
    my $subject = _text($args{subject}, 180) || $title;
    my $slug = _unique_announcement_slug($self->{db}->dbh, _slug($args{slug}) || slugify($title), $id);
    my $status = _announcement_status($args{status});
    my $manual = _body($args{manual_body}, 12000);
    my $sources = _digest_sources(%args);
    my $digest = $self->generate_digest(
        manual_body => $manual,
        sources     => $sources,
    );
    my $ts = now();
    my $dbh = $self->{db}->dbh;

    if ($id && $self->announcement_by_id($id)) {
        $dbh->do(
            q{
                UPDATE newsletter_announcements
                SET title = ?, subject = ?, slug = ?, status = ?, manual_body = ?,
                    digest_sources_json = ?, preview_text = ?, preview_html = ?, updated_at = ?
                WHERE id = ?
            },
            undef,
            $title, $subject, $slug, $status, $manual, encode_json($sources),
            $digest->{text}, $digest->{html}, $ts, $id
        );
    } else {
        $dbh->do(
            q{
                INSERT INTO newsletter_announcements
                    (title, subject, slug, status, manual_body, digest_sources_json,
                     preview_text, preview_html, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            $title, $subject, $slug, $status, $manual, encode_json($sources),
            $digest->{text}, $digest->{html}, $ts, $ts
        );
        $id = int($dbh->sqlite_last_insert_rowid);
    }
    return $self->announcement_by_id($id);
}

sub generate_digest {
    my ($self, %args) = @_;
    my $sources = $args{sources} && ref $args{sources} eq 'HASH' ? $args{sources} : {};
    my $manual = _body($args{manual_body}, 12000);
    my @sections;
    push @sections, _manual_section($manual) if length $manual;
    push @sections, $self->_source_section('Recent posts', _recent_posts($self)) if $sources->{posts};
    push @sections, $self->_source_section('Upcoming events', _recent_events($self)) if $sources->{events};
    push @sections, $self->_source_section('Directory updates', _recent_directory($self)) if $sources->{directory};
    push @sections, $self->_source_section('Catalog listings', _recent_shop($self)) if $sources->{shop};
    @sections = grep { $_ && @{$_->{items} || []} } @sections;

    my $text = '';
    my $html = '';
    for my $section (@sections) {
        $text .= $section->{title} . "\n" . ('-' x length($section->{title})) . "\n";
        $html .= '<h2>' . escape_html($section->{title}) . '</h2><ul>';
        for my $item (@{ $section->{items} }) {
            my $line = ($item->{title} || 'Untitled');
            $line .= ' - ' . $item->{summary} if length($item->{summary} || '');
            $line .= ' (' . $item->{url} . ')' if length($item->{url} || '');
            $text .= "* $line\n";
            my $title = escape_html($item->{title} || 'Untitled');
            my $summary = escape_html($item->{summary} || '');
            my $url = escape_html($item->{url} || '');
            my $link = length $url ? qq{<a href="$url">$title</a>} : $title;
            $html .= "<li><strong>$link</strong>";
            $html .= "<br><span>$summary</span>" if length $summary;
            $html .= '</li>';
        }
        $text .= "\n";
        $html .= '</ul>';
    }
    if (!length $text) {
        $text = "No digest items yet.\n";
        $html = '<p>No digest items yet.</p>';
    }
    return { text => $text, html => $html, sections => \@sections };
}

sub send_announcement {
    my ($self, %args) = @_;
    my $announcement = $self->announcement_by_id($args{id}) or die "announcement not found";
    my $readiness = $self->delivery_readiness;
    die "Newsletter delivery is not ready: $readiness->{summary}" unless $readiness->{send_ready};
    my $subscribers = $self->active_subscribers(limit => $args{limit} || 100000);
    die "there are no active newsletter subscribers" unless @{$subscribers};

    my $sent = 0;
    my $failed = 0;
    for my $subscriber (@{$subscribers}) {
        my ($text, $html) = $self->_message_for_subscriber($announcement, $subscriber);
        my ($ok, $message) = send_postmark(
            $self->{config},
            $self->{db},
            to         => $subscriber->{email},
            subject    => $announcement->{subject} || $announcement->{title},
            text_body  => $text,
            html_body  => $html,
            email_type => 'newsletter',
        );
        $ok ? ++$sent : ++$failed;
        $self->_record_send(
            announcement_id => $announcement->{id},
            subscriber_id   => $subscriber->{id},
            email           => $subscriber->{email},
            subject         => $announcement->{subject} || $announcement->{title},
            status          => $ok ? 'sent' : 'failed',
            error           => $ok ? '' : $message,
        );
    }
    if ($sent) {
        my $ts = now();
        $self->{db}->dbh->do(
            q{
                UPDATE newsletter_announcements
                SET status = 'sent', sent_at = COALESCE(sent_at, ?), updated_at = ?
                WHERE id = ?
            },
            undef,
            $ts, $ts, int($announcement->{id})
        );
    }
    return { sent => $sent, failed => $failed, total => scalar @{$subscribers} };
}

sub send_history {
    my ($self, %args) = @_;
    my $limit = _limit($args{limit}, 50, 1, 1000);
    return $self->{db}->dbh->selectall_arrayref(
        qq{
            SELECT h.*, a.title AS announcement_title
            FROM newsletter_send_history h
            LEFT JOIN newsletter_announcements a ON a.id = h.announcement_id
            ORDER BY h.created_at DESC, h.id DESC
            LIMIT $limit
        },
        { Slice => {} }
    );
}

sub unsubscribe_url {
    my ($self, $subscriber) = @_;
    return '' unless $subscriber && int($subscriber->{id} || 0) > 0;
    my $token = $self->_ensure_unsubscribe_token($subscriber);
    my $base = $self->{config}->get('site_url') || '';
    $base =~ s{/+\z}{};
    return $base . '/newsletter/unsubscribe/' . int($subscriber->{id}) . '/' . $token;
}

sub _message_for_subscriber {
    my ($self, $announcement, $subscriber) = @_;
    my $url = $self->unsubscribe_url($subscriber);
    my $text = $announcement->{preview_text} || '';
    $text .= "\nUnsubscribe: $url\n";
    my $html = $announcement->{preview_html} || '<p>No newsletter body.</p>';
    my $safe_url = escape_html($url);
    $html .= qq{<hr><p><a href="$safe_url">Unsubscribe</a></p>};
    return ($text, $html);
}

sub _ensure_unsubscribe_token {
    my ($self, $subscriber) = @_;
    return $subscriber->{unsubscribe_token} if length($subscriber->{unsubscribe_token} || '');
    my $token = random_hex(24);
    $self->{db}->dbh->do(
        'UPDATE newsletter_subscribers SET unsubscribe_token = ?, updated_at = ? WHERE id = ?',
        undef,
        $token,
        now(),
        int($subscriber->{id})
    );
    $subscriber->{unsubscribe_token} = $token;
    return $token;
}

sub _record_send {
    my ($self, %args) = @_;
    my $ts = now();
    $self->{db}->dbh->do(
        q{
            INSERT INTO newsletter_send_history
                (announcement_id, subscriber_id, email, subject, status, error, postmark_message_id, created_at, sent_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        int($args{announcement_id} || 0) || undef,
        int($args{subscriber_id} || 0) || undef,
        _email($args{email}),
        _text($args{subject}, 180),
        ($args{status} || '') eq 'sent' ? 'sent' : (($args{status} || '') eq 'failed' ? 'failed' : 'skipped'),
        _text($args{error}, 500),
        _text($args{postmark_message_id}, 160),
        $ts,
        ($args{status} || '') eq 'sent' ? $ts : undef
    );
}

sub _source_section {
    my ($self, $title, $items) = @_;
    return { title => $title, items => $items || [] };
}

sub _manual_section {
    my ($manual) = @_;
    my @items = grep { length } map { _text($_, 1000) } split /\n\s*\n/, $manual;
    @items = ($manual) unless @items;
    return {
        title => 'Announcement',
        items => [ map { { title => $_, summary => '', url => '' } } @items ],
    };
}

sub _recent_posts {
    my ($self) = @_;
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT title, slug, excerpt, published_at, updated_at
            FROM content_items
            WHERE type = 'post'
              AND status = 'published'
              AND deleted_at IS NULL
              AND COALESCE(access_policy, 'public') = 'public'
            ORDER BY published_at DESC, updated_at DESC
            LIMIT 6
        },
        { Slice => {} }
    );
    return [ map { {
        title => $_->{title} || 'Post',
        summary => $_->{excerpt} || '',
        url => '/posts/' . ($_->{slug} || '') . '/',
    } } @{$rows} ];
}

sub _recent_events {
    my ($self) = @_;
    my $settings = _settings($self);
    return [] unless DesertCMS::Modules::enabled($settings, 'events');
    my $events = eval { DesertCMS::Events->new(config => $self->{config}, db => $self->{db}) } or return [];
    my $rows = eval { $events->upcoming_occurrences(limit => 6) } || [];
    return [ map { {
        title => $_->{title} || 'Event',
        summary => $_->{summary} || '',
        url => '/events/' . ($_->{slug} || '') . '/' . ($_->{occurrence_key} || '') . '/',
    } } @{$rows} ];
}

sub _recent_directory {
    my ($self) = @_;
    my $settings = _settings($self);
    return [] unless DesertCMS::Modules::enabled($settings, 'directory');
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT title, slug, summary
            FROM directory_entries
            WHERE status = 'published'
              AND deleted_at IS NULL
            ORDER BY featured DESC, updated_at DESC, id DESC
            LIMIT 6
        },
        { Slice => {} }
    );
    return [ map { {
        title => $_->{title} || 'Directory entry',
        summary => $_->{summary} || '',
        url => '/directory/' . ($_->{slug} || '') . '/',
    } } @{$rows} ];
}

sub _recent_shop {
    my ($self) = @_;
    my $settings = _settings($self);
    return [] unless DesertCMS::Modules::enabled($settings, 'shop');
    my $rows = $self->{db}->dbh->selectall_arrayref(
        q{
            SELECT title, description
            FROM shop_listings
            WHERE active = 1
            ORDER BY updated_at DESC, id DESC
            LIMIT 6
        },
        { Slice => {} }
    );
    return [ map { {
        title => $_->{title} || 'Catalog listing',
        summary => $_->{description} || '',
        url => '/shop',
    } } @{$rows} ];
}

sub _settings {
    my ($self) = @_;
    return $self->{_settings} ||= DesertCMS::Settings::all($self->{config}, $self->{db});
}

sub _digest_sources {
    my (%args) = @_;
    if ($args{digest_sources_json}) {
        my $decoded = eval { decode_json($args{digest_sources_json}) };
        return _digest_sources(%{$decoded}) if $decoded && ref $decoded eq 'HASH';
    }
    return {
        posts     => _truthy($args{source_posts} // $args{posts} // 1),
        events    => _truthy($args{source_events} // $args{events} // 1),
        directory => _truthy($args{source_directory} // $args{directory} // 1),
        shop      => _truthy($args{source_shop} // $args{shop} // 1),
    };
}

sub _unique_announcement_slug {
    my ($dbh, $base, $id) = @_;
    $base = slugify($base || 'newsletter');
    $base = 'newsletter' unless length $base;
    my $slug = $base;
    my $suffix = 2;
    while (1) {
        my ($found) = $dbh->selectrow_array(
            'SELECT id FROM newsletter_announcements WHERE slug = ? AND id <> ? LIMIT 1',
            undef,
            $slug,
            int($id || 0)
        );
        return $slug unless $found;
        $slug = $base . '-' . $suffix++;
    }
}

sub _subscriber_status {
    my ($value) = @_;
    $value = lc($value || 'active');
    return $SUBSCRIBER_STATUS{$value} ? $value : 'active';
}

sub _announcement_status {
    my ($value) = @_;
    $value = lc($value || 'draft');
    return $ANNOUNCEMENT_STATUS{$value} ? $value : 'draft';
}

sub _source {
    my ($value) = @_;
    $value = lc($value || 'manual');
    return $value =~ /\A(?:public_signup|manual|import)\z/ ? $value : 'manual';
}

sub _email {
    my ($value) = @_;
    $value = lc(_text($value, 254));
    $value =~ s/\s+//g;
    return $value;
}

sub _valid_email {
    my ($value) = @_;
    return defined($value) && $value =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/ ? 1 : 0;
}

sub _slug {
    my ($value) = @_;
    return slugify(_text($value, 140));
}

sub _text {
    my ($value, $limit) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
    $value =~ s/^\s+|\s+\z//g;
    $limit ||= 255;
    return substr($value, 0, $limit);
}

sub _body {
    my ($value, $limit) = @_;
    $value = '' unless defined $value;
    $value =~ s/\r\n?/\n/g;
    $value =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
    $limit ||= 12000;
    return substr($value, 0, $limit);
}

sub _terms {
    my ($value) = @_;
    my @terms = grep { length } map { _text($_, 60) } split /\s*,\s*/, $value || '';
    my %seen;
    @terms = grep { !$seen{lc $_}++ } @terms;
    return join(', ', @terms);
}

sub _merge_terms {
    my (@values) = @_;
    return _terms(join(', ', grep { defined && length } @values));
}

sub _limit {
    my ($value, $default, $min, $max) = @_;
    $value = int($value || $default || 0);
    $value = $min if $value < $min;
    $value = $max if $value > $max;
    return $value;
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '';
    return 0 if "$value" =~ /\A(?:0|false|no|off)\z/i;
    return 1;
}

sub _csv {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

1;
