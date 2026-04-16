# =============================================================================
# mail.pl — WHM MailGuard: Sección de blacklist de correos
# https://github.com/MotionPulseWs/whm-mailguard
# =============================================================================

# ── Rutas de archivos Exim ──
my $DOMAINS_FILE   = '/etc/blocked_incoming_email_domains';
my $IPS_FILE       = '/etc/spammeripblocks';
my $WHITELIST_FILE = '/etc/mailguard_mail_whitelist';

# ── Funciones de lectura/escritura ──
sub read_file_lines {
    my ($file) = @_;
    return () unless -f $file;
    open(my $fh, '<', $file) or return ();
    my @lines = grep { /\S/ && !/^#/ } <$fh>;
    close($fh);
    chomp @lines;
    return @lines;
}

sub write_file_lines {
    my ($file, @lines) = @_;
    open(my $fh, '>', $file) or return 0;
    print $fh "# MailGuard - Blacklist\n";
    print $fh "# Modificado: " . localtime() . "\n\n";
    for my $line (@lines) {
        print $fh "$line\n" if $line =~ /\S/;
    }
    close($fh);
    return 1;
}

sub restart_exim {
    system("/scripts/restartsrv_exim > /dev/null 2>&1 &");
}

# ── Detectar si una IP es privada/reservada ──
sub is_private_ip {
    my ($ip) = @_;

    # IPv4-mapped IPv6: ::ffff:192.168.x.x etc
    if ($ip =~ /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i) {
        $ip = $1;
    }

    # IPv6 puro con rango privado embebido como [ipv6:::ffff:x.x.x.x]
    if ($ip =~ /^\[?ipv6:::ffff:(\d+\.\d+\.\d+\.\d+)\]?$/i) {
        $ip = $1;
    }

    return 0 unless $ip =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/;
    my ($a, $b, $c, $d) = ($1, $2, $3, $4);

    return 1 if $a == 10;                                    # 10.0.0.0/8
    return 1 if $a == 127;                                   # 127.0.0.0/8
    return 1 if $a == 172 && $b >= 16 && $b <= 31;          # 172.16.0.0/12
    return 1 if $a == 192 && $b == 168;                      # 192.168.0.0/16
    return 1 if $a == 169 && $b == 254;                      # 169.254.0.0/16 link-local
    return 1 if $a == 0;                                     # 0.0.0.0/8
    return 0;
}

# ── GeoIP lookup ──
sub geo_lookup {
    my ($ip) = @_;
    my $result = `geoiplookup "$ip" 2>/dev/null`;
    if ($result =~ /:\s*([A-Z]{2}),\s*(.+)$/) {
        my $code    = $1;
        my $country = $2;
        $country =~ s/^\s+|\s+$//g;
        return ($code, $country);
    }
    return ('??', 'Desconocido');
}

# ── Acciones AJAX ──
my $action = $form{action} || '';
my $entry  = $form{entry}  || '';
my $type   = $form{type}   || '';

# ── GeoIP por AJAX ──
if ($action eq 'geo_lookup' && $entry) {
    print "Content-type: application/json\r\n\r\n";
    my ($code, $country) = geo_lookup($entry);
    # Escapar comillas en nombre de país
    $country =~ s/"/\\"/g;
    print "{\"success\":1,\"code\":\"$code\",\"country\":\"$country\"}";
    exit;
}

# Agregar a whitelist
if ($action eq 'wl_add' && $entry) {
    print "Content-type: application/json\r\n\r\n";
    $entry =~ s/^\s+|\s+$//g;
    my @lines = read_file_lines($WHITELIST_FILE);
    if (grep { $_ eq $entry } @lines) {
        print '{"success":0,"error":"Ya existe en la whitelist"}';
    } else {
        push @lines, $entry;
        if (write_file_lines($WHITELIST_FILE, @lines)) {
            print '{"success":1}';
        } else {
            print '{"success":0,"error":"No se pudo escribir el archivo"}';
        }
    }
    exit;
}

# Eliminar de whitelist
if ($action eq 'wl_remove' && $entry) {
    print "Content-type: application/json\r\n\r\n";
    $entry =~ s/^\s+|\s+$//g;
    my @lines = read_file_lines($WHITELIST_FILE);
    my @new   = grep { $_ ne $entry } @lines;
    if (scalar(@new) == scalar(@lines)) {
        print '{"success":0,"error":"Entrada no encontrada"}';
    } else {
        if (write_file_lines($WHITELIST_FILE, @new)) {
            print '{"success":1}';
        } else {
            print '{"success":0,"error":"No se pudo escribir el archivo"}';
        }
    }
    exit;
}

# Agregar dominio o IP a blacklist
if ($action eq 'bl_add' && $entry && $type) {
    print "Content-type: application/json\r\n\r\n";
    $entry =~ s/^\s+|\s+$//g;

    my $file = $type eq 'domain' ? $DOMAINS_FILE : $IPS_FILE;
    my @lines = read_file_lines($file);

    if (grep { $_ eq $entry } @lines) {
        print '{"success":0,"error":"Ya existe en la lista"}';
    } else {
        push @lines, $entry;
        if (write_file_lines($file, @lines)) {
            restart_exim();
            print '{"success":1}';
        } else {
            print '{"success":0,"error":"No se pudo escribir el archivo"}';
        }
    }
    exit;
}

# Eliminar dominio o IP de blacklist
if ($action eq 'bl_remove' && $entry && $type) {
    print "Content-type: application/json\r\n\r\n";
    $entry =~ s/^\s+|\s+$//g;

    my $file = $type eq 'domain' ? $DOMAINS_FILE : $IPS_FILE;
    my @lines = read_file_lines($file);
    my @new   = grep { $_ ne $entry } @lines;

    if (scalar(@new) == scalar(@lines)) {
        print '{"success":0,"error":"Entrada no encontrada"}';
    } else {
        if (write_file_lines($file, @new)) {
            restart_exim();
            print '{"success":1}';
        } else {
            print '{"success":0,"error":"No se pudo escribir el archivo"}';
        }
    }
    exit;
}

# Analizar logs para sugerir dominios e IPs sospechosas
if ($action eq 'bl_analyze') {
    print "Content-type: application/json\r\n\r\n";

    my @blocked_domains = read_file_lines($DOMAINS_FILE);
    my @blocked_ips     = read_file_lines($IPS_FILE);
    my @whitelist       = read_file_lines($WHITELIST_FILE);

    my %already_blocked = map { $_ => 1 } (@blocked_domains, @blocked_ips);
    my %whitelisted     = map { $_ => 1 } @whitelist;

    # ── Proveedores legítimos conocidos ──
    my %legit_providers = map { $_ => 1 } qw(
        gmail.com google.com googlemail.com
        outlook.com hotmail.com live.com microsoft.com
        yahoo.com ymail.com
        amazonses.com amazon.com amazonaws.com
        sendgrid.net sendgrid.com
        mailchimp.com mandrillapp.com
        protection.outlook.com prod.outlook.com
        smtp.gmail.com
        icloud.com me.com mac.com
        protonmail.com proton.me
        zoho.com
    );

    # ── Dominios propios del servidor ──
    my %own_domains = map { $_ => 1 } qw(
        localhost localdomain localhost.localdomain
        server.motionpulse.company motionpulse.company
        motionpulse.net motionpulse.xyz motionpulse.online
    );

    my %domain_count;
    my %ip_count;

    open(my $log, '<', '/var/log/exim_mainlog') or do {
        print '{"success":0,"error":"No se pudo leer el log de Exim"}';
        exit;
    };

    while (my $line = <$log>) {
        next unless $line =~ /H=\(([^)]+)\)\s+\[([^\]]+)\]/;
        my $helo = lc($1);
        my $ip   = $2;

        # ── Detectar IPs sospechosas ──
        if ($ip =~ /^\d+\.\d+\.\d+\.\d+$/ || $ip =~ /^[0-9a-fA-F:]+$/) {
            if ($helo =~ /^\[?\d+\.\d+\.\d+\.\d+\]?$/ || $helo !~ /\./) {
                next if $already_blocked{$ip};
                next if $whitelisted{$ip};
                next if is_private_ip($ip);
                # Filtrar IPv6 de redes privadas/link-local
                next if $ip =~ /^::1$/i;                    # loopback IPv6
                next if $ip =~ /^fe80:/i;                   # link-local IPv6
                next if $ip =~ /^fc00:/i;                   # unique local IPv6
                next if $ip =~ /^fd/i;                      # unique local IPv6
                # Filtrar HELO que contiene IPv4 privada embebida
                next if $helo =~ /::ffff:(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/i;
                next if $helo =~ /^\[?ipv6:::ffff:/i && is_private_ip((split(/::ffff:/, lc($helo)))[-1]);
                $ip_count{$ip}++;
                next;
            }
        }

        # ── Detectar dominios sospechosos ──
        my $domain = $helo;
        $domain =~ s/^\[|\]$//g;
        $domain =~ s/^[^.]+\.//;

        next if $already_blocked{$helo};
        next if $whitelisted{$helo};
        next if $legit_providers{$domain} || $legit_providers{$helo};
        next if $own_domains{$helo} || $own_domains{$domain};
        next if $helo =~ /outlook\.com$|gmail\.com$|google\.com$|amazonaws\.com$|protection\.outlook\.com$/;

        $domain_count{$helo}++;
    }
    close($log);

    # ── Top 10 de cada tipo ──
    my @top_domains = (sort { $domain_count{$b} <=> $domain_count{$a} } keys %domain_count)[0..9];
    my @top_ips     = (sort { $ip_count{$b}     <=> $ip_count{$a}     } keys %ip_count)[0..9];

    @top_domains = grep { defined } @top_domains;
    @top_ips     = grep { defined } @top_ips;

    my @results;
    for my $d (@top_domains) {
        # Detectar país por TLD para dominios
        my $tld = '';
        if ($d =~ /\.([a-z]{2})$/) { $tld = uc($1); }
        (my $entry_json = $d) =~ s/"/\\"/g;
        push @results, "{\"entry\":\"$entry_json\",\"count\":$domain_count{$d},\"type\":\"domain\",\"tld\":\"$tld\"}";
    }
    for my $ip (@top_ips) {
        (my $ip_json = $ip) =~ s/"/\\"/g;
        # country se resolverá en el frontend vía geo_lookup
        push @results, "{\"entry\":\"$ip_json\",\"count\":$ip_count{$ip},\"type\":\"ip\",\"country\":null}";
    }

    my $json = '[' . join(',', @results) . ']';
    print "{\"success\":1,\"suggestions\":$json}";
    exit;
}

# ── Leer datos actuales ──
my @blocked_domains = read_file_lines($DOMAINS_FILE);
my @blocked_ips     = read_file_lines($IPS_FILE);
my @whitelist_items = read_file_lines($WHITELIST_FILE);

my $total_domains   = scalar(@blocked_domains);
my $total_ips       = scalar(@blocked_ips);
my $total_whitelist = scalar(@whitelist_items);

# ── Construir filas HTML ──
my $rows_domains = '';
for my $d (@blocked_domains) {
    $rows_domains .= "<tr><td><span class=\"mg-ip\">$d</span></td><td><button class=\"mg-btn mg-btn-sm mg-btn-danger\" onclick=\"blRemove('$d','domain')\">Eliminar</button></td></tr>\n";
}
$rows_domains ||= '<tr><td colspan="2" style="color:#586069;text-align:center">Sin dominios bloqueados</td></tr>';

my $rows_ips = '';
for my $ip (@blocked_ips) {
    $rows_ips .= "<tr><td><span class=\"mg-ip\">$ip</span></td><td><button class=\"mg-btn mg-btn-sm mg-btn-danger\" onclick=\"blRemove('$ip','ip')\">Eliminar</button></td></tr>\n";
}
$rows_ips ||= '<tr><td colspan="2" style="color:#586069;text-align:center">Sin IPs bloqueadas</td></tr>';

my $rows_whitelist = '';
for my $w (@whitelist_items) {
    $rows_whitelist .= "<tr><td><span class=\"mg-ip\">$w</span></td><td><button class=\"mg-btn mg-btn-sm mg-btn-warning\" onclick=\"wlRemove('$w')\">Quitar</button></td></tr>\n";
}
$rows_whitelist ||= '<tr><td colspan="2" style="color:#586069;text-align:center">Sin entradas en whitelist</td></tr>';

# ── Generar HTML ──
my $html = <<HTML;
<style>
*{box-sizing:border-box}
.mg-nav{display:flex;gap:8px;margin-bottom:24px}
.mg-nav-btn{padding:10px 24px;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;border:2px solid #1a6fc4;background:#fff;color:#1a6fc4;text-decoration:none;transition:all .2s}
.mg-nav-btn.active{background:#1a6fc4;color:#fff}
.mg-nav-btn:hover{opacity:.85}
.mg-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-bottom:24px}
.mg-stat{background:#fff;border:1px solid #d1d5da;border-radius:8px;padding:16px 20px;border-left:4px solid #cb2431}
.mg-stat.mg-blue{border-left-color:#1a6fc4}
.mg-stat.mg-green{border-left-color:#22863a}
.mg-stat-val{font-size:28px;font-weight:700;color:#1a1a2e}
.mg-stat-lbl{font-size:12px;color:#586069;margin-top:4px}
.mg-tabs{display:flex;gap:4px;margin-bottom:16px;background:#f6f8fa;border:1px solid #d1d5da;padding:4px;border-radius:8px;width:fit-content}
.mg-tab{padding:8px 18px;border-radius:6px;cursor:pointer;font-size:13px;font-weight:500;color:#586069;border:none;background:transparent}
.mg-tab.active{background:#1a6fc4;color:#fff}
.mg-panel{display:none}
.mg-panel.active{display:block}
.mg-search{display:flex;gap:8px;margin-bottom:16px}
.mg-search input{flex:1;padding:9px 14px;border:1px solid #d1d5da;border-radius:6px;font-size:14px}
.mg-btn{padding:9px 16px;border:none;border-radius:6px;font-size:13px;font-weight:600;cursor:pointer}
.mg-btn:hover{opacity:.85}
.mg-btn-blue{background:#1a6fc4;color:#fff}
.mg-btn-danger{background:#cb2431;color:#fff}
.mg-btn-warning{background:#f59e0b;color:#fff}
.mg-btn-success{background:#22863a;color:#fff}
.mg-btn-sm{padding:5px 10px;font-size:12px}
.mg-table-wrap{background:#fff;border:1px solid #d1d5da;border-radius:8px;overflow:hidden;margin-bottom:16px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#f6f8fa;padding:10px 14px;text-align:left;font-size:11px;font-weight:600;color:#586069;text-transform:uppercase;border-bottom:1px solid #d1d5da}
td{padding:10px 14px;border-top:1px solid #f0f0f0;vertical-align:middle}
tr:hover td{background:#f6f8fa}
.mg-ip{font-family:monospace;background:#f6f8fa;border:1px solid #d1d5da;padding:2px 8px;border-radius:4px;font-size:12px}
.mg-badge{display:inline-block;padding:3px 8px;border-radius:4px;font-size:11px;font-weight:600}
.mg-danger{background:#ffeef0;color:#cb2431}
.mg-warning{background:#fff8e1;color:#f59e0b}
.mg-success{background:#e6ffed;color:#22863a}
.mg-country{font-size:12px;color:#586069}
.mg-toast{position:fixed;bottom:24px;right:24px;background:#22863a;color:#fff;padding:12px 20px;border-radius:6px;font-size:13px;font-weight:600;display:none;z-index:9999;box-shadow:0 4px 12px rgba(0,0,0,.2)}
.mg-toast.error{background:#cb2431}
.bl-analyze-result{background:#fff;border:1px solid #d1d5da;border-radius:8px;padding:16px;margin-bottom:16px;display:none}
.bl-info{background:#e8f4fd;border:1px solid #bee3f8;border-radius:6px;padding:12px 16px;margin-bottom:16px;font-size:13px;color:#2b6cb0}
</style>

<!-- Navegación principal -->
<div class="mg-nav">
    <a href="index.cgi?section=auth" class="mg-nav-btn">🔐 Inicios de sesion</a>
    <a href="index.cgi?section=mail" class="mg-nav-btn active">📧 Proteccion de correos</a>
</div>

<!-- Stats -->
<div class="mg-grid">
    <div class="mg-stat"><div class="mg-stat-val">$total_domains</div><div class="mg-stat-lbl">Dominios bloqueados</div></div>
    <div class="mg-stat mg-blue"><div class="mg-stat-val">$total_ips</div><div class="mg-stat-lbl">IPs/subredes bloqueadas</div></div>
    <div class="mg-stat mg-green"><div class="mg-stat-val">$total_whitelist</div><div class="mg-stat-lbl">En whitelist</div></div>
</div>

<!-- Info -->
<div class="bl-info">
    Los dominios e IPs bloqueados aqui afectan el correo <strong>entrante</strong> — Exim rechazara cualquier correo proveniente de estos remitentes. Los cambios aplican inmediatamente al reiniciar Exim.
</div>

<!-- Tabs -->
<div class="mg-tabs">
    <button class="mg-tab active" onclick="mgTab('domains',this)">🚫 Dominios bloqueados</button>
    <button class="mg-tab" onclick="mgTab('ips',this)">🌐 IPs bloqueadas</button>
    <button class="mg-tab" onclick="mgTab('whitelist',this)">✅ Whitelist</button>
    <button class="mg-tab" onclick="mgTab('analyze',this)">🔍 Analizar logs</button>
</div>

<div style="text-align:right;margin-bottom:12px">
    <button class="mg-btn mg-btn-blue" id="bl-reload-btn">↻ Recargar</button>
</div>

<!-- Panel: Dominios -->
<div id="mg-panel-domains" class="mg-panel active">
    <div class="mg-search">
        <input type="text" id="bl-domain-input" placeholder="dominio.com o *.dominio.com" />
        <button class="mg-btn mg-btn-danger" id="bl-domain-add-btn">🚫 Bloquear dominio</button>
    </div>
    <div class="mg-table-wrap">
        <table>
            <thead><tr><th>Dominio bloqueado</th><th>Acciones</th></tr></thead>
            <tbody>$rows_domains</tbody>
        </table>
    </div>
</div>

<!-- Panel: IPs -->
<div id="mg-panel-ips" class="mg-panel">
    <div class="mg-search">
        <input type="text" id="bl-ip-input" placeholder="IP o subred (ej: 1.2.3.4 o 10.0.0.0/24)" />
        <button class="mg-btn mg-btn-danger" id="bl-ip-add-btn">🚫 Bloquear IP</button>
    </div>
    <div class="mg-table-wrap">
        <table>
            <thead><tr><th>IP / Subred bloqueada</th><th>Acciones</th></tr></thead>
            <tbody>$rows_ips</tbody>
        </table>
    </div>
</div>

<!-- Panel: Whitelist -->
<div id="mg-panel-whitelist" class="mg-panel">
    <div class="bl-info" style="background:#e6ffed;border-color:#c3e6cb;color:#155724">
        Las entradas en whitelist <strong>no apareceran</strong> en el analizador de logs aunque tengan mucha actividad. Agrega aqui IPs o dominios de clientes de confianza.
    </div>
    <div class="mg-search">
        <input type="text" id="wl-input" placeholder="IP o dominio de confianza (ej: 38.25.50.82 o cliente.com)" />
        <button class="mg-btn mg-btn-success" id="wl-add-btn">✅ Agregar a whitelist</button>
    </div>
    <div class="mg-table-wrap">
        <table>
            <thead><tr><th>IP / Dominio</th><th>Acciones</th></tr></thead>
            <tbody>$rows_whitelist</tbody>
        </table>
    </div>
</div>

<!-- Panel: Analizar -->
<div id="mg-panel-analyze" class="mg-panel">
    <p style="color:#586069;margin-bottom:16px;font-size:13px">
        Analiza los logs de Exim para detectar dominios e IPs sospechosas. Las entradas en whitelist no aparecen. Puedes bloquear directamente desde aqui sin recargar la pagina.
    </p>
    <button class="mg-btn mg-btn-warning" id="bl-analyze-btn">🔍 Analizar logs ahora</button>
    <div class="bl-analyze-result" id="bl-analyze-result"></div>
</div>

<div class="mg-toast" id="mg-toast"></div>
<script src="assets/blacklist.js"></script>
HTML

return $html;