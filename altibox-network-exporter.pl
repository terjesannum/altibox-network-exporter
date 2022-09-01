#!/usr/bin/env perl
# Prometheus exporter for altibox network
# Author: Terje Sannum <terje@offpiste.org>
# URL: https://github.com/terjesannum/altibox-network-exporter

use strict;
use HTTP::Cookies;
use HTTP::Response;
use JSON;
use LWP::UserAgent;
use Time::HiRes qw(gettimeofday);
use URI;
use Prometheus::Tiny;
use HTTP::Daemon;

$|=1;

print "Starting...\n";
sleep(10); # Pause 10 seconds to avoid spamming in case of a container in crash loop
my($user) = $ENV{'ALTIBOX_USER'};
my($password) = $ENV{'ALTIBOX_PASSWORD'};
my($verbose) = $ENV{'ALTIBOX_VERBOSE'} || 0;
my($api_url) = 'https://www.altibox.no/api/wifi/getlandevices';
my(%api_query_params) = ( activeOnly => 'false' );
my $cookies = HTTP::Cookies->new();
my $ua = LWP::UserAgent->new;
$ua->ssl_opts(SSL_cipher_list => 'DEFAULT:!DH');
$ua->cookie_jar($cookies);
push @{$ua->requests_redirectable}, 'POST';
my($site_id);
my($prom) = Prometheus::Tiny->new;
$prom->declare("altibox_network_client",
               help => "Connection status of network client",
               type => 'gauge');
$prom->declare("altibox_network_client_wifi_rssi",
               help => "Signal strength of connected wifi client",
               type => 'gauge');
authenticate();

my $d = HTTP::Daemon->new(
    LocalAddr => '0.0.0.0',
    LocalPort => 8080,
    );
print "HTTP server ready\n";

while(my $c = $d->accept) {
    while(my $req = $c->get_request) {
        my $res = HTTP::Response->new(200);
        $res->header("Content-Type" => "text/plain; version=0.0.4");
        $res->content(get_metrics());
        $c->send_response($res);
    }
    $c->close;
    undef($c);
}

sub get_metrics {
    $prom->clear;
    for(my $retry = 0; $retry < 3; $retry++) {
        verbose("========== Query api\n");
        my(%query_params) = (( siteid => $site_id,
                               _ => sprintf("%s000", time())),
                             %api_query_params);
        my($uri) = URI->new($api_url);
        $uri->query_form(%query_params);
        my($res) = $ua->get($uri);
        unless($res->is_success) {
            printf STDERR ("Query API failed: %s\n", $res->status_line);
            sleep(10);
            authenticate();
            next;
        }
        my($json) = decode_json($res->content);
        if($json->{'status'} eq 'notAuthenticated') {
            print STDERR "Query API failed: Not authenticated\n";
            sleep(10);
            authenticate();
            next;
        }
        foreach my $client (@{$json->{'networkClients'}}) {
            my($name) = $client->{"hostname"} || '';
            my($manufacturer) = $client->{"manufacturer"} || '';
            my($connected_to) = $client->{"connectionType"} eq 'DISCONNECTED' ? '' : $client->{"connectedTo"};
            my($port) = ($client->{"connectionType"} eq 'DISCONNECTED' ? '' : $client->{"portName"}) || '';
            $prom->set("altibox_network_client", $client->{'connectionType'} eq 'DISCONNECTED' ? 0 : 1,
                       {"name" => $name,
                            "manufacturer" => $manufacturer,
                            "mac" => $client->{'macAddress'},
                            "ip" => $client->{'ipAddress'},
                            "connected_to" => $connected_to,
                            "port" => $port,
                            "connection" => $client->{'connectionType'}
                       });
            next if(!$client->{"wifi"});
            $prom->set("altibox_network_client_wifi_rssi", $client->{'wifiRssi'},
                       {"name" => $name,
                            "manufacturer" => $manufacturer,
                            "mac" => $client->{'macAddress'},
                            "ip" => $client->{'ipAddress'},
                            "connected_to" => $connected_to,
                            "connection" => $client->{'connectionType'}
                       });
        }
        last;
    }
    return $prom->format;
}

