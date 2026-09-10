# ============================================================
# Customize SCCM Application Status Reports for your environment
#
# Replaces the generic placeholders in all RDL files with your
# actual server, database and SSRS folder names.
#
# Usage:
#   .\customize.ps1 -SqlServer CM01 -Database CM_P01 -SsrsFolder ConfigMgr_P01
#
#   or edit the defaults below and run .\customize.ps1 on its own, then
#   deploy the files from .\customized\ via Report Builder or
#   Publish-Reports.ps1.
#
# Passing them is the safer way round: this file is under version control
# and the reports it writes to .\customized\ are not, so a server name
# typed in here is one commit away from being published, while the same
# name passed on the command line never leaves the machine.
#
# Requires: PowerShell 5.1 or later
# ============================================================

[CmdletBinding()]
param(
    # SQL Server hosting the CM database (e.g. CM01 or SQL01\INST1)
    [string]$SqlServer = 'YOURSQLSERVER',

    # ConfigMgr site database (CM_<SiteCode>)
    [string]$Database = 'CM_ABC',

    # SSRS root folder of your ConfigMgr instance
    [string]$SsrsFolder = 'ConfigMgr_ABC',

    # SSRS folder below $SsrsFolder that holds these reports (drillthrough paths)
    [string]$ReportFolder = 'Softwareverteilung - Anwendungsüberwachung',

    # target collections of required application deployments
    [string]$RequiredCollectionPrefix = 'ins-req-dev-',

    # device collections per server role
    [string]$RoleCollectionPrefix = 'rol-dev-'
)

$ErrorActionPreference = 'Stop'

$sourceDir = $PSScriptRoot
$targetDir = Join-Path $PSScriptRoot 'customized'

if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir | Out-Null
}

$replacements = @(
    @('Data Source=CMSERVER;Initial Catalog=CM_P01', "Data Source=$SqlServer;Initial Catalog=$Database"),
    @('http://CMSERVER/ReportServer', "http://$SqlServer/ReportServer"),
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
