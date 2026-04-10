#!/bin/bash
# WHM MailGuard - Quick Update
# https://github.com/MotionPulseWs/whm-mailguard

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR='/usr/local/mailguard'
WHM_CGI_DIR='/usr/local/cpanel/whostmgr/docroot/cgi/mailguard'
WHM_TMPL_DIR='/usr/local/cpanel/whostmgr/docroot/templates'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && error "Debe ejecutarse como root"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         WHM MailGuard Updater            ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ─── Git pull ─────────────────────────────────────────────────────────────────
info "Actualizando desde GitHub..."
cd "$INSTALL_DIR" && git pull
success "Repositorio actualizado"

# ─── Backend ──────────────────────────────────────────────────────────────────
info "Actualizando backend..."
cp "$INSTALL_DIR/backend/mailguard.py" "$INSTALL_DIR/backend/mailguard.py"
chmod +x "$INSTALL_DIR/backend/mailguard.py"
success "Backend actualizado"

# ─── Plugin WHM ───────────────────────────────────────────────────────────────
info "Actualizando plugin WHM..."

mkdir -p "$WHM_CGI_DIR/sections"
mkdir -p "$WHM_CGI_DIR/assets"

cp "$INSTALL_DIR/whm-plugin/index.cgi"           "$WHM_CGI_DIR/index.cgi"
cp "$INSTALL_DIR/whm-plugin/sections/auth.pl"    "$WHM_CGI_DIR/sections/auth.pl"
cp "$INSTALL_DIR/whm-plugin/sections/mail.pl"    "$WHM_CGI_DIR/sections/mail.pl"
cp "$INSTALL_DIR/whm-plugin/assets/mailguard.js" "$WHM_CGI_DIR/assets/mailguard.js"
cp "$INSTALL_DIR/whm-plugin/assets/blacklist.js" "$WHM_CGI_DIR/assets/blacklist.js"
cp "$INSTALL_DIR/whm-plugin/mailguard.tmpl"      "$WHM_TMPL_DIR/mailguard.tmpl"

chmod 755 "$WHM_CGI_DIR/index.cgi"
chmod 644 "$WHM_CGI_DIR/sections/auth.pl"
chmod 644 "$WHM_CGI_DIR/sections/mail.pl"
chmod 644 "$WHM_CGI_DIR/assets/mailguard.js"
chmod 644 "$WHM_CGI_DIR/assets/blacklist.js"
chmod 644 "$WHM_TMPL_DIR/mailguard.tmpl"

success "Plugin WHM actualizado"

# ─── Reiniciar servicio ───────────────────────────────────────────────────────
info "Reiniciando servicio mailguard..."
systemctl restart mailguard
sleep 2

if systemctl is-active --quiet mailguard; then
    success "Servicio reiniciado correctamente"
else
    echo -e "${RED}[ERROR]${NC} El servicio no pudo reiniciarse"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      WHM MailGuard actualizado           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""