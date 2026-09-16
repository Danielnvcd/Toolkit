# Toolkit Windows — Call Center (400 PCs)
### Plan técnico de arquitectura, construcción y despliegue

**Versión:** 0.1 (borrador para revisión)
**Fecha:** 2026-09-15
**Entregable:** un único ejecutable `Toolkit.exe` firmado, sin dependencias, que configura ubicación (servicio + políticas), instala el stack de aplicaciones corporativas y diagnostica la red.

---

## 0. Resumen ejecutivo

| | |
|---|---|
| **Qué se construye** | Un binario único `Toolkit.exe` (~2–4 MB) que contiene todos los módulos embebidos. Sin `.ps1` sueltos, sin instalador, sin runtime que instalar. |
| **Tecnología principal** | **C# sobre .NET Framework 4.8** — presente de fábrica en todo Windows 10 1903+ y Windows 11. Cero despliegue de runtime. |
| **Tres modos en un solo binario** | GUI (técnico en sitio) · Silencioso (despliegue masivo) · Solo-reporte (auditoría sin cambios) |
| **El riesgo real no es el código** | Es el despliegue. Con 400 equipos y cero infraestructura de gestión, el 70% del esfuerzo del proyecto está en **cómo llega y se ejecuta el exe**, no en qué hace. |
| **Duración estimada** | 6–8 semanas hasta cobertura del 95% de la flota. |

> **Decisión central de este plan:** el `.exe` no es solo una herramienta, es también **el vehículo de despliegue**. En su primera ejecución se instala a sí mismo como agente (tarea programada) que se auto-actualiza desde un recurso compartido. Una sola pasada manual dolorosa por los 400 equipos, y nunca más.

---

## 0 bis. Estado actual del repositorio

Lo que ya está escrito y lo que falta. **Nada de esto se ha podido ejecutar todavía**: el código se desarrolló en Linux y requiere Windows para compilarse y probarse.

| Pieza | Estado | Archivo |
|---|---|---|
| Motor común (log, registro con reversión, mutex, resultados, reportes) | Escrito | `scripts/modules/Toolkit.Core.psm1` |
| Módulo A — Ubicación (4 capas + perfiles de usuario + verificación por API) | Escrito | `scripts/modules/Toolkit.Location.psm1` |
| Módulo B — Aplicaciones (catálogo, hash, mutex MSI, reintentos, verificación) | Escrito | `scripts/modules/Toolkit.Apps.psm1` |
| Módulo C — Red (latencia, jitter, pérdida, DNS, MTU, TLS, proxy) | Escrito | `scripts/modules/Toolkit.Network.psm1` |
| Orquestador (fuente única de la lógica) | Escrito | `scripts/Invoke-ToolkitRun.ps1` |
| Host C# con scripts embebidos + interfaz + CLI + agente | Escrito | `src/Toolkit.App/` |
| Generador de fichas de aplicación | Escrito | `scripts/tools/New-AppFicha.ps1` |
| Despliegue masivo WinRM/SMB | Escrito | `scripts/deploy/Deploy-Remote.ps1` |
| Compilación + validación + firma | Escrito | `build/build.ps1` |
| **Compilar y probar en Windows** | **Pendiente** | — |
| **Fichas reales de GoTo / NetExtender / MaxAssist** | **Pendiente — bloqueante** | `docs/APP-FICHAS/` |
| **Certificado de firma de código** | **Pendiente — dependencia más lenta** | §10 |
| **Destinos reales de red en el catálogo** | **Pendiente** | `scripts/config/catalog.json` (marcados `CAMBIAR`) |
| `RUNBOOK.md` para soporte nivel 1 | Pendiente | `docs/` |

### Primer paso real

```powershell
# En una maquina Windows con el SDK de .NET instalado:
cd build
.\build.ps1                     # valida los scripts, compila, verifica recursos
..\dist\Toolkit.exe /report     # auditoria: no modifica nada
```

`/report` es el primer comando que debe ejecutarse siempre: dice en qué estado está el equipo sin tocarlo.

---

## 1. Contexto y restricciones

| Factor | Situación | Consecuencia para el diseño |
|---|---|---|
| **Escala** | 400 PCs | Todo debe ser idempotente y desatendido. Nada que requiera intervención humana por equipo. |
| **Gestión actual** | Ninguna. Todo manual hoy. | No hay GPO, ni Intune, ni RMM. Hay que construir el canal de despliegue desde cero. |
| **Estado de la flota** | Mixta: equipos nuevos (reimagen) + equipos ya en producción | Dos caminos de entrada, un solo código base. En producción: sin reinicios forzados, ejecución fuera de horario. |
| **Privilegios** | Heterogéneos: unas áreas con admin local, otras no | El exe debe correr como SYSTEM y resolver explícitamente lo que necesita contexto de usuario. Además debe **blindar** la configuración contra usuarios admin que la reviertan. |
| **Operación crítica** | Agentes en llamada | Ninguna acción puede cortar audio, red o sesión durante horario productivo. |

### Decisiones aún pendientes de confirmar (bloquean la fase 1)

1. **¿Los equipos están en dominio Active Directory, o son workgroup?** Si hay dominio (aunque no se use para políticas), el despliegue se simplifica radicalmente vía GPO. *Esta es la pregunta más importante del proyecto.*
2. **¿Existe una contraseña de administrador local común / LAPS?** Determina si se puede usar PsExec/WinRM en masa.
3. **¿Por qué se necesita la ubicación?** Lo más probable en un call center: llamadas de emergencia dinámicas (E911) del softphone, o control de asistencia de agentes remotos. Define si basta con el servicio activo o hace falta consentimiento por aplicación concreta.
4. **Build exactos de Windows en la flota** (10 22H2 / 11 23H2 / 11 24H2). Las claves de ubicación cambian de comportamiento entre builds.
5. **Lista definitiva y versión de cada aplicación** (ver §7).

