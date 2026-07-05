package DesertCMS::Email;

use strict;
use warnings;
use Exporter 'import';
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use DesertCMS::Config;
use DesertCMS::DB;
use DesertCMS::Settings;
use DesertCMS::Util qw(now random_hex);

our @EXPORT_OK = qw(
    send_postmark
    resolved_postmark_settings
    postmark_https_transport_status
    email_readiness
    email_delivery_logs
    record_postmark_webhook
    postmark_template_previews
    generate_webhook_token
);

sub send_postmark {
    my ($config, $db, %args) = @_;
    my $resolved = resolved_postmark_settings($config, $db);
    my $token = $resolved->{token} || '';
    my $from = _normalize_email($resolved->{from_email} || '');
    my $to = _normalize_email($args{to} || '');
    my $subject = $args{subject} || 'DesertCMS';
    my $email_type = _clean_type($args{email_type} || 'transactional');

    if (!length $token || !_valid_email($from)) {
        _record_delivery(
            $db,
            email_type => $email_type,
            status     => 'skipped',
            from_email => $from,
            to_email   => $to,
            subject    => $subject,
            reason     => 'Postmark is not configured',
            response   => { source => $resolved->{source} || '', sender_mode => $resolved->{sender_mode} || '' },
        );
        return (0, 'Postmark is not configured');
    }
    if (!_valid_email($to)) {
        _record_delivery(
            $db,
            email_type => $email_type,
            status     => 'failed',
            from_email => $from,
            to_email   => $to,
            subject    => $subject,
            reason     => 'recipient email is invalid',
        );
        return (0, 'recipient email is invalid');
    }

    my $transport = postmark_https_transport_status();
    if (!$transport->{ok}) {
        my $reason = $transport->{detail} || 'HTTPS transport is not available for Postmark.';
        _record_delivery(
            $db,
            email_type => $email_type,
            status     => 'failed',
            from_email => $from,
            to_email   => $to,
            subject    => $subject,
            reason     => "Postmark send failed: $reason",
            response   => {
                transport    => 'https',
                missing      => $transport->{missing} || [],
                install_hint => $transport->{install_hint} || '',
            },
        );
        return (0, "Postmark send failed: $reason");
    }

    my $payload = {
        From     => $from,
        To       => $to,
        Subject  => $subject,
        TextBody => $args{text_body} || '',
        HtmlBody => $args{html_body} || _html_paragraphs($args{text_body} || ''),
    };

    my $response = eval {
        HTTP::Tiny->new(timeout => 10, verify_SSL => 1)->post(
            'https://api.postmarkapp.com/email',
            {
                headers => {
                    'Accept'                  => 'application/json',
                    'Content-Type'            => 'application/json',
                    'X-Postmark-Server-Token' => $token,
                },
                content => encode_json($payload),
            }
        );
    };
    if (!$response || ref $response ne 'HASH') {
        my $reason = _clean_response_excerpt($@ || 'unknown HTTPS transport error');
        $reason = 'unknown HTTPS transport error' unless length $reason;
        _record_delivery(
            $db,
            email_type => $email_type,
            status     => 'failed',
            from_email => $from,
            to_email   => $to,
            subject    => $subject,
            reason     => "Postmark send failed: $reason",
            response   => {
                transport => 'https',
                exception => $reason,
            },
        );
        return (0, "Postmark send failed: $reason");
    }

    my $json = $response->{content} ? eval { decode_json($response->{content}) } : undef;
    if ($response->{success}) {
        my $message_id = $json && ($json->{MessageID} || $json->{MessageId}) ? ($json->{MessageID} || $json->{MessageId}) : '';
        _record_delivery(
            $db,
            email_type => $email_type,
            status     => 'sent',
            message_id => $message_id,
            from_email => $from,
            to_email   => $to,
            subject    => $subject,
            reason     => 'sent',
            response   => $json || { status => $response->{status} || '' },
            sent_at    => now(),
        );
        return (1, 'sent');
    }

    my $reason = _postmark_failure_reason($response, $json);
    _record_delivery(
        $db,
        email_type => $email_type,
        status     => 'failed',
        from_email => $from,
        to_email   => $to,
        subject    => $subject,
        reason     => "Postmark send failed: $reason",
        response   => $json || {
            status  => $response->{status} || '',
            reason  => $response->{reason} || '',
            content => _clean_response_excerpt($response->{content} || ''),
        },
    );
    return (0, "Postmark send failed: $reason");
}

