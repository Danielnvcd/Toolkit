# Toolkit

Utilidad portable para Windows 10/11 que junta en una sola ventana las tareas de soporte que normalmente se hacen a mano y en varios sitios. Es **un único archivo**, `Toolkit.exe`: no se instala, se copia y se ejecuta. Todo lo que necesita (.NET Framework 4.8 y Windows PowerShell 5.1) ya viene con Windows.

| Página | Qué hace |
|---|---|
| **Alta de puesto** | Deja un equipo nuevo listo en un clic: ubicación, micrófono y cámara, no suspender, hora NTP, apps del catálogo, check-in de Zoho e informe PDF |
| **Ubicación** | Activa la ubicación de Windows para todos los usuarios y navegadores, **sin reiniciar**, y comprueba que el check-in de Zoho funcionará |
| **Aplicaciones** | Instala, reinstala y desinstala en silencio desde un catálogo (MSI, EXE o ZIP, con SHA-256 obligatorio) |
| **Red** | Latencia, jitter, pérdida, DNS, puertos TCP, TLS, MTU y proxy |
| **Firewall** | Dice si una conexión la corta el firewall y qué regla; pausa de 5 min con reactivación automática; bloquear programas; filtro web por categorías |
| **Soporte** | Diagnósticos de un clic, reparaciones rápidas (red, audio, impresión, hora, temporales, SFC…), antivirus e informe PDF para el ticket |
| **Usuarios** | Cuentas locales: crear, cambiar o quitar contraseña, habilitar, deshabilitar y eliminar |

## Empezar

1. Copia `Toolkit.exe` al equipo (o ejecútalo desde el USB) y haz doble clic. Pide permisos de administrador.
2. Pulsa primero **Auditar** / **Comprobar instaladas**: no cambian nada, solo muestran el estado.
3. Luego aplica lo que haga falta. Todo queda en el log de la ventana y en `C:\ProgramData\Toolkit\logs\`.

**Revertir** (pestaña Ubicación) deshace los cambios de registro del toolkit. Las instalaciones, las cuentas y los bloqueos del firewall no se revierten desde ahí: se quitan desde su propia página.

## Línea de comandos

```powershell
Toolkit.exe                                # interfaz gráfica
Toolkit.exe /report                        # auditoría completa, no modifica nada
Toolkit.exe /checkin                       # ¿funcionará el check-in de Zoho?
Toolkit.exe /support                       # diagnóstico completo + informe PDF
Toolkit.exe /silent /all                   # aplica todo sin preguntar
Toolkit.exe /silent /apps:krisp /reinstall # reinstala encima (subir de versión)
Toolkit.exe /rollback                      # revierte los cambios de registro
Toolkit.exe /?                             # ayuda completa
```

En `/silent` el módulo de usuarios solo lista; nunca modifica cuentas.

Códigos de salida: `0` correcto · `3010` requiere reinicio · `5` sin permisos de administrador · `1001` falló la ubicación · `1002` falló alguna aplicación · `1003` red crítica · `1` otro error.

## Configurar

Todo se configura en `catalog.json` (ubicación, destinos de red, categorías del filtro web y aplicaciones). El exe lleva uno dentro; si pones otro **junto al exe**, se usa ese, sin recompilar.

Para añadir una aplicación, genera su ficha a partir del instalador y pégala en `apps`:

```powershell
scripts\tools\New-AppFicha.ps1 -Path 'D:\instaladores\MiApp.msi' -Id miapp
```

`enabled` solo afecta al despliegue desatendido; en la interfaz, lo que marca el técnico se instala siempre.

## Compilar

Requiere el SDK de .NET.

```powershell
cd build
.\build.ps1          # valida scripts, compila y deja dist\Toolkit.exe con su SHA-256
.\build.ps1 -Sign    # además lo firma (certificado de danielnvcd)
```

El exe es un envase en C# con los módulos de PowerShell (`scripts\modules\`) embebidos, que se ejecutan en memoria. Para desarrollar sin recompilar, `scripts\Toolkit.ps1` corre los mismos módulos desde un menú de consola.

**Firma:** el certificado autofirmado (`scripts\tools\New-SigningCert.ps1`) hace que UAC muestre "Editor comprobado: danielnvcd" una vez instalado en cada equipo con `scripts\tools\Install-SigningCert.ps1`. Para quitar el aviso de SmartScreen hace falta un certificado de una CA pública (`-Sign -Thumbprint <huella>`).

**Icono:** se genera desde `assets\logo.svg` con `scripts\tools\New-Logo.ps1`.

## Para muchos equipos

El toolkit puede instalarse como **agente** (tarea programada como SYSTEM) que lee un `manifest.json` de una carpeta compartida y sube los reportes en JSON:

```powershell
Toolkit.exe /install-agent /share:\\SERVIDOR\Toolkit$ /ring:piloto
Toolkit.exe /uninstall-agent
```

Para el primer despliegue está `scripts\deploy\Deploy-Remote.ps1` (WinRM o SMB). Firma el exe y prueba antes en una máquina virtual ([`docs/PRUEBAS-VM.md`](docs/PRUEBAS-VM.md)). Diseño en [`docs/PLAN.md`](docs/PLAN.md) y mejoras pendientes en [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Estado

Las auditorías y diagnósticos de solo lectura ya se probaron en un equipo real. Falta probar en máquina virtual antes de producción: aplicar la ubicación, instalar Genesys Cloud y Krisp, las reparaciones de Soporte y el agente.

## Autor y licencia

Creado por **danielnvcd**. [MIT](LICENSE).
