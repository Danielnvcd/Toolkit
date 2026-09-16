# Toolkit BPO

Utilidad portable para Windows 10/11 que resuelve, desde una sola ventana, las tareas de soporte que normalmente hay que hacer a mano y en varios sitios:

- **Activar la ubicación** de Windows para todos los usuarios del equipo, **sin reiniciar**.
- **Gestionar las cuentas locales**: ver quién hay, cambiar o quitar contraseñas, habilitar, deshabilitar, crear y eliminar usuarios.
- **Instalar aplicaciones** en silencio a partir de un catálogo.
- **Diagnosticar la red**: latencia, jitter, pérdida de paquetes, DNS, MTU, puertos y TLS.
- **Soporte de primer nivel**: info del equipo, audio y micrófono, impresoras, hora, temporales, reparar red, reporte para ticket.

Es **un único archivo**, `Toolkit.exe`. No se instala: se copia a un USB o a una carpeta compartida y se ejecuta. Todo lo que necesita ya viene con Windows.

---

## Empezar

1. Copia `Toolkit.exe` al equipo (o ejecútalo directamente desde el USB).
2. Haz doble clic. Pedirá permisos de administrador: son necesarios porque toca servicios, registro y cuentas.
3. Cada cosa tiene su pestaña: **Ubicación**, **Aplicaciones**, **Red**, **Soporte** y **Usuarios**. Cada una lleva sus propias opciones y sus propios botones; el log de abajo es común.
4. En Ubicación y Aplicaciones, pulsa primero **Auditar** / **Comprobar instaladas**. No cambia nada; solo muestra el estado. Empieza siempre por ahí.
5. Cuando lo tengas claro, pulsa **Activar ubicación** (activa el servicio, las políticas, los usuarios y los navegadores, y al terminar comprueba el check-in) o **Instalar seleccionadas**. Todo lo que hace queda en el log de la ventana y en `C:\ProgramData\Toolkit\logs\`.

Si algo no te convence, **Revertir** (en la pestaña Ubicación) deshace todos los cambios de registro que hizo el toolkit en ese equipo. Las instalaciones de aplicaciones no se revierten.

---

## Qué hace cada parte

### Ubicación

Activar la ubicación en Windows no es un solo interruptor: hay cuatro capas y, si falta una, las aplicaciones no reciben la posición y no dicen por qué. El toolkit las aplica todas:

1. Servicio de geolocalización (`lfsvc`) en automático y arrancado.
2. Interruptor maestro del sistema.
3. Consentimiento de la máquina y de **cada usuario del equipo**, incluidos los que no tienen la sesión abierta y el perfil `Default` (para los usuarios que se creen después). Se activa también el permiso para **aplicaciones de escritorio**, que es el que suelen necesitar los programas clásicos.
4. Políticas para que nadie la desactive desde Configuración (opción *Impedir que el usuario desactive la ubicación*, marcada por defecto).

**Por qué no hace falta reiniciar:** el servicio de ubicación solo lee su configuración al arrancar. Por eso muchas guías terminan con "reinicia el equipo". El toolkit, en lugar de eso, reinicia el servicio y a continuación pregunta a la API de geolocalización de Windows si responde. Nadie pierde la sesión.

#### Check-in de Zoho en el navegador

El motivo de todo esto es que los agentes hagan **check-in en Zoho People desde el navegador**, y ahí hacen falta dos cosas más que Windows no resuelve:

- **Permiso del navegador.** Aunque Windows tenga la ubicación activa, el navegador pregunta "zoho.com quiere conocer tu ubicación" y, si el agente pulsa *Bloquear* una vez, el check-in deja de funcionar en ese perfil sin ningún aviso. *Activar ubicación* escribe la política de Chrome y Edge (`DefaultGeolocationSetting = 1`, permitir sin preguntar) y la lista de sitios permitidos de Firefox. Chrome y Edge la aplican al momento; Firefox al reiniciarse. Se puede desmarcar en la pestaña (o `/nobrowsers`).
- **Precisión.** Sin GPS, Windows ubica por las redes Wi-Fi cercanas (decenas de metros) o, si el equipo no tiene adaptador Wi-Fi, por la IP pública (kilómetros). **Los sobremesa por Ethernet, que son la mayoría en un call center, caen en el segundo caso**: con geovalla en Zoho pueden hacer check-in "fuera del radio" aunque todo esté activado. Tres salidas, de mejor a peor:
  1. En Zoho People, configurar la asistencia con **restricción por IP** (la IP pública de la oficina) en vez de, o además de, geovalla. Es lo pensado para puestos fijos y no necesita nada en el equipo.
  2. Un **adaptador Wi-Fi USB** en cada equipo. No hace falta conectarlo a ninguna red: basta con que esté habilitado para que Windows triangule con las redes de alrededor.
  3. Fijar la **ubicación predeterminada** del equipo (Configuración → Privacidad → Ubicación → Ubicación predeterminada, abre Mapas). Windows la usa como respaldo cuando no tiene nada mejor. Es manual, equipo por equipo.

El botón **Comprobar check-in Zoho** (o `Toolkit.exe /checkin`) recorre en orden todo lo que tiene que estar bien y dice si el equipo está listo o qué falta: capas de Windows, política de cada navegador instalado, adaptador Wi-Fi, posición real con su precisión, y conectividad (DNS + 443) hacia Zoho y hacia el servicio de posicionamiento de Microsoft. No modifica nada.

**Probar en el navegador** abre una página local que pide la ubicación exactamente igual que Zoho y muestra coordenadas, precisión o el error concreto (permiso denegado, posición no disponible…). Es la prueba definitiva. **Ajustes de Windows** abre Configuración → Privacidad → Ubicación.

Los sitios de Zoho y la precisión máxima aceptable se ajustan en `catalog.json` → `location.checkIn` (si tu Zoho está en el centro de datos europeo, cambia `.com` por `.eu`).

### Usuarios

La pestaña **Usuarios** muestra todas las cuentas locales con su estado, si son administradoras, si tienen contraseña, cuándo iniciaron sesión por última vez, si tienen la sesión abierta y dónde está su carpeta de perfil. Desde ahí puedes:

| Botón | Qué hace |
|---|---|
| Nuevo usuario | Crea una cuenta; con o sin contraseña, administrador o no |
| Cambiar contraseña | Pide la contraseña dos veces |
| Quitar contraseña | La cuenta entra sin contraseña (Windows solo lo permite en el propio equipo, no por red ni escritorio remoto) |
| Habilitar / Deshabilitar | Oculta o vuelve a mostrar la cuenta en la pantalla de inicio |
| Eliminar usuario | Borra la cuenta; pregunta si quieres borrar también su carpeta `C:\Users\<nombre>` |

Por seguridad, no deja eliminar las cuentas integradas de Windows, la cuenta con la que estás ejecutando el toolkit ni una cuenta con sesión abierta. Las contraseñas nunca se escriben en el log. Estas acciones no se pueden revertir con el botón *Revertir*.

### Aplicaciones

Instala en silencio las aplicaciones definidas en `catalog.json` (MSI o EXE): comprueba el hash del instalador, espera si otro instalador está en marcha, reintenta y verifica que la aplicación quedó instalada. Ver la sección *Configurar* para añadir las tuyas.

### Red

Mide contra los destinos que indiques en `catalog.json`: ping (latencia, jitter y pérdida), resolución DNS, puertos TCP, certificados TLS, MTU y proxy. Sirve para saber si un "va lento" o "se corta" es culpa de la red o del equipo.

### Soporte

Las herramientas de un clic que un técnico de primer nivel usa a diario. Todas funcionan en cualquier Windows 10/11 sin instalar nada.

| Diagnóstico (no cambia nada) | Qué muestra |
|---|---|
| Info del equipo | Modelo, serie, Windows y build, CPU, RAM libre, discos, tiempo encendido, BIOS, TPM, antivirus. Avisa si hay poca RAM, poco disco o lleva semanas sin reiniciar |
| Audio y micrófono | Servicios de audio, tarjetas, dispositivos activos, si hay micrófono, y los permisos de micrófono/cámara de Windows |
| Impresoras | Cola de impresión, impresoras, predeterminada, estado y trabajos atascados |
| Windows Update | Último parche, reinicio pendiente, estado del servicio |
| Hora del sistema | Hora, zona horaria, fuente NTP y desfase |
| Errores recientes (24 h) | Errores y críticos del registro de eventos agrupados por origen; marca apagados inesperados y fallos de disco |
| Procesos que más consumen | Top por CPU y por memoria, con el título de ventana |

| Reparación | Qué hace |
|---|---|
| Reparar red | Vacía DNS, renueva DHCP y comprueba puerta de enlace e Internet. Sin reiniciar |
| Reset de red | Además, Winsock y pila TCP/IP. Requiere reiniciar |
| Reiniciar audio | Reinicia los servicios de audio (el clásico "se me fue el sonido") |
| Limpiar cola de impresión | Elimina los trabajos atascados y arranca el Spooler |
| Sincronizar hora | Fuerza la sincronización NTP |
| Limpiar temporales | Temporales de todos los perfiles y de Windows (solo de más de 1 día) y papelera; dice cuántos MB liberó |
| Permitir micrófono y cámara | Igual que la ubicación: equipo, apps de escritorio y todos los usuarios. Reversible con *Revertir* |
| No suspender el equipo | Con corriente no se suspende ni hiberna; la pantalla se apaga a los 15 min |
| Buscar actualizaciones | Pide a Windows Update buscar, descargar e instalar |
| Reparar archivos del sistema | `sfc /scannow` (5-20 min) |
| Reiniciar equipo (60 s) / Cancelar | Reinicio con aviso de Windows y cuenta atrás para que el agente guarde |

**Guardar reporte para ticket** genera un `.txt` con todo lo anterior más ubicación, usuarios e `ipconfig /all` en `C:\ProgramData\Toolkit\reports\` y lo abre en el Explorador, listo para adjuntar a un escalado. **Copiar log** copia lo que hay en pantalla al portapapeles.

---

## Línea de comandos

La misma lógica está disponible sin interfaz, para scripts o tareas programadas:

```powershell
Toolkit.exe                                # interfaz gráfica
Toolkit.exe /report                        # auditoría completa, no modifica nada
Toolkit.exe /report /modules:users         # solo el inventario de cuentas
Toolkit.exe /checkin                       # ¿funcionará el check-in de Zoho con ubicación? no modifica nada
Toolkit.exe /support                       # diagnóstico de soporte completo + reporte para ticket
Toolkit.exe /support:audio,events          # solo esas acciones (info, audio, printers, update, time, events, procs, report)
Toolkit.exe /silent /all                   # aplica todo sin preguntar
Toolkit.exe /silent /modules:location      # solo la ubicación
Toolkit.exe /silent /apps:ejemplo-7zip     # solo esas apps del catálogo
Toolkit.exe /rollback                      # revierte los cambios de registro
Toolkit.exe /nolockdown                    # no bloquea el interruptor de ubicación al usuario
Toolkit.exe /?                             # ayuda completa
```

En modo desatendido (`/silent`) el módulo de usuarios **solo lista** las cuentas; nunca las modifica. Cambiar contraseñas o borrar usuarios se hace siempre desde la interfaz.

Códigos de salida: `0` correcto · `3010` correcto pero requiere reinicio (lo pidió algún instalador) · `5` sin permisos de administrador · `1001` falló la ubicación · `1002` falló alguna aplicación · `1003` red en estado crítico · `1` otro error.

---

## Configurar

Toda la configuración está en un solo archivo, `catalog.json`. El exe lleva uno dentro; si pones otro **junto al exe**, se usa ese (útil para tener una versión por cliente o por sede sin recompilar).

```jsonc
{
  "location": {
    "lockDown": true,        // impedir que el usuario desactive la ubicación
    "verifyWithApi": true,   // preguntar a Windows si la ubicación responde tras aplicar
    "getPosition": false,    // true = obtener coordenadas reales (tarda hasta 20 s)
    "checkIn": {
      "browserPolicy": true, // dar permiso de ubicación a Chrome/Edge/Firefox
      "urls": [ "https://people.zoho.com", "https://accounts.zoho.com" ],
      "maxAccuracyMeters": 500 // precisión mínima aceptable; ajustar al radio de la geovalla de Zoho
    }
  },
  "network": {
    "pingTargets": [ { "label": "Internet", "host": "8.8.8.8" } ],
    "dnsNames":    [ "www.google.com" ],
    "tcpTargets":  [ { "label": "Web", "host": "ejemplo.com", "port": 443 } ]
  },
  "apps": [ /* ver más abajo */ ]
}
```

### Añadir una aplicación

Cada aplicación del catálogo necesita saber cómo instalarse en silencio y cómo comprobar que quedó instalada. No lo escribas a mano: el script `scripts\tools\New-AppFicha.ps1` lee el instalador y genera la ficha:

```powershell
scripts\tools\New-AppFicha.ps1 -Path 'D:\instaladores\MiApp.msi' -Id miapp
```

Pega el resultado en `apps` del `catalog.json` y prueba la instalación en un equipo limpio. El catálogo trae **Genesys Cloud** y **Krisp** (instaladores oficiales, con su SHA-256, `enabled: true`) y un ejemplo con 7-Zip.

`enabled` solo gobierna el **despliegue desatendido** (`/silent /all` y el agente). En la pestaña Aplicaciones, lo que el técnico marca se instala aunque tenga `enabled: false`: la selección a mano manda.

---

## Compilar

Solo hace falta si cambias algo. Requiere Windows con el SDK de .NET.

```powershell
cd build
.\build.ps1                                  # valida scripts -> compila -> comprueba que es un solo archivo
.\build.ps1 -Sign                            # además lo firma con el certificado de danielnvcd (recomendado)
.\build.ps1 -Sign -Thumbprint <huella>       # o con otro certificado del almacén (p. ej. uno de CA pública)
```

Deja el resultado en `dist\Toolkit.exe` junto con su SHA-256.

### Firma y "Editor"

Lo que Windows muestra como **Editor** en el aviso de UAC (y en SmartScreen) no sale de las propiedades del exe: sale de la firma digital Authenticode. Sin firma siempre dice "Editor: desconocido".

El repo lleva un certificado de firma de código **autofirmado** a nombre de `danielnvcd` (`scripts\tools\New-SigningCert.ps1` lo crea; la parte pública está en `build\cert\danielnvcd-codesign.cer`, la clave privada se queda en el equipo que compila). `build.ps1 -Sign` firma el exe con él, con sello de tiempo de DigiCert. No hace falta el Windows SDK: si no hay `signtool`, firma PowerShell.

Como es autofirmado, en cada equipo destino hay que instalarlo una vez como de confianza — `scripts\tools\Install-SigningCert.ps1` como administrador (o por GPO en toda la flota). Hecho eso, UAC muestra **"Editor comprobado: danielnvcd"** y el antivirus puede poner el certificado en lista blanca en vez de cada hash.

Lo que un certificado autofirmado **no** quita es el aviso de SmartScreen ("Windows protegió tu PC") la primera vez que se ejecuta un binario nuevo: eso solo lo resuelve un certificado emitido por una CA pública (DigiCert, Sectigo, GlobalSign…), que se compra. Si se compra, se importa al almacén y se compila con `-Sign -Thumbprint <huella>`; nada más cambia.

El logo vive en `assets\logo.svg`. Si lo cambias, regenera el icono del exe y de las ventanas con `scripts\tools\New-Logo.ps1` (renderiza el SVG con el Edge que trae Windows y produce `assets\logo.ico` y `assets\logo.png`); el `.ico` se versiona porque es lo que compila.

Cómo está montado, en una línea: el exe es un envase en C# que lleva embebidos unos módulos de PowerShell (`scripts\modules\`) y los ejecuta en memoria, sin escribirlos en disco. Eso evita problemas de `ExecutionPolicy`, de antivirus bloqueando scripts sueltos y de scripts editados por ahí. Para desarrollar sin recompilar, `scripts\Toolkit.ps1` ejecuta exactamente los mismos módulos desde un menú de consola.

### Requisitos en el equipo destino

Nada que instalar. Todo viene de fábrica:

| Necesita | Dónde está |
|---|---|
| .NET Framework 4.8 | Windows 10 1903 o posterior y Windows 11 |
| Windows PowerShell 5.1 | Cualquier Windows 10/11 (no hace falta PowerShell 7) |

Lo único que el exe escribe en el equipo es la carpeta `C:\ProgramData\Toolkit\` (logs, reportes y el archivo de reversión). Es deliberado: el archivo de reversión debe quedarse en la máquina para poder deshacer los cambios otro día, aunque ya no tengas el mismo USB. Se puede cambiar con `/root:<ruta>`.

---

## Para muchos equipos

Si tienes que aplicar esto a decenas o cientos de equipos, el toolkit puede **instalarse a sí mismo como agente**: una tarea programada que se ejecuta como SYSTEM, lee un `manifest.json` de una carpeta compartida y aplica lo que ahí se indique. A partir de ese momento, cualquier cambio se despliega editando un JSON en el share, sin volver a tocar los equipos.

```powershell
Toolkit.exe /install-agent /share:\\SERVIDOR\Toolkit$ /ring:piloto
Toolkit.exe /uninstall-agent
```

Los reportes de cada equipo se suben al share en JSON, así que se puede ver el estado de todos sin entrar uno por uno. Para el primer despliegue hay un script remoto (`scripts\deploy\Deploy-Remote.ps1`) que lo hace por WinRM o SMB a partir de una lista de equipos.

Consejos si vas por ese camino:

- **Firma el exe.** Sin firma, SmartScreen y los antivirus lo bloquean y acabas creando excepciones a mano en cada equipo.
- **Ajusta la ventana de mantenimiento** (`Test-MaintenanceWindow` en `Toolkit.Core.psm1`). Por defecto solo instala aplicaciones entre las 23:00 y las 07:00 para no interrumpir a nadie.
- **Prueba en máquina virtual** antes. El procedimiento paso a paso está en [`docs/PRUEBAS-VM.md`](docs/PRUEBAS-VM.md).

El diseño completo está en [`docs/PLAN.md`](docs/PLAN.md) y el plan de mejora (funcionalidad, compatibilidad, seguridad, calidad, despliegue), con prioridades y orden sugerido, en [`docs/ROADMAP.md`](docs/ROADMAP.md).

---

## Estado

Compila y arranca en Windows 10/11 con el SDK de .NET 8 (`build\build.ps1`). Lo que ya se ha ejecutado en un equipo real: las auditorías y diagnósticos de solo lectura (ubicación, check-in, navegadores, info del equipo, audio, impresoras, Windows Update, hora). Lo que todavía necesita una pasada en máquina de pruebas antes de ir a producción: aplicar la ubicación, instalar Genesys Cloud y Krisp, las reparaciones de la pestaña Soporte y el agente. Procedimiento en [`docs/PRUEBAS-VM.md`](docs/PRUEBAS-VM.md).

---

## Autor

**Toolkit BPO** — creado por **danielnvcd**. La identidad de la app (creador, copyright, descripción) vive en `src\Toolkit.App\Toolkit.App.csproj` y de ahí sale lo que muestran el Explorador (Propiedades → Detalles del exe), el diálogo *Acerca de* de la app (clic en el logo o en "Acerca de") y `Toolkit.exe /?`.

---

## Licencia

[MIT](LICENSE) — libre de usar, copiar, modificar y distribuir, también con fines comerciales, manteniendo el aviso de copyright. Sin garantía.