sub resolved_postmark_settings {
    my ($config, $db, $settings) = @_;
    $settings ||= eval { DesertCMS::Settings::all($config, $db) } || {};
    my $is_contributor = _is_contributor_instance($config);
    my $mode = _clean_sender_mode($settings->{postmark_sender_mode} || $config->get('postmark_sender_mode') || '');
    $mode ||= $is_contributor ? 'inherit' : 'site';
    $mode = 'site' unless $is_contributor || $mode eq 'site';
    $mode = 'inherit'
        if $is_contributor
        && $mode eq 'site'
        && !_truthy($settings->{contributor_allow_postmark_sender_override});

    my $local = {
        sender_mode   => $mode,
        source        => 'site',
        source_label  => 'This CMS instance',
        from_email    => _normalize_email($settings->{postmark_from_email} || $config->get('postmark_from_email') || ''),
        token         => $settings->{postmark_server_token} || $config->get('postmark_server_token') || '',
        recipient     => _normalize_email($settings->{contributor_request_recipient_email} || ''),
        webhook_token => $settings->{postmark_webhook_token} || $config->get('postmark_webhook_token') || '',
    };

    if ($is_contributor && $mode eq 'inherit') {
        my $master = _master_postmark_settings($config);
        if ($master && _valid_email($master->{from_email}) && length($master->{token} || '')) {
            return {
                %{$local},
                source       => 'master',
                source_label => 'Master CMS',
                from_email   => $master->{from_email},
                token        => $master->{token},
                recipient    => $master->{recipient} || $local->{recipient},
            };
        }
        if (_valid_email($local->{from_email}) && length($local->{token})) {
            return {
                %{$local},
                source       => 'inherited_snapshot',
                source_label => 'Inherited provisioning snapshot',
            };
        }
        return {
            %{$local},
            source       => 'inherit_missing',
            source_label => 'Master CMS unavailable',
        };
    }

    return $local;
}

sub postmark_https_transport_status {
    my @missing;
    my @errors;
    my $ssl_ok = _load_postmark_https_module(
        module  => 'IO::Socket::SSL',
        path    => 'IO/Socket/SSL.pm',
        version => '1.42',
    );
    if (!$ssl_ok) {
        my $error = _clean_response_excerpt($@ || 'not available');
        push @missing, 'IO::Socket::SSL 1.42 (p5-IO-Socket-SSL)';
        push @errors, 'IO::Socket::SSL: ' . $error . _module_path_diagnostic('IO/Socket/SSL.pm');
    }

    my $ssleay_ok = _load_postmark_https_module(
        module  => 'Net::SSLeay',
        path    => 'Net/SSLeay.pm',
        version => '1.49',
    );
    if (!$ssleay_ok) {
        my $error = _clean_response_excerpt($@ || 'not available');
        push @missing, 'Net::SSLeay 1.49 (p5-Net-SSLeay)';
        push @errors, 'Net::SSLeay: ' . $error . _module_path_diagnostic('Net/SSLeay.pm');
    }

    my $hint = 'OpenBSD: doas pkg_add p5-IO-Socket-SSL p5-Net-SSLeay, then restart desertcms_slowcgi.';
    return {
        ok           => @missing ? 0 : 1,
        missing      => \@missing,
        install_hint => $hint,
        detail       => @missing
            ? 'HTTPS transport is not available. Install OpenBSD packages p5-IO-Socket-SSL and p5-Net-SSLeay, then restart desertcms_slowcgi. Missing Perl modules: '
                . join('; ', @errors)
            : 'Perl HTTPS transport is available for Postmark.',
    };
}

