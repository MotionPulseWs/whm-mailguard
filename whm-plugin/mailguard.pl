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
my $DB_PATH     = '/usr/local/mailguard/backend/db/mailguard.db';
my $INSTALL_DIR = '/usr/local/mailguard';
my $LOG_FILE    = '/var/log/mailguard.log';

# ── Acciones AJAX ──
my $action = $form{action} || '';
my $ip     = $form{ip}     || '';

# Toggle sistema
if ($action eq 'toggle_enabled') {
    print "Content-type: application/json\r\n\r\n";
    my $current = get_config('enabled');
    my $new     = $current eq '1' ? '0' : '1';
    set_config('enabled', $new);
    log_event($new eq '1' ? 'system_on' : 'system_off', '', $new eq '1' ? 'Sistema activado' : 'Sistema desactivado');

    if ($new eq '0') {
        my @blocked = db_query("SELECT ip FROM blocked_ips WHERE is_active=1");
        for my $row (@blocked) {
            system("iptables -D INPUT -s $row->{ip} -j DROP 2>/dev/null");
            db_exec("UPDATE blocked_ips SET is_active=0, unblocked_at=datetime('now'), unblocked_by='emergency' WHERE ip=? AND is_active=1", $row->{ip});
        }
        system("iptables-save > /etc/sysconfig/iptables 2>/dev/null");
    }
    print "{\"success\":1,\"enabled\":\"$new\"}";
    exit;
}

# Desbloquear IP
if ($action eq 'unblock' && $ip) {
    print "Content-type: application/json\r\n\r\n";
    system("iptables -D INPUT -s $ip -j DROP 2>/dev/null");
    db_exec("UPDATE blocked_ips SET is_active=0, unblocked_at=datetime('now'), unblocked_by='manual' WHERE ip=? AND is_active=1", $ip);
    log_event('unblock', $ip, 'Desbloqueado manualmente desde WHM');
    system("iptables-save > /etc/sysconfig/iptables 2>/dev/null");
    print '{"success":1}';
    exit;
}

# Agregar a whitelist
if ($action eq 'whitelist' && $ip) {
    print "Content-type: application/json\r\n\r\n";
    my $label = $form{label} || 'Sin etiqueta';
    system("iptables -D INPUT -s $ip -j DROP 2>/dev/null");
    db_exec("INSERT OR IGNORE INTO whitelist (ip, label, added_by) VALUES (?, ?, 'manual')", $ip, $label);
    db_exec("UPDATE blocked_ips SET is_active=0, unblocked_at=datetime('now'), unblocked_by='whitelist' WHERE ip=? AND is_active=1", $ip);
    log_event('whitelist', $ip, "Agregado a whitelist: $label");
    system("iptables-save > /etc/sysconfig/iptables 2>/dev/null");
    print '{"success":1}';
    exit;
}

# Agregar a whitelist manualmente
if ($action eq 'add_whitelist' && $ip) {
    print "Content-type: application/json\r\n\r\n";
    my $label = $form{label} || 'Sin etiqueta';
    db_exec("INSERT OR IGNORE INTO whitelist (ip, label, added_by) VALUES (?, ?, 'manual')", $ip, $label);
    log_event('whitelist', $ip, "Agregado manualmente: $label");
    print '{"success":1}';
    exit;
}

# Buscar IP
if ($action eq 'search' && $ip) {
    print "Content-type: application/json\r\n\r\n";
    my @blocked = db_query(
        "SELECT ip, attempts, account, domain, blocked_at, unblock_at, unblocked_at, unblocked_by, is_active FROM blocked_ips WHERE ip LIKE ? ORDER BY blocked_at DESC LIMIT 20",
        "%$ip%"
    );
    my @wl = db_query("SELECT ip, label, added_at FROM whitelist WHERE ip LIKE ?", "%$ip%");
    my $wl_json = @wl ? "{\"ip\":\"$wl[0]{ip}\",\"label\":\"$wl[0]{label}\",\"added_at\":\"$wl[0]{added_at}\"}" : 'null';

    my @rows;
    for my $r (@blocked) {
        push @rows, "{\"ip\":\"$r->{ip}\",\"account\":\"$r->{account}\",\"attempts\":$r->{attempts},\"blocked_at\":\"$r->{blocked_at}\",\"is_active\":$r->{is_active}}";
    }
    my $rows_json = '[' . join(',', @rows) . ']';
    print "{\"success\":1,\"blocked\":$rows_json,\"whitelisted\":$wl_json}";
    exit;
}

