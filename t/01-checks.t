use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Test::More;

use BetterStack::WHM::Checks;
use BetterStack::WHM::I18N ();
sub R { BetterStack::WHM::I18N::render( $_[0], 'nl' ) }
sub RM { BetterStack::WHM::I18N::render_msg( $_[0], 'nl' ) }

my $C = 'BetterStack::WHM::Checks';

subtest 'level/worst' => sub {
    is( $C->can('level')->( 50, 80, 90 ), 'ok' );
    is( $C->can('level')->( 85, 80, 90 ), 'warn' );
    is( $C->can('level')->( 90, 80, 90 ), 'fail' );
    is( $C->can('worst')->(qw(ok warn ok)),   'warn' );
    is( $C->can('worst')->(qw(ok fail warn)), 'fail' );
};

subtest 'parse_df' => sub {
    my $out = <<'DF';
Filesystem     Type     1024-blocks      Used Available Capacity Mounted on
/dev/vda1      xfs         52417516  37224000  15193516      72% /
tmpfs          tmpfs        1000000         0   1000000       0% /dev/shm
/dev/loop0     ext3         4054752    100000   3744000       3% /tmp
/dev/sdb1      ext4       100000000  50000000  50000000      50% /mnt/my disk
DF
    my $rows = BetterStack::WHM::Checks::parse_df($out);
    is( scalar @$rows, 4 );
    is( $rows->[0]{mount}, '/' );
    is( $rows->[0]{pct},   72 );
    is( $rows->[3]{mount}, '/mnt/my disk', 'mount points with spaces' );
};

subtest 'parse_mdstat' => sub {
    my $md = <<'MD';
Personalities : [raid1]
md0 : active raid1 sdb1[1] sda1[0]
      1046528 blocks super 1.2 [2/2] [UU]

md1 : active raid1 sdb2[1] sda2[0](F)
      976235520 blocks super 1.2 [2/1] [U_]
      [==>..................]  recovery = 12.6% (123/976) finish=80.1min speed=150000K/sec

unused devices: <none>
MD
    my $a = BetterStack::WHM::Checks::parse_mdstat($md);
    is( scalar @$a, 2 );
    is( $a->[0]{degraded}, 0 );
    is( $a->[1]{degraded}, 1 );
    is( $a->[1]{progress}, 'recovery 12.6%' );
};

subtest 'parse_meminfo' => sub {
    my $m = BetterStack::WHM::Checks::parse_meminfo("MemTotal:  1000 kB\nMemAvailable:  250 kB\n");
    is( $m->{MemTotal},     1024000 );
    is( $m->{MemAvailable}, 256000 );
};

subtest 'parse_servicestatus' => sub {
    my $s = BetterStack::WHM::Checks::parse_servicestatus(
        '{"data":{"service":[{"name":"httpd","enabled":1,"installed":1,"running":1},{"name":"exim","enabled":1,"installed":1,"running":0}]},"metadata":{"result":1}}');
    is( scalar @$s, 2 );
    my $ctx = { servicestatus => $s };
    my $d   = BetterStack::WHM::Checks::discover_services($ctx);
    is( $d->[0]{id},   'service:httpd' );
    is( RM( $d->[0]{name} ), 'Webserver' );
    is( BetterStack::WHM::Checks::run_service( $d->[0], {}, $ctx )->{status}, 'ok' );
    is( BetterStack::WHM::Checks::run_service( $d->[1], {}, $ctx )->{status}, 'fail' );
};

subtest 'backup log' => sub {
    is( BetterStack::WHM::Checks::parse_backup_log("...\nFinal state is Backup::Success (0)\n"),        'success' );
    is( BetterStack::WHM::Checks::parse_backup_log("...\nFinal state is Backup::PartialFailure (1)\n"), 'partial' );
    is( BetterStack::WHM::Checks::parse_backup_log("...\nFinal state is Backup::Failure (2)\n"),        'failure' );
    is( BetterStack::WHM::Checks::parse_backup_log("started"), 'running' );

    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/logs"; mkdir "$dir/logs/cpbackup";
    open my $fh, '>', "$dir/logs/cpbackup/1.log" or die; print $fh "Final state is Backup::Success (0)\n"; close $fh;
    local $BetterStack::WHM::Checks::CPANEL = $dir;
    is( BetterStack::WHM::Checks::run_backup( {}, { max_age_hours => 30 } )->{status}, 'ok' );
    utime time - 40 * 3600, time - 40 * 3600, "$dir/logs/cpbackup/1.log";
    is( BetterStack::WHM::Checks::run_backup( {}, { max_age_hours => 30 } )->{status}, 'fail', 'too old' );
};

