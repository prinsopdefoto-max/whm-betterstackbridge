#!/usr/local/cpanel/3rdparty/bin/perl
#WHMADDON:betterstack:StatusBridge
#ACLS:all
# StatusBridge for WHM - configuration and overview page.

use strict;
use warnings;
use utf8;

use lib '/usr/local/cpanel', '/opt/betterstack-whm/lib';

use Digest::SHA ();
use Encode ();
use POSIX ();

use BetterStack::WHM::API ();
use BetterStack::WHM::Checks ();
use BetterStack::WHM::Config ();
use BetterStack::WHM::Engine ();
use BetterStack::WHM::I18N qw(T render render_msg);
use BetterStack::WHM::UIStrings ();
use BetterStack::WHM::Update ();
use BetterStack::WHM::Util qw(log_file var_dir read_json write_json);

my @TABS = qw(overview items checks settings log);

# Root only: the page stores an API token and runs system commands as root.
# WHM runs addon CGIs for every logged-in WHM user (resellers too), so this
# check is what keeps them out. It fails closed: no ACL module, no access.
my $is_root = eval {
    require Whostmgr::ACLS;
    Whostmgr::ACLS::init_acls();
    Whostmgr::ACLS::hasroot() ? 1 : 0;
} || 0;

$BetterStack::WHM::I18N::LANG = ui_lang( BetterStack::WHM::Config::load() );

print "Content-Type: text/html; charset=utf-8\r\n";
print "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: same-origin\r\nX-Frame-Options: SAMEORIGIN\r\n\r\n";
if ( !$is_root ) {
    print Encode::encode_utf8( '<p>' . h( T('ui.denied') ) . '</p>' );
    exit;
}

