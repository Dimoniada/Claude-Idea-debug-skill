# idea-debug

A [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) skill that triggers an IntelliJ IDEA test/debug run from your Claude conversation, captures the console log and JUnit results, and pipes them back to Claude for analysis.

**Platform:** Windows only (uses Win32 API + PowerShell + `wscript.exe`).

## What it does

You're in Claude Code, you've been editing Java code in IntelliJ. You type:

```
/idea-debug
```

Behind the scenes, the skill:

1. Brings IntelliJ to the foreground.
2. Sends `Debug` shortcut (default is Shift+F9, re-run last config — works for both run and debug).
3. Waits for the test-runner JVM to exit (no timeout, with a 10s heartbeat for long suites).
4. Reads the console log file (`debug-capture.log`) IntelliJ wrote during the run.
5. Parses the JUnit XML and prints `[PASS]` / `[FAIL]` per test with stderr.
6. Minimizes IntelliJ so Claude Code surfaces again — without disturbing your Alt+Tab order.

Claude then summarizes pass/fail and suggests fixes based on the captured stack traces.

## Why this exists

Triggering IntelliJ from a Claude Code subprocess on Windows runs into several non-obvious quirks (cross-process focus stealing, JVM daemon reuse, key injection from a non-interactive shell, taskbar focus blocks). This skill works around all of them. See [DESIGN-NOTES.md](#design-notes-the-four-windows-quirks-this-skill-works-around) below for the technical details.

## Installation

1. Find your Claude Code skills directory (varies by install — search for an existing `skills/` folder near your Claude Code data directory).
2. Copy this repo's contents into a folder named `idea-debug` inside that directory:
   ```
   <skills-dir>/idea-debug/
   ├── SKILL.md
   └── scripts/
       ├── Debug-And-Capture.ps1
       ├── Chase-DebugProcess.ps1
       └── WinApi.ps1
   ```
3. Restart Claude Code so it picks up the new skill.
4. In IntelliJ, open your project's Run/Debug Configuration and add (one-time setup):
   - **Logs tab → "Save console output to file"**: `<your-project-folder>\debug-capture.log`
   - **VM options** (for Spring Boot): `-Dlogging.file.name=<your-project-folder>\debug-capture.log`

   The skill will print a HINT pointing you here if it can't find the log after a run.

## Configuration

### Shortcut

Default IntelliJ shortcut: `Shift+F9` (IntelliJ's stock "Re-run Debug").

**Per-conversation prompt:** the first time you invoke `/idea-debug` in a Claude conversation, Claude asks which shortcut to use. The answer is remembered for the rest of that conversation, then forgotten. Each new conversation asks again — useful if you debug different things with different shortcuts.

**One-off override** when invoking the script directly:

```powershell
powershell -ExecutionPolicy Bypass -File "...\Debug-And-Capture.ps1" -KeyDebug "+%{F10}"
```

**SendKeys notation:** `+` = Shift, `%` = Alt, `^` = Ctrl. So `Shift+Alt+F10` → `+%{F10}`, `Ctrl+F9` → `^{F9}`.

### Detection window (`-DetectionWindowSec`, default 30)

After sending the keystroke, the chaser waits up to N seconds for IntelliJ to spawn the test-runner JVM (a `java.exe` whose command-line includes `idea_rt.jar`). Once detected, it waits for that JVM to exit — **with no timeout** — so long-running suites are fine. A heartbeat line is printed every 10 seconds while the test is running.

If your IntelliJ takes longer than 30s to even start the JVM (cold-start projects, slow disk, large classpath), raise the window:

```powershell
powershell -ExecutionPolicy Bypass -File "...\Debug-And-Capture.ps1" -DetectionWindowSec 60
```

If the chaser fails with `no IntelliJ test runner detected within Ns`, that means the keystroke didn't actually launch a run (a modal dialog ate it, or no run config is selected, or focus was wrong). Try invoking the run manually in IntelliJ first.

## Usage

In a Claude Code session opened at your project folder:

```
/idea-debug
```

Whatever Run/Debug config was last used in IntelliJ will be re-triggered. Make sure the right config is "current" before invoking — IntelliJ remembers the most recently launched one.

## Design notes (the four Windows quirks this skill works around)

If you're tempted to "simplify" the code, please read this first.

### 1. Key injection: `wscript.exe`, not `keybd_event` or `WScript.Shell.SendKeys`

When PowerShell runs as a subprocess of Claude Code, it doesn't have interactive desktop access. `keybd_event` calls succeed but the synthesized keystrokes never reach IntelliJ. Same for COM-based `WScript.Shell.SendKeys` from in-process.

**Fix:** write a 2-line `.vbs` to `$env:TEMP` and invoke it via `wscript.exe`. `wscript.exe` runs at the top of the process tree, which gives it interactive access.

### 2. Process detection: filter `java.exe` by classpath AND exclude IntelliJ infrastructure

IntelliJ does spawn a fresh `java.exe` per test/run with `idea_rt.jar` in its classpath. So in principle you can watch for that. The catch: IntelliJ's own daemons — JPS BuildMain (`jps-launcher.jar`), Maven server, Kotlin daemon, JpsBootstrap — also include `idea_rt.jar` in their classpath, AND they're long-living. Naive detection picks up the build daemon and hangs forever waiting for it to exit.

**Fix:** filter `java.exe` whose cmdline matches `idea_rt.jar` AND does NOT match `BuildMain|jps-launcher|RemoteMavenServer|kotlin\.daemon|MavenServerCmdReader|JpsBootstrap`. Wait for that process to exit (no timeout, heartbeat every 10s). Snapshot existing testHistory XMLs as a fallback for sub-second tests where the JVM exits between polls.

**Bonus design rule:** use a sentinel-file handshake between parent and chaser. PowerShell startup can take 2–5 seconds; a fixed `Sleep 600ms` before the keystroke is unreliable. The chaser writes a ready file after snapshotting baselines; the parent waits for that file before firing the keystroke.

### 3. Temp files: `$env:TEMP`, not `$PSScriptRoot`

`Start-Process -RedirectStandardOutput "$PSScriptRoot\..."` works from an interactive shell but fails silently when invoked from Claude Code's subprocess — the skill directory is not reliably writable in that context.

**Fix:** all transient files (chaser stdout/stderr capture, the VBS) live in `$env:TEMP`.

### 4. Returning focus: minimize IntelliJ, don't try to bring Claude Code forward

`SetForegroundWindow(claudeHwnd)` and `WshShell.AppActivate(claudePid)` from a deep subprocess just flash the taskbar icon — Windows blocks cross-process focus stealing. `Alt+Tab` approach works but burns the user's MRU slot, breaking expected Alt+Tab behavior between IntelliJ and Claude Code.

**Fix:** call `ShowWindow(intelliJHwnd, SW_MINIMIZE)`. Cross-process minimize is unrestricted, and the next window in the Z-order (Claude Code) surfaces naturally without disturbing Alt+Tab.

## Failure modes

| Symptom | Cause |
|---|---|
| `IntelliJ IDEA not found` | IntelliJ minimized to system tray, hidden, or not running. |
| `[chaser] no IntelliJ test runner detected within 30s` | Shift+F9 didn't reach IntelliJ (modal dialog, not ready), or no run config selected. Increase with `-DetectionWindowSec`. Long-running tests are *not* a cause — once the JVM starts, the chaser waits with no timeout. |
| `=== LOG FILE: not found ===` followed by HINT | Run config is missing one or both of "Save console output to file" / `-Dlogging.file.name`. |
| `[FAIL] foo (?)` with no stderr | Test never actually ran — usually a Spring/JUnit bootstrap failure. Check the LOG FILE section for the root cause (e.g. Testcontainer dependency unavailable). |

## Contributing

PRs welcome. The four design notes above are load-bearing — if you change them, please test from a Claude Code subprocess, not just a manual PowerShell prompt (the failure modes are subtle and only show in the subprocess context).

## License

[The Unlicense](LICENSE) — public domain. Use it anywhere, for anything, no attribution required.

## Credits

Built and documented by Vladyslav Dubov. Big thanks to Claude (Anthropic) for pair-programming the Windows quirks down to the bottom.
