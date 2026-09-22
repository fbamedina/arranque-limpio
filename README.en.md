# Arranque Limpio

[Español](README.md) · **English**

A macOS menu bar app that tells you:

1. **Whether your Mac has finished starting up** and no system service is misbehaving
   (Siri, Time Machine, Spotlight, iCloud, Photos, XProtect, software updates, WindowServer, Dock/Finder…).
2. **Which processes or apps are using an excessive amount of CPU or memory**, with the option to quit them.

> The app's interface is in Spanish. Interface labels are quoted below in Spanish with their English meaning.

## Menu bar icon

It uses the same symbol as the app icon (a power button) with a small badge:

| Badge | Meaning |
|---|---|
| clock | Starting up or finishing startup tasks (indexing, syncing…) |
| ✓ | Startup finished, everything is fine |
| ! | There are warnings (failing services, unexpected quits…) |

The **color** reflects resource usage against the thresholds set in *Ajustes* (Settings): monochrome when
everything is within limits, **orange** when a process exceeds the CPU or memory threshold (or there is
memory pressure), and **red** when it doubles the threshold or memory pressure is critical.

### Right-click: pause / resume

Right-clicking (or ctrl-clicking) the icon opens a menu to **pause monitoring**: the app stays in the
menu bar but stops its timer and frees its history, so it uses no CPU. The icon dims and shows a pause
badge. From the same menu you can **resume**, open the panel, or quit the app. The paused state is
remembered across restarts.

## What it detects

- **Startup phase**: time since boot, overall load, and typical startup services still working.
- **Stuck or unstable services**: restart loops (the process keeps getting a new PID), crashes/hangs,
  and "excessive CPU usage" events that macOS records in `DiagnosticReports`.
- **Frozen Time Machine**: a backup in progress with no progress for more than 15 minutes (`tmutil status`).
- **Excessive usage**: average CPU over the last minute above the threshold, memory above the threshold,
  or memory that keeps growing (possible leak). Helper processes are grouped with their app, as are
  icon-less tools launched by an app from the same vendor (e.g. Claude Code inside Claude).
- **System memory**: memory pressure, swap, and processes killed due to low memory (Jetsam).
- **Other**: kernel panic or stalled shutdown on the previous restart, hung apps, processes blocked on I/O.

The thresholds (80 % CPU = 0.8 cores, and 4 GB of memory by default) can be changed in *Ajustes*
(Settings), where you can also choose the refresh interval (1 s – 1 min, 3 s by default) and enable
notifications and launch at login.

## Warnings: details and dismissing

- **Ver detalles** (Show details) expands extended information for each warning. Diagnostic reports
  are only parsed when you expand them:
  - *Stalled shutdown*: decodes the `spindump` capture and lists the processes that were still running,
    flagging third-party ones as the likely cause (and warning if an external disk was mounted).
  - *Crashes and hangs*: date, exception type and the function where it failed; repeats are grouped (×N).
  - *Low memory (Jetsam)*: which processes macOS killed, why, and which one was using the most memory.
  - *CPU/memory usage*: the app's individual processes, with PID, CPU and memory.
  - *Services*: excessive-CPU or crash reports, restart loops, and their processes right now.
  - Buttons to open the report in Console, view it in full, or reveal it in Finder.
- **✕ (dismiss)** hides that warning. If the problem happens again (a new report appears, or high usage
  comes back after having cleared), the warning is shown again. Dismissed warnings don't affect the icon
  color or trigger notifications; *Mostrar de nuevo* (Show again) restores them.

## Build and install

Requires Xcode or the Command Line Tools (Swift 5.9+), macOS 14 or later.

```bash
./build.sh            # builds build/Arranque Limpio.app
./build.sh --install  # also copies it to /Applications and opens it
```

Terminal diagnostics without opening the interface:

```bash
"/Applications/Arranque Limpio.app/Contents/MacOS/ArranqueLimpio" --report --details
```

No special permissions are needed. It can only quit processes owned by your user; for system processes
it offers to copy the `sudo killall …` command.

## License

Copyright © 2026 Borja Arias.

Distributed under the [PolyForm Noncommercial License 1.0.0](LICENSE):

- **Non-profit use: free.** You may use, modify and share the app for personal use, hobby projects,
  research, education, charities or public institutions.
- **Commercial use: requires prior authorization.** Any for-profit use (selling it, integrating it into a
  product or service, or using it in a company) is not covered by this license and requires a commercial
  license agreement with the author.

To request a commercial license, get in touch via [github.com/fbamedina](https://github.com/fbamedina).
