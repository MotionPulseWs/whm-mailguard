# WHM MailGuard 🛡️

Protección automática contra ataques de fuerza bruta para servidores WHM/cPanel.
Monitorea logs de Exim/Dovecot en tiempo real y bloquea IPs maliciosas automáticamente.

---

## ✨ Características

- 🔴/🟢 **Switch de emergencia** — apaga la protección con un clic y libera todas las IPs bloqueadas
- 🔍 **Buscador de IPs** — encuentra cualquier IP en el historial al instante
- 📋 **Historial completo** — registro de todos los bloqueos y desbloqueos
- ✅ **Whitelist** — agrega IPs de clientes o administradores para nunca bloquearlas
- ⚙️ **Configuración ajustable** — umbral de intentos, ventana de tiempo, duración del bloqueo
- 🔔 **Notificaciones por email** — aviso automático cuando se bloquea una IP
- 🔄 **Desbloqueo automático** — las IPs se liberan solas al vencer el tiempo configurado
- 🖥️ **Plugin integrado en WHM** — interfaz visual completa sin necesidad de terminal

---

## 📋 Requisitos

- WHM/cPanel instalado
- CentOS 7/8 o AlmaLinux 8/9
- Python 3.6 o superior
- iptables
- Exim + Dovecot

---

## 🚀 Instalación
```bash
# Clonar el repositorio
git clone https://github.com/tu-usuario/whm-mailguard.git
cd whm-mailguard

# Dar permisos al instalador
chmod +x install.sh

# Ejecutar como root
bash install.sh
```

El instalador te pedirá tu IP fija de administración para agregarla
a la whitelist automáticamente.

---

## 🗑️ Desinstalación
```bash
bash uninstall.sh
```

El desinstalador libera todas las IPs bloqueadas antes de eliminarse.
Opcionalmente puedes conservar el historial y los logs.

---

## ⚙️ Configuración por defecto

| Parámetro | Valor | Descripción |
|---|---|---|
| `max_attempts` | 10 | Intentos fallidos antes de bloquear |
| `window_minutes` | 10 | Ventana de tiempo para contar intentos |
| `block_minutes` | 60 | Duración del bloqueo automático |
| `notify_on_block` | 1 | Enviar email al bloquear una IP |

Puedes cambiar estos valores desde **WHM → MailGuard → ⚙️ Configuración**.

---

## 🖥️ Uso

### Desde WHM
```
WHM → Plugins → MailGuard
```

### Desde terminal
```bash
# Ver estado del servicio
systemctl status mailguard

# Ver logs en tiempo real
tail -f /var/log/mailguard.log

# Detener el servicio
systemctl stop mailguard

# Iniciar el servicio
systemctl start mailguard
```

---

## 🔴 Switch de emergencia

Si el sistema bloquea IPs legítimas o se comporta de forma inesperada:

1. Entra a **WHM → MailGuard**
2. Haz clic en el botón rojo **DESACTIVAR**
3. Todas las IPs bloqueadas se liberan automáticamente
4. El sistema entra en modo pasivo — sigue monitoreando pero no bloquea
5. Cuando soluciones el problema, reactívalo con el mismo botón

---

## 📁 Estructura del proyecto
```
whm-mailguard/
├── README.md
├── install.sh
├── uninstall.sh
├── backend/
│   ├── mailguard.py        # Motor de detección
│   ├── mailguard.service   # Servicio systemd
│   └── db/
│       └── schema.sql      # Esquema de base de datos
└── whm-plugin/
    ├── mailguard.conf      # Registro del plugin en WHM
    └── mailguard.cgi       # Interfaz web
```

---

## 🤝 Contribuir

Las contribuciones son bienvenidas. Por favor:

1. Haz fork del repositorio
2. Crea una rama: `git checkout -b feature/nueva-caracteristica`
3. Haz commit de tus cambios: `git commit -m 'Agrega nueva característica'`
4. Push a la rama: `git push origin feature/nueva-caracteristica`
5. Abre un Pull Request

---

## 📜 Licencia

MIT License — libre para usar, modificar y distribuir.

---

## 👤 Autor

Desarrollado para servidores WHM/cPanel con Exim + Dovecot.
Inspirado en la necesidad real de proteger hosting compartido
contra ataques de fuerza bruta distribuidos.

---

## ⭐ Si este proyecto te fue útil, dale una estrella en GitHub