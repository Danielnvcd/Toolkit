# Pruebas en máquina virtual — Anillo 0

Procedimiento de validación en laboratorio. **Ningún equipo de producción recibe el toolkit hasta que esta guía se completa entera y sin fallos abiertos** en cada build de Windows presente en la flota.

Tiempo estimado: medio día por build de Windows.

---

## 1. Preparar el laboratorio

### Máquinas virtuales

Una VM por cada build de Windows que exista en los 400 equipos. **No asumas paridad entre Windows 10 y 11**: las claves de ubicación se comportan distinto y esa suposición es precisamente lo que revienta en el anillo 2.

| VM | Sistema | Para qué |
|---|---|---|
| `LAB-W10` | Windows 10 22H2 x64 | Build mayoritario de la flota |
| `LAB-W11` | Windows 11 (build de producción) | Equipos nuevos / reimagen |

- **Imagen:** Windows Enterprise, evaluación de 90 días, desde el Microsoft Evaluation Center (ISO gratuita, sin licencia).
- **Hipervisor:** VirtualBox o KVM/virt-manager sobre el equipo Linux de IT.
- **Specs:** 2 vCPU, 4 GB RAM, 60 GB disco, red en NAT o puente.
- **Sin unir al dominio** en la primera pasada: replica el escenario real de workgroup.

### Cuentas de usuario

Los privilegios varían por área, así que hay que probar los dos casos. Crea en cada VM:

| Cuenta | Tipo | Simula |
|---|---|---|
| `labadmin` | Administrador local | Supervisores e IT |
| `labagente` | Usuario estándar | El agente de call center típico |

Inicia sesión **al menos una vez** con `labagente` antes de probar. Si su perfil nunca se ha creado, no existe `NTUSER.DAT` y no se estará probando el camino de perfiles de usuario, que es la parte más frágil del módulo de ubicación.

### Snapshots — no es opcional

```
snapshot "00-limpia"        Windows recién instalado, cuentas creadas, sesión iniciada con ambas
snapshot "01-prerrequisitos" Tras instalar .NET SDK + Developer Pack 4.8
```

Cada caso de prueba **arranca desde un snapshot restaurado**. Sin esto, la prueba de idempotencia miente: verás "YA-OK" porque lo dejó la prueba anterior, no porque el código funcione.

---

## 2. Llevar los archivos a la VM

Cualquiera de estas sirve:

- Carpeta compartida de VirtualBox (requiere Guest Additions)
- ZIP por el navegador de la VM
- `git clone` si el repositorio está accesible

Destino sugerido: `C:\Toolkit\`

---

## 3. FASE A — Probar los scripts (sin compilar nada)

PowerShell 5.1 viene de fábrica en Windows. Esta fase no necesita instalar **nada** y es la que más rápido detecta problemas de lógica.

> Restaurar snapshot `00-limpia` antes de empezar. Sesión con `labadmin`.

### A1 · Auditoría inicial

```powershell
cd C:\Toolkit\scripts
powershell -NoProfile -ExecutionPolicy Bypass -File .\Toolkit.ps1 -Report
```

**Esperado:** no modifica nada. Muestra el estado de las cuatro capas de ubicación, el inventario de aplicaciones y el diagnóstico de red. En una VM limpia, la ubicación aparecerá como no conforme — eso es correcto.

- [ ] Se ejecuta sin errores no controlados
- [ ] Lista los perfiles de usuario, incluido `labagente`
- [ ] Escribe log en `C:\ProgramData\Toolkit\logs\`
- [ ] Escribe reporte en `C:\ProgramData\Toolkit\reports\`

### A2 · Aplicar ubicación

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Toolkit.ps1 -Modules location
```

- [ ] Servicio `lfsvc` queda en `Automatic` y `Running`
- [ ] Las cuatro capas se aplican (mirar las líneas `+` del log)
- [ ] Se escribe el consentimiento en el perfil de `labagente`
- [ ] Se escribe el perfil `Default`
- [ ] Se crea `C:\ProgramData\Toolkit\rollback.json`

**Verificación manual** (no te fíes solo del log):

```powershell
Get-Service lfsvc | Select-Object Status, StartType
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration' -Name Status
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location\NonPackaged' -Name Value
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -Name LetAppsAccessLocation
```

Y en la interfaz: *Configuración → Privacidad y seguridad → Ubicación*. Con `lockDown` activo debe aparecer **"Algunas configuraciones las administra tu organización"** y el conmutador bloqueado. Si se puede desactivar a mano, la política no está surtiendo efecto.

### A3 · Idempotencia — el caso que más se salta

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Toolkit.ps1 -Modules location
```

- [ ] **Segunda ejecución: resultado `YA-OK`, cero cambios aplicados**
- [ ] El resumen no reporta ningún `CAMBIADO`

Si la segunda pasada vuelve a aplicar cambios, hay un fallo de comparación en `Set-RegValue` y el agente estaría reescribiendo el registro cada 4 horas en 400 equipos.

### A4 · Verificación con usuario estándar

Cerrar sesión, entrar como `labagente`.

- [ ] La ubicación aparece activada
- [ ] El usuario **no** puede desactivarla (con `lockDown`)
- [ ] Una app de escritorio que use ubicación la obtiene (ver §6 sobre la limitación de la VM)

### A5 · Reversión

Volver a sesión `labadmin`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Toolkit.ps1 -Rollback
```

