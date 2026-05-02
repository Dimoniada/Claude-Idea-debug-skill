if (-not ([System.Management.Automation.PSTypeName]'WinApiShared').Type) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WinApiShared {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);

    public static List<IntPtr> FindByClass(string className) {
        var result = new List<IntPtr>();
        EnumWindows((h, lp) => {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            if (sb.ToString() == className) result.Add(h);
            return true;
        }, IntPtr.Zero);
        return result;
    }

    // AttachThreadInput merges our input queue with the target's, which lifts the
    // foreground-stealing restriction long enough for SetForegroundWindow to take.
    // This works to bring IntelliJ forward from a subprocess; it does NOT reliably
    // work for bringing arbitrary windows (e.g. Claude Code) forward from deeper
    // subprocesses — see Chase-DebugProcess.ps1 for the minimize-IntelliJ workaround.
    public static void BringToForeground(IntPtr hwnd) {
        int pid;
        uint targetThread = GetWindowThreadProcessId(hwnd, out pid);
        uint currentThread = GetCurrentThreadId();
        ShowWindow(hwnd, 9); // SW_RESTORE
        AttachThreadInput(currentThread, targetThread, true);
        SetForegroundWindow(hwnd);
        AttachThreadInput(currentThread, targetThread, false);
    }
}
"@
}

function Invoke-BringToForeground([IntPtr]$hwnd) {
    [WinApiShared]::BringToForeground($hwnd)
    Start-Sleep -Milliseconds 300
}