---

## 2. Por qué un `.exe` que *contiene* los scripts

La pregunta no es "¿exe o scripts?". Los scripts son el trabajo real: activar la ubicación, instalar las aplicaciones, medir la red. El `.exe` es **el envase**: quien los transporta, los ejecuta en el orden correcto y los protege.

Los `.psm1` viven **dentro** del binario como recursos embebidos y **nunca se escriben en disco**. Esto no es un detalle de implementación; es lo que resuelve los problemas operativos de desplegar a 400 equipos:

| Problema con `.ps1` sueltos en disco | Cómo lo resuelve el exe con los scripts dentro |
|---|---|
| `ExecutionPolicy` bloqueando la ejecución | El host crea su propio *runspace* en proceso, donde la política no aplica al texto de script. |
| Antivirus poniendo en cuarentena scripts sueltos | Un único binario **firmado**, en lista blanca por certificado en vez de por hash de cada archivo. |
| El técnico ejecuta el script equivocado o en mal orden | Un único punto de entrada; el orden y las dependencias están dentro. |
| Alguien abre el `.ps1` y lee la clave de empresa de GoTo | Los secretos no viajan en claro (§11) y los scripts no son legibles de un vistazo. |
| Alguien edita un script en un equipo y la flota diverge | El binario es inmutable y su SHA-256 es verificable. |
| Saber qué versión corrió en cada PC | El exe lleva su propia versión y la reporta en cada ejecución. |

### La regla que hace que esto funcione

> **Una sola fuente de lógica.** La orquestación vive en `Invoke-ToolkitRun.ps1` y la consumen **dos** caminos: el exe (que lo lleva embebido) y `Toolkit.ps1` (envoltorio de línea de comandos para depurar sin recompilar). La interfaz gráfica y el despliegue masivo ejecutan literalmente el mismo código, así que no pueden divergir.

---

## 3. Elección de tecnología

### Comparativa evaluada

| Opción | Tamaño | Dependencias | Firma | Veredicto |
|---|---|---|---|---|
| **PS2EXE** (envolver PowerShell en exe) | ~100 KB | PowerShell + el script se extrae en disco | Débil | ❌ Es un envoltorio, no una solución. Altísima tasa de falsos positivos en AV. El script se puede extraer trivialmente. |
| **C# / .NET Framework 4.8** | 2–4 MB | **Ninguna** (viene en Windows) | ✅ Authenticode | ✅ **ELEGIDA** |
| **C# / .NET 8 self-contained** | 60–90 MB (o ~18 MB con trimming) | Ninguna | ✅ | ⚠️ Técnicamente superior, pero el tamaño complica la distribución sin infraestructura. Alternativa si más adelante se moderniza. |
| **Go** (`go:embed`) | 8–15 MB | Ninguna | ✅ | ⚠️ Excelente binario, pero el acceso a APIs de Windows (registro, servicios, perfiles de usuario) es mucho más verboso vía `syscall`. Más horas de desarrollo. |
| **AutoIt / NSIS** | Pequeño | Ninguna | ✅ | ❌ Marcados por AV con frecuencia. Mantenimiento pobre a largo plazo. |

### Veredicto: **C# + .NET Framework 4.8, WinForms, con los scripts embebidos y ejecutados en proceso**

Razones concretas para *este* proyecto:

- **Cero runtime que desplegar.** Con 400 equipos sin herramienta de gestión, tener que instalar .NET 8 primero convertiría esto en dos proyectos.
- **`System.Management.Automation` ya está en el equipo.** Se referencia contra los *reference assemblies* de PowerShell 5.1, pero en tiempo de ejecución resuelve contra la del GAC. **No se distribuye ninguna DLL de PowerShell.**
- **Firmable con Authenticode** → resuelve SmartScreen y la lista blanca del antivirus de una vez (§10).
- **Manifiesto embebido** con `requireAdministrator` → elevación predecible.

### Por qué los scripts se ejecutan *en proceso* y no lanzando `powershell.exe`

Es la decisión técnica central del diseño:

| | Lanzar `powershell.exe` | **Runspace en proceso (elegido)** |
|---|---|---|
| Scripts en disco | Sí, extraídos a una carpeta temporal | **No, nunca tocan el disco** |
| `ExecutionPolicy` | Hay que sortearla con `-ExecutionPolicy Bypass` | No aplica al texto de script del runspace propio |
| Salida en vivo para la interfaz | Hay que parsear stdout | Se enganchan los flujos (`Information`, `Warning`, `Error`) directamente |
| Control de tiempo límite | Matar un proceso hijo | `PowerShell.Stop()` sobre la invocación |
| Procesos que auditar | Dos | Uno |

La implementación está en `src/Toolkit.App/ScriptHost.cs`: cada `.psm1` se carga con `New-Module` desde su texto embebido y se importa al ámbito global del runspace.

> **La única excepción admitida** a "todo dentro" es lanzar instaladores de terceros (`msiexec.exe`, `setup.exe`) y tres utilidades del sistema (`reg.exe` para cargar colmenas de usuario, `schtasks.exe`, `icacls.exe`). Es inevitable y está acotado.

