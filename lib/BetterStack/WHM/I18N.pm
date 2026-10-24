package BetterStack::WHM::I18N;

# Translations. Texts that are stored (check results, sync errors) are kept
# as messages - [ key, args... ] - and rendered when shown, so the WHM page
# and the public status page can each use their own language.
#
#   T( 'r.queue', 12 )                      current language ($LANG)
#   tl( 'en', 'r.queue', 12 )               explicit language
#   render( $text, $lang )                  stored text -> string
#
# A stored text is a plain string or an arrayref of fragments (joined with
# ", "); a fragment is a plain string or a message [ key, args... ]. An
# argument can be a nested message (arrayref), { dur => seconds } or
# { bytes => n }.

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(T tl render render_msg);

our $LANG = 'nl';
our @LANGS = ( [ nl => 'Nederlands' ], [ en => 'English' ], [ de => 'Deutsch' ] );
my %KNOWN = map { $_->[0] => 1 } @LANGS;

sub valid { defined $_[0] && $KNOWN{ $_[0] } ? 1 : 0 }

# Best language from an Accept-Language header / WHM locale ("nl", "en_US", ...).
sub detect {
    my (@candidates) = @_;
    for my $c ( grep { defined && length } @candidates ) {
        for my $tag ( map { lc( ( split /;/ )[0] ) } split /\s*,\s*/, $c ) {
            $tag =~ s/[-_].*//;
            return $tag if $KNOWN{$tag};
        }
    }
    return undef;
}

our %S;