# Guardar configuración
if ($action eq 'save_config') {
    print "Content-type: application/json\r\n\r\n";
    for my $key (qw(max_attempts window_minutes block_minutes notify_email notify_on_block)) {
        set_config($key, $form{$key}) if $form{$key};
    }
    print '{"success":1}';
    exit;
}

# Status del servicio
if ($action eq 'service_status') {
    print "Content-type: application/json\r\n\r\n";
    my $running = `systemctl is-active mailguard 2>/dev/null`;
    chomp $running;
    print "{\"running\":\"$running\"}";
    exit;
}

# ── Datos para la interfaz ──
my $enabled       = get_config('enabled');
my $active_blocks = db_scalar("SELECT COUNT(*) FROM blocked_ips WHERE is_active=1");
my $blocks_today  = db_scalar("SELECT COUNT(*) FROM blocked_ips WHERE date(blocked_at)=date('now')");
my $total_blocks  = db_scalar("SELECT COUNT(*) FROM blocked_ips");
my $total_wl      = db_scalar("SELECT COUNT(*) FROM whitelist");

my @blocked_ips = db_query("SELECT ip, attempts, account, domain, blocked_at, unblock_at FROM blocked_ips WHERE is_active=1 ORDER BY blocked_at DESC LIMIT 50");
my @history     = db_query("SELECT ip, attempts, account, blocked_at, unblocked_at, unblocked_by, is_active FROM blocked_ips ORDER BY blocked_at DESC LIMIT 100");
my @whitelist   = db_query("SELECT ip, label, added_at FROM whitelist ORDER BY added_at DESC");

my $switch_color = $enabled eq '1' ? '#22c55e' : '#ef4444';
my $switch_label = $enabled eq '1' ? 'ACTIVO'  : 'INACTIVO';
my $switch_icon  = $enabled eq '1' ? '🟢'      : '🔴';
my $status_text  = $enabled eq '1'
    ? 'El sistema está protegiendo tu servidor'
    : '⚠️ MODO PASIVO — El servidor no está protegido';

# ── Construir filas de tablas ──
my $rows_blocked = '';
for my $r (@blocked_ips) {
    $rows_blocked .= <<ROW;
<tr>
    <td><span class="mg-ip">$r->{ip}</span></td>
    <td>$r->{account}</td>
    <td>$r->{domain}</td>
    <td><span class="mg-badge mg-danger">$r->{attempts} intentos</span></td>
    <td>$r->{blocked_at}</td>
    <td>$r->{unblock_at}</td>
    <td>
        <button class="mg-btn mg-btn-sm mg-btn-danger" onclick="mgUnblock('$r->{ip}')">Desbloquear</button>
        <button class="mg-btn mg-btn-sm mg-btn-success" onclick="mgWhitelist('$r->{ip}')">Whitelist</button>
    </td>
</tr>
ROW
}

my $rows_history = '';
for my $r (@history) {
    my $estado   = $r->{is_active} ? '<span class="mg-badge mg-danger">Activo</span>' : '<span class="mg-badge mg-success">Liberado</span>';
    my $by       = $r->{unblocked_by} || '-';
    my $unblocked = $r->{unblocked_at} || '-';
    $rows_history .= <<ROW;
<tr>
    <td><span class="mg-ip">$r->{ip}</span></td>
    <td>$r->{account}</td>
    <td>$r->{attempts}</td>
    <td>$r->{blocked_at}</td>
    <td>$unblocked</td>
    <td>$by</td>
    <td>$estado</td>
</tr>
ROW
}

