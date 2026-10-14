<#
  winless-launch.ps1 — 真正无控制台的进程启动器

  为什么要这个：用 WMI(Win32_Process.Create) 或 `start` 启动控制台程序时，
  进程拿不到 SW_HIDE 标记；Windows 11 默认终端是 Windows Terminal，
  它不理会隐藏标记，于是每启动一个就在任务栏多一个命令行窗口。
  这里直接用 CreateProcess + CREATE_NO_WINDOW，进程根本不分配控制台，
  Windows Terminal 也就没有东西可以显示；同时尝试脱离 Codex 的进程组，
  避免某个会话结束时把桌宠一起带走。

  用法：. winless-launch.ps1; Start-HiddenProcess -CommandLine '"pwsh.exe" -File "x.ps1"'
#>

if (-not ('HiddenLauncher' -as [type])) {
  $launcherCode = @'
using System;
using System.Runtime.InteropServices;

public static class HiddenLauncher {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string applicationName, string commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment,
        string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
    const int STARTF_USESHOWWINDOW = 0x00000001;
    const short SW_HIDE = 0;

    public static int Start(string commandLine, string workingDirectory) {
        STARTUPINFO info = new STARTUPINFO();
        info.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        info.dwFlags = STARTF_USESHOWWINDOW;
        info.wShowWindow = SW_HIDE;

        PROCESS_INFORMATION process;
        uint flags = CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB;
        bool ok = CreateProcess(null, commandLine, IntPtr.Zero, IntPtr.Zero, false, flags,
            IntPtr.Zero, workingDirectory, ref info, out process);
        if (!ok) {
            flags = CREATE_NO_WINDOW;
            ok = CreateProcess(null, commandLine, IntPtr.Zero, IntPtr.Zero, false, flags,
                IntPtr.Zero, workingDirectory, ref info, out process);
        }
        if (!ok) return -1;
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return process.dwProcessId;
    }
}
'@
  Add-Type -TypeDefinition $launcherCode -Language CSharp
}

function Start-HiddenProcess {
  param(
    [Parameter(Mandatory = $true)][string]$CommandLine,
    [string]$WorkingDirectory
  )
  if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }
  return [HiddenLauncher]::Start($CommandLine, $WorkingDirectory)
}
