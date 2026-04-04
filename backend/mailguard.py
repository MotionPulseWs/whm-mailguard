#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# WHM MailGuard - Detection Engine
# https://github.com/MotionPulseWs/whm-mailguard

import re
import sqlite3
import subprocess
import time
import smtplib
import logging
import os
import signal
import sys
from datetime import datetime, timedelta
from collections import defaultdict

# ─── Configuración de rutas ───────────────────────────────────────────────────
BASE_DIR    = os.path.dirname(os.path.abspath(__file__))
DB_PATH     = os.path.join(BASE_DIR, 'db', 'mailguard.db')
LOG_PATH    = '/var/log/mailguard.log'

# ─── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
log = logging.getLogger('mailguard')

# ─── Patrón de detección en logs de Exim ─────────────────────────────────────
# Detecta líneas como:
# dovecot_login authenticator failed for H=(...) [1.2.3.4]:port: 535 ... (set_id=user@domain)
PATTERN = re.compile(
    r'authenticator failed for.*?\[([0-9a-fA-F:.]+)\].*?set_id=([^\s\)]+)'
)

# ─── Base de datos ────────────────────────────────────────────────────────────
def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def get_config(key, default=None):
    with get_db() as db:
        row = db.execute('SELECT value FROM config WHERE key = ?', (key,)).fetchone()
        return row['value'] if row else default

def is_enabled():
    return get_config('enabled', '1') == '1'

def is_whitelisted(ip):
    with get_db() as db:
        row = db.execute('SELECT id FROM whitelist WHERE ip = ?', (ip,)).fetchone()
        return row is not None

# ─── Bloqueo de IPs ───────────────────────────────────────────────────────────
def block_ip(ip, account, attempts):
    if is_whitelisted(ip):
        log.info(f'IP {ip} en whitelist, ignorando bloqueo')
        return False

    block_minutes = int(get_config('block_minutes', '60'))
    unblock_at    = datetime.now() + timedelta(minutes=block_minutes)

    # Bloquear con iptables
    result = subprocess.run(
    ['iptables', '-I', 'INPUT', '-s', ip, '-j', 'DROP'],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )

    if result.returncode != 0:
        log.error(f'Error bloqueando {ip}: {result.stderr}')
        return False

    # Guardar en base de datos
    domain = account.split('@')[1] if '@' in account else None
    with get_db() as db:
        db.execute('''
            INSERT INTO blocked_ips (ip, attempts, account, domain, unblock_at)
            VALUES (?, ?, ?, ?, ?)
        ''', (ip, attempts, account, domain, unblock_at.strftime('%Y-%m-%d %H:%M:%S')))

        db.execute('''
            INSERT INTO events (event_type, ip, account, detail)
            VALUES ('block', ?, ?, ?)
        ''', (ip, account, f'{attempts} intentos fallidos'))

    log.info(f'BLOQUEADO: {ip} | cuenta: {account} | intentos: {attempts} | hasta: {unblock_at}')
    send_notification(ip, account, attempts, block_minutes)
    return True

def unblock_ip(ip, reason='auto'):
    subprocess.run(['iptables', '-D', 'INPUT', '-s', ip, '-j', 'DROP'],
               stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    with get_db() as db:
        db.execute('''
            UPDATE blocked_ips
            SET is_active=0, unblocked_at=CURRENT_TIMESTAMP, unblocked_by=?
            WHERE ip=? AND is_active=1
        ''', (reason, ip))

        db.execute('''
            INSERT INTO events (event_type, ip, detail)
            VALUES ('unblock', ?, ?)
        ''', (ip, f'Desbloqueado por: {reason}'))

    log.info('DESBLOQUEADO: ' + ip + ' | razon: ' + reason)

# ─── Desbloqueo automático ────────────────────────────────────────────────────
def process_auto_unblocks():
    with get_db() as db:
        expired = db.execute('''
            SELECT ip FROM blocked_ips
            WHERE is_active=1 AND unblock_at <= CURRENT_TIMESTAMP
        ''').fetchall()

    for row in expired:
        unblock_ip(row['ip'], reason='auto')

# ─── Notificaciones ───────────────────────────────────────────────────────────
def send_notification(ip, account, attempts, block_minutes):
    if get_config('notify_on_block', '1') != '1':
        return
    try:
        email   = get_config('notify_email', 'monitor@motionpulse.net')
        subject = f'[MailGuard] IP bloqueada: {ip}'
        body = (
            'WHM MailGuard bloqueo una IP.\r\n\r\n'
            'IP:       ' + ip + '\r\n'
            'Cuenta:   ' + account + '\r\n'
            'Intentos: ' + str(attempts) + '\r\n'
            'Duracion: ' + str(block_minutes) + ' minutos\r\n'
            'Fecha:    ' + datetime.now().strftime('%Y-%m-%d %H:%M:%S') + '\r\n'
        )
        msg = 'Subject: ' + subject + '\r\nFrom: mailguard@localhost\r\nTo: ' + email + '\r\n\r\n' + body
        with smtplib.SMTP('localhost') as s:
            s.sendmail('mailguard@localhost', [email], msg)
    except Exception as e:
        log.warning('No se pudo enviar notificacion: ' + str(e))

# ─── Motor principal ──────────────────────────────────────────────────────────
def run():
    log.info('WHM MailGuard iniciado')

    # Contadores en memoria: {ip: [(timestamp, account), ...]}
    attempts_tracker = defaultdict(list)

    exim_log = get_config('log_path', '/var/log/exim_mainlog')

    with open(exim_log, 'r') as f:
        f.seek(0, 2)  # Ir al final del archivo

        while True:
            # ── Switch de emergencia ──────────────────────────────────────────
            if not is_enabled():
                log.warning('MailGuard DESACTIVADO — modo pasivo')
                time.sleep(5)
                continue

            # ── Leer nuevas líneas ────────────────────────────────────────────
            line = f.readline()

            if not line:
                process_auto_unblocks()
                time.sleep(1)
                continue

            # ── Detectar intento fallido ──────────────────────────────────────
            match = PATTERN.search(line)
            if not match:
                continue

            ip      = match.group(1)
            account = match.group(2)
            now     = datetime.now()

            # Ignorar si ya está bloqueada o en whitelist
            if is_whitelisted(ip):
                continue

            with get_db() as db:
                active = db.execute(
                    'SELECT id FROM blocked_ips WHERE ip=? AND is_active=1', (ip,)
                ).fetchone()
                if active:
                    continue

            # ── Registrar intento ─────────────────────────────────────────────
            window  = int(get_config('window_minutes', '10'))
            cutoff  = now - timedelta(minutes=window)
            attempts_tracker[ip].append((now, account))

            # Limpiar intentos fuera de la ventana
            attempts_tracker[ip] = [
                (t, a) for t, a in attempts_tracker[ip] if t > cutoff
            ]

            count = len(attempts_tracker[ip])
            max_attempts = int(get_config('max_attempts', '10'))

            log.debug(f'{ip} → {account} | intentos en ventana: {count}/{max_attempts}')

            # ── Bloquear si supera el umbral ──────────────────────────────────
            if count >= max_attempts:
                if block_ip(ip, account, count):
                    attempts_tracker.pop(ip, None)

# ─── Manejo de señales (para systemd) ────────────────────────────────────────
def handle_signal(sig, frame):
    log.info('WHM MailGuard detenido')
    sys.exit(0)

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

# ─── Entry point ─────────────────────────────────────────────────────────────
if __name__ == '__main__':
    run()