use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Test::More;

my $dir = tempdir( CLEANUP => 1 );
mkdir "$dir/proc";
my $w = sub { open my $fh, '>', "$dir/proc/$_[0]" or die; print $fh $_[1]; close $fh };
$w->( 'cpuinfo', "processor : 0\n" );
$w->( 'loadavg', "0.10 0.20 0.30 1/100 1\n" );
$w->( 'meminfo', "MemTotal: 1000 kB\nMemAvailable: 900 kB\n" );
$w->( 'uptime',  "100.0 1.0\n" );

use BetterStack::WHM::Util ();
$BetterStack::WHM::Util::ETC_DIR  = "$dir/etc";
$BetterStack::WHM::Util::VAR_DIR  = "$dir/var";
$BetterStack::WHM::Util::LOG_FILE = "$dir/log";
use BetterStack::WHM::Checks ();
use BetterStack::WHM::Config ();
use BetterStack::WHM::Engine ();
use BetterStack::WHM::API ();
use BetterStack::WHM::I18N ();
use JSON::PP ();
$BetterStack::WHM::Checks::PROC = "$dir/proc";

# Only the proc based checks (all in category "system") plus a fake mail check.
my %only = map { $_ => 1 } qw(server load memory);
$BetterStack::WHM::Checks::TYPES{$_}{enabled} = $only{$_} ? 1 : 0 for keys %BetterStack::WHM::Checks::TYPES;
$BetterStack::WHM::Checks::TYPES{fakemail} = {
    label => 'fake', category => 'mail', interval => 300, enabled => 1, params => {},
    discover => sub { [ { id => 'fakemail', name => 'Mailwachtrij' } ] },
    run      => sub { { status => 'ok', detail => '3 berichten in de wachtrij' } },
};
push @BetterStack::WHM::Checks::TYPE_ORDER, 'fakemail';

