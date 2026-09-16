<#
.SYNOPSIS
    Finds the SQL Server, the site database and the SSRS folders of this
    ConfigMgr environment, so the other scripts need no typed-in names.

.DESCRIPTION
    Dot-source this file and call Get-ReportEnvironment. It answers with one
    object carrying SiteCode, SqlServer, Database, ReportServerUrl, SsrsFolder
    and, for each of them, where the value came from - because a wrong value
    that is silently guessed is worse than one that says it was guessed.

    The chain, each step falling back to the next:

        provider    the console's connection history (HKCU ConfigMgr10\AdminUI\MRU),
                    the site server's own identity when this is the site server
                    (HKLM SMS\Identification), the local SMS_ProviderLocation
        site code   from SMS_ProviderLocation on that provider
        SQL         the site server's registry, HKLM\SOFTWARE\Microsoft\SMS\SQL Server,
                    values "Server" and "Database Name"; a named instance is
                    stored there as "INSTANCE\CM_ABC" and is split apart again
        SSRS        SMS_SRSServerInformation in root\SMS\site_<SiteCode> for the
                    report server and its URL; the ConfigMgr root folder is
                    ConfigMgr_<SiteCode> by convention and is confirmed against
                    the report server itself when it can be reached

    Nothing is written anywhere and no ConfigMgr object is touched. Every step
    is in its own try/catch: a site that answers three of five questions still
    gets three answers and says so for the rest.

    Windows PowerShell 5.1. Run it as a user who may read the site - the same
    rights the console needs.

.PARAMETER SmsProvider
    Skip the search and ask this machine. A name that does not answer is
    reported with the reason instead of being silently dropped.

.EXAMPLE
    . .\Get-ReportEnvironment.ps1
    Get-ReportEnvironment | Format-List

.EXAMPLE
    . .\Get-ReportEnvironment.ps1
    $env = Get-ReportEnvironment -SmsProvider cm01.contoso.example
#>

#region ------------------------------------------------------------- helpers

function Test-ReportLocalComputer {
    param([string]$ComputerName)

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return $true }
    $short = ($ComputerName -split '\.')[0]
    return ($short -ieq $env:COMPUTERNAME)
}

<#
    Where this machine knows an SMS Provider from, in the order worth trying.
    Taken from the AZITC Toolkit, where it was measured against a real console:
    the connection history is what an admin workstation has, the identity key
    is what the site server has, SMS_ProviderLocation covers the rest.
#>
function Get-ReportProviderCandidate {
    [CmdletBinding()]
    param()

    $list = New-Object System.Collections.Generic.List[object]
    $add = {
        param($name, $source)
        if ($name -and -not ($list | Where-Object { $_.Name -ieq $name })) {
            $list.Add([pscustomobject]@{ Name = [string]$name; Source = $source })
        }
    }

    try {
        foreach ($key in (Get-ChildItem -Path 'HKCU:\SOFTWARE\Microsoft\ConfigMgr10\AdminUI\MRU' -ErrorAction Stop | Sort-Object PSChildName)) {
            $value = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($value -and $value.ServerName) { & $add $value.ServerName 'the console connection history of this user' }
        }
    }
    catch { }

    try {
        $identification = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -ErrorAction Stop
        if ($identification.'Site Server') { & $add $identification.'Site Server' 'this machine is the site server' }
    }
    catch { }

    try {
        $location = Get-CimInstance -Namespace 'root\SMS' -ClassName 'SMS_ProviderLocation' -ErrorAction Stop |
                        Where-Object { $_.ProviderForLocalSite } | Select-Object -First 1
        if ($location -and $location.Machine) { & $add $location.Machine 'SMS_ProviderLocation on this machine' }
    }
    catch { }

    return $list.ToArray()
}

<#
    Site code and provider machine, asked of one candidate. Throws with a
    reason a person can act on.
#>
function Get-ReportProviderInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    $parameters = @{ Namespace = 'root\SMS'; ClassName = 'SMS_ProviderLocation'; ErrorAction = 'Stop' }
    if (-not (Test-ReportLocalComputer -ComputerName $ComputerName)) { $parameters['ComputerName'] = $ComputerName }

    $locations = @(Get-CimInstance @parameters)
    if ($locations.Count -eq 0) { throw "No SMS provider found on [$ComputerName]." }

    $provider = $locations | Where-Object { $_.ProviderForLocalSite } | Select-Object -First 1
    if (-not $provider) { $provider = $locations[0] }

    return [pscustomobject]@{
        SiteCode        = [string]$provider.SiteCode
        ProviderMachine = [string]$provider.Machine
    }
}

