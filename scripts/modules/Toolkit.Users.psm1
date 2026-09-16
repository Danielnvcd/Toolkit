<#
    Toolkit.Users.psm1
    Gestion de cuentas de usuario LOCALES: inventario, contrasena, habilitar/deshabilitar,
    crear y eliminar.

    Se usa ADSI (proveedor WinNT) en vez de Get-LocalUser/Set-LocalUser porque:
      - funciona en cualquier Windows 10/11 con PowerShell 5.1, sin depender del
        modulo Microsoft.PowerShell.LocalAccounts (que falla con cuentas huerfanas
        o de Azure AD en los grupos)
      - permite dejar una cuenta SIN contrasena (Set-LocalUser rechaza la cadena vacia)
      - los nombres de grupo se resuelven por SID, asi funciona en Windows en espanol
        ("Administradores") y en ingles ("Administrators")

    NADA de este modulo pasa por rollback.json: cambiar una contrasena o borrar una
    cuenta no es reversible. Todo queda en el log (nunca la contrasena).
#>

if (-not (Get-Command 'Write-Log' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'Toolkit.Core.psm1') -Force -DisableNameChecking -Global
}

# Banderas de UserFlags (ADS_USER_FLAG_ENUM)
$script:UF_ACCOUNTDISABLE     = 0x0002
$script:UF_LOCKOUT            = 0x0010
$script:UF_PASSWD_NOTREQD     = 0x0020
$script:UF_DONT_EXPIRE_PASSWD = 0x10000

# SIDs conocidos (independientes del idioma de Windows)
$script:SidAdministrators = 'S-1-5-32-544'
$script:SidUsers          = 'S-1-5-32-545'

#region ---------- Inventario ----------

function Get-LocalUserInventory {
    <#
        Devuelve una fila por cuenta local con todo lo que necesita la GUI y el reporte.
        Solo lectura. No intenta iniciar sesion con contrasena en blanco (eso cuenta
        como intento fallido y puede bloquear cuentas con politica de bloqueo).
    #>
    [CmdletBinding()]
    param()

    $out      = @()
    $computer = Get-LocalComputerEntry
    if (-not $computer) { return $out }

    # Miembros de Administradores, por SID (robusto ante cuentas huerfanas y de dominio)
    $adminSids = @(Get-LocalGroupMemberSids -GroupSid $script:SidAdministrators)

    # Perfiles en disco: ruta, si esta cargado (= sesion abierta) y ultimo uso
    $profiles = @{}
    try {
        foreach ($pr in @(Get-CimInstance Win32_UserProfile -ErrorAction Stop)) {
            if ($pr.SID) { $profiles[$pr.SID] = $pr }
        }
    } catch { }

    $currentSid = $null
    try { $currentSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value } catch { }

    $users = @()
    try { $users = @($computer.Children | Where-Object { $_.SchemaClassName -eq 'user' }) } catch { return $out }

    foreach ($u in $users) {
        $name = [string]$u.Name
        $sid  = $null
        try { $sid = (New-Object Security.Principal.SecurityIdentifier(([byte[]]$u.objectSid.Value), 0)).Value } catch { }

        $flags = 0
        try { $flags = [int]$u.InvokeGet('UserFlags') } catch { }

        $rid = 0
        if ($sid -and $sid -match '-(\d+)$') { $rid = [int]$Matches[1] }

        $lastLogon = $null
        try { $lastLogon = [datetime]$u.InvokeGet('LastLogin') } catch { }

        $pwdLastSet = $null
        try {
            $age = [int]$u.InvokeGet('PasswordAge')
            if ($age -ge 0) { $pwdLastSet = (Get-Date).AddSeconds(-$age) }
        } catch { }

        $fullName = ''
        try { $fullName = [string]$u.InvokeGet('FullName') } catch { }
        $desc = ''
        try { $desc = [string]$u.InvokeGet('Description') } catch { }

        $profile = $null
        if ($sid -and $profiles.ContainsKey($sid)) { $profile = $profiles[$sid] }

        $out += [pscustomobject]@{
            Name              = $name
            FullName          = $fullName
            Description       = $desc
            Sid               = $sid
            Rid               = $rid
            # RID < 1000 = cuenta integrada (Administrador 500, Invitado 501, DefaultAccount 503, WDAGUtilityAccount 504)
            BuiltIn           = ($rid -gt 0 -and $rid -lt 1000)
            Enabled           = (($flags -band $script:UF_ACCOUNTDISABLE) -eq 0)
            LockedOut         = (($flags -band $script:UF_LOCKOUT) -ne 0)
            PasswordRequired  = (($flags -band $script:UF_PASSWD_NOTREQD) -eq 0)
            PasswordNeverExpires = (($flags -band $script:UF_DONT_EXPIRE_PASSWD) -ne 0)
            PasswordLastSet   = $pwdLastSet
            LastLogon         = $lastLogon
            IsAdmin           = ($sid -and $adminSids -contains $sid)
            IsCurrentUser     = ($sid -and $sid -eq $currentSid)
            HasProfile        = ($null -ne $profile)
            ProfilePath       = $(if ($profile) { $profile.LocalPath } else { $null })
            SessionOpen       = $(if ($profile) { [bool]$profile.Loaded } else { $false })
        }
    }

    return @($out | Sort-Object BuiltIn, Name)
}

