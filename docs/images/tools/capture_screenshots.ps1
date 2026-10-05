# win_capture.ps1 - ASCII-only window screenshot / click helper (Windows PowerShell 5.1)
param(
  [Parameter(Mandatory=$true)][string]$Action,
  [string]$Path = "F:\30_Novelcraft_Flutter\_shot.png",
  [int]$ProcId = 0,
  [int]$X = 0,
  [int]$Y = 0,
  [int]$W = 0,
  [int]$H = 0,
  [int]$WaitMs = 900,
  [string]$Result = "F:\30_Novelcraft_Flutter\_cap_result.txt"
)

Add-Type -AssemblyName System.Drawing

if (-not ("WinCap32" -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WinCap32 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, IntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
}
'@
}

[void][WinCap32]::SetProcessDPIAware()

function Get-TargetHwnd([int]$id) {
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue
  if ($null -eq $p) { return [IntPtr]::Zero }
  $p.Refresh()
  return $p.MainWindowHandle
}

switch ($Action) {
  "find" {
    $lines = @()
    Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object {
      $lines += ("$($_.ProcessName)|$($_.Id)|$($_.MainWindowTitle)")
    }
    ($lines -join "`r`n") | Out-File $Result -Encoding utf8
  }
  "show" {
    $h = Get-TargetHwnd $ProcId
    if ($h -eq [IntPtr]::Zero) { "NO_WINDOW" | Out-File $Result -Encoding utf8; exit 1 }
    if ($W -gt 0) { [void][WinCap32]::MoveWindow($h, $X, $Y, $W, $H, $true) }
    [void][WinCap32]::ShowWindow($h, 5)
    [void][WinCap32]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds $WaitMs
    $r = New-Object WinCap32+RECT
    [void][WinCap32]::GetWindowRect($h, [ref]$r)
    "SHOW hwnd=$h L=$($r.Left) T=$($r.Top) W=$($r.Right - $r.Left) H=$($r.Bottom - $r.Top)" | Out-File $Result -Encoding utf8
  }
  "shot" {
    $h = Get-TargetHwnd $ProcId
    if ($h -eq [IntPtr]::Zero) { "NO_WINDOW" | Out-File $Result -Encoding utf8; exit 1 }
    if ($W -gt 0) { [void][WinCap32]::MoveWindow($h, $X, $Y, $W, $H, $true) }
    [void][WinCap32]::ShowWindow($h, 5)
    [void][WinCap32]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds $WaitMs
    $r = New-Object WinCap32+RECT
    [void][WinCap32]::GetWindowRect($h, [ref]$r)
    $w = $r.Right - $r.Left
    $ht = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $ht))
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    "OK L=$($r.Left) T=$($r.Top) W=$w H=$ht PATH=$Path" | Out-File $Result -Encoding utf8
  }
  "pwshot" {
    $h = Get-TargetHwnd $ProcId
    if ($h -eq [IntPtr]::Zero) { "NO_WINDOW" | Out-File $Result -Encoding utf8; exit 1 }
    if ($W -gt 0) { [void][WinCap32]::MoveWindow($h, $X, $Y, $W, $H, $true) }
    [void][WinCap32]::ShowWindow($h, 5)
    [void][WinCap32]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds $WaitMs
    $r = New-Object WinCap32+RECT
    [void][WinCap32]::GetWindowRect($h, [ref]$r)
    $w = $r.Right - $r.Left
    $ht = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [WinCap32]::PrintWindow($h, $hdc, 2)
    $g.ReleaseHdc($hdc)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    "PW ok=$ok L=$($r.Left) T=$($r.Top) W=$w H=$ht PATH=$Path" | Out-File $Result -Encoding utf8
  }
  "scroll" {
    [void][WinCap32]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 200
    $delta = [int]($W * 120)
    $dw = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$delta), 0)
    [WinCap32]::mouse_event(0x0800, 0, 0, $dw, [IntPtr]::Zero)
    Start-Sleep -Milliseconds $WaitMs
    "SCROLL notch=$W at $X,$Y" | Out-File $Result -Encoding utf8
  }
  "click" {
    [void][WinCap32]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 150
    [WinCap32]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 70
    [WinCap32]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds $WaitMs
    "CLICK $X,$Y" | Out-File $Result -Encoding utf8
  }
  default {
    "UNKNOWN_ACTION" | Out-File $Result -Encoding utf8
  }
}
