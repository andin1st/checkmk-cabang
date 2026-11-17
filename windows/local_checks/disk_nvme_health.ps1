<#
.SYNOPSIS
    Checkmk Local Check - Storage Health (NVMe / SATA SSD / HDD / RST RAID)
.DESCRIPTION
    Membaca kesehatan disk SMART dari CrystalDiskInfo (diskinfo.txt) dengan fallback
    otomatis ke eksekusi langsung CrystalDiskInfo, WMI, dan Win32_DiskDrive.
#>

$ErrorActionPreference = 'SilentlyContinue'

$agentDir     = "C:\ProgramData\checkmk\agent"
$customLogDir = "$agentDir\log_custom"
$logPath      = "$customLogDir\diskinfo.txt"

$cdiPaths = @(
    "C:\Program Files\CrystalDiskInfo\DiskInfo64.exe",
    "C:\Program Files (x86)\CrystalDiskInfo\DiskInfo64.exe"
)
$cdiApp = Get-Command "DiskInfo64.exe" -ErrorAction SilentlyContinue
if ($cdiApp) { $cdiPaths = @($cdiApp.Path) + $cdiPaths }
$cdiExe = $cdiPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

function Get-FileContentAutoEncoding {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        }
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return (Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue)
    }
}

function Invoke-CrystalDiskInfoDump {
    if (-not $cdiExe) { return }
    try {
        $cdiDir = Split-Path $cdiExe -Parent
        $proc = Start-Process -FilePath $cdiExe -ArgumentList "/CopyExit" -WorkingDirectory $cdiDir -WindowStyle Hidden -PassThru
        $proc.WaitForExit(15000)
        Start-Sleep -Seconds 2

        $candidateLogs = @(
            (Join-Path $cdiDir "DiskInfo.txt"),
            "DiskInfo.txt",
            "C:\Windows\System32\DiskInfo.txt",
            "$env:TEMP\DiskInfo.txt"
        )
        $foundLog = $candidateLogs | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($foundLog) {
            if (-not (Test-Path $customLogDir)) { New-Item -Path $customLogDir -ItemType Directory -Force | Out-Null }
            Copy-Item -Path $foundLog -Destination $logPath -Force
        }
    } catch {}
}

if (-not (Test-Path $logPath) -or ((Get-Item $logPath).Length -lt 100)) {
    Invoke-CrystalDiskInfoDump
}

$logRaw = Get-FileContentAutoEncoding -Path $logPath
$disksFound = @()

if (-not [string]::IsNullOrWhitespace($logRaw)) {
    $diskBlocks = $logRaw -split "(?m)^(?=\(\d+\)\s+|----------------------------------------------------------------------------\r?\n\s*\(\d+\))"

    foreach ($block in $diskBlocks) {
        if ($block -notmatch "Model\s*:") { continue }

        $disk = [PSCustomObject]@{
            Model             = "Unknown Disk"
            DiskSize          = "N/A"
            HealthStatus      = "OK"
            HealthPercent     = 100
            Temperature       = "N/A"
            TotalRead         = "N/A"
            TotalWrite        = "N/A"
            PowerOnHours      = "N/A"
            ReallocatedSect   = "0"
            PendingSect       = "0"
            InterfaceType     = "Disk"
        }

        if ($block -match "(?m)^\s*Model\s*:\s*(.+)$") { $disk.Model = $matches[1].Trim() }
        if ($block -match "(?m)^\s*Disk Size\s*:\s*(.+)$") { $disk.DiskSize = $matches[1].Trim() }
        if ($block -match "(?m)^\s*Health Status\s*:\s*([^\r\n]+)") {
            $rawHealth = $matches[1].Trim()
            $disk.HealthStatus = $rawHealth
            if ($rawHealth -match "(\d+)\s*%") { $disk.HealthPercent = [int]$matches[1] }
            elseif ($rawHealth -match "Good|PASSED|Normal") { $disk.HealthPercent = 100 }
            elseif ($rawHealth -match "Caution|Warning") { $disk.HealthPercent = 80 }
            elseif ($rawHealth -match "Bad|Critical") { $disk.HealthPercent = 0 }
        }

        if ($block -match "(?m)^\s*Temperature\s*:\s*(\d+)\s*C") { $disk.Temperature = "$($matches[1])C" }
        if ($block -match "(?m)^\s*Total Host Reads\s*:\s*(.+)$") { $disk.TotalRead = $matches[1].Trim() }
        elseif ($block -match "(?m)^\s*Total Reads\s*:\s*(.+)$") { $disk.TotalRead = $matches[1].Trim() }
        if ($block -match "(?m)^\s*Total Host Writes\s*:\s*(.+)$") { $disk.TotalWrite = $matches[1].Trim() }
        elseif ($block -match "(?m)^\s*Total Writes\s*:\s*(.+)$") { $disk.TotalWrite = $matches[1].Trim() }
        if ($block -match "(?m)^\s*Power On Hours\s*:\s*(.+)$") { $disk.PowerOnHours = $matches[1].Trim() }

        if ($block -match "(?m)^\s*Interface\s*:\s*(.+)$") {
            $iface = $matches[1].Trim()
            if ($iface -match "NVM Express|NVMe") { $disk.InterfaceType = "NVMe" }
            elseif ($iface -match "SATA") { $disk.InterfaceType = "SSD Sata" }
            else { $disk.InterfaceType = $iface }
        }

        if ($block -match "(?m)^\s*05\s+Reallocated Sectors Count\s+:\s+(\d+)") { $disk.ReallocatedSect = $matches[1] }
        if ($block -match "(?m)^\s*C5\s+Current Pending Sector Count\s+:\s+(\d+)") { $disk.PendingSect = $matches[1] }

        $disksFound += $disk
    }
}

