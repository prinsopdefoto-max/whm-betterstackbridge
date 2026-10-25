package BetterStack::WHM::Config;

use strict;
use warnings;

use BetterStack::WHM::Util qw(etc_dir var_dir read_json_safe write_json hostname_fqdn);

sub config_path { etc_dir() . '/config.json' }
sub state_path  { var_dir() . '/state.json' }

sub defaults {
    return {
        api_token        => '',
        api_base         => 'https://incidents.betterstack.com/api/v2',
        team_name        => '',
        status_page_id   => '',
        server_label     => '',
        section_mode     => 'single',      # single | category
        alert_email      => 1,
        alert_sms        => 0,
        alert_call       => 0,
        alert_push       => 0,
        grace_pct        => 50,
        publish_details  => 1,
        details_interval => 300,
        delete_removed   => 1,
        maint_enabled    => 1,             # announce reboots as maintenance
        maint_minutes    => 15,            # expected duration of a reboot
        maint_report     => 1,             # maintenance report on the status page
        maint_notify     => 0,             # e-mail status page subscribers about it
        maint_monitors   => [],            # ids of other Better Stack monitors that share the maintenance
        checks           => {},
        instances        => {},
        group_names      => {},
        ui_lang          => 'auto',        # language of the WHM page: auto | nl | en | de
        public_lang      => 'en',          # language of the status page texts
        config_version   => 4,
    };
}

sub load {
    my $cfg = read_json_safe( config_path() ) || { config_version => 4 };
    my $def = defaults();

    # v1 stored "enabled => 1" for every item once the items form was saved,
    # which would hide the newer defaults (internal services and /boot off).
    if ( ( $cfg->{config_version} // 1 ) < 2 ) {
        for my $id ( keys %{ $cfg->{instances} || {} } ) {
            my $ov = $cfg->{instances}{$id};
            delete $ov->{enabled} if ( $ov->{enabled} // 0 ) == 1;
            delete $ov->{public_name} if defined $ov->{public_name} && !length $ov->{public_name};
            delete $cfg->{instances}{$id} unless %$ov;
        }
        $cfg->{config_version} = 2;
    }

    # v3: checks are bundled per category, so one section per category would
    # hold a single item each. Move existing installs to one section per server.
    if ( $cfg->{config_version} < 3 ) {
        $cfg->{section_mode}   = 'single';
        $cfg->{config_version} = 3;
    }
    # v4: English became the default status page language. Installs from before
    # that were Dutch-only, so they keep Dutch unless a language was chosen.
    if ( $cfg->{config_version} < 4 ) {
        $cfg->{public_lang} //= 'nl';
        $cfg->{config_version} = 4;
    }
    for ( keys %$def ) { $cfg->{$_} //= $def->{$_} }
    $cfg->{server_label} ||= hostname_fqdn();
    $cfg->{api_base} =~ s{/+\z}{};
    # Values that end up in request URLs are validated on every load, not only in the form.
    $cfg->{api_base}       = $def->{api_base} unless $cfg->{api_base} =~ m{^https://[A-Za-z0-9.-]+(?:/[A-Za-z0-9._/-]*)?\z};
    $cfg->{status_page_id} = ''               unless $cfg->{status_page_id} =~ /^\d{0,20}\z/;
    return $cfg;
}

sub save {
    my ($cfg) = @_;
    write_json( config_path(), $cfg, 0600 );
}

sub is_configured {
    my ($cfg) = @_;
    return length( $cfg->{api_token} // '' ) && length( $cfg->{status_page_id} // '' ) ? 1 : 0;
}

sub load_state {
    my $st = read_json_safe( state_path() ) || {};
    $st->{items}   ||= {};
    $st->{results} ||= {};
    $st->{sections} ||= {};
    return $st;
}

sub save_state {
    my ($st) = @_;
    write_json( state_path(), $st, 0600 );
}

1;
