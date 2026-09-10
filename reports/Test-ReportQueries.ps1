<#
.SYNOPSIS
    Runs every dataset query of the RDL files against the site database.

.DESCRIPTION
    Reads the queries straight out of the RDL files, binds the report
    parameters to sample values taken from the site, executes them and
    reports rows, duration and errors per dataset. The columns a query
    returns are checked against the fields the RDL expects, so a renamed
    column shows up here and not as "#Error" in the rendered report.

    Nothing is written. Run it on the site server, or anywhere the site
    database can be reached with Windows authentication.

.PARAMETER SqlServer
    SQL Server hosting the site database, e.g. CM01 or SQL01\INST1.

.PARAMETER Database
    Site database, CM_<SiteCode>.

.PARAMETER Path
    Folder holding the RDL files. Default: .\customized if it exists, else
    the folder of this script - so the generic files can be tested too, the
    placeholders only matter for the drillthrough paths, not for the queries.

.PARAMETER ComputerName
    Client for the per-client reports. Default: the first client that has a
    required application deployment.

.EXAMPLE
    .\Test-ReportQueries.ps1 -SqlServer CM01 -Database CM_P01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SqlServer,
    [Parameter(Mandatory = $true)][string]$Database,
    [string]$Path,
    [string]$ComputerName,
    [string]$RoleFilter = 'Alle',
    [string]$CollectionID,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    $Path = Join-Path $PSScriptRoot 'customized'
    if (-not (Test-Path -LiteralPath $Path)) { $Path = $PSScriptRoot }
}

$connectionString = "Data Source=$SqlServer;Initial Catalog=$Database;Integrated Security=SSPI;Application Name=sccm-reports test"
$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
$connection.Open()
Write-Host "Connected to $SqlServer / $Database" -ForegroundColor Cyan

function Invoke-Scalar {
    param([string]$Sql)
    $command = $connection.CreateCommand()
    $command.CommandText = $Sql
    $command.CommandTimeout = $TimeoutSeconds
    return $command.ExecuteScalar()
}

# Sample values for the parameters, from the site itself.
if (-not $ComputerName) {
    $ComputerName = [string](Invoke-Scalar "SELECT TOP 1 ads.MachineName FROM vAppDeploymentAssetDetails ads INNER JOIN v_ApplicationAssignment aa ON aa.AssignmentID = ads.AssignmentID AND aa.OfferTypeID = 0 ORDER BY ads.MachineName")
    if (-not $ComputerName) { $ComputerName = [string](Invoke-Scalar "SELECT TOP 1 Name0 FROM v_R_System WHERE Client0 = 1 ORDER BY Name0") }
}
if (-not $CollectionID) {
    $CollectionID = [string](Invoke-Scalar "SELECT TOP 1 CollectionID FROM v_Collection WHERE Name LIKE 'rol-%' ORDER BY Name")
    if (-not $CollectionID) { $CollectionID = 'SMS00001' }
}
Write-Host ("Sample values: ComputerName = [{0}], RoleFilter = [{1}], CollectionID = [{2}]" -f $ComputerName, $RoleFilter, $CollectionID) -ForegroundColor Gray

# The RBAC functions want the admin ids behind the caller's token, which the
# console passes as UserTokenSIDs - here they are derived from the current
# Windows identity, the user's SID and the SIDs of its groups.
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$tokenSids = (@($identity.User.Value) + @($identity.Groups | ForEach-Object { $_.Value })) -join ','
$userSids  = [string](Invoke-Scalar ("SELECT dbo.fn_rbac_GetAdminIDsfromUserSIDs('{0}')" -f $tokenSids.Replace("'", "''")))
Write-Host ("RBAC admin ids for {0}: [{1}]" -f $identity.Name, $userSids) -ForegroundColor Gray
if (-not $userSids) { Write-Warning "No ConfigMgr administrative user matches $($identity.Name) - the RBAC functions will return nothing." }

$sampleValues = @{
    '@ComputerName'  = $ComputerName
    '@RolleFilter'   = $RoleFilter
    '@CollID'        = $CollectionID
    '@UserTokenSIDs' = $tokenSids
    '@UserSIDs'      = $userSids
}

