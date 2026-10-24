package BetterStack::WHM::Checks;

# Check registry. Every check type can discover one or more instances
# (e.g. one per service or per mount point) and run them.
#
# A result is { status => 'ok'|'warn'|'fail', detail => TEXT, info => TEXT }
#   detail: may be published on the (public) status page
#   info:   private, only shown inside WHM (may contain domain names etc.)
# TEXT is a list of translatable fragments, see BetterStack::WHM::I18N.

use strict;
use warnings;
use utf8;

use Socket qw(inet_aton);
use Time::Local qw(timegm);
use BetterStack::WHM::Util qw(run_cmd json_decode);
use BetterStack::WHM::I18N qw(tl render_msg);

# A failing check dies with a message: _die( 'err.read', 'loadavg' ).
sub _die { die { msg => [@_] } }

# Fixed system locations (tests change these variables, never %ENV).
our $PROC   = '/proc';
our $CPANEL = '/usr/local/cpanel';
our $VARCP  = '/var/cpanel';

# Absolute paths of the system tools we call; nothing is looked up via $PATH.
sub _bin {
    for (@_) { return $_ if -x $_ && !-d _ }
    return undef;
}

our @CATEGORIES = ( [ system => 'cat.system' ], [ services => 'cat.services' ], [ mail => 'cat.mail' ], [ security => 'cat.security' ] );

# Friendly public names for cPanel services are the I18N keys "svc.<name>".

# Customer facing services; other cPanel services (lfd, rsyslogd, p0f,
# queueprocd, ipaliases, ...) are discovered but off by default.
our %DEFAULT_SERVICES = map { $_ => 1 } qw(
  httpd lsws nginx apache_php_fpm mysql postgresql exim dovecot imap named pdns
  ftpd ftpserver pure-ftpd cpsrvd cpdavd
);

# Type definitions: label, category, default interval, enabled by default,
# tunable params (with defaults) and discover/run implementations.
our %TYPES;
our @TYPE_ORDER = qw(server service load memory disk mysql mailqueue rbl ssl backup raid);

%TYPES = (
    server => {
        label => 'type.server', category => 'system', interval => 60, enabled => 1,
        params => {},
        discover => sub { [ { id => 'server', name => ['name.server'] } ] },
        run      => \&run_server,
    },
    service => {
        label => 'type.service', category => 'services', interval => 60, enabled => 1,
        params => {},
        discover => \&discover_services,
        run      => \&run_service,
    },
    load => {
        label => 'type.load', category => 'system', interval => 60, enabled => 1,
        params => { warn_per_cpu => 1.5, crit_per_cpu => 4 },
        discover => sub { [ { id => 'load', name => ['name.load'] } ] },
        run      => \&run_load,
    },
    memory => {
        label => 'type.memory', category => 'system', interval => 60, enabled => 1,
        params => { warn_pct => 90, crit_pct => 98 },
        discover => sub { [ { id => 'memory', name => ['name.memory'] } ] },
        run      => \&run_memory,
    },
    disk => {
        label => 'type.disk', category => 'system', interval => 300, enabled => 1,
        params => { warn_pct => 85, crit_pct => 95, inode_warn_pct => 85, inode_crit_pct => 95 },
        discover => \&discover_disks,
        run      => \&run_disk,
    },
    mysql => {
        label => 'type.mysql', category => 'services', interval => 60, enabled => 1,
        params => {},
        discover => sub { _bin(qw(/usr/bin/mysqladmin /usr/sbin/mysqladmin)) ? [ { id => 'mysql', name => ['name.mysql'] } ] : [] },
        run      => \&run_mysql,
    },
    mailqueue => {
        label => 'type.mailqueue', category => 'mail', interval => 300, enabled => 1,
        params => { warn => 500, crit => 2500 },
        discover => sub { _bin('/usr/sbin/exim') ? [ { id => 'mailqueue', name => ['name.mailqueue'] } ] : [] },
        run      => \&run_mailqueue,
    },
    rbl => {
        label => 'type.rbl', category => 'mail', interval => 1800, enabled => 1,
        params => { lists => 'zen.spamhaus.org bl.spamcop.net b.barracudacentral.org psbl.surriel.com', extra_ips => '' },
        discover => sub { [ { id => 'rbl', name => ['name.rbl'] } ] },
        run      => \&run_rbl,
    },
    ssl => {
        label => 'type.ssl', category => 'security', interval => 3600, enabled => 1,
        params => { warn_days => 14, crit_days => 3 },
        discover => sub { [ { id => 'ssl', name => ['name.ssl'] } ] },
        run      => \&run_ssl,
    },
    backup => {
        label => 'type.backup', category => 'security', interval => 3600, enabled => 1,
        params => { max_age_hours => 30, partial_is_fail => 0 },
        discover => sub { [ { id => 'backup', name => ['name.backup'] } ] },
        run      => \&run_backup,
    },
    raid => {
        label => 'type.raid', category => 'system', interval => 300, enabled => 1,
        params => {},
        discover => \&discover_raid,
        run      => \&run_raid,
    },
);

