package BetterStack::WHM::Util;

# Shared helpers: paths, JSON files, logging, HTTP and command execution.

use strict;
use warnings;

use Exporter 'import';
use Fcntl qw(:flock O_WRONLY O_CREAT O_EXCL O_APPEND O_NOFOLLOW);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp ();
use HTTP::Tiny ();
use IO::Handle ();
use JSON::PP ();
use POSIX ();

our $VERSION = '1.0.0';

our @EXPORT_OK = qw(
  etc_dir var_dir log_file
  read_json read_json_safe write_json json_encode json_decode
  logmsg run_cmd http_request hostname_fqdn
);

# Fixed locations. Deliberately not overridable through the environment:
# this code runs as root and must not trust %ENV. Tests change these variables.
our $ETC_DIR  = '/etc/betterstack-whm';
our $VAR_DIR  = '/var/lib/betterstack-whm';
our $LOG_FILE = '/var/log/betterstack-whm.log';

# Language of log lines (set by the engine from the configuration).
our $LOG_LANG = 'nl';

sub etc_dir  { $ETC_DIR }
sub var_dir  { $VAR_DIR }
sub log_file { $LOG_FILE }

# Minimal, trusted environment for every child process.
our %CHILD_ENV = (
    PATH   => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    LC_ALL => 'C',
    LANG   => 'C',
    HOME   => '/root',
);

my $JSON = JSON::PP->new->utf8->canonical->pretty;

sub json_encode { $JSON->encode( $_[0] ) }

sub json_decode {
    my ($text) = @_;
    return undef unless defined $text && length $text;
    my $data = eval { JSON::PP->new->utf8->decode($text) };
    return $data;
}

sub read_json {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return json_decode($text);
}

# Like read_json, but falls back to the backup copy when the file is
# missing, empty or damaged (e.g. after a hard reset).
sub read_json_safe {
    my ($path) = @_;
    for my $p ( $path, "$path.bak" ) {
        my $d = read_json($p);
        return $d if ref $d eq 'HASH';
    }
    return undef;
}

sub _write_atomic {
    my ( $path, $content, $mode ) = @_;
    my $tmp = "$path.tmp.$$";
    unlink $tmp;
    sysopen( my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, $mode ) or die "Cannot write $tmp: $!\n";
    print {$fh} $content;
    # Flush to disk before the rename: without this a hard reset can leave an
    # empty file behind (XFS/ext4 delayed allocation).
    $fh->flush;
    $fh->sync or die "Cannot flush $tmp to disk: $!\n";
    close $fh or die "Cannot close $tmp: $!\n";
    chmod $mode, $tmp;
    rename $tmp, $path or die "Cannot rename $tmp: $!\n";
    if ( open my $dh, '<', dirname($path) ) { $dh->sync; close $dh }    # persist the rename
}

# Atomic, durable write with restrictive permissions (config holds the API
# token), plus a backup copy that read_json_safe can fall back to.
sub write_json {
    my ( $path, $data, $mode ) = @_;
    $mode //= 0600;
    make_path( dirname($path), { mode => 0700 } );
    my $content = json_encode($data);
    _write_atomic( $path, $content, $mode );
    _write_atomic( "$path.bak", $content, $mode );
    return 1;
}

sub logmsg {
    my ( $level, $msg ) = @_;
    if ( ref $msg ) {
        require BetterStack::WHM::I18N;
        $msg = BetterStack::WHM::I18N::render_msg( $msg, $LOG_LANG );
    }
    my $file = log_file();
    if ( -f $file && -s _ > 5 * 1024 * 1024 ) {
        rename $file, "$file.1";
    }

    # 0600: the log can contain customer domain names and must not be
    # readable by account users. O_NOFOLLOW refuses a planted symlink.
    sysopen( my $fh, $file, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600 ) or return;
    chmod 0600, $fh;
    flock $fh, LOCK_EX;
    $msg =~ s/[\r\n]+/ | /g;    # one entry per line, no forged entries
    utf8::encode($msg) if utf8::is_utf8($msg);    # log file is UTF-8 bytes
    printf {$fh} "%s [%s] %s\n", POSIX::strftime( '%Y-%m-%d %H:%M:%S', localtime ), uc $level, $msg;
    close $fh;
    print STDERR "[$level] $msg\n" if $ENV{BSWHM_VERBOSE};
}

