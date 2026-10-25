package BetterStack::WHM::Maintenance;

# Announces planned downtime (a reboot, or work started by hand) to Better Stack.
#
# - The heartbeats of this server get a maintenance window, so missed beats
#   do not open incidents. It is a time window, not a pause: if the server does
#   not come back, the heartbeats alert again once the window has passed.
# - Optionally a maintenance report on the status page, with this server's
#   items marked as "maintenance".
#
# A reboot is noticed by a systemd unit (whm/betterstack-whm-maintenance.service)
# while the network is still up. Maintenance ends at boot, or at the latest on
# the next cron run after the reboot or after the planned end.

use strict;
use warnings;

use POSIX ();
use JSON::PP ();

use BetterStack::WHM::API ();
use BetterStack::WHM::Checks ();
use BetterStack::WHM::Config ();
use BetterStack::WHM::Util qw(run_cmd logmsg);
use BetterStack::WHM::I18N qw(tl);

our @SYSTEMCTL = qw(/usr/bin/systemctl /bin/systemctl);
my @WINDOW = qw(maintenance_from maintenance_to maintenance_timezone maintenance_days);

sub active {
    my ($st) = @_;
    my $m = $st->{maintenance};
    return ref $m eq 'HASH' && $m->{since} ? $m : undef;
}

# 'reboot' or 'poweroff' while the system is shutting down, else undef (for
# example when only the systemd unit itself is stopped or restarted).
sub shutdown_kind {
    my ($bin) = grep { -x $_ && !-d _ } @SYSTEMCTL;
    return undef unless $bin;
    my ( undef, $out ) = run_cmd( 10, $bin, 'list-jobs', '--no-legend', '--no-pager' );
    return 'reboot'   if $out =~ /\b(?:reboot|kexec)\.target\b/;
    return 'poweroff' if $out =~ /\b(?:poweroff|halt)\.target\b/;
    return undef;
}

sub _iso { POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime $_[0] ) }

# Heartbeat maintenance window in UTC covering $from..$to (at most a day).
sub window {
    my ( $from, $to ) = @_;
    my @f   = gmtime $from;
    my @t   = gmtime $to;
    my @wd  = qw(sun mon tue wed thu fri sat);
    my %day = ( $wd[ $f[6] ] => 1, $wd[ $t[6] ] => 1 );
    return {
        maintenance_from     => sprintf( '%02d:%02d', $f[2], $f[1] ),
        maintenance_to       => sprintf( '%02d:%02d', $t[2], $t[1] ),
        maintenance_timezone => 'UTC',
        maintenance_days     => [ grep { $day{$_} } qw(mon tue wed thu fri sat sun) ],
    };
}

# Starts maintenance. Options: reason (reboot | poweroff | manual), minutes.
# Returns a list of error messages.
sub start {
    my ( $cfg, $st, %o ) = @_;
    return [] if active($st);
    return [ ['mt.not_configured'] ] unless BetterStack::WHM::Config::is_configured($cfg);
    my $minutes = int( $o{minutes} || $cfg->{maint_minutes} || 15 );
    $minutes = 1 if $minutes < 1;
    $minutes = 720 if $minutes > 720;
    my $reason = $o{reason} // 'manual';
    my $from   = time;
    my $to     = $from + 60 * $minutes + 59;
    $to -= $to % 60;    # whole minutes, rounded up
    my $api = BetterStack::WHM::API->from_config($cfg);
    my ( @errors, %prev );

    for my $it ( grep { $_->{heartbeat_id} } values %{ $st->{items} } ) {
        my ($d) = $api->request( 'GET', "/heartbeats/$it->{heartbeat_id}" );
        my $a = ref $d eq 'HASH' && ref $d->{data} eq 'HASH' ? $d->{data}{attributes} || {} : {};
        my ( undef, $err ) = $api->update_heartbeat( $it->{heartbeat_id}, window( $from, $to ) );
        if ($err) { push @errors, [ 'e.err', [ 'mt.e_window', $it->{heartbeat_id} ], $err ]; next }
        $prev{ $it->{heartbeat_id} } = { map { $_ => $a->{$_} } @WINDOW };
    }

    my $report;
    my @res = map { { status_page_resource_id => $_->{resource_id} + 0, status => 'maintenance' } } grep { $_->{resource_id} } values %{ $st->{items} };
    if ( $cfg->{maint_report} && @res && $st->{status_page_id} ) {
        my $lang = BetterStack::WHM::Checks::public_lang($cfg);
        my ( $d, $err ) = $api->request(
            'POST',
            "/status-pages/$st->{status_page_id}/status-reports",
            {
                title              => tl( $lang, 'mt.title', $cfg->{server_label} ),
                message            => tl( $lang, $reason eq 'manual' ? 'mt.msg_manual' : 'mt.msg_reboot', $minutes ),
                report_type        => 'maintenance',
                starts_at          => _iso($from),
                ends_at            => _iso($to),
                affected_resources => \@res,
                notify_subscribers => $cfg->{maint_notify} ? JSON::PP::true : JSON::PP::false,
            }
        );
        if   ($err) { push @errors, [ 'e.err', ['mt.e_report'], $err ] }
        else {
            my $id = ref $d eq 'HASH' && ref $d->{data} eq 'HASH' ? $d->{data}{id} : undef;
            $report = "$id" if defined $id && $id =~ /^\d{1,20}\z/;
        }
    }

    $st->{maintenance} = { since => $from, until => $to, reason => $reason, heartbeats => \%prev, ( $report ? ( report_id => $report, page => $st->{status_page_id} ) : () ) };
    logmsg( info => [ 'mt.log_start', ["mt.reason_$reason"], $minutes ] );
    logmsg( error => $_ ) for @errors;
    return \@errors;
}

# Ends maintenance: restores the heartbeats' previous maintenance settings and
# ends the status page report now (unless it has ended already).
sub finish {
    my ( $cfg, $st ) = @_;
    my $m = active($st) or return [];
    my $api = BetterStack::WHM::API->from_config($cfg);
    my @errors;
    for my $id ( keys %{ $m->{heartbeats} || {} } ) {
        my $p = $m->{heartbeats}{$id} || {};
        my ( undef, $err ) = $api->update_heartbeat( $id, { map { $_ => $p->{$_} } @WINDOW } );
        push @errors, [ 'e.err', [ 'mt.e_window', $id ], $err ] if $err && ( $api->{last_status} // 0 ) != 404;
    }
    my $now = time;
    if ( $m->{report_id} && $now < $m->{until} ) {
        my ( undef, $err ) = $api->request( 'PATCH', "/status-pages/$m->{page}/status-reports/$m->{report_id}", { ends_at => _iso($now) } );
        push @errors, [ 'e.err', ['mt.e_report'], $err ] if $err && ( $api->{last_status} // 0 ) != 404;
    }
    delete $st->{maintenance};
    logmsg( info => ['mt.log_end'] );
    logmsg( error => $_ ) for @errors;
    return \@errors;
}

sub boot_time {
    my $up = BetterStack::WHM::Checks::_read("$BetterStack::WHM::Checks::PROC/uptime") // '';
    return $up =~ /^([\d.]+)/ ? time - $1 : undef;
}

# Called on every run: ends maintenance once the server has rebooted since it
# started, or once its planned end has passed.
sub end_if_due {
    my ( $cfg, $st ) = @_;
    my $m = active($st) or return [];
    my $boot = boot_time();
    return [] unless time >= $m->{until} || ( defined $boot && $boot > $m->{since} + 5 );
    return finish( $cfg, $st );
}

1;