sub _load_postmark_https_module {
    my (%args) = @_;
    my $module = $args{module} || '';
    my $path = $args{path} || '';
    my $version = $args{version} || 0;

    my $ok = eval {
        if ($module eq 'IO::Socket::SSL') {
            require IO::Socket::SSL;
            IO::Socket::SSL->VERSION($version);
        } elsif ($module eq 'Net::SSLeay') {
            require Net::SSLeay;
            Net::SSLeay->VERSION($version);
        } else {
            die "unsupported module $module";
        }
        1;
    };
    return 1 if $ok;

    my $require_error = $@ || '';
    my $candidate = _first_readable_module_path($path);
    if ($candidate) {
        my $direct_ok = eval {
            my $loaded = do $candidate;
            die($@ || "could not load $candidate") unless $loaded;
            $INC{$path} ||= $candidate;
            if ($module eq 'IO::Socket::SSL') {
                IO::Socket::SSL->VERSION($version);
            } elsif ($module eq 'Net::SSLeay') {
                Net::SSLeay->VERSION($version);
            }
            1;
        };
        return 1 if $direct_ok;
        $@ = ($@ || 'direct module load failed') . '; require failed first: ' . $require_error;
        return 0;
    }

    $@ = $require_error;
    return 0;
}

sub _first_readable_module_path {
    my ($module_path) = @_;
    return '' unless length($module_path || '');
    for my $inc (@INC) {
        next if ref $inc || !defined $inc || !length $inc;
        my $candidate = "$inc/$module_path";
        return $candidate if -f $candidate && -r $candidate;
    }
    return '';
}

sub _module_path_diagnostic {
    my ($module_path) = @_;
    my @checks;
    for my $inc (@INC) {
        next if ref $inc || !defined $inc || !length $inc;
        my $candidate = "$inc/$module_path";
        push @checks, "$candidate exists=" . (-e $candidate ? 1 : 0) . ' readable=' . (-r $candidate ? 1 : 0);
    }
    return @checks ? ' Paths checked: ' . join('; ', @checks) : '';
}

sub email_readiness {
    my ($config, $db) = @_;
    my $settings = eval { DesertCMS::Settings::all($config, $db) } || {};
    my $resolved = resolved_postmark_settings($config, $db, $settings);
    my $transport = postmark_https_transport_status();
    my $from_ok = _valid_email($resolved->{from_email} || '');
    my $token_ok = length($resolved->{token} || '') ? 1 : 0;
    my $recipient_ok = _valid_email($settings->{contributor_request_recipient_email} || '');
    my $webhook_ok = length($settings->{postmark_webhook_token} || '') ? 1 : 0;
    my $last_test = _latest_log($db, 'postmark_test');
    my $last_event = _latest_delivery_event($db);
    my $last_bad = $last_event && _bad_delivery_status($last_event->{status}) ? $last_event : undef;

    return {
        resolved => $resolved,
        checks   => [
            {
                key    => 'https_transport',
                label  => 'HTTPS transport',
                state  => $transport->{ok} ? 'ok' : 'warn',
                status => $transport->{ok} ? 'Ready' : 'Missing modules',
                detail => $transport->{ok}
                    ? 'The OpenBSD Perl HTTPS modules are available for Postmark sends.'
                    : ($transport->{detail} || $transport->{install_hint} || 'Install p5-IO-Socket-SSL and p5-Net-SSLeay.'),
            },
            {
                key    => 'sender',
                label  => 'Sender',
                state  => $from_ok ? 'ok' : 'warn',
                status => $from_ok ? 'Configured' : 'Missing',
                detail => $from_ok
                    ? $resolved->{from_email} . ' via ' . ($resolved->{source_label} || 'this site')
                    : 'Save a verified Postmark sender address.',
            },
            {
                key    => 'token',
                label  => 'Server token',
                state  => $token_ok ? 'ok' : 'warn',
                status => $token_ok ? 'Saved' : 'Missing',
                detail => $token_ok ? 'A Postmark server token is available for sends.' : 'Paste the Postmark server token.',
            },
            {
                key    => 'recipient',
                label  => 'Request inbox',
                state  => $recipient_ok ? 'ok' : 'warn',
                status => $recipient_ok ? 'Configured' : 'Missing',
                detail => $recipient_ok ? $settings->{contributor_request_recipient_email} : 'Set the receiving email for contributor requests.',
            },
            {
                key    => 'test',
                label  => 'Verified sender test',
                state  => $last_test && ($last_test->{status} || '') eq 'sent' ? 'ok' : 'warn',
                status => $last_test && ($last_test->{status} || '') eq 'sent' ? 'Sent' : 'Needs test',
                detail => $last_test
                    ? _time_label($last_test->{sent_at} || $last_test->{created_at}) . ' to ' . ($last_test->{to_email} || '')
                    : 'Send a test after the sender is verified in Postmark.',
            },
            {
                key    => 'webhook',
                label  => 'Bounce/spam webhook',
                state  => $webhook_ok ? 'ok' : 'warn',
                status => $webhook_ok ? 'Ready' : 'Missing',
                detail => $webhook_ok ? 'Use the endpoint below in Postmark webhooks.' : 'Save settings to generate a webhook endpoint token.',
            },
            {
                key    => 'deliverability',
                label  => 'Recent delivery health',
                state  => $last_bad ? 'warn' : 'ok',
                status => $last_bad ? ucfirst($last_bad->{status}) : 'Clean',
                detail => $last_bad
                    ? _time_label($last_bad->{updated_at} || $last_bad->{created_at}) . ' ' . ($last_bad->{to_email} || '')
                    : 'No recent failures, bounces, or spam complaints recorded.',
            },
        ],
    };
}

