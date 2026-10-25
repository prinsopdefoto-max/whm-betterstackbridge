use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Test::More;

use BetterStack::WHM::Util ();
use BetterStack::WHM::API ();
use BetterStack::WHM::Checks ();
use BetterStack::WHM::Maintenance ();
use BetterStack::WHM::UIStrings ();

my $dir = tempdir( CLEANUP => 1 );
$BetterStack::WHM::Util::VAR_DIR  = "$dir/var";
$BetterStack::WHM::Util::LOG_FILE = "$dir/log";
mkdir "$dir/proc";
$BetterStack::WHM::Checks::PROC = "$dir/proc";
sub put { open my $fh, '>', $_[0] or die; print $fh $_[1]; close $fh }

# Fake Better Stack API: records calls, heartbeats have no maintenance window yet.
my @calls;
{
    no warnings 'redefine';
    *BetterStack::WHM::API::request = sub {
        my ( $self, $m, $path, $body ) = @_;
        push @calls, [ $m, $path, $body ];
        $self->{last_status} = 200;
        return ( { data => { id => $1, attributes => { maintenance_from => undef, maintenance_to => undef, maintenance_timezone => 'UTC', maintenance_days => [qw(mon tue wed thu fri sat sun)] } } }, undef )
          if $m eq 'GET' && $path =~ m{^/(?:heartbeats|monitors)/(\d+)$};
        return ( { data => [ { id => '31', attributes => { resource_type => 'Monitor', resource_id => 41 } },
                             { id => '32', attributes => { resource_type => 'Monitor', resource_id => 42 } },
                             { id => '21', attributes => { resource_type => 'Heartbeat', resource_id => 11 } } ] }, undef )
          if $m eq 'GET' && $path eq '/status-pages/5/resources';
        return ( { data => { id => '777' } }, undef ) if $m eq 'POST';
        return ( {}, undef );
    };
}

my $cfg = { api_token => 't', status_page_id => '5', server_label => 'srv1', public_lang => 'en', maint_minutes => 15, maint_report => 1, maint_notify => 0 };
sub fresh_state {
    return { status_page_id => '5', items => { 'cat:system' => { heartbeat_id => '11', resource_id => '21' }, 'cat:mail' => { heartbeat_id => '12', resource_id => '22' } } };
}

subtest 'maintenance window' => sub {
    my $w = BetterStack::WHM::Maintenance::window( 1_800_000_000 - 600, 1_800_000_000 + 900 );    # 07:50 - 08:15 UTC, a Friday
    is_deeply( $w, { maintenance_from => '07:50:00', maintenance_to => '08:15:00', maintenance_timezone => 'UTC', maintenance_days => ['fri'] } );
    $w = BetterStack::WHM::Maintenance::window( 1_800_000_000 + 57_000, 1_800_000_000 + 59_400 );    # 23:50 - 00:30
    is_deeply( $w->{maintenance_days}, [ 'fri', 'sat' ], 'overnight window covers both days' );
};

my $st = fresh_state();
subtest 'start' => sub {
    @calls = ();
    my $errs = BetterStack::WHM::Maintenance::start( $cfg, $st, reason => 'reboot' );
    is_deeply( $errs, [] );
    my @patch = grep { $_->[0] eq 'PATCH' } @calls;
    is( scalar @patch, 2, 'both heartbeats get a window' );
    ok( !exists $patch[0][2]{paused}, 'not paused: alerts resume if the server does not come back' );
    like( $patch[0][2]{maintenance_from}, qr/^\d\d:\d\d:00$/ );
    my ($report) = grep { $_->[0] eq 'POST' } @calls;
    is( $report->[1], '/status-pages/5/status-reports' );
    is( $report->[2]{report_type}, 'maintenance' );
    is( $report->[2]{title}, 'Maintenance: srv1' );
    like( $report->[2]{message}, qr/restarting.*15 minutes/ );
    is_deeply( [ sort map { $_->{status_page_resource_id} } @{ $report->[2]{affected_resources} } ], [ 21, 22 ] );
    is( $report->[2]{affected_resources}[0]{status}, 'maintenance' );
    ok( !$report->[2]{notify_subscribers}, 'subscribers not e-mailed by default' );
    my $m = BetterStack::WHM::Maintenance::active($st);
    is( $m->{report_id}, '777' );
    cmp_ok( $m->{until} - $m->{since}, '>=', 15 * 60 );
    is( $m->{restore}{'heartbeats/11'}{maintenance_timezone}, 'UTC', 'previous settings kept' );

    @calls = ();
    BetterStack::WHM::Maintenance::start( $cfg, $st, reason => 'reboot' );
    is( scalar @calls, 0, 'already active: nothing done' );
};