---

## 4. Arquitectura del ejecutable

```
  Toolkit.exe  (firmado, x64, ~2 MB)
  ├─ CAPA C#  ─ el envase
  │   Program.cs / CommandLine.cs   modos de ejecucion y argumentos
  │   MainForm.cs                   interfaz para el tecnico en sitio
  │   ScriptHost.cs                 runspace en proceso + limite de tiempo
  │   AgentInstaller.cs             auto-instalacion como agente
  │   EmbeddedScripts.cs            lectura de los recursos embebidos
  │
  └─ RECURSOS EMBEBIDOS  ─ el trabajo real
      Scripts/Toolkit.Core.psm1       log, registro con reversion, resultados
      Scripts/Toolkit.Location.psm1   MODULO A  ubicacion
      Scripts/Toolkit.Apps.psm1       MODULO B  aplicaciones
      Scripts/Toolkit.Network.psm1    MODULO C  red
      Scripts/Invoke-ToolkitRun.ps1   ORQUESTADOR (fuente unica de la logica)
      Scripts/catalog.json            catalogo por defecto
```

**Flujo de una ejecución:**

```
  Toolkit.exe /silent /all
        |
        v
  ScriptHost.Open()          abre el runspace, ExecutionPolicy = Bypass
        |
        v
  ScriptHost.LoadModules()   New-Module desde el texto embebido (Core primero)
        |
        v
  Invoke-ToolkitRun.ps1      toma el mutex global -> modulos A/B/C -> reporte
        |
        v
  codigo de salida           0 / 3010 / 1001 / 1002 / 1003 / 5 / 1
```

### Modos de ejecución (un binario, varios comportamientos)

| Invocación | Uso | Comportamiento |
|---|---|---|
| Doble clic | Técnico en sitio | Interfaz con casillas por módulo, log en vivo, botón *Revertir*. |
| `Toolkit.exe /silent /all` | Despliegue masivo, tarea programada | Sin ventana. Aplica todo. Reporta y devuelve código de salida. |
| `Toolkit.exe /silent /modules:location,network` | Despliegue selectivo | Solo los módulos indicados. |
| `Toolkit.exe /report` | Auditoría | **No modifica nada.** Mide cobertura de la flota. |
| `Toolkit.exe /install-agent /share:... /ring:...` | Bootstrap | Se copia a `C:\ProgramData\Toolkit\bin`, aplica ACL y crea la tarea programada. |
| `Toolkit.exe /rollback` | Reversión | Deshace los cambios de registro registrados. |
| `Toolkit.exe /uninstall-agent` | Retirada | Obligatorio tenerlo desde el día 1. |

### Patrón de diseño: `Test` / `Set` (idempotencia)

Cada acción evalúa antes de actuar. `Set-RegValue` devuelve si **realmente** cambió algo, de modo que:

- ejecutar dos veces seguidas no produce efectos la segunda,
- el modo `/report` sale gratis (solo se evalúa, no se aplica),
- la medición de cobertura de los 400 equipos es honesta.

### Garantías de estabilidad

| Garantía | Implementación |
|---|---|
| Nunca dos ejecuciones simultáneas | Mutex global `ToolkitCallCenter` (`Enter-ToolkitInstance`). Sin él, la tarea del agente y el técnico pueden corromper `rollback.json`. |
| Nunca un proceso colgado | Tiempo límite global de 30 min en `ScriptHost.Run` + `ExecutionTimeLimit` de la tarea programada. |
| Nunca un `rollback.json` truncado | Escritura atómica (temporal + reemplazo). |
| Nunca dos instaladores MSI a la vez | Espera del mutex `Global\_MSIExecute` y reintento del código 1618. |
| Siempre reversible | Cada valor de registro se respalda antes de escribirse. |

---

## 5. Estructura del proyecto

```
Toolkit/
├── src/Toolkit.App/                  # El envase (C#)
│   ├── Toolkit.App.csproj            #   <EmbeddedResource> = los scripts entran aqui
│   ├── app.manifest                  #   requireAdministrator + DPI
│   ├── Program.cs                    #   punto de entrada, modos
│   ├── CommandLine.cs                #   parseo de /silent /all /modules:...
│   ├── ScriptHost.cs                 #   runspace en proceso + limite de tiempo
│   ├── EmbeddedScripts.cs            #   lectura de recursos + cascada del catalogo
│   ├── AgentInstaller.cs             #   /install-agent y /uninstall-agent
│   └── MainForm.cs                   #   interfaz del tecnico
│
├── scripts/                          # El trabajo real (PowerShell, embebido en el exe)
│   ├── Invoke-ToolkitRun.ps1         #   ORQUESTADOR - fuente unica de la logica
│   ├── Toolkit.ps1                   #   envoltorio CLI para depurar sin recompilar
│   ├── modules/
│   │   ├── Toolkit.Core.psm1         #   log, registro+reversion, mutex, resultados
│   │   ├── Toolkit.Location.psm1     #   MODULO A
│   │   ├── Toolkit.Apps.psm1         #   MODULO B
│   │   └── Toolkit.Network.psm1      #   MODULO C
│   ├── config/catalog.json           #   catalogo de apps y destinos de red
│   ├── tools/
│   │   └── New-AppFicha.ps1          #   genera la ficha de una app desde su instalador
│   └── deploy/
│       ├── Install-Agent.ps1         #   equivalente al /install-agent del exe
│       ├── Invoke-AgentCheck.ps1     #   latido del agente (camino scripts)
│       ├── Deploy-Remote.ps1         #   despliegue masivo WinRM / SMB
│       └── manifest.example.json     #   manifiesto del share
│
├── build/build.ps1                   # valida sintaxis -> compila -> verifica recursos -> firma
├── docs/
│   ├── PLAN.md                       # este documento
│   ├── RUNBOOK.md                    # guia operativa de soporte
│   └── APP-FICHAS/                   # una ficha por aplicacion
└── dist/Toolkit.exe                  # artefacto firmado
```