- [ ] Los valores vuelven a su estado previo
- [ ] `rollback.json` se renombra a `rollback-aplicado-<fecha>.json`
- [ ] Un `-Report` posterior muestra el estado original

**Si la reversión no funciona, el proyecto se para aquí.** Sin reversión verificada no hay forma de deshacer un despliegue fallido en 400 equipos.

### A6 · Instancia única

En dos ventanas de PowerShell a la vez:

```powershell
# ventana 1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Toolkit.ps1 -Modules location,network
# ventana 2, inmediatamente después
powershell -NoProfile -ExecutionPolicy Bypass -File .\Toolkit.ps1 -Modules location
```

- [ ] La segunda espera o aborta con "Ya hay otra instancia del toolkit en ejecución"
- [ ] `rollback.json` sigue siendo JSON válido al terminar

---

## 4. FASE B — Compilar y probar el exe

### Prerrequisitos (solo una vez, luego snapshot `01-prerrequisitos`)

1. **.NET SDK 8** o superior
2. **.NET Framework 4.8 Developer Pack** ← el que se olvida

Sin el Developer Pack, `dotnet build` falla con *"the reference assemblies for .NETFramework,Version=v4.8 were not found"*. El SDK **no** trae los *reference assemblies* de .NET Framework.

### B1 · Compilar

```powershell
cd C:\Toolkit\build
.\build.ps1
```

- [ ] Valida la sintaxis de los 10 scripts sin errores
- [ ] `catalog.json` valida como JSON
- [ ] Compila sin errores
- [ ] **Verifica los 6 recursos embebidos** (si falta alguno, aborta)
- [ ] Avisa de que el binario va **sin firmar**
- [ ] Genera `dist\Toolkit.exe` y muestra su SHA-256

Anota el SHA-256: es como los equipos verifican que la versión que reciben del share no ha sido manipulada.

### B2 · Modo consola

> Restaurar snapshot `01-prerrequisitos`.

```powershell
cd C:\Toolkit\dist
.\Toolkit.exe /report
```

- [ ] Se eleva vía UAC (por el manifiesto `requireAdministrator`)
- [ ] La salida aparece **en la consola actual**, no en una ventana aparte
- [ ] Muestra `catalogo: embebido en el exe`
- [ ] El resultado coincide con el de la Fase A

```powershell
.\Toolkit.exe /silent /all
echo $LASTEXITCODE
```

- [ ] No abre ninguna ventana
- [ ] Devuelve un código de salida coherente (`0`, o `3010` si algo pidió reinicio)

### B3 · Interfaz gráfica

Doble clic en `Toolkit.exe`.

- [ ] Se eleva vía UAC
- [ ] Las casillas de módulo funcionan
- [ ] *Auditar* no modifica nada
- [ ] *Aplicar cambios* pide confirmación antes de tocar el equipo
- [ ] El log se pinta **en vivo y con colores** (no todo al final)
- [ ] La ventana no se congela durante la ejecución
- [ ] *Revertir* pide confirmación y funciona

### B4 · Catálogo externo

Copia `scripts\config\catalog.json` junto a `Toolkit.exe`, cámbiale algo y ejecuta `/report`.

- [ ] Dice `catalogo: junto al exe` y usa el modificado
- [ ] Al borrarlo, vuelve al embebido sin fallar

Esto valida la cascada de configuración: permite ajustar destinos de red sin recompilar.

### B5 · Agente

```powershell
.\Toolkit.exe /install-agent /share:\\SRV-FILE\Toolkit$ /ring:0-lab
```

- [ ] Se copia a `C:\ProgramData\Toolkit\bin\`
- [ ] La ACL impide escritura a usuarios estándar (probar desde `labagente`)
- [ ] Se crea la tarea `Toolkit Agent` corriendo como SYSTEM
- [ ] La tarea tiene **dos** disparadores: arranque (+5 min) y cada 4 h

```powershell
schtasks /Run /TN "Toolkit Agent"
# esperar, luego revisar C:\ProgramData\Toolkit\logs\
```

- [ ] Se ejecuta como SYSTEM y deja log
- [ ] **El consentimiento de ubicación llega igualmente al perfil de `labagente`** ← este es el caso crítico: SYSTEM no tiene el HKCU del agente

```powershell
.\Toolkit.exe /uninstall-agent
```

- [ ] Elimina la tarea
- [ ] Conserva logs, reportes y `rollback.json`

### B6 · Reinicio y persistencia

- [ ] Reiniciar la VM: `lfsvc` sigue en `Running`
- [ ] La tarea del agente se dispara sola a los 5 minutos
- [ ] Crear un usuario **nuevo** e iniciar sesión: hereda el consentimiento del perfil `Default`

---

## 5. FASE C — Instalación de aplicaciones

Las tres apps corporativas están con `enabled: false` porque no tienen ficha validada. Para probar el motor de extremo a extremo, usa el ejemplo de 7-Zip.

```powershell
# 1. Descargar el MSI y calcular su hash
Invoke-WebRequest https://www.7-zip.org/a/7z2409-x64.msi -OutFile 7z.msi
Get-FileHash .\7z.msi -Algorithm SHA256

