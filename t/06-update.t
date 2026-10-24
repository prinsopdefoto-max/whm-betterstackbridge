use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Test::More;

use BetterStack::WHM::Util ();
use BetterStack::WHM::Update ();
use BetterStack::WHM::I18N ();
use BetterStack::WHM::UIStrings ();

my $git = BetterStack::WHM::Update::git_bin();
plan skip_all => 'git not available' unless $git;

my $dir = tempdir( CLEANUP => 1 );
$BetterStack::WHM::Util::VAR_DIR  = "$dir/var";
$BetterStack::WHM::Util::LOG_FILE = "$dir/log";
my $info_file = "$dir/var/install.json";

# Test set-up commands, with git's progress chatter hidden.
sub quiet { open my $save, '>&', \*STDERR; open STDERR, '>', '/dev/null'; my $r = system(@_); open STDERR, '>&', $save; $r == 0 or die "@_ failed\n" }
sub g { my $d = shift; quiet( $git, '-C', $d, '-c', 'user.name=t', '-c', 'user.email=t@example.com', @_ ) }
sub out { my $d = shift; my $o = `$git -C $d @_`; chomp $o; $o }
sub put { open my $fh, '>', $_[0] or die; print $fh $_[1]; close $fh }

# "GitHub" (a bare repository), a working copy to push from, and the clone the plugin was installed from.
quiet( $git, 'init', '-q', '--bare', '-b', 'main', "$dir/remote.git" );
quiet( $git, 'clone', '-q', "$dir/remote.git", "$dir/dev" );
g( "$dir/dev", 'checkout', '-q', '-b', 'main' );
put( "$dir/dev/README", "v1\n" );
g( "$dir/dev", 'add', '.' );
g( "$dir/dev", 'commit', '-q', '-m', 'First' );
g( "$dir/dev", 'push', '-q', 'origin', 'main' );
quiet( $git, 'clone', '-q', "$dir/remote.git", "$dir/src" );
chmod 0755, "$dir/src";

subtest 'without install info' => sub {
    my $s = BetterStack::WHM::Update::check();
    is( $s->{state}, 'unknown' );
    is_deeply( $s->{reason}, ['upd.no_info'] );
    like( BetterStack::WHM::Update::command(undef), qr/git pull && \.\/install\.sh/ );
};

BetterStack::WHM::Util::write_json( $info_file, { source => "$dir/src", commit => out( "$dir/src", 'rev-parse HEAD' ), upstream => 'origin/main', at => time } );

subtest 'up to date' => sub {
    my $s = BetterStack::WHM::Update::check();
    is( $s->{state}, 'current' ) or diag explain $s;
    is( $s->{count}, 0 );
    ok( !BetterStack::WHM::Update::due(), 'not due right after a check' );
};

put( "$dir/dev/README", "v2\n" );
g( "$dir/dev", 'commit', '-q', '-am', 'Second change' );
put( "$dir/dev/README", "v3\n" );
g( "$dir/dev", 'commit', '-q', '-am', 'Third change' );
g( "$dir/dev", 'push', '-q', 'origin', 'main' );

subtest 'new commits are found' => sub {
    my $s = BetterStack::WHM::Update::check();
    is( $s->{state}, 'available' );
    is( $s->{count}, 2 );
    is_deeply( [ map { $_->[2] } @{ $s->{commits} } ], [ 'Third change', 'Second change' ], 'newest first' );
    is( out( "$dir/src", 'rev-parse HEAD' ), BetterStack::WHM::Update::install_info()->{commit}, 'the clone itself is not changed by a check' );
};

subtest 'unsafe clone is refused' => sub {
    chmod 0666, "$dir/src/.git/config";
    my $s = BetterStack::WHM::Update::check();
    is( $s->{state}, 'error' );
    is( $s->{reason}[0], 'upd.unsafe' );
    chmod 0644, "$dir/src/.git/config";
};

subtest 'a check never touches the clone' => sub {
    put( "$dir/src/README", "local edit\n" );
    my $head = out( "$dir/src", 'rev-parse HEAD' );
    is( BetterStack::WHM::Update::check()->{state}, 'available' );
    is( out( "$dir/src", 'rev-parse HEAD' ), $head, 'HEAD unchanged' );
    is( do { open my $fh, '<', "$dir/src/README"; local $/; <$fh> }, "local edit\n", 'working tree unchanged' );
    ok( !BetterStack::WHM::Update->can('update'), 'there is no update function at all' );
};

subtest 'installed version moves on' => sub {
    BetterStack::WHM::Util::write_json( $info_file, { source => "$dir/src", commit => out( "$dir/dev", 'rev-parse HEAD' ), upstream => 'origin/main', at => time } );
    ok( !BetterStack::WHM::Update::status(), 'status of the old version no longer applies' );
    is( BetterStack::WHM::Update::check()->{state}, 'current' );
};

subtest 'fetch failure is reported' => sub {
    g( "$dir/src", 'remote', 'set-url', 'origin', "$dir/gone.git" );
    my $s = BetterStack::WHM::Update::check();
    is( $s->{state}, 'error' );
    is( $s->{reason}[0], 'upd.fetch_failed' );
    unlike( BetterStack::WHM::I18N::render_msg( $s->{reason}, 'en' ), qr/%s/ );
};

done_testing;