my %form = parse_form();
my @messages;    # [ type, text ]
my $action = $form{action} // '';
my $csrf   = csrf_token();
my $tab    = ( grep { $_ eq ( $form{tab} // '' ) } @TABS ) ? $form{tab} : '';

if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' && $action ) {
    # Own CSRF token on top of WHM's cpsess token, so state-changing actions stay
    # protected even if security tokens are ever disabled in Tweak Settings.
    if ( !length( $form{csrf} // '' ) || $form{csrf} ne $csrf ) {
        push @messages, [ 'error', T('ui.csrf') ];
    }
    else {
        my $ok = eval { handle_action( $action, \%form ); 1 };
        push @messages, [ 'error', T( 'ui.action_failed', ref $@ ? render_msg($@) : $@ ) ] unless $ok;
    }
}

my $cfg = BetterStack::WHM::Config::load();
my $st  = BetterStack::WHM::Config::load_state();
$BetterStack::WHM::I18N::LANG = ui_lang($cfg);
$tab ||= BetterStack::WHM::Config::is_configured($cfg) ? 'overview' : 'settings';

my $html = render_page();

my $headed = eval {
    require Whostmgr::HTMLInterface;
    Whostmgr::HTMLInterface::defheader( 'StatusBridge', '', '/cgi/betterstack/index.cgi' );
    1;
};
print "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>StatusBridge</title></head><body>"
  unless $headed;
print Encode::encode_utf8($html);
if   ($headed) { eval { Whostmgr::HTMLInterface::deffooter(); 1 } }
else           { print "</body></html>" }
exit;

# ====================================================================== language

# WHM page language: setting, else the WHM user's locale, else the browser,
# else the language of the status page.
sub ui_lang {
    my ($cfg) = @_;
    return $cfg->{ui_lang} if BetterStack::WHM::I18N::valid( $cfg->{ui_lang} );
    my $whm = eval { require Cpanel::Locale; Cpanel::Locale->get_handle->get_language_tag };
    return BetterStack::WHM::I18N::detect( $whm, $ENV{HTTP_ACCEPT_LANGUAGE} ) // BetterStack::WHM::Checks::public_lang($cfg);
}

# ====================================================================== actions

sub handle_action {
    my ( $action, $f ) = @_;
    my $cfg = BetterStack::WHM::Config::load();

    if ( $action eq 'save_settings' ) {
        $cfg->{api_token} = clean_text( $f->{api_token}, 200 ) if length( $f->{api_token} // '' );
        $cfg->{api_token} = '' if $f->{clear_token};
        for my $k (qw(api_base team_name status_page_id server_label)) {
            next unless defined $f->{$k};
            $cfg->{$k} = clean_text( $f->{$k}, 200 );
        }
        $cfg->{api_base} = 'https://incidents.betterstack.com/api/v2' unless $cfg->{api_base} =~ m{^https://[\w.-]+(/[\w./-]*)?$};
        $cfg->{status_page_id} = '' unless $cfg->{status_page_id} =~ /^\d*$/;
        $cfg->{section_mode} = ( $f->{section_mode} // '' ) eq 'category' ? 'category' : 'single';
        $cfg->{$_} = $f->{$_} ? 1 : 0 for qw(alert_email alert_sms alert_call alert_push publish_details delete_removed);
        $cfg->{grace_pct}        = num( $f->{grace_pct},        $cfg->{grace_pct},        0,  500 );
        $cfg->{details_interval} = num( $f->{details_interval}, $cfg->{details_interval}, 60, 86400 );
        $cfg->{ui_lang}     = BetterStack::WHM::I18N::valid( $f->{ui_lang} )     ? $f->{ui_lang}     : 'auto' if defined $f->{ui_lang};
        $cfg->{public_lang} = BetterStack::WHM::I18N::valid( $f->{public_lang} ) ? $f->{public_lang} : $cfg->{public_lang};
        BetterStack::WHM::Config::save($cfg);
        $BetterStack::WHM::I18N::LANG = ui_lang($cfg);
        push @messages, [ 'success', T('ui.saved_settings') ];
        sync_now();
    }
    elsif ( $action eq 'set_lang' ) {
        $cfg->{ui_lang} = BetterStack::WHM::I18N::valid( $f->{ui_lang} ) ? $f->{ui_lang} : 'auto';
        BetterStack::WHM::Config::save($cfg);
        $BetterStack::WHM::I18N::LANG = ui_lang($cfg);
    }
    elsif ( $action eq 'save_checks' ) {
        for my $type (@BetterStack::WHM::Checks::TYPE_ORDER) {
            my $def = $BetterStack::WHM::Checks::TYPES{$type};
            my $c   = $cfg->{checks}{$type} ||= {};
            $c->{enabled}         = $f->{"chk_${type}_enabled"} ? 1 : 0;
            $c->{publish_details} = $f->{"chk_${type}_publish"} ? 1 : 0;
            $c->{interval}        = int num( $f->{"chk_${type}_interval"}, $def->{interval}, 60, 86400 );
            for my $p ( keys %{ $def->{params} } ) {
                if ( $BetterStack::WHM::Checks::BOOL_PARAMS{$p} ) { $c->{$p} = $f->{"chk_${type}_$p"} ? 1 : 0; next }
                my $v = $f->{"chk_${type}_$p"};
                next unless defined $v;
                if ( $def->{params}{$p} =~ /^[\d.]+$/ ) {
                    $c->{$p} = num( $v, $def->{params}{$p}, 0, 1e9 );
                }
                else {
                    $v =~ s/[^\w.,:\s-]//g;
                    $c->{$p} = substr( $v, 0, 500 );
                }
            }
        }
        BetterStack::WHM::Config::save($cfg);
        push @messages, [ 'success', T('ui.saved_checks') ];
        sync_now();
    }
    elsif ( $action eq 'save_items' ) {
        my %known = map { $_->{id} => $_ } @{ BetterStack::WHM::Checks::discover_all($cfg) };
        for my $i ( 0 .. 500 ) {
            my $id = $f->{"item_id_$i"} // last;
            my $inst = $known{$id} or next;
            my %ov;
            # Only store what differs from the default, so new defaults keep applying.
            my $enabled = $f->{"item_enabled_$i"} ? 1 : 0;
            $ov{enabled}     = $enabled if $enabled != ( $inst->{default_enabled} // 1 );
            $ov{own}         = 1 if $f->{"item_own_$i"};
            $ov{public_name} = clean_text( $f->{"item_name_$i"}, 120 );
            delete $ov{public_name} unless length $ov{public_name};
            if (%ov) { $cfg->{instances}{$id} = \%ov }
            else     { delete $cfg->{instances}{$id} }
        }
        for my $c (@BetterStack::WHM::Checks::CATEGORIES) {
            my $v = clean_text( $f->{"group_name_$c->[0]"}, 120 );
            if   ( length $v ) { $cfg->{group_names}{ $c->[0] } = $v }
            else               { delete $cfg->{group_names}{ $c->[0] } }
        }
        BetterStack::WHM::Config::save($cfg);
        push @messages, [ 'success', T('ui.saved_items') ];
        sync_now();
    }
    elsif ( $action =~ /^preview(_type)?:(.{1,300})\z/s ) {
        # Test checks that are switched off; nothing is reported to Better Stack.
        my ( $by_type, $what ) = ( $1, $2 );
        die "invalid check\n" if $by_type && !$BetterStack::WHM::Checks::TYPES{$what};
        my $r = BetterStack::WHM::Engine::preview( $by_type ? ( type => $what ) : ( only => $what ) );
        report( $r, T( 'ui.preview_done', $r->{ran} // 0 ) );
    }
    elsif ( $action eq 'update_check' ) {
        my $s = BetterStack::WHM::Update::check();
        push @messages, $s->{state} eq 'current' ? [ 'success', T('upd.current') ]
          : $s->{state} eq 'available' ? [ 'info', T( 'upd.available', $s->{count} // 1 ) ]
          :                              [ 'error', render_msg( $s->{reason} ) ];
    }
    elsif ( $action eq 'run' ) {
        my $r = BetterStack::WHM::Engine::run( force => 1 );
        report( $r, T( 'ui.ran', $r->{ran} // 0 ) );
    }
    elsif ( $action eq 'sync' ) {
        sync_now();
    }
    elsif ( $action eq 'test' ) {
        # Test the token in the form if one was entered, else the saved one.
        my %c = %$cfg;
        $c{api_token} = clean_text( $f->{api_token}, 200 ) if length( $f->{api_token} // '' );
        my ( $pages, $err ) = BetterStack::WHM::API->from_config( \%c )->status_pages;
        push @messages, $err ? [ 'error', T( 'ui.test_failed', $err ) ] : [ 'success', T( 'ui.test_ok', scalar @$pages ) ];
    }
    elsif ( $action eq 'cleanup' && ( $f->{confirm} // '' ) =~ /^\s*(?:VERWIJDER|DELETE|LÖSCHEN|LOSCHEN)\s*$/i ) {
        my $r = BetterStack::WHM::Engine::with_lock(
            sub {
                my $st   = BetterStack::WHM::Config::load_state();
                my $errs = BetterStack::WHM::Engine::cleanup( $cfg, $st );
                BetterStack::WHM::Config::save_state($st);
                return { ok => !@$errs, errors => $errs };
            },
            wait => 1,
        );
        report( $r, T('ui.cleaned') );
    }
    elsif ( $action eq 'cleanup' ) {
        push @messages, [ 'error', T( 'ui.confirm_needed', T('ui.confirm_word') ) ];
    }
}

# Per-user token derived from a random secret stored root-only on disk.
sub csrf_token {
    my $file = var_dir() . '/csrf.secret';
    my $secret;
    if ( open my $fh, '<', $file ) { local $/; $secret = <$fh>; close $fh }
    if ( !$secret || length $secret < 32 ) {
        open my $rnd, '<:raw', '/dev/urandom' or die "/dev/urandom\n";
        read $rnd, my $bytes, 32;
        close $rnd;
        $secret = unpack 'H*', $bytes;
        require File::Path;
        File::Path::make_path( var_dir(), { mode => 0700 } );
        require Fcntl;
        unlink $file;
        sysopen( my $out, $file, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL() | Fcntl::O_NOFOLLOW(), 0600 ) or die "csrf.secret\n";
        print {$out} $secret;
        close $out;
    }
    return Digest::SHA::hmac_sha256_hex( $ENV{REMOTE_USER} // '', $secret );
}

# Free text that ends up in names: no control characters, bounded length.
sub clean_text {
    my ( $v, $max ) = @_;
    $v //= '';
    $v =~ s/[\x00-\x1f\x7f]//g;
    $v =~ s/^\s+|\s+$//g;
    return substr( $v, 0, $max );
}

sub sync_now {
    my $cfg = BetterStack::WHM::Config::load();
    return push @messages, [ 'info', T('ui.not_configured_hint') ] unless BetterStack::WHM::Config::is_configured($cfg);
    my $r = BetterStack::WHM::Engine::run( sync => 1, force => 1, wait => 1 );
    report( $r, T('ui.synced') );
}

sub report {
    my ( $r, $okmsg ) = @_;
    if ( $r->{error} ) { push @messages, [ 'error', render_msg( $r->{error} ) ]; return }
    push @messages, [ 'error', render_msg($_) ] for @{ $r->{errors} || [] };
    push @messages, [ 'success', $okmsg ] if $r->{ok};
}

sub num {
    my ( $v, $default, $min, $max ) = @_;
    return $default unless defined $v && $v =~ /^\s*(\d+(?:[.,]\d+)?)\s*$/;
    ( my $n = $1 ) =~ tr/,/./;
    $n = $min if $n < $min;
    $n = $max if $n > $max;
    return $n + 0;
}

sub parse_form {
    my $data = $ENV{QUERY_STRING} // '';
    if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' ) {
        my $len = $ENV{CONTENT_LENGTH} // 0;
        $len = 1_000_000 if $len > 1_000_000;
        my $body = '';
        read( STDIN, $body, $len ) if $len;
        $data = $body;
    }
    my %f;
    for my $pair ( split /[&;]/, $data ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k;
        for ( $k, $v ) { next unless defined; tr/+/ /; s/%([0-9A-Fa-f]{2})/chr hex $1/eg }
        $f{ Encode::decode( 'UTF-8', $k ) } = Encode::decode( 'UTF-8', $v // '' );
    }
    return %f;
}

# ====================================================================== data

# Status pages of the account, cached for 10 minutes (per token).
sub status_pages {
    return ( undef, undef ) unless length $cfg->{api_token};
    my $file  = var_dir() . '/pages.json';
    my $key   = Digest::SHA::sha256_hex( $cfg->{api_token} . '|' . $cfg->{api_base} );
    my $cache = read_json($file);
    if ( $cache && ( $cache->{key} // '' ) eq $key && time - ( $cache->{at} // 0 ) < 600 && ref $cache->{pages} eq 'ARRAY' ) {
        return ( $cache->{pages}, undef );
    }
    my ( $pages, $err ) = BetterStack::WHM::API->from_config($cfg)->status_pages;
    return ( undef, $err ) if $err;
    my @slim = map {
        my $a = $_->{attributes} || {};
        { id => "$_->{id}", name => $a->{company_name} // '', domain => $a->{custom_domain} || ( length( $a->{subdomain} // '' ) ? "$a->{subdomain}.betteruptime.com" : '' ) }
    } @$pages;
    eval { write_json( $file, { key => $key, at => time, pages => \@slim } ) };
    return ( \@slim, undef );
}

# ====================================================================== render helpers

sub h {
    my $s = shift // '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
}

sub th { h( T(@_) ) }    # translated + escaped

sub csrf_field { '<input type="hidden" name="csrf" value="' . h($csrf) . '">' }

sub form_open {
    my ( $action, $tab, $class ) = @_;
    return '<form method="post" action="index.cgi"' . ( $class ? qq{ class="$class"} : '' ) . '>' . csrf_field()
      . ( $action ? '<input type="hidden" name="action" value="' . h($action) . '">' : '' )
      . '<input type="hidden" name="tab" value="' . h($tab) . '">';
}

# Icon paths (a sub, so it works regardless of where in the file it is called from).
sub icon_paths {
    return {
        play     => '<path d="M7 5.5v13l11-6.5z"/>',
        refresh  => '<path d="M20 11a8 8 0 0 0-14.3-4.9L4 8"/><path d="M4 4v4h4"/><path d="M4 13a8 8 0 0 0 14.3 4.9L20 16"/><path d="M20 20v-4h-4"/>',
        external => '<path d="M14 4h6v6"/><path d="M20 4l-9 9"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
        grid     => '<rect x="4" y="4" width="6.5" height="6.5" rx="1"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1"/>',
        list     => '<path d="M9 6.5h11M9 12h11M9 17.5h11"/><path d="M4.5 6.5h1M4.5 12h1M4.5 17.5h1"/>',
        sliders  => '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
        cog      => '<circle cx="12" cy="12" r="2.75"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1.08-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1.08 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
        file     => '<path d="M14 3.5H7a1 1 0 0 0-1 1v15a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V7.5z"/><path d="M14 3.5v4h4M9 12h6M9 15.5h6"/>',
        check    => '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
        warn     => '<path d="M12 4l9 16H3z"/><path d="M12 10v4.5M12 17.2v.3"/>',
        fail     => '<circle cx="12" cy="12" r="8.5"/><path d="M9 9l6 6M15 9l-6 6"/>',
        info     => '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5M12 8v.3"/>',
        globe    => '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.4 2.3 3.5 5.2 3.5 8.5s-1.1 6.2-3.5 8.5c-2.4-2.3-3.5-5.2-3.5-8.5s1.1-6.2 3.5-8.5z"/>',
        lock     => '<rect x="5" y="10.5" width="14" height="9.5" rx="1"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/>',
        pulse    => '<path d="M3 12h4l2.5-6 5 12 2.5-6h4"/>',
        trash    => '<path d="M4.5 6.5h15M10 6.5V4.5h4v2M6.5 6.5l.8 13h9.4l.8-13M10 10.5v6M14 10.5v6"/>',
        plug     => '<path d="M9 3.5v4M15 3.5v4M6.5 7.5h11v3a5.5 5.5 0 0 1-11 0zM12 16v4.5"/>',
        clock    => '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
        chevron  => '<path d="M9 6l6 6-6 6"/>',
    };
}

sub icon {
    my ( $name, $cls ) = @_;
    return sprintf '<svg class="bsw-ic%s" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" shape-rendering="geometricPrecision" aria-hidden="true">%s</svg>',
      $cls ? " $cls" : '', icon_paths()->{$name} // '';
}

sub switch {
    my ( $name, $on, $label, %o ) = @_;
    return sprintf '<label class="bsw-switch%s"><input type="checkbox" name="%s" value="1"%s><span class="bsw-switch-track"></span>%s</label>',
      $o{small} ? ' bsw-switch-sm' : '', h($name), $on ? ' checked' : '', defined $label && length $label ? '<span class="bsw-switch-label">' . h($label) . '</span>' : '';
}

sub status_word {
    my ($s) = @_;
    return T('ui.st_ok') if $s eq 'ok';
    return T('ui.st_warn') if $s eq 'warn';
    return T('ui.st_fail') if $s eq 'fail';
    return T('ui.st_off') if $s eq 'off';
    return T('ui.st_none');
}

sub badge {
    my ($s) = @_;
    $s ||= 'none';
    my $ic = { ok => 'check', warn => 'warn', fail => 'fail' }->{$s};
    return sprintf '<span class="bsw-badge bsw-b-%s">%s%s</span>', h($s), $ic ? icon($ic) : '', h( status_word($s) );
}

sub dot { sprintf '<span class="bsw-dot bsw-d-%s" title="%s"></span>', h( $_[0] || 'none' ), h( status_word( $_[0] || 'none' ) ) }

sub status_label { sprintf '<span class="bsw-status bsw-s-%s"><span class="bsw-dot bsw-d-%s"></span>%s</span>', ( $_[0] || 'none' ) x 2, h( status_word( $_[0] || 'none' ) ) }

sub ago {
    my $t = shift or return T('ui.never');
    my $d = time - $t;
    return T('ui.just_now') if $d < 15;
    return T( 'ui.ago_s', $d ) if $d < 90;
    return T( 'ui.ago_m', int( $d / 60 ) ) if $d < 5400;
    return T( 'ui.ago_h', int( $d / 3600 ) ) if $d < 2 * 86400;
    return POSIX::strftime( '%d-%m-%Y %H:%M', localtime $t );
}

sub worst {
    my %rank = ( none => -1, ok => 0, warn => 1, fail => 2 );
    my $w = 'none';
    for (@_) { $w = $_ if defined $_ && ( $rank{$_} // -1 ) > $rank{$w} }
    return $w;
}

sub sync_errors {
    my $e = $st->{last_sync_error} or return ();
    return ref $e ? map { render_msg($_) } @$e : grep { length } split /\n/, $e;
}

# ====================================================================== page

sub render_page {
    my $configured = BetterStack::WHM::Config::is_configured($cfg);
    my $all        = BetterStack::WHM::Checks::discover_all($cfg);
    my @enabled    = grep { $_->{enabled} } @$all;
    my $units      = BetterStack::WHM::Engine::units( $cfg, \@enabled );
    my ( $pages, $perr ) = status_pages();
    my ($page) = grep { $_->{id} eq $cfg->{status_page_id} } @{ $pages || [] };

    my %count;
    $count{ ( $st->{results}{ $_->{id} } || {} )->{status} // 'none' }++ for @enabled;
    my $overall = worst( map { ( $st->{results}{ $_->{id} } || {} )->{status} } @enabled );
    my @serr    = sync_errors();
    my $upd     = BetterStack::WHM::Update::status();
    my $upd_available = $upd && $upd->{state} eq 'available';

    my $o = style() . '<div class="bsw bsw-nojs" id="bsw" data-start="' . h($tab) . '" data-busy="' . th('ui.preview_busy') . '" data-failed="' . th('ui.preview_failed') . '">';

    # ---- header
    my $conn = !$configured ? [ 'none', T('ui.conn_none') ] : @serr ? [ 'warn', T('ui.conn_errors') ] : [ 'ok', T('ui.conn_ok') ];
    $o .= '<header class="bsw-head"><div class="bsw-head-main">'
      . '<div class="bsw-logo">' . icon('pulse') . '</div><div><div class="bsw-eyebrow">StatusBridge &middot; Better Stack</div><h1 class="bsw-title">' . th('ui.product') . '</h1>'
      . '<div class="bsw-sub"><span class="bsw-mono">' . h( $cfg->{server_label} ) . '</span><span class="bsw-sep"></span>'
      . sprintf( '<span class="bsw-conn bsw-s-%s"><span class="bsw-dot bsw-d-%s"></span>%s</span>', $conn->[0], $conn->[0], h( $conn->[1] ) )
      . ( $page && $page->{domain} ? sprintf( '<span class="bsw-sep"></span><a class="bsw-link" href="https://%s" target="_blank" rel="noopener noreferrer">%s%s</a>', h( $page->{domain} ), h( $page->{domain} ), icon('external') ) : '' )
      . '</div></div></div><div class="bsw-head-actions">';
    $o .= form_open( 'set_lang', $tab, 'bsw-lang' ) . icon('globe') . '<select name="ui_lang" aria-label="' . th('ui.language') . '" onchange="this.form.submit()">'
      . sprintf( '<option value="auto"%s>%s</option>', ( BetterStack::WHM::I18N::valid( $cfg->{ui_lang} ) ? '' : ' selected' ), th('ui.lang_auto') )
      . join( '', map { sprintf '<option value="%s"%s>%s</option>', $_->[0], ( ( $cfg->{ui_lang} // '' ) eq $_->[0] ? ' selected' : '' ), h( $_->[1] ) } @BetterStack::WHM::I18N::LANGS )
      . '</select><noscript><button class="bsw-btn bsw-btn-sm">OK</button></noscript></form>';
    $o .= form_open( 'sync', $tab ) . '<button class="bsw-btn">' . icon('refresh') . th('ui.sync_now') . '</button></form>' if $configured;
    $o .= form_open( 'run', $tab ) . '<button class="bsw-btn bsw-btn-primary">' . icon('play') . th('ui.run_now') . '</button></form>';
    $o .= '</div></header>';

    # ---- tabs
    my %tabicon = ( overview => 'grid', items => 'list', checks => 'sliders', settings => 'cog', log => 'file' );
    $o .= '<nav class="bsw-tabs" role="tablist">';
    for my $t (@TABS) {
        my $extra = '';
        $extra = sprintf( '<span class="bsw-count bsw-c-fail">%d</span>', $count{fail} ) if $t eq 'overview' && $count{fail};
        $extra = '<span class="bsw-count bsw-c-warn">1</span>' if $t eq 'settings' && ( !$configured || @serr || $upd_available );
        $o .= sprintf '<a href="#%s" class="bsw-tab%s" data-tab="%s" role="tab">%s<span>%s</span>%s</a>', $t, ( $t eq $tab ? ' bsw-active' : '' ), $t, icon( $tabicon{$t} ),
          th("ui.tab_$t"), $extra;
    }
    $o .= '</nav>';

    # ---- flash messages
    for my $m (@messages) {
        my $ic = { success => 'check', error => 'fail', info => 'info' }->{ $m->[0] } // 'info';
        $o .= sprintf '<div class="bsw-flash bsw-f-%s">%s<div>%s</div></div>', h( $m->[0] ), icon($ic), h( $m->[1] );
    }

    if ($upd_available) {
        $o .= '<div class="bsw-flash bsw-f-info">' . icon('refresh') . '<div>' . th( 'upd.available', $upd->{count} // 1 )
          . ' <a href="#settings" data-goto="settings" class="bsw-link">' . th('upd.show') . '</a></div></div>';
    }

    $o .= panel_overview( $configured, $units, \%count, $overall, \@serr, $page );
    $o .= panel_items( $all, $units );
    $o .= panel_checks();
    $o .= panel_settings( $configured, $pages, $perr );
    $o .= panel_log();
    $o .= '<footer class="bsw-foot">StatusBridge for WHM · ' . h($BetterStack::WHM::Util::VERSION) . '</footer>';
    $o .= '</div>' . script();
    return $o;
}

sub panel_open {
    my ( $id, $title, $sub ) = @_;
    return sprintf '<section class="bsw-panel%s" id="bsw-%s" data-panel="%s"><div class="bsw-panel-head"><h2>%s</h2>%s</div>', ( $id eq $tab ? ' bsw-active' : '' ), $id, $id,
      h($title), $sub ? '<p>' . h($sub) . '</p>' : '';
}

# ---------------------------------------------------------------- overview

sub panel_overview {
    my ( $configured, $units, $count, $overall, $serr, $page ) = @_;
    my $o = panel_open( 'overview', T('ui.tab_overview') );

    if ( !$configured ) {
        my $has_token = length $cfg->{api_token};
        my @steps = (
            [ $has_token, T('ui.step_token'), T('ui.step_token_d') ],
            [ length $cfg->{status_page_id}, T('ui.step_page'), T('ui.step_page_d') ],
            [ 0, T('ui.step_done'), T('ui.step_done_d') ],
        );
        $o .= '<div class="bsw-card bsw-onboard"><h3>' . th('ui.onboard_title') . '</h3><p class="bsw-muted">' . th('ui.onboard_intro') . '</p><ol class="bsw-steps">';
        my $n = 0;
        for my $s (@steps) {
            $n++;
            $o .= sprintf '<li class="%s"><span class="bsw-step-n">%s</span><div><strong>%s</strong><span>%s</span></div></li>', $s->[0] ? 'bsw-done' : '',
              $s->[0] ? icon('check') : sprintf( '%02d', $n ), h( $s->[1] ), h( $s->[2] );
        }
        $o .= '</ol><a href="#settings" class="bsw-btn bsw-btn-primary" data-goto="settings">' . th('ui.to_settings') . icon('chevron') . '</a></div>';
    }

    if (@$serr) {
        $o .= '<div class="bsw-flash bsw-f-error">' . icon('warn') . '<div><strong>' . th('ui.sync_problems') . '</strong><ul>'
          . join( '', map { '<li>' . h($_) . '</li>' } @$serr ) . '</ul></div></div>';
    }

    # KPI tiles
    my $headline = { ok => T('ui.all_ok'), warn => T('ui.some_warn'), fail => T('ui.some_fail'), none => T('ui.no_data') }->{$overall};
    $o .= sprintf '<div class="bsw-summary"><div class="bsw-banner bsw-k-%s"><span class="bsw-banner-bar"></span><div><div class="bsw-label">%s</div><div class="bsw-banner-v">%s</div><div class="bsw-banner-l">%s</div></div></div>',
      $overall, th('ui.system_status'), h($headline), th( 'ui.last_check', ago( $st->{last_run} ) );
    $o .= kpi( $count->{ok}   // 0, T('ui.st_ok'),   'ok' );
    $o .= kpi( $count->{warn} // 0, T('ui.st_warn'), 'warn' );
    $o .= kpi( $count->{fail} // 0, T('ui.st_fail'), 'fail' );
    $o .= kpi( scalar @$units, T('ui.heartbeats'), 'hb' );
    $o .= '</div>';

    # one card per heartbeat (bundle or own item)
    $o .= '<div class="bsw-units">';
    for my $u (@$units) {
        my $it = $st->{items}{ $u->{key} } || {};
        my $us = worst( map { ( $st->{results}{ $_->{id} } || {} )->{status} } @{ $u->{members} } );
        my $link
          = !$configured       ? ''
          : $it->{ping_error}  ? '<span class="bsw-meta-warn" title="' . h( $it->{ping_error} ) . '">' . th('ui.ping_error') . '</span>'
          : $it->{resource_id} ? '<span class="bsw-meta-ok">' . icon('check') . th('ui.linked') . '</span>'
          :                      '<span>' . th('ui.not_linked') . '</span>';
        $o .= sprintf '<article class="bsw-card bsw-unit bsw-u-%s"><div class="bsw-unit-head"><div class="bsw-unit-title"><h3>%s</h3>'
          . '<div class="bsw-meta"><span>%s</span><span>%s</span>%s</div></div>%s</div><ul class="bsw-members">',
          $us, h( $u->{public_name} ), th( $u->{kind} eq 'cat' ? 'ui.kind_bundle' : 'ui.kind_own' ),
          h( BetterStack::WHM::Checks::category_label( $u->{category} ) ), $link, status_label($us);
        for my $inst ( @{ $u->{members} } ) {
            my $r    = $st->{results}{ $inst->{id} } || {};
            my $info = render( $r->{info} );
            $o .= sprintf '<li>%s<div class="bsw-m-body"><div class="bsw-m-name">%s</div><div class="bsw-m-detail">%s</div>%s</div><time class="bsw-num">%s</time></li>',
              dot( $r->{status} ), h( render_msg( $inst->{name_msg} ) ), h( render( $r->{detail} ) || T('ui.no_data') ),
              length $info ? '<div class="bsw-m-info" title="' . th('ui.private') . '">' . icon('lock') . h($info) . '</div>' : '', h( ago( $r->{at} ) );
        }
        $o .= '</ul>';
        if ( $it->{explanation_sent} ) {
            $o .= '<div class="bsw-unit-pub"><div class="bsw-label">' . th('ui.published_text') . '</div>' . h( $it->{explanation_sent} ) . '</div>';
        }
        $o .= '</article>';
    }
    $o .= '<p class="bsw-empty">' . th('ui.nothing_enabled') . '</p>' unless @$units;
    $o .= '</div></section>';
    return $o;
}

sub kpi {
    my ( $v, $label, $cls ) = @_;
    return sprintf '<div class="bsw-kpi bsw-k-%s"><div class="bsw-label">%s</div><div class="bsw-kpi-v">%s</div></div>', $cls, h($label), h($v);
}

# ---------------------------------------------------------------- items

sub panel_items {
    my ( $all, $units ) = @_;
    my $o = panel_open( 'items', T('ui.tab_items'), T('ui.items_intro') );
    $o .= form_open( 'save_items', 'items' );
    my $i = 0;
    for my $c (@BetterStack::WHM::Checks::CATEGORIES) {
        my $cat     = $c->[0];
        my @members = grep { $_->{category} eq $cat } @$all;
        next unless @members;
        my ($bundle) = grep { $_->{kind} eq 'cat' && $_->{category} eq $cat } @$units;
        $o .= sprintf '<div class="bsw-card bsw-cat"><div class="bsw-cat-head"><div><h3>%s</h3><span class="bsw-muted">%s</span></div>'
          . '<label class="bsw-field bsw-inline"><span>%s</span><input type="text" name="group_name_%s" value="%s" placeholder="%s" maxlength="120"></label></div>',
          h( BetterStack::WHM::Checks::category_label($cat) ),
          h( $bundle ? T( 'ui.bundle_members', scalar @{ $bundle->{members} } ) : T('ui.bundle_empty') ),
          th('ui.bundle_name'), h($cat), h( ( $cfg->{group_names} || {} )->{$cat} // '' ),
          h( BetterStack::WHM::Checks::category_label( $cat, BetterStack::WHM::Checks::public_lang($cfg) ) );
        $o .= '<div class="bsw-rows"><div class="bsw-row bsw-row-head"><span>' . th('ui.col_on') . '</span><span>' . th('ui.col_check') . '</span><span>'
          . th('ui.col_public') . '</span><span>' . th('ui.col_own') . '</span></div>';
        for my $inst (@members) {
            my $ov = $cfg->{instances}{ $inst->{id} } || {};
            my $r  = $st->{results}{ $inst->{id} } || {};
            my $pv = $inst->{enabled} ? '' : preview_line( $inst->{id} );
            $o .= sprintf '<div class="bsw-row%s"><span>%s<input type="hidden" name="item_id_%d" value="%s"></span>'
              . '<span class="bsw-row-name">%s<span><strong>%s</strong><code>%s</code>%s</span></span>'
              . '<span><input type="text" name="item_name_%d" value="%s" placeholder="%s" maxlength="120" aria-label="%s"></span>'
              . '<span>%s</span></div>',
              $inst->{enabled} ? '' : ' bsw-row-off', switch( "item_enabled_$i", $inst->{enabled}, '', small => 1 ), $i, h( $inst->{id} ),
              dot( $inst->{enabled} ? $r->{status} : 'off' ), h( render_msg( $inst->{name_msg} ) ), h( $inst->{id} ), $pv,
              $i, h( $ov->{public_name} // '' ), h( $inst->{name} ), th('ui.col_public'),
              switch( "item_own_$i", $ov->{own}, '', small => 1 );
            $i++;
        }
        $o .= '</div></div>';
    }
    $o .= savebar( T( 'ui.uses_heartbeats', scalar @$units ), T('ui.save_items') ) . '</form></section>';
    return $o;
}

# ---------------------------------------------------------------- preview

# The test button posts the form; with JavaScript the result is fetched in the
# background and only the element with id $target is replaced. Without
# JavaScript the page reloads and jumps back to that element.
sub preview_button {
    my ( $value, $target ) = @_;
    return sprintf '<button class="bsw-btn bsw-btn-sm" name="action" value="%s" formaction="index.cgi#%s" data-preview="%s" title="%s">%s<span>%s</span></button>', h($value), h($target),
      h($target), th('ui.preview_help'), icon('play'), th('ui.preview');
}

sub preview_anchor { my $id = shift; $id =~ s/[^\w-]/_/g; return "bsw-pv-$id" }

# Test result of a switched-off instance, below its name on the status page tab.
sub preview_line {
    my ($id) = @_;
    my $r      = ( $st->{preview} || {} )->{$id};
    my $anchor = preview_anchor($id);
    my $o      = '<span class="bsw-preview-line" id="' . h($anchor) . '">' . preview_button( "preview:$id", $anchor );
    if ($r) {
        my $info = render( $r->{info} );
        $o .= sprintf '<em>%s%s %s</em><time>%s</time>', dot( $r->{status} ), h( status_word( $r->{status} ) ), h( render( $r->{detail} ) ), h( ago( $r->{at} ) );
        $o .= '<em class="bsw-m-info">' . icon('lock') . h($info) . '</em>' if length $info;
    }
    return $o . '</span>';
}

# Test results of a switched-off check type, at the bottom of its card on the checks tab.
sub preview_block {
    my ($type) = @_;
    my $pv = $st->{preview} || {};
    my @ids = sort grep { ( $pv->{$_}{type} // '' ) eq $type } keys %$pv;
    my $anchor = preview_anchor("type-$type");
    my $o = '<div class="bsw-preview" id="' . h($anchor) . '"><div class="bsw-preview-head"><span class="bsw-muted">' . th('ui.preview_hint') . '</span>'
      . preview_button( "preview_type:$type", $anchor ) . '</div>';
    if (@ids) {
        $o .= '<ul class="bsw-members">';
        for my $id (@ids) {
            my $r    = $pv->{$id};
            my $info = render( $r->{info} );
            $o .= sprintf '<li>%s<div class="bsw-m-body"><div class="bsw-m-name">%s</div><div class="bsw-m-detail">%s</div>%s</div><time class="bsw-num">%s</time></li>',
              dot( $r->{status} ), h( render_msg( $r->{name_msg} // $id ) ), h( render( $r->{detail} ) || T('ui.no_data') ),
              length $info ? '<div class="bsw-m-info" title="' . th('ui.private') . '">' . icon('lock') . h($info) . '</div>' : '', h( ago( $r->{at} ) );
        }
        $o .= '</ul>';
    }
    return $o . '</div>';
}

sub savebar {
    my ( $note, $label ) = @_;
    return '<div class="bsw-savebar"><span>' . h($note) . '</span><button class="bsw-btn bsw-btn-primary">' . h($label) . '</button></div>';
}

# ---------------------------------------------------------------- checks

sub panel_checks {
    my $o = panel_open( 'checks', T('ui.tab_checks'), T('ui.checks_intro') );
    $o .= form_open( 'save_checks', 'checks' ) . '<div class="bsw-grid">';
    my @porder = qw(warn_per_cpu crit_per_cpu warn_pct crit_pct inode_warn_pct inode_crit_pct warn crit warn_days crit_days skip_suspended max_age_hours partial_is_fail lists extra_ips);
    my %prank  = map { $porder[$_] => $_ } 0 .. $#porder;
    for my $type (@BetterStack::WHM::Checks::TYPE_ORDER) {
        my $def = $BetterStack::WHM::Checks::TYPES{$type};
        my $ts  = BetterStack::WHM::Checks::type_settings( $cfg, $type );
        $o .= sprintf '<article class="bsw-card bsw-check%1$s"><div class="bsw-check-head"><div><div class="bsw-label">%4$s</div><h3>%3$s</h3></div>%2$s</div><p class="bsw-muted">%5$s</p><div class="bsw-fields">',
          $ts->{enabled} ? '' : ' bsw-check-off', switch( "chk_${type}_enabled", $ts->{enabled}, '' ),
          h( BetterStack::WHM::Checks::type_label($type) ), h( BetterStack::WHM::Checks::category_label( $def->{category} ) ), th("typedesc.$type");
        $o .= sprintf '<label class="bsw-field"><span>%s</span><div class="bsw-unit-input"><input type="number" min="60" step="60" name="chk_%s_interval" value="%d"><em>%s</em></div></label>',
          th('ui.interval'), $type, $ts->{interval}, th('ui.seconds');
        for my $p ( sort { ( $prank{$a} // 99 ) <=> ( $prank{$b} // 99 ) } keys %{ $def->{params} } ) {
            if ( $BetterStack::WHM::Checks::BOOL_PARAMS{$p} ) {
                $o .= '<div class="bsw-field bsw-wide">' . switch( "chk_${type}_$p", $ts->{$p}, T("param.$p"), small => 1 ) . '</div>';
                next;
            }
            my $wide = $def->{params}{$p} !~ /^[\d.]+$/;
            $o .= sprintf '<label class="bsw-field%s"><span>%s</span><input type="%s" name="chk_%s_%s" value="%s"%s></label>', $wide ? ' bsw-wide' : '',
              th("param.$p"), $wide ? 'text' : 'number', $type, $p, h( $ts->{$p} ), $wide ? '' : ' step="any" min="0"';
        }
        $o .= '<div class="bsw-field bsw-wide">' . switch( "chk_${type}_publish", $ts->{publish_details}, T('ui.publish_details'), small => 1 ) . '</div>';
        $o .= '</div>';
        $o .= preview_block($type) unless $ts->{enabled};
        $o .= '</article>';
    }
    $o .= '</div>' . savebar( T('ui.checks_note'), T('ui.save_checks') ) . '</form></section>';
    return $o;
}

# ---------------------------------------------------------------- settings

sub panel_settings {
    my ( $configured, $pages, $perr ) = @_;
    my $o = panel_open( 'settings', T('ui.tab_settings') );
    $o .= form_open( 'save_settings', 'settings', 'bsw-settings' );

    # connection
    my $has = length $cfg->{api_token};
    my $page_field;
    if ( $pages && @$pages ) {
        $page_field = '<select name="status_page_id"><option value="">' . th('ui.choose') . '</option>'
          . join( '', map { sprintf '<option value="%s"%s>%s</option>', h( $_->{id} ), ( $_->{id} eq $cfg->{status_page_id} ? ' selected' : '' ), h( ( $_->{name} || T('ui.status_page') ) . ( $_->{domain} ? " ($_->{domain})" : '' ) ) } @$pages )
          . '</select>';
    }
    else {
        $page_field = sprintf '<input type="text" name="status_page_id" value="%s" inputmode="numeric" placeholder="%s">', h( $cfg->{status_page_id} ), th('ui.page_id');
        $page_field .= '<div class="bsw-help bsw-help-warn">' . icon('warn') . th( 'ui.pages_failed', $perr ) . '</div>' if $perr;
    }

    $o .= group( 'plug', T('ui.g_connection'), T('ui.g_connection_d'),
        field( T('ui.api_token'),
            sprintf( '<div class="bsw-inline-row"><input type="password" name="api_token" autocomplete="new-password" placeholder="%s"><button class="bsw-btn" name="action" value="test">%s%s</button></div>',
                $has ? th('ui.token_saved') : th('ui.token_ph'), '', th('ui.test') )
              . ( $has ? '<div class="bsw-help">' . icon('lock') . th('ui.token_stored') . ' ' . switch( 'clear_token', 0, T('ui.clear_token'), small => 1 ) . '</div>' : '' ),
            T('ui.api_token_help') )
          . field( T('ui.status_page'), $page_field, $pages && @$pages ? '' : T('ui.status_page_help') ) );

    # presentation
    my $seg = '<div class="bsw-seg">'
      . join( '', map { sprintf '<label><input type="radio" name="section_mode" value="%s"%s><span><strong>%s</strong><em>%s</em></span></label>', $_->[0],
            ( ( $cfg->{section_mode} eq 'category' ? 'category' : 'single' ) eq $_->[0] ? ' checked' : '' ), th( $_->[1] ), th( $_->[2] ) }
          ( [ 'single', 'ui.layout_single', 'ui.layout_single_d' ], [ 'category', 'ui.layout_cat', 'ui.layout_cat_d' ] ) )
      . '</div>';
    my $langsel = sub {
        my ( $name, $cur, $auto ) = @_;
        return "<select name=\"$name\">"
          . ( $auto ? sprintf( '<option value="auto"%s>%s</option>', ( BetterStack::WHM::I18N::valid($cur) ? '' : ' selected' ), th('ui.lang_auto') ) : '' )
          . join( '', map { sprintf '<option value="%s"%s>%s</option>', $_->[0], ( ( $cur // '' ) eq $_->[0] ? ' selected' : '' ), h( $_->[1] ) } @BetterStack::WHM::I18N::LANGS )
          . '</select>';
    };
    $o .= group( 'layers', T('ui.g_page'), T('ui.g_page_d'),
        field( T('ui.server_name'), sprintf( '<input type="text" name="server_label" value="%s" maxlength="200">', h( $cfg->{server_label} ) ), T('ui.server_name_help') )
          . field( T('ui.layout'), $seg )
          . field( T('ui.public_lang'), $langsel->( 'public_lang', BetterStack::WHM::Checks::public_lang($cfg), 0 ), T('ui.public_lang_help') )
          . field( T('ui.ui_lang'), $langsel->( 'ui_lang', $cfg->{ui_lang}, 1 ), T('ui.ui_lang_help') ) );

    # alerts & behaviour
    $o .= group( 'bell', T('ui.g_alerts'), T('ui.g_alerts_d'),
        field( T('ui.channels'),
            '<div class="bsw-switches">' . join( '', map { switch( "alert_$_->[0]", $cfg->{"alert_$_->[0]"}, T( $_->[1] ) ) } ( [ email => 'ui.ch_email' ], [ sms => 'ui.ch_sms' ], [ call => 'ui.ch_call' ], [ push => 'ui.ch_push' ] ) ) . '</div>' )
          . field( T('ui.grace'), sprintf( '<div class="bsw-unit-input"><input type="number" name="grace_pct" value="%d" min="0" max="500"><em>%%</em></div>', $cfg->{grace_pct} ), T('ui.grace_help') )
          . field( T('ui.live_details'),
            switch( 'publish_details', $cfg->{publish_details}, T('ui.live_details_on') )
              . sprintf( '<div class="bsw-unit-input bsw-mt"><input type="number" name="details_interval" value="%d" min="60" step="60"><em>%s</em></div>', $cfg->{details_interval}, th('ui.seconds') ),
            T('ui.live_details_help') )
          . field( T('ui.cleanup_opt'), switch( 'delete_removed', $cfg->{delete_removed}, T('ui.cleanup_opt_on') ) ) );

    # advanced
    $o .= '<details class="bsw-adv"><summary>' . icon('chevron') . th('ui.g_advanced') . '</summary>'
      . field( T('ui.api_base'), sprintf( '<input type="text" name="api_base" value="%s">', h( $cfg->{api_base} ) ) )
      . field( T('ui.team_name'), sprintf( '<input type="text" name="team_name" value="%s" placeholder="%s">', h( $cfg->{team_name} ), th('ui.team_name_ph') ) )
      . '</details>';
    $o .= savebar( T('ui.settings_note'), T('ui.save_settings') ) . '</form>';

    $o .= panel_updates();

    # danger zone
    $o .= form_open( 'cleanup', 'settings', 'bsw-card bsw-danger' )
      . '<div><div><h3>' . th('ui.danger_title') . '</h3><p>' . th('ui.danger_text') . '</p></div></div>'
      . '<div class="bsw-inline-row"><input type="text" name="confirm" placeholder="' . h( T( 'ui.type_to_confirm', T('ui.confirm_word') ) ) . '" autocomplete="off">'
      . '<button class="bsw-btn bsw-btn-danger">' . th('ui.danger_button') . '</button></div></form>';
    $o .= '</section>';
    return $o;
}

# Update check of the git clone the plugin was installed from.
sub panel_updates {
    my $info = BetterStack::WHM::Update::install_info();
    my $s    = BetterStack::WHM::Update::status();
    my $btn  = sub {
        my ( $action, $label, $ic ) = @_;
        return sprintf '<button class="bsw-btn" name="action" value="%s" data-busy-label="%s">%s<span>%s</span></button>', $action, th('ui.preview_busy'), icon($ic), h($label);
    };

    my $state;
    if    ( !$s )                         { $state = '<p>' . th('upd.never') . '</p>' }
    elsif ( $s->{state} eq 'current' )    { $state = '<p class="bsw-upd-ok">' . icon('check') . th('upd.current') . '</p>' }
    elsif ( $s->{state} eq 'available' ) {
        $state = '<p class="bsw-upd-new">' . icon('refresh') . th( 'upd.available', $s->{count} // 1 ) . '</p>';
        if ( @{ $s->{commits} || [] } ) {
            $state .= '<ul class="bsw-commits">'
              . join( '', map { sprintf '<li><code>%s</code><span>%s</span><time>%s</time></li>', h( $_->[0] ), h( $_->[2] // '' ), h( ago( $_->[1] ) ) } @{ $s->{commits} } )
              . '</ul>';
            $state .= '<div class="bsw-help">' . th( 'upd.more', $s->{count} - @{ $s->{commits} } ) . '</div>' if ( $s->{count} // 0 ) > @{ $s->{commits} };
        }
    }
    else { $state = '<div class="bsw-help bsw-help-warn">' . icon('warn') . h( render_msg( $s->{reason} ) ) . '</div>' }
    $state .= '<div class="bsw-help">' . th( 'upd.checked', ago( $s->{at} ) ) . '</div>' if $s;

    my $buttons = '<div class="bsw-inline-row bsw-mt">' . $btn->( 'update_check', T('upd.check_now'), 'refresh' );
    $buttons .= '</div>';

    my $installed = $info
      ? sprintf( '<span class="bsw-upd-src"><span class="bsw-mono">%s</span> &middot; %s</span>', h( substr( $info->{commit} || '-', 0, 7 ) ), h( $info->{source} . ( $info->{upstream} ? " ($info->{upstream})" : '' ) ) )
      : h( T('upd.no_info') );

    my $o = form_open( 'update_check', 'settings' );
    $o .= group( 'refresh', T('upd.title'), T('upd.title_d'),
        field( T('upd.installed'), $installed . '<div class="bsw-help">' . h($BetterStack::WHM::Util::VERSION) . ( $info && $info->{at} ? ' &middot; ' . h( ago( $info->{at} ) ) : '' ) . '</div>' )
          . field( T('upd.status'), $state . $buttons, T('upd.help') )
          . field( T('upd.terminal'), '<code class="bsw-cmd">' . h( BetterStack::WHM::Update::command($info) ) . '</code>', T('upd.terminal_help') ) );
    return $o . '</form>';
}

sub group {
    my ( $ic, $title, $desc, $fields ) = @_;
    return '<div class="bsw-group"><div class="bsw-group-label"><h3>' . h($title) . '</h3><p>' . h($desc) . '</p></div><div class="bsw-card bsw-group-body">' . $fields . '</div></div>';
}

sub field {
    my ( $label, $input, $help ) = @_;
    return '<div class="bsw-setting"><div class="bsw-setting-label">' . h($label) . '</div><div class="bsw-setting-input">' . $input
      . ( $help ? '<div class="bsw-help">' . h($help) . '</div>' : '' ) . '</div></div>';
}

# ---------------------------------------------------------------- log

sub panel_log {
    my $o = panel_open( 'log', T('ui.tab_log'), T('ui.log_intro') );
    my @lines = tail_log(150);
    if ( !@lines ) { return $o . '<div class="bsw-card"><p class="bsw-empty">' . th('ui.log_empty') . '</p></div></section>' }
    $o .= '<div class="bsw-card bsw-log"><ol>';
    for my $l (@lines) {
        my ( $time, $lvl, $msg ) = $l =~ /^(\S+ \S+) \[(\w+)\] (.*)$/ ? ( $1, lc $2, $3 ) : ( '', 'info', $l );
        $o .= sprintf '<li class="bsw-l-%s"><time>%s</time><span class="bsw-lvl">%s</span><span class="bsw-msg">%s</span></li>', h($lvl), h($time), h($lvl), h($msg);
    }
    $o .= '</ol></div></section>';
    return $o;
}

sub tail_log {
    my ($n) = @_;
    open my $fh, '<', log_file() or return ();
    my @lines = <$fh>;
    close $fh;
    @lines = @lines[ -$n .. -1 ] if @lines > $n;
    chomp @lines;
    return reverse map { Encode::decode( 'UTF-8', $_ ) } @lines;
}

# ====================================================================== assets

sub script {
    return <<'JS';
<script>
(function () {
  var root = document.getElementById('bsw');
  if (!root) return;
  root.classList.remove('bsw-nojs');
  function show(tab) {
    var ok = false;
    root.querySelectorAll('.bsw-panel').forEach(function (p) { var on = p.getAttribute('data-panel') === tab; p.classList.toggle('bsw-active', on); ok = ok || on; });
    if (!ok) return;
    root.querySelectorAll('.bsw-tab').forEach(function (t) { t.classList.toggle('bsw-active', t.getAttribute('data-tab') === tab); });
    root.querySelectorAll('input[name=tab]').forEach(function (i) { i.value = tab; });
  }
  root.addEventListener('click', function (e) {
    // Only tab links and "go to" buttons are handled here; every other click
    // (switches, selects, buttons) must keep its normal behaviour.
    var a = e.target.closest('a.bsw-tab[data-tab],a[data-goto]');
    if (!a || !root.contains(a)) return;
    e.preventDefault();
    var t = a.getAttribute('data-tab') || a.getAttribute('data-goto');
    show(t);
    if (history.replaceState) history.replaceState(null, '', '#' + t);
  });
  if (location.hash.length > 1) show(location.hash.slice(1)); else show(root.getAttribute('data-start'));

  // Test buttons of switched-off checks: run the test in the background and
  // replace only its result, so the page does not reload or scroll away.
  root.addEventListener('click', function (e) {
    var b = e.target.closest('button[data-preview]');
    if (!b || !root.contains(b) || !window.fetch || !window.DOMParser) return;
    e.preventDefault();
    if (b.disabled) return;
    var id = b.getAttribute('data-preview'), f = b.form, label = b.querySelector('span'), text = label.textContent;
    var body = new URLSearchParams();
    body.append('csrf', f.querySelector('input[name=csrf]').value);
    body.append('tab', f.querySelector('input[name=tab]').value);
    body.append('action', b.value);
    b.disabled = true;
    b.classList.add('bsw-busy');
    label.textContent = root.getAttribute('data-busy');
    var fail = function (msg) {
      b.disabled = false;
      b.classList.remove('bsw-busy');
      label.textContent = text;
      var old = document.getElementById(id);
      if (!old) return;
      var p = old.querySelector('.bsw-preview-err') || old.appendChild(document.createElement('em'));
      p.className = 'bsw-preview-err';
      p.textContent = msg || root.getAttribute('data-failed');
    };
    fetch(f.getAttribute('action'), { method: 'POST', body: body, credentials: 'same-origin' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
      .then(function (html) {
        var doc = new DOMParser().parseFromString(html, 'text/html');
        var fresh = doc.getElementById(id), old = document.getElementById(id);
        var err = doc.querySelector('#bsw .bsw-flash.bsw-f-error');
        if (!fresh || !old) return fail(err && err.textContent.trim());
        old.replaceWith(document.importNode(fresh, true));
        if (err) fail(err.textContent.trim());
      })
      .catch(function () { fail(); });
  });
  root.addEventListener('click', function (e) {
    var b = e.target.closest('button[data-busy-label]');
    if (!b || !root.contains(b)) return;
    // Not disabled: a disabled button would not submit its action.
    setTimeout(function () { b.classList.add('bsw-busy'); b.querySelector('span').textContent = b.getAttribute('data-busy-label'); }, 0);
  });
  root.querySelectorAll('.bsw-danger').forEach(function (f) {
    f.addEventListener('submit', function (e) { if (!window.confirm(f.querySelector('button').textContent.trim() + '?')) e.preventDefault(); });
  });
  root.querySelectorAll('.bsw-row input[name^=item_enabled_]').forEach(function (c) {
    c.addEventListener('change', function () { c.closest('.bsw-row').classList.toggle('bsw-row-off', !c.checked); });
  });
  root.querySelectorAll('.bsw-check-head input[type=checkbox]').forEach(function (c) {
    c.addEventListener('change', function () { c.closest('.bsw-check').classList.toggle('bsw-check-off', !c.checked); });
  });
})();
</script>
JS
}

sub style {
    return <<'CSS';
<style>
.bsw{--ink:#0b1220;--ink2:#344054;--mu:#667085;--mu2:#98a2b3;--line:#e4e7ec;--line2:#f0f2f5;--bg:#f9fafb;--card:#fff;
 --ac:#1d4ed8;--ac-h:#1e40af;--ac-l:rgba(29,78,216,.12);
 --ok:#12b76a;--ok-t:#067647;--warn:#f79009;--warn-t:#b54708;--fail:#f04438;--fail-t:#b42318;
 font:13px/1.55 "Inter",-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;color:var(--ink);
 max-width:1280px;margin:0 auto 48px;-webkit-font-smoothing:antialiased;font-feature-settings:"cv11","ss01"}
.bsw *,.bsw *::before,.bsw *::after{box-sizing:border-box}
.bsw h1,.bsw h2,.bsw h3{margin:0;font-weight:600;letter-spacing:-.011em;color:var(--ink)}
.bsw p{margin:0}
.bsw a{color:var(--ac);text-decoration:none}
.bsw a:hover{text-decoration:underline}
.bsw-ic{width:15px;height:15px;flex:none;vertical-align:-3px}
.bsw-muted{color:var(--mu)}
.bsw-mono,.bsw code{font-family:"JetBrains Mono","SFMono-Regular",Menlo,Consolas,"Liberation Mono",monospace;font-size:12px}
.bsw-num,.bsw-kpi-v,.bsw-log time{font-variant-numeric:tabular-nums}
.bsw-label{font-size:11px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--mu)}

/* header */
.bsw-head{display:flex;flex-wrap:wrap;gap:16px;align-items:center;justify-content:space-between;padding:18px 22px;background:var(--card);border:1px solid var(--line);border-radius:8px}
.bsw-head-main{display:flex;gap:14px;align-items:center;min-width:0}
.bsw-logo{width:38px;height:38px;border-radius:7px;background:var(--ink);color:#fff;display:grid;place-items:center;flex:none}
.bsw-logo .bsw-ic{width:20px;height:20px;stroke-width:1.75}
.bsw-eyebrow{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--mu2);line-height:1.2}
.bsw .bsw-title{font-size:17px;line-height:1.35}
.bsw-sub{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-top:3px;color:var(--mu);font-size:12px}
.bsw-sep{width:1px;height:12px;background:var(--line)}
.bsw-conn{display:inline-flex;align-items:center;gap:6px;font-weight:500}
.bsw-conn.bsw-s-ok{color:var(--ok-t)}.bsw-conn.bsw-s-warn{color:var(--warn-t)}
.bsw .bsw-link{display:inline-flex;align-items:center;gap:4px;color:var(--ink2);font-weight:500}
.bsw .bsw-link .bsw-ic{width:13px;height:13px;color:var(--mu2)}
.bsw-head-actions{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.bsw-head-actions form{margin:0}
.bsw-lang{display:flex;align-items:center;gap:4px;height:32px;padding:0 4px 0 10px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--mu)}
.bsw .bsw-lang select{border:0;background:transparent;height:30px;padding:0 4px;color:var(--ink);font:500 13px inherit;font-family:inherit;cursor:pointer}
.bsw .bsw-lang select:focus{box-shadow:none}

/* buttons */
.bsw .bsw-btn{display:inline-flex;align-items:center;gap:7px;height:32px;padding:0 13px;border-radius:6px;border:1px solid var(--line);background:var(--card);color:var(--ink);
 font:500 13px/1 inherit;font-family:inherit;cursor:pointer;white-space:nowrap;text-decoration:none;box-shadow:0 1px 2px rgba(16,24,40,.05);transition:background .12s,border-color .12s}
.bsw .bsw-btn:hover{background:var(--bg);border-color:#d0d5dd;text-decoration:none}
.bsw .bsw-btn:focus-visible{outline:2px solid var(--ac);outline-offset:2px}
.bsw .bsw-btn .bsw-ic{color:var(--mu)}
.bsw .bsw-btn[disabled]{opacity:.5;cursor:not-allowed}
.bsw .bsw-btn-primary{background:var(--ink);border-color:var(--ink);color:#fff}
.bsw .bsw-btn-primary:hover{background:#1d2939;border-color:#1d2939}
.bsw .bsw-btn-primary .bsw-ic{color:#fff}
.bsw .bsw-btn-danger{color:var(--fail-t);border-color:#fda29b}
.bsw .bsw-btn-danger:hover{background:var(--fail-t);border-color:var(--fail-t);color:#fff}
.bsw .bsw-btn-sm{height:28px;padding:0 10px}

/* tabs */
.bsw-tabs{display:flex;gap:26px;margin:22px 0 24px;padding:0 4px;border-bottom:1px solid var(--line);overflow-x:auto}
.bsw .bsw-tab{display:inline-flex;align-items:center;gap:7px;padding:10px 0 11px;margin-bottom:-1px;border-bottom:2px solid transparent;color:var(--mu);font-weight:500;white-space:nowrap}
.bsw .bsw-tab .bsw-ic{color:var(--mu2)}
.bsw .bsw-tab:hover{color:var(--ink);text-decoration:none}
.bsw .bsw-tab.bsw-active{color:var(--ink);border-bottom-color:var(--ink)}
.bsw .bsw-tab.bsw-active .bsw-ic{color:var(--ink)}
.bsw-count{display:inline-grid;place-items:center;min-width:17px;height:17px;padding:0 4px;border-radius:4px;font-size:11px;font-weight:600;line-height:1;color:#fff}
.bsw-c-fail{background:var(--fail-t)}.bsw-c-warn{background:var(--warn)}

/* panels */
.bsw.bsw-nojs .bsw-panel{display:block;margin-bottom:40px}
.bsw:not(.bsw-nojs) .bsw-panel{display:none}
.bsw:not(.bsw-nojs) .bsw-panel.bsw-active{display:block}
.bsw-panel-head{margin-bottom:18px}
.bsw-panel-head h2{font-size:16px}
.bsw-panel-head p{color:var(--mu);margin-top:4px;max-width:780px}
.bsw-card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:18px 20px}
.bsw-empty{color:var(--mu);text-align:center;padding:28px}

/* messages */
.bsw-flash{display:flex;gap:10px;align-items:flex-start;padding:11px 14px;margin:0 0 14px;background:var(--card);border:1px solid var(--line);border-left:3px solid var(--mu2);border-radius:6px;color:var(--ink2)}
.bsw-flash .bsw-ic{margin-top:2px}
.bsw-flash ul{margin:6px 0 0;padding-left:18px}
.bsw-f-success{border-left-color:var(--ok)}.bsw-f-success .bsw-ic{color:var(--ok-t)}
.bsw-f-error{border-left-color:var(--fail)}.bsw-f-error .bsw-ic{color:var(--fail-t)}
.bsw-f-info{border-left-color:var(--ac)}.bsw-f-info .bsw-ic{color:var(--ac)}

/* status */
.bsw-dot{width:8px;height:8px;border-radius:2px;flex:none;display:inline-block;background:#d0d5dd}
.bsw-d-ok{background:var(--ok)}.bsw-d-warn{background:var(--warn)}.bsw-d-fail{background:var(--fail)}.bsw-d-off{background:var(--line)}
.bsw-status{display:inline-flex;align-items:center;gap:7px;font-size:12px;font-weight:500;color:var(--mu);white-space:nowrap}
.bsw-s-ok{color:var(--ok-t)}.bsw-s-warn{color:var(--warn-t)}.bsw-s-fail{color:var(--fail-t)}

/* onboarding */
.bsw-onboard{margin-bottom:20px}
.bsw-onboard h3{font-size:15px;margin-bottom:2px}
.bsw-steps{list-style:none;margin:18px 0;padding:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));border:1px solid var(--line);border-radius:6px}
.bsw-steps li{display:flex;gap:12px;padding:14px 16px}
.bsw-steps li+li{border-left:1px solid var(--line)}
.bsw-steps li div{display:flex;flex-direction:column}
.bsw-steps li span:last-child{color:var(--mu);font-size:12px}
.bsw-step-n{font:600 12px/1 "JetBrains Mono",Menlo,monospace;color:var(--mu2);padding-top:3px;flex:none}
.bsw-done .bsw-step-n{color:var(--ok-t)}
.bsw-onboard .bsw-btn .bsw-ic{color:#fff}

/* summary */
.bsw-summary{display:grid;grid-template-columns:1.8fr repeat(4,1fr);background:var(--card);border:1px solid var(--line);border-radius:8px;margin-bottom:20px;overflow:hidden}
.bsw-summary>div+div{border-left:1px solid var(--line)}
.bsw-banner{position:relative;display:flex;gap:14px;padding:18px 20px 18px 24px}
.bsw-banner-bar{position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--line)}
.bsw-k-ok .bsw-banner-bar{background:var(--ok)}.bsw-k-warn .bsw-banner-bar{background:var(--warn)}.bsw-k-fail .bsw-banner-bar{background:var(--fail)}
.bsw-banner-v{font-size:16px;font-weight:600;margin-top:6px;letter-spacing:-.01em}
.bsw-k-fail .bsw-banner-v{color:var(--fail-t)}.bsw-k-warn .bsw-banner-v{color:var(--warn-t)}
.bsw-banner-l{color:var(--mu);font-size:12px;margin-top:2px}
.bsw-kpi{padding:18px 20px}
.bsw-kpi-v{font-size:26px;font-weight:500;letter-spacing:-.02em;line-height:1.1;margin-top:8px;color:var(--ink)}
.bsw-k-warn .bsw-kpi-v{color:var(--warn-t)}.bsw-k-fail .bsw-kpi-v{color:var(--fail-t)}

/* units */
.bsw-units{columns:3 360px;column-gap:16px}
.bsw-units>.bsw-unit{break-inside:avoid;display:block;margin:0 0 16px}
.bsw-unit{padding:0;overflow:hidden;box-shadow:inset 3px 0 0 var(--line)}
.bsw-u-ok{box-shadow:inset 3px 0 0 var(--ok)}.bsw-u-warn{box-shadow:inset 3px 0 0 var(--warn)}.bsw-u-fail{box-shadow:inset 3px 0 0 var(--fail)}
.bsw-unit-head{display:flex;gap:12px;align-items:flex-start;justify-content:space-between;padding:15px 18px 13px 21px;border-bottom:1px solid var(--line)}
.bsw-unit-title{min-width:0}
.bsw-unit-title h3{font-size:14px}
.bsw-meta{display:flex;flex-wrap:wrap;align-items:center;margin-top:3px;color:var(--mu);font-size:12px}
.bsw-meta>span{display:inline-flex;align-items:center;gap:4px}
.bsw-meta>span+span::before{content:"";width:3px;height:3px;border-radius:50%;background:var(--mu2);margin:0 8px}
.bsw-meta .bsw-ic{width:13px;height:13px}
.bsw-meta-ok{color:var(--ok-t)}.bsw-meta-warn{color:var(--warn-t)}
.bsw-members{list-style:none;margin:0;padding:0}
.bsw-members li{display:flex;gap:12px;align-items:flex-start;padding:11px 18px 11px 21px}
.bsw-members li+li{border-top:1px solid var(--line2)}
.bsw-members .bsw-dot{margin-top:6px}
.bsw-m-body{flex:1;min-width:0}
.bsw-m-name{font-weight:500}
.bsw-m-detail{color:var(--mu);font-size:12.5px}
.bsw-m-info{display:flex;gap:6px;align-items:flex-start;margin-top:5px;color:var(--mu);font:11.5px/1.5 "JetBrains Mono",Menlo,Consolas,monospace}
.bsw-m-info .bsw-ic{width:12px;height:12px;margin-top:2px;color:var(--mu2)}
.bsw-members time{color:var(--mu2);font-size:12px;white-space:nowrap}
.bsw-unit-pub{padding:12px 18px 14px 21px;background:var(--bg);border-top:1px solid var(--line);font-size:12px;color:var(--ink2)}
.bsw-unit-pub .bsw-label{margin-bottom:4px}

/* items */
.bsw-cat{margin-bottom:16px;padding:0;overflow:hidden}
.bsw-cat-head{display:flex;flex-wrap:wrap;gap:12px;justify-content:space-between;align-items:center;padding:14px 20px;border-bottom:1px solid var(--line)}
.bsw-cat-head h3{font-size:14px}
.bsw-cat-head .bsw-muted{font-size:12px}
.bsw-row{display:grid;grid-template-columns:56px minmax(200px,1.2fr) minmax(200px,1.4fr) 116px;gap:16px;align-items:center;padding:9px 20px}
.bsw-row+.bsw-row{border-top:1px solid var(--line2)}
.bsw-row-head{background:var(--bg);font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--mu);font-weight:600;padding-top:8px;padding-bottom:8px}
.bsw-row-name{display:flex;gap:10px;align-items:center}
.bsw-row-name strong{font-weight:500}
.bsw-row-name span{display:flex;flex-direction:column;min-width:0}
.bsw-row-name code{font-size:11px;color:var(--mu2);background:none;padding:0;border:0;overflow:hidden;text-overflow:ellipsis}
.bsw-row-off .bsw-row-name>.bsw-dot,.bsw-row-off .bsw-row-name strong,.bsw-row-off .bsw-row-name code,.bsw-row-off input[type=text]{opacity:.45}

/* checks */
.bsw-grid{columns:3 360px;column-gap:16px}
.bsw-grid>.bsw-check{break-inside:avoid;display:block;margin:0 0 16px}
.bsw-check-off .bsw-check-head,.bsw-check-off>.bsw-muted,.bsw-check-off .bsw-fields{opacity:.55}
.bsw-preview{margin-top:14px;padding-top:12px;border-top:1px solid var(--line2)}
.bsw-preview-head{display:flex;gap:12px;justify-content:space-between;align-items:center;font-size:12.5px}
.bsw-preview .bsw-members li{padding:9px 0}
.bsw-preview-line{display:flex!important;flex-flow:row wrap!important;gap:4px 8px;align-items:center;margin-top:5px;font-size:12px;color:var(--mu)}
.bsw-preview-line em{font-style:normal;display:inline-flex;gap:6px;align-items:center}
.bsw-preview-line time{color:var(--mu2)}
.bsw-preview-line .bsw-m-info{flex-basis:100%;margin-top:0}
.bsw .bsw-btn.bsw-busy{cursor:progress;opacity:.75}
.bsw-upd-ok,.bsw-upd-new{display:flex;gap:7px;align-items:center;margin:0;font-weight:500}
.bsw-upd-ok .bsw-ic{color:var(--ok-t)}.bsw-upd-new .bsw-ic{color:var(--warn-t)}
.bsw-commits{list-style:none;margin:8px 0 0;padding:0;border:1px solid var(--line2);border-radius:6px;max-height:260px;overflow:auto}
.bsw-commits li{display:flex;gap:10px;align-items:baseline;padding:6px 10px;font-size:12.5px}
.bsw-commits li+li{border-top:1px solid var(--line2)}
.bsw-commits span{flex:1;min-width:0}.bsw-commits time{color:var(--mu2);font-size:12px;white-space:nowrap}
.bsw-upd-src{overflow-wrap:anywhere}
.bsw-cmd{display:block;max-width:100%;box-sizing:border-box;padding:8px 10px;border:1px solid var(--line2);border-radius:6px;overflow-x:auto;white-space:nowrap;font-size:12px}
.bsw .bsw-btn.bsw-busy .bsw-ic{animation:bsw-pulse 1s ease-in-out infinite}
@keyframes bsw-pulse{50%{opacity:.2}}
.bsw-preview-err{display:block;flex-basis:100%;font-style:normal;color:var(--fail-t);font-size:12px;margin-top:4px}
.bsw-check-head{display:flex;gap:12px;justify-content:space-between;align-items:flex-start;margin-bottom:6px}
.bsw-check-head h3{font-size:14px;margin-top:3px}
.bsw-check>p{margin-bottom:14px;font-size:12.5px}
.bsw-fields{display:grid;grid-template-columns:1fr 1fr;gap:12px 14px;padding-top:14px;border-top:1px solid var(--line2)}
.bsw-field{display:flex;flex-direction:column;gap:5px;margin:0;font-weight:normal}
.bsw-field>span{font-size:12px;font-weight:500;color:var(--ink2)}
.bsw-wide{grid-column:1/-1}
.bsw-inline{flex-direction:row;align-items:center;gap:10px}
.bsw-inline>span{font-size:12px;color:var(--mu)}
.bsw-inline input{width:260px}

/* inputs */
.bsw input[type=text],.bsw input[type=number],.bsw input[type=password],.bsw .bsw-setting select{width:100%;height:34px;padding:0 11px;border:1px solid #d0d5dd;border-radius:6px;
 background:#fff;color:var(--ink);font:inherit;font-size:13px;box-shadow:0 1px 2px rgba(16,24,40,.04);transition:border-color .12s,box-shadow .12s;margin:0}
.bsw input:focus,.bsw .bsw-setting select:focus{outline:none;border-color:var(--ac);box-shadow:0 0 0 3px var(--ac-l)}
.bsw input::placeholder{color:var(--mu2)}
.bsw-unit-input{display:flex;align-items:center;position:relative;max-width:220px}
.bsw-unit-input input{padding-right:70px!important}
.bsw-unit-input em{position:absolute;right:11px;font-style:normal;color:var(--mu2);font-size:12px;pointer-events:none}
.bsw-inline-row{display:flex;gap:8px;align-items:center}
.bsw-inline-row input{flex:1}
.bsw-mt{margin-top:10px}

/* switch */
.bsw .bsw-switch{display:inline-flex;align-items:center;gap:10px;cursor:pointer;margin:0;font-weight:400;user-select:none}
.bsw-switch input{position:absolute;opacity:0;width:1px;height:1px}
.bsw-switch-track{position:relative;width:32px;height:18px;border-radius:9px;background:#d0d5dd;transition:background .15s;flex:none}
.bsw-switch-track::after{content:"";position:absolute;top:2px;left:2px;width:14px;height:14px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(16,24,40,.2);transition:transform .15s}
.bsw-switch input:checked+.bsw-switch-track{background:var(--ac)}
.bsw-switch input:checked+.bsw-switch-track::after{transform:translateX(14px)}
.bsw-switch input:focus-visible+.bsw-switch-track{box-shadow:0 0 0 3px var(--ac-l)}
.bsw-switch-sm .bsw-switch-track{width:28px;height:16px}
.bsw-switch-sm .bsw-switch-track::after{width:12px;height:12px}
.bsw-switch-sm input:checked+.bsw-switch-track::after{transform:translateX(12px)}
.bsw-switch-label{font-size:13px;color:var(--ink2)}
.bsw-switches{display:flex;flex-wrap:wrap;gap:12px 24px}

/* settings */
.bsw-group{display:grid;grid-template-columns:260px minmax(0,1fr);gap:32px;padding:24px 0;border-top:1px solid var(--line)}
.bsw-group:first-of-type{border-top:0;padding-top:0}
.bsw-group-label h3{font-size:14px;margin-bottom:4px}
.bsw-group-label p{color:var(--mu);font-size:12.5px}
.bsw-group-body{padding:4px 20px}
.bsw-setting{display:grid;grid-template-columns:180px minmax(0,1fr);gap:18px;padding:14px 0}
.bsw-setting+.bsw-setting{border-top:1px solid var(--line2)}
.bsw-setting-label{font-weight:500;padding-top:7px;color:var(--ink2)}
.bsw-help{margin-top:6px;font-size:12px;color:var(--mu);display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center}
.bsw-help .bsw-ic{width:13px;height:13px;color:var(--mu2)}
.bsw-help-warn{color:var(--warn-t);flex-wrap:nowrap;align-items:flex-start}
.bsw-help-warn .bsw-ic{color:var(--warn-t);margin-top:2px}
.bsw-seg{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.bsw-seg label{margin:0;cursor:pointer;font-weight:normal}
.bsw-seg input{position:absolute;opacity:0}
.bsw-seg span{display:flex;flex-direction:column;gap:2px;padding:10px 12px;border:1px solid #d0d5dd;border-radius:6px;height:100%;transition:border-color .12s,box-shadow .12s}
.bsw-seg strong{font-weight:500}
.bsw-seg em{font-style:normal;color:var(--mu);font-size:12px}
.bsw-seg input:checked+span{border-color:var(--ink);box-shadow:inset 0 0 0 1px var(--ink)}
.bsw-seg input:focus-visible+span{box-shadow:0 0 0 3px var(--ac-l)}
.bsw-adv{margin:8px 0 0 292px;padding:12px 18px;border:1px solid var(--line);border-radius:8px;background:var(--card)}
.bsw-adv summary{cursor:pointer;font-weight:500;display:flex;gap:6px;align-items:center;color:var(--ink2);list-style:none}
.bsw-adv summary::-webkit-details-marker{display:none}
.bsw-adv summary .bsw-ic{transition:transform .15s;color:var(--mu2)}
.bsw-adv[open] summary .bsw-ic{transform:rotate(90deg)}
.bsw-adv[open] summary{margin-bottom:4px}
.bsw-danger{display:flex;flex-wrap:wrap;gap:16px;align-items:center;justify-content:space-between;margin-top:40px;border-color:#fecdca}
.bsw-danger h3{font-size:14px;color:var(--fail-t);margin-bottom:2px}
.bsw-danger p{color:var(--mu);font-size:12.5px;max-width:640px}
.bsw-danger .bsw-inline-row input{width:220px}

/* save bar */
.bsw-savebar{position:sticky;bottom:12px;z-index:5;display:flex;gap:12px;align-items:center;justify-content:space-between;margin-top:20px;padding:10px 10px 10px 18px;border-radius:8px;
 background:rgba(255,255,255,.96);border:1px solid var(--line);box-shadow:0 12px 32px -16px rgba(16,24,40,.28)}
.bsw-savebar>span{color:var(--mu);font-size:12.5px}

/* log */
.bsw-log{padding:0;overflow:hidden}
.bsw-log ol{list-style:none;margin:0;padding:0;max-height:640px;overflow:auto;font:12px/1.6 "JetBrains Mono","SFMono-Regular",Menlo,Consolas,monospace}
.bsw-log li{display:grid;grid-template-columns:150px 58px 1fr;gap:14px;padding:7px 20px;border-bottom:1px solid var(--line2)}
.bsw-log li:last-child{border-bottom:0}
.bsw-log time{color:var(--mu2)}
.bsw-lvl{font-weight:600;text-transform:uppercase;font-size:11px;letter-spacing:.04em;color:var(--mu)}
.bsw-l-warn .bsw-lvl{color:var(--warn-t)}.bsw-l-error .bsw-lvl{color:var(--fail-t)}
.bsw-msg{word-break:break-word;color:var(--ink2)}
.bsw-foot{margin-top:32px;padding-top:16px;border-top:1px solid var(--line);color:var(--mu2);font-size:12px;text-align:center}

@media (max-width:1040px){.bsw-summary{grid-template-columns:repeat(4,1fr)}.bsw-banner{grid-column:1/-1}.bsw-summary>div:nth-child(2){border-left:0}
 .bsw-summary>.bsw-kpi{border-top:1px solid var(--line)}.bsw-group{grid-template-columns:1fr;gap:12px}.bsw-adv{margin-left:0}}
@media (max-width:720px){.bsw-head{padding:16px}.bsw-summary{grid-template-columns:1fr 1fr}.bsw-summary>div:nth-child(4){border-left:0}
 .bsw-units,.bsw-grid{columns:1;grid-template-columns:1fr}.bsw-setting{grid-template-columns:1fr;gap:6px}.bsw-setting-label{padding-top:0}
 .bsw-row{grid-template-columns:44px 1fr 56px}.bsw-row>span:nth-child(3){grid-column:1/-1;order:4}.bsw-row-head>span:nth-child(3){display:none}.bsw-fields,.bsw-seg{grid-template-columns:1fr}
 .bsw-steps li+li{border-left:0;border-top:1px solid var(--line)}.bsw-log li{grid-template-columns:1fr;gap:2px}.bsw-inline input{width:100%}}
</style>
CSS
}
