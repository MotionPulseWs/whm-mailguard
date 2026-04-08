#!/usr/local/cpanel/3rdparty/bin/perl
# =============================================================================
# mailguard.pl — WHM MailGuard Plugin
# https://github.com/MotionPulseWs/whm-mailguard
# =============================================================================

use strict;
use warnings;

use lib '/usr/local/cpanel';
require Cpanel::Form;
require Whostmgr::ACLS;
require Cpanel::Template;

use DBI;

# ── Verificar acceso root ──
Whostmgr::ACLS::init_acls();
if (!Whostmgr::ACLS::hasroot()) {
    print "Content-type: text/html\r\n\r\n";
    print "<h1>Acceso denegado</h1>";
    exit;
}

# ── Leer parámetros ──
my %form = Cpanel::Form::parseform();

# ── Rutas ──
my $DB_PATH = '/usr/local/mailguard/backend/db/mailguard.db';

# ── Conexión a base de datos ──
sub get_db {
    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$DB_PATH", '', '',
        { RaiseError => 0, AutoCommit => 1, sqlite_unicode => 1 }
    );
    return $dbh;
}

sub get_config {
    my ($key, $default) = @_;
    $default //= '';
    my $dbh = get_db() or return $default;
    my $row = $dbh->selectrow_arrayref("SELECT value FROM config WHERE key=?", {}, $key);
    $dbh->disconnect();
    return $row ? $row->[0] : $default;
}

sub set_config {
    my ($key, $value) = @_;
    my $dbh = get_db() or return;
    $dbh->do("UPDATE config SET value=?, updated_at=datetime('now') WHERE key=?", {}, $value, $key);
    $dbh->disconnect();
}

sub log_event {
    my ($type, $ip, $detail) = @_;
    $ip     //= '';
    $detail //= '';
    my $dbh = get_db() or return;
    $dbh->do("INSERT INTO events (event_type, ip, detail) VALUES (?, ?, ?)", {}, $type, $ip, $detail);
    $dbh->disconnect();
}

# ── Acciones AJAX ──
my $action = $form{action} || '';
my $ip     = $form{ip}     || '';

# Toggle sistema
if ($action eq 'toggle_enabled') {
    print "Content-type: application/json\r\n\r\n";
    my $current = get_config('enabled', '1');
    my $new     = $current eq '1' ? '0' : '1';
    set_config('enabled', $new);
    log_event($new eq '1' ? 'system_on' : 'system_off', '', $new eq '1' ? 'Sistema activado' : 'Sistema desactivado');

    if ($new eq '0') {
        my $dbh = get_db();
        if ($dbh) {
            my $blocked = $dbh->selectall_arrayref("SELECT ip FROM blocked_ips WHERE is_active=1", { Slice => {} });
            for my $row (@$blocked) {
                system("iptables -D INPUT -s $row->{ip} -j DROP 2>/dev/null");
                $dbh->do("UPDATE blocked_ips SET is_active=0, unblocked_at=datetime('now'), unblocked_by='emergency' WHERE ip=? AND is_active=1", {}, $row->{ip});
            }
            $dbh->disconnect();
            system("iptables-save > /etc/sysconfig/iptables 2>/dev/null");
        }
    }
    print "{\"success\":1,\"enabled\":\"$new\"}";
    exit;
}

# Desbloquear IP
if ($action eq 'unblock' && $ip) {
    print "Content-type: application/json\r\n\r\n";
    system("iptables -D INPUT -s $ip -j DROP 2>/dev/null");
    my $dbh = get_db();
    if ($dbh) {
        $dbh->do("UPDATE blocked_ips SET is_active=0, unblocked_at=datetime('now'), unblocked_by='manual' WHERE ip=? AND is_active=1", {}, $ip);
        $dbh->do("INSERT INTO events (event_type, ip, detail) VALUES ('unblock', ?, 'Desbloqueado manualmente desde WHM')", {}, $ip);
        $dbh->disconnect();
    }
    system("iptables-save > /etc/sysconfig/iptables 2>/dev/null");
    print '{"success":1}';
    exit;
}

