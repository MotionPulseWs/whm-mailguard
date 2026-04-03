#!/usr/bin/perl
# WHM MailGuard - WHM Plugin Interface
# https://github.com/MotionPulseWs/whm-mailguard

use strict;
use warnings;
use CGI qw(:standard);
use JSON;
use DBI;

# ─── Configuración ────────────────────────────────────────────────────────────
my $DB_PATH     = '/usr/local/mailguard/backend/db/mailguard.db';
my $INSTALL_DIR = '/usr/local/mailguard';

# ─── Base de datos ────────────────────────────────────────────────────────────
sub get_db {
    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$DB_PATH", '', '',
        { RaiseError => 1, AutoCommit => 1, sqlite_unicode => 1 }
    ) or die "No se pudo conectar a la base de datos: $!";
    return $dbh;
}

sub get_config {
    my ($key, $default) = @_;
    my $dbh = get_db();
    my $row = $dbh->selectrow_hashref(
        'SELECT value FROM config WHERE key = ?', {}, $key
    );
    $dbh->disconnect();
    return $row ? $row->{value} : $default;
}

sub set_config {
    my ($key, $value) = @_;
    my $dbh = get_db();
    $dbh->do(
        'UPDATE config SET value=?, updated_at=CURRENT_TIMESTAMP WHERE key=?',
        {}, $value, $key
    );
    $dbh->disconnect();
}

# ─── Acciones AJAX ────────────────────────────────────────────────────────────
sub handle_ajax {
    my $action = param('action') // '';
    my $ip     = param('ip')     // '';

    print "Content-Type: application/json\n\n";

    # Toggle switch de emergencia
    if ($action eq 'toggle_enabled') {
        my $current = get_config('enabled', '1');
        my $new     = $current eq '1' ? '0' : '1';
        set_config('enabled', $new);

        # Registrar evento
        my $dbh = get_db();
        my $event = $new eq '1' ? 'system_on' : 'system_off';
        $dbh->do(
            'INSERT INTO events (event_type, detail) VALUES (?, ?)',
            {}, $event, $new eq '1' ? 'Sistema activado' : 'Sistema desactivado'
        );

        # Si se apaga, liberar todas las IPs bloqueadas
        if ($new eq '0') {
            my $blocked = $dbh->selectall_arrayref(
                'SELECT ip FROM blocked_ips WHERE is_active=1', { Slice => {} }
            );
            for my $row (@$blocked) {
                system("iptables -D INPUT -s $row->{ip} -j DROP 2>/dev/null");
                $dbh->do(
                    q{UPDATE blocked_ips SET is_active=0,
                      unblocked_at=CURRENT_TIMESTAMP, unblocked_by='emergency'
                      WHERE ip=? AND is_active=1},
                    {}, $row->{ip}
                );
            }
            system("iptables-save > /etc/sysconfig/iptables 2>/dev/null");
        }
        $dbh->disconnect();
        print encode_json({ success => 1, enabled => $new });
        return;
    }

    # Desbloquear IP
    if ($action eq 'unblock' && $ip) {
        system("iptables -D INPUT -s $ip -j DROP 2>/dev/null");
        my $dbh = get_db();
        $dbh->do(
            q{UPDATE blocked_ips SET is_active=0,
              unblocked_at=CURRENT_TIMESTAMP, unblocked_by='manual'
              WHERE ip=? AND is_active=1},
            {}, $ip
        );
        $dbh->do(
            'INSERT INTO events (event_type, ip, detail) VALUES (?, ?, ?)',
            {}, 'unblock', $ip, 'Desbloqueado manualmente desde WHM'
        );
        $dbh->disconnect();
        system("iptables-save > /etc/sysconfig/iptables 2>/dev/null");
        print encode_json({ success => 1 });
        return;
    }

    # Agregar a whitelist
    if ($action eq 'whitelist' && $ip) {
        system("iptables -D INPUT -s $ip -j DROP 2>/dev/null");
        my $dbh = get_db();
        my $label = param('label') // 'Agregado manualmente';
        $dbh->do(
            'INSERT OR IGNORE INTO whitelist (ip, label, added_by) VALUES (?, ?, ?)',
            {}, $ip, $label, 'manual'
        );
        $dbh->do(
            q{UPDATE blocked_ips SET is_active=0,
              unblocked_at=CURRENT_TIMESTAMP, unblocked_by='whitelist'
              WHERE ip=? AND is_active=1},
            {}, $ip
        );
        $dbh->do(
            'INSERT INTO events (event_type, ip, detail) VALUES (?, ?, ?)',
            {}, 'whitelist', $ip, "Agregado a whitelist: $label"
        );
        $dbh->disconnect();
        system("iptables-save > /etc/sysconfig/iptables 2>/dev/null");
        print encode_json({ success => 1 });
        return;
    }

    # Buscar IP
    if ($action eq 'search' && $ip) {
        my $dbh = get_db();
        my $blocked = $dbh->selectall_arrayref(
            q{SELECT ip, attempts, account, domain, blocked_at, unblock_at,
              unblocked_at, unblocked_by, is_active
              FROM blocked_ips WHERE ip LIKE ? ORDER BY blocked_at DESC LIMIT 20},
            { Slice => {} }, "%$ip%"
        );
        my $whitelisted = $dbh->selectrow_hashref(
            'SELECT ip, label, added_at FROM whitelist WHERE ip LIKE ?',
            {}, "%$ip%"
        );
        $dbh->disconnect();
        print encode_json({
            success     => 1,
            blocked     => $blocked,
            whitelisted => $whitelisted ? $whitelisted : undef
        });
        return;
    }

    # Guardar configuración
    if ($action eq 'save_config') {
        my @keys = qw(max_attempts window_minutes block_minutes notify_email notify_on_block);
        my $dbh  = get_db();
        for my $key (@keys) {
            my $val = param($key) // '';
            next unless $val;
            $dbh->do(
                'UPDATE config SET value=?, updated_at=CURRENT_TIMESTAMP WHERE key=?',
                {}, $val, $key
            );
        }
        $dbh->disconnect();
        print encode_json({ success => 1 });
        return;
    }

    print encode_json({ error => 'Acción no reconocida' });
}

