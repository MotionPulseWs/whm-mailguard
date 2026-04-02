-- WHM MailGuard - Database Schema
-- https://github.com/tu-usuario/whm-mailguard

CREATE TABLE IF NOT EXISTS blocked_ips (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ip          TEXT NOT NULL,
    attempts    INTEGER DEFAULT 1,
    account     TEXT,
    domain      TEXT,
    blocked_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    unblock_at  DATETIME,
    unblocked_at DATETIME,
    unblocked_by TEXT,         -- 'auto', 'manual', 'whitelist'
    is_active   INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS whitelist (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ip          TEXT NOT NULL UNIQUE,
    label       TEXT,          -- ej: "Cliente Juan", "Mi oficina"
    added_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
    added_by    TEXT DEFAULT 'manual'
);

CREATE TABLE IF NOT EXISTS events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type  TEXT NOT NULL,  -- 'block', 'unblock', 'whitelist', 'system_on', 'system_off'
    ip          TEXT,
    account     TEXT,
    detail      TEXT,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS config (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Configuración por defecto
INSERT OR IGNORE INTO config (key, value) VALUES
    ('enabled',         '1'),       -- 1=activo, 0=apagado (switch emergencia)
    ('max_attempts',    '10'),      -- intentos antes de bloquear
    ('window_minutes',  '10'),      -- ventana de tiempo para contar intentos
    ('block_minutes',   '60'),      -- duración del bloqueo
    ('log_path',        '/var/log/exim_mainlog'),
    ('notify_email',    'monitor@motionpulse.net'),
    ('notify_on_block', '1');       -- enviar email al bloquear

CREATE INDEX IF NOT EXISTS idx_blocked_ips_ip ON blocked_ips(ip);
CREATE INDEX IF NOT EXISTS idx_blocked_ips_active ON blocked_ips(is_active);
CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at);