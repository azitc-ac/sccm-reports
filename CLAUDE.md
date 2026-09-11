# Working notes for this repository

SSRS reports for ConfigMgr application deployment compliance. What the reports do, how they
are deployed and what was verified when is in `README.md` - read it first, its *Status*
section is the handover log and every session that changes something on the site appends
an entry there with the date and what was actually measured, not what was assumed.

## Environment

- **This repository is public.** No domain names, account names or client names in code,
  docs or commit messages; the lab server is referred to as `CM1`, its site as `AZI`, as the
  README already does.
- Lab site: CM1, site code AZI, database `CM_AZI`, reporting point and SSRS on the same box
  (`http://cm1/ReportServer`, portal `http://cm1/Reports`).
- Sessions run on CM1 itself, usually elevated, under an account that is **not** a ConfigMgr
  administrator (`RBAC_Admins` does not know it), so RBAC functions return nothing for its
  own token - test them with a real admin id (see README, 2026-09-10).
- Reporting point source folder: `D:\Program Files\SMS_SRSRP\Reports` (512 RDL).
  Component log: `D:\Program Files\Microsoft Configuration Manager\Logs\srsrp.log`.
  Registry: `HKLM:\SOFTWARE\Microsoft\SMS\SRSRP`.
- Counting reports on the server: SSRS REST API,
  `Invoke-RestMethod 'http://cm1/Reports/api/v2.0/Reports?$top=2000' -UseDefaultCredentials -AllowUnencryptedAuthentication`
  (`New-WebServiceProxy` does not work under PowerShell 7). Expected: 512 built-in + 7 ours.

## Rules of the road

- Edit the RDL under `reports/`, never under `reports/customized/` - that folder is generated
  by `customize.ps1` and ignored by git.
- Before publishing: `Test-ReportQueries.ps1`, then `Publish-Reports.ps1`. Render at least one
  report afterwards; a green test run is not a rendered report.
- Never delete anything on the reporting point. Our folder `Softwareverteilung -
  Anwendungsüberwachung` is the German name of the built-in folder `Software Distribution -
  Application Monitoring`; the built-in one lost its 21 reports once (README, 2026-09-11).
- Commit messages in the style of the existing history: what changed and what was measured.

## Backlog

- **Rename our report folder** so it no longer collides with the built-in
  `Software Distribution - Application Monitoring` (ours is its German translation; in the
  portal both show up next to each other). `customize.ps1` rewrites the drillthrough paths via
  `$ReportFolder`, so the change is: new default in `customize.ps1` and the RDL, new name in
  the README table, republish, remove the old folder on the server by hand. Noted 2026-09-11.
- **Prove the version comparison** with a client that really holds an older version than the
  deployed one; the outdated-apps report has only ever returned zero rows (README, 2026-09-10).
