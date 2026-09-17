<#
.SYNOPSIS
    Updates this folder to the current state of the repository, then customizes and publishes
    the reports.

.DESCRIPTION
    "git pull" for a machine without git. Downloads the branch from GitHub as a zip (the
    repository is public, no credential needed), replaces the repository files in this folder,
    then runs the deploy steps of the README:

        reports\customize.ps1          site names into the RDL files -> reports\customized\
        reports\Test-ReportQueries.ps1 only with -Test: every dataset query against the site database
        reports\Publish-Reports.ps1    the customized RDL files onto the report server

    Run it on a machine that knows the site (site server, or a workstation with the console),
    as a user who may read the site and write to the report server's ConfigMgr folder. Without
    parameters the three scripts find SQL Server, database, report server and SSRS folder
    themselves. reports\customized\ (generated, carries your server names) and files that are
    not in the repository are left alone.

.PARAMETER NoDeploy
    Only replace the files; run customize / publish yourself.

.PARAMETER Test
    Run Test-ReportQueries.ps1 between customize and publish.

.PARAMETER SmsProvider
    Handed to the three scripts. Optional - they find the provider from the console's
    connection history or the local site installation.

.PARAMETER ReportFolder
    The SSRS folder below the ConfigMgr root folder; handed to customize and publish.

.EXAMPLE
    .\update.ps1
    Update, customize, publish.

.EXAMPLE
    .\update.ps1 -WhatIf
    Lists what would be replaced.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$NoDeploy,
    [switch]$Test,
    [string]$SmsProvider = '',
    [string]$ReportFolder = '',
    [string]$Branch = 'main',
    [string]$Token
)
$Deploy = -not $NoDeploy

$ErrorActionPreference = 'Stop'

# Started with "Run with PowerShell" or a double-click, the window closes with
# the last line of output - too fast to read what happened. Then the script
# waits for Enter at the end, also after an error. Started from an open shell
# it does not; the parent process tells the two apart.
$keepWindow = $false
try {
    $me = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
    $parent = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($me.ParentProcessId)" -ErrorAction Stop
    $keepWindow = ([string]$parent.Name -notin 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'WindowsTerminal.exe', 'powershell_ise.exe', 'Code.exe', 'conhost.exe')
} catch { }
$failed = $false
try {
$repoOwner = 'azitc-ac'
$repoName  = 'sccm-reports'
$keep      = @('reports\customized\')   # generated on this machine, never replaced

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }

# --- download ---------------------------------------------------------------------------------

Write-Step "Downloading $repoOwner/$repoName ($Branch)"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'sccm-reports-update' }
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('sccm-reports-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $temp -Force -WhatIf:$false
$zip = Join-Path $temp 'repo.zip'
try {
    Invoke-WebRequest -Uri "https://api.github.com/repos/$repoOwner/$repoName/zipball/$Branch" -Headers $headers -OutFile $zip -UseBasicParsing -ErrorAction Stop
} catch {
    $status = ''; try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    switch ($status) {
        401     { throw 'GitHub asked for authentication - is the repository private? Then pass -Token.' }
        403     { throw 'GitHub refused the request (403): 60 unauthenticated calls per hour - wait, or pass -Token.' }
        404     { throw "Neither the repository nor the branch [$Branch] was found." }
        default { throw ('Download failed: {0}' -f $_.Exception.Message) }
    }
}
Write-Ok ('Downloaded: {0:N1} MB' -f ((Get-Item -LiteralPath $zip).Length / 1MB))

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $temp)
$archiveRoot = Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1
if (-not $archiveRoot) { throw 'The downloaded archive holds no folder.' }
$source = $archiveRoot.FullName
if (-not (Test-Path -LiteralPath (Join-Path $source 'reports\Publish-Reports.ps1'))) { throw 'The archive does not look like the sccm-reports repository (no reports\Publish-Reports.ps1).' }
$commit = ''; if ($archiveRoot.Name -match '-(?<sha>[0-9a-f]{7,40})$') { $commit = $Matches['sha'].Substring(0, 7) }

# --- replace ----------------------------------------------------------------------------------

Write-Step "Updating $root"
$copied = 0; $skipped = 0
$prefix = $source.TrimEnd('\') + '\'
foreach ($file in (Get-ChildItem -LiteralPath $source -Recurse -File)) {
    $relative = $file.FullName.Substring($prefix.Length)
    $protected = $false
    foreach ($k in $keep) { if ($relative.StartsWith($k, [StringComparison]::OrdinalIgnoreCase)) { $protected = $true } }
    if ($protected) { $skipped++; continue }
    $target = Join-Path $root $relative
    if ($PSCmdlet.ShouldProcess($relative, 'replace')) {
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    $copied++
}
Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
Write-Ok ('{0} file(s) updated{1}{2}' -f $copied, $(if ($commit) { " ($commit)" } else { '' }), $(if ($skipped) { ", $skipped left alone" } else { '' }))

# --- deploy -----------------------------------------------------------------------------------

if ($Deploy -and -not $WhatIfPreference) {
    $reports = Join-Path $root 'reports'
    $common = @{}
    if ($SmsProvider) { $common['SmsProvider'] = $SmsProvider }
    $folderArg = @{}
    if ($ReportFolder) { $folderArg['ReportFolder'] = $ReportFolder }

    Write-Step 'Customizing the reports (site names into the RDL files)'
    & (Join-Path $reports 'customize.ps1') @common @folderArg

    if ($Test) {
        Write-Step 'Testing the dataset queries against the site database'
        & (Join-Path $reports 'Test-ReportQueries.ps1') @common
    }

    Write-Step 'Publishing the reports'
    & (Join-Path $reports 'Publish-Reports.ps1') @common @folderArg
}
elseif (-not $WhatIfPreference) {
    Write-Info 'Next: .\reports\customize.ps1, .\reports\Test-ReportQueries.ps1, .\reports\Publish-Reports.ps1 - or run update.ps1 without -NoDeploy.'
}
}
catch {
    $failed = $true
    Write-Host ''
    Write-Host ("FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { Write-Host ("    at line {0}" -f $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray }
}
finally {
    if ($keepWindow) { Write-Host ''; $null = Read-Host 'Press Enter to close' }
}
if ($failed) { exit 1 }