$namespace = @{ r = 'http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition' }
$results = @()

foreach ($file in (Get-ChildItem -LiteralPath $Path -Filter '*.rdl' | Sort-Object Name)) {
    [xml]$rdl = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $manager = New-Object System.Xml.XmlNamespaceManager $rdl.NameTable
    $manager.AddNamespace('r', $namespace.r)

    foreach ($dataset in $rdl.SelectNodes('/r:Report/r:DataSets/r:DataSet', $manager)) {
        $name  = $dataset.GetAttribute('Name')
        $query = $dataset.SelectSingleNode('r:Query/r:CommandText', $manager).InnerText
        $expectedFields = @($dataset.SelectNodes('r:Fields/r:Field', $manager) | ForEach-Object {
            $dataField = $_.SelectSingleNode('r:DataField', $manager)
            if ($dataField) { $dataField.InnerText }
        })
        $queryParameters = @($dataset.SelectNodes('r:Query/r:QueryParameters/r:QueryParameter', $manager) | ForEach-Object { $_.GetAttribute('Name') })

        $command = $connection.CreateCommand()
        $command.CommandText = $query
        $command.CommandTimeout = $TimeoutSeconds
        foreach ($parameter in $queryParameters) {
            $value = $(if ($sampleValues.ContainsKey($parameter)) { $sampleValues[$parameter] } else { '' })
            $null = $command.Parameters.AddWithValue($parameter, $value)
        }

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $rows = 0
        $columns = @()
        $queryError = ''
        try {
            $reader = $command.ExecuteReader()
            try {
                for ($i = 0; $i -lt $reader.FieldCount; $i++) { $columns += $reader.GetName($i) }
                while ($reader.Read()) { $rows++ }
            }
            finally { $reader.Close() }
        }
        catch {
            $queryError = $_.Exception.Message
            # A function called with the wrong number of arguments: say what
            # it actually takes, so the fix is a lookup and not a guess.
            if ($queryError -match 'arguments were supplied for the procedure or function (\w+)') {
                $function = $Matches[1]
                try {
                    $signature = New-Object System.Collections.ArrayList
                    $lookup = $connection.CreateCommand()
                    $lookup.CommandText = "SELECT p.name, t.name AS type FROM sys.parameters p JOIN sys.types t ON t.user_type_id = p.user_type_id WHERE p.object_id = OBJECT_ID('dbo.$function') ORDER BY p.parameter_id"
                    $signatureReader = $lookup.ExecuteReader()
                    try { while ($signatureReader.Read()) { $null = $signature.Add(('{0} {1}' -f $signatureReader.GetString(0), $signatureReader.GetString(1))) } }
                    finally { $signatureReader.Close() }
                    $queryError += (' - {0} takes: {1}' -f $function, ($signature -join ', '))
                }
                catch { }
            }
        }
        $watch.Stop()

        $missing = @($expectedFields | Where-Object { $_ -and $_ -notin $columns })

        $status = if ($queryError) { 'ERROR' } elseif ($missing.Count -gt 0) { 'FIELDS' } else { 'ok' }
        $results += [pscustomobject]@{
            Report   = $file.BaseName
            DataSet  = $name
            Status   = $status
            Rows     = $rows
            Seconds  = [math]::Round($watch.Elapsed.TotalSeconds, 1)
            Problem  = $(if ($queryError) { $queryError } elseif ($missing.Count -gt 0) { 'missing columns: ' + ($missing -join ', ') } else { '' })
        }

        $colour = switch ($status) { 'ok' { 'Green' } 'FIELDS' { 'Yellow' } default { 'Red' } }
        Write-Host ("  {0,-6} {1,-34} {2,-18} {3,6} rows {4,6} s  {5}" -f $status, $file.BaseName, $name, $rows, $watch.Elapsed.TotalSeconds.ToString('0.0'), $results[-1].Problem) -ForegroundColor $colour
    }
}

$connection.Close()

$failed = @($results | Where-Object { $_.Status -ne 'ok' }).Count
Write-Host ""
Write-Host ("{0} dataset(s), {1} with problems" -f $results.Count, $failed) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
$results | Format-Table -AutoSize
exit $(if ($failed) { 1 } else { 0 })