# ---- fake Better Stack API (keeps attributes like the real one)
my ( %hb, %res, %sec, %grp, @calls );
my $next  = 100;
my $quota = 99;
my $out = sub { my ( $h, $extra ) = @_; [ map { { id => "$_", attributes => { %{ $h->{$_} }, ( $extra ? $extra->($_) : () ) } } } sort keys %$h ] };
no warnings 'redefine';
*BetterStack::WHM::API::request = sub {
    my ( $self, $m, $path, $body ) = @_;
    push @calls, "$m $path";
    $self->{last_status} = 200;
    if ( $m eq 'GET' ) {
        return ( { data => $out->( \%sec ) }, undef ) if $path =~ m{^/status-pages/\d+/sections$};
        return ( { data => $out->( \%res ) }, undef ) if $path =~ m{^/status-pages/\d+/resources$};
        return ( { data => $out->( \%grp ) }, undef ) if $path eq '/heartbeat-groups';
        return ( { data => $out->( \%hb, sub { ( url => "https://uptime.betterstack.com/api/v1/heartbeat/tok$_[0]" ) } ) }, undef ) if $path eq '/heartbeats';
    }
    if ( $m eq 'POST' && $path eq '/heartbeat-groups' ) { my $id = $next++; $grp{$id} = {%$body}; return ( { data => { id => $id } }, undef ) }
    if ( $m eq 'POST' && $path eq '/heartbeats' ) {
        if ( keys %hb >= $quota ) {
            $self->{last_status} = 403;
            return ( undef, 'HTTP 403: Heartbeat quota reached. Please upgrade your account to add another heartbeat.' );
        }
        my $id = $next++; $hb{$id} = {%$body};
        return ( { data => { id => "$id", attributes => { url => "https://uptime.betterstack.com/api/v1/heartbeat/tok$id" } } }, undef );
    }
    if ( $m eq 'POST' && $path =~ m{/sections$} )  { my $id = $next++; $sec{$id} = {%$body}; return ( { data => { id => "$id" } }, undef ) }
    if ( $m eq 'POST' && $path =~ m{/resources$} ) { my $id = $next++; $res{$id} = {%$body}; return ( { data => { id => "$id" } }, undef ) }
    for ( [ resources => \%res ], [ heartbeats => \%hb ], [ sections => \%sec ] ) {
        my ( $kind, $h ) = @$_;
        if ( $m eq 'PATCH' && $path =~ m{/$kind/(\d+)$} ) {
            if ( !$h->{$1} ) { $self->{last_status} = 404; return ( undef, 'HTTP 404' ) }
            $h->{$1} = { %{ $h->{$1} }, %$body };
            return ( {}, undef );
        }
    }
    if ( $m eq 'DELETE' ) {
        my ($id) = $path =~ m{/(\d+)$};
        my $found = grep { exists $_->{$id} } \%hb, \%res, \%sec, \%grp;
        delete $_->{$id} for \%hb, \%res, \%sec, \%grp;
        # Deleting a heartbeat removes its status page items, like Better Stack does.
        delete $res{$_} for grep { ( $res{$_}{resource_id} // '' ) eq $id } keys %res;
        if ( !$found ) { $self->{last_status} = 404; return ( undef, 'HTTP 404' ) }
        return ( {}, undef );
    }
    die "unexpected $m $path";
};
my @pings;
*BetterStack::WHM::Engine::http_request = sub {
    my ( $m, $url, %o ) = @_;
    push @pings, [ $m, $url, $o{body} ];
    return { success => 1, status => 200, content => '' };
};
sub res_named { my $n = shift; ( grep { ( $res{$_}{public_name} // '' ) eq $n } keys %res )[0] }

# ---- not configured: checks run, nothing provisioned
my $r = BetterStack::WHM::Engine::run();
is( $r->{ran}, 4, 'four checks ran' );
is( scalar @calls, 0, 'no API calls without configuration' );

# ---- a v1 install left one heartbeat per check behind (legacy state keys)
my $cfg = BetterStack::WHM::Config::load();
$cfg->{api_token}      = 'tok';
$cfg->{status_page_id} = '7';
$cfg->{server_label}   = 'srv1';
$cfg->{public_lang}    = 'nl';    # expectations below are in Dutch
BetterStack::WHM::Config::save($cfg);
my $st = BetterStack::WHM::Config::load_state();
for my $legacy (qw(load memory)) {
    my $id = $next++;
    $hb{$id} = { name => "old $legacy" };
    $st->{items}{$legacy} = { heartbeat_id => "$id", heartbeat_url => "https://uptime.betterstack.com/api/v1/heartbeat/x$id" };
}
BetterStack::WHM::Config::save_state($st);
$quota = 3;    # 2 legacy heartbeats already use most of it

$r = BetterStack::WHM::Engine::run( force => 1 );
ok( $r->{ok}, 'run ok: legacy heartbeats removed before creating new ones' ) or diag explain $r;
is_deeply( [ sort map { $_->{name} } values %hb ], [ 'srv1: E-mail', 'srv1: Server' ], 'one bundled heartbeat per category' );
is( scalar keys %res, 2, 'two status page items' );
is( scalar keys %sec, 1, 'one section in single mode' );
is( ( values %sec )[0]{name}, 'srv1' );
my $sys = res_named('Server');
like( $res{$sys}{explanation}, qr/^Processorbelasting: Load .* · Werkgeheugen: 10% in gebruik/, 'bundle explanation lists member details' );
unlike( $res{$sys}{explanation}, qr/uptime/i, 'uptime not published' );
like( $res{$sys}{explanation}, qr/ \x{00B7} /, 'separator is a real middle dot' );
unlike( $res{$sys}{explanation}, qr/\x{00C2}/, 'no double-encoded UTF-8 (\x{00C2}\x{00B7})' );
like( JSON::PP->new->utf8->encode( [ $res{$sys}{explanation} ] ), qr/ \xC2\xB7 /, 'sent to the API as UTF-8 C2 B7' );
is( scalar( grep { $_->[0] eq 'GET' } @pings ), 2, 'one ping per bundle' );

# ---- nothing changed, nothing due
@calls = (); @pings = ();
$r = BetterStack::WHM::Engine::run();
is( $r->{ran}, 0, 'nothing due' );
is( scalar @calls, 0, 'no API calls when nothing changed' );

# ---- a forced run replaces an outdated explanation right away (e.g. after an upgrade)
$st = BetterStack::WHM::Config::load_state();
$st->{items}{'cat:system'}{explanation_sent} = "oud \x{00C2}\x{00B7} kapot";
$st->{items}{'cat:system'}{explanation_at}   = time;
BetterStack::WHM::Config::save_state($st);
$res{$sys}{explanation} = "oud \x{00C2}\x{00B7} kapot";
BetterStack::WHM::Engine::run( force => 1 );
unlike( $res{$sys}{explanation}, qr/kapot/, 'forced run pushes the explanation immediately' );

# ---- failure in a bundle -> /fail with the failing member
$w->( 'meminfo', "MemTotal: 1000 kB\nMemAvailable: 10 kB\n" );
@pings = ();
$r = BetterStack::WHM::Engine::run( force => 1 );
my ($fail) = grep { $_->[1] =~ m{/fail$} } @pings;
ok( $fail, 'bundle failure reported' );
like( $fail->[2], qr/\[fail\] Werkgeheugen: 99% in gebruik/ );
like( $res{$sys}{explanation}, qr/^\x{2716} Werkgeheugen: 99%/, 'failing member first in explanation' );

# ---- own heartbeat for one item, but the quota is full
$cfg = BetterStack::WHM::Config::load();
$cfg->{instances}{load} = { own => 1, public_name => 'CPU' };
$cfg->{group_names}{system} = 'Hosting';
BetterStack::WHM::Config::save($cfg);
$quota = 2;
@calls = ();
$r = BetterStack::WHM::Engine::run();
ok( !$r->{ok} );
is( scalar @{ $r->{errors} }, 1, 'one clear quota error' );
like( BetterStack::WHM::I18N::render_msg( $r->{errors}[0], 'nl' ), qr/Heartbeat-limiet/ );
ok( res_named('Hosting'), 'bundle renamed' );
@calls = ();
BetterStack::WHM::Engine::run();
is( scalar( grep { /^POST \/heartbeats/ } @calls ), 0, 'no retry storm after quota error' );

# ---- quota raised -> retried after backoff
$quota = 9;
$st = BetterStack::WHM::Config::load_state();
$st->{last_sync_attempt} -= 3600;
BetterStack::WHM::Config::save_state($st);
$r = BetterStack::WHM::Engine::run();
ok( $r->{ok}, 'sync retried after backoff' ) or diag explain $r;
ok( res_named('CPU'), 'own item on status page' );
is( scalar keys %hb, 3 );

# ---- back to bundled: own heartbeat removed
$cfg = BetterStack::WHM::Config::load();
delete $cfg->{instances}{load};
BetterStack::WHM::Config::save($cfg);
BetterStack::WHM::Engine::run();
is( scalar keys %hb, 2, 'own heartbeat deleted when bundled again' );

# ---- layout switch: per category -> one section, items move, empty sections removed
$cfg = BetterStack::WHM::Config::load();
$cfg->{section_mode} = 'category';
BetterStack::WHM::Config::save($cfg);
BetterStack::WHM::Engine::run();
is( scalar keys %sec, 2, 'one section per category' );
$cfg->{section_mode} = 'single';
BetterStack::WHM::Config::save($cfg);
$r = BetterStack::WHM::Engine::run();
ok( $r->{ok} );
is_deeply( [ map { $_->{name} } values %sec ], ['srv1'], 'back to one section, old ones deleted' );
my ($only_sec) = keys %sec;
is( scalar( grep { $_->{status_page_section_id} != $only_sec } values %res ), 0, 'all items moved to it' );
is( scalar keys %res, 2, 'items moved, not recreated' );

# ---- your own things in Better Stack are never touched
my $own_hb  = $next++; $hb{$own_hb}   = { name => 'Website example.com' };
my $own_hb2 = $next++; $hb{$own_hb2}  = { name => 'srv1: handmatig', heartbeat_group_id => 999 };    # not in our group
my $own_sec = $next++; $sec{$own_sec} = { name => 'srv1' . " \x{2014} " . 'Websites' };            # our naming, but has a monitor
my $own_res = $next++; $res{$own_res} = { resource_type => 'Monitor', resource_id => 555, status_page_section_id => $own_sec };

# ---- state file lost (e.g. hard reset): adopt instead of duplicating
my %before = ( hb => [ sort keys %hb ], res => [ sort keys %res ], sec => [ sort keys %sec ], grp => [ sort keys %grp ] );
unlink "$dir/var/state.json", "$dir/var/state.json.bak";
$r = BetterStack::WHM::Engine::run( force => 1 );
ok( $r->{ok}, 'run after lost state ok' ) or diag explain $r;
is_deeply( { hb => [ sort keys %hb ], res => [ sort keys %res ], sec => [ sort keys %sec ], grp => [ sort keys %grp ] },
    \%before, 'nothing created twice, nothing of yours removed' );
$st = BetterStack::WHM::Config::load_state();
is( scalar( grep { $_->{heartbeat_url} } values %{ $st->{items} } ), 2, 'existing heartbeats adopted and pinged again' );

# ---- damaged state file: the backup copy is used
open my $trunc, '>', "$dir/var/state.json"; close $trunc;    # zero length, like after a crash
@calls = ();
$r = BetterStack::WHM::Engine::run();
is( scalar( grep { /^POST/ } @calls ), 0, 'empty state.json -> backup used, nothing created' );

# ---- the situation from the screenshot: a complete second set exists
my $old_grp = $next++; $grp{$old_grp} = { name => 'srv1' };
my %old_sec;
for my $n ( 'Server', 'E-mail' ) {
    my $sid = $next++; $sec{$sid} = { name => "srv1 \x{2014} $n" };
    my $hid = $next++; $hb{$hid}  = { name => "srv1: $n", heartbeat_group_id => $old_grp };
    my $rid = $next++; $res{$rid} = { resource_type => 'Heartbeat', resource_id => $hid, status_page_section_id => $sid, public_name => $n };
    $old_sec{$sid} = 1;
}
my $legacy_hb = $next++; $hb{$legacy_hb} = { name => 'srv1: Processorbelasting', heartbeat_group_id => $old_grp };    # v1 leftover
$r = BetterStack::WHM::Engine::run( sync => 1 );
ok( $r->{ok}, 'sync with duplicates ok' ) or diag explain $r;
is_deeply( [ sort keys %hb ], [ sort( @{ $before{hb} } ) ], 'duplicate and leftover heartbeats removed' );
ok( !( grep { $old_sec{$_} } keys %sec ), 'duplicate sections removed' );
ok( !$grp{$old_grp}, 'empty duplicate group removed' );
ok( $hb{$own_hb} && $hb{$own_hb2} && $sec{$own_sec} && $res{$own_res}, 'your own heartbeats, section and monitor untouched' );
is( scalar( grep { ( $_->{resource_type} // '' ) eq 'Heartbeat' } values %res ), 2, 'exactly one status page item per bundle' );

# ---- same, in "per category" layout: duplicates carry exactly the same names
$cfg = BetterStack::WHM::Config::load();
$cfg->{section_mode} = 'category';
BetterStack::WHM::Config::save($cfg);
BetterStack::WHM::Engine::run();
my @current = sort grep { $sec{$_}{name} =~ /^srv1 \x{2014} / } keys %sec;
for my $n ( 'Server', 'E-mail' ) {
    my $sid = $next++; $sec{$sid} = { name => "srv1 \x{2014} $n" };
    my $hid = $next++; $hb{$hid}  = { name => "srv1: $n", heartbeat_group_id => BetterStack::WHM::Config::load_state()->{group_id} };
    my $rid = $next++; $res{$rid} = { resource_type => 'Heartbeat', resource_id => $hid, status_page_section_id => $sid, public_name => $n };
}
$r = BetterStack::WHM::Engine::run( sync => 1 );
ok( $r->{ok} ) or diag explain $r;
is_deeply( [ sort grep { $sec{$_}{name} =~ /^srv1 \x{2014} / } keys %sec ], [ sort @current ], 'same-name duplicate sections removed, the right ones kept' );
is( scalar( grep { ( $_->{resource_type} // '' ) eq 'Heartbeat' } values %res ), 2, 'still one item per bundle' );
$cfg->{section_mode} = 'single';
BetterStack::WHM::Config::save($cfg);
BetterStack::WHM::Engine::run();

# ---- cleanup
$st = BetterStack::WHM::Config::load_state();
my $errs = BetterStack::WHM::Engine::cleanup( $cfg, $st );
is( scalar @$errs, 0 );
is_deeply( [ sort( keys %hb ), sort( keys %res ), sort( keys %sec ), sort keys %grp ], [ sort( $own_hb, $own_hb2 ), $own_res, $own_sec ],
    'everything of the plugin removed, your own objects kept' );

# ---- defaults: internal services and /boot off, v1 config migrated
my $ctx = { servicestatus => [ map { { name => $_, installed => 1, enabled => 1, running => 1 } } qw(httpd p0f lfd exim) ],
            df => [ map { { mount => $_ } } qw(/ /boot /boot/efi) ] };
my %d = map { $_->{id} => $_->{enabled} } @{ BetterStack::WHM::Checks::discover_all( { checks => { service => { enabled => 1 }, disk => { enabled => 1 } } }, $ctx ) };
is_deeply( [ @d{qw(service:httpd service:exim service:p0f service:lfd disk:/ disk:/boot disk:/boot/efi)} ], [ 1, 1, 0, 0, 1, 0, 0 ] );

BetterStack::WHM::Util::write_json( "$dir/etc/config.json", { instances => { 'service:p0f' => { enabled => 1, public_name => '' }, load => { enabled => 0 } } } );
$cfg = BetterStack::WHM::Config::load();
is_deeply( $cfg->{instances}, { load => { enabled => 0 } }, 'v1 "enabled => 1" overrides dropped, explicit off kept' );

BetterStack::WHM::Util::write_json( "$dir/etc/config.json", { config_version => 2, section_mode => 'category' } );
is( BetterStack::WHM::Config::load()->{section_mode}, 'single', 'v2 installs move to one section per server' );
BetterStack::WHM::Util::write_json( "$dir/etc/config.json", { config_version => 3, section_mode => 'category' } );
is( BetterStack::WHM::Config::load()->{section_mode}, 'category', 'a later explicit choice is kept' );
BetterStack::WHM::Util::write_json( "$dir/etc/config.json", { config_version => 3 } );
is( BetterStack::WHM::Config::load()->{public_lang}, 'nl', 'existing installs keep a Dutch status page' );
BetterStack::WHM::Util::write_json( "$dir/etc/config.json", { config_version => 3, public_lang => 'de' } );
is( BetterStack::WHM::Config::load()->{public_lang}, 'de', 'a chosen language is kept' );
unlink "$dir/etc/config.json", "$dir/etc/config.json.bak";
is( BetterStack::WHM::Config::load()->{public_lang}, 'en', 'new installs default to English' );

done_testing;
