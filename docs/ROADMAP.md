# Toolkit BPO — plan de mejora

Estado de partida (16-09-2026): compila, se firma, y todo lo de solo lectura está probado en un equipo real. Lo que cambia el sistema (activar ubicación, instalar apps, reparaciones, agente) está escrito pero **sin pasar por máquina de pruebas**. Ese es el primer bloque del plan, porque sin él lo demás son suposiciones.

Prioridad: **P0** bloquea usarlo en producción · **P1** primera semana en producción · **P2** cuando haya tiempo · **P3** ideas.
Esfuerzo: **S** horas · **M** 1-2 días · **L** más.

---

## 1. Validación en máquina de pruebas (P0)

Sin esto no se despliega. Una VM Windows 10 22H2 y otra Windows 11 24H2, limpias, con un usuario estándar además del admin (para reproducir "el técnico eleva con su cuenta, el agente usa la suya").

| Qué probar | Cómo saber que está bien | Esf. |
|---|---|---|
| Activar ubicación → Comprobar check-in | Pasa de `[NO LISTO]` a `[OK]` sin reiniciar; en la sesión del **agente** (no del admin) la página *Probar en el navegador* da coordenadas | S |
| Revertir | El registro vuelve exactamente al estado anterior (comparar `reg export` antes/después) | S |
| Instalar Genesys Cloud y Krisp | Código 0, la post-detección los ve, arrancan como el agente, Krisp aparece como dispositivo de audio | M |
| Reparaciones de Soporte, una por una | Especialmente *Reset de red*, *Limpiar temporales* (no borra nada en uso) y *Permitir micrófono* (Krisp y Genesys ven el micro) | M |
| Agente (`/install-agent`) | La tarea programada corre como SYSTEM, lee el manifest del share, sube el reporte | M |
| Certificado | Con `Install-SigningCert.ps1`, UAC muestra *Editor comprobado: danielnvcd* | S |

Dejar el procedimiento actualizado en `docs/PRUEBAS-VM.md` con capturas de lo que se espera ver.

---

## 2. Funcionalidad

### P0
- **GoTo y MaxAssist**: fichas reales o quitarlas del catálogo. Hoy son marcadores que fallan con "sin origen válido" y confunden al técnico. Falta saber qué producto exacto de GoTo se usa. — S (una vez se tenga el instalador)
- **Zoho con restricción por IP**: si se decide esa vía, añadir a *Comprobar check-in* la IP pública actual (`https://api.ipify.org` o equivalente) y compararla con la lista de IPs autorizadas en el catálogo. Con Ethernet en casi todos los puestos, esto es lo que realmente resuelve el check-in. — S

### P1
- **Estado del catálogo a la vista**: en la pestaña Aplicaciones, mostrar junto a cada app si está instalada y en qué versión sin tener que pulsar *Comprobar* (una pasada de `Test-AppInstalled` al cargar la lista). — S
- **Prueba de micrófono**: grabar 3 s con el dispositivo predeterminado y mostrar el nivel (WASAPI vía `NAudio` no vale — sin dependencias; usar `System.Media`/`winmm` `waveIn`). Es la comprobación que faltaría para cerrar "no me oyen". — M
- **Reporte para ticket en HTML**: mismo contenido que el `.txt` pero con semáforos y secciones plegables; se adjunta igual y se lee mejor. — S
- **Historial**: pestaña o botón "Últimas ejecuciones" leyendo `C:\ProgramData\Toolkit\reports\*.json` (qué se hizo, cuándo, resultado). — M
- **Actualización de fichas de apps**: script que consulta las URLs estables (`download.krisp.ai/win`, directorio de Genesys), detecta versión nueva, descarga, calcula SHA-256 y propone el cambio en `catalog.json`. Hoy es manual. — M