# Agregar a whitelist desde tabla de bloqueadas
if ($action eq 'whitelist' && $ip) {
    print "Content-type: application/json\r\n\r\n";
    my $label = $form{label} || 'Sin etiqueta';
    system("iptables -D INPUT -s $ip -j DROP 2>/dev/null");
    my $dbh = get_db();
    if ($dbh) {
        $dbh->do("INSERT OR IGNORE INTO whitelist (ip, label, added_by) VALUES (?, ?, 'manual')", {}, $ip, $label);
        $dbh->do("UPDATE blocked_ips SET is_active=0, unblocked_at=datetime('now'), unblocked_by='whitelist' WHERE ip=? AND is_active=1", {}, $ip);
        $dbh->do("INSERT INTO events (event_type, ip, detail) VALUES ('whitelist', ?, ?)", {}, $ip, "Agregado a whitelist: $label");
        $dbh->disconnect();
    }
    system("iptables-save > /etc/sysconfig/iptables 2>/dev/null");
    print '{"success":1}';
    exit;
}

# Agregar a whitelist manualmente
if ($action eq 'add_whitelist' && $ip) {
    print "Content-type: application/json\r\n\r\n";
    my $label = $form{label} || 'Sin etiqueta';
    my $dbh = get_db();
    if ($dbh) {
        $dbh->do("INSERT OR IGNORE INTO whitelist (ip, label, added_by) VALUES (?, ?, 'manual')", {}, $ip, $label);
        $dbh->do("INSERT INTO events (event_type, ip, detail) VALUES ('whitelist', ?, ?)", {}, $ip, "Agregado manualmente: $label");
        $dbh->disconnect();
    }
    print '{"success":1}';
    exit;
}

# Eliminar de whitelist
if ($action eq 'remove_whitelist' && $ip) {
    print "Content-type: application/json\r\n\r\n";
    my $dbh = get_db();
    if ($dbh) {
        $dbh->do("DELETE FROM whitelist WHERE ip=?", {}, $ip);
        $dbh->do("INSERT INTO events (event_type, ip, detail) VALUES ('whitelist_remove', ?, 'Eliminado de whitelist')", {}, $ip);
        $dbh->disconnect();
    }
    print '{"success":1}';
    exit;
}

# Buscar IP
if ($action eq 'search' && $ip) {
    print "Content-type: application/json\r\n\r\n";
    my $dbh = get_db();
    my (@blocked_rows, $wl_json);
    if ($dbh) {
        my $blocked = $dbh->selectall_arrayref(
            "SELECT ip, attempts, account, domain, blocked_at, unblock_at, unblocked_at, unblocked_by, is_active FROM blocked_ips WHERE ip LIKE ? ORDER BY blocked_at DESC LIMIT 20",
            { Slice => {} }, "%$ip%"
        );
        my $wl = $dbh->selectrow_hashref("SELECT ip, label, added_at FROM whitelist WHERE ip LIKE ?", {}, "%$ip%");
        $dbh->disconnect();

        $wl_json = $wl
            ? "{\"ip\":\"$wl->{ip}\",\"label\":\"$wl->{label}\",\"added_at\":\"$wl->{added_at}\"}"
            : 'null';

        for my $r (@$blocked) {
            my $act = $r->{is_active} // 0;
            my $acc = $r->{account}   // '';
            my $att = $r->{attempts}  // 0;
            my $bat = $r->{blocked_at} // '';
            push @blocked_rows, "{\"ip\":\"$r->{ip}\",\"account\":\"$acc\",\"attempts\":$att,\"blocked_at\":\"$bat\",\"is_active\":$act}";
        }
    }
    my $rows_json = '[' . join(',', @blocked_rows) . ']';
    $wl_json //= 'null';
    print "{\"success\":1,\"blocked\":$rows_json,\"whitelisted\":$wl_json}";
    exit;
}

# Guardar configuración
if ($action eq 'save_config') {
    print "Content-type: application/json\r\n\r\n";
    my $dbh = get_db();
    if ($dbh) {
        for my $key (qw(max_attempts window_minutes block_minutes notify_email notify_on_block)) {
            $dbh->do("UPDATE config SET value=?, updated_at=datetime('now') WHERE key=?", {}, $form{$key}, $key) if $form{$key};
        }
        $dbh->disconnect();
    }
    print '{"success":1}';
    exit;
}

# ── Datos para la interfaz ──
my $dbh = get_db();
my ($enabled, $active_blocks, $blocks_today, $total_blocks, $total_wl) = ('1', 0, 0, 0, 0);
my (@blocked_ips, @history, @whitelist);

