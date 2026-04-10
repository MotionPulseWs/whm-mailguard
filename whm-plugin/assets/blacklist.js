var BL_URL = window.location.href.split('?')[0];

// ── Toast ─────────────────────────────────────────────────────────────────────
function mgToast(msg, err) {
    var t = document.getElementById('mg-toast');
    if (!t) return;
    t.textContent = msg;
    t.className = 'mg-toast' + (err ? ' error' : '');
    t.style.display = 'block';
    setTimeout(function() { t.style.display = 'none'; }, 3000);
}

// ── Tabs ──────────────────────────────────────────────────────────────────────
function mgTab(name, el) {
    document.querySelectorAll('.mg-panel').forEach(function(p) {
        p.classList.remove('active');
    });
    document.querySelectorAll('.mg-tab').forEach(function(t) {
        t.classList.remove('active');
    });
    document.getElementById('mg-panel-' + name).classList.add('active');
    el.classList.add('active');
}

// ── API helper ────────────────────────────────────────────────────────────────
function blApi(params, callback) {
    var body = new URLSearchParams(params);
    fetch(BL_URL + '?section=mail', { method: 'POST', body: body })
        .then(function(r) { return r.json(); })
        .then(callback)
        .catch(function(e) { mgToast('Error: ' + e, true); });
}

// ── Agregar dominio ───────────────────────────────────────────────────────────
function blAddDomain() {
    var entry = document.getElementById('bl-domain-input').value.trim();
    if (!entry) { mgToast('Ingresa un dominio', true); return; }
    blApi({ action: 'bl_add', entry: entry, type: 'domain' }, function(d) {
        if (d.success) {
            mgToast('Dominio bloqueado: ' + entry);
            setTimeout(function() { location.reload(); }, 1500);
        } else {
            mgToast(d.error || 'Error al bloquear', true);
        }
    });
}

// ── Agregar IP ────────────────────────────────────────────────────────────────
function blAddIP() {
    var entry = document.getElementById('bl-ip-input').value.trim();
    if (!entry) { mgToast('Ingresa una IP o subred', true); return; }
    blApi({ action: 'bl_add', entry: entry, type: 'ip' }, function(d) {
        if (d.success) {
            mgToast('IP bloqueada: ' + entry);
            setTimeout(function() { location.reload(); }, 1500);
        } else {
            mgToast(d.error || 'Error al bloquear', true);
        }
    });
}

// ── Eliminar entrada ──────────────────────────────────────────────────────────
function blRemove(entry, type) {
    blApi({ action: 'bl_remove', entry: entry, type: type }, function(d) {
        if (d.success) {
            mgToast('Entrada eliminada: ' + entry);
            setTimeout(function() { location.reload(); }, 1500);
        } else {
            mgToast(d.error || 'Error al eliminar', true);
        }
    });
}

// ── Analizar logs ─────────────────────────────────────────────────────────────
function blAnalyze() {
    var btn = document.getElementById('bl-analyze-btn');
    var div = document.getElementById('bl-analyze-result');
    btn.textContent = 'Analizando...';
    btn.disabled = true;
    div.style.display = 'none';

    blApi({ action: 'bl_analyze' }, function(d) {
        btn.textContent = '🔍 Analizar logs ahora';
        btn.disabled = false;

        if (!d.success) {
            mgToast(d.error || 'Error al analizar', true);
            return;
        }

        if (!d.suggestions || d.suggestions.length === 0) {
            div.style.display = 'block';
            div.innerHTML = '<p style="color:#586069">No se encontraron entradas sospechosas nuevas.</p>';
            return;
        }

        var html = '<table style="width:100%;font-size:13px"><thead><tr>';
        html += '<th>Entrada</th><th>Tipo</th><th>Apariciones</th><th>Accion</th>';
        html += '</tr></thead><tbody>';

        d.suggestions.forEach(function(s) {
            var tipo = s.type === 'domain'
                ? '<span class="mg-badge mg-danger">Dominio</span>'
                : '<span class="mg-badge mg-warning">IP</span>';
            html += '<tr>';
            html += '<td><span class="mg-ip">' + s.entry + '</span></td>';
            html += '<td>' + tipo + '</td>';
            html += '<td>' + s.count + ' veces</td>';
            html += '<td><button class="mg-btn mg-btn-sm mg-btn-danger" onclick="blRemoveFromSuggestion(\'' + s.entry + '\',\'' + s.type + '\')">🚫 Bloquear</button></td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
        div.style.display = 'block';
        div.innerHTML = html;
    });
}

// ── Bloquear desde sugerencias ────────────────────────────────────────────────
function blRemoveFromSuggestion(entry, type) {
    blApi({ action: 'bl_add', entry: entry, type: type }, function(d) {
        if (d.success) {
            mgToast('Bloqueado: ' + entry);
            setTimeout(function() { location.reload(); }, 1500);
        } else {
            mgToast(d.error || 'Error', true);
        }
    });
}

// ── Binding de eventos ────────────────────────────────────────────────────────
function blBindAll() {
    var domainAddBtn = document.getElementById('bl-domain-add-btn');
    if (domainAddBtn) domainAddBtn.onclick = blAddDomain;

    var ipAddBtn = document.getElementById('bl-ip-add-btn');
    if (ipAddBtn) ipAddBtn.onclick = blAddIP;

    var analyzeBtn = document.getElementById('bl-analyze-btn');
    if (analyzeBtn) analyzeBtn.onclick = blAnalyze;

    var reloadBtn = document.getElementById('bl-reload-btn');
    if (reloadBtn) reloadBtn.onclick = function() { location.reload(); };

    // Enter en inputs
    var domainInput = document.getElementById('bl-domain-input');
    if (domainInput) domainInput.onkeypress = function(e) {
        if (e.key === 'Enter') blAddDomain();
    };

    var ipInput = document.getElementById('bl-ip-input');
    if (ipInput) ipInput.onkeypress = function(e) {
        if (e.key === 'Enter') blAddIP();
    };
}

// ── Inicializar ───────────────────────────────────────────────────────────────
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', blBindAll);
} else {
    blBindAll();
}