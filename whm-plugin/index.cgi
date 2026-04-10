#!/usr/local/cpanel/3rdparty/bin/perl
# =============================================================================
# index.cgi — WHM MailGuard Router Principal
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

# ── Determinar sección activa ──
my $section = $form{section} || 'auth';
$section = 'auth' unless $section =~ /^(auth|mail)$/;

# ── Rutas ──
my $SECTIONS_DIR = '/usr/local/cpanel/whostmgr/docroot/cgi/mailguard/sections';

# ── Cargar sección correspondiente ──
my $html_output = '';

if ($section eq 'auth') {
    $html_output = do "$SECTIONS_DIR/auth.pl"
        or die "No se pudo cargar auth.pl: $!";
} elsif ($section eq 'mail') {
    $html_output = do "$SECTIONS_DIR/mail.pl"
        or die "No se pudo cargar mail.pl: $!";
}

# ── Render con template WHM ──
print "Content-type: text/html\r\n\r\n";
Cpanel::Template::process_template(
    'whostmgr',
    {
        'template_file'    => 'mailguard.tmpl',
        'mailguard_output' => $html_output,
    }
);