# 2. Poner ese hash en catalog.json y enabled: true
# 3. Ejecutar
.\Toolkit.exe /silent /modules:apps
```

- [ ] Detecta que no está instalado
- [ ] Descarga (o copia del share)
- [ ] **Verifica el SHA-256**
- [ ] Instala en silencio
- [ ] **Vuelve a detectar después** de instalar
- [ ] Segunda ejecución: `YA-OK`, no reinstala

**Prueba de hash corrupto** — cambia un carácter del `sha256` en el catálogo:

- [ ] Aborta con `FALLO` y **no ejecuta el instalador**

Ese caso es el que impide que un instalador manipulado en el share se ejecute en 400 equipos.

### Fichas de las apps reales

```powershell
cd C:\Toolkit\scripts\tools
.\New-AppFicha.ps1 -Path 'D:\instaladores\NetExtender.msi' -Id netextender -OutputDir ..\..\docs\APP-FICHAS
```

Repetir para GoTo y MaxAssist. Cada ficha generada trae su propia lista de comprobación; **completarla antes de poner `enabled: true`**.

---

## 6. Lo que la VM NO puede validar

Sé honesto sobre el alcance de estas pruebas:

| No validable en VM | Por qué | Cómo validarlo |
|---|---|---|
| **Precisión de la ubicación** | Sin GPS ni WiFi real, `Test-LocationApi` devolverá `NoData` o precisión pésima por IP | Laptop real de un agente, con el proveedor de telefonía si el caso es E911 |
| **Latencia, jitter y pérdida reales** | La red de la VM es la del host con NAT en medio | Un puesto real del call center, en su VLAN |
| **Señal WiFi** | La VM no tiene adaptador inalámbrico | Puesto real |
| **MTU del enlace corporativo** | NAT del hipervisor la enmascara | Puesto real, sobre todo con la VPN levantada |
| **Comportamiento del antivirus corporativo** | La VM no lo lleva | Instalar el AV de producción en una VM, o probar en un equipo real del anillo 1 |
| **SmartScreen con binario firmado** | Aún no hay certificado | Tras comprar el certificado |

La VM valida **lógica y configuración**. El anillo 1 valida **realidad**.

---

## 7. Criterio de salida del anillo 0

No se pasa al anillo 1 hasta que, **en cada build de Windows**:

- [ ] Fases A, B y C completas sin fallos abiertos
- [ ] Idempotencia demostrada (segunda pasada = cero cambios)
- [ ] Reversión demostrada
- [ ] El consentimiento de ubicación llega al usuario estándar con el toolkit corriendo como SYSTEM
- [ ] Al menos una aplicación instalada de extremo a extremo con verificación de hash
- [ ] Rechazo de hash corrupto demostrado
- [ ] Instancia única demostrada
- [ ] Destinos de red reales puestos en el catálogo (nada marcado `CAMBIAR`)
- [ ] Ventana de mantenimiento ajustada a los turnos reales
- [ ] Ficha validada para cada app con `enabled: true`

### Registro de resultados

| Caso | W10 22H2 | W11 | Notas |
|---|---|---|---|
| A1 auditoría | | | |
| A2 aplicar ubicación | | | |
| A3 idempotencia | | | |
| A4 usuario estándar | | | |
| A5 reversión | | | |
| A6 instancia única | | | |
| B1 compilación | | | |
| B2 consola | | | |
| B3 interfaz | | | |
| B4 catálogo externo | | | |
| B5 agente | | | |
| B6 persistencia | | | |
| C1 instalación app | | | |
| C2 hash corrupto | | | |

---

## 8. Si algo falla

| Síntoma | Dónde mirar |
|---|---|
| El script no arranca | `-ExecutionPolicy Bypass`; ¿sesión elevada? |
| `dotnet build` no encuentra net48 | Falta el .NET Framework 4.8 Developer Pack |
| Faltan recursos embebidos | Rutas de `<EmbeddedResource>` en `Toolkit.App.csproj` |
| La ubicación se configura pero la app no la ve | Casi siempre es la rama `NonPackaged` del ConsentStore |
| El usuario puede desactivar la ubicación | `LetAppsAccessLocation` no se aplicó; revisar `lockDown` en el catálogo |
| El consentimiento no llega al usuario | Colmena `NTUSER.DAT` bloqueada; buscar avisos de `reg load` en el log |
| Instalación con código 1603 | Log detallado del MSI en `C:\ProgramData\Toolkit\logs\install-*.log` |
| Instalación con código 1618 | Otra instalación en curso; el motor reintenta una vez |

Todo queda registrado en `C:\ProgramData\Toolkit\logs\`. Adjunta el log al reportar cualquier fallo.