function Show-LocalUserInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Users)

    Write-Host ''
    Write-Host '  USUARIOS LOCALES' -ForegroundColor Cyan
    Write-Host '  ----------------' -ForegroundColor Cyan
    $fmt = '    {0,-22} {1,-12} {2,-6} {3,-12} {4,-17} {5}'
    Write-Host ($fmt -f 'Usuario', 'Estado', 'Admin', 'Contrasena', 'Ultimo inicio', 'Sesion') -ForegroundColor Gray
    foreach ($u in $Users) {
        $estado = if ($u.LockedOut) { 'BLOQUEADA' } elseif ($u.Enabled) { 'Activa' } else { 'Deshabilitada' }
        $pwd    = if ($u.PasswordRequired) { 'requerida' } else { 'SIN contrasena' }
        $last   = if ($u.LastLogon) { $u.LastLogon.ToString('yyyy-MM-dd HH:mm') } else { 'nunca' }
        $ses    = if ($u.SessionOpen) { 'ABIERTA' } elseif ($u.HasProfile) { 'perfil' } else { '-' }
        $color  = if ($u.BuiltIn) { 'DarkGray' } elseif (-not $u.Enabled) { 'Yellow' } else { 'White' }
        Write-Host ($fmt -f $u.Name, $estado, $(if ($u.IsAdmin) { 'si' } else { '' }), $pwd, $last, $ses) -ForegroundColor $color
    }
    Write-Host ''
}

#endregion

#region ---------- Acciones ----------

function Set-LocalUserPassword {
    <# Cambia la contrasena. Vuelve a marcar la cuenta como "contrasena requerida". #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password
    )

    if ($Password.Length -eq 0) { return Clear-LocalUserPassword -Name $Name }

    $u = Get-LocalUserEntry -Name $Name
    if (-not $u) { return New-ActionResult -Success $false -Message "La cuenta '$Name' no existe" }
    if (Test-ReportOnly) { return New-ActionResult -Success $false -Message 'Modo reporte: no se cambian contrasenas' }

    try {
        $u.SetPassword($Password)
        $flags = [int]$u.InvokeGet('UserFlags')
        if (($flags -band $script:UF_PASSWD_NOTREQD) -ne 0) {
            $u.InvokeSet('UserFlags', ($flags -band (-bnot $script:UF_PASSWD_NOTREQD)))
        }
        $u.SetInfo()
        Write-Log "  + Contrasena cambiada para '$Name'" -Level OK
        return New-ActionResult -Success $true -Message "Contrasena de '$Name' cambiada"
    } catch {
        $msg = Get-AdsiErrorText $_
        Write-Log "  x No se pudo cambiar la contrasena de '$Name': $msg" -Level ERROR
        return New-ActionResult -Success $false -Message $msg
    }
}