if ($dbh) {
    $enabled       = get_config('enabled', '1');
    $active_blocks = $dbh->selectrow_array("SELECT COUNT(*) FROM blocked_ips WHERE is_active=1") // 0;
    $blocks_today  = $dbh->selectrow_array("SELECT COUNT(*) FROM blocked_ips WHERE date(blocked_at)=date('now')") // 0;
    $total_blocks  = $dbh->selectrow_array("SELECT COUNT(*) FROM blocked_ips") // 0;
    $total_wl      = $dbh->selectrow_array("SELECT COUNT(*) FROM whitelist") // 0;

    my $bi = $dbh->selectall_arrayref("SELECT ip, attempts, account, domain, blocked_at, unblock_at FROM blocked_ips WHERE is_active=1 ORDER BY blocked_at DESC LIMIT 50", { Slice => {} });
    @blocked_ips = @$bi if $bi;

    my $hi = $dbh->selectall_arrayref("SELECT ip, attempts, account, blocked_at, unblocked_at, unblocked_by, is_active FROM blocked_ips ORDER BY blocked_at DESC LIMIT 100", { Slice => {} });
    @history = @$hi if $hi;

    my $wi = $dbh->selectall_arrayref("SELECT ip, label, added_at FROM whitelist ORDER BY added_at DESC", { Slice => {} });
    @whitelist = @$wi if $wi;

    $dbh->disconnect();
}

my $switch_color = $enabled eq '1' ? '#22c55e' : '#ef4444';
my $switch_label = $enabled eq '1' ? 'ACTIVO'  : 'INACTIVO';
my $switch_icon  = $enabled eq '1' ? '🟢'      : '🔴';
my $status_text  = $enabled eq '1'
    ? 'El sistema está protegiendo tu servidor'
    : '⚠️ MODO PASIVO — El servidor no está protegido';

# ── Construir filas HTML ──
my $rows_blocked = '';
for my $r (@blocked_ips) {
    my $rip  = $r->{ip}       // '';
    my $racc = $r->{account}  // '';
    my $rdom = $r->{domain}   // '';
    my $ratt = $r->{attempts} // 0;
    my $rba  = $r->{blocked_at}  // '';
    my $rua  = $r->{unblock_at}  // '';
    $rows_blocked .= "<tr><td><span class=\"mg-ip\">$rip</span></td><td>$racc</td><td>$rdom</td><td><span class=\"mg-badge mg-danger\">$ratt intentos</span></td><td>$rba</td><td>$rua</td><td><button class=\"mg-btn mg-btn-sm mg-btn-danger\" onclick=\"mgUnblock('$rip')\">Desbloquear</button> <button class=\"mg-btn mg-btn-sm mg-btn-success\" onclick=\"mgWhitelist('$rip')\">Whitelist</button></td></tr>\n";
}

my $rows_history = '';
for my $r (@history) {
    my $rip  = $r->{ip}       // '';
    my $racc = $r->{account}  // '';
    my $ratt = $r->{attempts} // 0;
    my $rba  = $r->{blocked_at}   // '';
    my $rua  = $r->{unblocked_at} // '-';
    my $rby  = $r->{unblocked_by} // '-';
    my $ract = $r->{is_active}    // 0;
    my $estado = $ract ? '<span class="mg-badge mg-danger">Activo</span>' : '<span class="mg-badge mg-success">Liberado</span>';
    $rows_history .= "<tr><td><span class=\"mg-ip\">$rip</span></td><td>$racc</td><td>$ratt</td><td>$rba</td><td>$rua</td><td>$rby</td><td>$estado</td></tr>\n";
}

my $rows_whitelist = '';
for my $r (@whitelist) {
    my $rip  = $r->{ip}       // '';
    my $rlbl = $r->{label}    // '';
    my $rdat = $r->{added_at} // '';
    $rows_whitelist .= "<tr><td><span class=\"mg-ip\">$rip</span></td><td>$rlbl</td><td>$rdat</td><td><button class=\"mg-btn mg-btn-sm mg-btn-danger\" onclick=\"mgRemoveWhitelist('$rip')\">Eliminar</button></td></tr>\n";
}

my $cfg_max      = get_config('max_attempts',    '10');
my $cfg_window   = get_config('window_minutes',  '10');
my $cfg_block    = get_config('block_minutes',   '60');
my $cfg_email    = get_config('notify_email',    'monitor@motionpulse.net');
my $cfg_notify   = get_config('notify_on_block', '1');

