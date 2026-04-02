#!/bin/bash
# WHM MailGuard - Uninstaller
# https://github.com/tu-usuario/whm-mailguard

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

# ─── Confirmación ─────────────────────────────────────────────────────────────
confirm() {
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║     ¿Deseas desinstalar WHM MailGuard?       ║${NC}"
    echo -e "${RED}║  Esto eliminará todos los datos e historial  ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    read -r -p "Escribe 'SI' para confirmar: " CONFIRM
    [ "$CONFIRM" = "SI" ] || { echo "Cancelado."; exit 0; }
}

# ─── Detener y eliminar servicio ──────────────────────────────────────────────
remove_service() {
    info "Deteniendo servicio..."

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
        success "Servicio detenido"
    else
        warning "El servicio no estaba activo"
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl disable "$SERVICE_NAME"
    fi

    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    systemctl daemon-reload
    success "Servicio eliminado"
}

# ─── Limpiar reglas de iptables ───────────────────────────────────────────────
cleanup_iptables() {
    info "Liberando IPs bloqueadas por MailGuard..."

    if [ -f "$INSTALL_DIR/backend/db/mailguard.db" ]; then
        BLOCKED_IPS=$(python3 -c "
import sqlite3
conn = sqlite3.connect('$INSTALL_DIR/backend/db/mailguard.db')
rows = conn.execute('SELECT ip FROM blocked_ips WHERE is_active=1').fetchall()
conn.close()
for row in rows:
    print(row[0])
" 2>/dev/null)

        COUNT=0
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            iptables -D INPUT -s "$ip" -j DROP 2>/dev/null && COUNT=$((COUNT+1))
        done <<< "$BLOCKED_IPS"

        success "$COUNT IPs desbloqueadas"
    else
        warning "Base de datos no encontrada — omitiendo limpieza de iptables"
    fi

    # Guardar cambios
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
}

# ─── Eliminar plugin WHM ──────────────────────────────────────────────────────
remove_whm_plugin() {
    info "Eliminando plugin WHM..."

    rm -f "$WHM_PLUGIN_DIR/mailguard.cgi"
    rm -f "$WHM_ADDON_DIR/mailguard.conf"

    success "Plugin WHM eliminado"
}

# ─── Opción de conservar logs ─────────────────────────────────────────────────
handle_logs() {
    echo ""
    echo -e "${YELLOW}¿Deseas conservar el historial de logs?${NC}"
    read -r -p "  (s/n): " KEEP_LOGS

    if [[ "$KEEP_LOGS" =~ ^[Ss]$ ]]; then
        BACKUP="/root/mailguard_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP"
        cp "$INSTALL_DIR/backend/db/mailguard.db" "$BACKUP/" 2>/dev/null || true
        cp "$LOG_FILE" "$BACKUP/" 2>/dev/null || true
        success "Backup guardado en $BACKUP"
    fi
}

# ─── Eliminar archivos ────────────────────────────────────────────────────────
remove_files() {
    info "Eliminando archivos de instalación..."

    rm -rf "$INSTALL_DIR"
    rm -f  "$LOG_FILE"

    success "Archivos eliminados"
}

# ─── Resumen final ────────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    WHM MailGuard desinstalado con éxito  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Todas las IPs bloqueadas han sido liberadas."
    echo -e "  El servidor queda sin protección activa."
    echo ""
    echo -e "  Para reinstalar:"
    echo -e "    ${BLUE}bash install.sh${NC}"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    [ "$EUID" -ne 0 ] && { echo "Debe ejecutarse como root"; exit 1; }

    echo ""
    echo -e "${RED}╔══════════════════════════════════════════╗${NC}"
    echo -e "${RED}║        WHM MailGuard Uninstaller         ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════╝${NC}"

    confirm
    remove_service
    cleanup_iptables
    remove_whm_plugin
    handle_logs
    remove_files
    show_summary
}

main "$@"