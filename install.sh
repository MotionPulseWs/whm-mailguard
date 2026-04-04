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
WHM_CGI_DIR='/usr/local/cpanel/whostmgr/docroot/cgi'
WHM_TMPL_DIR='/usr/local/cpanel/whostmgr/docroot/templates'
LOG_FILE='/var/log/mailguard.log'

# ─── Funciones ────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ─── Verificaciones previas ───────────────────────────────────────────────────
check_requirements() {
    info "Verificando requisitos..."
    [ "$EUID" -ne 0 ]                          && error "Debe ejecutarse como root"
    command -v python3 &>/dev/null             || error "Python3 no está instalado"
    python3 -c "import sqlite3, subprocess, re" 2>/dev/null || error "Módulos Python requeridos no disponibles"
    command -v iptables &>/dev/null            || error "iptables no está instalado"
    [ -f /var/log/exim_mainlog ]               || error "No se encontró /var/log/exim_mainlog"
    [ -d /usr/local/cpanel ]                   || warning "cPanel no detectado — el plugin WHM no se instalará"
    success "Requisitos verificados"
}

# ─── Instalación de archivos backend ─────────────────────────────────────────
install_backend() {
    info "Instalando backend en $INSTALL_DIR..."

    mkdir -p "$INSTALL_DIR/backend/db"
    mkdir -p "$INSTALL_DIR/whm-plugin/assets"

    # Solo copiar si no estamos en el mismo directorio
    if [ "$(pwd)" != "$INSTALL_DIR" ]; then
        cp -r backend/  "$INSTALL_DIR/"
        cp -r whm-plugin/ "$INSTALL_DIR/"
    fi

    chmod +x "$INSTALL_DIR/backend/mailguard.py"

    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"

    success "Backend instalado"
}

# ─── Base de datos ────────────────────────────────────────────────────────────
setup_database() {
    info "Creando base de datos..."

    python3 -c "
import sqlite3
conn = sqlite3.connect('$INSTALL_DIR/backend/db/mailguard.db')
with open('$INSTALL_DIR/backend/db/schema.sql') as f:
    conn.executescript(f.read())
conn.close()
print('OK')
"
    chmod 640 "$INSTALL_DIR/backend/db/mailguard.db"
    success "Base de datos lista"
}

# ─── Whitelist inicial ────────────────────────────────────────────────────────
setup_whitelist() {
    info "Configurando whitelist inicial..."

    SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || echo "")

    python3 -c "
import sqlite3
conn = sqlite3.connect('$INSTALL_DIR/backend/db/mailguard.db')
ips = [
    ('127.0.0.1', 'Localhost'),
    ('::1',       'Localhost IPv6'),
]
if '$SERVER_IP':
    ips.append(('$SERVER_IP', 'IP del servidor'))
for ip, label in ips:
    conn.execute('INSERT OR IGNORE INTO whitelist (ip, label, added_by) VALUES (?, ?, ?)', (ip, label, 'install'))
conn.commit()
conn.close()
"
    success "Whitelist inicial configurada"
}

# ─── IP del administrador ─────────────────────────────────────────────────────
add_admin_ip() {
    echo ""
    echo -e "${YELLOW}¿Cuál es tu IP fija de administración?${NC} (Enter para omitir)"
    read -r -p "IP: " ADMIN_IP

    if [ -n "$ADMIN_IP" ]; then
        python3 -c "
import sqlite3
conn = sqlite3.connect('$INSTALL_DIR/backend/db/mailguard.db')
conn.execute('INSERT OR IGNORE INTO whitelist (ip, label, added_by) VALUES (?, ?, ?)', ('$ADMIN_IP', 'IP Admin', 'install'))
conn.commit()
conn.close()
"
        success "IP $ADMIN_IP agregada a whitelist"
    fi
}

# ─── Servicio systemd ─────────────────────────────────────────────────────────
install_service() {
    info "Instalando servicio systemd..."

    cp "$INSTALL_DIR/backend/mailguard.service" "/etc/systemd/system/$SERVICE_NAME.service"
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

    mkdir -p "$WHM_CGI_DIR/mailguard/assets"

    cp "$INSTALL_DIR/whm-plugin/mailguard.pl" "$WHM_CGI_DIR/mailguard/index.cgi"
    chmod 755 "$WHM_CGI_DIR/mailguard/index.cgi"

    cp "$INSTALL_DIR/whm-plugin/assets/mailguard.js" "$WHM_CGI_DIR/mailguard/assets/"
    chmod 644 "$WHM_CGI_DIR/mailguard/assets/mailguard.js"

    cp "$INSTALL_DIR/whm-plugin/mailguard.tmpl" "$WHM_TMPL_DIR/"
    chmod 644 "$WHM_TMPL_DIR/mailguard.tmpl"

    cp "$INSTALL_DIR/whm-plugin/mailguard.conf" /var/cpanel/apps/
    /usr/local/cpanel/bin/register_appconfig /var/cpanel/apps/mailguard.conf

    success "Plugin WHM instalado"
    echo -e "  Accede en: ${BLUE}WHM → Plugins → MailGuard${NC}"
}

# ─── Resumen ──────────────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     WHM MailGuard instalado con éxito    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Servicio:  ${BLUE}systemctl status mailguard${NC}"
    echo -e "  Log:       ${BLUE}tail -f /var/log/mailguard.log${NC}"
    echo -e "  Plugin:    ${BLUE}https://TU_IP:2087/cgi/mailguard.pl${NC}"
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
    install_backend
    setup_database
    setup_whitelist
    add_admin_ip
    install_service
    install_whm_plugin
    show_summary
}

main "$@"