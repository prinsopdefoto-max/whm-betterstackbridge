use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Test::More;

use BetterStack::WHM::Util ();
use BetterStack::WHM::History ();

my $H   = 'BetterStack::WHM::History';
my $now = 1_800_000_000;    # a whole hour

subtest 'metrics: one point per 5 minutes, worst value kept' => sub {
    my $h = {};
    $H->can('record')->( $h, 'disk:/', { status => 'ok', metrics => [ { k => 'space', v => 50, d => 'up' } ] }, $now );
    $H->can('record')->( $h, 'disk:/', { status => 'ok', metrics => [ { k => 'space', v => 70, d => 'up' } ] }, $now + 60 );
    $H->can('record')->( $h, 'disk:/', { status => 'ok', metrics => [ { k => 'space', v => 60, d => 'up' } ] }, $now + 120 );
    $H->can('record')->( $h, 'disk:/', { status => 'ok', metrics => [ { k => 'space', v => 40, d => 'up' } ] }, $now + 300 );
    is_deeply( $h->{'disk:/'}{m}{space}, [ [ $now, 70 ], [ $now + 300, 40 ] ] );

    $H->can('record')->( $h, 'ssl', { status => 'ok', metrics => [ { k => 'days', v => 30, d => 'down' } ] }, $now );
    $H->can('record')->( $h, 'ssl', { status => 'ok', metrics => [ { k => 'days', v => -2, d => 'down' } ] }, $now + 10 );
    is( $h->{ssl}{m}{days}[0][1], -2, 'lowest kept where down is bad (negative too)' );

    $H->can('record')->( $h, 'x', { status => 'ok', metrics => [ { k => 'bad', v => '1; rm' } ] }, $now );
    ok( !$h->{x}{m}{bad}, 'only numbers are stored' );
};

subtest 'status per hour, worst wins; old data dropped' => sub {
    my $h = {};
    $H->can('record')->( $h, 'load', { status => 'ok' },   $now + 10 );
    $H->can('record')->( $h, 'load', { status => 'fail' }, $now + 20 );
    $H->can('record')->( $h, 'load', { status => 'warn' }, $now + 30 );
    $H->can('record')->( $h, 'load', { status => 'ok' },   $now + 3600 );
    is_deeply( $h->{load}{s}, [ [ $now, 'fail' ], [ $now + 3600, 'ok' ] ] );

    my $cells = $H->can('hours')->( $h, 'load', $now + 3600, 24 );
    is( scalar @$cells, 24 );
    is_deeply( [ map { $_->[1] } @$cells[ -2, -1 ] ], [ 'fail', 'ok' ], 'oldest first, current hour last' );
    ok( !defined $cells->[0][1], 'hours without data are empty' );

    $H->can('record')->( $h, 'load', { status => 'ok', metrics => [ { k => 'load', v => 1 } ] }, $now + 3 * 86400 );
    is( scalar @{ $h->{load}{s} }, 1, 'statuses older than 48 hours dropped' );
    $H->can('prune')->( $h, { load => 1 }, $now + 5 * 86400 );
    ok( !$h->{load}{m}{load}, 'metric that stopped reporting dropped' );
    $H->can('prune')->( $h, {}, $now );
    ok( !$h->{load}, 'switched-off check forgotten' );
};

# ---- the charts on the overview
my $dir = tempdir( CLEANUP => 1 );
system 'mkdir', '-p', "$dir/fakelib/Whostmgr", "$dir/var", "$dir/etc";
open my $acl, '>', "$dir/fakelib/Whostmgr/ACLS.pm" or die;
print $acl "package Whostmgr::ACLS; sub init_acls {1} sub hasroot {1} 1;\n";
close $acl;
$BetterStack::WHM::Util::VAR_DIR = "$dir/var";
my $t = time;
my %res = (
    load   => { status => 'ok', at => $t, detail => [], metrics => [ { k => 'load', v => 0.5, w => 1.5, c => 4, u => 'load', d => 'up' } ] },
    memory => { status => 'warn', at => $t, detail => [], metrics => [ { k => 'mem', v => 93, w => 90, c => 98, u => 'pct', d => 'up' } ] },
);
my $h = {};
for my $i ( 0 .. 20 ) {
    $H->can('record')->( $h, $_, $res{$_}, $t - $i * 600 ) for keys %res;
}
BetterStack::WHM::Util::write_json( "$dir/var/state.json", { results => \%res, items => {} } );
BetterStack::WHM::Util::write_json( "$dir/var/history.json", $h );
BetterStack::WHM::Util::write_json( "$dir/etc/config.json", { config_version => 3, ui_lang => 'en' } );
open my $w, '>', "$dir/wrap.pl" or die;
print $w <<"PL";
use lib '$FindBin::Bin/../lib', '$dir/fakelib';
use BetterStack::WHM::Util;
\$BetterStack::WHM::Util::ETC_DIR = '$dir/etc';
\$BetterStack::WHM::Util::VAR_DIR = '$dir/var';
\$BetterStack::WHM::Util::LOG_FILE = '$dir/log';
do '$FindBin::Bin/../cgi/index.cgi'; die \$@ if \$@;
PL
close $w;
my $page = do { local %ENV = ( %ENV, REQUEST_METHOD => 'GET', REMOTE_USER => 'root' ); `$^X $dir/wrap.pl 2>&1` };
utf8::decode($page);

subtest 'overview charts' => sub {
    unlike( $page, qr/(?:Use of uninitialized|line \d+\.)/, 'no Perl warnings' );
    like( $page, qr/Closest to a threshold/, 'closest card' );
    my ($closest) = $page =~ m{<section class="bsw-card bsw-closest">(.*?)</section>}s;
    like( $closest, qr/Memory.*CPU load/s, 'memory (93% of 90%) listed before load (0.5 of 1.5)' );
    like( $page, qr/class="bsw-meter bsw-mt-warn"[^>]*title="93% · warning at 90% · outage at 98%"/, 'meter with thresholds' );
    like( $page, qr/<span class="bsw-tick bsw-tick-warn" style="left:90\.0%">/, 'warning tick at 90%' );
    like( $page, qr/<svg class="bsw-spark"/, 'sparkline' );
    like( $page, qr/<div class="bsw-strip"/, 'status strip' );
    like( $page, qr/0\.50 per core/ );
};

done_testing;
