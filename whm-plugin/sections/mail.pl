# =============================================================================
# mail.pl — WHM MailGuard: Sección de blacklist de correos
# https://github.com/MotionPulseWs/whm-mailguard
# =============================================================================

# ── Rutas de archivos Exim ──
my $DOMAINS_FILE = '/etc/blocked_incoming_email_domains';
my $IPS_FILE     = '/etc/spammeripblocks';

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

# ── Acciones AJAX ──
my $action = $form{action} || '';
my $entry  = $form{entry}  || '';
my $type   = $form{type}   || '';

# Agregar dominio o IP
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

# Eliminar dominio o IP
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

# Analizar logs para sugerir dominios sospechosos
if ($action eq 'bl_analyze') {
    print "Content-type: application/json\r\n\r\n";

    my @blocked_domains = read_file_lines($DOMAINS_FILE);
    my @blocked_ips     = read_file_lines($IPS_FILE);
    my %already_blocked = map { $_ => 1 } (@blocked_domains, @blocked_ips);

    my %domain_count;
    my %ip_count;

    open(my $log, '<', '/var/log/exim_mainlog') or do {
        print '{"success":0,"error":"No se pudo leer el log de Exim"}';
        exit;
    };

    while (my $line = <$log>) {
        # Detectar dominios sospechosos por SPF fail
        if ($line =~ /SPF.*fail/i && $line =~ /H=\S*\s+\[(\d+\.\d+\.\d+\.\d+)\]/) {
            my $ip = $1;
            $ip_count{$ip}++ unless $already_blocked{$ip};
        }
        # Detectar dominios con muchos envios
        if ($line =~ /<=.*H=\(([^)]+)\)/) {
            my $domain = lc($1);
            $domain =~ s/^www\.//;
            $domain_count{$domain}++ unless $already_blocked{$domain};
        }
    }
    close($log);

    # Top 10 dominios sospechosos
    my @top_domains = sort { $domain_count{$b} <=> $domain_count{$a} } keys %domain_count;
    @top_domains = @top_domains[0..9] if @top_domains > 10;

    # Top 10 IPs sospechosas
    my @top_ips = sort { $ip_count{$b} <=> $ip_count{$a} } keys %ip_count;
    @top_ips = @top_ips[0..9] if @top_ips > 10;

    my @domain_results = map { "{\"entry\":\"$_\",\"count\":$domain_count{$_},\"type\":\"domain\"}" } @top_domains;
    my @ip_results     = map { "{\"entry\":\"$_\",\"count\":$ip_count{$_},\"type\":\"ip\"}" } @top_ips;

    my $json = '[' . join(',', @domain_results, @ip_results) . ']';
    print "{\"success\":1,\"suggestions\":$json}";
    exit;
}

# ── Leer datos actuales ──
my @blocked_domains = read_file_lines($DOMAINS_FILE);
my @blocked_ips     = read_file_lines($IPS_FILE);

my $total_domains = scalar(@blocked_domains);
my $total_ips     = scalar(@blocked_ips);

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

# ── Generar HTML ──
my $html = <<HTML;
<style>
*{box-sizing:border-box}
.mg-nav{display:flex;gap:8px;margin-bottom:24px}
.mg-nav-btn{padding:10px 24px;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;border:2px solid #1a6fc4;background:#fff;color:#1a6fc4;text-decoration:none;transition:all .2s}
.mg-nav-btn.active{background:#1a6fc4;color:#fff}
.mg-nav-btn:hover{opacity:.85}
.mg-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:16px;margin-bottom:24px}
.mg-stat{background:#fff;border:1px solid #d1d5da;border-radius:8px;padding:16px 20px;border-left:4px solid #cb2431}
.mg-stat.mg-blue{border-left-color:#1a6fc4}
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
</div>

<!-- Info -->
<div class="bl-info">
    Los dominios e IPs bloqueados aqui afectan el correo <strong>entrante</strong> — Exim rechazara cualquier correo proveniente de estos remitentes. Los cambios aplican inmediatamente al reiniciar Exim.
</div>

<!-- Tabs -->
<div class="mg-tabs">
    <button class="mg-tab active" onclick="mgTab('domains',this)">🚫 Dominios bloqueados</button>
    <button class="mg-tab" onclick="mgTab('ips',this)">🌐 IPs bloqueadas</button>
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
        <input type="text" id="bl-ip-input" placeholder="IP o subred (ej: 192.168.1.1 o 10.0.0.0/24)" />
        <button class="mg-btn mg-btn-danger" id="bl-ip-add-btn">🚫 Bloquear IP</button>
    </div>
    <div class="mg-table-wrap">
        <table>
            <thead><tr><th>IP / Subred bloqueada</th><th>Acciones</th></tr></thead>
            <tbody>$rows_ips</tbody>
        </table>
    </div>
</div>

<!-- Panel: Analizar -->
<div id="mg-panel-analyze" class="mg-panel">
    <p style="color:#586069;margin-bottom:16px;font-size:13px">
        Analiza los logs de Exim para detectar dominios e IPs que envian muchos correos o tienen SPF fail. Puedes bloquearlos directamente desde aqui.
    </p>
    <button class="mg-btn mg-btn-warning" id="bl-analyze-btn">🔍 Analizar logs ahora</button>
    <div class="bl-analyze-result" id="bl-analyze-result"></div>
</div>

<div class="mg-toast" id="mg-toast"></div>
<script src="assets/blacklist.js"></script>
HTML

return $html;