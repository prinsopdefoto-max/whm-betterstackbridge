use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Test::More;

use BetterStack::WHM::I18N qw(tl render render_msg);
use BetterStack::WHM::UIStrings ();
use BetterStack::WHM::Checks ();
use BetterStack::WHM::Engine ();

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

my %S = %BetterStack::WHM::I18N::S;
my @langs = map { $_->[0] } @BetterStack::WHM::I18N::LANGS;

subtest 'every text exists in every language, with the same placeholders' => sub {
    my @bad;
    for my $k ( sort keys %S ) {
        for my $l (@langs) {
            push @bad, "$k: no $l" unless defined $S{$k}{$l} && length $S{$k}{$l};
        }
        my $ph = sub { join ',', ( $_[0] // '' ) =~ /%(?!%)[-\d.]*([sd])/g };
        my $ref = $ph->( $S{$k}{nl} );
        for my $l (@langs) {
            push @bad, "$k: placeholders $l differ" if $ph->( $S{$k}{$l} ) ne $ref;
        }
    }
    is_deeply( \@bad, [], 'no missing translations or mismatched placeholders' ) or diag join "\n", @bad;
};

subtest 'every key used in the code is defined' => sub {
    my %used;
    for my $f ( glob("$FindBin::Bin/../lib/BetterStack/WHM/*.pm"), "$FindBin::Bin/../cgi/index.cgi", "$FindBin::Bin/../bin/bswhm" ) {
        open my $fh, '<:encoding(UTF-8)', $f or die $f;
        local $/;
        my $src = <$fh>;
        $used{$1} = $f while $src =~ /['"]((?:ui|cli|r|e|err|log|cat|type|typedesc|param|name|svc|dur)\.[a-z0-9_-]+)['"]/g;
    }
    my @missing = grep { !$S{$_} } sort keys %used;
    is_deeply( \@missing, [], 'all keys defined' ) or diag join "\n", map { "$_ ($used{$_})" } @missing;
    for my $t (@BetterStack::WHM::Checks::TYPE_ORDER) {
        ok( $S{"type.$t"} && $S{"typedesc.$t"}, "labels for check type $t" );
        ok( $S{"param.$_"}, "label for $t/$_" ) for keys %{ $BetterStack::WHM::Checks::TYPES{$t}{params} };
    }
};

subtest 'rendering' => sub {
    is( render( 'plain text', 'en' ), 'plain text', 'old plain-string results still render' );
    is( render( [ [ 'r.queue', 3 ], 'raw' ], 'en' ), '3 messages in the queue, raw' );
    is( render( [ [ 'r.backup_ok', { dur => 3 * 86400 } ] ], 'de' ), 'Erfolgreich, letztes vor 3 Tagen' );
    is( render( [ [ 'r.mem', 50, { bytes => 1024**3 }, { bytes => 2 * 1024**3 } ] ], 'nl' ), '50% in gebruik (1.0 GB van 2.0 GB)' );
    is( render_msg( [ 'e.err', [ 'e.create_hb', 'x' ], 'HTTP 500' ], 'en' ), "Create heartbeat 'x': HTTP 500", 'nested messages' );
    is( tl( 'xx', 'r.active' ), 'Running', 'unknown language falls back to English' );
    is( tl( 'en', 'no.such.key' ), 'no.such.key', 'unknown key shows the key' );
};

subtest 'language detection' => sub {
    is( BetterStack::WHM::I18N::detect( undef, 'de-DE,de;q=0.9,en;q=0.8' ), 'de' );
    is( BetterStack::WHM::I18N::detect( 'en_US', 'nl' ), 'en', 'WHM locale wins over the browser' );
    is( BetterStack::WHM::I18N::detect( 'fr', 'fr-FR, nl;q=0.5' ), 'nl', 'first supported language' );
    is( BetterStack::WHM::I18N::detect( 'fr', '' ), undef );
};

subtest 'status page texts follow the status page language' => sub {
    my $results = { load => { status => 'ok', detail => [ [ 'r.load', '0.10', '0.20', '0.30', 4, 5 ] ] },
                    'service:httpd' => { status => 'fail', detail => [ ['r.inactive'] ], info => [ [ 'r.svc_down_info', 'httpd' ] ] } };
    for my $case ( [ en => qr/^\x{2716} Web server: Not running \x{b7} CPU load: Load 0\.10/, qr/\[fail\] Web server: Not running \(httpd is not running/ ],
                   [ de => qr/^\x{2716} Webserver: Nicht aktiv \x{b7} CPU-Auslastung: Last 0\.10/, qr/\[fail\] Webserver: Nicht aktiv/ ] ) {
        my ( $lang, $pub, $body ) = @$case;
        my $cfg = { public_lang => $lang, publish_details => 1 };
        my $ctx = { servicestatus => [ { name => 'httpd', installed => 1, enabled => 1, running => 0 } ], df => [] };
        local $BetterStack::WHM::Checks::TYPES{$_}{enabled} = ( $_ eq 'load' || $_ eq 'service' ) ? 1 : 0 for keys %BetterStack::WHM::Checks::TYPES;
        my @inst = grep { $_->{enabled} } @{ BetterStack::WHM::Checks::discover_all( $cfg, $ctx ) };
        $_->{category} = 'system' for @inst;    # put both in one bundle
        my ($unit) = @{ BetterStack::WHM::Engine::units( $cfg, \@inst ) };
        my $ur = BetterStack::WHM::Engine::unit_result( $cfg, $unit, $results );
        like( $ur->{public}, $pub, "public text in $lang" );
        like( $ur->{body},   $body, "incident text in $lang" );
        is( $unit->{public_name}, tl( $lang, 'cat.system' ), "bundle name in $lang" );
    }
};

# ---- the WHM page in each language
my $dir = tempdir( CLEANUP => 1 );
system 'mkdir', '-p', "$dir/fakelib/Whostmgr";
open my $acl, '>', "$dir/fakelib/Whostmgr/ACLS.pm" or die;
print $acl "package Whostmgr::ACLS; sub init_acls {1} sub hasroot {1} 1;\n";
close $acl;

sub page {
    my (%env) = @_;
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
    local %ENV = ( %ENV, REQUEST_METHOD => 'GET', REMOTE_USER => 'root', HTTP_ACCEPT_LANGUAGE => '', %env );
    my $out = `$^X $dir/wrap.pl 2>&1`;
    utf8::decode($out);
    return $out;
}

subtest 'WHM page languages' => sub {
    like( page( HTTP_ACCEPT_LANGUAGE => 'en-GB,en' ), qr/All systems operational|No data yet|Connect this server/, 'English from the browser' );
    like( page( HTTP_ACCEPT_LANGUAGE => 'de' ), qr/Einstellungen/, 'German from the browser' );
    like( page(), qr/Settings/, 'English for a new install without browser language' );
    for my $p ( page( HTTP_ACCEPT_LANGUAGE => 'en' ), page( HTTP_ACCEPT_LANGUAGE => 'de' ) ) {
        ( my $text = $p ) =~ s{<(script|style)\b.*?</\1>}{}gs;
        my @keys = grep { index( $text, $_ ) >= 0 } grep { /^(?:ui|cli|upd|mt|r|e|err|param|type|typedesc)\./ } keys %S;
        is_deeply( \@keys, [], 'no untranslated keys on the page' );
        unlike( $p, qr/(?:Use of uninitialized|line \d+\.)/, 'no Perl warnings' );
    }
};

done_testing;