> **`build.ps1` valida la sintaxis de cada `.psm1` antes de compilar.** Un error de sintaxis en un script no rompe la compilación de C#: se embebería igual y explotaría en el equipo del cliente. Ese chequeo previo es obligatorio.

---

## 6. MÓDULO A — Ubicación (servicio + políticas)

Éste es el módulo con más trampas. Activar la ubicación en Windows **no es un solo interruptor**: son cuatro capas independientes, y si falta una, la aplicación que consume la ubicación falla sin decir por qué.

### Las cuatro capas

#### Capa 1 — El servicio

| Elemento | Valor |
|---|---|
| Servicio | `lfsvc` (*Geolocation Service*) |
| Por defecto | `Manual (Trigger Start)` |
| Acción | `StartType = Automatic`, luego arrancar |
| API .NET | `ServiceController` + `ChangeServiceConfig` vía P/Invoke (el `StartType` no se puede cambiar solo con `ServiceController` en .NET Framework) |

Dependencia: `lfsvc` requiere el servicio `DeviceAssociationService` — verificarlo también.

#### Capa 2 — El interruptor maestro del sistema

```
HKLM\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration
    Status (REG_DWORD) = 1
```

Es lo que escribe *Configuración → Privacidad → Ubicación → Servicios de ubicación*.

#### Capa 3 — El almacén de consentimiento (`ConsentStore`)

```
# Máquina — aplicaciones empaquetadas (UWP/Store)
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location
    Value (REG_SZ) = "Allow"

# Máquina — aplicaciones de escritorio clásicas (Win32)  ← LA QUE SE OLVIDA
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location\NonPackaged
    Value (REG_SZ) = "Allow"

# Usuario — se repite la misma estructura bajo HKCU
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location
    Value (REG_SZ) = "Allow"
```

> ⚠️ **El softphone y cualquier aplicación de escritorio necesitan la rama `NonPackaged`.** Es la causa número uno de "activé la ubicación y la app sigue sin verla".

#### Capa 4 — Políticas (lo que impide que el usuario lo revierta)

```
HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors
    DisableLocation               (REG_DWORD) = 0
    DisableLocationScripting      (REG_DWORD) = 0
    DisableWindowsLocationProvider(REG_DWORD) = 0

HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy
    LetAppsAccessLocation         (REG_DWORD) = 1     # 1 = Forzar permitir
```

`LetAppsAccessLocation = 1` fuerza el permiso **y bloquea el conmutador en la interfaz** (aparecerá "Administrado por tu organización"). Eso es exactamente lo que se busca en las áreas donde los agentes son administradores locales.

Para aplicaciones de escritorio concretas puede hacer falta:
`LetAppsAccessLocation_ForceAllowTheseApps` (REG_MULTI_SZ, lista de identidades de app).

### El problema difícil: `HKCU` cuando el exe corre como SYSTEM

Cuando el toolkit corre desatendido como SYSTEM, `HKCU` apunta al perfil de SYSTEM, no al del agente. Estrategia en cuatro frentes (se aplican todos, por redundancia):

| # | Técnica | Cubre |
|---|---|---|
| 1 | Política `LetAppsAccessLocation = 1` | Anula el consentimiento por usuario para apps empaquetadas. Es la defensa principal. |
| 2 | Enumerar `HKEY_USERS\<SID>` y escribir en cada perfil cargado | Los usuarios con sesión activa en ese momento. |
| 3 | `reg load` de `NTUSER.DAT` de perfiles no cargados, escribir, `reg unload` | Los usuarios que han iniciado sesión alguna vez pero no están activos. **Cuidado: nunca descargar una colmena que ya estaba cargada.** |
| 4 | Escribir en el perfil `Default` (`C:\Users\Default\NTUSER.DAT`) | Usuarios futuros y equipos reimaginados. |

Complemento opcional: tarea programada al inicio de sesión que ejecuta `Toolkit.exe /silent /modules=location-user` en el contexto del usuario. Barata y cierra cualquier hueco.

### Verificación (no basta con escribir el registro)

El módulo debe **probar que funciona**, no solo que las claves están puestas:

1. `lfsvc` en estado `Running`.
2. Consultar la API de geolocalización (`Windows.Devices.Geolocation` vía WinRT, accesible desde .NET Framework 4.8) y comprobar que `LocationStatus` no devuelve `Disabled` ni `NotAvailable`.
3. Registrar la precisión obtenida. Sin GPS, Windows usa WiFi/IP → precisión de decenas o cientos de metros. **Si el caso de uso es E911, esto hay que validarlo con el proveedor de telefonía antes de desplegar a 400 equipos.**

### Matriz de reversión

Cada clave escrita se guarda con su valor previo en `C:\ProgramData\Toolkit\rollback.json` antes de modificarla. `Rollback()` la restaura. Sin esto, no hay forma de deshacer un despliegue fallido en 400 equipos.

---

## 7. MÓDULO B — Instalación de aplicaciones

### Aplicaciones objetivo (a confirmar)