sub email_delivery_logs {
    my ($config, $db, %args) = @_;
    return [] unless $db;
    my $limit = int($args{limit} || 25);
    $limit = 25 if $limit < 1 || $limit > 100;
    return eval {
        $db->dbh->selectall_arrayref(
            q{
                SELECT *
                FROM email_delivery_logs
                ORDER BY created_at DESC, id DESC
                LIMIT ?
            },
            { Slice => {} },
            $limit
        );
    } || [];
}

sub record_postmark_webhook {
    my ($config, $db, %args) = @_;
    my $settings = eval { DesertCMS::Settings::all($config, $db) } || {};
    my $expected = $settings->{postmark_webhook_token} || $config->get('postmark_webhook_token') || '';
    return { ok => 0, status => 403, error => 'Postmark webhook token is not configured' }
        unless length $expected;
    return { ok => 0, status => 403, error => 'Postmark webhook token is invalid' }
        unless defined $args{token} && $args{token} eq $expected;

    my $event = eval { decode_json($args{body} || '{}') };
    return { ok => 0, status => 400, error => 'Invalid Postmark webhook JSON' }
        unless $event && ref $event eq 'HASH';

    my $message_id = _first_value($event, qw(MessageID MessageId MessageID));
    my $to = _normalize_email(_first_value($event, qw(Email Recipient To)));
    my $event_type = _postmark_event_type($event);
    my $reason = _first_value($event, qw(Description Details Message Name Type RecordType)) || $event_type;
    my $ts = now();

    eval {
        my $dbh = $db->dbh;
        if (length $message_id) {
            my $updated = $dbh->do(
                q{
                    UPDATE email_delivery_logs
                    SET status = ?,
                        reason = ?,
                        webhook_event_json = ?,
                        updated_at = ?,
                        last_event_at = ?
                    WHERE message_id = ?
                },
                undef,
                $event_type,
                substr($reason, 0, 1000),
                encode_json($event),
                $ts,
                $ts,
                $message_id
            );
            return if $updated && $updated > 0;
        }
        _record_delivery(
            $db,
            email_type => 'postmark_webhook',
            status     => $event_type,
            message_id => $message_id,
            to_email   => $to,
            subject    => _first_value($event, qw(Subject)) || '',
            reason     => $reason,
            webhook    => $event,
            last_event_at => $ts,
        );
        1;
    };

    return {
        ok         => 1,
        status     => 200,
        event_type => $event_type,
        message_id => $message_id,
    };
}

