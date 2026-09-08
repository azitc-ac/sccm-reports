# SCCM Application Status Reports

SSRS reports (RDL) for monitoring required application deployments in Microsoft Configuration Manager (SCCM/MECM), with version-aware compliance evaluation based on Add/Remove Programs inventory data.

## Why these reports?

The built-in ConfigMgr deployment reports trust the client's enforcement state. In practice this can be misleading: a deployment may report success while the actual installation never completed, or an application may be installed in an older version than the one being deployed. These reports instead evaluate compliance primarily against the **Add/Remove Programs (ARP) hardware inventory**, including a proper **numeric version comparison** — an installed version *newer* than the deployed one counts as compliant, an *older* one does not.

## Reports

| File | Purpose |
|---|---|
| `AppStatus_Compliance-Overview.rdl` | Entry page: compliance summary per server role with visual compliance bars. Clicking a role opens the overview filtered to that role. |
| `AppStatus_Overview.rdl` | Clients per server role with per-client app counts, compliance percentage and inventory age. Role filter dropdown. Links to both detail reports. |
| `AppStatus_Detail.rdl` | Per-client status of every deployed application: target vs. installed version, status, install date. |
| `AppStatus_Detail_AllApps.rdl` | Complete ARP inventory (32- and 64-bit) of a single client, sortable. |
| `AppStatus_Veraltet.rdl` | Only outdated applications (installed < deployed version), grouped by application, with affected clients. |
| `AppStatus_Installationsdaten.rdl` | Installation timestamps per managed application. |
| `AppStatus_Overview_AllApps.rdl` | Software inventory grouped by product across a selected role collection. |

Report languages: German (UI labels). SQL and structure are language-neutral.

## Compliance logic

Priority order per application and client:

1. ARP entry present with a version, version equals target → **compliant**
2. ARP entry present with a version, version newer than target → **compliant**
3. ARP entry present with a version, version older than target → **not compliant** (shown as outdated)
4. ARP entry without a version, or no ARP entry, but `InstalledState = 2` and `ComplianceState = 1` → **compliant** (for products that do not register in ARP, e.g. Oracle)
5. `EnforcementState` 3000–3999 (requirements not met) → **not applicable**: excluded from both numerator and denominator
6. A bare `EnforcementState = 1001` without any of the above is **not** treated as proof of installation — the enforcement state can report success even when the installation never completed (e.g. file-based detection methods matching files that were staged before an aborted install)

The version comparison cuts or pads both versions to four numeric segments **from the left**
before comparing them segment by segment (`PARSENAME` counts from the right, so without
this step `26.02` against an installed `25.01.00.0` compares the deployed major version with
the installed revision and the older build counts as newer). Up to four segments compare
numerically; a fifth and beyond are ignored; non-numeric segments compare as `0`.

The status text in the detail report names the enforcement state family when there is
nothing better to say: success reported but not proven (1000–1999), in progress (2000–2999),
requirements not met (3000–3999), unknown (4000–4999), failed (5000–5999), with the code in
brackets.

All reports resolve the ARP entry the same way: the shortest display name that starts with
the application name, highest version first, on the client's `ResourceID` (`MachineID` of
`vAppDeploymentAssetDetails`, not the computer name, so an obsolete duplicate record cannot
double a client).

## Prerequisites / conventions

The SQL queries assume these collection naming conventions (adjust the queries if yours differ):

- **Role collections:** `rol-dev-<RoleName>` — device collections per server role
- **Install collections:** `ins-req-dev-<App - Version>` — target collections of *required* application deployments (`OfferTypeID = 0`)

Application display names are matched against ARP entries using the part before the first `" - "` separator (e.g. deployment name `7-Zip - 24.08` matches ARP entries starting with `7-Zip`).

Hardware inventory must include Add/Remove Programs (default inventory classes `SMS_G_System_ADD_REMOVE_PROGRAMS` and `..._64`).

## Deployment

1. Clone the repository.
2. Edit the variables at the top of `reports/customize.ps1`:
   - `$SqlServer` — SQL Server hosting the site database
   - `$Database` — site database name (`CM_<SiteCode>`)
   - `$SsrsFolder` — SSRS root folder of your ConfigMgr instance (`ConfigMgr_<SiteCode>`)
   - optionally `$ReportFolder` and the two collection prefixes, if your naming differs
