@echo off & chcp 936 >nul & set "FARGS=%*" & set "FSELF=%~f0" & powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:FSELF,[Text.Encoding]::UTF8); iex $s.Substring($s.IndexOf('#PS'+'-START'))" & exit /b
#PS-START
# 风扇控制 - 单文件版 (ROG Zephyrus M16 GU603HM)
# 用法: 双击=进入工具(默认二档,按1一档/按2二档);  风扇控制.cmd restore = 手动恢复默认
$ErrorActionPreference = 'Stop'
$argv = @("$env:FARGS" -split '\s+' | Where-Object { $_ })
$mode = if ($argv.Count -gt 0) { $argv[0] } else { 'run' }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process cmd.exe -Verb RunAs -ArgumentList '/c', ('""{0}" {1}"' -f $env:FSELF, $env:FARGS)
    exit
}

$RangeCpu = 0x00110022; $RangeGpu = 0x00110023; $RpmCpu = 0x00110013; $RpmGpu = 0x00110014
$Dir = Join-Path $env:LOCALAPPDATA 'FanMax'
$Backup = Join-Path $Dir 'range_backup.json'
$Defaults = @{ cpu = 200; gpu = 225 }   # 本机实测出厂值

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Atk {
  [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
  static extern IntPtr CreateFile(string f,uint a,uint s,IntPtr sec,uint d,uint fl,IntPtr t);
  [DllImport("kernel32.dll",SetLastError=true)]
  static extern bool DeviceIoControl(IntPtr h,uint c,byte[] i,uint il,byte[] o,uint ol,out uint r,IntPtr ov);
  [DllImport("kernel32.dll")]
  static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);
  public delegate bool HandlerRoutine(uint ctrlType);
  static IntPtr H = IntPtr.Zero;
  static HandlerRoutine keep;
  public static uint RestoreCpu = 200, RestoreGpu = 225;
  public static bool Armed = false;
  public static string BackupPath = null;
  public static void Open() {
    H = CreateFile(@"\\.\ATKACPI", 0xC0000000, 3, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
    if (H == new IntPtr(-1)) throw new Exception("无法打开 ATKACPI, Win32=" + Marshal.GetLastWin32Error());
  }
  static byte[] Call(uint method, byte[] p) {
    byte[] i = new byte[8 + p.Length];
    BitConverter.GetBytes(method).CopyTo(i, 0);
    BitConverter.GetBytes((uint)p.Length).CopyTo(i, 4);
    p.CopyTo(i, 8);
    byte[] o = new byte[16]; uint r;
    if (!DeviceIoControl(H, 0x0022240C, i, (uint)i.Length, o, 16, out r, IntPtr.Zero))
      throw new Exception("ioctl 失败 Win32=" + Marshal.GetLastWin32Error());
    return o;
  }
  public static uint Dsts(uint id) {
    byte[] p = new byte[8]; BitConverter.GetBytes(id).CopyTo(p, 0);
    return BitConverter.ToUInt32(Call(0x53545344, p), 0);
  }
  public static uint Devs(uint id, uint v) {
    byte[] p = new byte[8];
    BitConverter.GetBytes(id).CopyTo(p, 0); BitConverter.GetBytes(v).CopyTo(p, 4);
    return BitConverter.ToUInt32(Call(0x53564544, p), 0);
  }
  public static void RestoreNow() {
    try { Devs(0x00110022, RestoreCpu); Devs(0x00110023, RestoreGpu); } catch { return; }
    try { if (BackupPath != null && System.IO.File.Exists(BackupPath)) System.IO.File.Delete(BackupPath); } catch { }
  }
  // 点叉关窗口 / 注销 / 关机 时自动恢复
  public static void ArmCloseHandler() {
    keep = delegate(uint t) { if (Armed) { RestoreNow(); Armed = false; } return false; };
    SetConsoleCtrlHandler(keep, true);
  }
}
"@

function Get-Rpm([uint32]$id) { ([Atk]::Dsts($id) -band 0xFFFF) * 100 }
function Get-Range([uint32]$id) { [Atk]::Dsts($id) -band 0xFFFF }

function Save-Backup {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    if (Test-Path $Backup) { return }   # 上次异常退出时备份还在，不覆盖
    $c = Get-Range $RangeCpu; $g = Get-Range $RangeGpu
    if ($c -lt 100 -or $c -gt 254 -or $g -lt 100 -or $g -gt 254) { $c = $Defaults.cpu; $g = $Defaults.gpu }
    @{ cpu = [int]$c; gpu = [int]$g; time = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $Backup
}
function Read-Backup {
    if (Test-Path $Backup) {
        try {
            $b = Get-Content $Backup -Raw | ConvertFrom-Json
            $c = [int]$b.cpu; $g = [int]$b.gpu
            if ($c -ge 100 -and $c -le 254 -and $g -ge 100 -and $g -le 254) { return @{ cpu = [uint32]$c; gpu = [uint32]$g } }
        } catch { }
    }
    return $Defaults
}
function Restore-Range {
    $b = Read-Backup
    [void][Atk]::Devs($RangeCpu, [uint32]$b.cpu)
    [void][Atk]::Devs($RangeGpu, [uint32]$b.gpu)
    Remove-Item $Backup -ErrorAction SilentlyContinue
    return $b
}

if ($mode -eq 'restore') {
    [Atk]::Open()
    $r = Restore-Range
    Write-Host ("已把风扇范围恢复为 cpu={0} gpu={1}" -f $r.cpu, $r.gpu) -ForegroundColor Green
    Start-Sleep 2
    exit
}

# 档位表：二档(默认) 约 CPU7000/GPU7800 RPM；一档 满速 约 8300-8400 RPM
$gears = @{
    1 = @{ cpu = 255; gpu = 255; name = '一档 满速 (约 8400 RPM)' }
    2 = @{ cpu = 200; gpu = 230; name = '二档 (约 CPU 7000 / GPU 7800 RPM)' }
}
$Seconds = 0; $SimKeys = ''
if ($mode -eq 'test') { $Seconds = [int]$argv[1]; if ($argv.Count -gt 2) { $SimKeys = $argv[2] } }

$host.UI.RawUI.WindowTitle = 'Fan MAX - 按 1=一档  2=二档  关闭窗口/Ctrl+C=恢复默认'
[Atk]::Open()
Save-Backup
$b = Read-Backup
[Atk]::RestoreCpu = [uint32]$b.cpu; [Atk]::RestoreGpu = [uint32]$b.gpu
[Atk]::BackupPath = $Backup
[Atk]::Armed = $true
[Atk]::ArmCloseHandler()

Write-Host '=== 风扇控制 (ROG Zephyrus M16) ===' -ForegroundColor Cyan
Write-Host '按 1 = 一档(满速)   按 2 = 二档   关闭窗口 / Ctrl+C = 恢复默认' -ForegroundColor Yellow
Write-Host ("原值 cpu={0} gpu={1}，已备份。" -f $b.cpu, $b.gpu)

$cur = 2
$simQueue = [System.Collections.Queue]::new(); foreach ($ch in $SimKeys.ToCharArray()) { $simQueue.Enqueue($ch) }
$tick = 0; $t0 = Get-Date
try {
    while ($true) {
        $new = $null
        try {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.KeyChar -eq '1' -or $k.Key -eq 'NumPad1') { $new = 1 }
                elseif ($k.KeyChar -eq '2' -or $k.Key -eq 'NumPad2') { $new = 2 }
            }
        } catch { }
        if ($simQueue.Count -gt 0 -and $tick -ge 6 -and ($tick % 6) -eq 0) { $c = $simQueue.Dequeue(); if ($c -eq '1') { $new = 1 } elseif ($c -eq '2') { $new = 2 } }
        if ($new -and $new -ne $cur) { $cur = $new; $tick = 0 }

        # 每 5 秒(或切档时)写入一次，防止固件改回
        if (($tick % 5) -eq 0) {
            [void][Atk]::Devs($RangeCpu, [uint32]$gears[$cur].cpu)
            [void][Atk]::Devs($RangeGpu, [uint32]$gears[$cur].gpu)
        }
        Write-Host ("`r[{0}]  CPU {1,5} RPM   GPU {2,5} RPM    " -f $gears[$cur].name, (Get-Rpm $RpmCpu), (Get-Rpm $RpmGpu)) -NoNewline
        Start-Sleep -Seconds 1
        $tick++
        if ($Seconds -gt 0 -and ((Get-Date) - $t0).TotalSeconds -ge $Seconds) { throw 'timeout' }
    }
}
catch { if ("$_" -ne 'timeout') { Write-Host "`n错误: $_" -ForegroundColor Red } }
finally {
    [Atk]::Armed = $false
    $r = Restore-Range
    Write-Host ("`n已恢复 cpu={0} gpu={1}" -f $r.cpu, $r.gpu) -ForegroundColor Green
    Start-Sleep 1
}
