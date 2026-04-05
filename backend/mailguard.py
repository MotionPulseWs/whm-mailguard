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
def block_ip(ip, account, attempts, reason='ip'):
    if is_whitelisted(ip):
        log.info('IP ' + ip + ' en whitelist, ignorando bloqueo')
        return False

    # Verificar si ya está bloqueada
    with get_db() as db:
        active = db.execute(
            'SELECT id FROM blocked_ips WHERE ip=? AND is_active=1', (ip,)
        ).fetchone()
        if active:
            return False

    block_minutes = int(get_config('block_minutes', '60'))
    unblock_at    = datetime.now() + timedelta(minutes=block_minutes)

   # Detectar si es IPv6
    is_ipv6 = ':' in ip
    cmd_block = 'ip6tables' if is_ipv6 else 'iptables'

    result = subprocess.run(
          [cmd_block, '-I', 'INPUT', '-s', ip, '-j', 'DROP'],
          stdout=subprocess.PIPE, stderr=subprocess.PIPE
      )

    if result.returncode != 0:
        log.error('Error bloqueando ' + ip + ': ' + str(result.stderr))
        return False

    domain = account.split('@')[1] if '@' in account else None
    detail = str(attempts) + ' intentos fallidos'
    if reason == 'account':
        detail = 'Ataque distribuido a cuenta: ' + account

    with get_db() as db:
        db.execute('''
            INSERT INTO blocked_ips (ip, attempts, account, domain, unblock_at)
            VALUES (?, ?, ?, ?, ?)
        ''', (ip, attempts, account, domain, unblock_at.strftime('%Y-%m-%d %H:%M:%S')))

        db.execute('''
            INSERT INTO events (event_type, ip, account, detail)
            VALUES ('block', ?, ?, ?)
        ''', (ip, account, detail))

    log.info('BLOQUEADO: ' + ip + ' | cuenta: ' + account + ' | intentos: ' + str(attempts) + ' | razon: ' + reason + ' | hasta: ' + str(unblock_at))
    send_notification(ip, account, attempts, block_minutes, reason)
    return True

def unblock_ip(ip, reason='auto'):
    is_ipv6 = ':' in ip
    cmd_unblock = 'ip6tables' if is_ipv6 else 'iptables'

    subprocess.run(
        [cmd_unblock, '-D', 'INPUT', '-s', ip, '-j', 'DROP'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )

    with get_db() as db:
        db.execute('''
            UPDATE blocked_ips
            SET is_active=0, unblocked_at=CURRENT_TIMESTAMP, unblocked_by=?
            WHERE ip=? AND is_active=1
        ''', (reason, ip))

        db.execute('''
            INSERT INTO events (event_type, ip, detail)
            VALUES ('unblock', ?, ?)
        ''', (ip, 'Desbloqueado por: ' + reason))

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
def send_notification(ip, account, attempts, block_minutes, reason='ip'):
    if get_config('notify_on_block', '1') != '1':
        return
    try:
        email   = get_config('notify_email', 'monitor@motionpulse.net')
        subject = '[MailGuard] IP bloqueada: ' + ip

        if reason == 'account':
            tipo = 'Ataque distribuido detectado (multiples IPs atacando misma cuenta)'
        else:
            tipo = 'Exceso de intentos fallidos desde una IP'

        body = (
            'WHM MailGuard bloqueo una IP.\r\n\r\n'
            'IP:       ' + ip + '\r\n'
            'Cuenta:   ' + account + '\r\n'
            'Intentos: ' + str(attempts) + '\r\n'
            'Tipo:     ' + tipo + '\r\n'
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

    # Tracker por IP: {ip: [(timestamp, account), ...]}
    attempts_tracker = defaultdict(list)

    # Tracker por cuenta: {account: [(timestamp, ip), ...]}
    account_tracker = defaultdict(list)

    exim_log = get_config('log_path', '/var/log/exim_mainlog')

    with open(exim_log, 'r') as f:
        f.seek(0, 2)  # Ir al final del archivo

        while True:
            # ── Switch de emergencia ──────────────────────────────────────────
            if not is_enabled():
                log.warning('MailGuard DESACTIVADO - modo pasivo')
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

            # Ignorar si ya está en whitelist
            if is_whitelisted(ip):
                continue

            # ── Ventana de tiempo ─────────────────────────────────────────────
            window  = int(get_config('window_minutes', '10'))
            cutoff  = now - timedelta(minutes=window)

            # ── REGLA 1: Bloqueo por IP ───────────────────────────────────────
            # Verificar si ya está bloqueada
            with get_db() as db:
                active = db.execute(
                    'SELECT id FROM blocked_ips WHERE ip=? AND is_active=1', (ip,)
                ).fetchone()
                if not active:
                    attempts_tracker[ip].append((now, account))
                    attempts_tracker[ip] = [
                        (t, a) for t, a in attempts_tracker[ip] if t > cutoff
                    ]

                    count        = len(attempts_tracker[ip])
                    max_attempts = int(get_config('max_attempts', '10'))

                    if count >= max_attempts:
                        if block_ip(ip, account, count, reason='ip'):
                            attempts_tracker.pop(ip, None)
                            # Limpiar también del tracker de cuenta
                            if account in account_tracker:
                                account_tracker[account] = [
                                    (t, i) for t, i in account_tracker[account] if i != ip
                                ]
                            continue

            # ── REGLA 2: Bloqueo por cuenta atacada ───────────────────────────
            # Registrar intento en tracker de cuenta
            account_tracker[account].append((now, ip))
            account_tracker[account] = [
                (t, i) for t, i in account_tracker[account] if t > cutoff
            ]

            # IPs únicas atacando esta cuenta en la ventana
            ips_atacando = set(i for t, i in account_tracker[account])
            max_ips      = int(get_config('max_ips_per_account', '5'))

            if len(ips_atacando) >= max_ips:
                log.info(
                    'Ataque distribuido detectado en cuenta: ' + account +
                    ' | IPs atacantes: ' + str(len(ips_atacando))
                )
                bloqueadas = 0
                for attacker_ip in ips_atacando:
                    intentos = len([t for t, i in account_tracker[account] if i == attacker_ip])
                    if block_ip(attacker_ip, account, intentos, reason='account'):
                        bloqueadas += 1
                        attempts_tracker.pop(attacker_ip, None)

                log.info('Ataque distribuido: ' + str(bloqueadas) + ' IPs bloqueadas para cuenta ' + account)
                account_tracker.pop(account, None)

# ─── Manejo de señales (para systemd) ────────────────────────────────────────
def handle_signal(sig, frame):
    log.info('WHM MailGuard detenido')
    sys.exit(0)

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

# ─── Entry point ─────────────────────────────────────────────────────────────
if __name__ == '__main__':
    run()