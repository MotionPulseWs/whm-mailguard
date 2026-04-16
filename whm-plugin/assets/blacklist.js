var BL_URL = window.location.href.split('?')[0];

// ── Mapeo de TLDs a países (para dominios) ────────────────────────────────────
var TLD_COUNTRIES = {
    'cn': '🇨🇳 China', 'ru': '🇷🇺 Rusia', 'in': '🇮🇳 India',
    'br': '🇧🇷 Brasil', 'vn': '🇻🇳 Vietnam', 'id': '🇮🇩 Indonesia',
    'pk': '🇵🇰 Pakistan', 'ua': '🇺🇦 Ucrania', 'tr': '🇹🇷 Turquia',
    'th': '🇹🇭 Tailandia', 'ng': '🇳🇬 Nigeria', 'ir': '🇮🇷 Iran',
    'kz': '🇰🇿 Kazajistan', 'bd': '🇧🇩 Bangladesh', 'ro': '🇷🇴 Rumania',
    'mx': '🇲🇽 Mexico', 'co': '🇨🇴 Colombia', 'ar': '🇦🇷 Argentina',
    'pe': '🇵🇪 Peru', 'cl': '🇨🇱 Chile', 've': '🇻🇪 Venezuela',
    'ec': '🇪🇨 Ecuador', 'de': '🇩🇪 Alemania', 'fr': '🇫🇷 Francia',
    'it': '🇮🇹 Italia', 'es': '🇪🇸 España', 'pl': '🇵🇱 Polonia',
    'nl': '🇳🇱 Paises Bajos', 'uk': '🇬🇧 Reino Unido', 'jp': '🇯🇵 Japon',
    'kr': '🇰🇷 Corea del Sur', 'hk': '🇭🇰 Hong Kong', 'tw': '🇹🇼 Taiwan',
    'sg': '🇸🇬 Singapur', 'my': '🇲🇾 Malasia', 'ph': '🇵🇭 Filipinas',
    'za': '🇿🇦 Sudafrica', 'eg': '🇪🇬 Egipto', 'ke': '🇰🇪 Kenya',
};

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
            document.getElementById('bl-domain-input').value = '';
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
            document.getElementById('bl-ip-input').value = '';
            setTimeout(function() { location.reload(); }, 1500);
        } else {
            mgToast(d.error || 'Error al bloquear', true);
        }
    });
}

// ── Eliminar de blacklist ──────────────────────────────────────────────────────
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

// ── Whitelist: Agregar ────────────────────────────────────────────────────────
function wlAdd() {
    var entry = document.getElementById('wl-input').value.trim();
    if (!entry) { mgToast('Ingresa una IP o dominio', true); return; }
    blApi({ action: 'wl_add', entry: entry }, function(d) {
        if (d.success) {
            mgToast('Agregado a whitelist: ' + entry);
            document.getElementById('wl-input').value = '';
            setTimeout(function() { location.reload(); }, 1500);
        } else {
            mgToast(d.error || 'Error al agregar', true);
        }
    });
}

// ── Whitelist: Eliminar ───────────────────────────────────────────────────────
function wlRemove(entry) {
    blApi({ action: 'wl_remove', entry: entry }, function(d) {
        if (d.success) {
            mgToast('Eliminado de whitelist: ' + entry);
            setTimeout(function() { location.reload(); }, 1500);
        } else {
            mgToast(d.error || 'Error al eliminar', true);
        }
    });
}

