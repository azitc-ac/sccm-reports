# ============================================================
# Customize SCCM Application Status Reports for your environment
#
# Replaces the generic placeholders in all RDL files with your
# actual server, database and SSRS folder names.
#
# Usage:
#   1. Adjust the three variables below
#   2. Run:  .\customize.ps1
#   3. Deploy the files from .\customized\ via Report Builder
#
# Requires: PowerShell 5.1 or later
# ============================================================

$ErrorActionPreference = 'Stop'

# --- Adjust these three values for your environment -----------
$SqlServer   = 'YOURSQLSERVER'        # SQL Server hosting the CM database (e.g. CM01 or SQL01\INST1)
$Database    = 'CM_ABC'               # ConfigMgr site database (CM_<SiteCode>)
$SsrsFolder  = 'ConfigMgr_ABC'        # SSRS root folder of your ConfigMgr instance

# Optional - only change these if your naming differs from the defaults:
$ReportFolder             = 'Softwareverteilung - Anwendungsüberwachung'  # SSRS folder below $SsrsFolder that holds these reports (drillthrough paths)
$RequiredCollectionPrefix = 'ins-req-dev-'   # target collections of required application deployments
$RoleCollectionPrefix     = 'rol-dev-'       # device collections per server role
# --------------------------------------------------------------

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
