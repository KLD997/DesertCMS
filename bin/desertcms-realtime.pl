#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use IO::Socket::INET;
use DesertCMS::Config;
use DesertCMS::Realtime;
use DesertCMS::Util qw(url_decode);

my $config = DesertCMS::Config->load;
my $status = DesertCMS::Realtime->service_status($config);
my $host = $status->{host} || '127.0.0.1';
my $port = int($status->{port} || 8787);

my $server = IO::Socket::INET->new(
    LocalAddr => $host,
    LocalPort => $port,
    Proto     => 'tcp',
    Listen    => 16,
    ReuseAddr => 1,
) or die "cannot start desertcms realtime on $host:$port: $!";

while (my $client = $server->accept) {
    $client->autoflush(1);
    my $request = <$client> || '';
    my ($target) = $request =~ m{\AGET\s+(\S+)};
    my ($path, $query) = split /\?/, ($target || ''), 2;
    my %headers;
    while (defined(my $line = <$client>)) {
        last if $line =~ /^\r?\n\z/;
        if ($line =~ /\A([^:]+):\s*(.*?)\s*\r?\n\z/) {
            $headers{lc $1} = $2;
        }
    }
    if (($path || '') eq '/health') {
        print {$client} "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nok\n";
    } elsif (($path || '') eq '/events') {
        my %params = _query_params($query || '');
        if (!DesertCMS::Realtime->origin_allowed($config, $headers{origin} || '', host_header => $headers{host} || '')) {
            print {$client} "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nVary: Origin\r\nConnection: close\r\n\r\norigin forbidden\n";
        } else {
            my $cors = DesertCMS::Realtime->cors_headers(
                $config,
                $headers{origin} || '',
                host_header => $headers{host} || '',
            );
            if (!DesertCMS::Realtime->channel_request_authorized(
                $config,
                channel => $params{channel} || '',
                token   => $params{token} || '',
            )) {
                print {$client} "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n$cors" . "Connection: close\r\n\r\nprivate realtime channel forbidden\n";
            } else {
                my $events = eval {
                    DesertCMS::Realtime->recent_events(
                        $config,
                        channel => $params{channel} || '',
                        limit   => $params{limit} || 100,
                    );
                };
                if (!$events) {
                    print {$client} "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n$cors" . "Connection: close\r\n\r\nbad realtime channel\n";
                } else {
                    print {$client} "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n$cors" . "Connection: close\r\n\r\n";
                    print {$client} DesertCMS::Realtime->sse_prelude;
                    if (@{$events}) {
                        print {$client} DesertCMS::Realtime->sse_event($_) for @{$events};
                    } else {
                        print {$client} DesertCMS::Realtime->sse_event({ type => 'dashboard.widget', channel => 'dashboard.widgets', data => { status => 'ready' } });
                    }
                }
            }
        }
    } elsif (($path || '') eq '/ws') {
        my %params = _query_params($query || '');
        if (!DesertCMS::Realtime->origin_allowed($config, $headers{origin} || '', host_header => $headers{host} || '')) {
            print {$client} "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nVary: Origin\r\nConnection: close\r\n\r\norigin forbidden\n";
        } elsif (!DesertCMS::Realtime->channel_request_authorized(
            $config,
            channel => $params{channel} || '',
            token   => $params{token} || '',
        )) {
            print {$client} "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nVary: Origin\r\nConnection: close\r\n\r\nprivate realtime channel forbidden\n";
        } else {
            my $upgrade = lc($headers{upgrade} || '');
            my $key = $headers{'sec-websocket-key'} || '';
            my $accept = eval {
                die "websocket upgrade is required" unless $upgrade eq 'websocket';
                DesertCMS::Realtime->websocket_accept_key($key);
            };
            if (!$accept) {
                print {$client} "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nbad websocket request\n";
            } else {
                my $frame = eval {
                    DesertCMS::Realtime->websocket_snapshot_frame(
                        $config,
                        channel => $params{channel} || '',
                        limit   => $params{limit} || 100,
                    );
                };
                if (!defined $frame) {
                    print {$client} "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nbad realtime channel\n";
                } else {
                    print {$client} "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\nCache-Control: no-store\r\nVary: Origin\r\n\r\n";
                    print {$client} $frame;
                }
            }
        }
    } else {
        print {$client} "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nnot found\n";
    }
    close $client;
}

sub _query_params {
    my ($query) = @_;
    my %params;
    for my $pair (split /&/, $query || '') {
        my ($key, $value) = split /=/, $pair, 2;
        next unless defined $key && length $key;
        $params{url_decode($key)} = url_decode(defined $value ? $value : '');
    }
    return %params;
}