subtest 'proc based checks' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $w = sub { open my $fh, '>', "$dir/$_[0]" or die; print $fh $_[1]; close $fh };
    $w->( 'cpuinfo', "processor : 0\nprocessor : 1\n" );
    $w->( 'loadavg', "1.00 9.00 1.00 1/100 123\n" );
    $w->( 'meminfo', "MemTotal: 1000 kB\nMemAvailable: 500 kB\nSwapTotal: 100 kB\nSwapFree: 50 kB\n" );
    $w->( 'uptime',  "200000.00 1.00\n" );
    local $BetterStack::WHM::Checks::PROC = $dir;
    my $l = BetterStack::WHM::Checks::run_load( {}, { warn_per_cpu => 1.5, crit_per_cpu => 4 } );
    is( $l->{status}, 'fail', 'load 9 on 2 cores is critical' );
    like( R( $l->{detail} ), qr/2 cores/ );
    my $m = BetterStack::WHM::Checks::run_memory( {}, { warn_pct => 90, crit_pct => 98 } );
    is( $m->{status}, 'ok' );
    like( R( $m->{detail} ), qr/^50% in gebruik.*swap 50%/ );
    is( R( BetterStack::WHM::Checks::run_server()->{detail} ), 'Online', 'uptime is not published' );
    like( R( BetterStack::WHM::Checks::run_server()->{info} ), qr/2 dagen/ );
};

subtest 'openssl date parsing' => sub {
    is( BetterStack::WHM::Checks::parse_openssl_date("notAfter=Mar  3 12:00:00 2027 GMT\n"), 1804075200 );
    is( BetterStack::WHM::Checks::parse_openssl_date("notAfter=\$(reboot)"), undef );
    is( BetterStack::WHM::Checks::parse_openssl_date(undef), undef );
};

subtest 'rbl: no false positives from a broken resolver' => sub {
    my @asked;
    my $ts = { lists => 'zen.spamhaus.org bl.spamcop.net', extra_ips => '192.0.2.10' };
    local $BetterStack::WHM::Checks::VARCP = '/nonexistent';

    # Wildcard resolver: every name resolves (this caused 4 false listings).
    local $BetterStack::WHM::Checks::RESOLVE = sub { push @asked, $_[0]; '127.0.0.2' };
    my $r = BetterStack::WHM::Checks::run_rbl( {}, $ts, {} );
    is( $r->{status}, 'warn', 'wildcard resolver -> cannot check, not "listed"' );
    like( R( $r->{info} ), qr/zen\.spamhaus\.org/ );
    ok( ( grep { /\.\z/ } @asked ) == @asked, 'all queries are absolute (trailing dot)' );

    # Healthy lists, IP not listed.
    my %zone = ( '2.0.0.127.zen.spamhaus.org.' => '127.0.0.2', '2.0.0.127.bl.spamcop.net.' => '127.0.0.2' );
    local $BetterStack::WHM::Checks::RESOLVE = sub { $zone{ $_[0] } };
    $r = BetterStack::WHM::Checks::run_rbl( {}, $ts, {} );
    is( $r->{status}, 'ok' );
    is( R( $r->{detail} ), 'Niet vermeld (2 lijsten gecontroleerd)' );

    # Really listed on one list.
    $zone{'10.2.0.192.bl.spamcop.net.'} = '127.0.0.2';
    $r = BetterStack::WHM::Checks::run_rbl( {}, $ts, {} );
    is( $r->{status}, 'fail' );
    like( R( $r->{info} ), qr/^192\.0\.2\.10 op bl\.spamcop\.net \(127\.0\.0\.2\)$/ );

    # Spamhaus refusing a public resolver answers 127.255.255.254: not a listing.
    delete $zone{'10.2.0.192.bl.spamcop.net.'};
    $zone{'10.2.0.192.zen.spamhaus.org.'} = '127.255.255.254';
    $r = BetterStack::WHM::Checks::run_rbl( {}, $ts, {} );
    is( $r->{status}, 'ok' );
    like( R( $r->{info} ), qr/zen\.spamhaus\.org/ );
};

