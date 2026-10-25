package BetterStack::WHM::Engine;

# Runs checks, provisions heartbeats + status page resources in Better Stack
# and reports the results to their heartbeats.
#
# Checks are reported through "units". By default all checks of a category
# share one heartbeat (Server, Diensten, E-mail, Beveiliging & back-ups), so
# the plugin stays within the heartbeat quota of a Better Stack plan. Single
# checks can get their own heartbeat (and status page item) on request.

use strict;
use warnings;

use Fcntl qw(:flock);
use JSON::PP ();
use File::Path qw(make_path);

use BetterStack::WHM::API ();
use BetterStack::WHM::Checks ();
use BetterStack::WHM::Config ();
use BetterStack::WHM::History ();
use BetterStack::WHM::Maintenance ();
use BetterStack::WHM::Util qw(var_dir logmsg http_request);
use BetterStack::WHM::I18N qw(T tl render render_msg);

# Language for log lines, sync errors shown in WHM and incident texts.
sub admin_lang {
    my ($cfg) = @_;
    my $l = $cfg->{ui_lang} // '';
    return BetterStack::WHM::I18N::valid($l) ? $l : BetterStack::WHM::Checks::public_lang($cfg);
}

# "action: API error" as a translatable message.
sub _err { [ 'e.err', $_[0], $_[1] // '' ] }

# IDs and URLs returned by the API end up in request paths and in the ping
# target, so only accept what they are supposed to look like.
sub _id {
    my ($d) = @_;
    my $id = ref $d eq 'HASH' && ref $d->{data} eq 'HASH' ? $d->{data}{id} : undef;
    return defined $id && $id =~ /^\d{1,20}\z/ ? "$id" : undef;
}

sub _hb_url {
    my ($d) = @_;
    my $url = eval { $d->{data}{attributes}{url} } // '';
    return $url =~ m{^https://[A-Za-z0-9.-]+\.(?:betterstack|betteruptime)\.com/[A-Za-z0-9/_-]+\z} ? $url : undef;
}

my %STATUS_ICON = ( ok => '', warn => "\x{26a0} ", fail => "\x{2716} " );
my $MAX_EXPLANATION = 900;

# Exclusive lock so cron and the WHM UI never run at the same time.
sub with_lock {
    my ( $code, %opt ) = @_;
    make_path( var_dir(), { mode => 0700 } );
    open my $lock, '>', var_dir() . '/run.lock' or die "Cannot open lock file: $!\n";
    my $mode = LOCK_EX | ( $opt{wait} ? 0 : LOCK_NB );
    if ( !flock $lock, $mode ) {
        return { ok => 0, error => ['e.busy'] };
    }
    my $r = eval { $code->() };
    my $err = $@;
    close $lock;
    die $err if $err;
    return $r;
}

sub grace_for {
    my ( $cfg, $period ) = @_;
    my $g = int( $period * ( $cfg->{grace_pct} // 50 ) / 100 );
    return $g < 30 ? 30 : $g;
}

sub alerts_sig {
    my ($cfg) = @_;
    return join '', map { $cfg->{"alert_$_"} ? 1 : 0 } qw(email sms call push);
}

sub section_key {
    my ( $cfg, $unit ) = @_;
    return $cfg->{section_mode} eq 'single' ? '_single' : $unit->{category};
}

sub section_name {
    my ( $cfg, $key ) = @_;
    return $cfg->{server_label} if $key eq '_single';
    return "$cfg->{server_label} \x{2014} " . BetterStack::WHM::Checks::category_label( $key, BetterStack::WHM::Checks::public_lang($cfg) );
}

# ------------------------------------------------------------------ units

sub unit_key {
    my ( $cfg, $inst ) = @_;
    my $ov = ( $cfg->{instances} || {} )->{ $inst->{id} } || {};
    return $ov->{own} ? "item:$inst->{id}" : "cat:$inst->{category}";
}

sub group_name {
    my ( $cfg, $cat ) = @_;
    my $n = ( $cfg->{group_names} || {} )->{$cat};
    return defined $n && length $n ? $n : BetterStack::WHM::Checks::category_label( $cat, BetterStack::WHM::Checks::public_lang($cfg) );
}

# Enabled instances -> ordered list of units.
sub units {
    my ( $cfg, $instances ) = @_;
    my ( %by_key, @order );
    for my $inst (@$instances) {
        my $key = unit_key( $cfg, $inst );
        my $u   = $by_key{$key};
        if ( !$u ) {
            my $own = $key =~ /^item:/;
            $u = $by_key{$key} = {
                key         => $key,
                kind        => $own ? 'item' : 'cat',
                category    => $inst->{category},
                name        => $own ? $inst->{name}        : BetterStack::WHM::Checks::category_label( $inst->{category}, BetterStack::WHM::Checks::public_lang($cfg) ),
                public_name => $own ? $inst->{public_name} : group_name( $cfg, $inst->{category} ),
                interval    => $inst->{interval},
                members     => [],
            };
            push @order, $u;
        }
        push @{ $u->{members} }, $inst;
        $u->{interval} = $inst->{interval} if $inst->{interval} < $u->{interval};
    }
    my %rank;
    my $n = 0;
    $rank{ $_->[0] } = $n++ for @BetterStack::WHM::Checks::CATEGORIES;
    return [ sort { ( $rank{ $a->{category} } // 99 ) <=> ( $rank{ $b->{category} } // 99 ) || ( $a->{kind} eq 'cat' ? 0 : 1 ) <=> ( $b->{kind} eq 'cat' ? 0 : 1 ) }
          @order ];
}

sub signature {
    my ( $cfg, $units ) = @_;
    return join '|', $cfg->{status_page_id}, $cfg->{server_label}, $cfg->{section_mode}, alerts_sig($cfg), $cfg->{grace_pct},
      map { "$_->{key}=$_->{public_name}=$_->{interval}" } @$units;
}

sub _quota_error { ( $_[0] // '' ) =~ /quota/i }

# ------------------------------------------------------------------ sync

sub sync {
    my ( $cfg, $st, $units ) = @_;
    my $api   = BetterStack::WHM::API->from_config($cfg);
    my $page  = $cfg->{status_page_id};
    my $label = $cfg->{server_label};
    my @errors;

    # Status page switched: drop resources/sections from the old page.
    if ( $st->{status_page_id} && $st->{status_page_id} ne $page ) {
        for my $it ( values %{ $st->{items} } ) {
            $api->delete_resource( $st->{status_page_id}, $it->{resource_id} ) if $it->{resource_id};
            delete @{$it}{qw(resource_id public_name section_key explanation_sent explanation_base)};
        }
        $api->delete_section( $st->{status_page_id}, $_->{id} ) for values %{ $st->{sections} };
        $st->{sections} = {};
    }
    $st->{status_page_id} = $page;

    # 1. Remove what is no longer wanted first, so it frees up heartbeat quota.
    my %want = map { $_->{key} => $_ } @$units;
    for my $key ( keys %{ $st->{items} } ) {
        next if $want{$key};
        my $it     = $st->{items}{$key};
        my $legacy = $key !~ /^(?:item|cat):/;    # one-heartbeat-per-check layout of v1.0
        if ( $it->{resource_id} ) {
            my ( undef, $err ) = $api->delete_resource( $page, $it->{resource_id} );
            if ( $err && ( $api->{last_status} // 0 ) != 404 ) { push @errors, _err( [ 'e.del_item', $key ], $err ); next }
            delete @{$it}{qw(resource_id public_name section_key explanation_sent explanation_base)};
        }
        if ( !$it->{heartbeat_id} ) { delete $st->{items}{$key}; next }
        if ( $cfg->{delete_removed} || $legacy ) {
            my ( undef, $err ) = $api->delete_heartbeat( $it->{heartbeat_id} );
            if ( $err && ( $api->{last_status} // 0 ) != 404 ) { push @errors, _err( [ 'e.del_hb', $key ], $err ); next }
            delete $st->{items}{$key};
            logmsg( info => [ 'log.hb_deleted', $key ] );
        }
        elsif ( !$it->{paused} ) {
            my ( undef, $err ) = $api->update_heartbeat( $it->{heartbeat_id}, { paused => JSON::PP::true } );
            $it->{paused} = 1 unless $err;
        }
    }

    # What exists in Better Stack right now. Used to adopt objects instead of
    # creating duplicates (e.g. when state.json was lost) and to remove
    # leftovers of this server. A list that cannot be fetched is undef, and
    # then nothing of that kind is adopted or removed.
    my $inv = inventory( $api, $page );

    # 2. Heartbeat group per server keeps Better Stack tidy.
    my @label_groups = grep { ( $_->{attributes}{name} // '' ) eq $label } @{ $inv->{groups} || [] };
    if ( $st->{group_id} && $inv->{groups} && !grep { $_->{id} eq $st->{group_id} } @{ $inv->{groups} } ) {
        delete $st->{group_id};    # deleted in Better Stack
    }
    if ( !$st->{group_id} && @label_groups ) {
        $st->{group_id} = "$label_groups[0]{id}";
        logmsg( info => [ 'log.group_adopted', $label, $st->{group_id} ] );
    }
    if ( !$st->{group_id} ) {
        my ( $d, $err ) = $api->create_hb_group($label);
        if   ($err) { push @errors, _err( ['e.create_group'], $err ) }
        else        { $st->{group_id} = _id($d) }
    }
    my %our_groups = map { $_->{id} => 1 } @label_groups;
    $our_groups{ $st->{group_id} } = 1 if $st->{group_id};

    # Heartbeats of this server: in one of its groups and named "<label>: ...".
    my @our_hbs = grep { $our_groups{ $_->{attributes}{heartbeat_group_id} // '' } && index( $_->{attributes}{name} // '', "$label: " ) == 0 }
      @{ $inv->{heartbeats} || [] };
    my %claimed_hb = map { $_->{heartbeat_id} => 1 } grep { $_->{heartbeat_id} } values %{ $st->{items} };

    # 3. Sections.
    my %needed;
    $needed{ section_key( $cfg, $_ ) } = 1 for @$units;
    my @order = ( '_single', map { $_->[0] } @BetterStack::WHM::Checks::CATEGORIES );
    my $existing_sections = $inv->{sections};
    my %exists = map { $_->{id} => 1 } @{ $existing_sections || [] };
    my %claimed_sec = map { $_->{id} => 1 } values %{ $st->{sections} };
    for my $key ( grep { $needed{$_} } @order ) {
        my $name = section_name( $cfg, $key );
        my $sec  = $st->{sections}{$key};
        if ( ( !$sec || ( $existing_sections && !$exists{ $sec->{id} } ) ) && $existing_sections ) {
            my ($found) = grep { !$claimed_sec{ $_->{id} } && ( $_->{attributes}{name} // '' ) eq $name } @$existing_sections;
            if ($found) {
                $sec = $st->{sections}{$key} = { id => "$found->{id}", name => $name };
                $claimed_sec{ $found->{id} } = 1;
                $_->{section_key} = '' for grep { ( $_->{section_key} // '' ) eq $key } values %{ $st->{items} };
                logmsg( info => [ 'log.section_adopted', $name ] );
                next;
            }
        }
        next if $sec && ( !$existing_sections || $exists{ $sec->{id} } ) && $sec->{name} eq $name;
        if ( $sec && $exists{ $sec->{id} } ) {
            # Label changed: rename in place.
            my ( undef, $err ) = $api->request( 'PATCH', "/status-pages/$page/sections/$sec->{id}", { name => $name } );
            if ( !$err ) { $sec->{name} = $name; next }
        }
        my ( $d, $err ) = $api->create_section( $page, { name => $name } );
        if ($err) { push @errors, _err( [ 'e.create_sec', $name ], $err ); next }
        my $sid = _id($d) or do { push @errors, [ 'e.unexpected', [ 'e.create_sec', $name ] ]; next };
        $st->{sections}{$key} = { id => $sid, name => $name };
        $claimed_sec{$sid} = 1;
        # Resources pointing at a vanished section must be re-linked.
        $_->{section_key} = '' for grep { ( $_->{section_key} // '' ) eq $key } values %{ $st->{items} };
    }

    # 4. Heartbeats + resources.
    my $quota_hit = 0;
    for my $unit (@$units) {
        my $it   = $st->{items}{ $unit->{key} } ||= {};
        my $name = "$label: $unit->{name}";
        my %hb   = (
            name   => $name,
            period => $unit->{interval},
            grace  => grace_for( $cfg, $unit->{interval} ),
            email  => $cfg->{alert_email} ? JSON::PP::true : JSON::PP::false,
            sms    => $cfg->{alert_sms}   ? JSON::PP::true : JSON::PP::false,
            call   => $cfg->{alert_call}  ? JSON::PP::true : JSON::PP::false,
            push   => $cfg->{alert_push}  ? JSON::PP::true : JSON::PP::false,
            ( $st->{group_id} ? ( heartbeat_group_id => $st->{group_id} + 0 ) : () ),
        );
        my $hb_sig = join '|', $name, $hb{period}, $hb{grace}, alerts_sig($cfg), $st->{group_id} // '';

        if ( $it->{heartbeat_id} && ( ( $it->{hb_sig} // '' ) ne $hb_sig || $it->{paused} ) ) {
            my ( undef, $err ) = $api->update_heartbeat( $it->{heartbeat_id}, { %hb, paused => JSON::PP::false } );
            if ( $err && ( $api->{last_status} // 0 ) == 404 ) {
                delete @{$it}{qw(heartbeat_id heartbeat_url resource_id)};
            }
            elsif ($err) { push @errors, _err( [ 'e.update_hb', $name ], $err ) }
            else         { $it->{hb_sig} = $hb_sig; delete $it->{paused} }
        }
        if ( !$it->{heartbeat_id} ) {
            # Adopt an existing heartbeat of this server with the same name.
            my ($found) = grep { !$claimed_hb{ $_->{id} } && ( $_->{attributes}{name} // '' ) eq $name && _hb_url( { data => $_ } ) } @our_hbs;
            if ($found) {
                $it->{heartbeat_id}  = "$found->{id}";
                $it->{heartbeat_url} = _hb_url( { data => $found } );
                $it->{hb_sig}        = '';    # bring its settings up to date
                $claimed_hb{ $found->{id} } = 1;
                delete @{$it}{qw(resource_id public_name section_key explanation_sent explanation_base)};
                logmsg( info => [ 'log.hb_adopted', $name, $found->{id} ] );
                my ( undef, $err ) = $api->update_heartbeat( $it->{heartbeat_id}, { %hb, paused => JSON::PP::false } );
                $it->{hb_sig} = $hb_sig unless $err;
            }
        }
        if ( !$it->{heartbeat_id} ) {
            if ($quota_hit) { delete $st->{items}{ $unit->{key} }; next }
            my ( $d, $err ) = $api->create_heartbeat( \%hb );
            if ( $err && _quota_error($err) ) {
                $quota_hit = 1;
                delete $st->{items}{ $unit->{key} };
                push @errors, [ 'e.quota', $name ];
                next;
            }
            if ($err) { push @errors, _err( [ 'e.create_hb', $name ], $err ); delete $st->{items}{ $unit->{key} }; next }
            my ( $hid, $hurl ) = ( _id($d), _hb_url($d) );
            if ( !$hid || !$hurl ) { push @errors, [ 'e.unexpected', [ 'e.create_hb', $name ] ]; next }
            $it->{heartbeat_id}  = $hid;
            $it->{heartbeat_url} = $hurl;
            $it->{hb_sig}        = $hb_sig;
            $claimed_hb{$hid}    = 1;
            delete $it->{resource_id};
            logmsg( info => [ 'log.hb_created', $name, $it->{heartbeat_id} ] );
        }

        my $skey = section_key( $cfg, $unit );
        my $sec  = $st->{sections}{$skey} or next;
        if ( $it->{resource_id}
            && ( ( $it->{public_name} // '' ) ne $unit->{public_name} || ( $it->{section_key} // '' ) ne $skey ) )
        {
            my ( undef, $err ) = $api->update_resource( $page, $it->{resource_id},
                { public_name => $unit->{public_name}, status_page_section_id => $sec->{id} + 0 } );
            if ( $err && ( $api->{last_status} // 0 ) == 404 ) { delete $it->{resource_id} }
            elsif ($err) { push @errors, _err( [ 'e.update_res', $unit->{public_name} ], $err ) }
            else { $it->{public_name} = $unit->{public_name}; $it->{section_key} = $skey }
        }
        if ( !$it->{resource_id} && $inv->{resources} ) {
            my ($found) = grep { ( $_->{attributes}{resource_type} // '' ) eq 'Heartbeat' && ( $_->{attributes}{resource_id} // '' ) eq $it->{heartbeat_id} }
              @{ $inv->{resources} };
            if ($found) {
                $it->{resource_id} = "$found->{id}";
                my ( undef, $err ) = $api->update_resource( $page, $it->{resource_id},
                    { public_name => $unit->{public_name}, status_page_section_id => $sec->{id} + 0 } );
                if ( !$err ) { $it->{public_name} = $unit->{public_name}; $it->{section_key} = $skey }
                delete @{$it}{qw(explanation_sent explanation_base)};
            }
        }
        if ( !$it->{resource_id} ) {
            my ( $d, $err ) = $api->create_resource(
                $page,
                {
                    resource_id            => $it->{heartbeat_id} + 0,
                    resource_type          => 'Heartbeat',
                    public_name            => $unit->{public_name},
                    status_page_section_id => $sec->{id} + 0,
                    widget_type            => 'history',
                }
            );
            if ($err) { push @errors, _err( [ 'e.create_res', $unit->{public_name} ], $err ); next }
            $it->{resource_id} = _id($d) or do { push @errors, [ 'e.unexpected', [ 'e.create_res', $unit->{public_name} ] ]; next };
            $it->{public_name} = $unit->{public_name};
            $it->{section_key} = $skey;
            delete @{$it}{qw(explanation_sent explanation_base)};
        }
    }

    # 5. Sections that are no longer used.
    for my $key ( keys %{ $st->{sections} } ) {
        next if $needed{$key};
        my ( undef, $err ) = $api->delete_section( $page, $st->{sections}{$key}{id} );
        delete $st->{sections}{$key} if !$err || ( $api->{last_status} // 0 ) == 404;
    }

    # 6. Leftovers of this server that nothing refers to any more (duplicates
    #    after a lost state file, older layouts). Only objects that are clearly
    #    this plugin's are touched; anything holding other items is kept.
    push @errors, cleanup_leftovers( $api, $cfg, $st, $inv, \@our_hbs, \@label_groups ) unless $quota_hit;

    $st->{last_sync} = time;
    return \@errors;
}

sub inventory {
    my ( $api, $page ) = @_;
    my %inv;
    ( $inv{heartbeats} ) = $api->list_heartbeats;
    ( $inv{groups} )     = $api->list_hb_groups;
    ( $inv{sections} )   = $api->list_sections($page);
    ( $inv{resources} )  = $api->list_resources($page);
    for my $list ( values %inv ) {
        next unless $list;
        $list = [ grep { ref $_ eq 'HASH' && defined $_->{id} && $_->{id} =~ /^\d{1,20}\z/ && ref $_->{attributes} eq 'HASH' } @$list ];
    }
    return \%inv;
}

sub cleanup_leftovers {
    my ( $api, $cfg, $st, $inv, $our_hbs, $label_groups ) = @_;
    my $page  = $cfg->{status_page_id};
    my $label = $cfg->{server_label};
    my @errors;
    my $gone = sub { !$_[0] || ( $api->{last_status} // 0 ) == 404 };

    my %state_hb  = map { $_->{heartbeat_id} => 1 } grep { $_->{heartbeat_id} } values %{ $st->{items} };
    my %state_res = map { $_->{resource_id}  => 1 } grep { $_->{resource_id} } values %{ $st->{items} };
    my %state_sec = map { $_->{id} => 1 } values %{ $st->{sections} };

    # Heartbeats of this server that are not in use.
    my %orphan_hb;
    if ( $inv->{heartbeats} ) {
        for my $hb ( grep { !$state_hb{ $_->{id} } } @$our_hbs ) {
            my ( undef, $e ) = $api->delete_heartbeat( $hb->{id} );
            if ( $gone->($e) ) { $orphan_hb{ $hb->{id} } = 1; logmsg( info => [ 'log.orphan_hb', $hb->{attributes}{name}, $hb->{id} ] ) }
            else               { push @errors, _err( [ 'e.orphan_hb', $hb->{attributes}{name} ], $e ) }
        }
    }

    # Status page items that point at those heartbeats, or duplicates of ours.
    my %res_in_section;
    for my $r ( @{ $inv->{resources} || [] } ) {
        my $a      = $r->{attributes};
        my $is_hb  = ( $a->{resource_type} // '' ) eq 'Heartbeat';
        my $target = $a->{resource_id} // '';
        my $dup    = $is_hb && $state_hb{$target} && !$state_res{ $r->{id} };
        if ( $is_hb && ( $orphan_hb{$target} || $dup ) ) {
            my ( undef, $e ) = $api->delete_resource( $page, $r->{id} );
            next if $gone->($e);
            push @errors, _err( ['e.orphan_res'], $e );
        }
        $res_in_section{ $a->{status_page_section_id} // '' }++;
    }

    # Sections named like this server's that are not in use and now empty.
    if ( $inv->{sections} && $inv->{resources} ) {
        for my $sec ( @{ $inv->{sections} } ) {
            my $name = $sec->{attributes}{name} // '';
            next if $state_sec{ $sec->{id} } || $res_in_section{ $sec->{id} };
            next unless $name eq $label || index( $name, "$label \x{2014} " ) == 0;
            my ( undef, $e ) = $api->delete_section( $page, $sec->{id} );
            if   ( $gone->($e) ) { logmsg( info => [ 'log.orphan_sec', $name ] ) }
            else                 { push @errors, _err( [ 'e.orphan_sec', $name ], $e ) }
        }
    }

    # Extra heartbeat groups with this server's name that are now empty.
    if ( $inv->{heartbeats} ) {
        my %used;
        $used{ $_->{attributes}{heartbeat_group_id} // '' }++ for grep { !$orphan_hb{ $_->{id} } } @{ $inv->{heartbeats} };
        for my $g (@$label_groups) {
            next if $g->{id} eq ( $st->{group_id} // '' ) || $used{ $g->{id} };
            my ( undef, $e ) = $api->delete_hb_group( $g->{id} );
            push @errors, _err( ['e.orphan_grp'], $e ) unless $gone->($e);
        }
    }
    return @errors;
}

# Remove everything this plugin created in Better Stack.
sub cleanup {
    my ( $cfg, $st ) = @_;
    my $api  = BetterStack::WHM::API->from_config($cfg);
    my $page = $st->{status_page_id} || $cfg->{status_page_id};
    my @errors;
    my $gone = sub { !$_[0] || ( $api->{last_status} // 0 ) == 404 };
    for my $id ( keys %{ $st->{items} } ) {
        my $it = $st->{items}{$id};
        if ( $it->{resource_id} ) {
            my ( undef, $e ) = $api->delete_resource( $page, $it->{resource_id} );
            push @errors, _err( [ 'e.del_item', $id ], $e ) unless $gone->($e);
        }
        if ( $it->{heartbeat_id} ) {
            my ( undef, $e ) = $api->delete_heartbeat( $it->{heartbeat_id} );
            push @errors, _err( [ 'e.del_hb', $id ], $e ) unless $gone->($e);
        }
    }
    for my $sec ( values %{ $st->{sections} } ) {
        my ( undef, $e ) = $api->delete_section( $page, $sec->{id} );
        push @errors, _err( [ 'e.del_sec', $sec->{name} ], $e ) unless $gone->($e);
    }
    if ( $st->{group_id} ) {
        my ( undef, $e ) = $api->delete_hb_group( $st->{group_id} );
        push @errors, _err( ['e.del_group'], $e ) unless $gone->($e);
    }
    %$st = ( results => $st->{results} || {}, items => {}, sections => {} );
    return \@errors;
}

# ------------------------------------------------------------------ run

sub ping {
    my ( $it, $res ) = @_;
    my $url = $it->{heartbeat_url} or return ( 0, 'geen heartbeat' );
    my $r;
    if ( $res->{status} eq 'fail' ) {
        $r = http_request( 'POST', "$url/fail", body => $res->{body} // '', headers => { 'Content-Type' => 'text/plain' }, timeout => 15 );
    }
    else {
        $r = http_request( 'GET', $url, timeout => 15 );
    }
    return ( $r->{success}, $r->{success} ? '' : $r->{error} );
}

# Combined result of a unit, based on the latest result of each member.
sub unit_result {
    my ( $cfg, $unit, $results ) = @_;
    my $lang  = BetterStack::WHM::Checks::public_lang($cfg);
    my $alang = admin_lang($cfg);
    my %rank = ( ok => 0, warn => 1, fail => 2 );
    my ( $status, @problems, @public, @body, $ok_services ) = ('ok');
    my $publish_any = 0;
    for my $inst ( @{ $unit->{members} } ) {
        my $r = $results->{ $inst->{id} } or next;
        $status = $r->{status} if $rank{ $r->{status} } > $rank{$status};
        my $ts      = BetterStack::WHM::Checks::type_settings( $cfg, $inst->{type} );
        my $publish = $cfg->{publish_details} && $ts->{publish_details};
        $publish_any ||= $publish;
        if ( $r->{status} ne 'ok' ) {
            push @problems, $STATUS_ICON{ $r->{status} } . $inst->{public_name} . ( $publish ? ': ' . render( $r->{detail}, $lang ) : '' );
            my $info = render( $r->{info}, $alang );
            push @body, "[$r->{status}] " . render_msg( $inst->{name_msg}, $alang ) . ': ' . render( $r->{detail}, $alang ) . ( length $info ? " ($info)" : '' );
        }
        next unless $publish;
        if ( $r->{status} eq 'ok' && $inst->{type} eq 'service' ) { $ok_services++; next }
        next if $r->{status} eq 'ok' && $inst->{type} eq 'server' && $unit->{kind} eq 'cat';    # a bundle that is up says that already
        push @public, $unit->{kind} eq 'item' ? render( $r->{detail}, $lang ) : "$inst->{public_name}: " . render( $r->{detail}, $lang ) if $r->{status} eq 'ok';
    }
    my $public;
    if ( $unit->{kind} eq 'item' ) {
        my $r = $results->{ $unit->{members}[0]{id} } || {};
        $public = $publish_any ? ( $STATUS_ICON{ $r->{status} // 'ok' } // '' ) . render( $r->{detail}, $lang ) : '';
    }
    elsif ($publish_any) {
        unshift @public, tl( $lang, $ok_services == 1 ? 'e.services_1' : 'e.services_n', $ok_services ) if $ok_services;
        $public = join " \x{00B7} ", @problems, @public;    # middle dot, escaped: this file is ASCII-only
    }
    $public //= '';
    $public = substr( $public, 0, $MAX_EXPLANATION - 3 ) . '...' if length $public > $MAX_EXPLANATION;
    return { status => $status, public => $public, body => join( "\n", @body ) };
}

sub _stamp {
    my ( $time, $lang ) = @_;
    my @t = localtime $time;
    return ' ' . tl( $lang, 'e.updated', sprintf( '%02d:%02d', $t[2], $t[1] ) );
}

# Options: force => run every check now, sync => force a sync, only => instance id.
sub run {
    my (%opt) = @_;
    return with_lock(
        sub {
            my $cfg = BetterStack::WHM::Config::load();
            my $st  = BetterStack::WHM::Config::load_state();
            my $ctx = {};
            my $now = time;
            local $BetterStack::WHM::Util::LOG_LANG = admin_lang($cfg);

            my $all        = BetterStack::WHM::Checks::discover_all( $cfg, $ctx );
            my @instances  = grep { $_->{enabled} } @$all;
            my $units      = units( $cfg, \@instances );
            my $configured = BetterStack::WHM::Config::is_configured($cfg);
            my %summary    = ( ok => 1, ran => 0, errors => [] );

            # Provision when the set of units or settings changed.
            if ($configured) {
                my $sig        = signature( $cfg, $units );
                my $needs_sync = $opt{sync} || $sig ne ( $st->{signature} // '' ) || $st->{last_sync_error}
                  || $now - ( $st->{last_sync} // 0 ) >= 6 * 3600;    # periodic check that Better Stack still matches
                my $backoff    = $st->{last_sync_error} && $now - ( $st->{last_sync_attempt} // 0 ) < 900;
                if ( $needs_sync && ( $opt{sync} || $sig ne ( $st->{signature} // '' ) || !$backoff ) ) {
                    $st->{last_sync_attempt} = $now;
                    my $errs = sync( $cfg, $st, $units );
                    $st->{signature} = $sig;
                    if (@$errs) {
                        $st->{last_sync_error} = $errs;    # list of messages, rendered where shown
                        logmsg( error => $_ ) for @$errs;
                        push @{ $summary{errors} }, @$errs;
                    }
                    else {
                        $st->{last_sync_error} = '';
                    }
                }
            }

            my %present = map { $_->{id} => 1 } @$all;
            delete $st->{results}{$_} for grep { !$present{$_} } keys %{ $st->{results} };
            delete @{ $st->{preview} }{ map { $_->{id} } @instances } if $st->{preview};    # live results take over

            # 1. Run the checks that are due.
            my $hist = BetterStack::WHM::History::load();
            for my $inst (@instances) {
                next if $opt{only} && $opt{only} ne $inst->{id};
                my $prev = $st->{results}{ $inst->{id} };
                next unless $opt{force} || !$prev || $now - ( $prev->{at} // 0 ) >= $inst->{interval} - 10;
                my $res = BetterStack::WHM::Checks::run_instance( $cfg, $inst, $ctx );
                $res->{at} = time;
                $summary{ran}++;
                logmsg( warn => "$inst->{id}: $res->{status} - " . render( $res->{detail} ) . ( length render( $res->{info} ) ? ' (' . render( $res->{info} ) . ')' : '' ) ) if $res->{status} ne 'ok';
                $st->{results}{ $inst->{id} } = $res;
                BetterStack::WHM::History::record( $hist, $inst->{id}, $res, $res->{at} );
            }
            if ( $summary{ran} ) {
                BetterStack::WHM::History::prune( $hist, { map { $_->{id} => 1 } @instances }, $now );
                BetterStack::WHM::History::save($hist);
            }

            # 2. Report every unit that is due or whose status changed.
            return finish( $st, $now, \%summary ) unless $configured;
            # Back from a reboot (or past the planned end): end the maintenance first.
            push @{ $summary{errors} }, @{ BetterStack::WHM::Maintenance::end_if_due( $cfg, $st ) };
            my $api;
            for my $unit (@$units) {
                my $it = $st->{items}{ $unit->{key} } or next;
                next unless $it->{heartbeat_url};
                my $ur      = unit_result( $cfg, $unit, $st->{results} );
                my $changed = ( $it->{last_status} // '' ) ne $ur->{status};
                if ( $opt{force} || $changed || $now - ( $it->{last_ping} // 0 ) >= $unit->{interval} - 10 ) {
                    my ( $ok, $err ) = ping( $it, $ur );
                    if ($ok) { $it->{last_ping} = $now; $it->{last_status} = $ur->{status}; delete $it->{ping_error} }
                    else     { $it->{ping_error} = $err; logmsg( error => "Ping $unit->{key}: $err" ) }
                }

                # Live details as help text on the status page.
                next unless $it->{resource_id};
                my $sent = $it->{explanation_sent} // '';
                # explanation_base: last text sent, without the timestamp.
                my $same = defined $it->{explanation_base} ? $ur->{public} eq $it->{explanation_base} : ( $sent eq '' && $ur->{public} eq '' );
                $same = 0 if $ur->{public} eq '' && $sent ne '';    # details switched off: clear the text
                next if $same && !$opt{force};    # a forced run always re-sends (repairs edited texts)
                my $stale = $now - ( $it->{explanation_at} // 0 ) >= ( $cfg->{details_interval} || 300 );
                next unless $opt{force} || $stale || $changed || $sent eq '' || $ur->{public} eq '';
                my $want = $ur->{public} eq '' ? '' : $ur->{public} . _stamp( $now, BetterStack::WHM::Checks::public_lang($cfg) );
                $api ||= BetterStack::WHM::API->from_config($cfg);
                my ( undef, $e ) = $api->update_resource( $st->{status_page_id}, $it->{resource_id}, { explanation => $want } );
                if   ($e) { logmsg( error => "Details $unit->{key}: $e" ) }
                else      { $it->{explanation_sent} = $want; $it->{explanation_base} = $ur->{public}; $it->{explanation_at} = $now }
            }
            return finish( $st, $now, \%summary );
        },
        wait => $opt{wait},
    );
}

# Run checks that are switched off, only to show their result in WHM. Nothing
# is sent to Better Stack, so this never pings a heartbeat or opens an incident.
# Options: only => instance id, type => check type.
sub preview {
    my (%opt) = @_;
    return with_lock(
        sub {
            my $cfg = BetterStack::WHM::Config::load();
            my $st  = BetterStack::WHM::Config::load_state();
            my $ctx = {};
            local $BetterStack::WHM::Util::LOG_LANG = admin_lang($cfg);
            my $all = BetterStack::WHM::Checks::discover_all( $cfg, $ctx, all_types => 1 );
            my %off = map { $_->{id} => 1 } grep { !$_->{enabled} } @$all;
            delete $st->{preview}{$_} for grep { !$off{$_} } keys %{ $st->{preview} || {} };
            my $ran = 0;
            for my $inst ( grep { !$_->{enabled} } @$all ) {
                next if defined $opt{only} && $opt{only} ne $inst->{id};
                next if defined $opt{type} && $opt{type} ne $inst->{type};
                my $res = BetterStack::WHM::Checks::run_instance( $cfg, $inst, $ctx );
                $st->{preview}{ $inst->{id} } = { %$res, at => time, type => $inst->{type}, name_msg => $inst->{name_msg} };
                $ran++;
            }
            BetterStack::WHM::Config::save_state($st);
            return { ok => 1, ran => $ran, errors => [] };
        },
        wait => 1,
    );
}

sub finish {
    my ( $st, $now, $summary ) = @_;
    $st->{last_run} = $now;
    BetterStack::WHM::Config::save_state($st);
    $summary->{ok} = @{ $summary->{errors} } ? 0 : 1;
    return $summary;
}

1;