function Clear-LocalUserPassword {
    <#
        Deja la cuenta SIN contrasena (inicio de sesion directo).
        Primero se marca PASSWD_NOTREQD: sin eso, la politica de longitud minima
        rechaza la contrasena vacia.
        Nota: por defecto Windows solo permite cuentas sin contrasena en la consola
        local (no por red / escritorio remoto). Eso es lo deseable en un call center.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $u = Get-LocalUserEntry -Name $Name
    if (-not $u) { return New-ActionResult -Success $false -Message "La cuenta '$Name' no existe" }
    if (Test-ReportOnly) { return New-ActionResult -Success $false -Message 'Modo reporte: no se cambian contrasenas' }

    try {
        $flags = [int]$u.InvokeGet('UserFlags')
        $u.InvokeSet('UserFlags', ($flags -bor $script:UF_PASSWD_NOTREQD))
        $u.SetInfo()
        $u.SetPassword('')
        $u.SetInfo()
        Write-Log "  + Cuenta '$Name' sin contrasena (inicio de sesion directo, solo consola local)" -Level OK
        return New-ActionResult -Success $true -Message "'$Name' ya no tiene contrasena"
    } catch {
        $msg = Get-AdsiErrorText $_
        Write-Log "  x No se pudo quitar la contrasena de '$Name': $msg" -Level ERROR
        return New-ActionResult -Success $false -Message $msg
    }
}

function Enable-LocalUserAccount {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return Set-LocalUserEnabled -Name $Name -Enabled $true
}

function Disable-LocalUserAccount {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return Set-LocalUserEnabled -Name $Name -Enabled $false
}

function Set-LocalUserEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Enabled
    )

    $u = Get-LocalUserEntry -Name $Name
    if (-not $u) { return New-ActionResult -Success $false -Message "La cuenta '$Name' no existe" }
    if (Test-ReportOnly) { return New-ActionResult -Success $false -Message 'Modo reporte: sin cambios' }

    if (-not $Enabled) {
        $guard = Test-LocalUserProtected -Name $Name -Action 'deshabilitar'
        if ($guard) { return New-ActionResult -Success $false -Message $guard }
    }

    try {
        $u.InvokeSet('AccountDisabled', (-not $Enabled))
        $u.SetInfo()
        $verb = if ($Enabled) { 'habilitada' } else { 'deshabilitada' }
        Write-Log "  + Cuenta '$Name' $verb" -Level OK
        return New-ActionResult -Success $true -Message "'$Name' $verb"
    } catch {
        $msg = Get-AdsiErrorText $_
        Write-Log "  x No se pudo cambiar el estado de '$Name': $msg" -Level ERROR
        return New-ActionResult -Success $false -Message $msg
    }
}