sub postmark_template_previews {
    my ($config, $db) = @_;
    my $settings = eval { DesertCMS::Settings::all($config, $db) } || {};
    my $site_name = $settings->{site_name} || $config->get('site_name') || 'DesertCMS';
    my $base = $config->get('site_url') || 'https://example.com';
    $base =~ s{/+\z}{};
    my $contributor_domain = 'alexs.example.com';
    my @templates = (
        {
            key     => 'contributor_invite',
            label   => 'Contributor invite',
            subject => "Invitation to create your $site_name site",
            text    => join("\n\n", "You have been invited to create a contributor site on $site_name.", 'Accept the invite here:', "$base/admin/invite/example-token"),
        },
        {
            key     => 'contributor_request_received',
            label   => 'Request received notification',
            subject => 'New contributor request from Alex Smith',
            text    => join("\n\n", 'A new contributor request was submitted.', 'Name: Alex Smith', 'Email: alex@example.com', 'Review:', "$base/admin/settings/contributors/requests/1"),
        },
        {
            key     => 'contributor_request_approved',
            label   => 'Request approved',
            subject => "Your $site_name contributor request was approved",
            text    => join("\n\n", 'Congratulations. Your contributor request was approved.', 'Complete your public contributor profile here:', "$base/contributors/profile/example-token", "Your contributor site is being created at https://$contributor_domain/.", 'You will receive your temporary admin setup email as soon as provisioning is complete.'),
        },
        {
            key     => 'contributor_request_denied',
            label   => 'Request denied',
            subject => "Your $site_name contributor request",
            text    => join("\n\n", "Thank you for your interest in becoming a contributor to $site_name.", 'We are sorry, but you were not selected at this time.'),
        },
        {
            key     => 'contributor_access_grant',
            label   => 'Contributor access grant',
            subject => "Access to $contributor_domain",
            text    => join("\n\n", "You have been granted access to the contributor CMS for $contributor_domain.", "Admin URL: https://$contributor_domain/admin", 'Username: alex', 'Temporary password: example-temporary-password'),
        },
    );
    return \@templates;
}

sub generate_webhook_token {
    return random_hex(24);
}

sub _record_delivery {
    my ($db, %args) = @_;
    return unless $db;
    my $ts = now();
    eval {
        $db->dbh->do(
            q{
                INSERT INTO email_delivery_logs
                    (provider, message_id, email_type, status, from_email, to_email, subject, reason,
                     provider_response_json, webhook_event_json, created_at, updated_at, sent_at, last_event_at)
                VALUES
                    ('postmark', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            },
            undef,
            substr($args{message_id} || '', 0, 200),
            substr($args{email_type} || 'transactional', 0, 80),
            substr($args{status} || 'unknown', 0, 40),
            substr(_normalize_email($args{from_email} || ''), 0, 180),
            substr(_normalize_email($args{to_email} || ''), 0, 180),
            substr($args{subject} || '', 0, 300),
            substr($args{reason} || '', 0, 1000),
            encode_json($args{response} || {}),
            encode_json($args{webhook} || {}),
            $ts,
            $ts,
            $args{sent_at},
            $args{last_event_at}
        );
        1;
    };
}

sub _postmark_failure_reason {
    my ($response, $json) = @_;
    return $json->{Message} if $json && $json->{Message};
    my $reason = $response->{reason} || $response->{status} || 'unknown Postmark error';
    my $content = _clean_response_excerpt($response->{content} || '');
    return length $content ? "$reason: $content" : $reason;
}

sub _clean_response_excerpt {
    my ($content) = @_;
    $content = '' unless defined $content;
    $content =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]+/ /g;
    $content =~ s/\s+/ /g;
    $content =~ s/^\s+|\s+\z//g;
    return substr($content, 0, 500);
}

sub _latest_log {
    my ($db, $email_type) = @_;
    return undef unless $db;
    return eval {
        $db->dbh->selectrow_hashref(
            q{
                SELECT *
                FROM email_delivery_logs
                WHERE email_type = ?
                ORDER BY created_at DESC, id DESC
                LIMIT 1
            },
            undef,
            $email_type
        );
    };
}