# Run a command (list form, never a shell) with a timeout, a clean
# environment and stdin from /dev/null. Commands must be absolute paths.
# Returns (exit_code, combined_output). exit_code is -1 on timeout/exec failure.
sub run_cmd {
    my ( $timeout, @cmd ) = @_;
    die "run_cmd: not an absolute path: $cmd[0]\n" unless $cmd[0] =~ m{^/};
    my $output = '';
    my ( $pid, $fh );
    my $outer = alarm 0;    # keep an enclosing timeout intact
    my $start = time;
    my $capped = $outer && $outer <= $timeout;
    $timeout = $outer if $capped;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        $pid = open( $fh, '-|' ) // die "fork: $!\n";
        if ( !$pid ) {
            setpgrp( 0, 0 );    # own process group, so a timeout can kill grandchildren too
            %ENV = %CHILD_ENV;
            open STDIN, '<', '/dev/null';
            open STDERR, '>&', \*STDOUT;
            { no warnings 'exec'; exec {$cmd[0]} @cmd; }
            POSIX::_exit(127);
        }
        local $/;
        $output = <$fh> // '';
        close $fh;
        alarm 0;
        1;
    };
    alarm 0;
    my $status = $?;
    if ( !$ok ) {
        # Kill before closing: closing a pipe waits for the child to exit.
        kill 'KILL', -$pid, $pid if $pid;
        close $fh if $fh;
    }
    if ($outer) {
        my $left = $outer - ( time - $start );
        ( ( $capped && !$ok ) || $left <= 0 ) ? kill( 'ALRM', $$ ) : alarm $left;
    }
    return ( -1, $output ) unless $ok;
    my $code = $status == -1 ? -1 : ( $status >> 8 );
    return ( $code, $output );
}

# Minimal HTTP client. Uses HTTP::Tiny when it can do TLS, curl otherwise.
# Returns hashref { status, content, success, error }.
sub http_request {
    my ( $method, $url, %opt ) = @_;
    my $headers = $opt{headers} || {};
    my $body    = $opt{body};
    my $timeout = $opt{timeout} || 15;

    my $ua_name = "statusbridge-whm/$VERSION";

    # Only HTTPS, and nothing that could smuggle extra lines into a request
    # or into the curl config below.
    return { status => 599, content => '', success => 0, error => 'Invalid URL' }
      unless $url =~ m{^https://[A-Za-z0-9.-]+(?::\d+)?(?:/[\x21-\x7e]*)?\z} && $url !~ /["\\]/;
    for ( $method, %$headers ) {
        return { status => 599, content => '', success => 0, error => 'Invalid header' } if /[\r\n]/;
    }

    if ( HTTP::Tiny->can_ssl ) {
        # No redirects: they would forward the Authorization header to another host.
        my $ua = HTTP::Tiny->new( timeout => $timeout, agent => $ua_name, verify_SSL => 1, max_redirect => 0 );
        my $res = $ua->request( $method, $url, { headers => $headers, ( defined $body ? ( content => $body ) : () ) } );
        return {
            status  => $res->{status},
            content => $res->{content},
            success => $res->{success} ? 1 : 0,
            error   => $res->{success} ? '' : ( $res->{status} == 599 ? $res->{content} : "HTTP $res->{status} $res->{reason}" ),
        };
    }

    # curl fallback; secrets go through a 0600 config file instead of argv.
    my $cfg = File::Temp->new( UNLINK => 1 );
    chmod 0600, $cfg->filename;
    my $q = sub { my $s = shift; $s =~ s/(["\\])/\\$1/g; qq{"$s"} };
    print {$cfg} "url = " . $q->($url) . "\n";
    print {$cfg} "request = " . $q->($method) . "\n";
    print {$cfg} "user-agent = " . $q->($ua_name) . "\n";
    print {$cfg} "header = " . $q->("$_: $headers->{$_}") . "\n" for sort keys %$headers;
    my $bodyfile;
    if ( defined $body ) {
        $bodyfile = File::Temp->new( UNLINK => 1 );
        print {$bodyfile} $body;
        close $bodyfile;
        print {$cfg} "data-binary = " . $q->( '@' . $bodyfile->filename ) . "\n";
    }
    close $cfg;
    my ($curl) = grep { -x } qw(/usr/bin/curl /bin/curl);
    return { status => 599, content => '', success => 0, error => 'No TLS support and no curl found' } unless $curl;
    my ( $code, $out ) = run_cmd( $timeout + 5, $curl, '-q', '-sS', '--proto', '=https', '--max-time', $timeout, '-w', "\n%{http_code}", '-K', $cfg->filename );
    my ($status) = $out =~ /(\d{3})\s*\z/;
    $out =~ s/\n?\d{3}\s*\z//;
    $status //= 599;
    my $success = ( $code == 0 && $status >= 200 && $status < 300 ) ? 1 : 0;
    return { status => $status, content => $out, success => $success, error => $success ? '' : "HTTP $status $out" };
}

sub hostname_fqdn {
    my ($bin) = grep { -x } qw(/usr/bin/hostname /bin/hostname);
    if ($bin) {
        my ( $code, $out ) = run_cmd( 5, $bin, '-f' );
        chomp $out if defined $out;
        return $out if $code == 0 && $out && $out =~ /^[A-Za-z0-9.-]+$/;
    }
    return ( POSIX::uname() )[1];
}

1;