### P2
- **Perfil de puesto**: aplicar en un clic todo lo que un puesto nuevo necesita (ubicación + micro/cámara + no suspender + apps del catálogo + hora) y terminar con el reporte. Es el "alta de equipo". — S (es orquestar lo que ya existe)
- **Modo agente sin GUI para el técnico remoto**: `/support` ya existe; añadir `/support:fix-audio,fix-network` con las reparaciones seguras para poder lanzarlas desde el RMM. — S
- **Inventario de hardware para la CMDB**: exportar la ficha del equipo en JSON con un esquema estable (serie, modelo, RAM, disco, MAC, usuario). — S
- **Softphone: comprobación de puertos/RTP** hacia Genesys (UDP, no solo TCP 443): rango RTP y `*.mypurecloud.com` según la región. Requiere confirmar la región de la organización. — M
- **Multi-idioma**: hoy todo está en español sin acentos (para evitar problemas de codificación en consola). Sacar los textos a un recurso permitiría acentos en la GUI y un inglés si hace falta. — L

### P3
- Acceso rápido a Asistencia rápida / escritorio remoto del proveedor.
- Chequeo de licencias (Windows activado, Office) en la ficha del equipo.
- Notificación al agente (toast) cuando el técnico va a reiniciar o reparar audio.

---

## 3. Compatibilidad

| Área | Situación | Acción | Prio | Esf. |
|---|---|---|---|---|
| **Windows 10 21H2/22H2 y 11 22H2-24H2** | Objetivo principal; PS 5.1 y .NET 4.8 de fábrica | Matriz de pruebas en VM (sección 1) | P0 | M |
| **Windows 10 LTSC 2019/2021** | Sin Store ni `UsoClient` en algunas imágenes; `Get-PnpDevice` ok | Probar; hacer que *Buscar actualizaciones* avise en vez de fallar | P1 | S |
| **Windows 11 ARM64** (Surface, algunos portátiles) | El exe es x64: corre bajo emulación; los instaladores x64 de Genesys/Krisp también | Compilar `AnyCPU` o dos binarios; probar en un ARM real | P2 | M |
| **Equipos en dominio con GPO** | Las políticas de ubicación/navegador pueden venir de GPO y pisar lo que escribe el toolkit en el siguiente refresco | Detectar `gpresult`/claves `Policies` gestionadas y avisar "esto lo gobierna el dominio; cámbialo en la GPO" | P1 | M |
| **Escalado DPI 125-175 %** | Implementado con `AutoScaleMode.Dpi`; no verificado visualmente | Captura en VM al 150 % | P1 | S |
| **Cambio de monitor con distinto DPI** | .NET 4.8 no reescala en caliente sin `app.config` (y el exe no lleva `.config` a propósito) | Aceptar (la ventana se ve borrosa al mover de monitor) o añadir `DpiChanged` manual | P3 | M |
| **PowerShell 7 instalado** | No afecta: el exe usa siempre 5.1 embebido en proceso | Nada | — | — |
| **Antivirus corporativo** | Puede bloquear `reg load` de colmenas, `shutdown`, o el runspace en proceso | Lista blanca por certificado (ya se firma); documentar exclusiones mínimas | P1 | S |
| **Sin Internet en el puesto** | Descarga de apps falla; el resto funciona | `packageRepo` en un share local; el toolkit ya lo prioriza | P1 | S (solo configurar) |
| **Cuentas de agente sin perfil aún** | El consentimiento se escribe en `Default`, así que el perfil nuevo nace bien | Verificar en la VM creando un usuario después de aplicar | P0 | S |
| **Firefox ESR con `policies.json`** | Si ya hay un `policies.json` en `distribution\`, tiene prioridad sobre el registro | Detectarlo y avisar | P2 | S |

---

## 4. Seguridad

| Tema | Acción | Prio | Esf. |
|---|---|---|---|
| **Certificado de CA pública** | Comprar (OV basta; EV evita SmartScreen desde el día 1). Hasta entonces, desplegar el `.cer` autofirmado por GPO. | P1 | S + coste |
| **Integridad del catálogo externo** | Un `catalog.json` junto al exe o en el share lo puede editar cualquiera con acceso: podría apuntar `url` a un instalador malicioso. Exigir `sha256` no vacío para instalar (hoy solo avisa) y, opcionalmente, firmar el catálogo. | P1 | S |
| **Descargas solo por HTTPS** | Rechazar `http://` en `source.url`. | P1 | S |
| **Secretos en el catálogo** | La ficha de GoTo prevé `COMPANYKEY`; no debe ir en claro. Leerlo de un archivo con ACL en el share (ya previsto en el PLAN §11). | P1 | M |
| **Superficie del agente** | La tarea corre como SYSTEM y lee un share: si el share se compromete, se ejecuta lo que diga el manifest. Firmar el manifest o restringir a instalar solo del catálogo embebido. | P2 | M |
| **Log sin datos sensibles** | Ya no se registran contraseñas; revisar que `ipconfig /all` del reporte no sea un problema para el cliente (contiene MACs y DNS internos). | P2 | S |

