var MG_URL = window.location.href.split('?')[0] + '?section=auth';

function mgTab(name, el) {
    document.querySelectorAll('.mg-panel').forEach(function(p){ p.classList.remove('active'); });
    document.querySelectorAll('.mg-tab').forEach(function(t){ t.classList.remove('active'); });
    document.getElementById('mg-panel-' + name).classList.add('active');
    el.classList.add('active');
}

function mgToast(msg, err) {
    var t = document.getElementById('mg-toast');
    t.textContent = msg;
    t.className = 'mg-toast' + (err ? ' error' : '');
    t.style.display = 'block';
    setTimeout(function(){ t.style.display = 'none'; }, 3000);
}

function mgApi(params, callback) {
    var body = new URLSearchParams(params);
    fetch(MG_URL, { method: 'POST', body: body })
        .then(function(r){ return r.json(); })
        .then(callback)
        .catch(function(e){ mgToast('Error: ' + e, true); });
}

function mgToggle() {
    mgApi({ action: 'toggle_enabled' }, function(d) {
        if (d.success) {
            mgToast(d.enabled === '1' ? 'Sistema ACTIVADO' : 'Sistema DESACTIVADO');
            setTimeout(function(){ location.reload(); }, 1500);
        }
    });
}

function mgUnblock(ip) {
    
    mgApi({ action: 'unblock', ip: ip }, function(d) {
        if (d.success) { mgToast('IP ' + ip + ' desbloqueada'); setTimeout(function(){ location.reload(); }, 1500); }
    });
}

function mgWhitelist(ip) {
    var label = prompt('Etiqueta para ' + ip + ':', '');
    if (label === null) return;
    mgApi({ action: 'whitelist', ip: ip, label: label || 'Sin etiqueta' }, function(d) {
        if (d.success) { mgToast('IP ' + ip + ' en whitelist'); setTimeout(function(){ location.reload(); }, 1500); }
    });
}

function mgAddWhitelist() {
    var ip    = document.getElementById('mg-wl-ip').value.trim();
    var label = document.getElementById('mg-wl-label').value.trim() || 'Sin etiqueta';
    if (!ip) { mgToast('Ingresa una IP', true); return; }
    mgApi({ action: 'add_whitelist', ip: ip, label: label }, function(d) {
        if (d.success) { mgToast('IP agregada a whitelist'); setTimeout(function(){ location.reload(); }, 1500); }
    });
}

function mgSearch() {
    var ip = document.getElementById('mg-search-input').value.trim();
    if (!ip) { mgToast('Ingresa una IP', true); return; }
    mgApi({ action: 'search', ip: ip }, function(d) {
        var div = document.getElementById('mg-search-result');
        div.style.display = 'block';
        if (!d.blocked.length && !d.whitelisted) {
            div.innerHTML = '<p style="color:#586069">Sin resultados para <strong>' + ip + '</strong></p>';
            return;
        }
        var html = '';
        if (d.whitelisted) {
            html += '<div style="background:#dcffe4;border-radius:6px;padding:10px;margin-bottom:10px">';
            html += 'IP <strong>' + d.whitelisted.ip + '</strong> en whitelist: ' + d.whitelisted.label;
            html += '</div>';
        }
        if (d.blocked.length) {
            html += '<table style="width:100%;font-size:13px"><thead><tr><th>IP</th><th>Cuenta</th><th>Intentos</th><th>Fecha</th><th>Estado</th><th>Acciones</th></tr></thead><tbody>';
            d.blocked.forEach(function(r) {
                var active = r.is_active == 1;
                html += '<tr><td><span class="mg-ip">' + r.ip + '</span></td>';
                html += '<td>' + r.account + '</td>';
                html += '<td>' + r.attempts + '</td>';
                html += '<td>' + r.blocked_at + '</td>';
                html += '<td>' + (active ? '<span class="mg-badge mg-danger">Activo</span>' : '<span class="mg-badge mg-success">Liberado</span>') + '</td>';
                html += '<td>' + (active ? '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="mgUnblock(\'' + r.ip + '\')">Desbloquear</button>' : '') + '</td></tr>';
            });
            html += '</tbody></table>';
        }
        div.innerHTML = html;
    });
}

function mgSaveConfig() {
    var params = { action: 'save_config' };    
    ['max_attempts','window_minutes','block_minutes','notify_email','notify_on_block','max_ips_per_account','window_minutes_account'].forEach(function(k) {
        params[k] = document.getElementById('cfg-' + k).value;
    });
    mgApi(params, function(d) {
        if (d.success) mgToast('Configuracion guardada');
    });
}

function mgBindAll() {
    var switchBtn = document.getElementById('mg-switch-btn');
    if (switchBtn) {
        switchBtn.onclick = mgToggle;
    }
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mgBindAll);
} else {
    mgBindAll();
}

function mgRemoveWhitelist(ip) {
    mgApi({ action: 'remove_whitelist', ip: ip }, function(d) {
        if (d.success) { mgToast('IP ' + ip + ' eliminada de whitelist'); setTimeout(function(){ location.reload(); }, 1500); }
    });
}

function mgReload() {
    location.reload();
}