<#
    SQL Server and database of the site, out of the site server's registry.

    The same read the SCCMAppHelper setup assistant does, and it has been run
    against two different sites. Falls back to the provider machine and
    CM_<SiteCode>, which is what a default installation uses.
#>
function Get-ReportSqlInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][string]$SiteCode
    )

    $server   = $null
    $database = $null
    $source   = "the registry of $ComputerName"

    try {
        if (Test-ReportLocalComputer -ComputerName $ComputerName) {
            $key = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server' -ErrorAction Stop
            $server   = $key.Server
            $database = $key.'Database Name'
        }
        else {
            $hive = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $ComputerName)
            try {
                $subKey = $hive.OpenSubKey('SOFTWARE\Microsoft\SMS\SQL Server')
                if ($subKey) {
                    $server   = $subKey.GetValue('Server')
                    $database = $subKey.GetValue('Database Name')
                    $subKey.Close()
                }
            }
            finally { $hive.Close() }
        }
    }
    catch {
        $source = "guessed - the registry of $ComputerName could not be read ($($_.Exception.Message))"
    }

    if ([string]::IsNullOrWhiteSpace($server))   { $server = $ComputerName;      $source = "guessed from the provider name" }
    if ([string]::IsNullOrWhiteSpace($database)) { $database = "CM_$SiteCode";   $source = "guessed from the site code" }

    # A named instance is stored as "INSTANCE\CM_ABC".
    if ($database -match '\\') {
        $parts = $database -split '\\', 2
        if ($server -notmatch '\\') { $server = "$server\$($parts[0])" }
        $database = $parts[1]
    }

    return [pscustomobject]@{ SqlServer = [string]$server; Database = [string]$database; Source = $source }
}

<#
    One property of a WMI instance, by whichever of the given names it carries.

    The reporting point classes are not identical across ConfigMgr versions and
    the property that holds the URL has been called more than one thing. Asking
    for a name that is not there answers $null, which reads exactly like an
    empty value - so the names are tried in turn and the first one that exists
    wins. Returns $null when none of them do.
