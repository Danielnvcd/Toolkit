# Toolkit Call Center

Herramienta de configuración para una flota de 400 PCs de call center: activa la ubicación de Windows (servicio + políticas + todos los perfiles, **sin reiniciar el equipo**), instala el stack de aplicaciones corporativas, diagnostica la red y gestiona las cuentas de usuario locales.

**El entregable es un único `Toolkit.exe` firmado, sin dependencias, con los scripts dentro.**

---

## Cómo está montado

```
Toolkit.exe                       el envase (C#)
   └── recursos embebidos         el trabajo real (PowerShell)
         Toolkit.Core.psm1
         Toolkit.Location.psm1    modulo A
         Toolkit.Apps.psm1        modulo B
         Toolkit.Network.psm1     modulo C
         Toolkit.Users.psm1       modulo D (usuarios locales)
         Invoke-ToolkitRun.ps1    orquestador
         catalog.json
```

Los `.psm1` **nunca se escriben en disco**: se cargan en un runspace de PowerShell dentro del propio proceso. Eso elimina los problemas de `ExecutionPolicy`, de antivirus bloqueando scripts sueltos y de que alguien edite un script en un equipo y la flota diverja.

`Invoke-ToolkitRun.ps1` es la **única** fuente de la lógica y la comparten los dos caminos: el exe y `Toolkit.ps1` (envoltorio de línea de comandos para depurar sin recompilar). La interfaz gráfica y el despliegue masivo ejecutan literalmente el mismo código.

El plan completo está en [`docs/PLAN.md`](docs/PLAN.md).
El procedimiento de pruebas en máquina virtual, en [`docs/PRUEBAS-VM.md`](docs/PRUEBAS-VM.md).

---

## Compilar

Requiere **Windows** con el SDK de .NET (incluye el targeting pack de .NET Framework 4.8).

```powershell
cd build
.\build.ps1                                  # valida scripts -> compila -> verifica recursos
.\build.ps1 -Sign -Thumbprint <huella>       # + firma Authenticode
```

`build.ps1` valida la sintaxis de cada `.psm1` **antes** de embeberlo. Un error de sintaxis no rompe la compilación de C#: se embebería igual y explotaría en el equipo del cliente.

---

## Usar

```powershell
Toolkit.exe                            # interfaz grafica (tecnico en sitio)
Toolkit.exe /report                    # auditoria: NO modifica nada  <- empieza siempre por aqui
Toolkit.exe /silent /all               # desatendido: aplica todo
Toolkit.exe /silent /modules:location,network
Toolkit.exe /silent /apps:netextender,goto
Toolkit.exe /report /modules:users        # inventario de cuentas locales
Toolkit.exe /rollback                  # revierte los cambios de registro
Toolkit.exe /install-agent /share:\\SRV-FILE\Toolkit$ /ring:1-piloto
Toolkit.exe /uninstall-agent
```

### Ubicación: por qué no hace falta reiniciar

`lfsvc` (el servicio de geolocalización) lee el interruptor maestro y el consentimiento **solo al arrancar**. Escribir el registro y no reiniciar el servicio es la causa de que "se active pero no funciona hasta reiniciar la PC". El módulo, tras aplicar las cuatro capas, **reinicia `lfsvc`** y después consulta la API de geolocalización para confirmar que responde. No se reinicia el equipo ni se cierra ninguna sesión.

Por cada perfil de usuario (con sesión abierta, con la colmena descargada, y el perfil `Default` para usuarios futuros) se escriben dos consentimientos: el general y el de **apps de escritorio** (`NonPackaged`), que es el que necesitan el softphone y el CRM.

### Usuarios locales

La pestaña **Usuarios** de la interfaz (y la opción `U` del menú de `Toolkit.ps1`) permite:

| Acción | Detalle |
|---|---|
| Listar | estado, si es administrador, si requiere contraseña, último inicio, sesión abierta, carpeta de perfil |
| Cambiar contraseña | vuelve a marcar la cuenta como "contraseña requerida" |
| Quitar contraseña | inicio de sesión directo; Windows sólo lo permite en consola local, no por red ni RDP |
| Habilitar / deshabilitar | |
| Eliminar | con o sin la carpeta `C:\Users\<nombre>` |
| Crear | con o sin contraseña, opcionalmente administrador local |

Protecciones: no se puede eliminar una cuenta integrada de Windows, la cuenta que está ejecutando el toolkit ni una cuenta con sesión abierta. Estas acciones **no** pasan por `rollback.json` (no son reversibles) y se registran en el log sin la contraseña. En el despliegue desatendido (`/silent`) el módulo `users` sólo inventaría; nunca modifica cuentas.

### Códigos de salida

| | | | |
|---|---|---|---|
| `0` correcto | `3010` requiere reinicio | `5` sin privilegios | `1` fallo genérico |
| `1001` falló ubicación | `1002` falló alguna app | `1003` red crítica | |

---

## Antes de desplegar a los 400

1. **Rellenar las fichas de aplicación.** No se escriben a mano:
   ```powershell
   scripts\tools\New-AppFicha.ps1 -Path 'D:\instaladores\NetExtender.msi' -Id netextender -OutputDir docs\APP-FICHAS
   ```
   Lee el `ProductCode`, la versión, las propiedades públicas del MSI (ahí están `SERVER`, `COMPANYKEY`...) y el SHA-256. Después hay que **validar la instalación en una VM limpia** antes de poner `enabled: true`.

2. **Cambiar los destinos de red** en `scripts/config/catalog.json` (todo lo marcado `CAMBIAR`): conmutador, CRM, VPN.

3. **Ajustar la ventana de mantenimiento** (`Test-MaintenanceWindow` en `Toolkit.Core.psm1`) a los turnos reales. Por defecto es 23:00–07:00; en una operación 24/7 no se instalaría nunca nada.

4. **Comprar el certificado de firma.** Sin firma, SmartScreen y el antivirus bloquean el exe y acabas creando 400 excepciones a mano. Es la dependencia externa más lenta del proyecto.

5. **Validar para qué se necesita la ubicación** con el proveedor de telefonía. Sin GPS, Windows la resuelve por WiFi/IP con precisión de decenas o cientos de metros; si el caso de uso es E911, hay que confirmar que eso sirve.

---

## Despliegue sin infraestructura

No hay GPO, ni Intune, ni RMM. La estrategia (detallada en §12 del plan) es que el exe **se instale a sí mismo como agente**: una tarea programada que corre como SYSTEM cada 4 horas, lee un `manifest.json` de un recurso compartido y se auto-actualiza.

Una sola pasada manual por equipo. A partir de ahí, cualquier cambio se despliega editando un JSON en el share.

```powershell
# Despliegue masivo inicial (WinRM, con respaldo por SMB)
scripts\deploy\Deploy-Remote.ps1 -ComputerList .\equipos-anillo1.txt `
                                 -SharePath \\SRV-FILE\Toolkit$ `
                                 -Credential (Get-Credential)
```

Deja un CSV con el resultado por equipo y un `.pendientes.txt` con los que hay que reintentar o visitar a mano.

---

## Estado

El código está escrito pero **no se ha ejecutado todavía**: se desarrolló en Linux y necesita Windows para compilarse y probarse. Ver "Estado actual del repositorio" en el plan para el detalle de qué falta.