sub category_label {
    my ( $cat, $lang ) = @_;
    for (@CATEGORIES) { return tl( $lang // $BetterStack::WHM::I18N::LANG, $_->[1] ) if $_->[0] eq $cat }
    return $cat;
}

sub type_label { tl( $_[1] // $BetterStack::WHM::I18N::LANG, $TYPES{ $_[0] }{label} ) }

sub public_lang {
    my ($config) = @_;
    my $l = $config->{public_lang} // '';
    return BetterStack::WHM::I18N::valid($l) ? $l : 'nl';
}

# Effective settings for a type: defaults merged with config.
sub type_settings {
    my ( $config, $type ) = @_;
    my $def = $TYPES{$type};
    my $cfg = ( $config->{checks} || {} )->{$type} || {};
    my %s = (
        enabled         => $cfg->{enabled} // $def->{enabled},
        interval        => $cfg->{interval} || $def->{interval},
        publish_details => $cfg->{publish_details} // 1,
    );
    for my $p ( keys %{ $def->{params} } ) {
        $s{$p} = $cfg->{$p} // $def->{params}{$p};
    }
    $s{interval} = 60 if $s{interval} < 60;
    return \%s;
}

# All instances for enabled types, honouring per-instance overrides.
# Returns arrayref of { id, type, category, name, name_msg, public_name, interval, enabled }.
# Names are rendered in the language of the public status page.
sub discover_all {
    my ( $config, $ctx ) = @_;
    $ctx ||= {};
    my $lang = public_lang($config);
    my @out;
    for my $type (@TYPE_ORDER) {
        my $ts = type_settings( $config, $type );
        next unless $ts->{enabled};
        my $list = eval { $TYPES{$type}{discover}->( $ctx, $ts ) } || [];
        for my $inst (@$list) {
            my $ov = ( $config->{instances} || {} )->{ $inst->{id} } || {};
            my $msg = $inst->{name};
            push @out, {
                %$inst,
                name_msg    => $msg,
                name        => render_msg( $msg, $lang ),
                type        => $type,
                category    => $TYPES{$type}{category},
                public_name => ( defined $ov->{public_name} && length $ov->{public_name} ) ? $ov->{public_name} : render_msg( $msg, $lang ),
                interval    => $ts->{interval},
                enabled     => $ov->{enabled} // $inst->{default_enabled} // 1,
            };
        }
    }
    return \@out;
}

sub run_instance {
    my ( $config, $inst, $ctx ) = @_;
    my $ts  = type_settings( $config, $inst->{type} );
    my $res = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 120;
        my $r = $TYPES{ $inst->{type} }{run}->( $inst, $ts, $ctx || {} );
        alarm 0;
        $r;
    };
    alarm 0;
    if ( !$res ) {
        my $err = $@;
        my $info;
        if    ( ref $err eq 'HASH' && $err->{msg} ) { $info = [ $err->{msg} ] }
        elsif ( ( $err // '' ) =~ /^timeout/ )      { $info = [ ['err.timeout'] ] }
        else { $err = "$err"; $err =~ s/\s+\z//; $info = length $err ? [$err] : [ ['err.unknown'] ] }
        $res = { status => 'fail', detail => [ ['r.check_failed'] ], info => $info };
    }
    $res->{status} ||= 'fail';
    $res->{detail} //= [];
    $res->{info}   //= [];
    return $res;
}

# ---------------------------------------------------------------- helpers

sub _read {
    my ( $path, $max ) = @_;
    open my $fh, '<', $path or return undef;
    if ( $max && -s $fh > $max ) { seek $fh, -$max, 2 }    # only the tail of big logs
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

sub level {
    my ( $value, $warn, $crit ) = @_;
    return 'fail' if defined $crit && $crit ne '' && $value >= $crit;
    return 'warn' if defined $warn && $warn ne '' && $value >= $warn;
    return 'ok';
}

sub worst {
    my %rank = ( ok => 0, warn => 1, fail => 2 );
    my $w = 'ok';
    for (@_) { $w = $_ if $rank{$_} > $rank{$w} }
    return $w;
}

sub cpu_count {
    my $t = _read("$PROC/cpuinfo") // '';
    my $n = () = $t =~ /^processor\s*:/mg;
    return $n || 1;
}

# ---------------------------------------------------------------- server

sub run_server {
    my $up = _read("$PROC/uptime") // '';
    my ($secs) = $up =~ /^([\d.]+)/;
    # Uptime stays internal: publicly it would reveal how long the kernel has gone unpatched.
    return { status => 'ok', detail => [ ['r.online'] ], info => defined $secs ? [ [ 'r.uptime', { dur => $secs } ] ] : [] };
}

# ---------------------------------------------------------------- services

sub service_status {
    my ($ctx) = @_;
    return $ctx->{servicestatus} if $ctx->{servicestatus};
    my $bin = "$CPANEL/bin/whmapi1";
    return $ctx->{servicestatus} = [] unless -x $bin;
    my ( $code, $out ) = run_cmd( 60, $bin, '--output=json', 'servicestatus' );
    $ctx->{servicestatus} = parse_servicestatus($out);
    return $ctx->{servicestatus};
}

sub parse_servicestatus {
    my ($json) = @_;
    my $data = json_decode($json) or return [];
    my $list = ( $data->{data} || {} )->{service} || [];
    return [ grep { ref $_ eq 'HASH' && $_->{name} } @$list ];
}

sub discover_services {
    my ($ctx) = @_;
    my @out;
    for my $svc ( @{ service_status($ctx) } ) {
        next unless $svc->{installed} && $svc->{enabled};
        my $name = exists $BetterStack::WHM::I18N::S{"svc.$svc->{name}"} ? ["svc.$svc->{name}"] : ( $svc->{display_name} || $svc->{name} );
        push @out, { id => "service:$svc->{name}", name => $name, service => $svc->{name}, default_enabled => $DEFAULT_SERVICES{ $svc->{name} } ? 1 : 0 };
    }
    return \@out;
}

sub run_service {
    my ( $inst, $ts, $ctx ) = @_;
    my ($svc) = grep { $_->{name} eq $inst->{service} } @{ service_status($ctx) };
    return { status => 'fail', detail => [ ['r.unknown_status'] ], info => [ ['r.svc_missing'] ] } unless $svc;
    return { status => 'ok', detail => [ ['r.active'] ] } if $svc->{running};
    return { status => 'fail', detail => [ ['r.inactive'] ], info => [ [ 'r.svc_down_info', $svc->{name} ] ] };
}

# ---------------------------------------------------------------- load

sub parse_loadavg {
    my ($t) = @_;
    return unless defined $t;
    my @l = ( split /\s+/, $t )[ 0 .. 2 ];
    return @l;
}

sub run_load {
    my ( $inst, $ts ) = @_;
    my @l = parse_loadavg( _read("$PROC/loadavg") ) or _die( 'err.read', 'loadavg' );
    my $cpus   = cpu_count();
    my $per    = $l[1] / $cpus;                       # 5 minute average
    my $status = level( $per, $ts->{warn_per_cpu}, $ts->{crit_per_cpu} );
    return {
        status => $status,
        detail => [ [ 'r.load', ( map { sprintf '%.2f', $_ } @l ), $cpus, $per * 100 ] ],
    };
}

# ---------------------------------------------------------------- memory

sub parse_meminfo {
    my ($t) = @_;
    my %m;
    for ( split /\n/, $t // '' ) { $m{$1} = $2 * 1024 if /^(\w+):\s+(\d+)/ }
    return \%m;
}

sub run_memory {
    my ( $inst, $ts ) = @_;
    my $m = parse_meminfo( _read("$PROC/meminfo") );
    _die( 'err.read', 'meminfo' ) unless $m->{MemTotal};
    my $avail = $m->{MemAvailable} // ( ( $m->{MemFree} || 0 ) + ( $m->{Cached} || 0 ) + ( $m->{Buffers} || 0 ) );
    my $used_pct = 100 * ( $m->{MemTotal} - $avail ) / $m->{MemTotal};
    my $detail = [ [ 'r.mem', $used_pct, { bytes => $m->{MemTotal} - $avail }, { bytes => $m->{MemTotal} } ] ];
    if ( $m->{SwapTotal} ) {
        my $swap_used = $m->{SwapTotal} - ( $m->{SwapFree} || 0 );
        push @$detail, [ 'r.swap', 100 * $swap_used / $m->{SwapTotal} ];
    }
    return { status => level( $used_pct, $ts->{warn_pct}, $ts->{crit_pct} ), detail => $detail };
}

# ---------------------------------------------------------------- disk

my %SKIP_FS = map { $_ => 1 } qw(tmpfs devtmpfs overlay squashfs proc sysfs cgroup cgroup2 devpts nfs nfs4 cifs fuse.lxcfs efivarfs autofs ramfs iso9660 fuse.sshfs);

sub parse_df {
    my ($out) = @_;
    my @rows;
    for my $line ( split /\n/, $out // '' ) {
        next if $line =~ /^Filesystem/;
        my @f = split /\s+/, $line;
        next unless @f >= 7;
        my ( $dev, $type, $total, $used, $avail, $pct, $mount ) = @f;
        $mount = join ' ', @f[ 6 .. $#f ];
        push @rows, { dev => $dev, type => $type, total => $total, used => $used, avail => $avail, pct => ( $pct =~ /(\d+)/ )[0] // 0, mount => $mount };
    }
    return \@rows;
}

sub disk_rows {
    my ($ctx) = @_;
    return $ctx->{df} if $ctx->{df};
    my $df = _bin(qw(/usr/bin/df /bin/df)) or return $ctx->{df} = [];
    # -l: local filesystems only, so a hanging network mount cannot block us.
    my ( undef, $out )  = run_cmd( 30, $df, '-P', '-T', '-l', '-k' );
    my ( undef, $iout ) = run_cmd( 30, $df, '-P', '-T', '-l', '-i' );
    my $rows   = parse_df($out);
    my %inodes = map { $_->{mount} => $_ } @{ parse_df($iout) };
    my ( @keep, %seen );
    for my $r (@$rows) {
        next if $SKIP_FS{ $r->{type} };
        next if $r->{mount} =~ m{^/(proc|sys|dev|run|snap)(/|$)};
        next if $r->{mount} =~ m{/virtfs/};      # cPanel jailshell bind mounts
        next if $seen{ $r->{dev} }++ && $r->{dev} =~ m{^/};
        $r->{inode_pct} = $inodes{ $r->{mount} } ? $inodes{ $r->{mount} }{pct} : 0;
        push @keep, $r;
    }
    return $ctx->{df} = \@keep;
}

sub discover_disks {
    my ($ctx) = @_;
    # /boot and friends rarely matter to customers: discovered but off by default.
    return [ map { { id => "disk:$_->{mount}", name => [ 'name.disk', $_->{mount} ], mount => $_->{mount}, default_enabled => ( $_->{mount} =~ m{^/boot(/|$)} ? 0 : 1 ) } }
          @{ disk_rows($ctx) } ];
}

sub run_disk {
    my ( $inst, $ts, $ctx ) = @_;
    my ($r) = grep { $_->{mount} eq $inst->{mount} } @{ disk_rows($ctx) };
    return { status => 'fail', detail => [ ['r.disk_missing'] ], info => [ [ 'r.disk_missing_info', $inst->{mount} ] ] } unless $r;
    my $status = worst( level( $r->{pct}, $ts->{warn_pct}, $ts->{crit_pct} ), level( $r->{inode_pct}, $ts->{inode_warn_pct}, $ts->{inode_crit_pct} ) );
    return {
        status => $status,
        detail => [ [ 'r.disk', $r->{pct}, { bytes => $r->{avail} * 1024 }, { bytes => $r->{total} * 1024 } ], [ 'r.inodes', $r->{inode_pct} ] ],
    };
}

# ---------------------------------------------------------------- mysql

sub run_mysql {
    my $bin = _bin(qw(/usr/bin/mysqladmin /usr/sbin/mysqladmin)) or _die( 'err.notfound', 'mysqladmin' );
    my ( $code, $out ) = run_cmd( 20, $bin, 'status' );
    if ( $code != 0 ) {
        $out =~ s/\s+\z//;
        return { status => 'fail', detail => [ ['r.db_down'] ], info => [$out] };
    }
    my ($threads) = $out =~ /Threads:\s*(\d+)/;
    my ($qps)     = $out =~ /Queries per second avg:\s*([\d.]+)/;
    my ($slow)    = $out =~ /Slow queries:\s*(\d+)/;
    my ($uptime)  = $out =~ /Uptime:\s*(\d+)/;
    my @p = ( ['r.db_ok'] );
    push @p, [ 'r.db_conns', $threads ] if defined $threads;
    push @p, [ 'r.db_qps', sprintf( '%.1f', $qps ) ] if defined $qps;
    push @p, [ 'r.uptime', { dur => $uptime } ] if defined $uptime;
    return { status => 'ok', detail => \@p, info => defined $slow ? [ [ 'r.slow', $slow ] ] : [] };
}

# ---------------------------------------------------------------- mail queue

sub run_mailqueue {
    my ( $inst, $ts ) = @_;
    my $exim = _bin('/usr/sbin/exim') or _die( 'err.notfound', 'exim' );
    my ( $code, $out ) = run_cmd( 60, $exim, '-bpc' );
    _die( 'err.cmd', 'exim -bpc', $out ) unless $code == 0 && $out =~ /^\s*(\d+)/;
    my $n = $1;
    return { status => level( $n, $ts->{warn}, $ts->{crit} ), detail => [ [ 'r.queue', $n ] ] };
}

# ---------------------------------------------------------------- rbl

sub server_ips {
    my ($ts) = @_;
    my @ips;
    my $main = _read("$VARCP/mainip");
    push @ips, $1 if defined $main && $main =~ /(\d+\.\d+\.\d+\.\d+)/;
    push @ips, grep { /^\d+\.\d+\.\d+\.\d+$/ } split /[\s,]+/, ( $ts->{extra_ips} // '' );
    my %s;
    return grep { !$s{$_}++ } @ips;
}

# DNS lookup used by the RBL check (replaceable in tests). Returns the
# dotted-quad answer or undef (NXDOMAIN / no answer).
our $RESOLVE = sub {
    my $packed = inet_aton( $_[0] );
    return $packed ? join( '.', unpack 'C4', $packed ) : undef;
};

sub _rbl_query {
    my ( $ip, $zone ) = @_;
    # Trailing dot: an absolute name, so resolv.conf "search" domains are never
    # appended (a wildcard record there would make every lookup "listed").
    return $RESOLVE->( join( '.', reverse split /\./, $ip ) . ".$zone." );
}

# RFC 5782: 127.0.0.1 must never be listed and 127.0.0.2 must always be.
# If the resolver gets that wrong (wildcard, hijacking, blocked public
# resolver), its answers for this list cannot be trusted.
sub rbl_zone_ok {
    my ( $zone, $ctx ) = @_;
    $ctx ||= {};
    return $ctx->{rbl_zone_ok}{$zone} //= do {
        my $neg = _rbl_query( '127.0.0.1', $zone );
        my $pos = _rbl_query( '127.0.0.2', $zone );
        !defined $neg && defined $pos && $pos =~ /^127\.0\.0\.(\d+)$/ && $1 >= 2 ? 1 : 0;
    };
}

# Returns ( 'listed' | 'clean' | 'unknown', $answer ).
sub rbl_lookup {
    my ( $ip, $zone, $ctx ) = @_;
    return ('unknown') unless rbl_zone_ok( $zone, $ctx );
    my $ans = _rbl_query( $ip, $zone );
    return ('clean') unless defined $ans;
    # Real listings are 127.0.0.2-127.0.0.254; anything else (127.255.255.x
    # error codes from Spamhaus, 127.0.0.1, non-loopback) is not a listing.
    return ( 'listed', $ans ) if $ans =~ /^127\.0\.0\.(\d+)$/ && $1 >= 2 && $1 <= 254;
    return ( 'unknown', $ans );
}

sub run_rbl {
    my ( $inst, $ts, $ctx ) = @_;
    my @ips   = server_ips($ts) or _die('err.noip');
    my @zones = grep { length } split /[\s,]+/, ( $ts->{lists} // '' );
    my ( @listed, %unknown, $checked );
    for my $ip (@ips) {
        for my $z (@zones) {
            my ( $r, $ans ) = rbl_lookup( $ip, $z, $ctx );
            if    ( $r eq 'listed' )  { push @listed, [ 'r.rbl_listed_item', $ip, $z, $ans ]; $checked++ }
            elsif ( $r eq 'unknown' ) { $unknown{$z} = 1 }
            else                      { $checked++ }
        }
    }
    my @unknown = %unknown ? ( [ 'r.rbl_unknown', join( ', ', sort keys %unknown ) ] ) : ();
    if (@listed) {
        return { status => 'fail', detail => [ [ 'r.rbl_listed', scalar @listed ] ], info => [ @listed, @unknown ] };
    }
    return { status => 'warn', detail => [ ['r.rbl_cannot'] ], info => \@unknown } unless $checked;
    return { status => 'ok', detail => [ [ $checked == 1 ? 'r.rbl_clean_1' : 'r.rbl_clean_n', $checked ] ], info => \@unknown };
}

# ---------------------------------------------------------------- ssl

my %MON = ( Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5, Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11 );

# "notAfter=Mar  3 12:00:00 2027 GMT" -> epoch, parsed in Perl (no extra process).
sub parse_openssl_date {
    my ($s) = @_;
    return undef unless defined $s && $s =~ /notAfter=(\w{3})\s+(\d{1,2})\s+(\d\d):(\d\d):(\d\d)\s+(\d{4})\s+GMT/;
    return undef unless exists $MON{$1};
    return eval { timegm( $5, $4, $3, $2, $MON{$1}, $6 ) };
}

sub cert_end_epoch {
    my ($file) = @_;
    my $openssl = _bin(qw(/usr/bin/openssl /bin/openssl)) or _die( 'err.notfound', 'openssl' );
    my ( $code, $out ) = run_cmd( 10, $openssl, 'x509', '-enddate', '-noout', '-in', $file );
    return $code == 0 ? parse_openssl_date($out) : undef;
}

sub run_ssl {
    my ( $inst, $ts ) = @_;
    my @files = grep { -f && !-l } glob("$VARCP/ssl/apache_tls/*/combined"), "$VARCP/ssl/cpanel/mycpanel.pem";
    return { status => 'ok', detail => [ ['r.ssl_none'] ] } unless @files;
    my $now = time;
    my ( @crit, @warn, $soonest, $soonest_name );
    for my $f (@files) {
        my $end = cert_end_epoch($f) // next;
        my ($name) = $f =~ m{apache_tls/([^/]+)/} ? $1 : ('cpanel-service');
        next if $name =~ /^\*/;
        my $days = int( ( $end - $now ) / 86400 );
        if ( !defined $soonest || $days < $soonest ) { $soonest = $days; $soonest_name = $name }
        push @crit, "$name ($days d)" if $days <= $ts->{crit_days};
        push @warn, "$name ($days d)" if $days > $ts->{crit_days} && $days <= $ts->{warn_days};
    }
    my $n = @files;
    my $status = @crit ? 'fail' : @warn ? 'warn' : 'ok';
    my $detail = [ [ 'r.ssl_count', $n ] ];
    push @$detail, [ 'r.ssl_next', $soonest ] if defined $soonest;
    push @$detail, [ 'r.ssl_soon', @crit + @warn ] if @crit || @warn;
    my $info = [ ( @crit ? [ 'r.ssl_crit', join( ', ', @crit ) ] : () ), ( @warn ? [ 'r.ssl_warn', join( ', ', @warn ) ] : () ) ];
    $info = [ [ 'r.ssl_first', $soonest_name ] ] if !@$info && $soonest_name;
    return { status => $status, detail => $detail, info => $info };
}

# ---------------------------------------------------------------- backup

sub parse_backup_log {
    my ($text) = @_;
    return 'success' if $text =~ /Final state is Backup::Success/;
    return 'partial' if $text =~ /Final state is Backup::PartialFailure/;
    return 'failure' if $text =~ /Final state is Backup::Failure/;
    return 'success' if $text =~ /Completed at/;
    return 'running';
}

sub run_backup {
    my ( $inst, $ts ) = @_;
    my @logs = sort { ( stat $b )[9] <=> ( stat $a )[9] } glob("$CPANEL/logs/cpbackup/*.log");
    return { status => 'fail', detail => [ ['r.backup_none'] ], info => [ [ 'r.backup_nologs', "$CPANEL/logs/cpbackup" ] ] } unless @logs;

    # Skip a run that is still in progress, judge the newest finished one.
    my ( $state, $mtime );
    for my $log ( @logs[ 0 .. ( $#logs < 2 ? $#logs : 2 ) ] ) {
        $state = parse_backup_log( _read( $log, 64 * 1024 ) // '' );
        $mtime = ( stat $log )[9];
        last unless $state eq 'running';
    }
    my $age_h  = ( time - $mtime ) / 3600;
    my $ago    = { dur => time - $mtime };
    my $status = 'ok';
    my $key;
    if    ( $state eq 'failure' ) { $status = 'fail'; $key = 'r.backup_failed' }
    elsif ( $state eq 'partial' ) { $status = $ts->{partial_is_fail} ? 'fail' : 'warn'; $key = 'r.backup_partial' }
    elsif ( $state eq 'running' ) { $key = 'r.backup_running' }
    else                          { $key = 'r.backup_ok' }
    if ( $age_h > $ts->{max_age_hours} ) { $status = 'fail'; $key = 'r.backup_old' }
    return { status => $status, detail => [ [ $key, $ago ] ] };
}

# ---------------------------------------------------------------- raid

sub parse_mdstat {
    my ($t) = @_;
    my @arrays;
    my @lines = split /\n/, $t // '';
    for my $i ( 0 .. $#lines ) {
        next unless $lines[$i] =~ /^(md\w+)\s*:\s*(\w+)\s+(\S+)?/;
        my %a = ( name => $1, state => $2, level => $3 // '' );
        my $next = $lines[ $i + 1 ] // '';
        ( $a{map} ) = $next =~ /\[([U_]+)\]/;
        $a{degraded} = ( defined $a{map} && $a{map} =~ /_/ ) || $a{state} ne 'active' ? 1 : 0;
        my $after = join "\n", @lines[ $i + 1 .. ( $i + 3 > $#lines ? $#lines : $i + 3 ) ];
        ( $a{progress} ) = $after =~ /(recovery|resync|check)\s*=\s*([\d.]+%)/ ? "$1 $2" : ();
        push @arrays, \%a;
    }
    return \@arrays;
}

sub discover_raid {
    return [ map { { id => "raid:$_->{name}", name => [ 'name.raid', $_->{name} ], md => $_->{name} } } @{ parse_mdstat( _read("$PROC/mdstat") ) } ];
}

sub run_raid {
    my ($inst) = @_;
    my ($a) = grep { $_->{name} eq $inst->{md} } @{ parse_mdstat( _read("$PROC/mdstat") ) };
    return { status => 'fail', detail => [ ['r.raid_missing'] ] } unless $a;
    my $map = $a->{map} ? " [$a->{map}]" : '';
    my @progress = $a->{progress} ? ( $a->{progress} ) : ();
    if ( $a->{degraded} ) {
        return { status => 'fail', detail => [ [ 'r.raid_degraded', $a->{level}, $map ], @progress ] };
    }
    return { status => @progress ? 'warn' : 'ok', detail => [ [ 'r.raid_ok', $a->{level}, $map ], @progress ] };
}

1;
