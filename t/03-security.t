use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Test::More;

use BetterStack::WHM::Util qw(http_request run_cmd logmsg write_json);
use BetterStack::WHM::Engine ();

my $dir = tempdir( CLEANUP => 1 );

subtest 'http_request only sends to clean https URLs' => sub {
    for my $bad ( 'http://example.com/', "https://example.com/a\nheader = x", 'https://example.com/"x', 'file:///etc/passwd', 'https://user@evil/' ) {
        my $r = http_request( 'GET', $bad );
        ok( !$r->{success} && $r->{error} eq 'Invalid URL', "rejected: $bad" );
    }
    my $r = http_request( 'GET', 'https://example.com/', headers => { 'X-A' => "a\r\nInjected: 1" } );
    is( $r->{error}, 'Invalid header' );
};

subtest 'run_cmd: absolute path, clean environment, no stdin' => sub {
    ok( !eval { run_cmd( 5, 'env' ); 1 }, 'relative command refused' );
    local $ENV{EVIL} = 'x';
    local $ENV{PATH} = "$dir:$ENV{PATH}";
    my ( $code, $out ) = run_cmd( 5, '/usr/bin/env' );
    is( $code, 0 );
    unlike( $out, qr/EVIL/, 'caller environment not passed on' );
    like( $out, qr{^PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin$}m, 'fixed PATH' );
    like( $out, qr/^LC_ALL=C$/m );
    ( $code, $out ) = run_cmd( 5, '/bin/cat' );
    is( $out, '', 'stdin is /dev/null' );
};

subtest 'run_cmd keeps an enclosing timeout' => sub {
    my $t0 = time;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "outer\n" };
        alarm 2;
        run_cmd( 1, '/bin/true' );
        run_cmd( 10, '/bin/sleep', '5' );
        alarm 0;
        1;
    };
    alarm 0;
    ok( !$ok, 'outer alarm still fires' );
    cmp_ok( time - $t0, '<=', 4 );
};

subtest 'log file is private and refuses symlinks' => sub {
    local $BetterStack::WHM::Util::LOG_FILE = "$dir/test.log";
    logmsg( info => "regel1\nFORGED [ERROR] x" );
    is( ( stat "$dir/test.log" )[2] & 0777, 0600, 'log is 0600' );
    open my $fh, '<', "$dir/test.log"; my @l = <$fh>; close $fh;
    is( scalar @l, 1, 'newlines cannot forge log entries' );

    symlink "$dir/target", "$dir/link.log";
    local $BetterStack::WHM::Util::LOG_FILE = "$dir/link.log";
    logmsg( info => 'x' );
    ok( !-e "$dir/target", 'symlinked log not followed' );
};

subtest 'write_json is private and atomic' => sub {
    write_json( "$dir/c/config.json", { a => 1 } );
    is( ( stat "$dir/c/config.json" )[2] & 0777, 0600 );
    is( ( stat "$dir/c" )[2] & 0777, 0700 );
};

subtest 'API responses are validated' => sub {
    is( BetterStack::WHM::Engine::_id( { data => { id => '123' } } ), '123' );
    is( BetterStack::WHM::Engine::_id( { data => { id => '1/../../x' } } ), undef );
    is( BetterStack::WHM::Engine::_id( { data => 'x' } ), undef );
    is( BetterStack::WHM::Engine::_hb_url( { data => { attributes => { url => 'https://uptime.betterstack.com/api/v1/heartbeat/AbC123' } } } ),
        'https://uptime.betterstack.com/api/v1/heartbeat/AbC123' );
    for my $bad ( 'https://evil.com/api/v1/heartbeat/x', 'https://uptime.betterstack.com.evil.com/x', 'http://uptime.betterstack.com/x',
        "https://uptime.betterstack.com/x\nurl=y" )
    {
        is( BetterStack::WHM::Engine::_hb_url( { data => { attributes => { url => $bad } } } ), undef, "rejected $bad" );
    }
};

# ---- CGI: access control and CSRF, with a fake Whostmgr::ACLS
my $fake = "$dir/fakelib/Whostmgr";
system 'mkdir', '-p', $fake;
open my $acl, '>', "$fake/ACLS.pm" or die;
print $acl "package Whostmgr::ACLS; sub init_acls {1} sub hasroot { \$ENV{FAKE_ROOT} ? 1 : 0 } 1;\n";
close $acl;

sub cgi {
    my ( $method, $body, %env ) = @_;
    my $wrapper = <<"PL";
use lib '$FindBin::Bin/../lib', '$dir/fakelib';
use BetterStack::WHM::Util;
\$BetterStack::WHM::Util::ETC_DIR = '$dir/cgi-etc';
\$BetterStack::WHM::Util::VAR_DIR = '$dir/cgi-var';
\$BetterStack::WHM::Util::LOG_FILE = '$dir/cgi.log';
do '$FindBin::Bin/../cgi/index.cgi'; die \$@ if \$@;
PL
    open my $w, '>', "$dir/wrap.pl"; print $w $wrapper; close $w;
    open my $b, '>', "$dir/body"; print $b $body // ''; close $b;
    local %ENV = ( %ENV, REQUEST_METHOD => $method, CONTENT_LENGTH => length( $body // '' ), REMOTE_USER => 'root', HTTP_ACCEPT_LANGUAGE => 'nl', %env );
    return scalar `$^X -I$dir/fakelib $dir/wrap.pl < $dir/body 2>&1`;
}

subtest 'CGI access control' => sub {
    my $out = cgi( 'GET', '', FAKE_ROOT => 0, REMOTE_USER => 'root' );
    like( $out, qr/Toegang geweigerd/, 'non-root (e.g. reseller) denied even if REMOTE_USER claims root' );
    unlike( $out, qr/api_token/ );
    $out = cgi( 'GET', '', FAKE_ROOT => 1 );
    like( $out, qr/<h1 class="bsw-title">[^<]+<\/h1>/, 'root allowed' );
    unlike( $out, qr/Toegang geweigerd/ );
    like( $out, qr/Cache-Control: no-store/ );
};

subtest 'CGI CSRF protection' => sub {
    my $out = cgi( 'POST', 'action=save_settings&server_label=pwned', FAKE_ROOT => 1 );
    like( $out, qr/CSRF/, 'POST without token rejected' );
    ok( !-e "$dir/cgi-etc/config.json" || `cat $dir/cgi-etc/config.json` !~ /pwned/, 'nothing saved' );

    my ($token) = cgi( 'GET', '', FAKE_ROOT => 1 ) =~ /name="csrf" value="([0-9a-f]{64})"/;
    ok( $token, 'token rendered in forms' );
    $out = cgi( 'POST', "csrf=$token&action=save_settings&server_label=%3Cscript%3Ealert(1)%3C%2Fscript%3E", FAKE_ROOT => 1 );
    like( $out, qr/Instellingen opgeslagen/, 'POST with token accepted' );
    unlike( $out, qr/<script>alert/, 'stored value is escaped on output' );
    like( $out, qr/&lt;script&gt;alert\(1\)/ );

    my ($other) = cgi( 'GET', '', FAKE_ROOT => 1, REMOTE_USER => 'reseller' ) =~ /name="csrf" value="([0-9a-f]{64})"/;
    isnt( $other, $token, 'token is bound to the user' );
    is( ( stat "$dir/cgi-var/csrf.secret" )[2] & 0777, 0600, 'secret is private' );
};

done_testing;