3. Run `customize.ps1` (PowerShell 5.1+). Customized copies are written to `reports\customized\`.
4. Run `Test-ReportQueries.ps1 -SqlServer <server> -Database CM_<SiteCode>` — see *Testing*.
5. Run `Publish-Reports.ps1 -ReportServerUrl http://<reporting point>/ReportServer -SsrsFolder ConfigMgr_<SiteCode>`.
   It creates the report folder, uploads every RDL under its display name, and points the
   reports at the shared ConfigMgr data source, so they run with the reporting point's
   credentials like the built-in reports do. Repeatable; existing reports are overwritten.

Uploading by hand via Report Builder or the web portal works too. The reports then have to
carry these display names, because the drillthrough links between them refer to them:

| File | Report name on the server |
|---|---|
| AppStatus_Compliance-Overview.rdl | `Anwendungs-Installationsstatus - Compliance-Übersicht` |
| AppStatus_Overview.rdl | `Anwendungs-Installationsstatus - Übersicht` |
| AppStatus_Detail.rdl | `Anwendungs-Installationsstatus - Details` |
| AppStatus_Detail_AllApps.rdl | `Anwendungs-Installationsstatus - Details (Alle Apps)` |
| AppStatus_Veraltet.rdl | `Anwendungs-Installationsstatus - Veraltete Apps` |
| AppStatus_Installationsdaten.rdl | `Anwendungs-Installationsstatus - Installationsdaten` |
| AppStatus_Overview_AllApps.rdl | `Anwendungs-Installationsstatus - Übersicht (Alle Apps)` |

The default SSRS folder used in the drillthrough paths is `Softwareverteilung - Anwendungsüberwachung` below the ConfigMgr root folder; `customize.ps1` rewrites it when `$ReportFolder` is changed.

## Testing

`Test-ReportQueries.ps1` reads every dataset query out of the RDL files, binds the report
parameters to sample values taken from the site (the first client with a required
deployment, the first role collection), runs them against the site database and prints rows,
seconds and errors per dataset. The columns a query returns are checked against the fields
the RDL expects, so a renamed column shows up here instead of as `#Error` in the rendered
report. Nothing is written. Run it on the site server or anywhere the database can be reached
with Windows authentication:

```powershell
.\Test-ReportQueries.ps1 -SqlServer CM01 -Database CM_P01
.\Test-ReportQueries.ps1 -SqlServer CM01 -Database CM_P01 -ComputerName SRV042 -RoleFilter Fileserver
```

Exit code 1 when any dataset fails.

## Status

2026-09-08: the queries were reworked - left-aligned version comparison, `MachineID` instead of
the computer name, one ARP lookup shared by all reports, enforcement state families - and
the two scripts were added.

`Test-ReportQueries.ps1` was run against the AZI lab site (CM1, `CM_AZI`): all 18 datasets
of the seven reports return without errors, every column the reports expect is there, and
no query takes longer than 0.6 seconds. The outdated-apps report returned no rows on that
site, which is consistent with the overview (every client compliant) but not a proof of the
comparison on real data yet. `Publish-Reports.ps1` uploaded all seven reports to the same site's reporting point. The
first render from the console failed on the reporting point's missing SELECT right on
`vAppDeploymentAssetDetails`, which is why the reports now go through
`fn_rbac_AppDeploymentAssetDetails`; the rendered reports have not been checked since.

## Notes and limitations

- The deployment status comes from `fn_rbac_AppDeploymentAssetDetails(@UserSIDs)`, the same
  RBAC function the built-in deployment reports use, with `UserSIDs` resolved from the
  caller's token through `DataSetAdminID` exactly like those reports. The plain view behind
  it, `vAppDeploymentAssetDetails`, is not readable by the reporting point's account (the
  `smsschm_users` role), so a report on the shared data source fails with "SELECT permission
  was denied" on it. The other views (`v_Collection`, `v_GS_ADD_REMOVE_PROGRAMS`, …) are
  granted to that role and are used directly, so role-based filtering applies to the
  deployments but not to the inventory rows. Restrict access via SSRS folder permissions if
  needed.
- Opened from the ConfigMgr console the token SIDs are passed in; opened from the SSRS web
  portal the reports behave like the built-in ones do there.
- Version comparison handles up to four numeric segments (`major.minor.build.revision`); a fifth and beyond are ignored, non-numeric segments compare as `0`.
- An application name containing `%`, `_` or `[` is matched as a `LIKE` pattern and may match more than intended.
- The embedded WinForms report viewer in the ConfigMgr console does not support cross-report bookmark navigation and cannot set hidden parameters via drillthrough — this is why the role navigation uses a visible filter parameter with a default value.

## License

MIT
