package BetterStack::WHM::Update;

# Update check for installs from a git clone.
#
# install.sh records which clone (and commit) the plugin was installed from.
# check() fetches that clone's upstream branch and lists the commits that are
# not installed yet. It never changes the clone or installs anything: the
# update itself is done by root in a terminal, after reviewing the changes.
# Git runs with the clone's own remote and credentials, so a private
# repository works as long as `git pull` works in that clone.

use strict;
use warnings;

use BetterStack::WHM::Util qw(run_cmd var_dir read_json write_json);

our $INFO_FILE;            # default: var_dir()/install.json, written by install.sh
our $STATUS_FILE;          # default: var_dir()/update.json
our $CHECK_EVERY = 86400;
our @GIT = qw(/usr/bin/git /usr/local/bin/git /usr/local/cpanel/3rdparty/bin/git);

sub info_file   { $INFO_FILE   // var_dir() . '/install.json' }
sub status_file { $STATUS_FILE // var_dir() . '/update.json' }

sub git_bin {
    for (@GIT) { return $_ if -x $_ && !-d _ }
    return undef;
}

# Where and what was installed: { source, commit, upstream, at } or undef.
sub install_info {
    my $i = read_json( info_file() );
    return ref $i eq 'HASH' && ( $i->{source} // '' ) =~ m{^/} ? $i : undef;
}

# Latest check result, or undef when there is none for the installed commit.
sub status {
    my $s    = read_json( status_file() );
    my $info = install_info();
    return undef unless ref $s eq 'HASH';
    return undef if $info && ( $s->{installed} // '' ) ne ( $info->{commit} // '' );
    return $s;
}

sub due {
    my $s = status();
    return !$s || time - ( $s->{at} // 0 ) >= $CHECK_EVERY;
}

# The update command for a terminal.
sub command {
    my ($info) = @_;
    my $src = $info ? $info->{source} : '/root/whm-betterstackbridge';
    $src = "'$src'" if $src =~ /[^\w\/.-]/;
    return "cd $src && git pull && ./install.sh";
}

# Git runs as root inside the clone, so the clone and its git config must be
# root's and not writable by anyone else. Otherwise a local user could make
# root run code through .git/config.
sub _untrusted {
    my ($src) = @_;
    for my $p ( $src, "$src/.git", "$src/.git/config" ) {
        my @s = lstat $p or return [ 'upd.missing', $p ];
        return [ 'upd.unsafe', $p ] if -l _ || $s[4] != $> || $s[2] & 022;
    }
    return undef;
}

sub _git {
    my ( $src, $timeout, @args ) = @_;
    my $git = git_bin() or return ( -1, 'git not found' );
    # HOME for the clone's stored credentials and ssh keys; never prompt.
    local %BetterStack::WHM::Util::CHILD_ENV = (
        %BetterStack::WHM::Util::CHILD_ENV,
        HOME                => ( getpwuid $> )[7] // '/root',
        GIT_TERMINAL_PROMPT => 0,
        GIT_ASKPASS         => '/bin/false',
        SSH_ASKPASS         => '/bin/false',
        GIT_SSH_COMMAND     => 'ssh -o BatchMode=yes',
    );
    my ( $code, $out ) = run_cmd( $timeout, $git, '-C', $src, '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', @args );
    $out =~ s/\s+\z//;
    return ( $code, $out );
}

sub _last_line { my @l = grep { /\S/ } split /\n/, $_[0] // ''; return $l[-1] // '' }

# Fetches the upstream branch and stores what is new. Returns the status.
sub check {
    my $info = install_info();
    my %s    = ( at => time, installed => $info ? $info->{commit} // '' : '' );
    my $save = sub { eval { write_json( status_file(), \%s ) }; return \%s };

    if ( !$info ) { $s{state} = 'unknown'; $s{reason} = ['upd.no_info']; return $save->() }
    my $src = $info->{source};
    if ( my $bad = _untrusted($src) ) { $s{state} = 'error'; $s{reason} = $bad; return $save->() }
    my ( $remote, $branch ) = ( $info->{upstream} // '' ) =~ m{^([\w.-]+)/([\w./-]+)\z};
    if ( !$remote || !$info->{commit} ) { $s{state} = 'unknown'; $s{reason} = ['upd.no_upstream']; return $save->() }

    my ( $code, $out ) = _git( $src, 120, 'fetch', '--quiet', $remote, $branch );
    if ($code) { $s{state} = 'error'; $s{reason} = [ 'upd.fetch_failed', _last_line($out) ]; return $save->() }

    my $up = "$remote/$branch";
    ( $code, my $latest ) = _git( $src, 30, 'rev-parse', '--verify', '--quiet', "$up^{commit}" );
    if ( $code || $latest !~ /^[0-9a-f]{40}\z/ ) { $s{state} = 'error'; $s{reason} = [ 'upd.fetch_failed', _last_line($latest) ]; return $save->() }
    $s{latest} = $latest;

    ( $code, $out ) = _git( $src, 30, 'log', '--no-merges', '--format=%h%x09%ct%x09%s', "$info->{commit}..$up" );
    if ($code) {
        # The installed commit is not in the history (rewritten branch): only say whether it differs.
        $s{state} = $latest eq $info->{commit} ? 'current' : 'available';
        $s{commits} = [];
        return $save->();
    }
    my @commits = map { [ split /\t/, $_, 3 ] } grep { /\S/ } split /\n/, $out;
    $s{count}   = @commits;
    $s{commits} = [ @commits[ 0 .. ( $#commits < 29 ? $#commits : 29 ) ] ];
    $s{state}   = $latest eq $info->{commit} ? 'current' : 'available';
    return $save->();
}

1;