| Aplicación | Qué es (asunción) | Estado |
|---|---|---|
| **GoTo** (GoTo Resolve / GoToAssist) | Soporte remoto desatendido | ⚠️ Confirmar producto exacto — hay 5 productos distintos bajo la marca GoTo |
| **NetExtender** (SonicWall) | Cliente VPN SSL | ⚠️ Confirmar versión: 10.2.x usa instalador EXE, 10.3+ usa MSI. Los conmutadores cambian. |
| **MaxAssist** | Asistencia remota | ⚠️ Producto no identificado con certeza — requiere ficha completa |
| *(pendiente)* | Softphone / CRM / navegador | Completar lista |

> **Nada de esto se codifica a ciegas.** Cada aplicación necesita su **ficha** validada en laboratorio antes de entrar al catálogo.

### Las fichas no se escriben a mano: se generan

Rellenar el catálogo a ojo es la causa número uno de instalaciones que fallan en masa. `scripts/tools/New-AppFicha.ps1` apunta a un instalador real, lo inspecciona y emite el bloque JSON listo para pegar más la ficha en markdown:

```powershell
.\New-AppFicha.ps1 -Path 'D:\instaladores\NetExtender.msi' -Id netextender -OutputDir ..\..\docs\APP-FICHAS
```

Qué extrae automáticamente:

| Tipo | Qué obtiene |
|---|---|
| **MSI** | `ProductCode` (GUID exacto), `ProductName`, `ProductVersion`, fabricante y **la lista de propiedades públicas que admite** — ahí es donde aparecen `SERVER`, `COMPANYKEY`, `LICENSEKEY` y demás |
| **EXE** | Empaquetador (Inno / NSIS / InstallShield / WiX burn / 7z SFX) y, con él, el conmutador silencioso correcto |
| Ambos | SHA-256 (obligatorio en el catálogo) y estado de la firma Authenticode del instalador |

Esto es lo que desbloquea GoTo, NetExtender y MaxAssist: en lugar de adivinar los conmutadores, se leen del propio instalador.

> **Sigue siendo obligatorio validar en máquina virtual limpia antes de `enabled: true`.** La ficha generada incluye la lista de comprobación. El generador reduce la adivinanza; no la elimina.

### Métodos de detección disponibles

Saber si una aplicación ya está instalada es tan importante como instalarla: sin detección fiable no hay idempotencia, y el toolkit reinstalaría en cada ejecución.

| Método | Cómo funciona | Cuándo usarlo |
|---|---|---|
| **`productCode`** | Busca el GUID del MSI en la rama de desinstalación | **Preferido para todo MSI.** Exacto, inmune a cambios de nombre comercial y a traducciones |
| `uninstall` | Coincidencia parcial del `DisplayName` | Solo cuando no hay `ProductCode` (instaladores EXE) |
| `file` | Existencia de un archivo + versión | Aplicaciones portables o que no se registran |
| `service` | Existencia de un servicio | Agentes que instalan servicio (GoTo, MaxAssist) |

Con `minVersion`, una versión instalada por debajo del mínimo cuenta como *no instalada*, de modo que el mismo mecanismo sirve para actualizar.

### Motor de instalación — secuencia por aplicación

```
1. Detectar       -> ya instalado y en version >= objetivo?  -> SALTAR
2. Obtener        -> share (primero) -> URL oficial (respaldo)
3. Verificar      -> SHA-256 contra la ficha. Si no coincide: ABORTAR y alertar
4. Esperar turno  -> mutex Global\_MSIExecute: Windows Installer es de instancia unica
5. Instalar       -> silencioso, con tiempo limite (15 min por defecto)
6. Interpretar    -> codigo contra successCodes, traducido a texto legible
                     1618 (otra instalacion en curso) -> UN reintento a los 30 s
                     3010 / 1641                      -> marca reinicio pendiente
7. Verificar      -> repetir la deteccion. Exito del instalador != aplicacion instalada
8. Registrar      -> app, version, resultado, duracion
```

Tres detalles que separan un motor que funciona en laboratorio de uno que funciona en 400 equipos:

- **Windows Installer solo admite una instalación a la vez en todo el equipo.** Si Windows Update está instalando algo, `msiexec` devuelve 1618 y la instalación se pierde. El motor espera el mutex y reintenta.
- **Un código de salida 0 no garantiza que la aplicación esté instalada.** Siempre se vuelve a detectar después. Si el instalador dice que sí y la detección dice que no, es fallo real y casi siempre significa que la ficha de detección está mal.
- **`silentArgs` vacío es un fallo, no un caso por defecto.** Un instalador sin conmutador silencioso abriría interfaz en un equipo desatendido y se quedaría colgado hasta el tiempo límite. El motor lo rechaza antes de lanzarlo.

### Conmutadores silenciosos por tipo de instalador (referencia)

| Tipo | Comando |
|---|---|
| MSI | `msiexec /i "pkg.msi" /qn /norestart /l*v "log.txt"` |
| InnoSetup | `setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="log.txt"` |
| NSIS | `setup.exe /S` |
| InstallShield | `setup.exe /s /v"/qn /norestart"` |
| Bootstrapper MSI | `setup.exe /quiet /norestart` |

### Sobre `winget`

**No se usa como mecanismo principal.** Motivos: bajo SYSTEM el ejecutable de `winget` no está en la ruta (vive en `WindowsApps`, por usuario), depende de *App Installer* actualizado, y las aplicaciones corporativas del catálogo (NetExtender, GoTo con clave, MaxAssist) sencillamente no están en el repositorio. Descarga directa + MSI da control total y reproducible.

