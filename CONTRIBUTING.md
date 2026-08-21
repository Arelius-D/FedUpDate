# Contributing to FedUpDate

Thanks for taking an interest. Issues, questions, and pull requests are welcome.

---

## Licensing of contributions

**Read this first — this project is not under a conventional open-source licence.**

FedUpDate is released under the
[PolyForm Noncommercial License 1.0.0](LICENSE). Anyone may use, modify, and
share it for any noncommercial purpose. Commercial use is not permitted.

By submitting a pull request or patch, you agree that:

- your contribution is licensed under the same PolyForm Noncommercial License 1.0.0, and
- you grant the project owner (Arelius-D) a perpetual, worldwide, irrevocable
  right to use, modify, relicense, and sublicense your contribution, including
  under commercial terms, and
- the contribution is your own work and you have the right to submit it.

If you are not comfortable with those terms, please open an issue to discuss
rather than sending code.

---

## Building

The CLI and TUI are pure PowerShell and need no build step at all. Only the
desktop GUI is compiled.

```powershell
gui\SetupLibs.ps1      # fetch WebView2 from nuget.org into gui\bin
gui\bin\build.ps1      # compile gui\src\Program.cs -> gui\bin\FedUpDate.UI.exe
```

No Visual Studio, .NET SDK, or NuGet client is required. `build.ps1` discovers
whichever C# compiler is present, including the `csc.exe` that ships with the
.NET Framework on every Windows 10/11 machine.

---

## Before opening a pull request

Both audits must pass with exit code 0. They are the project's gate:

```powershell
audit\audit-syntax.ps1   # every .ps1 / .psm1 must parse cleanly
audit\audit-css.ps1      # 24-law design system verification
```

If an audit is wrong or too narrow, **fix the audit** in the same pull request
rather than working around it. An audit that passes for the wrong reason is
worse than one that fails.

Also:

- Update `CHANGELOG.md` under the current version, following
  [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
- Rebuild `FedUpDate.UI.exe` if you changed `gui/src/Program.cs`.
- Keep changes focused. One concern per pull request.

---

## Design system rules

`gui/styles.css` is governed by the 24 laws enforced in `audit/audit-css.ps1`.
The ones contributors hit most often:

- No `!important`.
- No raw `px` — use `rem` and the existing spacing tokens.
- No hex, `rgb()`, `hsl()` — colours are OKLCH tokens defined on `:root` and the
  theme selectors, referenced via `var(--sys-*)`.
- Every colour token defined for the dark theme needs a light-theme counterpart.
- Every class used in `index.html` needs a matching rule in `styles.css`.
- Inline SVGs use `currentColor`, never hardcoded fills.

---

## Reporting bugs

Open an issue with:

- your Windows version and build (`winver`),
- whether you were running elevated,
- the relevant portion of `data/logs/fedupdate.log`,
- what you expected and what happened instead.

Nearly every operation supports `-WhatIf`. Reproducing with that
flag first is the safest way to describe a problem without changing your system.

For anything security-sensitive, follow [SECURITY.md](SECURITY.md) instead of
opening a public issue.
