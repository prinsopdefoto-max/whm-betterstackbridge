package BetterStack::WHM::API;

# Thin client for the Better Stack Uptime API (v2).

use strict;
use warnings;

use BetterStack::WHM::Util qw(http_request json_decode);
use JSON::PP ();

sub new {
    my ( $class, %a ) = @_;
    my $base = $a{base} || 'https://incidents.betterstack.com/api/v2';
    $base =~ s{/+\z}{};
    return bless { token => $a{token}, base => $base, team_name => $a{team_name} // '' }, $class;
}

sub from_config {
    my ( $class, $cfg ) = @_;
    return $class->new( token => $cfg->{api_token}, base => $cfg->{api_base}, team_name => $cfg->{team_name} );
}

# Returns ( $decoded_body, $error ). $error is undef on success.
# On error the HTTP status is available as $self->{last_status}.
sub request {
    my ( $self, $method, $path, $body ) = @_;
    my $url = $path =~ m{^https?://} ? $path : $self->{base} . $path;
    my %h = ( Authorization => "Bearer $self->{token}", Accept => 'application/json' );
    my $content;
    if ( defined $body ) {
        $h{'Content-Type'} = 'application/json';
        $content = JSON::PP->new->utf8->canonical->encode($body);
    }
    my $res = http_request( $method, $url, headers => \%h, body => $content, timeout => 20 );
    $self->{last_status} = $res->{status};
    my $data = json_decode( $res->{content} );
    return ( $data, undef ) if $res->{success};
    my $err = "HTTP $res->{status}";
    if ( ref $data eq 'HASH' ) {
        my $e = $data->{errors} // $data->{error} // $data->{message};
        $err .= ': ' . ( ref $e ? JSON::PP->new->canonical->encode($e) : $e ) if defined $e;
    }
    elsif ( $res->{status} == 599 ) {
        $err .= ': ' . ( $res->{content} // $res->{error} );
    }
    return ( undef, $err );
}

sub _list {
    my ( $self, $path ) = @_;
    my @all;
    my $url = $path;
    for ( 1 .. 20 ) {
        my ( $d, $err ) = $self->request( 'GET', $url );
        return ( undef, $err ) if $err;
        push @all, @{ $d->{data} || [] };
        $url = ( $d->{pagination} || {} )->{next} or last;
    }
    return ( \@all, undef );
}

sub _with_team {
    my ( $self, $body ) = @_;
    $body->{team_name} = $self->{team_name} if length $self->{team_name};
    return $body;
}

sub status_pages         { $_[0]->_list('/status-pages') }
sub list_heartbeats      { $_[0]->_list('/heartbeats') }
sub list_monitors        { $_[0]->_list('/monitors') }
sub list_hb_groups       { $_[0]->_list('/heartbeat-groups') }
sub list_resources       { $_[0]->_list("/status-pages/$_[1]/resources") }
sub get_status_page      { $_[0]->request( 'GET', "/status-pages/$_[1]" ) }
sub create_heartbeat     { $_[0]->request( 'POST', '/heartbeats', $_[0]->_with_team( $_[1] ) ) }
sub update_heartbeat     { $_[0]->request( 'PATCH', "/heartbeats/$_[1]", $_[2] ) }
sub delete_heartbeat     { $_[0]->request( 'DELETE', "/heartbeats/$_[1]" ) }
sub create_hb_group      { $_[0]->request( 'POST', '/heartbeat-groups', $_[0]->_with_team( { name => $_[1] } ) ) }
sub delete_hb_group      { $_[0]->request( 'DELETE', "/heartbeat-groups/$_[1]" ) }
sub list_sections        { $_[0]->_list("/status-pages/$_[1]/sections") }
sub create_section       { $_[0]->request( 'POST', "/status-pages/$_[1]/sections", $_[2] ) }
sub delete_section       { $_[0]->request( 'DELETE', "/status-pages/$_[1]/sections/$_[2]" ) }
sub create_resource      { $_[0]->request( 'POST', "/status-pages/$_[1]/resources", $_[2] ) }
sub update_resource      { $_[0]->request( 'PATCH', "/status-pages/$_[1]/resources/$_[2]", $_[3] ) }
sub delete_resource      { $_[0]->request( 'DELETE', "/status-pages/$_[1]/resources/$_[2]" ) }

1;