function Remove-LocalUserAccount {
    <#
        Elimina la cuenta. Con -RemoveProfile borra tambien la carpeta C:\Users\<nombre>
        y su entrada en ProfileList (via Win32_UserProfile, que es lo que hace el propio
        Windows desde Propiedades del sistema > Perfiles de usuario).
        IRREVERSIBLE.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$RemoveProfile
    )

    $info = Get-LocalUserInventory | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $info) { return New-ActionResult -Success $false -Message "La cuenta '$Name' no existe" }
    if (Test-ReportOnly) { return New-ActionResult -Success $false -Message 'Modo reporte: sin cambios' }

    $guard = Test-LocalUserProtected -Name $Name -Action 'eliminar' -Info $info
    if ($guard) {
        Write-Log "  ! No se elimina '$Name': $guard" -Level WARN
        return New-ActionResult -Success $false -Message $guard
    }

    # El perfil se borra ANTES que la cuenta: Win32_UserProfile lo localiza por SID
    # y, una vez borrada la cuenta, el SID ya no resuelve.
    if ($RemoveProfile -and $info.HasProfile) {
        try {
            $pr = Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $info.Sid) -ErrorAction Stop
            if ($pr) {
                Remove-CimInstance -InputObject $pr -ErrorAction Stop
                Write-Log "  + Perfil eliminado: $($info.ProfilePath)" -Level OK
            }
        } catch {
            Write-Log "  x No se pudo eliminar el perfil $($info.ProfilePath): $($_.Exception.Message)" -Level ERROR
            return New-ActionResult -Success $false -Message ("No se pudo eliminar el perfil: {0}. La cuenta NO se ha borrado." -f $_.Exception.Message)
        }
    }

    try {
        $computer = Get-LocalComputerEntry
        $computer.Delete('user', $Name)
        Write-Log "  + Cuenta '$Name' eliminada" -Level OK
        $extra = if ($RemoveProfile -and $info.HasProfile) { ' (con su perfil)' } elseif ($info.HasProfile) { " (la carpeta $($info.ProfilePath) se conserva)" } else { '' }
        return New-ActionResult -Success $true -Message ("Cuenta '{0}' eliminada{1}" -f $Name, $extra)
    } catch {
        $msg = Get-AdsiErrorText $_
        Write-Log "  x No se pudo eliminar '$Name': $msg" -Level ERROR
        return New-ActionResult -Success $false -Message $msg
    }
}

function New-LocalUserAccount {
    <#
        Crea una cuenta local. -NoPassword la deja sin contrasena; -Administrator la
        mete en el grupo de administradores. Siempre se agrega al grupo Usuarios.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Password = '',
        [string]$FullName = '',
        [string]$Description = '',
        [switch]$NoPassword,
        [switch]$Administrator,
        [switch]$PasswordNeverExpires
    )

    if ($Name -notmatch '^[^\\/\[\]:;|=,+*?<>"@]{1,20}$') {
        return New-ActionResult -Success $false -Message 'Nombre no valido (max. 20 caracteres, sin \ / [ ] : ; | = , + * ? < > " @)'
    }
    if ([ADSI]::Exists("WinNT://$env:COMPUTERNAME/$Name,user")) {
        return New-ActionResult -Success $false -Message "La cuenta '$Name' ya existe"
    }
    if (-not $NoPassword -and $Password.Length -eq 0) {
        return New-ActionResult -Success $false -Message 'Indica una contrasena o marca "sin contrasena"'
    }
    if (Test-ReportOnly) { return New-ActionResult -Success $false -Message 'Modo reporte: sin cambios' }

    $computer = Get-LocalComputerEntry
    try {
        $u = $computer.Create('user', $Name)
        # Con -NoPassword se crea con una contrasena temporal aleatoria (para no
        # chocar con la politica de longitud minima) y despues se limpia.
        $initial = if ($NoPassword) { New-RandomPassword } else { $Password }
        $u.SetPassword($initial)
        if ($FullName)    { $u.InvokeSet('FullName', $FullName) }
        if ($Description) { $u.InvokeSet('Description', $Description) }
        $u.SetInfo()

        if ($PasswordNeverExpires) {
            $flags = [int]$u.InvokeGet('UserFlags')
            $u.InvokeSet('UserFlags', ($flags -bor $script:UF_DONT_EXPIRE_PASSWD))
            $u.SetInfo()
        }
        Write-Log "  + Cuenta '$Name' creada" -Level OK
    } catch {
        $msg = Get-AdsiErrorText $_
        Write-Log "  x No se pudo crear '$Name': $msg" -Level ERROR
        return New-ActionResult -Success $false -Message $msg
    }

    $warnings = @()
    foreach ($gsid in @($script:SidUsers) + $(if ($Administrator) { @($script:SidAdministrators) } else { @() })) {
        try {
            $g = Get-LocalGroupEntry -GroupSid $gsid
            $g.Add("WinNT://$env:COMPUTERNAME/$Name,user")
            Write-Log ("  + '{0}' agregado al grupo {1}" -f $Name, [string]$g.Name) -Level OK
        } catch {
            $m = Get-AdsiErrorText $_
            # "ya es miembro" no es un error real
            if ($m -notmatch '(?i)ya es miembro|already a member') {
                $warnings += "grupo $gsid : $m"
                Write-Log ("  ! No se pudo agregar '{0}' al grupo {1}: {2}" -f $Name, $gsid, $m) -Level WARN
            }
        }
    }

    if ($NoPassword) {
        $r = Clear-LocalUserPassword -Name $Name
        if (-not $r.Success) { $warnings += "sin contrasena: $($r.Message)" }
    }

    $msg = "Cuenta '$Name' creada"
    if ($warnings.Count -gt 0) { $msg += ' con avisos: ' + ($warnings -join '; ') }
    return New-ActionResult -Success $true -Message $msg
}

