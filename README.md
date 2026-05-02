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
2. Sends `Shift+F9` (re-run last config — works for both run and debug).
3. Waits for IntelliJ to write a new test-results XML.
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

The keyboard shortcut sent to IntelliJ is configurable. Default is `Shift+F9` (IntelliJ's stock "Re-run Debug").

**Claude remembers your shortcut in its project memory** (file `idea-debug-prefs.md` next to your other memory files). On the first invocation in a project Claude will ask you which shortcut you use and save it. Subsequent runs use it silently. To change it later, just tell Claude (e.g. "switch my idea-debug shortcut to Ctrl+F9").

**One-off override** without changing memory: pass `-KeyDebug` to the script, e.g.

```powershell
powershell -ExecutionPolicy Bypass -File "...\Debug-And-Capture.ps1" -KeyDebug "+%{F10}"
```

**SendKeys notation:** `+` = Shift, `%` = Alt, `^` = Ctrl. So `Shift+Alt+F10` → `+%{F10}`, `Ctrl+F9` → `^{F9}`.

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

### 2. Process detection: watch testHistory XML, not `java.exe` spawns

Naively, you'd watch for new `java.exe` processes via WMI to detect a test run. But IntelliJ reuses an existing JVM as a test-runner daemon — no new process spawns when you re-run tests. The WMI watcher would never fire.

**Fix:** snapshot existing `*.xml` files in `%LOCALAPPDATA%\JetBrains\IntelliJIdea*\testHistory\*\*.xml` before sending Shift+F9, then poll for any new or modified XML.

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
| `[chaser] no new test results XML appeared within 120s` | Shift+F9 didn't reach IntelliJ (modal dialog, not ready), or tests took longer than 120s. |
| `=== LOG FILE: not found ===` followed by HINT | Run config is missing one or both of "Save console output to file" / `-Dlogging.file.name`. |
| `[FAIL] foo (?)` with no stderr | Test never actually ran — usually a Spring/JUnit bootstrap failure. Check the LOG FILE section for the root cause (e.g. Testcontainer dependency unavailable). |

## Contributing

PRs welcome. The four design notes above are load-bearing — if you change them, please test from a Claude Code subprocess, not just a manual PowerShell prompt (the failure modes are subtle and only show in the subprocess context).

## License

[The Unlicense](LICENSE) — public domain. Use it anywhere, for anything, no attribution required.

## Credits

Built and documented by Vladyslav Dubov. Big thanks to Claude (Anthropic) for pair-programming the Windows quirks down to the bottom.