### Repositorio de instaladores

Un recurso compartido SMB de solo lectura, p. ej. `\\SRV-FILE\Toolkit$\packages\`, con estructura `<app>\<version>\`. El exe intenta primero el share (rápido, sin saturar la salida a Internet con 400 descargas) y cae a la URL oficial si no hay share alcanzable.

> Con 400 equipos, descargar un instalador de 80 MB desde Internet en todos a la vez satura el enlace del call center. **El share no es opcional.**

---

## 8. MÓDULO C — Diagnóstico de red

En un call center la red no se mide con "¿hay Internet?". Se mide con las métricas que matan una llamada VoIP.

### Qué mide

| Categoría | Prueba | Umbral de alarma (VoIP) |
|---|---|---|
| **Conectividad** | Puerta de enlace, DNS, salida a Internet, portal cautivo | — |
| **Latencia** | RTT al conmutador/SBC y al CRM | > 150 ms |
| **Jitter** | Desviación entre 100 pings consecutivos | > 30 ms |
| **Pérdida de paquetes** | % sobre 100 paquetes | > 1% |
| **DNS** | Tiempo de resolución, servidores configurados, resolución de dominios corporativos | > 100 ms |
| **MTU** | Descubrimiento con paquetes DF | < 1500 (túnel/VPN mal configurada) |
| **Interfaz** | Cable vs WiFi, velocidad de enlace, señal RSSI si es WiFi | WiFi = bandera amarilla en puesto de agente |
| **Proxy** | Configuración WinHTTP y WinINET | Descuadre entre ambas = fallos intermitentes |
| **TLS** | Handshake a los destinos corporativos | Inspección SSL rompiendo certificados |
| **Puertos** | SIP (5060/5061), RTP (rango), VPN | Cerrados por firewall local o de red |

### Implementación

- `System.Net.NetworkInformation.Ping` para RTT/jitter/pérdida (nativo, sin lanzar `ping.exe`).
- `Dns.GetHostEntry` con cronómetro para DNS.
- `NetworkInterface` para velocidad y tipo de enlace.
- WMI (`MSFT_NetAdapter`, `MSNdis_80211_*`) para señal WiFi.
- `TcpClient.ConnectAsync` con tiempo límite para puertos.

### Salida

Dos formatos a la vez:
- **Humano:** tabla en consola/GUI con semáforo verde/ámbar/rojo.
- **Máquina:** `network-<equipo>-<fecha>.json` depositado en el share. Con 400 equipos reportando, esto se convierte en el mapa de calor de la red del call center — probablemente el subproducto más valioso de todo el proyecto.

---

## 9. Motor transversal

### Registro de actividad (logging)

| Destino | Formato | Retención |
|---|---|---|
| `C:\ProgramData\Toolkit\logs\toolkit-<fecha>.log` | Texto con marca de tiempo | 30 días, rotación |
| `\\SRV-FILE\Toolkit$\reports\<equipo>.json` | JSON estructurado | Permanente |
| Registro de eventos de Windows, origen `Toolkit` | Eventos con ID | Según política del equipo |

Campos obligatorios en cada reporte: nombre del equipo, número de serie, usuario, versión de SO y build, versión del toolkit, marca de tiempo, y por cada tarea: `{nombre, estado_previo, accion, resultado, duracion_ms, error}`.

### Códigos de salida

| Código | Significado |
|---|---|
| `0` | Todo correcto |
| `3010` | Correcto, requiere reinicio |
| `1` | Fallo general |
| `5` | Permisos insuficientes (no elevado) |
| `1001` | Módulo de ubicación falló |
| `1002` | Una o más aplicaciones fallaron |
| `1003` | Diagnóstico de red con estado crítico |

Son consumibles por cualquier RMM, GPO o tarea programada — imprescindible para medir cobertura sin entrar equipo por equipo.

> **`3010` se genera de verdad, no solo se documenta.** Cualquier instalador que devuelva 3010 o 1641 marca el equipo como *reinicio pendiente*, y la ejecución completa termina con 3010 aunque todo lo demás haya ido bien. Sin esto, el equipo queda a medias y nadie se entera: es el fallo silencioso clásico del despliegue masivo.

### Seguridad de la ejecución

- Manifiesto con `requireAdministrator`.
- Si no está elevado y hay sesión interactiva: reelevar vía UAC. Si es desatendido: salir con código 5 y registrarlo.
- Tiempo límite global de 30 min con auto-terminación (`ScriptHost.Run`) — nunca un proceso colgado en 400 equipos.
- Mutex global `ToolkitCallCenter`: nunca dos instancias aplicando cambios a la vez. El modo `/report` queda exento porque no escribe nada.
- **Ventana de mantenimiento:** en modo desatendido se comprueba el horario antes de instalar aplicaciones. Por defecto 23:00–07:00; **hay que ajustarlo a los turnos reales del call center antes de desplegar**, o en una operación 24/7 no se instalará nunca nada. El técnico en sitio la ignora (está delante del equipo).
- Reversión: cada valor de registro se respalda antes de escribirse, con escritura atómica del archivo de reversión.

---

## 10. Firma de código y antivirus — crítico a esta escala

Con 400 equipos, un binario sin firmar **no es viable**: SmartScreen lo bloquea, el antivirus lo pone en cuarentena, y acabarás creando 400 excepciones a mano.

| Acción | Detalle | Coste aprox. |
|---|---|---|
| **Certificado de firma de código OV o EV** | EV da reputación inmediata en SmartScreen; OV necesita acumular reputación. Desde junio 2023 ambos requieren almacenamiento en HSM/token. | 250–600 USD/año |
| **Firmar en cada compilación** | `signtool sign /fd SHA256 /tr <servidor-de-sellado> /td SHA256` | — |
| **Lista blanca en el antivirus corporativo** | Por **editor/certificado**, no por hash — así no hay que repetirlo en cada versión | — |
| **Envío preventivo a Microsoft Defender** | *Submit a file for analysis* antes del despliegue masivo | Gratis |

> Alternativa si no hay presupuesto: certificado autofirmado + desplegar el certificado raíz al almacén *Editores de confianza* de la flota. **Pero esto hay que hacerlo antes del primer despliegue del exe**, lo que crea un problema del huevo y la gallina sin infraestructura de gestión. Recomendación: comprar el certificado. Es el gasto con mejor relación coste/dolor evitado de todo el proyecto.

---

## 11. Gestión de secretos

Las claves de empresa de GoTo, credenciales de VPN o tokens de agente **no pueden ir en texto plano dentro del binario** (un `strings Toolkit.exe` las expone).

| Nivel | Enfoque |
|---|---|
| **Mínimo aceptable** | Recurso embebido cifrado con AES-256; la clave derivada por PBKDF2 de un valor compilado + identificador de máquina. Ofusca frente a un vistazo casual. |
| **Recomendado** | Los secretos **no viajan en el exe**. Se leen del share con ACL restringida (`\\SRV-FILE\Toolkit$\config\`), legible solo por *Equipos del dominio* o por una cuenta de servicio. El exe sin acceso al share simplemente omite las apps que requieren clave. |
| **Nunca** | Codificar en el fuente, en Base64, o en un `.config` junto al exe. |

Se asume que cualquier secreto en un binario distribuido a 400 equipos **es recuperable** por alguien con motivación. Diseñar en consecuencia: usar claves con el mínimo privilegio necesario y rotables.

---

## 12. Despliegue — la parte difícil

Sin GPO, sin Intune y sin RMM, hay que resolver el problema de arranque: *¿cómo llega el exe a 400 equipos la primera vez?*

### Estrategia en dos tiempos

#### Tiempo 1 — Agente puente (lo que construimos nosotros)

En su primera ejecución, `Toolkit.exe /install-agent`:

1. Se copia a `C:\ProgramData\Toolkit\Toolkit.exe` (carpeta con ACL: solo SYSTEM/Administradores escriben).
2. Crea una tarea programada `Toolkit Agent`:
   - Ejecuta como `SYSTEM`, con privilegios máximos.
   - Disparadores: al arrancar (+5 min de retraso) y cada 4 horas.
   - Acción: `Toolkit.exe /agent-check`.
3. En cada ejecución, `/agent-check`:
   - Lee `\\SRV-FILE\Toolkit$\manifest.json` → versión objetivo y trabajos pendientes.
   - Si hay versión nueva: se auto-actualiza (descarga, **verifica firma y hash**, se reemplaza).
   - Ejecuta los trabajos que le correspondan según su anillo de despliegue.
   - Sube su reporte de estado.

**Esto es un mini-RMM de unas 400 líneas.** A partir de la primera instalación, cualquier cambio futuro (nueva app, nueva política, nuevo diagnóstico) se despliega editando un JSON en un recurso compartido. Ése es el verdadero retorno del proyecto.

#### Cómo llega el exe la PRIMERA vez (por orden de preferencia)

| Vía | Condición | Cobertura esperada |
|---|---|---|
| **GPO** (script de inicio o tarea programada) | Requiere dominio AD | 100% — *verificar si existe dominio; cambiaría todo el plan* |
| **PsExec / PowerShell Remoting en masa** | Admin local común o LAPS + SMB/WinRM alcanzables | 60–80% |
| **Carpeta de Inicio / RunOnce** vía acceso administrativo remoto (`\\PC\C$`) | Admin local + SMB | 60–80% |
| **Pasada manual del equipo de soporte** | Siempre funciona | El resto |
| **Imagen base** (equipos nuevos/reimagen) | Incluir el exe en la imagen dorada y ejecutar `/install-agent` en el primer arranque | 100% de los equipos nuevos |

Realista: entre 2 y 4 técnicos pueden cubrir manualmente el remanente de ~100 equipos en 2–3 días (≈3 min por PC).

#### Tiempo 2 — Infraestructura real (recomendación estratégica)

Construir y mantener un mini-RMM para 400 equipos tiene un coste continuo. **Se recomienda que este proyecto sea el detonante para adoptar una herramienta de gestión real**, y que el toolkit pase a ser solo la carga útil:

| Opción | Coste | Comentario |
|---|---|---|
| **Unir al dominio + GPO** | Coste del servidor | Si ya hay AD, es lo más barato y potente. |
| **Microsoft Intune** | ~2–8 USD/equipo/mes | El mejor destino a largo plazo. El exe se empaqueta como `.intunewin` con script de detección. |
| **Action1** | Gratis hasta 200 equipos | Con 400 hacen falta dos instancias o plan de pago. Muy bueno para esta escala. |
| **PDQ Deploy + Inventory** | ~1.500 USD/año | Pensado exactamente para este escenario. Despliega el exe por consola. |

El toolkit está diseñado para funcionar igual bajo cualquiera de ellas: un exe, conmutadores de línea de comandos, códigos de salida estándar. **Ninguna de estas migraciones exigiría reescribirlo.**

### Anillos de despliegue

| Anillo | Equipos | Quién | Criterio para avanzar |
|---|---|---|---|
| **0 — Laboratorio** | 3–5 | IT | Todos los módulos verifican correctamente en cada build de Windows presente en la flota |
| **1 — Piloto** | 15–20 | Un área, voluntarios | 72 h sin incidencias, 0 tickets |
| **2 — Ampliación** | ~100 | Un turno completo | 1 semana, tasa de éxito > 95% |
| **3 — General** | Resto | Toda la flota | — |

Regla: entre anillos siempre hay una reunión de revisión. Nunca se salta un anillo, por urgente que parezca.

---

## 13. Cronograma

| Semana | Trabajo | Entregable |
|---|---|---|
| **1** | Descubrimiento: confirmar dominio/workgroup, inventario de builds, fichas de aplicación validadas en laboratorio, definir por qué se necesita la ubicación | Inventario + 3 fichas completas |
| **2** | Esqueleto: solución C#, motor `ITask`, logger, CLI/GUI, manifiesto, compilación a archivo único | `Toolkit.exe` que no hace nada pero corre |
| **3** | Módulo Ubicación completo, incluida la estrategia HKCU y la verificación por API | Módulo A + pruebas |
| **4** | Módulo Apps + catálogo + repositorio en el share | Módulo B |
| **5** | Módulo Red + reportes JSON + panel de resultados | Módulo C |
| **6** | Agente puente, auto-actualización, certificado de firma, lista blanca en AV | Binario firmado + canal de despliegue |
| **7** | Anillos 0 y 1 | Piloto en producción |
| **8+** | Anillos 2 y 3, `RUNBOOK.md`, formación al equipo de soporte | Flota cubierta |

Sin adelantar la compra del certificado a la semana 1–2, la semana 6 se convierte en cuello de botella. **Es la dependencia externa más larga del proyecto.**

---

## 14. Riesgos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| El antivirus pone el exe en cuarentena en masa | Bloqueante | Firma EV + lista blanca por editor + envío previo a Defender |
| Las claves de ubicación se comportan distinto entre builds de Windows | Alto | Matriz de pruebas por build en el anillo 0. Nunca asumir paridad 10/11. |
| La precisión de la ubicación no sirve para el caso de uso (E911) | Alto — invalida el módulo | **Validar con el proveedor de telefonía en la semana 1**, antes de escribir código |
| Conmutadores silenciosos de instalador incorrectos → instalaciones a medias | Medio | Ficha validada en laboratorio + verificación post-instalación obligatoria |
| 400 descargas simultáneas saturan el enlace | Medio | Repositorio en share + ejecución escalonada por anillo y horario |
| Agentes con admin local revierten la configuración | Medio | Políticas que bloquean la interfaz + reaplicación cada 4 h por el agente |
| El agente se auto-actualiza a una versión defectuosa en 400 equipos | **Crítico** | Despliegue por anillos también para el propio agente + verificación de firma + capacidad de reversión + versión mínima de rescate en el manifiesto |
| Pérdida del recurso compartido | Medio | El exe funciona de forma autónoma con el catálogo embebido; el share es optimización, no dependencia dura |

### Cumplimiento y aspecto laboral

Activar la geolocalización en los equipos de 400 empleados tiene implicaciones legales (RGPD/LOPD o la normativa local equivalente) independientemente de la motivación técnica.

- Documentar la **finalidad concreta** (p. ej. llamadas de emergencia del softphone) y ceñirse a ella.
- Informar a la plantilla y, si aplica, al comité de empresa **antes** del despliegue.
- Consultarlo con Legal/RRHH en la semana 1. Es más barato que pararlo en la semana 7.
- Si la finalidad es E911, dejarlo por escrito: acota el alcance y evita que se interprete como vigilancia.

---

## 15. Criterios de aceptación

El proyecto se considera terminado cuando:

- [ ] `Toolkit.exe` es un archivo único, firmado, y corre en Windows 10 22H2 y Windows 11 (todos los builds de la flota) sin instalar nada previo.
- [ ] `Toolkit.exe /report` devuelve el estado real sin modificar el sistema.
- [ ] Ejecutarlo dos veces seguidas produce el mismo resultado y ningún cambio la segunda vez (idempotencia demostrada).
- [ ] El módulo de ubicación verifica mediante **API**, no solo por registro, y funciona con el usuario estándar tras cerrar y abrir sesión.
- [ ] `Rollback()` restaura el estado previo en un equipo de prueba, verificado.
- [ ] ≥ 95% de los 400 equipos reportan estado correcto en el panel.
- [ ] El equipo de soporte despliega una aplicación nueva editando únicamente `manifest.json`, sin recompilar.
- [ ] `RUNBOOK.md` permite a un técnico de nivel 1 resolver los fallos habituales sin escalar.

---

## 16. Anexo — Primeros pasos concretos

1. **Responder las 5 preguntas abiertas de §1** (especialmente: ¿hay dominio AD?).
2. **Iniciar la compra del certificado de firma de código** — es la dependencia más lenta.
3. **Montar el laboratorio**: una máquina virtual por cada build de Windows presente en la flota.
4. **Validar el caso de uso de la ubicación** con el proveedor de telefonía.
5. **Rellenar las fichas** de GoTo, NetExtender y MaxAssist con instaladores reales y conmutadores probados a mano.

Sólo después de esos cinco puntos merece la pena escribir la primera línea de C#.