subtest 'ends after the reboot, not before' => sub {
    @calls = ();
    put( "$dir/proc/uptime", "999999.0 1.0\n" );    # booted long before the maintenance started
    BetterStack::WHM::Maintenance::end_if_due( $cfg, $st );
    ok( BetterStack::WHM::Maintenance::active($st), 'still before the reboot' );
    is( scalar @calls, 0 );

    $st->{maintenance}{since} = time - 600;    # started 10 minutes ago ...
    put( "$dir/proc/uptime", "30.0 1.0\n" );    # ... and the server booted 30 seconds ago
    BetterStack::WHM::Maintenance::end_if_due( $cfg, $st );
    ok( !BetterStack::WHM::Maintenance::active($st), 'ended' );
    my @hb = grep { $_->[1] =~ m{^/heartbeats/} } @calls;
    is( scalar @hb, 2 );
    is_deeply( $hb[0][2]{maintenance_days}, [qw(mon tue wed thu fri sat sun)], 'heartbeat settings restored' );
    ok( exists $hb[0][2]{maintenance_from} && !defined $hb[0][2]{maintenance_from} );
    my ($rep) = grep { $_->[1] eq '/status-pages/5/status-reports/777' } @calls;
    ok( $rep && $rep->[2]{ends_at}, 'status page report ended now' );
};

subtest 'manual maintenance ends after the planned time' => sub {
    put( "$dir/proc/uptime", "999999.0 1.0\n" );
    my $st2 = fresh_state();
    BetterStack::WHM::Maintenance::start( { %$cfg, maint_report => 0 }, $st2, reason => 'manual', minutes => 5 );
    ok( !grep { $_->[0] eq 'POST' } @calls[ -2 .. -1 ] );
    ok( !BetterStack::WHM::Maintenance::active($st2)->{report_id}, 'no status page report when switched off' );
    BetterStack::WHM::Maintenance::end_if_due( $cfg, $st2 );
    ok( BetterStack::WHM::Maintenance::active($st2), 'not yet' );
    $st2->{maintenance}{until} = time - 1;
    BetterStack::WHM::Maintenance::end_if_due( $cfg, $st2 );
    ok( !BetterStack::WHM::Maintenance::active($st2), 'ended at the planned time' );
};

subtest 'other monitors share the maintenance' => sub {
    put( "$dir/proc/uptime", "999999.0 1.0\n" );
    my $st4 = fresh_state();
    @calls = ();
    BetterStack::WHM::Maintenance::start( { %$cfg, maint_monitors => [ '41', 'x; rm' ] }, $st4, reason => 'reboot' );
    my @mon = grep { $_->[0] eq 'PATCH' && $_->[1] =~ m{^/monitors/} } @calls;
    is_deeply( [ map { $_->[1] } @mon ], ['/monitors/41'], 'chosen monitor gets the window, invalid ids ignored' );
    my ($report) = grep { $_->[0] eq 'POST' } @calls;
    is_deeply( [ map { $_->{status_page_resource_id} } @{ $report->[2]{affected_resources} } ], [ 21, 22, 31 ], 'its status page item is in the report' );
    @calls = ();
    BetterStack::WHM::Maintenance::finish( $cfg, $st4 );
    ok( ( grep { $_->[1] eq '/monitors/41' } @calls ), 'monitor restored' );
};

subtest 'state from the first version still ends cleanly' => sub {
    my $old = { %{ fresh_state() }, maintenance => { since => time - 60, until => time + 600, heartbeats => { 11 => { maintenance_from => undef } } } };
    @calls = ();
    BetterStack::WHM::Maintenance::finish( $cfg, $old );
    is_deeply( [ map { $_->[1] } @calls ], ['/heartbeats/11'] );
};

subtest 'not configured' => sub {
    my $st3 = fresh_state();
    is( BetterStack::WHM::Maintenance::start( { %$cfg, api_token => '' }, $st3 )->[0][0], 'mt.not_configured' );
    ok( !BetterStack::WHM::Maintenance::active($st3) );
};

subtest 'shutdown detection' => sub {
    my $fake = "$dir/systemctl";
    local @BetterStack::WHM::Maintenance::SYSTEMCTL = ($fake);
    for ( [ "1234 reboot.target start waiting\n2 systemd-reboot.service start waiting\n", 'reboot' ],
          [ "88 poweroff.target start waiting\n", 'poweroff' ],
          [ "", undef ],
          [ "5 httpd.service restart running\n", undef ] ) {
        put( $fake, "#!/bin/sh\nprintf '%s' '$_->[0]'\n" );
        chmod 0755, $fake;
        is( BetterStack::WHM::Maintenance::shutdown_kind(), $_->[1], 'list-jobs: ' . ( $_->[1] // 'no shutdown' ) );
    }
};

done_testing;
