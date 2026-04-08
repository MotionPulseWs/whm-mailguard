#!/bin/bash
# WHM MailGuard - Quick Update
# Sincroniza los archivos después de un git pull

INSTALL_DIR='/usr/local/mailguard'
WHM_CGI_DIR='/usr/local/cpanel/whostmgr/docroot/cgi/mailguard'
WHM_TMPL_DIR='/usr/local/cpanel/whostmgr/docroot/templates'

echo "Actualizando WHM MailGuard..."

cd $INSTALL_DIR && git pull

cp $INSTALL_DIR/whm-plugin/mailguard.pl $WHM_CGI_DIR/index.cgi
chmod 755 $WHM_CGI_DIR/index.cgi

cp $INSTALL_DIR/whm-plugin/assets/mailguard.js $WHM_CGI_DIR/assets/mailguard.js
chmod 644 $WHM_CGI_DIR/assets/mailguard.js

cp $INSTALL_DIR/whm-plugin/mailguard.tmpl $WHM_TMPL_DIR/mailguard.tmpl
chmod 644 $WHM_TMPL_DIR/mailguard.tmpl

systemctl restart mailguard

echo "Listo!"