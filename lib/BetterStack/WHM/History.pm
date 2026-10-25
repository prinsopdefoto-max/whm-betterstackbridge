package BetterStack::WHM::History;

# Recent history of the checks, for the charts in WHM. Never sent anywhere.
#
# Per instance id:
#   m => { <metric key> => [ [ time, value ], ... ] }   one point per 5 minutes, 24 hours
#   s => [ [ time, status ], ... ]                       one per hour, 48 hours
# A bucket keeps its worst value: the highest for metrics where up is bad,
# the lowest where down is bad (days until a certificate expires).

use strict;
use warnings;

use BetterStack::WHM::Util qw(var_dir read_json write_json);

our $FILE;
our $POINT       = 300;
our $KEEP_POINTS = 86400;
our $KEEP_STATUS = 2 * 86400;

my %RANK = ( ok => 0, warn => 1, fail => 2 );

sub file { $FILE // var_dir() . '/history.json' }

sub load {
    my $h = read_json( file() );
    return ref $h eq 'HASH' ? $h : {};
}

sub save { eval { write_json( file(), $_[0] ) } }

# Adds a check result (with its optional metrics) to the history.
sub record {
    my ( $hist, $id, $res, $now ) = @_;
    my $e = $hist->{$id} ||= {};
    for my $m ( @{ $res->{metrics} || [] } ) {
        next unless defined $m->{v} && $m->{v} =~ /^-?\d+(?:\.\d+)?\z/;
        my $series = $e->{m}{ $m->{k} } ||= [];
        my $t      = int( $now / $POINT ) * $POINT;
        my $last   = $series->[-1];
        if ( $last && $last->[0] == $t ) {
            my $worse = ( $m->{d} // 'up' ) eq 'down' ? $m->{v} < $last->[1] : $m->{v} > $last->[1];
            $last->[1] = $m->{v} + 0 if $worse;
        }
        else { push @$series, [ $t, $m->{v} + 0 ] }
        shift @$series while @$series && $series->[0][0] <= $now - $KEEP_POINTS;
    }
    my $status = $res->{status} // 'fail';
    my $t      = int( $now / 3600 ) * 3600;
    my $s      = $e->{s} ||= [];
    if ( $s->[-1] && $s->[-1][0] == $t ) { $s->[-1][1] = $status if ( $RANK{$status} // 2 ) > ( $RANK{ $s->[-1][1] } // 0 ) }
    else                                 { push @$s, [ $t, $status ] }
    shift @$s while @$s && $s->[0][0] <= $now - $KEEP_STATUS;
    return $hist;
}

# Forgets checks that no longer exist or are switched off, and metrics that stopped.
sub prune {
    my ( $hist, $keep, $now ) = @_;
    for my $id ( keys %$hist ) {
        if ( !$keep->{$id} ) { delete $hist->{$id}; next }
        for my $k ( keys %{ $hist->{$id}{m} || {} } ) {
            my $series = $hist->{$id}{m}{$k};
            delete $hist->{$id}{m}{$k} if !@$series || $series->[-1][0] <= $now - $KEEP_POINTS;
        }
    }
    return $hist;
}

# Hourly status cells for the last $hours hours, oldest first: [ hour start, status or undef ].
sub hours {
    my ( $hist, $id, $now, $hours ) = @_;
    my %by = map { $_->[0] => $_->[1] } @{ ( $hist->{$id} || {} )->{s} || [] };
    my $cur = int( $now / 3600 ) * 3600;
    return [ map { my $t = $cur - $_ * 3600; [ $t, $by{$t} ] } reverse 0 .. $hours - 1 ];
}

1;
