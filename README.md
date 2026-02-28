<div align="center">

# ⚡ FW | Zabbix Auto-Installer ⚡

**Instalador universal y automatizado para Zabbix (Server / Proxy / Agent / Docker).**  
Deploy consistente, rápido y repetible para SysAdmins/DevOps.

<br/>

![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnu-bash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-Compatible-success)
![Zabbix](https://img.shields.io/badge/Zabbix-Automation-red)

[![Stars](https://img.shields.io/github/stars/micklo5188/zabbix-auto-installer)](https://github.com/micklo5188/zabbix-auto-installer/stargazers)
[![Issues](https://img.shields.io/github/issues/micklo5188/zabbix-auto-installer)](https://github.com/micklo5188/zabbix-auto-installer/issues)
[![Last Commit](https://img.shields.io/github/last-commit/micklo5188/zabbix-auto-installer)](https://github.com/micklo5188/zabbix-auto-installer/commits/main)

</div>

---

## ✅ Qué hace
Este proyecto automatiza el despliegue de Zabbix con un asistente interactivo.  
Se encarga de repos/versions, dependencias, DB/Web, hardening, puertos y modo Docker/Compose para que el setup sea rápido y confiable.

---

## 🧭 Tabla de contenido
- [Características](#-características)
- [Sistemas soportados](#-sistemas-soportados)
- [Requisitos](#-requisitos)
- [Instalación rápida](#-instalación-rápida)
- [Modos de despliegue](#-modos-de-despliegue)
- [Puertos](#-puertos)
- [Logs](#-logs)
- [Limpieza total / Uninstall](#-limpieza-total--uninstall)
- [Troubleshooting](#-troubleshooting)
- [Seguridad](#-seguridad)

---

## 🚀 Características
- **Multi-OS real:** instalación en múltiples distros con detección automática.
- **Smart Scraper:** detecta versiones disponibles y compatibles usando repos oficiales.
- **Deploy guiado:** Server / Proxy / Agent / Docker Stack.
- **Seguridad integrada:** UFW/Firewalld + ajustes SELinux cuando aplica.
- **Docker multi-instancia:** un stack por instancia con directorios separados y puertos dinámicos.
- **Logs completos:** logging para soporte y debugging.

---

## 🖥️ Sistemas soportados
Según modo (nativo o Docker), soporta:

- Debian / Ubuntu
- Oracle Linux / RHEL / Alma / Rocky / CentOS
- Amazon Linux
- openSUSE / SLES
- Arch (principalmente modo nativo/rolling)

> Para sumar soporte: abrí un issue incluyendo `cat /etc/os-release`.

---

## 🧩 Requisitos
- Ejecutar como **root** (`sudo`)
- Acceso a internet (repos / docker registry)
- Herramientas base: `bash`, `curl`, `wget`, `grep`, `awk`, `sed`

> En modo Docker: Docker instalado (el script puede instalarlo automáticamente).

---

## 🛠️ Instalación rápida

git clone https://github.com/FW-MechBoy/zabbix-auto-installer.git

cd zabbix-auto-installer

chmod +x zabbix_install.sh

sudo ./zabbix_install.sh

---

## 🧰 Modos de despliegue

El instalador ofrece:

[1] Zabbix Server (Nativo) → Frontend + DB + Server en el host

[2] Zabbix Proxy (Nativo) → Proxy con SQLite3

[3] Zabbix Agent (Nativo) → Agent/Agent2 según disponibilidad

[4] Zabbix Containers (Docker/Compose) → Stack oficial (Server + Web + DB) o Proxy/Agent en contenedores

---

## 🌐 Puertos

Por defecto:
Web UI: 80/tcp (o dinámico en Docker si el 80 está ocupado)
Zabbix Server: 10051/tcp
Zabbix Agent: 10050/tcp

---

## 🧾 Logs
Log principal: /tmp/zbx_install.log
Ver últimas líneas:
tail -n 200 /tmp/zbx_install.log

---

## 🧹 Limpieza total / Uninstall
⚠️ Esto puede borrar datos/DB/volúmenes. Usar con cuidado en producción.

cd zabbix-auto-installer

chmod +x zbx_clean.sh

sudo ./zbx_clean.sh

---

## 🧯 Troubleshooting
“Database error / Unable to select configuration”

Suele ocurrir cuando la UI levanta antes del import del schema o el server todavía inicializa.

Logs útiles (Docker):
docker ps
docker logs --tail=200 <container_db>
docker logs --tail=200 <container_server>
docker logs --tail=200 <container_web>

Health DB:
docker inspect --format '{{json .State.Health}}' <container_db>

---

## 🔐 Seguridad
No subas credenciales reales al repo.
Si exponés la UI a internet: TLS + reverse proxy + allowlists.
Cambiá credenciales por defecto en entornos productivos.


<div align="center">

⚡FW-Mech Boy⚡

</div> ```
