#!/bin/bash
# WHM MailGuard - Installer
# https://github.com/MotionPulseWs/whm-mailguard

set -e

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Variables ────────────────────────────────────────────────────────────────
INSTALL_DIR='/usr/local/mailguard'
SERVICE_NAME='mailguard'
WHM_PLUGIN_DIR='/usr/local/cpanel/whostmgr/docroot/cgi'
WHM_ADDON_DIR='/usr/local/cpanel/whostmgr/addonfeatures'
LOG_FILE='/var/log/mailguard.log'

# ─── Funciones ────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ─── Verificaciones previas ───────────────────────────────────────────────────
check_requirements() {
    info "Verificando requisitos..."

    [ "$EUID" -ne 0 ] && error "Debe ejecutarse como root"

    command -v python3 &>/dev/null || error "Python3 no está instalado"

    python3 -c "import sqlite3, subprocess, re" 2>/dev/null \
        || error "Módulos Python requeridos no disponibles"

    command -v iptables &>/dev/null || error "iptables no está instalado"

    [ -f /var/log/exim_mainlog ] || error "No se encontró /var/log/exim_mainlog"

    [ -d /usr/local/cpanel ] || warning "cPanel no detectado — el plugin WHM no se instalará"

    success "Requisitos verificados"
}

# ─── Instalación de archivos ──────────────────────────────────────────────────
install_files() {
    info "Instalando archivos en $INSTALL_DIR..."

    mkdir -p "$INSTALL_DIR/backend/db"

    cp -r backend/   "$INSTALL_DIR/"
    cp -r whm-plugin/ "$INSTALL_DIR/"

    chmod +x "$INSTALL_DIR/backend/mailguard.py"

    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"

    success "Archivos instalados"
}

# ─── Base de datos ────────────────────────────────────────────────────────────
setup_database() {
    info "Creando base de datos..."

    DB_PATH="$INSTALL_DIR/backend/db/mailguard.db"

    python3 -c "
import sqlite3
conn = sqlite3.connect('$DB_PATH')
with open('$INSTALL_DIR/backend/db/schema.sql') as f:
    conn.executescript(f.read())
conn.close()
print('Base de datos creada')
"
    chmod 640 "$DB_PATH"
    success "Base de datos lista"
}

# ─── Whitelist inicial ────────────────────────────────────────────────────────
setup_whitelist() {
    info "Configurando whitelist inicial..."

    # Obtener IP del servidor
    SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || echo "")

    python3 -c "
import sqlite3
conn = sqlite3.connect('$INSTALL_DIR/backend/db/mailguard.db')
ips = [
    ('127.0.0.1',  'Localhost'),
    ('::1',        'Localhost IPv6'),
]
server_ip = '$SERVER_IP'
if server_ip:
    ips.append((server_ip, 'IP del servidor'))

for ip, label in ips:
    conn.execute('''
        INSERT OR IGNORE INTO whitelist (ip, label, added_by)
        VALUES (?, ?, ?)
    ''', (ip, label, 'install'))
conn.commit()
conn.close()
print(f'Whitelist configurada con {len(ips)} entradas')
"
    success "Whitelist inicial configurada"
}

# ─── Servicio systemd ─────────────────────────────────────────────────────────
install_service() {
    info "Instalando servicio systemd..."

    cp "$INSTALL_DIR/backend/mailguard.service" \
       "/etc/systemd/system/$SERVICE_NAME.service"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start  "$SERVICE_NAME"

    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "Servicio iniciado correctamente"
    else
        error "El servicio no pudo iniciarse. Revisa: journalctl -u $SERVICE_NAME"
    fi
}

# ─── Plugin WHM ───────────────────────────────────────────────────────────────
install_whm_plugin() {
    if [ ! -d /usr/local/cpanel ]; then
        warning "cPanel no encontrado — saltando instalación del plugin WHM"
        return
    fi

    info "Instalando plugin WHM..."

    cp "$INSTALL_DIR/whm-plugin/mailguard.cgi" "$WHM_PLUGIN_DIR/"
    chmod 755 "$WHM_PLUGIN_DIR/mailguard.cgi"

    cp "$INSTALL_DIR/whm-plugin/mailguard.conf" "$WHM_ADDON_DIR/" 2>/dev/null || true

    success "Plugin WHM instalado"
}

# ─── Agregar IP del admin ─────────────────────────────────────────────────────
add_admin_ip() {
    echo ""
    echo -e "${YELLOW}¿Cuál es tu IP fija de administración?${NC}"
    echo -e "  (Déjalo vacío para omitir)"
    read -r -p "IP: " ADMIN_IP

    if [ -n "$ADMIN_IP" ]; then
        python3 -c "
import sqlite3
conn = sqlite3.connect('$INSTALL_DIR/backend/db/mailguard.db')
conn.execute('''
    INSERT OR IGNORE INTO whitelist (ip, label, added_by)
    VALUES (?, 'IP Admin', 'install')
''', ('$ADMIN_IP',))
conn.commit()
conn.close()
"
        success "IP $ADMIN_IP agregada a whitelist"
    fi
}

# ─── Resumen final ────────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     WHM MailGuard instalado con éxito    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Directorio:  ${BLUE}$INSTALL_DIR${NC}"
    echo -e "  Log:         ${BLUE}$LOG_FILE${NC}"
    echo -e "  Servicio:    ${BLUE}systemctl status $SERVICE_NAME${NC}"
    echo -e "  Plugin WHM:  ${BLUE}WHM → Plugins → MailGuard${NC}"
    echo ""
    echo -e "  Comandos útiles:"
    echo -e "    ${YELLOW}systemctl status mailguard${NC}   — ver estado"
    echo -e "    ${YELLOW}systemctl stop mailguard${NC}     — detener"
    echo -e "    ${YELLOW}tail -f /var/log/mailguard.log${NC} — ver logs en vivo"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         WHM MailGuard Installer          ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""

    check_requirements
    install_files
    setup_database
    setup_whitelist
    add_admin_ip
    install_service
    install_whm_plugin
    show_summary
}

main "$@"