// ── GeoIP en background ───────────────────────────────────────────────────────
function loadGeoForRow(ip, rowId) {
    blApi({ action: 'geo_lookup', entry: ip }, function(d) {
        var cell = document.getElementById('geo-' + rowId);
        if (!cell) return;
        if (d.success && d.code !== '??') {
            cell.innerHTML = '<span class="mg-country">' + d.code + ' ' + d.country + '</span>';
        } else {
            cell.innerHTML = '<span class="mg-country" style="color:#ccc">—</span>';
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
        html += '<th>Entrada</th><th>Tipo</th><th>Pais</th><th>Apariciones</th><th>Accion</th>';
        html += '</tr></thead><tbody>';

        d.suggestions.forEach(function(s, idx) {
            var rowId = 'row-' + idx;
            var tipo = s.type === 'domain'
                ? '<span class="mg-badge mg-danger">Dominio</span>'
                : '<span class="mg-badge mg-warning">IP</span>';

            // País: para dominio usamos TLD, para IP placeholder que se llena después
            var countryCell = '';
            if (s.type === 'domain') {
                var tld = s.tld ? s.tld.toLowerCase() : '';
                var countryName = TLD_COUNTRIES[tld] || (tld ? '.' + s.tld : '—');
                countryCell = '<span class="mg-country">' + countryName + '</span>';
            } else {
                // IP: mostrar spinner, luego se reemplaza
                countryCell = '<span id="geo-' + rowId + '" class="mg-country">⏳</span>';
            }

            html += '<tr id="' + rowId + '">';
            html += '<td><span class="mg-ip">' + s.entry + '</span></td>';
            html += '<td>' + tipo + '</td>';
            html += '<td>' + countryCell + '</td>';
            html += '<td>' + s.count + ' veces</td>';
            html += '<td>';
            html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="blBlock(\'' + s.entry + '\',\'' + s.type + '\',\'' + rowId + '\')">🚫 Bloquear</button> ';
            html += '<button class="mg-btn mg-btn-sm mg-btn-success" onclick="wlAddFromAnalyze(\'' + s.entry + '\',\'' + rowId + '\')">✅ Whitelist</button>';
            html += '</td>';
            html += '</tr>';
        });

        html += '</tbody></table>';
        div.style.display = 'block';
        div.innerHTML = html;

        // Cargar geo en background solo para IPs
        d.suggestions.forEach(function(s, idx) {
            if (s.type === 'ip') {
                var rowId = 'row-' + idx;
                setTimeout(function() { loadGeoForRow(s.entry, rowId); }, idx * 150);
            }
        });
    });
}

// ── Bloquear desde analizador (sin reload) ────────────────────────────────────
function blBlock(entry, type, rowId) {
    blApi({ action: 'bl_add', entry: entry, type: type }, function(d) {
        if (d.success) {
            mgToast('Bloqueado: ' + entry);
            // Eliminar la fila del DOM sin recargar
            var row = document.getElementById(rowId);
            if (row) {
                row.style.transition = 'opacity 0.3s';
                row.style.opacity = '0';
                setTimeout(function() { row.remove(); }, 300);
            }
        } else {
            mgToast(d.error || 'Error al bloquear', true);
        }
    });
}

// ── Agregar a whitelist desde analizador (sin reload) ─────────────────────────
function wlAddFromAnalyze(entry, rowId) {
    blApi({ action: 'wl_add', entry: entry }, function(d) {
        if (d.success) {
            mgToast('Agregado a whitelist: ' + entry);
            var row = document.getElementById(rowId);
            if (row) {
                row.style.transition = 'opacity 0.3s';
                row.style.opacity = '0';
                setTimeout(function() { row.remove(); }, 300);
            }
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

    var wlAddBtn = document.getElementById('wl-add-btn');
    if (wlAddBtn) wlAddBtn.onclick = wlAdd;

    // Enter en inputs
    var domainInput = document.getElementById('bl-domain-input');
    if (domainInput) domainInput.onkeypress = function(e) {
        if (e.key === 'Enter') blAddDomain();
    };

    var ipInput = document.getElementById('bl-ip-input');
    if (ipInput) ipInput.onkeypress = function(e) {
        if (e.key === 'Enter') blAddIP();
    };

    var wlInput = document.getElementById('wl-input');
    if (wlInput) wlInput.onkeypress = function(e) {
        if (e.key === 'Enter') wlAdd();
    };
}

// ── Inicializar ───────────────────────────────────────────────────────────────
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', blBindAll);
} else {
    blBindAll();
}