# ── Generar HTML ──
my $html_output;
open my $OUT, '>', \$html_output;
select $OUT;

print <<HTML;
<style>
*{box-sizing:border-box}
.mg-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:24px}
.mg-stat{background:#fff;border:1px solid #d1d5da;border-radius:8px;padding:16px 20px;border-left:4px solid #1a6fc4}
.mg-stat.mg-red{border-left-color:#cb2431}
.mg-stat.mg-green{border-left-color:#22863a}
.mg-stat.mg-yellow{border-left-color:#f59e0b}
.mg-stat-val{font-size:28px;font-weight:700;color:#1a1a2e}
.mg-stat-lbl{font-size:12px;color:#586069;margin-top:4px}
.mg-emergency{background:#fff;border:2px solid $switch_color;border-radius:8px;padding:20px 24px;margin-bottom:24px;display:flex;align-items:center;justify-content:space-between}
.mg-emergency h2{font-size:16px;font-weight:600;margin:0 0 4px}
.mg-emergency p{font-size:13px;color:#586069;margin:0}
.mg-switch-btn{background:$switch_color;color:#fff;border:none;border-radius:6px;padding:12px 24px;font-size:14px;font-weight:700;cursor:pointer;min-width:140px}
.mg-switch-btn:hover{opacity:.85}
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
.mg-btn-success{background:#22863a;color:#fff}
.mg-btn-sm{padding:5px 10px;font-size:12px}
.mg-table-wrap{background:#fff;border:1px solid #d1d5da;border-radius:8px;overflow:hidden}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#f6f8fa;padding:10px 14px;text-align:left;font-size:11px;font-weight:600;color:#586069;text-transform:uppercase;border-bottom:1px solid #d1d5da}
td{padding:10px 14px;border-top:1px solid #f0f0f0;vertical-align:middle}
tr:hover td{background:#f6f8fa}
.mg-badge{display:inline-block;padding:3px 8px;border-radius:4px;font-size:11px;font-weight:600}
.mg-danger{background:#ffeef0;color:#cb2431}
.mg-success{background:#dcffe4;color:#22863a}
.mg-ip{font-family:monospace;background:#f6f8fa;border:1px solid #d1d5da;padding:2px 8px;border-radius:4px;font-size:12px}
.mg-form-group{margin-bottom:14px}
.mg-form-group label{display:block;font-size:12px;font-weight:600;color:#586069;margin-bottom:5px}
.mg-form-group input{width:100%;padding:9px 12px;border:1px solid #d1d5da;border-radius:6px;font-size:14px}
.mg-config-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px}
\#mg-search-result{background:#fff;border:1px solid #d1d5da;border-radius:8px;padding:16px;margin-bottom:16px;display:none}
.mg-toast{position:fixed;bottom:24px;right:24px;background:#22863a;color:#fff;padding:12px 20px;border-radius:6px;font-size:13px;font-weight:600;display:none;z-index:9999;box-shadow:0 4px 12px rgba(0,0,0,.2)}
.mg-toast.error{background:#cb2431}
</style>

<div class="mg-emergency">
    <div>
        <h2>$switch_icon Estado: <strong>$switch_label</strong></h2>
        <p>$status_text</p>
    </div>
    <button class="mg-switch-btn" id="mg-switch-btn">$switch_icon $switch_label</button>
</div>

<div class="mg-grid">
    <div class="mg-stat mg-red"><div class="mg-stat-val">$active_blocks</div><div class="mg-stat-lbl">IPs bloqueadas ahora</div></div>
    <div class="mg-stat mg-yellow"><div class="mg-stat-val">$blocks_today</div><div class="mg-stat-lbl">Bloqueadas hoy</div></div>
    <div class="mg-stat"><div class="mg-stat-val">$total_blocks</div><div class="mg-stat-lbl">Total historial</div></div>
    <div class="mg-stat mg-green"><div class="mg-stat-val">$total_wl</div><div class="mg-stat-lbl">IPs en whitelist</div></div>
</div>

<div class="mg-tabs">
    <button class="mg-tab active" onclick="mgTab('blocked',this)">🔴 Bloqueadas</button>
    <button class="mg-tab" onclick="mgTab('search',this)">🔍 Buscar IP</button>
    <button class="mg-tab" onclick="mgTab('history',this)">📋 Historial</button>
    <button class="mg-tab" onclick="mgTab('whitelist',this)">✅ Whitelist</button>
    <button class="mg-tab" onclick="mgTab('config',this)">⚙️ Configuración</button>
</div>

<div style="text-align:right;margin-bottom:12px">
    <button class="mg-btn mg-btn-blue" onclick="mgReload()">↻ Recargar</button>
</div>

<div id="mg-panel-blocked" class="mg-panel active">
    <div class="mg-table-wrap">
        <table>
            <thead><tr><th>IP</th><th>Cuenta</th><th>Dominio</th><th>Intentos</th><th>Bloqueada</th><th>Se libera</th><th>Acciones</th></tr></thead>
            <tbody>$rows_blocked</tbody>
        </table>
    </div>
</div>

<div id="mg-panel-search" class="mg-panel">
    <div class="mg-search">
        <input type="text" id="mg-search-input" placeholder="IP o parte de ella (ej: 192.168.1)" />
        <button class="mg-btn mg-btn-blue" onclick="mgSearch()">🔍 Buscar</button>
    </div>
    <div id="mg-search-result"></div>
</div>

<div id="mg-panel-history" class="mg-panel">
    <div class="mg-table-wrap">
        <table>
            <thead><tr><th>IP</th><th>Cuenta</th><th>Intentos</th><th>Bloqueada</th><th>Desbloqueada</th><th>Por</th><th>Estado</th></tr></thead>
            <tbody>$rows_history</tbody>
        </table>
    </div>
</div>

<div id="mg-panel-whitelist" class="mg-panel">
    <div class="mg-search">
        <input type="text" id="mg-wl-ip" placeholder="IP (ej: 179.6.164.138)" />
        <input type="text" id="mg-wl-label" placeholder="Etiqueta (ej: Cliente Juan)" style="max-width:220px" />
        <button class="mg-btn mg-btn-success" onclick="mgAddWhitelist()">✅ Agregar</button>
    </div>
    <div class="mg-table-wrap">
        <table>
            <thead><tr><th>IP</th><th>Etiqueta</th><th>Agregada</th><th>Acciones</th></tr></thead>
            <tbody>$rows_whitelist</tbody>
        </table>
    </div>
</div>

<div id="mg-panel-config" class="mg-panel">
    <div class="mg-table-wrap" style="padding:24px">
        <div class="mg-config-grid">
            <div>
                <div class="mg-form-group"><label>Máximo de intentos antes de bloquear</label><input type="number" id="cfg-max_attempts" value="$cfg_max" min="3" max="50" /></div>
                <div class="mg-form-group"><label>Ventana de tiempo (minutos)</label><input type="number" id="cfg-window_minutes" value="$cfg_window" min="1" max="60" /></div>
                <div class="mg-form-group"><label>Duración del bloqueo (minutos)</label><input type="number" id="cfg-block_minutes" value="$cfg_block" min="5" max="1440" /></div>
            </div>
            <div>
                <div class="mg-form-group"><label>Email de notificaciones</label><input type="email" id="cfg-notify_email" value="$cfg_email" /></div>
                <div class="mg-form-group"><label>Notificar al bloquear (1=sí, 0=no)</label><input type="number" id="cfg-notify_on_block" value="$cfg_notify" min="0" max="1" /></div>
                <div class="mg-form-group"><label>Max IPs distintas por cuenta antes de bloquear</label><input type="number" id="cfg-max_ips_per_account" value="5" min="2" max="20" /></div>
                <div class="mg-form-group"><label>Ventana de tiempo para ataque distribuido (minutos)</label><input type="number" id="cfg-window_minutes_account" value="60" min="10" max="1440" /></div>
            </div>
            
        </div>
        <button class="mg-btn mg-btn-blue" onclick="mgSaveConfig()">💾 Guardar</button>
    </div>
</div>

<div class="mg-toast" id="mg-toast"></div>

<script src="assets/mailguard.js"></script>

HTML

select STDOUT;

# ── Procesar con template WHM ──
print "Content-type: text/html\r\n\r\n";
Cpanel::Template::process_template(
    'whostmgr',
    {
        'template_file'    => 'mailguard.tmpl',
        'mailguard_output' => $html_output,
    }
);