subtest 'type settings and overrides' => sub {
    my $cfg = { checks => { load => { warn_per_cpu => 2, interval => 10 }, rbl => { enabled => 0 } },
                instances => { load => { public_name => 'CPU' }, memory => { enabled => 0 } } };
    my $ts = BetterStack::WHM::Checks::type_settings( $cfg, 'load' );
    is( $ts->{warn_per_cpu}, 2 );
    is( $ts->{crit_per_cpu}, 4 );
    is( $ts->{interval}, 60, 'interval clamped to 60' );
    my %all = map { $_->{id} => $_ } @{ BetterStack::WHM::Checks::discover_all( $cfg, { servicestatus => [], df => [] } ) };
    ok( !$all{rbl}, 'disabled type not discovered' );
    is( $all{load}{public_name}, 'CPU' );
    is( $all{memory}{enabled}, 0 );
    %all = map { $_->{id} => $_ } @{ BetterStack::WHM::Checks::discover_all( $cfg, { servicestatus => [], df => [] }, all_types => 1 ) };
    ok( $all{rbl} && !$all{rbl}{enabled} && !$all{rbl}{type_enabled}, 'all_types: disabled type discovered, but off' );
    ok( $all{load}{enabled} && $all{load}{type_enabled} );
};

subtest 'ssl: suspended accounts can be left out' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $BetterStack::WHM::Checks::VARCP = "$dir/var";
    local $BetterStack::WHM::Checks::ETC   = "$dir/etc";
    local $BetterStack::WHM::Checks::SSL_CACHE = "$dir/ssl-dates.json";
    system 'mkdir', '-p', "$dir/var/suspended", "$dir/etc", map { "$dir/var/ssl/apache_tls/$_" } qw(good.nl bad.nl sub.bad.nl);
    my $touch = sub { open my $fh, '>', $_[0] or die; print $fh $_[1] // ''; close $fh };
    $touch->("$dir/var/ssl/apache_tls/$_/combined") for qw(good.nl bad.nl sub.bad.nl);
    $touch->("$dir/var/suspended/baduser");
    $touch->("$dir/etc/userdomains", "good.nl: gooduser\nbad.nl: baduser\nsub.bad.nl: baduser\n*: nobody\n");
    no warnings 'redefine';
    my $openssl = 0;
    local *BetterStack::WHM::Checks::cert_end_epoch = sub { $openssl++; time + ( $_[0] =~ /good/ ? 60 : 1 ) * 86400 + 3600 };
    my $ts = { warn_days => 14, crit_days => 3 };
    my $r = BetterStack::WHM::Checks::run_ssl( {}, $ts );
    is( $r->{status}, 'fail', 'expiring certificate of a suspended account counts by default' );
    $r = BetterStack::WHM::Checks::run_ssl( {}, { %$ts, skip_suspended => 1 } );
    is( $r->{status}, 'ok', 'left out when the option is on' );
    is( R( $r->{detail} ), RM( [ 'r.ssl_count', 1 ] ) . ', ' . RM( [ 'r.ssl_next', 60 ] ) );
    like( R( $r->{info} ), qr/^.*\b2\b.*/, 'skipped count shown in WHM' );
    unlink "$dir/var/suspended/baduser";
    is( BetterStack::WHM::Checks::run_ssl( {}, { %$ts, skip_suspended => 1 } )->{status}, 'fail', 'unsuspended accounts count again' );

    $openssl = 0;
    BetterStack::WHM::Checks::run_ssl( {}, $ts );
    is( $openssl, 0, 'known certificates are not read again' );
    $touch->( "$dir/var/ssl/apache_tls/good.nl/combined", 'renewed' );
    BetterStack::WHM::Checks::run_ssl( {}, $ts );
    is( $openssl, 1, 'a renewed certificate is read again' );
};

done_testing;