sub _latest_status {
    my ($db, $statuses) = @_;
    return undef unless $db && $statuses && @{$statuses};
    my $placeholders = join ',', map { '?' } @{$statuses};
    return eval {
        $db->dbh->selectrow_hashref(
            qq{
                SELECT *
                FROM email_delivery_logs
                WHERE status IN ($placeholders)
                ORDER BY updated_at DESC, id DESC
                LIMIT 1
            },
            undef,
            @{$statuses}
        );
    };
}

sub _latest_delivery_event {
    my ($db) = @_;
    return undef unless $db;
    return eval {
        $db->dbh->selectrow_hashref(
            q{
                SELECT *
                FROM email_delivery_logs
                ORDER BY updated_at DESC, id DESC
                LIMIT 1
            }
        );
    };
}

sub _bad_delivery_status {
    my ($status) = @_;
    $status = lc($status || '');
    return $status =~ /\A(?:bounced|spam|complaint|failed)\z/ ? 1 : 0;
}

sub _truthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value eq '' || $value eq '0';
    return 0 if $value =~ /\A(?:false|no|off)\z/i;
    return 1;
}

sub _master_postmark_settings {
    my ($config) = @_;
    my $current = $config->get('path') || '';
    my $path = $config->get('master_config_path') || '';
    if (!length $path && $current ne '/etc/desertcms.conf' && -f '/etc/desertcms.conf') {
        $path = '/etc/desertcms.conf';
    }
    return undef unless length $path && $path ne $current && -f $path;
    return eval {
        my $master_config = DesertCMS::Config->load($path);
        my $master_db = DesertCMS::DB->new(config => $master_config);
        my $settings = DesertCMS::Settings::all($master_config, $master_db);
        {
            from_email => _normalize_email($settings->{postmark_from_email} || $master_config->get('postmark_from_email') || ''),
            token      => $settings->{postmark_server_token} || $master_config->get('postmark_server_token') || '',
            recipient  => _normalize_email($settings->{contributor_request_recipient_email} || ''),
        };
    };
}

sub _postmark_event_type {
    my ($event) = @_;
    my $record = lc(_first_value($event, qw(RecordType Type Name)) || '');
    if ($record =~ /spam|complaint/) {
        return 'spam';
    }
    if ($record =~ /bounce/) {
        return 'bounced';
    }
    if ($record =~ /deliver/) {
        return 'delivered';
    }
    if ($record =~ /open/) {
        return 'opened';
    }
    if ($record =~ /click/) {
        return 'clicked';
    }
    return $record =~ /\S/ ? substr($record, 0, 40) : 'webhook';
}

sub _first_value {
    my ($hash, @keys) = @_;
    return '' unless $hash && ref $hash eq 'HASH';
    for my $key (@keys) {
        return $hash->{$key} if defined $hash->{$key} && !ref $hash->{$key} && length "$hash->{$key}";
    }
    return '';
}

sub _html_paragraphs {
    my ($text) = @_;
    my @parts = split /\n{2,}/, $text || '';
    return join '', map { '<p>' . _html($_) . '</p>' } @parts;
}

sub _normalize_email {
    my ($email) = @_;
    $email = lc($email || '');
    $email =~ s/^\s+|\s+$//g;
    return $email;
}

sub _valid_email {
    my ($email) = @_;
    return $email =~ /\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z/ ? 1 : 0;
}

sub _clean_sender_mode {
    my ($mode) = @_;
    $mode = lc($mode || '');
    $mode =~ s/^\s+|\s+$//g;
    return $mode =~ /\A(?:site|inherit)\z/ ? $mode : '';
}

sub _clean_type {
    my ($type) = @_;
    $type = lc($type || '');
    $type =~ s/[^a-z0-9_.:-]+/_/g;
    return substr($type || 'transactional', 0, 80);
}

sub _is_contributor_instance {
    my ($config) = @_;
    return 1 if $config && length($config->get('contributor_site_id') || '');
    return 1 if $config && length($config->get('contributor_domain') || '');
    return 0;
}

sub _time_label {
    my ($epoch) = @_;
    return 'Never' unless $epoch;
    return scalar localtime($epoch);
}

sub _html {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    $value =~ s/\n/<br>/g;
    return $value;
}

1;