# ─── Datos para la interfaz ───────────────────────────────────────────────────
sub get_stats {
    my $dbh     = get_db();
    my $enabled = get_config('enabled', '1');

    my $active_blocks = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM blocked_ips WHERE is_active=1'
    );
    my $total_blocks = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM blocked_ips'
    );
    my $total_whitelist = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM whitelist'
    );
    my $blocks_today = $dbh->selectrow_array(
        q{SELECT COUNT(*) FROM blocked_ips
          WHERE date(blocked_at) = date('now')}
    );

    my $blocked_ips = $dbh->selectall_arrayref(
        q{SELECT ip, attempts, account, domain, blocked_at, unblock_at
          FROM blocked_ips WHERE is_active=1
          ORDER BY blocked_at DESC LIMIT 50},
        { Slice => {} }
    );

    my $history = $dbh->selectall_arrayref(
        q{SELECT ip, attempts, account, domain, blocked_at,
          unblocked_at, unblocked_by, is_active
          FROM blocked_ips
          ORDER BY blocked_at DESC LIMIT 100},
        { Slice => {} }
    );

    my $whitelist = $dbh->selectall_arrayref(
        'SELECT ip, label, added_at FROM whitelist ORDER BY added_at DESC',
        { Slice => {} }
    );

    my $config = $dbh->selectall_arrayref(
        'SELECT key, value FROM config',
        { Slice => {} }
    );

    $dbh->disconnect();

    return {
        enabled         => $enabled,
        active_blocks   => $active_blocks,
        total_blocks    => $total_blocks,
        total_whitelist => $total_whitelist,
        blocks_today    => $blocks_today,
        blocked_ips     => $blocked_ips,
        history         => $history,
        whitelist       => $whitelist,
        config          => $config,
    };
}