sub authenticate {
    verbose("========== Get base data\n");
    my $res = $ua->get('https://www.altibox.no/altibox/js/altibox.min.js');
    die $res->status_line unless($res->is_success);
    my($client_id, $scope, $client_secret) = $res->content =~ m|{baseUrl:\"https://idconnect.cloud\",client_id:\"(.+?)\",scope:\"(.+?)\",client_secret:\"(.+?)\"|;
    die "client_id not found\n" unless $client_id;
    die "scope not found\n" unless $scope;
    die "client_secret not found\n" unless $client_secret;
    verbose("client_id: %s\nscope: %s\nclient_secret: %s\n", $client_id, $scope, $client_secret);
    
    verbose("========== Get entity id\n");
    my %query_params = (client_id     => $client_id,
                        locale        => 'no',
                        redirect_uri  => 'https://www.altibox.no/auth/callback/',
                        response_type => 'code',
                        scope         => $scope,
                        state         => '/mine-sider/',
                        template      => 'altibox'
        );
    my $uri = URI->new("https://idconnect.cloud/uas/oauth2/authorization");
    $uri->query_form(%query_params);
    $res = $ua->get($uri);
    die $res->status_line unless($res->is_success);
    my($redirres) = $res->previous;
    die "Unexpected response\n" unless($redirres);
    my($entity_id) = $redirres->header("Location") =~ /[?&]_id=([^&]+)/;
    die sprintf("Couldn't find id in url: %s\n", $redirres->header("Location")) unless($entity_id);
    verbose("entity_id: %s\n", $entity_id);

    verbose("========== Logging in\n");
    %query_params = ( entityID => $entity_id,
                      locale   => 'no'
        );
    my %query_data = ( username => $user,
                       password => $password,
                       method   => 'password.2'
        );
    $uri = URI->new(sprintf("https://idconnect.cloud/uas/authn/%s/submit", $entity_id));
    $uri->query_form(%query_params);
    $res = $ua->post($uri, \%query_data);
    die $res->status_line unless($res->is_success);
    die "Login failed" unless($res->content =~ /Du er logget inn/);
    my($code) = $res->content =~ /name="code" value="(.*?)"/;
    die "code not found\n" unless $code;
    verbose("code: %s\n", $code);

    verbose("========== Get token\n");
    %query_data = ( client_id => $client_id,
                    client_secret => $client_secret,
                    code => $code,
                    grant_type => 'authorization_code',
                    redirect_uri => 'https://www.altibox.no/auth/callback/'
        );
    $uri = URI->new('https://idconnect.cloud/uas/oauth2/token');
    $res = $ua->post($uri, \%query_data);
    die $res->status_line unless($res->is_success);
    my $json = decode_json($res->content);
    my $token = $json->{'access_token'};
    die "No access token\n" unless($token);
    verbose("token: %s\n", $token);
    $cookies->set_cookie(0, 'sso_access_token', $token, '/', 'www.altibox.no');

    verbose("========== Get api session ticket\n");
    $uri = URI->new('https://www.altibox.no/api/authentication/token');
    $res = $ua->post($uri,
                     Authorization => sprintf("Bearer %s", $token));
    die $res->status_line unless($res->is_success);
    $json = decode_json($res->content);
    my $ticket = $json->{'data'}->{'sessionTicket'}->{'identifier'};
    die "No session ticket\n" unless($ticket);
    verbose("ticket: %s\n", $ticket);
    $cookies->set_cookie(0, 'sessionTicketApi', $ticket, '/', 'www.altibox.no');

    verbose("========== Get site_id\n");
    $uri = URI->new('https://www.altibox.no/api/customer/servicelocations');
    $res = $ua->get($uri,
                    "SessionTicket" => $ticket);
    die $res->status_line unless($res->is_success);
    $json = decode_json($res->content);
    $site_id = $json->{'value'}->[0]->{'siteId'};
    die "Couldn't find site id\n" unless($site_id =~ /^\d+$/);
    verbose("site_id: %s\n", $site_id);
}

sub verbose {
    printf STDERR @_ if($verbose);
}
