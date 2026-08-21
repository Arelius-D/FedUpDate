# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately through GitHub:

1. Go to the [Security tab](https://github.com/Arelius-D/FedUpDate/security) of this repository.
2. Choose **Report a vulnerability**.

That opens a private advisory visible only to the maintainer. Please include:

- what the issue allows an attacker to do,
- the steps to reproduce it,
- the Windows version and build, and whether the session was elevated,
- the affected version or commit.

You will get an initial response as quickly as is practical. This is a
single-maintainer project, so please allow reasonable time before disclosing
publicly.

---

## What this tool does to your system

FedUpDate is not a passive utility. Understanding its blast radius is part of
using it safely, and part of judging whether something is a genuine
vulnerability.

With the Anti-Tamper Watchdog enabled, it:

- writes Windows Update Group Policy values under
  `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`,
- changes the start type of Windows update services (`wuauserv`, `DoSvc`,
  `UsoSvc`),
- disables selected scheduled tasks under `\Microsoft\Windows\UpdateOrchestrator\`
  and `\Microsoft\Windows\WindowsUpdate\`,
- registers a scheduled task, `FedUpDate-Watchdog-Enforcer`, which runs at
  startup under the SYSTEM account to reapply those settings.

These actions require administrator rights and are exactly what the tool is for:
taking update timing away from Windows and giving it to you.

**Every one of those changes is recorded** in `data/state_ledger.json` with the
original value, so it can be reverted:

```powershell
fedupdate rollback -Latest      # revert the most recent change set
fedupdate watchdog audit         # show current state and any policy drift
install.ps1 -Uninstall           # uninstall, with an option to restore defaults
```

Every operation supports `-WhatIf`, which reports what would change
without touching the system.

---

## In scope

- Privilege escalation beyond what an operation legitimately requires.
- Any path where a non-administrator can cause administrator-level changes.
- Command or argument injection through configuration values, package names, or
  update metadata.
- Weaknesses in the local GUI HTTP bridge (`gui/Server.ps1`, bound to
  `localhost`) that allow access from outside the local machine, or by another
  user on it.
- Tampering with the installation directory that leads to code execution,
  including via the SYSTEM-level scheduled task.
- Failures in the rollback ledger that leave the system unrecoverable, or that
  restore incorrect values.

## Out of scope

- The documented behaviour above: disabling update services and writing update
  policy is the tool's stated purpose, not a vulnerability.
- Needing administrator rights to change machine-wide settings.
- Antivirus or SmartScreen warnings about locally compiled or unsigned binaries.
- Vulnerabilities in Windows, WinGet, the Microsoft Store, or the WebView2
  runtime. Report those to Microsoft.

---

## Distribution and trust

This project distributes **source only**. There is no packaged installer and no
prebuilt binary.

- Installation fetches a plain PowerShell script you can read before running it.
- The desktop GUI is compiled **on your machine** at install time from the C#
  source in this repository.
- The only third-party binaries involved are Microsoft's WebView2 libraries,
  downloaded directly from Microsoft's package CDN at build time. They are never
  redistributed here.

Anything claiming to be a prebuilt FedUpDate installer or executable did not come
from this project.

---

## Supported versions

FedUpDate is pre-1.0. Only the latest released version receives security fixes.