#endregion

#region ---------- Interno ----------

function New-ActionResult {
    param([bool]$Success, [string]$Message)
    return [pscustomobject]@{ Success = $Success; Message = $Message }
}

function Get-LocalComputerEntry {
    try { return [ADSI]"WinNT://$env:COMPUTERNAME,computer" } catch { return $null }
}

function Get-LocalUserEntry {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $path = "WinNT://$env:COMPUTERNAME/$Name,user"
        if (-not [ADSI]::Exists($path)) { return $null }
        return [ADSI]$path
    } catch { return $null }
}

function Get-LocalGroupEntry {
    <# Resuelve el grupo por SID para no depender del idioma de Windows. #>
    param([Parameter(Mandatory)][string]$GroupSid)
    $nt   = (New-Object Security.Principal.SecurityIdentifier($GroupSid)).Translate([Security.Principal.NTAccount]).Value
    $name = $nt.Split('\')[-1]
    return [ADSI]"WinNT://$env:COMPUTERNAME/$name,group"
}

function Get-LocalGroupMemberSids {
    param([Parameter(Mandatory)][string]$GroupSid)
    $sids = @()
    try {
        $g = Get-LocalGroupEntry -GroupSid $GroupSid
        foreach ($m in @($g.Invoke('Members'))) {
            try {
                $bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
                $sids += (New-Object Security.Principal.SecurityIdentifier(([byte[]]$bytes), 0)).Value
            } catch { }
        }
    } catch {
        Write-Log "  ! No se pudieron leer los miembros del grupo $GroupSid : $($_.Exception.Message)" -Level DEBUG
    }
    return $sids
}

function Test-LocalUserProtected {
    <#
        Devuelve un texto con el motivo si la accion NO debe hacerse, o $null si es segura.
        Protege: cuentas integradas, la cuenta que ejecuta el toolkit y cuentas con sesion abierta.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Action,
        $Info
    )
    if (-not $Info) { $Info = Get-LocalUserInventory | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
    if (-not $Info) { return $null }

    if ($Info.BuiltIn -and $Action -eq 'eliminar') {
        return "'$Name' es una cuenta integrada de Windows y no se puede eliminar"
    }
    if ($Info.IsCurrentUser) {
        return "'$Name' es la cuenta con la que se esta ejecutando el toolkit"
    }
    if ($Info.SessionOpen -and $Action -eq 'eliminar') {
        return "'$Name' tiene una sesion abierta. Cierra su sesion primero"
    }
    return $null
}

function New-RandomPassword {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!$%&*'
    $rng   = New-Object System.Random
    return -join (1..24 | ForEach-Object { $chars[$rng.Next($chars.Length)] })
}

function Get-AdsiErrorText {
    <# Las excepciones COM de ADSI vienen envueltas: se saca el mensaje util. #>
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    $m = $ex.Message
    if (-not $m) { $m = "$ErrorRecord" }
    return $m.Trim()
}

#endregion

Export-ModuleMember -Function @(
    'Get-LocalUserInventory', 'Show-LocalUserInventory',
    'Set-LocalUserPassword', 'Clear-LocalUserPassword',
    'Enable-LocalUserAccount', 'Disable-LocalUserAccount',
    'Remove-LocalUserAccount', 'New-LocalUserAccount'
)
