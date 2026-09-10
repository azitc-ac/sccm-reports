<#
.SYNOPSIS
    Uploads the RDL files to the reporting point and wires them to the
    ConfigMgr data source.

.DESCRIPTION
    Talks to the SSRS SOAP endpoint (ReportService2010), which every
    reporting point offers, from SSRS 2016 to Power BI Report Server:

        1. creates the report folder below the ConfigMgr root folder
        2. uploads every RDL under the display name the drillthrough links
           between the reports expect (see the table in the README)
        3. points the report's data source at the shared ConfigMgr data
           source, so it runs with the reporting point's own credentials -
           the same way the built-in reports do

    Repeatable: an existing report is overwritten, an existing folder kept.

.PARAMETER ReportServerUrl
    The web service URL of the reporting point, e.g. http://CM01/ReportServer.
    Not the portal URL (/Reports).

.PARAMETER SsrsFolder
    The ConfigMgr root folder on the report server, ConfigMgr_<SiteCode>.

.PARAMETER ReportFolder
    The folder below it that holds these reports. Must match what
    customize.ps1 wrote into the drillthrough paths.

.PARAMETER Path
    Folder with the RDL files. Default: .\customized.

.PARAMETER EmbeddedDataSource
    Leave the data source embedded in the RDL (Windows integrated security of
    whoever views the report) instead of switching to the shared one.

.EXAMPLE
    .\Publish-Reports.ps1 -ReportServerUrl http://CM01/ReportServer -SsrsFolder ConfigMgr_P01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReportServerUrl,
    [Parameter(Mandatory = $true)][string]$SsrsFolder,
    [string]$ReportFolder = 'Softwareverteilung - Anwendungsüberwachung',
    [string]$Path,
    [string]$SharedDataSourceName = '{5C6358F2-4BB6-4a1b-A16E-8D96795D8602}',
    [switch]$EmbeddedDataSource
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is still empty while the param block is being bound, so the
# default cannot be written there - Join-Path then refuses the empty string
# and the script dies before its first line runs.
if (-not $Path) { $Path = Join-Path $PSScriptRoot 'customized' }

# The display names the drillthrough links between the reports refer to.
$displayNames = @{
    'AppStatus_Compliance-Overview.rdl' = 'Anwendungs-Installationsstatus - Compliance-Übersicht'
    'AppStatus_Overview.rdl'            = 'Anwendungs-Installationsstatus - Übersicht'
    'AppStatus_Detail.rdl'              = 'Anwendungs-Installationsstatus - Details'
    'AppStatus_Detail_AllApps.rdl'      = 'Anwendungs-Installationsstatus - Details (Alle Apps)'
    'AppStatus_Veraltet.rdl'            = 'Anwendungs-Installationsstatus - Veraltete Apps'
    'AppStatus_Installationsdaten.rdl'  = 'Anwendungs-Installationsstatus - Installationsdaten'
    'AppStatus_Overview_AllApps.rdl'    = 'Anwendungs-Installationsstatus - Übersicht (Alle Apps)'
}

if (-not (Test-Path -LiteralPath $Path)) { throw "No RDL folder at [$Path] - run customize.ps1 first, or pass -Path." }

$serviceUrl = $ReportServerUrl.TrimEnd('/') + '/ReportService2010.asmx'
Write-Host "Connecting to $serviceUrl" -ForegroundColor Cyan
$proxy = New-WebServiceProxy -Uri $serviceUrl -UseDefaultCredential -Namespace 'SSRS'

$rootPath   = '/' + $SsrsFolder.Trim('/')
$folderPath = $rootPath + '/' + $ReportFolder
$dataSourcePath = $rootPath + '/' + $SharedDataSourceName

# --- the folder ---
$existing = $proxy.ListChildren($rootPath, $false) | Where-Object { $_.TypeName -eq 'Folder' -and $_.Name -eq $ReportFolder }
if ($existing) {
    Write-Host "Folder exists: $folderPath" -ForegroundColor Gray
}
else {
    $null = $proxy.CreateFolder($ReportFolder, $rootPath, $null)
    Write-Host "Folder created: $folderPath" -ForegroundColor Green
}

# --- the shared data source ---
$sharedDataSource = $null
if (-not $EmbeddedDataSource) {
    $sharedDataSource = $proxy.ListChildren($rootPath, $false) | Where-Object { $_.TypeName -eq 'DataSource' -and $_.Name -eq $SharedDataSourceName }
    if (-not $sharedDataSource) {
        Write-Warning "Shared data source [$dataSourcePath] not found - the reports keep their embedded data source."
    }
}

# --- the reports ---
$namespace = $proxy.GetType().Namespace
foreach ($file in (Get-ChildItem -LiteralPath $Path -Filter '*.rdl' | Sort-Object Name)) {
    $name = $displayNames[$file.Name]
    if (-not $name) { $name = $file.BaseName; Write-Warning "No display name known for $($file.Name) - using the file name." }

    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $warnings = $null
    $item = $proxy.CreateCatalogItem('Report', $name, $folderPath, $true, $bytes, $null, [ref]$warnings)
    Write-Host ("Uploaded: {0}" -f $name) -ForegroundColor Green
    # The data source warning is expected - it is rewired right below - and
    # an entry without a code is the empty placeholder the service returns.
    foreach ($warning in @($warnings)) {
        if (-not $warning -or [string]::IsNullOrWhiteSpace($warning.Code)) { continue }
        if ($warning.Code -eq 'rsDataSourceReferenceNotPublished') { continue }
        Write-Host ("    {0}: {1}" -f $warning.Code, $warning.Message) -ForegroundColor Yellow
    }

    if ($sharedDataSource) {
        $current = @($proxy.GetItemDataSources($item.Path))
        $updated = @()
        foreach ($dataSource in $current) {
            $reference = New-Object ($namespace + '.DataSourceReference')
            $reference.Reference = $sharedDataSource.Path
            $replacement = New-Object ($namespace + '.DataSource')
            $replacement.Name = $dataSource.Name
            $replacement.Item = $reference
            $updated += $replacement
        }
        if ($updated.Count -gt 0) {
            $proxy.SetItemDataSources($item.Path, $updated)
            Write-Host ("    data source -> {0}" -f $sharedDataSource.Path) -ForegroundColor Gray
        }
    }
}

Write-Host ""
Write-Host ("Done. The reports are in {0}" -f $folderPath) -ForegroundColor Cyan