my $rows_whitelist = '';
for my $r (@whitelist) {
    $rows_whitelist .= <<ROW;
<tr>
    <td><span class="mg-ip">$r->{ip}</span></td>
    <td>$r->{label}</td>
    <td>$r->{added_at}</td>
</tr>
ROW
}

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
#mg-search-result{background:#fff;border:1px solid #d1d5da;border-radius:8px;padding:16px;margin-bottom:16px;display:none}
.mg-toast{position:fixed;bottom:24px;right:24px;background:#22863a;color:#fff;padding:12px 20px;border-radius:6px;font-size:13px;font-weight:600;display:none;z-index:9999}
.mg-toast.error{background:#cb2431}
</style>

<!-- Switch de emergencia -->
<div class="mg-emergency">
    <div>
        <h2>$switch_icon Estado: <strong>$switch_label</strong></h2>
        <p>$status_text</p>
    </div>
    <button class="mg-switch-btn" onclick="mgToggle()">$switch_icon $switch_label</button>
</div>

<!-- Stats -->
<div class="mg-grid">
    <div class="mg-stat mg-red">
        <div class="mg-stat-val">$active_blocks</div>
        <div class="mg-stat-lbl">IPs bloqueadas ahora</div>
    </div>
    <div class="mg-stat mg-yellow">
        <div class="mg-stat-val">$blocks_today</div>
        <div class="mg-stat-lbl">Bloqueadas hoy</div>
    </div>
    <div class="mg-stat">
        <div class="mg-stat-val">$total_blocks</div>
        <div class="mg-stat-lbl">Total historial</div>
    </div>
    <div class="mg-stat mg-green">
        <div class="mg-stat-val">$total_wl</div>
        <div class="mg-stat-lbl">IPs en whitelist</div>
    </div>
</div>

<!-- Tabs -->
<div class="mg-tabs">
    <button class="mg-tab active" onclick="mgTab('blocked', this)">🔴 Bloqueadas</button>
    <button class="mg-tab" onclick="mgTab('search', this)">🔍 Buscar IP</button>
    <button class="mg-tab" onclick="mgTab('history', this)">📋 Historial</button>
    <button class="mg-tab" onclick="mgTab('whitelist', this)">✅ Whitelist</button>
    <button class="mg-tab" onclick="mgTab('config', this)">⚙️ Configuración</button>
</div>

<!-- Panel: Bloqueadas -->
<div id="mg-panel-blocked" class="mg-panel active">
    <div class="mg-table-wrap">
        <table>
            <thead><tr>
                <th>IP</th><th>Cuenta</th><th>Dominio</th>
                <th>Intentos</th><th>Bloqueada</th><th>Se libera</th><th>Acciones</th>
            </tr></thead>
            <tbody>$rows_blocked</tbody>
        </table>
    </div>
</div>

<!-- Panel: Buscar -->
<div id="mg-panel-search" class="mg-panel">
    <div class="mg-search">
        <input type="text" id="mg-search-input" placeholder="IP o parte de ella (ej: 192.168.1)" />
        <button class="mg-btn mg-btn-blue" onclick="mgSearch()">🔍 Buscar</button>
    </div>
    <div id="mg-search-result"></div>
</div>

<!-- Panel: Historial -->
<div id="mg-panel-history" class="mg-panel">
    <div class="mg-table-wrap">
        <table>
            <thead><tr>
                <th>IP</th><th>Cuenta</th><th>Intentos</th>
                <th>Bloqueada</th><th>Desbloqueada</th><th>Por</th><th>Estado</th>
            </tr></thead>
            <tbody>$rows_history</tbody>
        </table>
    </div>
</div>

<!-- Panel: Whitelist -->
<div id="mg-panel-whitelist" class="mg-panel">
    <div class="mg-search" style="margin-bottom:16px">
        <input type="text" id="mg-wl-ip" placeholder="IP (ej: 179.6.164.138)" />
        <input type="text" id="mg-wl-label" placeholder="Etiqueta (ej: Cliente Juan)" style="max-width:200px" />
        <button class="mg-btn mg-btn-success" onclick="mgAddWhitelist()">✅ Agregar</button>
    </div>
    <div class="mg-table-wrap">
        <table>
            <thead><tr><th>IP</th><th>Etiqueta</th><th>Agregada</th></tr></thead>
            <tbody>$rows_whitelist</tbody>
        </table>
    </div>
</div>

<!-- Panel: Configuración -->
<div id="mg-panel-config" class="mg-panel">
    <div class="mg-table-wrap" style="padding:24px">
        <div class="mg-config-grid">
            <div>
                <div class="mg-form-group">
                    <label>Máximo de intentos antes de bloquear</label>
                    <input type="number" id="cfg-max_attempts" value="10" min="3" max="50" />
                </div>
                <div class="mg-form-group">
                    <label>Ventana de tiempo (minutos)</label>
                    <input type="number" id="cfg-window_minutes" value="10" min="1" max="60" />
                </div>
                <div class="mg-form-group">
                    <label>Duración del bloqueo (minutos)</label>
                    <input type="number" id="cfg-block_minutes" value="60" min="5" max="1440" />
                </div>
            </div>
            <div>
                <div class="mg-form-group">
                    <label>Email de notificaciones</label>
                    <input type="email" id="cfg-notify_email" value="monitor\@motionpulse.net" />
                </div>
                <div class="mg-form-group">
                    <label>Notificar al bloquear (1=sí, 0=no)</label>
                    <input type="number" id="cfg-notify_on_block" value="1" min="0" max="1" />
                </div>
            </div>
        </div>
        <button class="mg-btn mg-btn-blue" onclick="mgSaveConfig()">💾 Guardar</button>
    </div>
</div>

<!-- Toast -->
<div class="mg-toast" id="mg-toast"></div>

<script>
const MG_URL = window.location.href.split('?')[0];

function mgTab(name, el) {
    document.querySelectorAll('.mg-panel').forEach(p => p.classList.remove('active'));
    document.querySelectorAll('.mg-tab').forEach(t => t.classList.remove('active'));
    document.getElementById('mg-panel-' + name).classList.add('active');
    el.classList.add('active');
}

function mgToast(msg, err) {
    const t = document.getElementById('mg-toast');
    t.textContent = msg;
    t.className = 'mg-toast' + (err ? ' error' : '');
    t.style.display = 'block';
    setTimeout(() => t.style.display = 'none', 3000);
}

async function mgApi(params) {
    const res = await fetch(MG_URL, {
        method: 'POST',
        body: new URLSearchParams(params)
    });
    return res.json();
}

async function mgToggle() {
    if (!confirm('¿Cambiar estado del sistema?')) return;
    const d = await mgApi({ action: 'toggle_enabled' });
    if (d.success) {
        mgToast(d.enabled === '1' ? '✅ Sistema ACTIVADO' : '⚠️ Sistema DESACTIVADO');
        setTimeout(() => location.reload(), 1500);
    }
}

async function mgUnblock(ip) {
    if (!confirm('¿Desbloquear ' + ip + '?')) return;
    const d = await mgApi({ action: 'unblock', ip });
    if (d.success) { mgToast('✅ ' + ip + ' desbloqueada'); setTimeout(() => location.reload(), 1500); }
}

async function mgWhitelist(ip) {
    const label = prompt('Etiqueta para ' + ip + ':', '');
    if (label === null) return;
    const d = await mgApi({ action: 'whitelist', ip, label: label || 'Sin etiqueta' });
    if (d.success) { mgToast('✅ ' + ip + ' en whitelist'); setTimeout(() => location.reload(), 1500); }
}

async function mgAddWhitelist() {
    const ip    = document.getElementById('mg-wl-ip').value.trim();
    const label = document.getElementById('mg-wl-label').value.trim() || 'Sin etiqueta';
    if (!ip) { mgToast('Ingresa una IP', true); return; }
    const d = await mgApi({ action: 'add_whitelist', ip, label });
    if (d.success) { mgToast('✅ IP agregada'); setTimeout(() => location.reload(), 1500); }
}

async function mgSearch() {
    const ip  = document.getElementById('mg-search-input').value.trim();
    if (!ip) { mgToast('Ingresa una IP', true); return; }
    const d   = await mgApi({ action: 'search', ip });
    const div = document.getElementById('mg-search-result');
    div.style.display = 'block';

    if (!d.blocked.length && !d.whitelisted) {
        div.innerHTML = '<p style="color:#586069">Sin resultados para <strong>' + ip + '</strong></p>';
        return;
    }

    let html = '';
    if (d.whitelisted) {
        html += '<div style="background:#dcffe4;border-radius:6px;padding:10px;margin-bottom:10px">';
        html += '✅ <strong>' + d.whitelisted.ip + '</strong> está en whitelist — ' + d.whitelisted.label;
        html += '</div>';
    }
    if (d.blocked.length) {
        html += '<table style="width:100%;font-size:13px"><thead><tr><th>IP</th><th>Cuenta</th><th>Intentos</th><th>Fecha</th><th>Estado</th><th>Acciones</th></tr></thead><tbody>';
        d.blocked.forEach(r => {
            const active = r.is_active == 1;
            html += '<tr><td><span class="mg-ip">' + r.ip + '</span></td><td>' + r.account + '</td><td>' + r.attempts + '</td><td>' + r.blocked_at + '</td>';
            html += '<td>' + (active ? '<span class="mg-badge mg-danger">Activo</span>' : '<span class="mg-badge mg-success">Liberado</span>') + '</td>';
            html += '<td>' + (active ? '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="mgUnblock(\'' + r.ip + '\')">Desbloquear</button>' : '') + '</td></tr>';
        });
        html += '</tbody></table>';
    }
    div.innerHTML = html;
}

async function mgSaveConfig() {
    const params = { action: 'save_config' };
    ['max_attempts','window_minutes','block_minutes','notify_email','notify_on_block'].forEach(k => {
        params[k] = document.getElementById('cfg-' + k).value;
    });
    const d = await mgApi(params);
    if (d.success) mgToast('✅ Configuración guardada');
}

setInterval(() => location.reload(), 30000);
</script>
HTML

select STDOUT;

# ── Procesar con template WHM ──
print "Content-type: text/html\r\n\r\n";
Cpanel::Template::process_template(
    'whostmgr',
    {
        'template_file'       => 'mailguard.tmpl',
        'mailguard_output'    => $html_output,
    }
);

# =============================================================================
# FUNCIONES AUXILIARES
# =============================================================================

sub db_exec {
    my ($sql, @params) = @_;
    my $cmd = "python3 -c \"
import sqlite3
conn = sqlite3.connect('$DB_PATH')
conn.execute('''$sql''', " . _params_to_python(@params) . ")
conn.commit()
conn.close()
\" 2>/dev/null";
    system($cmd);
}

sub db_scalar {
    my ($sql, @params) = @_;
    my $result = `python3 -c \"
import sqlite3
conn = sqlite3.connect('$DB_PATH')
row = conn.execute('''$sql''', " . _params_to_python(@params) . ").fetchone()
print(row[0] if row else 0)
conn.close()
\" 2>/dev/null`;
    chomp $result;
    return $result || 0;
}

sub db_query {
    my ($sql, @params) = @_;
    my $result = `python3 -c \"
import sqlite3, json
conn = sqlite3.connect('$DB_PATH')
conn.row_factory = sqlite3.Row
rows = conn.execute('''$sql''', " . _params_to_python(@params) . ").fetchall()
print(json.dumps([dict(r) for r in rows]))
conn.close()
\" 2>/dev/null`;
    chomp $result;
    return () unless $result;
    eval {
        require JSON;
        my $data = JSON::decode_json($result);
        return @$data;
    };
    return ();
}

sub _params_to_python {
    my @params = @_;
    return '[]' unless @params;
    my @quoted = map { "\"$_\"" } @params;
    return '(' . join(',', @quoted) . ',)';
}

sub get_config {
    my ($key) = @_;
    my $val = db_scalar("SELECT value FROM config WHERE key='$key'");
    return $val || '1';
}

sub set_config {
    my ($key, $value) = @_;
    db_exec("UPDATE config SET value=?, updated_at=datetime('now') WHERE key=?", $value, $key);
}

sub log_event {
    my ($type, $ip, $detail) = @_;
    db_exec("INSERT INTO events (event_type, ip, detail) VALUES (?, ?, ?)", $type, $ip, $detail);
}