# ─── HTML Principal ───────────────────────────────────────────────────────────
sub render_html {
    my $data    = get_stats();
    my $enabled = $data->{enabled} eq '1';

    my $switch_color  = $enabled ? '#22c55e' : '#ef4444';
    my $switch_label  = $enabled ? 'ACTIVO' : 'INACTIVO';
    my $switch_icon   = $enabled ? '🟢' : '🔴';
    my $status_text   = $enabled
        ? 'El sistema está protegiendo tu servidor'
        : '⚠️ MODO PASIVO — El servidor no está protegido';

    print "Content-Type: text/html\n\n";
    print <<HTML;
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WHM MailGuard</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #0f172a;
            color: #e2e8f0;
            min-height: 100vh;
            padding: 24px;
        }

        /* ── Header ── */
        .header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 24px;
            padding-bottom: 16px;
            border-bottom: 1px solid #1e293b;
        }
        .header h1 {
            font-size: 24px;
            font-weight: 700;
            color: #f1f5f9;
        }
        .header h1 span { color: #3b82f6; }
        .version { font-size: 12px; color: #64748b; margin-top: 2px; }

        /* ── Switch de emergencia ── */
        .emergency-card {
            background: #1e293b;
            border: 2px solid $switch_color;
            border-radius: 12px;
            padding: 20px 24px;
            margin-bottom: 24px;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }
        .emergency-info h2 {
            font-size: 16px;
            font-weight: 600;
            margin-bottom: 4px;
        }
        .emergency-info p {
            font-size: 13px;
            color: #94a3b8;
        }
        .switch-btn {
            background: $switch_color;
            color: white;
            border: none;
            border-radius: 8px;
            padding: 12px 24px;
            font-size: 15px;
            font-weight: 700;
            cursor: pointer;
            transition: all 0.2s;
            min-width: 140px;
        }
        .switch-btn:hover { opacity: 0.85; transform: scale(1.02); }

        /* ── Stats ── */
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 16px;
            margin-bottom: 24px;
        }
        .stat-card {
            background: #1e293b;
            border-radius: 10px;
            padding: 16px 20px;
            border-left: 4px solid #3b82f6;
        }
        .stat-card.danger  { border-left-color: #ef4444; }
        .stat-card.success { border-left-color: #22c55e; }
        .stat-card.warning { border-left-color: #f59e0b; }
        .stat-value {
            font-size: 28px;
            font-weight: 700;
            color: #f1f5f9;
        }
        .stat-label {
            font-size: 12px;
            color: #64748b;
            margin-top: 4px;
        }

        /* ── Tabs ── */
        .tabs {
            display: flex;
            gap: 4px;
            margin-bottom: 16px;
            background: #1e293b;
            padding: 4px;
            border-radius: 10px;
            width: fit-content;
        }
        .tab {
            padding: 8px 20px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 13px;
            font-weight: 500;
            color: #64748b;
            border: none;
            background: transparent;
            transition: all 0.2s;
        }
        .tab.active {
            background: #3b82f6;
            color: white;
        }

        /* ── Search ── */
        .search-bar {
            display: flex;
            gap: 8px;
            margin-bottom: 16px;
        }
        .search-bar input {
            flex: 1;
            background: #1e293b;
            border: 1px solid #334155;
            border-radius: 8px;
            padding: 10px 16px;
            color: #e2e8f0;
            font-size: 14px;
            outline: none;
        }
        .search-bar input:focus { border-color: #3b82f6; }
        .btn {
            background: #3b82f6;
            color: white;
            border: none;
            border-radius: 8px;
            padding: 10px 20px;
            font-size: 13px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
        }
        .btn:hover { background: #2563eb; }
        .btn.danger  { background: #ef4444; }
        .btn.success { background: #22c55e; }
        .btn.sm { padding: 6px 12px; font-size: 12px; }

        /* ── Table ── */
        .table-wrap {
            background: #1e293b;
            border-radius: 10px;
            overflow: hidden;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 13px;
        }
        th {
            background: #0f172a;
            padding: 12px 16px;
            text-align: left;
            font-size: 11px;
            font-weight: 600;
            color: #64748b;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        td {
            padding: 12px 16px;
            border-top: 1px solid #0f172a;
            vertical-align: middle;
        }
        tr:hover td { background: #243044; }
        .badge {
            display: inline-block;
            padding: 3px 8px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 600;
        }
        .badge.active  { background: #450a0a; color: #fca5a5; }
        .badge.freed   { background: #052e16; color: #86efac; }
        .badge.auto    { background: #1e3a5f; color: #93c5fd; }
        .ip-code {
            font-family: monospace;
            background: #0f172a;
            padding: 3px 8px;
            border-radius: 4px;
            font-size: 12px;
        }

        /* ── Panel de configuración ── */
        .config-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 16px;
        }
        .form-group { margin-bottom: 16px; }
        .form-group label {
            display: block;
            font-size: 12px;
            color: #94a3b8;
            margin-bottom: 6px;
            font-weight: 500;
        }
        .form-group input {
            width: 100%;
            background: #0f172a;
            border: 1px solid #334155;
            border-radius: 8px;
            padding: 10px 14px;
            color: #e2e8f0;
            font-size: 14px;
            outline: none;
        }
        .form-group input:focus { border-color: #3b82f6; }

        /* ── Resultado de búsqueda ── */
        #search-result {
            background: #1e293b;
            border-radius: 10px;
            padding: 16px;
            margin-bottom: 16px;
            display: none;
        }

        /* ── Panel sections ── */
        .panel { display: none; }
        .panel.active { display: block; }

        /* ── Toast ── */
        .toast {
            position: fixed;
            bottom: 24px;
            right: 24px;
            background: #22c55e;
            color: white;
            padding: 12px 20px;
            border-radius: 8px;
            font-size: 13px;
            font-weight: 600;
            display: none;
            z-index: 999;
            box-shadow: 0 4px 12px rgba(0,0,0,0.3);
        }
        .toast.error { background: #ef4444; }
    </style>
</head>
<body>

<!-- Header -->
<div class="header">
    <div>
        <h1>WHM <span>MailGuard</span></h1>
        <div class="version">v1.0.0 — Protección contra fuerza bruta</div>
    </div>
</div>

<!-- Switch de emergencia -->
<div class="emergency-card">
    <div class="emergency-info">
        <h2>$switch_icon Estado del sistema: <strong>$switch_label</strong></h2>
        <p>$status_text</p>
    </div>
    <button class="switch-btn" onclick="toggleSystem()">
        $switch_icon $switch_label
    </button>
</div>

<!-- Stats -->
<div class="stats-grid">
    <div class="stat-card danger">
        <div class="stat-value">$data->{active_blocks}</div>
        <div class="stat-label">IPs bloqueadas ahora</div>
    </div>
    <div class="stat-card warning">
        <div class="stat-value">$data->{blocks_today}</div>
        <div class="stat-label">Bloqueadas hoy</div>
    </div>
    <div class="stat-card">
        <div class="stat-value">$data->{total_blocks}</div>
        <div class="stat-label">Total historial</div>
    </div>
    <div class="stat-card success">
        <div class="stat-value">$data->{total_whitelist}</div>
        <div class="stat-label">IPs en whitelist</div>
    </div>
</div>

<!-- Tabs -->
<div class="tabs">
    <button class="tab active" onclick="showTab('blocked')">🔴 Bloqueadas</button>
    <button class="tab" onclick="showTab('search')">🔍 Buscar IP</button>
    <button class="tab" onclick="showTab('history')">📋 Historial</button>
    <button class="tab" onclick="showTab('whitelist')">✅ Whitelist</button>
    <button class="tab" onclick="showTab('config')">⚙️ Configuración</button>
</div>

<!-- Panel: Bloqueadas -->
<div id="panel-blocked" class="panel active">
    <div class="table-wrap">
        <table>
            <thead>
                <tr>
                    <th>IP</th>
                    <th>Cuenta atacada</th>
                    <th>Dominio</th>
                    <th>Intentos</th>
                    <th>Bloqueada</th>
                    <th>Se libera</th>
                    <th>Acciones</th>
                </tr>
            </thead>
            <tbody>
HTML

    for my $row (@{$data->{blocked_ips}}) {
        print <<ROW;
                <tr>
                    <td><span class="ip-code">$row->{ip}</span></td>
                    <td>$row->{account}</td>
                    <td>$row->{domain}</td>
                    <td><span class="badge active">$row->{attempts} intentos</span></td>
                    <td>$row->{blocked_at}</td>
                    <td>$row->{unblock_at}</td>
                    <td>
                        <button class="btn sm danger" onclick="unblockIP('$row->{ip}')">Desbloquear</button>
                        <button class="btn sm success" onclick="whitelistIP('$row->{ip}')">Whitelist</button>
                    </td>
                </tr>
ROW
    }

    print <<HTML;
            </tbody>
        </table>
    </div>
</div>

<!-- Panel: Buscar IP -->
<div id="panel-search" class="panel">
    <div class="search-bar">
        <input type="text" id="search-input" placeholder="Ingresa una IP o parte de ella (ej: 192.168.1)" />
        <button class="btn" onclick="searchIP()">🔍 Buscar</button>
    </div>
    <div id="search-result"></div>
</div>

<!-- Panel: Historial -->
<div id="panel-history" class="panel">
    <div class="table-wrap">
        <table>
            <thead>
                <tr>
                    <th>IP</th>
                    <th>Cuenta</th>
                    <th>Intentos</th>
                    <th>Bloqueada</th>
                    <th>Desbloqueada</th>
                    <th>Por</th>
                    <th>Estado</th>
                </tr>
            </thead>
            <tbody>
HTML

    for my $row (@{$data->{history}}) {
        my $estado = $row->{is_active}
            ? '<span class="badge active">Activo</span>'
            : '<span class="badge freed">Liberado</span>';
        my $by = $row->{unblocked_by} // '-';
        my $badge_by = $by eq 'auto'      ? '<span class="badge auto">Auto</span>'
                     : $by eq 'manual'    ? '<span class="badge freed">Manual</span>'
                     : $by eq 'whitelist' ? '<span class="badge success">Whitelist</span>'
                     : $by eq 'emergency' ? '<span class="badge active">Emergencia</span>'
                     : $by;

        print <<ROW;
                <tr>
                    <td><span class="ip-code">$row->{ip}</span></td>
                    <td>$row->{account}</td>
                    <td>$row->{attempts}</td>
                    <td>$row->{blocked_at}</td>
                    <td>${\($row->{unblocked_at} // '-')}</td>
                    <td>$badge_by</td>
                    <td>$estado</td>
                </tr>
ROW
    }

    print <<HTML;
            </tbody>
        </table>
    </div>
</div>

<!-- Panel: Whitelist -->
<div id="panel-whitelist" class="panel">
    <div class="search-bar" style="margin-bottom:16px">
        <input type="text" id="wl-ip" placeholder="IP a agregar (ej: 179.6.164.138)" />
        <input type="text" id="wl-label" placeholder="Etiqueta (ej: Cliente Juan)" style="max-width:200px" />
        <button class="btn success" onclick="addWhitelist()">✅ Agregar</button>
    </div>
    <div class="table-wrap">
        <table>
            <thead>
                <tr>
                    <th>IP</th>
                    <th>Etiqueta</th>
                    <th>Agregada</th>
                </tr>
            </thead>
            <tbody>
HTML

    for my $row (@{$data->{whitelist}}) {
        print <<ROW;
                <tr>
                    <td><span class="ip-code">$row->{ip}</span></td>
                    <td>$row->{label}</td>
                    <td>$row->{added_at}</td>
                </tr>
ROW
    }

    print <<HTML;
            </tbody>
        </table>
    </div>
</div>

<!-- Panel: Configuración -->
<div id="panel-config" class="panel">
    <div class="table-wrap" style="padding:24px">
        <div class="config-grid">
            <div>
                <div class="form-group">
                    <label>Máximo de intentos antes de bloquear</label>
                    <input type="number" id="cfg-max_attempts"
                           value="${\get_config('max_attempts','10')}" min="3" max="50" />
                </div>
                <div class="form-group">
                    <label>Ventana de tiempo (minutos)</label>
                    <input type="number" id="cfg-window_minutes"
                           value="${\get_config('window_minutes','10')}" min="1" max="60" />
                </div>
                <div class="form-group">
                    <label>Duración del bloqueo (minutos)</label>
                    <input type="number" id="cfg-block_minutes"
                           value="${\get_config('block_minutes','60')}" min="5" max="1440" />
                </div>
            </div>
            <div>
                <div class="form-group">
                    <label>Email de notificaciones</label>
                    <input type="email" id="cfg-notify_email"
                           value="${\get_config('notify_email','monitor\@motionpulse.net')}" />
                </div>
                <div class="form-group">
                    <label>Notificar al bloquear (1=sí, 0=no)</label>
                    <input type="number" id="cfg-notify_on_block"
                           value="${\get_config('notify_on_block','1')}" min="0" max="1" />
                </div>
            </div>
        </div>
        <button class="btn" onclick="saveConfig()">💾 Guardar configuración</button>
    </div>
</div>

<!-- Toast -->
<div class="toast" id="toast"></div>

<script>
// ── Tabs ──────────────────────────────────────────────────────────────────────
function showTab(name) {
    document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.getElementById('panel-' + name).classList.add('active');
    event.target.classList.add('active');
}

// ── Toast ─────────────────────────────────────────────────────────────────────
function toast(msg, isError = false) {
    const t = document.getElementById('toast');
    t.textContent = msg;
    t.className   = 'toast' + (isError ? ' error' : '');
    t.style.display = 'block';
    setTimeout(() => t.style.display = 'none', 3000);
}

// ── API helper ────────────────────────────────────────────────────────────────
async function api(params) {
    const qs  = new URLSearchParams(params).toString();
    const res = await fetch('?' + qs);
    return res.json();
}

// ── Switch de emergencia ──────────────────────────────────────────────────────
async function toggleSystem() {
    if (!confirm('¿Estás seguro? Esto activará/desactivará la protección del servidor.')) return;
    const data = await api({ action: 'toggle_enabled' });
    if (data.success) {
        toast(data.enabled === '1' ? '✅ Sistema ACTIVADO' : '⚠️ Sistema DESACTIVADO');
        setTimeout(() => location.reload(), 1500);
    }
}

// ── Desbloquear IP ────────────────────────────────────────────────────────────
async function unblockIP(ip) {
    if (!confirm('¿Desbloquear ' + ip + '?')) return;
    const data = await api({ action: 'unblock', ip });
    if (data.success) {
        toast('✅ IP ' + ip + ' desbloqueada');
        setTimeout(() => location.reload(), 1500);
    }
}

// ── Whitelist IP ──────────────────────────────────────────────────────────────
async function whitelistIP(ip) {
    const label = prompt('Etiqueta para esta IP (ej: Cliente Juan):', '');
    if (label === null) return;
    const data = await api({ action: 'whitelist', ip, label: label || 'Sin etiqueta' });
    if (data.success) {
        toast('✅ IP ' + ip + ' agregada a whitelist');
        setTimeout(() => location.reload(), 1500);
    }
}

// ── Agregar a whitelist ───────────────────────────────────────────────────────
async function addWhitelist() {
    const ip    = document.getElementById('wl-ip').value.trim();
    const label = document.getElementById('wl-label').value.trim() || 'Sin etiqueta';
    if (!ip) { toast('Ingresa una IP', true); return; }
    const data = await api({ action: 'whitelist', ip, label });
    if (data.success) {
        toast('✅ IP agregada a whitelist');
        setTimeout(() => location.reload(), 1500);
    }
}

// ── Buscar IP ─────────────────────────────────────────────────────────────────
async function searchIP() {
    const ip   = document.getElementById('search-input').value.trim();
    if (!ip) { toast('Ingresa una IP para buscar', true); return; }
    const data = await api({ action: 'search', ip });
    const div  = document.getElementById('search-result');
    div.style.display = 'block';

    if (!data.blocked.length && !data.whitelisted) {
        div.innerHTML = '<p style="color:#64748b">No se encontraron resultados para <strong>' + ip + '</strong></p>';
        return;
    }

    let html = '';

    if (data.whitelisted) {
        html += '<div style="background:#052e16;border-radius:8px;padding:12px;margin-bottom:12px">';
        html += '✅ <strong>' + data.whitelisted.ip + '</strong> está en la whitelist';
        html += ' — <em>' + data.whitelisted.label + '</em>';
        html += '</div>';
    }

    if (data.blocked.length) {
        html += '<table style="width:100%;font-size:13px"><thead><tr>';
        html += '<th>IP</th><th>Cuenta</th><th>Intentos</th><th>Fecha</th><th>Estado</th><th>Acciones</th>';
        html += '</tr></thead><tbody>';
        data.blocked.forEach(r => {
            const active = r.is_active == 1;
            html += '<tr>';
            html += '<td><span class="ip-code">' + r.ip + '</span></td>';
            html += '<td>' + r.account + '</td>';
            html += '<td>' + r.attempts + '</td>';
            html += '<td>' + r.blocked_at + '</td>';
            html += '<td>' + (active ? '<span class="badge active">Activo</span>' : '<span class="badge freed">Liberado</span>') + '</td>';
            html += '<td>';
            if (active) {
                html += '<button class="btn sm danger" onclick="unblockIP(\'' + r.ip + '\')">Desbloquear</button> ';
                html += '<button class="btn sm success" onclick="whitelistIP(\'' + r.ip + '\')">Whitelist</button>';
            }
            html += '</td></tr>';
        });
        html += '</tbody></table>';
    }

    div.innerHTML = html;
}

// ── Guardar configuración ─────────────────────────────────────────────────────
async function saveConfig() {
    const params = { action: 'save_config' };
    ['max_attempts','window_minutes','block_minutes','notify_email','notify_on_block'].forEach(k => {
        params[k] = document.getElementById('cfg-' + k).value;
    });
    const data = await api(params);
    if (data.success) toast('✅ Configuración guardada');
}

// ── Auto-refresh cada 30 segundos ─────────────────────────────────────────────
setInterval(() => location.reload(), 30000);
</script>

</body>
</html>
HTML
}

# ─── Router principal ─────────────────────────────────────────────────────────
if (param('action')) {
    handle_ajax();
} else {
    render_html();
}