#>
function Get-ReportWmiValue {
    param(
        [Parameter(Mandatory = $true)]$Instance,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if (-not $Instance) { return $null }
    $available = @($Instance.PSObject.Properties.Name)
    foreach ($name in $Names) {
        if ($available -contains $name) {
            $value = $Instance.$name
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
        }
    }
    return $null
}

<#
    The reporting point and the ConfigMgr root folder on it.

    The folder is ConfigMgr_<SiteCode> - that is how the reporting point names
    it when it installs, not a guess about this site. Where the report server
    answers, the name is confirmed by listing the root folder, which also
    catches the case of several ConfigMgr folders on one report server.
#>
function Get-ReportServerInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProviderMachine,
        [Parameter(Mandatory = $true)][string]$SiteCode
    )

    $server    = $null
    $url       = $null
    $folder    = "ConfigMgr_$SiteCode"
    $srcServer = ''
    $srcFolder = 'the site code - that is how a reporting point names its folder'

    # --- what the site says about its reporting point ---
    try {
        $parameters = @{ Namespace = "root\SMS\site_$SiteCode"; ClassName = 'SMS_SRSServerInformation'; ErrorAction = 'Stop' }
        if (-not (Test-ReportLocalComputer -ComputerName $ProviderMachine)) { $parameters['ComputerName'] = $ProviderMachine }

        $srs = @(Get-CimInstance @parameters) | Select-Object -First 1
        if ($srs) {
            $server = Get-ReportWmiValue -Instance $srs -Names 'ServerName', 'NetworkOSPath', 'SiteSystem'
            $url    = Get-ReportWmiValue -Instance $srs -Names 'ReportServerUri', 'ReportServerUrl', 'ReportManagerUri'
            $named  = Get-ReportWmiValue -Instance $srs -Names 'RootFolder', 'ReportServerRootFolder'
            if ($named) { $folder = $named; $srcFolder = 'SMS_SRSServerInformation' }
            if ($server -or $url) { $srcServer = 'SMS_SRSServerInformation' }
        }
    }
    catch {
        $srcServer = "SMS_SRSServerInformation could not be read ($($_.Exception.Message))"
    }

    # A site system path arrives as \\SERVER\, which is not a host name.
    if ($server) { $server = $server.Trim('\') }

    if (-not $server -and $url) {
        try { $server = ([uri]$url).Host } catch { }
    }
    if (-not $server) {
        $server = $ProviderMachine
        $srcServer = 'guessed - the SMS provider, which is the reporting point on a single-server site'
    }

    # ReportManagerUri points at the portal (/Reports); the SOAP endpoint the
    # publisher needs lives under /ReportServer.
    if ($url -and $url -match '/Reports/?$') { $url = $null }
    if (-not $url) { $url = "http://$server/ReportServer" }
    $url = $url.TrimEnd('/')

    # --- confirm the folder on the report server itself ---
    try {
        $proxy = New-WebServiceProxy -Uri ($url + '/ReportService2010.asmx') -UseDefaultCredential -ErrorAction Stop
        $roots = @($proxy.ListChildren('/', $false) | Where-Object { $_.TypeName -eq 'Folder' })
        $match = $roots | Where-Object { $_.Name -ieq "ConfigMgr_$SiteCode" } | Select-Object -First 1
        if (-not $match) { $match = $roots | Where-Object { $_.Name -like 'ConfigMgr_*' } | Select-Object -First 1 }
        if ($match) {
            $folder = $match.Name
            $srcFolder = "confirmed on $url"
        }
        else {
            $srcFolder += " - no ConfigMgr_* folder is on $url yet"
        }
    }
    catch {
        $srcFolder += " - $url could not be asked ($($_.Exception.Message))"
    }

    return [pscustomobject]@{
        ReportServer    = [string]$server
        ReportServerUrl = [string]$url
        SsrsFolder      = [string]$folder
        ServerSource    = $srcServer
        FolderSource    = $srcFolder
    }
}

#endregion

#region --------------------------------------------------------------- the lot

function Get-ReportEnvironment {
    [CmdletBinding()]
    param(
        [string]$SmsProvider,
        [switch]$Quiet
    )

    $say = { param($text, $colour) if (-not $Quiet) { Write-Host $text -ForegroundColor $colour } }

    # --- the provider ---
    $candidates = @()
    if ($SmsProvider) { $candidates = @([pscustomobject]@{ Name = $SmsProvider; Source = 'given on the command line' }) }
    else              { $candidates = @(Get-ReportProviderCandidate) }

    if ($candidates.Count -eq 0) {
        throw ('No SMS provider could be found from this machine. It knows one through the console connection history, ' +
               'through its own site server identity, or through SMS_ProviderLocation, and none of the three answered. ' +
               'Name one with -SmsProvider.')
    }

    $provider = $null
    $failures = @()
    foreach ($candidate in $candidates) {
        try {
            $info = Get-ReportProviderInfo -ComputerName $candidate.Name
            $provider = [pscustomobject]@{
                Machine  = $info.ProviderMachine
                SiteCode = $info.SiteCode
                Asked    = $candidate.Name
                Source   = $candidate.Source
            }
            break
        }
        catch { $failures += ('{0}: {1}' -f $candidate.Name, $_.Exception.Message) }
    }

    if (-not $provider) {
        throw ("No SMS provider answered. Tried:`n  " + ($failures -join "`n  "))
    }

    & $say ("Site {0} through {1} ({2})" -f $provider.SiteCode, $provider.Machine, $provider.Source) 'Gray'

    # --- SQL and SSRS ---
    $sql = Get-ReportSqlInfo    -ComputerName $provider.Machine -SiteCode $provider.SiteCode
    $srs = Get-ReportServerInfo -ProviderMachine $provider.Machine -SiteCode $provider.SiteCode

    $result = [pscustomobject]@{
        SiteCode        = $provider.SiteCode
        SmsProvider     = $provider.Machine
        SqlServer       = $sql.SqlServer
        Database        = $sql.Database
        ReportServer    = $srs.ReportServer
        ReportServerUrl = $srs.ReportServerUrl
        SsrsFolder      = $srs.SsrsFolder
        Sources         = [ordered]@{
            Provider   = $provider.Source
            Sql        = $sql.Source
            SsrsServer = $srs.ServerSource
            SsrsFolder = $srs.FolderSource
        }
    }

    if (-not $Quiet) {
        & $say '' 'Gray'
        & $say ("  SQL Server       {0}" -f $result.SqlServer) 'White'
        & $say ("  Database         {0}" -f $result.Database) 'White'
        & $say ("  Report server    {0}" -f $result.ReportServerUrl) 'White'
        & $say ("  SSRS folder      {0}" -f $result.SsrsFolder) 'White'
        & $say '' 'Gray'
        foreach ($key in $result.Sources.Keys) {
            if ($result.Sources[$key]) { & $say ("  {0,-11} {1}" -f $key, $result.Sources[$key]) 'DarkGray' }
        }
        $guessed = @($result.Sources.Values | Where-Object { $_ -like 'guessed*' })
        if ($guessed.Count -gt 0) {
            & $say '' 'Gray'
            & $say '  Something above was guessed rather than read. Check it, and pass the value if it is wrong.' 'Yellow'
        }
    }

    return $result
}

#endregion

# Run on its own, print what this environment looks like.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s') {
    $null = Get-ReportEnvironment
}
