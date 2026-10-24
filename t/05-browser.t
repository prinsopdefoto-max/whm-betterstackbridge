use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;

# Real clicks in a headless browser. Skipped when Node.js + Playwright are not available.
my $node = `command -v node 2>/dev/null`;
chomp $node;
my $root = `npm root -g 2>/dev/null`;
chomp $root;
plan skip_all => 'node/playwright not available' unless $node && -d "$root/playwright";

my $dir = tempdir( CLEANUP => 1 );
system 'mkdir', '-p', "$dir/fakelib/Whostmgr";
open my $acl, '>', "$dir/fakelib/Whostmgr/ACLS.pm" or die;
print $acl "package Whostmgr::ACLS; sub init_acls {1} sub hasroot {1} 1;\n";
close $acl;
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

my $html = do { local %ENV = ( %ENV, REQUEST_METHOD => 'GET', REMOTE_USER => 'root', HTTP_ACCEPT_LANGUAGE => 'nl' ); `$^X $dir/wrap.pl` };
$html =~ s/\A.*?\r?\n\r?\n//s;    # strip CGI headers
open my $fh, '>', "$dir/page.html" or die;
print $fh $html;
close $fh;

local $ENV{NODE_PATH} = $root;
my $out = `$node $FindBin::Bin/browser/interact.js $dir/page.html`;
my $r   = eval { JSON::PP->new->decode($out) } || { fatal => $out };
ok( !$r->{fatal}, 'browser run' ) or diag $r->{fatal};
is( $r->{tab_click},           'settings', 'tab link switches the tab' );
is( $r->{after_select_click},  'settings', 'clicking a dropdown does not jump to another tab' );
is( $r->{select_value},        'en',       'dropdown value can be changed' );
is( $r->{after_select_change}, 'settings' );
ok( $r->{switch_toggled}, 'switch toggles' );
is( $r->{radio}, 'category', 'radio card can be selected' );
is( $r->{typed}, 'typed', 'text field accepts input' );
is( $r->{still_settings}, 'settings' );
ok( $r->{check_switch}, 'switch on the checks tab toggles' );
ok( $r->{item_switch},  'switch on the status page tab toggles' );
is( $r->{final_tab}, 'items' );
is_deeply( $r->{errors}, [], 'no JavaScript errors' );

done_testing;