sub tl {
    my ( $lang, $key, @args ) = @_;
    my $e = $S{$key};
    my $s = $e ? ( $e->{$lang} // $e->{en} // $e->{nl} ) : $key;
    return $s unless @args;
    my @r = map { _arg( $_, $lang ) } @args;
    my $out = eval { no warnings; sprintf( $s, @r ) };
    return defined $out ? $out : $s;
}

sub T { tl( $LANG, @_ ) }

sub _arg {
    my ( $a, $lang ) = @_;
    return $a unless ref $a;
    return render_msg( $a, $lang ) if ref $a eq 'ARRAY';
    if ( ref $a eq 'HASH' ) {
        return duration( $a->{dur}, $lang ) if exists $a->{dur};
        return bytes( $a->{bytes} )         if exists $a->{bytes};
    }
    return '';
}

sub render_msg {
    my ( $m, $lang ) = @_;
    $lang //= $LANG;
    return '' unless defined $m;
    return $m unless ref $m;
    return '' unless ref $m eq 'ARRAY' && @$m;
    return tl( $lang, @$m );
}

sub render {
    my ( $text, $lang ) = @_;
    $lang //= $LANG;
    return '' unless defined $text;
    return $text unless ref $text;
    return '' unless ref $text eq 'ARRAY';
    return join ', ', grep { length } map { render_msg( $_, $lang ) } @$text;
}

sub duration {
    my ( $s, $lang ) = @_;
    $s = 0 if !defined $s || $s < 0;
    return tl( $lang, 'dur.days',  int( $s / 86400 ) ) if $s >= 2 * 86400;
    return tl( $lang, 'dur.hours', int( $s / 3600 ) )  if $s >= 2 * 3600;
    return tl( $lang, 'dur.min',   int( $s / 60 ) )    if $s >= 120;
    return tl( $lang, 'dur.sec',   int $s );
}

sub bytes {
    my ($b) = @_;
    my @u = qw(B KB MB GB TB PB);
    my $i = 0;
    while ( $b >= 1024 && $i < $#u ) { $b /= 1024; $i++ }
    return sprintf( $i ? '%.1f %s' : '%d %s', $b, $u[$i] );
}

# ------------------------------------------------------------------ strings
# Format: key => [ nl, en, de ]

my %RAW = (

    # categories (public)
    'cat.system'   => [ 'Server', 'Server', 'Server' ],
    'cat.services' => [ 'Diensten', 'Services', 'Dienste' ],
    'cat.mail'     => [ 'E-mail', 'Email', 'E-Mail' ],
    'cat.security' => [ 'Beveiliging & back-ups', 'Security & backups', 'Sicherheit & Backups' ],

    # check types (WHM)
    'type.server'    => [ 'Server bereikbaar', 'Server reachable', 'Server erreichbar' ],
    'type.service'   => [ 'cPanel-diensten', 'cPanel services', 'cPanel-Dienste' ],
    'type.load'      => [ 'CPU-belasting', 'CPU load', 'CPU-Last' ],
    'type.memory'    => [ 'Geheugen & swap', 'Memory & swap', 'Arbeitsspeicher & Swap' ],
    'type.disk'      => [ 'Schijfruimte & inodes', 'Disk space & inodes', 'Speicherplatz & Inodes' ],
    'type.mysql'     => [ 'Database bereikbaar', 'Database reachable', 'Datenbank erreichbar' ],
    'type.mailqueue' => [ 'Mailwachtrij', 'Mail queue', 'Mail-Warteschlange' ],
    'type.rbl'       => [ 'Blacklistcontrole', 'Blacklist check', 'Blacklist-Prüfung' ],
    'type.ssl'       => [ 'SSL-certificaten', 'SSL certificates', 'SSL-Zertifikate' ],
    'type.backup'    => [ 'cPanel-back-ups', 'cPanel backups', 'cPanel-Backups' ],
    'type.raid'      => [ 'Software-RAID', 'Software RAID', 'Software-RAID' ],

    'typedesc.server'    => [ 'Teken van leven van de server; valt weg als de server uitvalt.', 'Sign of life from the server; stops when the server goes down.', 'Lebenszeichen des Servers; bleibt aus, wenn der Server ausfällt.' ],
    'typedesc.service'   => [ 'Elke ingeschakelde cPanel-dienst, via chkservd.', 'Every enabled cPanel service, via chkservd.', 'Jeder aktivierte cPanel-Dienst, über chkservd.' ],
    'typedesc.load'      => [ 'Gemiddelde belasting over 5 minuten, per CPU-core.', '5-minute load average per CPU core.', '5-Minuten-Lastdurchschnitt pro CPU-Kern.' ],
    'typedesc.memory'    => [ 'Gebruikt werkgeheugen (op basis van MemAvailable).', 'Memory in use (based on MemAvailable).', 'Belegter Arbeitsspeicher (basierend auf MemAvailable).' ],
    'typedesc.disk'      => [ 'Vrije ruimte en inodes, per lokale partitie.', 'Free space and inodes, per local partition.', 'Freier Speicher und Inodes, je lokaler Partition.' ],
    'typedesc.mysql'     => [ 'Verbindt met MySQL/MariaDB via mysqladmin.', 'Connects to MySQL/MariaDB via mysqladmin.', 'Verbindet sich über mysqladmin mit MySQL/MariaDB.' ],
    'typedesc.mailqueue' => [ 'Aantal berichten in de Exim-wachtrij.', 'Number of messages in the Exim queue.', 'Anzahl Nachrichten in der Exim-Warteschlange.' ],
    'typedesc.rbl'       => [ 'Controleert of het server-IP op een blacklist staat.', 'Checks whether the server IP is on a blacklist.', 'Prüft, ob die Server-IP auf einer Blacklist steht.' ],
    'typedesc.ssl'       => [ 'Geïnstalleerde en AutoSSL-certificaten die bijna verlopen.', 'Installed and AutoSSL certificates that are about to expire.', 'Installierte und AutoSSL-Zertifikate, die bald ablaufen.' ],
    'typedesc.backup'    => [ 'Resultaat en leeftijd van de laatste cPanel-back-up.', 'Result and age of the latest cPanel backup.', 'Ergebnis und Alter des letzten cPanel-Backups.' ],
    'typedesc.raid'      => [ 'Status van mdadm-arrays uit /proc/mdstat.', 'State of mdadm arrays from /proc/mdstat.', 'Zustand der mdadm-Arrays aus /proc/mdstat.' ],

    # parameters
    'param.warn_per_cpu'    => [ 'Waarschuwing (load/core)', 'Warning (load/core)', 'Warnung (Last/Kern)' ],
    'param.crit_per_cpu'    => [ 'Storing (load/core)', 'Outage (load/core)', 'Störung (Last/Kern)' ],
    'param.warn_pct'        => [ 'Waarschuwing (%)', 'Warning (%)', 'Warnung (%)' ],
    'param.crit_pct'        => [ 'Storing (%)', 'Outage (%)', 'Störung (%)' ],
    'param.inode_warn_pct'  => [ 'Inodes waarschuwing (%)', 'Inodes warning (%)', 'Inodes Warnung (%)' ],
    'param.inode_crit_pct'  => [ 'Inodes storing (%)', 'Inodes outage (%)', 'Inodes Störung (%)' ],
    'param.warn'            => [ 'Waarschuwing (berichten)', 'Warning (messages)', 'Warnung (Nachrichten)' ],
    'param.crit'            => [ 'Storing (berichten)', 'Outage (messages)', 'Störung (Nachrichten)' ],
    'param.lists'           => [ 'Blacklists', 'Blacklists', 'Blacklists' ],
    'param.extra_ips'       => [ "Extra IP-adressen", 'Extra IP addresses', 'Zusätzliche IP-Adressen' ],
    'param.warn_days'       => [ 'Waarschuwing (dagen)', 'Warning (days)', 'Warnung (Tage)' ],
    'param.crit_days'       => [ 'Storing (dagen)', 'Outage (days)', 'Störung (Tage)' ],
    'param.max_age_hours'   => [ 'Maximale leeftijd (uur)', 'Maximum age (hours)', 'Maximales Alter (Stunden)' ],
    'param.partial_is_fail' => [ 'Gedeeltelijk mislukt telt als storing', 'Partial failure counts as outage', 'Teilweiser Fehler zählt als Störung' ],
    'param.skip_suspended'  => [ 'Geschorste accounts uitsluiten', 'Exclude suspended accounts', 'Gesperrte Konten ausschließen' ],

    # instance names (public)
    'name.server'    => [ 'Server', 'Server', 'Server' ],
    'name.load'      => [ 'Processorbelasting', 'CPU load', 'CPU-Auslastung' ],
    'name.memory'    => [ 'Werkgeheugen', 'Memory', 'Arbeitsspeicher' ],
    'name.disk'      => [ 'Opslag %s', 'Storage %s', 'Speicher %s' ],
    'name.mysql'     => [ 'Databaseverbindingen', 'Database connections', 'Datenbankverbindungen' ],
    'name.mailqueue' => [ 'Mailwachtrij', 'Mail queue', 'Mail-Warteschlange' ],
    'name.rbl'       => [ 'E-mailreputatie (blacklists)', 'Email reputation (blacklists)', 'E-Mail-Reputation (Blacklists)' ],
    'name.ssl'       => [ 'SSL-certificaten', 'SSL certificates', 'SSL-Zertifikate' ],
    'name.backup'    => [ 'Back-ups', 'Backups', 'Backups' ],
    'name.raid'      => [ 'RAID %s', 'RAID %s', 'RAID %s' ],

    # cPanel services (public)
    'svc.httpd'               => [ 'Webserver', 'Web server', 'Webserver' ],
    'svc.apache_php_fpm'      => [ 'PHP-FPM', 'PHP-FPM', 'PHP-FPM' ],
    'svc.mysql'               => [ 'Database (MySQL/MariaDB)', 'Database (MySQL/MariaDB)', 'Datenbank (MySQL/MariaDB)' ],
    'svc.postgresql'          => [ 'Database (PostgreSQL)', 'Database (PostgreSQL)', 'Datenbank (PostgreSQL)' ],
    'svc.exim'                => [ 'E-mail verzenden (SMTP)', 'Outgoing email (SMTP)', 'E-Mail-Versand (SMTP)' ],
    'svc.dovecot'             => [ 'E-mail ontvangen (IMAP/POP3)', 'Incoming email (IMAP/POP3)', 'E-Mail-Empfang (IMAP/POP3)' ],
    'svc.imap'                => [ 'E-mail ontvangen (IMAP/POP3)', 'Incoming email (IMAP/POP3)', 'E-Mail-Empfang (IMAP/POP3)' ],
    'svc.named'               => [ 'DNS', 'DNS', 'DNS' ],
    'svc.pdns'                => [ 'DNS', 'DNS', 'DNS' ],
    'svc.ftpd'                => [ 'FTP', 'FTP', 'FTP' ],
    'svc.ftpserver'           => [ 'FTP', 'FTP', 'FTP' ],
    'svc.cpsrvd'              => [ 'cPanel / WHM / Webmail', 'cPanel / WHM / Webmail', 'cPanel / WHM / Webmail' ],
    'svc.cpdavd'              => [ 'Agenda & contacten (CalDAV/CardDAV)', 'Calendars & contacts (CalDAV/CardDAV)', 'Kalender & Kontakte (CalDAV/CardDAV)' ],
    'svc.cphulkd'             => [ 'Brute-forcebescherming (cPHulk)', 'Brute-force protection (cPHulk)', 'Brute-Force-Schutz (cPHulk)' ],
    'svc.spamd'               => [ 'Spamfilter', 'Spam filter', 'Spamfilter' ],
    'svc.sshd'                => [ 'SSH', 'SSH', 'SSH' ],
    'svc.crond'               => [ 'Geplande taken (cron)', 'Scheduled tasks (cron)', 'Geplante Aufgaben (cron)' ],
    'svc.nscd'                => [ 'Name service cache', 'Name service cache', 'Name-Service-Cache' ],
    'svc.cpanel-dovecot-solr' => [ 'E-mailzoekindex', 'Email search index', 'E-Mail-Suchindex' ],
    'svc.lsws'                => [ 'Webserver (LiteSpeed)', 'Web server (LiteSpeed)', 'Webserver (LiteSpeed)' ],
    'svc.nginx'               => [ 'Reverse proxy (NGINX)', 'Reverse proxy (NGINX)', 'Reverse Proxy (NGINX)' ],
    'svc.redis'               => [ 'Redis', 'Redis', 'Redis' ],
    'svc.memcached'           => [ 'Memcached', 'Memcached', 'Memcached' ],
    'svc.clamd'               => [ 'Virusscanner (ClamAV)', 'Virus scanner (ClamAV)', 'Virenscanner (ClamAV)' ],
    'svc.mailman'             => [ 'Mailinglijsten', 'Mailing lists', 'Mailinglisten' ],

    # check results
    'r.online'           => [ 'Online', 'Online', 'Online' ],
    'r.uptime'           => [ 'uptime %s', 'uptime %s', 'Laufzeit %s' ],
    'r.active'           => [ 'Actief', 'Running', 'Aktiv' ],
    'r.inactive'         => [ 'Niet actief', 'Not running', 'Nicht aktiv' ],
    'r.unknown_status'   => [ 'Status onbekend', 'Status unknown', 'Status unbekannt' ],
    'r.svc_missing'      => [ 'Dienst niet gevonden in servicestatus', 'Service not found in service status', 'Dienst nicht im Dienststatus gefunden' ],
    'r.svc_down_info'    => [ '%s draait niet volgens chkservd', '%s is not running according to chkservd', '%s läuft laut chkservd nicht' ],
    'r.load'             => [ 'Load %s / %s / %s (%d cores, %d%% benut)', 'Load %s / %s / %s (%d cores, %d%% used)', 'Last %s / %s / %s (%d Kerne, %d%% ausgelastet)' ],
    'r.mem'              => [ '%d%% in gebruik (%s van %s)', '%d%% used (%s of %s)', '%d%% belegt (%s von %s)' ],
    'r.swap'             => [ 'swap %d%%', 'swap %d%%', 'Swap %d%%' ],
    'r.disk'             => [ '%d%% vol (%s vrij van %s)', '%d%% full (%s free of %s)', '%d%% belegt (%s frei von %s)' ],
    'r.inodes'           => [ 'inodes %d%%', 'inodes %d%%', 'Inodes %d%%' ],
    'r.disk_missing'     => [ 'Partitie niet gevonden', 'Partition not found', 'Partition nicht gefunden' ],
    'r.disk_missing_info'=> [ '%s niet gemount', '%s not mounted', '%s nicht eingehängt' ],
    'r.db_down'          => [ 'Database niet bereikbaar', 'Database unreachable', 'Datenbank nicht erreichbar' ],
    'r.db_ok'            => [ 'Bereikbaar', 'Reachable', 'Erreichbar' ],
    'r.db_conns'         => [ '%d verbindingen', '%d connections', '%d Verbindungen' ],
    'r.db_qps'           => [ '%s queries/s', '%s queries/s', '%s Abfragen/s' ],
    'r.slow'             => [ 'Trage queries: %d', 'Slow queries: %d', 'Langsame Abfragen: %d' ],
    'r.queue'            => [ '%d berichten in de wachtrij', '%d messages in the queue', '%d Nachrichten in der Warteschlange' ],
    'r.rbl_listed'       => [ 'Vermeld op %d blacklist(s)', 'Listed on %d blacklist(s)', 'Auf %d Blacklist(s) gelistet' ],
    'r.rbl_listed_item'  => [ '%s op %s (%s)', '%s on %s (%s)', '%s auf %s (%s)' ],
    'r.rbl_unknown'      => [ 'Niet betrouwbaar te controleren via de DNS-resolver van deze server: %s (publieke resolvers worden door o.a. Spamhaus geweigerd; gebruik een eigen resolver)',
                              "Cannot be checked reliably via this server's DNS resolver: %s (public resolvers are refused by Spamhaus and others; use your own resolver)",
                              'Über den DNS-Resolver dieses Servers nicht zuverlässig prüfbar: %s (öffentliche Resolver werden u. a. von Spamhaus abgelehnt; eigenen Resolver verwenden)' ],
    'r.rbl_cannot'       => [ 'Blacklists niet te controleren', 'Blacklists cannot be checked', 'Blacklists nicht prüfbar' ],
    'r.rbl_clean_1'      => [ 'Niet vermeld (%d lijst gecontroleerd)', 'Not listed (%d list checked)', 'Nicht gelistet (%d Liste geprüft)' ],
    'r.rbl_clean_n'      => [ 'Niet vermeld (%d lijsten gecontroleerd)', 'Not listed (%d lists checked)', 'Nicht gelistet (%d Listen geprüft)' ],
    'r.ssl_none'         => [ 'Geen certificaten gevonden', 'No certificates found', 'Keine Zertifikate gefunden' ],
    'r.ssl_count'        => [ '%d certificaten', '%d certificates', '%d Zertifikate' ],
    'r.ssl_next'         => [ 'eerstvolgende verloopt over %d dagen', 'next one expires in %d days', 'nächstes läuft in %d Tagen ab' ],
    'r.ssl_soon'         => [ '%d verlopen binnenkort', '%d expiring soon', '%d laufen bald ab' ],
    'r.ssl_crit'         => [ 'Kritiek: %s', 'Critical: %s', 'Kritisch: %s' ],
    'r.ssl_warn'         => [ 'Waarschuwing: %s', 'Warning: %s', 'Warnung: %s' ],
    'r.ssl_first'        => [ 'Eerstvolgende: %s', 'Next: %s', 'Nächstes: %s' ],
    'r.ssl_skipped'      => [ '%d certificaten van geschorste accounts overgeslagen', '%d certificates of suspended accounts skipped', '%d Zertifikate gesperrter Konten übersprungen' ],
    'r.backup_none'      => [ 'Geen back-up gevonden', 'No backup found', 'Kein Backup gefunden' ],
    'r.backup_nologs'    => [ 'Geen logs in %s', 'No logs in %s', 'Keine Logs in %s' ],
    'r.backup_failed'    => [ 'Mislukt, laatste %s geleden', 'Failed, last one %s ago', 'Fehlgeschlagen, letztes vor %s' ],
    'r.backup_partial'   => [ 'Gedeeltelijk geslaagd, laatste %s geleden', 'Partially succeeded, last one %s ago', 'Teilweise erfolgreich, letztes vor %s' ],
    'r.backup_running'   => [ 'Bezig, laatste %s geleden', 'In progress, last one %s ago', 'Läuft, letztes vor %s' ],
    'r.backup_ok'        => [ 'Geslaagd, laatste %s geleden', 'Succeeded, last one %s ago', 'Erfolgreich, letztes vor %s' ],
    'r.backup_old'       => [ 'Te oud: laatste %s geleden', 'Too old: last one %s ago', 'Zu alt: letztes vor %s' ],
    'r.raid_missing'     => [ 'Array niet gevonden', 'Array not found', 'Array nicht gefunden' ],
    'r.raid_degraded'    => [ 'Gedegradeerd (%s)%s', 'Degraded (%s)%s', 'Degradiert (%s)%s' ],
    'r.raid_ok'          => [ 'Gezond (%s)%s', 'Healthy (%s)%s', 'Intakt (%s)%s' ],
    'r.check_failed'     => [ 'Controle mislukt', 'Check failed', 'Prüfung fehlgeschlagen' ],

    'err.read'     => [ 'Kan %s niet lezen', 'Cannot read %s', '%s kann nicht gelesen werden' ],
    'err.notfound' => [ '%s niet gevonden', '%s not found', '%s nicht gefunden' ],
    'err.cmd'      => [ '%s mislukt: %s', '%s failed: %s', '%s fehlgeschlagen: %s' ],
    'err.noip'     => [ 'Geen server-IP gevonden', 'No server IP found', 'Keine Server-IP gefunden' ],
    'err.timeout'  => [ 'Time-out', 'Timed out', 'Zeitüberschreitung' ],
    'err.unknown'  => [ 'Onbekende fout', 'Unknown error', 'Unbekannter Fehler' ],

    'dur.days'  => [ '%d dagen', '%d days', '%d Tagen' ],
    'dur.hours' => [ '%d uur', '%d hours', '%d Stunden' ],
    'dur.min'   => [ '%d min', '%d min', '%d Min.' ],
    'dur.sec'   => [ '%d s', '%d s', '%d s' ],

    # engine
    'e.services_1'   => [ '%d dienst actief', '%d service running', '%d Dienst aktiv' ],
    'e.services_n'   => [ '%d diensten actief', '%d services running', '%d Dienste aktiv' ],
    'e.updated'      => [ '(bijgewerkt %s)', '(updated %s)', '(aktualisiert %s)' ],
    'e.err'          => [ '%s: %s', '%s: %s', '%s: %s' ],
    'e.busy'         => [ 'Er draait al een controle, probeer het zo opnieuw.', 'A check is already running, please try again shortly.', 'Es läuft bereits eine Prüfung, bitte gleich erneut versuchen.' ],
    'e.quota'        => [ "Heartbeat-limiet van je Better Stack-abonnement bereikt bij '%s'. Bundel meer items (zet 'Eigen heartbeat' uit), zet controles uit of verwijder ongebruikte heartbeats in Better Stack.",
                          "Heartbeat limit of your Better Stack plan reached at '%s'. Bundle more items (turn off 'Own heartbeat'), disable checks or delete unused heartbeats in Better Stack.",
                          "Heartbeat-Limit Ihres Better-Stack-Tarifs bei '%s' erreicht. Bündeln Sie mehr Elemente ('Eigener Heartbeat' ausschalten), deaktivieren Sie Prüfungen oder löschen Sie ungenutzte Heartbeats in Better Stack." ],
    'e.unexpected'   => [ '%s: onverwacht antwoord van de API', '%s: unexpected API response', '%s: unerwartete API-Antwort' ],
    'e.del_item'     => [ 'Item %s verwijderen', 'Delete item %s', 'Element %s löschen' ],
    'e.del_hb'       => [ 'Heartbeat %s verwijderen', 'Delete heartbeat %s', 'Heartbeat %s löschen' ],
    'e.create_group' => [ 'Heartbeat-groep aanmaken', 'Create heartbeat group', 'Heartbeat-Gruppe anlegen' ],
    'e.create_sec'   => [ "Sectie '%s' aanmaken", "Create section '%s'", "Abschnitt '%s' anlegen" ],
    'e.update_hb'    => [ "Heartbeat '%s' bijwerken", "Update heartbeat '%s'", "Heartbeat '%s' aktualisieren" ],
    'e.create_hb'    => [ "Heartbeat '%s' aanmaken", "Create heartbeat '%s'", "Heartbeat '%s' anlegen" ],
    'e.update_res'   => [ "Statuspagina-item '%s' bijwerken", "Update status page item '%s'", "Statusseiten-Element '%s' aktualisieren" ],
    'e.create_res'   => [ "Statuspagina-item '%s' aanmaken", "Create status page item '%s'", "Statusseiten-Element '%s' anlegen" ],
    'e.del_sec'      => [ 'Sectie %s verwijderen', 'Delete section %s', 'Abschnitt %s löschen' ],
    'e.del_group'    => [ 'Heartbeat-groep verwijderen', 'Delete heartbeat group', 'Heartbeat-Gruppe löschen' ],
    'e.orphan_hb'    => [ "Overbodige heartbeat '%s' verwijderen", "Delete obsolete heartbeat '%s'", "Überflüssigen Heartbeat '%s' löschen" ],
    'e.orphan_res'   => [ 'Overbodig statuspagina-item verwijderen', 'Delete obsolete status page item', 'Überflüssiges Statusseiten-Element löschen' ],
    'e.orphan_sec'   => [ "Overbodige sectie '%s' verwijderen", "Delete obsolete section '%s'", "Überflüssigen Abschnitt '%s' löschen" ],
    'e.orphan_grp'   => [ 'Overbodige heartbeat-groep verwijderen', 'Delete obsolete heartbeat group', 'Überflüssige Heartbeat-Gruppe löschen' ],

    'log.hb_created'      => [ 'Heartbeat aangemaakt: %s (%s)', 'Heartbeat created: %s (%s)', 'Heartbeat angelegt: %s (%s)' ],
    'log.hb_deleted'      => [ 'Heartbeat verwijderd: %s', 'Heartbeat deleted: %s', 'Heartbeat gelöscht: %s' ],
    'log.group_adopted'   => [ 'Bestaande heartbeat-groep overgenomen: %s (%s)', 'Adopted existing heartbeat group: %s (%s)', 'Bestehende Heartbeat-Gruppe übernommen: %s (%s)' ],
    'log.section_adopted' => [ 'Bestaande sectie overgenomen: %s', 'Adopted existing section: %s', 'Bestehenden Abschnitt übernommen: %s' ],
    'log.hb_adopted'      => [ 'Bestaande heartbeat overgenomen: %s (%s)', 'Adopted existing heartbeat: %s (%s)', 'Bestehenden Heartbeat übernommen: %s (%s)' ],
    'log.orphan_hb'       => [ 'Overbodige heartbeat verwijderd: %s (%s)', 'Removed obsolete heartbeat: %s (%s)', 'Überflüssigen Heartbeat entfernt: %s (%s)' ],
    'log.orphan_sec'      => [ 'Overbodige sectie verwijderd: %s', 'Removed obsolete section: %s', 'Überflüssigen Abschnitt entfernt: %s' ],
);

for my $k ( keys %RAW ) {
    my ( $nl, $en, $de ) = @{ $RAW{$k} };
    $S{$k} = { nl => $nl, en => $en, de => $de };
}

# Further string tables (e.g. the WHM page) register themselves here.
sub add {
    my (%more) = @_;
    for my $k ( keys %more ) {
        my ( $nl, $en, $de ) = @{ $more{$k} };
        $S{$k} = { nl => $nl, en => $en, de => $de };
    }
}

1;
