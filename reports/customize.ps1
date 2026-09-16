# ============================================================
# Customize SCCM Application Status Reports for your environment
#
# Replaces the generic placeholders in all RDL files with your
# actual server, database and SSRS folder names.
#
# Run on a machine that knows the site - the site server, or a workstation
# with the console installed - and it asks the site for the names itself:
#
#   .\customize.ps1
#
# Anything you pass wins over what is detected, and on a machine that
# cannot reach the site you pass all three:
#
#   .\customize.ps1 -SqlServer CM01 -Database CM_P01 -SsrsFolder ConfigMgr_P01
#
# Passing them is the safer way round: this file is under version control
# and the reports it writes to .\customized\ are not, so a server name
# typed in here is one commit away from being published, while the same
# name passed on the command line never leaves the machine. Detection keeps
# it out of both.
#
# Requires: PowerShell 5.1 or later
# ============================================================

[CmdletBinding()]
param(
    # SQL Server hosting the CM database (e.g. CM01 or SQL01\INST1).
    # Detected from the site when not given.
    [string]$SqlServer,

    # ConfigMgr site database (CM_<SiteCode>). Detected when not given.
    [string]$Database,

    # SSRS root folder of your ConfigMgr instance. Detected when not given.
    [string]$SsrsFolder,

    # Report server the data source URLs point at. Detected when not given,
    # and falls back to $SqlServer.
    [string]$ReportServer,

    # SSRS folder below $SsrsFolder that holds these reports (drillthrough paths)
    [string]$ReportFolder = 'Softwareverteilung - Anwendungsüberwachung',

    # target collections of required application deployments
    [string]$RequiredCollectionPrefix = 'ins-req-dev-',

    # device collections per server role
    [string]$RoleCollectionPrefix = 'rol-dev-',

    # SMS provider to ask, when the automatic search does not find one
    [string]$SmsProvider,

    # Do not ask the site. Missing names stay as the generic placeholders,
    # which is what you want when preparing files for another environment.
    [switch]$NoDetect
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Whatever was not passed, ask the site for it.
# ------------------------------------------------------------
$missing = @()
if (-not $SqlServer)    { $missing += 'SqlServer' }
if (-not $Database)     { $missing += 'Database' }
if (-not $SsrsFolder)   { $missing += 'SsrsFolder' }
if (-not $ReportServer) { $missing += 'ReportServer' }

if ($missing.Count -gt 0 -and -not $NoDetect) {
    $detector = Join-Path $PSScriptRoot 'Get-ReportEnvironment.ps1'
    if (Test-Path -LiteralPath $detector) {
        Write-Host ("Asking the site for: {0}" -f ($missing -join ', ')) -ForegroundColor Cyan
        try {
            . $detector
            $site = Get-ReportEnvironment -SmsProvider $SmsProvider
            if (-not $SqlServer)    { $SqlServer    = $site.SqlServer }
            if (-not $Database)     { $Database     = $site.Database }
            if (-not $SsrsFolder)   { $SsrsFolder   = $site.SsrsFolder }
            if (-not $ReportServer) { $ReportServer = $site.ReportServer }
        }
        catch {
            Write-Warning ("The site could not be asked: {0}" -f $_.Exception.Message)
        }
    }
    else {
        Write-Warning "Get-ReportEnvironment.ps1 is not next to this script, so nothing can be detected."
    }
}

# Still empty means neither passed nor detected. The placeholders stay
# recognisable on purpose: a report carrying YOURSQLSERVER fails loudly,
# one carrying a plausible but wrong name fails a fortnight later.
if (-not $SqlServer)    { $SqlServer  = 'YOURSQLSERVER';   Write-Warning "SQL Server unknown - '$SqlServer' stays in the files." }
if (-not $Database)     { $Database   = 'CM_ABC';          Write-Warning "Site database unknown - '$Database' stays in the files." }
if (-not $SsrsFolder)   { $SsrsFolder = 'ConfigMgr_ABC';   Write-Warning "SSRS folder unknown - '$SsrsFolder' stays in the files." }
if (-not $ReportServer) { $ReportServer = $SqlServer }

Write-Host ''
Write-Host ("SQL Server    {0}" -f $SqlServer)    -ForegroundColor White
Write-Host ("Database      {0}" -f $Database)     -ForegroundColor White
Write-Host ("Report server {0}" -f $ReportServer) -ForegroundColor White
Write-Host ("SSRS folder   {0}" -f $SsrsFolder)   -ForegroundColor White
Write-Host ''

$sourceDir = $PSScriptRoot
$targetDir = Join-Path $PSScriptRoot 'customized'

if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir | Out-Null
}

$replacements = @(
    @('Data Source=CMSERVER;Initial Catalog=CM_P01', "Data Source=$SqlServer;Initial Catalog=$Database"),
    @('http://CMSERVER/ReportServer', "http://$ReportServer/ReportServer"),
    @('/ConfigMgr_P01/', "/$SsrsFolder/"),
    @('CMSERVER', $SqlServer),
    @('CM_P01', $Database),
    @('ConfigMgr_P01', $SsrsFolder),
    @('Softwareverteilung - Anwendungsüberwachung', $ReportFolder),
    @('ins-req-dev-', $RequiredCollectionPrefix),
    @('rol-dev-', $RoleCollectionPrefix)
)

$rdlFiles = Get-ChildItem -Path $sourceDir -Filter '*.rdl'

foreach ($file in $rdlFiles) {
    $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

    foreach ($pair in $replacements) {
        $content = $content.Replace($pair[0], $pair[1])
    }

    $targetPath = Join-Path $targetDir $file.Name
    # Write with UTF-8 BOM (required for umlauts in Report Builder)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($targetPath, $content, $utf8Bom)

    Write-Host "Customized: $($file.Name)"
}

Write-Host ""
Write-Host "Done. Deploy the files from '$targetDir' with .\Publish-Reports.ps1, or via Report Builder / the SSRS web portal."