---

## 5. Calidad y mantenimiento

| Tema | Acción | Prio | Esf. |
|---|---|---|---|
| **Pruebas automáticas** | Pester para las funciones puras (parseo de catálogo, `Compare-AppVersion`, detección, `Get-MsiExitMeaning`) y un smoke test que ejecute `/report` en la VM y compruebe el código de salida. | P1 | M |
| **PSScriptAnalyzer en el build** | Añadirlo a `build.ps1` (hoy solo valida sintaxis). | P1 | S |
| **CI** | GitHub Actions con runner Windows: build + análisis + Pester en cada push; el `.pfx` como secreto para firmar releases. | P2 | M |
| **Versionado** | `Version` en el csproj a mano. Pasar a `MAJOR.MINOR.BUILD` con la fecha o el número de commit para distinguir binarios en el share. | P1 | S |
| **Tiempo límite por acción de soporte** | `ScriptHost.Invoke` no tiene timeout; una acción colgada deja la GUI "ocupada" para siempre. Añadir timeout y botón *Cancelar*. | P1 | M |
| **Refactor de colmenas de usuario** | `Toolkit.Location` y `Toolkit.Support` tienen cada uno su bucle de cargar/descargar `NTUSER.DAT`. Unificar en `Toolkit.Core` (`Invoke-ForEachUserHive`). | P2 | S |
| **Textos con acentos** | Los `.psm1` evitan acentos por la codificación de consola; la GUI sí los soportaría. Decidir una política (UTF-8 con BOM en los scripts) y aplicarla. | P2 | M |
| **Documentar el catálogo** | Esquema JSON (`catalog.schema.json`) para validar en el build y tener autocompletado en VS Code. | P2 | S |

---

## 6. Despliegue y operación

| Tema | Acción | Prio | Esf. |
|---|---|---|---|
| **Anillo piloto** | 5-10 equipos con `/install-agent /ring:piloto` una semana antes del resto. | P0 | S |
| **Panel de reportes** | Los JSON del share ya tienen todo; un script que los consolide en un CSV/HTML con semáforos por equipo (ubicación OK / apps OK / última ejecución). | P1 | M |
| **Actualización del exe en el share** | El agente debería comprobar el hash del `Toolkit.exe` del share y auto-actualizarse (ya está previsto en el PLAN; verificar que funciona). | P1 | M |
| **Ventana de mantenimiento configurable** | Hoy está en código (`Test-MaintenanceWindow`, 23:00-07:00). Pasarla al catálogo por sede/turno. | P1 | S |
| **Manual de 1 página para técnicos** | Qué botón para qué síntoma ("no me oyen" → Audio y micrófono → Reiniciar audio → Permitir micro). | P1 | S |

---

## Orden sugerido (primeras 2 semanas)

1. VM de pruebas y matriz de la sección 1 (todo P0).
2. Decidir Zoho por IP o por geovalla y, según eso, IP pública en el check-in.
3. Fichas de GoTo/MaxAssist o quitarlas.
4. `sha256` obligatorio + solo HTTPS + versión automática (tres cambios pequeños de seguridad).
5. Pester + PSScriptAnalyzer en el build.
6. Piloto en 5-10 equipos con el `.cer` desplegado por GPO.
7. Certificado de CA pública en paralelo (es lo que más tarda en llegar).