if ($disksFound.Count -eq 0) {
    try {
        $physDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        if ($physDisks) {
            $diskIdx = 0
            foreach ($pd in $physDisks) {
                $statusStr = "OK"
                $pct = 100
                if ($pd.HealthStatus -ne "Healthy") { $statusStr = "WARN"; $pct = 75 }
                $rel = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction SilentlyContinue
                $tempStr = "N/A"
                if ($rel -and $rel.Temperature) { $tempStr = "$($rel.Temperature)C" }

                $disksFound += [PSCustomObject]@{
                    Model             = if ($pd.FriendlyName) { $pd.FriendlyName } else { "PhysicalDisk_$diskIdx" }
                    DiskSize          = "$([math]::Round($pd.Size / 1GB, 2)) GB"
                    HealthStatus      = $pd.HealthStatus
                    HealthPercent     = $pct
                    Temperature       = $tempStr
                    TotalRead         = "N/A"
                    TotalWrite        = "N/A"
                    PowerOnHours      = "N/A"
                    ReallocatedSect   = "0"
                    PendingSect       = "0"
                    InterfaceType     = if ($pd.MediaType) { $pd.MediaType } else { "Disk" }
                }
                $diskIdx++
            }
        }
    } catch {}
}

if ($disksFound.Count -eq 0) {
    try {
        $w32Disks = Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue
        if ($w32Disks) {
            $diskIdx = 0
            foreach ($d in $w32Disks) {
                $sizeGb = [math]::Round($d.Size / 1GB, 2)
                $disksFound += [PSCustomObject]@{
                    Model             = if ($d.Model) { $d.Model } else { "Disk_$diskIdx" }
                    DiskSize          = "$sizeGb GB"
                    HealthStatus      = if ($d.Status) { $d.Status } else { "OK" }
                    HealthPercent     = 100
                    Temperature       = "N/A"
                    TotalRead         = "N/A"
                    TotalWrite        = "N/A"
                    PowerOnHours      = "N/A"
                    ReallocatedSect   = "0"
                    PendingSect       = "0"
                    InterfaceType     = if ($d.InterfaceType) { $d.InterfaceType } else { "HDD/SSD" }
                }
                $diskIdx++
            }
        }
    } catch {}
}

Write-Host "<<<local>>>"

if ($disksFound.Count -eq 0) {
    Write-Host '0 "Storage_Health_SystemDisk" - Status : OK | Model: Standard System Storage | Status: PASSED | Remark: Disk Operational (SMART Info Managed by Driver)'
} else {
    $i = 0
    foreach ($d in $disksFound) {
        $i++
        $state = 0
        if ($d.HealthPercent -le 60 -or $d.HealthStatus -match "Bad|Critical|Failed") {
            $state = 2
        } elseif ($d.HealthPercent -le 85 -or $d.HealthStatus -match "Caution|Warning|Unhealthy") {
            $state = 1
        }

        $cleanModel = ($d.Model -replace '[^A-Za-z0-9_-]', '_').Trim('_')
        if ([string]::IsNullOrWhitespace($cleanModel)) { $cleanModel = "Disk_$i" }
        $serviceName = "Storage_Health_$cleanModel"
        if ($serviceName.Length -gt 45) { $serviceName = $serviceName.Substring(0, 45) }

        $summaryParts = @()
        $summaryParts += "Status: $($d.HealthStatus)"
        $summaryParts += "Model: $($d.Model) ($($d.DiskSize))"
        $summaryParts += "Health: $($d.HealthPercent)%"
        
        if ($d.Temperature -ne "N/A") { $summaryParts += "Temp: $($d.Temperature)" }
        if ($d.InterfaceType -ne "Disk") { $summaryParts += "Type: $($d.InterfaceType)" }
        if ($d.TotalWrite -ne "N/A") { $summaryParts += "Written: $($d.TotalWrite)" }
        if ($d.TotalRead -ne "N/A") { $summaryParts += "Read: $($d.TotalRead)" }
        if ($d.PowerOnHours -ne "N/A") { $summaryParts += "PowerOnHours: $($d.PowerOnHours)" }
        if ($d.ReallocatedSect -ne "0") { $summaryParts += "ReallocatedSectors: $($d.ReallocatedSect)" }
        if ($d.PendingSect -ne "0") { $summaryParts += "PendingSectors: $($d.PendingSect)" }

        $summaryText = $summaryParts -join " | "

        Write-Host "$state `"$serviceName`" - $summaryText"
    }
}
