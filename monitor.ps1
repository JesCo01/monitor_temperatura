<#
================================================================================
 MONITOR DE TEMPERATURAS Y ESTABILIDAD DEL SISTEMA (GENERAL / AUTO-INSTALABLE)
 Compatible con cualquier PC, Laptop o Surface con Windows 10/11
================================================================================
#>

param (
    [int]$Intervalo = 2,
    [int]$UmbralAlerta = 85,
    [switch]$SinSonido,
    [switch]$SoloUnaVez
)

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $Host.UI.RawUI.WindowTitle = "Monitor de Temperaturas - Remote Shield"
} catch {}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path $scriptDir "lib"
$dllPath = Join-Path $libDir "LibreHardwareMonitorLib.dll"
$logPath = Join-Path $scriptDir "registro_temperaturas.csv"

# Comprobación de permisos de Administrador
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 1. Auto-instalación de LibreHardwareMonitorLib si no existe
if (-not (Test-Path $dllPath)) {
    Write-Host "[INSTALADOR] Descargando LibreHardwareMonitorLib (primera ejecución)..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null
        $zipTemp = Join-Path $env:TEMP "LibreHardwareMonitor_setup.zip"
        $url = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest/download/LibreHardwareMonitor.zip"
        Invoke-WebRequest -Uri $url -OutFile $zipTemp -UseBasicParsing
        Expand-Archive -Path $zipTemp -DestinationPath $libDir -Force
        Remove-Item -Path $zipTemp -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Librería de sensores instalada correctamente." -ForegroundColor Green
    } catch {
        Write-Host "[AVISO] No se pudo descargar LibreHardwareMonitorLib: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 2. Cargar librería y auto-instalar driver firmado PawnIO (requerido por LHM v0.9.6 en Win11/HVCI)
$computer = $null
if (Test-Path $dllPath) {
    try {
        Get-ChildItem -Path $libDir -Filter "*.dll" | Unblock-File -ErrorAction SilentlyContinue
        Add-Type -Path $dllPath -ErrorAction Stop

        if ($isAdmin -and -not [LibreHardwareMonitor.PawnIo.PawnIo]::IsInstalled) {
            Write-Host "[INSTALADOR] Instalando driver firmado PawnIO para desbloquear sensores de CPU y Placa..." -ForegroundColor Cyan
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $pawnExe = Join-Path $env:TEMP "PawnIO_setup.exe"
                $pawnUrl = "https://github.com/namazso/PawnIO.Setup/releases/latest/download/PawnIO_setup.exe"
                Invoke-WebRequest -Uri $pawnUrl -OutFile $pawnExe -UseBasicParsing
                Start-Process -FilePath $pawnExe -ArgumentList "-install", "-silent" -Wait -NoNewWindow
                Remove-Item -Path $pawnExe -Force -ErrorAction SilentlyContinue
                Write-Host "[OK] Driver PawnIO instalado correctamente." -ForegroundColor Green
            } catch {
                Write-Host "[AVISO] No se pudo auto-instalar PawnIO: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        $computer = [LibreHardwareMonitor.Hardware.Computer]::new()
        $computer.IsCpuEnabled = $true
        $computer.IsGpuEnabled = $true
        $computer.IsMemoryEnabled = $true
        $computer.IsMotherboardEnabled = $true
        $computer.IsStorageEnabled = $true
        $computer.IsControllerEnabled = $true
        $computer.Open()
    } catch {
        $computer = $null
    }
}

# Detectar información base del hardware dinámicamente
$hwInfo = @{
    CpuName         = "Procesador Desconocido"
    MoboName        = "Placa Base / Equipo"
    GpuFallbackName = "Gráfica Integrada / Estándar"
    HasNvidiaSmi    = [bool](Get-Command "nvidia-smi" -ErrorAction SilentlyContinue)
    PawnInstalled   = $false
}

try {
    if ($computer) { $hwInfo.PawnInstalled = [LibreHardwareMonitor.PawnIo.PawnIo]::IsInstalled }
    $proc = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Name) { $hwInfo.CpuName = $proc.Name.Trim() }
    $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bb) { $hwInfo.MoboName = "$($bb.Manufacturer) $($bb.Product)".Trim() }
    $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vc -and $vc.Name) { $hwInfo.GpuFallbackName = $vc.Name.Trim() }
} catch {}

# Crear cabecera CSV si no existe
if (-not (Test-Path $logPath)) {
    try {
        "Fecha_Hora,CPU_Temp_C,CPU_Carga_Pct,GPU_Nombre,GPU_Temp_C,GPU_Carga_Pct,SSD_Principal_Temp_C,RAM_Usada_GB,RAM_Pct,Estado" | Out-File -FilePath $logPath -Encoding utf8
    } catch {}
}

function Parse-InvariantDouble($val) {
    if ($null -eq $val -or $val -eq "") { return $null }
    try {
        $str = ($val.ToString()).Trim()
        return [double]::Parse($str, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        try {
            $str = ($val.ToString()).Trim().Replace('.', ',')
            return [double]$str
        } catch {
            return $null
        }
    }
}

function Obtener-Fallback-Nvidia {
    if (-not $hwInfo.HasNvidiaSmi) { return $null }
    try {
        $smi = nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,power.draw,fan.speed --format=csv,noheader,nounits 2>$null
        if ($smi) {
            $firstLine = ($smi -split "`r?`n")[0]
            $parts = $firstLine -split ',' | ForEach-Object { $_.Trim() }
            return @{
                Name  = $parts[0]
                Temp  = Parse-InvariantDouble $parts[1]
                Load  = Parse-InvariantDouble $parts[2]
                Power = Parse-InvariantDouble $parts[3]
                Fan   = Parse-InvariantDouble $parts[4]
            }
        }
    } catch {}
    return $null
}

function Obtener-EstadoBadge($temp, $umbral) {
    if ($null -eq $temp -or $temp -eq "" -or $temp -eq "N/A") {
        return @{ Texto = "N/A    "; Color = "DarkGray"; Icon = "[?]" }
    }
    $val = [double]$temp
    if ($val -ge $umbral) {
        return @{ Texto = "PELIGRO"; Color = "Red"; Icon = "[!]" }
    } elseif ($val -ge ($umbral - 10)) {
        return @{ Texto = "ELEVADO"; Color = "Yellow"; Icon = "[~]" }
    } else {
        return @{ Texto = "NORMAL "; Color = "Green"; Icon = "[OK]" }
    }
}

function Obtener-SensoresRecursivo($hwItem) {
    $hwItem.Update()
    $lista = @()
    if ($hwItem.Sensors) { $lista += $hwItem.Sensors }
    if ($hwItem.SubHardware) {
        foreach ($sub in $hwItem.SubHardware) {
            $lista += Obtener-SensoresRecursivo $sub
        }
    }
    return $lista
}

function Leer-Metricas {
    $m = [ordered]@{
        Fecha      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CpuName    = $hwInfo.CpuName
        MoboName   = $hwInfo.MoboName
        CpuTempPkg = $null
        CpuTempMax = $null
        CpuLoad    = $null
        CpuPower   = $null
        MoboTemp   = $null
        Gpus       = @()
        Drives     = @()
        RamUsedGB  = $null
        RamTotalGB = $null
        RamPct     = $null
    }

    if ($computer) {
        foreach ($hw in $computer.Hardware) {
            $type = $hw.HardwareType
            $allSensors = Obtener-SensoresRecursivo $hw

            if ($type -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) {
                $m.CpuName = $hw.Name
                foreach ($s in $allSensors) {
                    if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $s.Value -gt 1 -and $s.Value -lt 130) {
                        if ($s.Name -like "*Distance to TjMax*") { continue }
                        $val = [math]::Round($s.Value, 1)
                        if ($s.Name -eq "CPU Package" -or $s.Name -like "*Package*" -or $s.Name -like "*Tctl/Tdie*") {
                            $m.CpuTempPkg = $val
                        } elseif ($s.Name -eq "Core Max" -or $s.Name -eq "Core Average") {
                            if ($null -eq $m.CpuTempMax -or $val -gt $m.CpuTempMax) { $m.CpuTempMax = $val }
                        } elseif ($s.Name -like "*Core*") {
                            if ($null -eq $m.CpuTempMax -or $val -gt $m.CpuTempMax) { $m.CpuTempMax = $val }
                        }
                    } elseif ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and $null -ne $s.Value) {
                        if ($s.Name -eq "CPU Total") { $m.CpuLoad = [math]::Round($s.Value, 1) }
                    } elseif ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and $s.Value -gt 0) {
                        if ($s.Name -eq "CPU Package" -or $s.Name -like "*Package*") { $m.CpuPower = [math]::Round($s.Value, 1) }
                    }
                }
            } elseif ($type -eq [LibreHardwareMonitor.Hardware.HardwareType]::Motherboard) {
                $m.MoboName = $hw.Name
                foreach ($s in $allSensors) {
                    if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $s.Value -gt 5 -and $s.Value -lt 120) {
                        $val = [math]::Round($s.Value, 1)
                        if ($s.Name -like "*CPU*" -and $null -eq $m.CpuTempPkg) {
                            $m.CpuTempPkg = $val
                        } elseif ($null -eq $m.MoboTemp -and ($s.Name -like "*Motherboard*" -or $s.Name -like "*System*" -or $s.Name -eq "Temperature #1")) {
                            $m.MoboTemp = $val
                        }
                    }
                }
            } elseif ($type -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuNvidia -or
                      $type -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuAmd -or
                      $type -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuIntel) {
                $g = [ordered]@{
                    Name     = $hw.Name
                    TempCore = $null
                    TempVram = $null
                    Load     = $null
                    Power    = $null
                    Fan      = $null
                }
                foreach ($s in $allSensors) {
                    if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $s.Value -gt 1) {
                        if ($s.Name -eq "GPU Core" -or $null -eq $g.TempCore) { $g.TempCore = [math]::Round($s.Value, 1) }
                        if ($s.Name -like "*Memory*") { $g.TempVram = [math]::Round($s.Value, 1) }
                    } elseif ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and $null -ne $s.Value) {
                        if ($s.Name -eq "GPU Core" -or $s.Name -eq "D3D 3D") {
                            if ($null -eq $g.Load -or $s.Name -eq "GPU Core") { $g.Load = [math]::Round($s.Value, 1) }
                        }
                    } elseif ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and $s.Value -gt 0) {
                        if ($s.Name -like "*Package*" -or $s.Name -like "*Power*") { $g.Power = [math]::Round($s.Value, 1) }
                    } elseif ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Fan -and $null -ne $s.Value) {
                        if ($null -eq $g.Fan) { $g.Fan = [math]::Round($s.Value, 0) }
                    }
                }
                $m.Gpus += $g
            } elseif ($type -eq [LibreHardwareMonitor.Hardware.HardwareType]::Storage) {
                $tempMain = $null
                $tempCtrl = $null
                foreach ($s in $allSensors) {
                    if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $s.Value -gt 1 -and $s.Value -lt 120) {
                        if ($s.Name -like "*Warning*" -or $s.Name -like "*Critical*" -or $s.Name -like "*Limit*" -or $s.Name -like "*Threshold*") {
                            continue
                        }
                        $t = [math]::Round($s.Value, 1)
                        if ($s.Name -eq "Temperature") {
                            $tempMain = $t
                        } else {
                            if ($null -eq $tempCtrl -or $t -gt $tempCtrl) { $tempCtrl = $t }
                        }
                    }
                }
                if ($null -eq $tempMain -and $null -ne $tempCtrl) {
                    $tempMain = $tempCtrl
                    $tempCtrl = $null
                }
                if ($null -ne $tempMain) {
                    $m.Drives += [ordered]@{
                        Name     = $hw.Name
                        TempMain = $tempMain
                        TempCtrl = $tempCtrl
                    }
                }
            } elseif ($type -eq [LibreHardwareMonitor.Hardware.HardwareType]::Memory -and $hw.Name -eq "Total Memory") {
                foreach ($s in $allSensors) {
                    if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Data -and $s.Name -eq "Memory Used") {
                        $m.RamUsedGB = [math]::Round($s.Value, 1)
                    } elseif ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and $s.Name -eq "Memory") {
                        $m.RamPct = [math]::Round($s.Value, 1)
                    }
                }
            }
        }
    }

    # Fallback para NVIDIA si existe nvidia-smi
    $fb = Obtener-Fallback-Nvidia
    if ($fb) {
        $nvGpu = $m.Gpus | Where-Object { $_.Name -like "*NVIDIA*" } | Select-Object -First 1
        if ($nvGpu) {
            if ($null -eq $nvGpu.TempCore) { $nvGpu.TempCore = $fb.Temp }
            if ($null -eq $nvGpu.Load)     { $nvGpu.Load = $fb.Load }
            if ($null -eq $nvGpu.Power)    { $nvGpu.Power = $fb.Power }
            if ($null -eq $nvGpu.Fan)      { $nvGpu.Fan = $fb.Fan }
        } else {
            $m.Gpus += [ordered]@{
                Name     = $fb.Name
                TempCore = $fb.Temp
                TempVram = $null
                Load     = $fb.Load
                Power    = $fb.Power
                Fan      = $fb.Fan
            }
        }
    }

    if ($m.Gpus.Count -eq 0) {
        $m.Gpus += [ordered]@{
            Name     = $hwInfo.GpuFallbackName
            TempCore = $null
            TempVram = $null
            Load     = $null
            Power    = $null
            Fan      = $null
        }
    }

    # Fallback ACPI solo para laptops/Surface (ignorando valores fijos falsos de BIOS como 27.8°C / 26.8°C)
    if ($null -eq $m.CpuTempPkg -and $null -eq $m.CpuTempMax -and $isAdmin) {
        try {
            $tz = Get-CimInstance -Namespace "root/wmi" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction SilentlyContinue
            if ($tz) {
                $temps = @()
                foreach ($z in $tz) {
                    $c = [math]::Round(($z.CurrentTemperature - 2732) / 10.0, 1)
                    if ($c -gt 15 -and $c -lt 120 -and $c -ne 27.8 -and $c -ne 26.8 -and $c -ne 29.8) {
                        $temps += $c
                    }
                }
                if ($temps.Count -gt 0) {
                    $m.CpuTempPkg = ($temps | Measure-Object -Maximum).Maximum
                }
            }
        } catch {}
    }

    if ($null -eq $m.RamPct) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os) {
                $total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
                $free = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
                $m.RamUsedGB = [math]::Round($total - $free, 1)
                $m.RamPct = [math]::Round((($total - $free) / $total) * 100, 1)
            }
        } catch {}
    }

    if ($null -eq $m.CpuLoad) {
        try {
            $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average
            if ($cpu) { $m.CpuLoad = [math]::Round($cpu.Average, 1) }
        } catch {}
    }

    return $m
}

# Bucle principal
if (-not $SoloUnaVez) { Clear-Host }
try {
    while ($true) {
        $m = Leer-Metricas
        $hayAlerta = $false
        $motivoAlerta = ""

        $cpuTempRef = if ($null -ne $m.CpuTempPkg) { $m.CpuTempPkg } else { $m.CpuTempMax }
        $cpuBadge = Obtener-EstadoBadge $cpuTempRef $UmbralAlerta

        if (($null -ne $m.CpuTempPkg -and $m.CpuTempPkg -ge $UmbralAlerta) -or ($null -ne $m.CpuTempMax -and $m.CpuTempMax -ge $UmbralAlerta)) {
            $hayAlerta = $true
            $motivoAlerta += " [CPU SOBRECALENTANDO: $($cpuTempRef)°C]"
        }
        foreach ($g in $m.Gpus) {
            if ($null -ne $g.TempCore -and $g.TempCore -ge $UmbralAlerta) {
                $hayAlerta = $true
                $motivoAlerta += " [GPU ($($g.Name)) SOBRECALENTANDO: $($g.TempCore)°C]"
            }
        }
        foreach ($d in $m.Drives) {
            if ($null -ne $d.TempMain -and $d.TempMain -ge 75) {
                $hayAlerta = $true
                $motivoAlerta += " [SSD ($($d.Name)) SOBRECALENTANDO: $($d.TempMain)°C]"
            }
        }

        # Log en CSV
        try {
            $estadoStr = if ($hayAlerta) { "CRITICO" } else { "NORMAL" }
            $mainGpu = $m.Gpus[0]
            $mainSsdT = if ($m.Drives.Count -gt 0) { $m.Drives[0].TempMain } else { "" }
            "$($m.Fecha),$cpuTempRef,$($m.CpuLoad),`"$($mainGpu.Name)`",$($mainGpu.TempCore),$($mainGpu.Load),$mainSsdT,$($m.RamUsedGB),$($m.RamPct),$estadoStr" | Out-File -FilePath $logPath -Append -Encoding utf8
        } catch {}

        if ($hayAlerta -and -not $SinSonido) {
            try { [Console]::Beep(1200, 250) } catch {}
        }

        if (-not $SoloUnaVez) {
            try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
        }

        Write-Host "================================================================================" -ForegroundColor Cyan
        Write-Host "         MONITOR DE TEMPERATURAS Y ESTABILIDAD DEL SISTEMA - EN VIVO" -ForegroundColor White
        Write-Host "================================================================================" -ForegroundColor Cyan
        Write-Host ("  Hora actual : {0} | Actualización cada: {1}s                    " -f $m.Fecha, $Intervalo) -ForegroundColor Gray
        Write-Host ("  Procesador  : {0}" -f $m.CpuName).PadRight(78) -ForegroundColor Gray
        Write-Host ("  Placa/Equipo: {0}" -f $m.MoboName).PadRight(78) -ForegroundColor Gray
        if ($isAdmin) {
            Write-Host "  Privilegios : MODO ADMINISTRADOR (Sensores de hardware desbloqueados)       " -ForegroundColor Green
        } else {
            Write-Host "  Privilegios : MODO NORMAL (Sensores de núcleo CPU requieren Admin)          " -ForegroundColor Yellow
        }
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host ("  {0,-24} | {1,-16} | {2,-10} | {3,-22}" -f "COMPONENTE", "TEMPERATURA", "ESTADO", "USO / DETALLES") -ForegroundColor White
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkCyan

        # CPU
        $cpuTempStr = if ($null -ne $cpuTempRef) { "$cpuTempRef °C" } else { if ($isAdmin) { "Sin sensor" } else { "Requiere Admin" } }
        $cpuCargaStr = if ($null -ne $m.CpuLoad) { "$($m.CpuLoad)%" } else { "N/A" }
        $cpuWStr = if ($null -ne $m.CpuPower) { " | $($m.CpuPower)W" } else { "" }
        Write-Host ("  {0,-24} | " -f "CPU Package") -NoNewline
        Write-Host ("{0,-16} | " -f $cpuTempStr) -NoNewline -ForegroundColor $cpuBadge.Color
        Write-Host ("{0} {1,-6} | " -f $cpuBadge.Icon, $cpuBadge.Texto) -NoNewline -ForegroundColor $cpuBadge.Color
        Write-Host ("Carga: $cpuCargaStr$cpuWStr").PadRight(24) -ForegroundColor Gray

        if ($null -ne $m.CpuTempMax -and $m.CpuTempMax -ne $cpuTempRef) {
            $cpuMaxBadge = Obtener-EstadoBadge $m.CpuTempMax $UmbralAlerta
            Write-Host ("  {0,-24} | " -f "CPU Core Max") -NoNewline
            Write-Host ("{0,-16} | " -f "$($m.CpuTempMax) °C") -NoNewline -ForegroundColor $cpuMaxBadge.Color
            Write-Host ("{0} {1,-6} | " -f $cpuMaxBadge.Icon, $cpuMaxBadge.Texto) -NoNewline -ForegroundColor $cpuMaxBadge.Color
            Write-Host ("Núcleo más caliente").PadRight(24) -ForegroundColor Gray
        }

        if ($null -ne $m.MoboTemp) {
            $moboBadge = Obtener-EstadoBadge $m.MoboTemp 75
            Write-Host ("  {0,-24} | " -f "Placa Base (Mainboard)") -NoNewline
            Write-Host ("{0,-16} | " -f "$($m.MoboTemp) °C") -NoNewline -ForegroundColor $moboBadge.Color
            Write-Host ("{0} {1,-6} | " -f $moboBadge.Icon, $moboBadge.Texto) -NoNewline -ForegroundColor $moboBadge.Color
            Write-Host ("Sensor de placa").PadRight(24) -ForegroundColor Gray
        }

        # GPUs
        foreach ($g in $m.Gpus) {
            $gBadge = Obtener-EstadoBadge $g.TempCore $UmbralAlerta
            $shortName = if ($g.Name.Length -gt 24) { $g.Name.Substring(0, 21) + "..." } else { $g.Name }
            $gTempStr = if ($null -ne $g.TempCore) { "$($g.TempCore) °C" } else { "Integrada/N/A" }
            $gCargaStr = if ($null -ne $g.Load) { "$($g.Load)%" } else { "N/A" }
            $gWStr = if ($null -ne $g.Power) { " | $($g.Power)W" } else { "" }
            Write-Host ("  {0,-24} | " -f $shortName) -NoNewline
            Write-Host ("{0,-16} | " -f $gTempStr) -NoNewline -ForegroundColor $gBadge.Color
            Write-Host ("{0} {1,-6} | " -f $gBadge.Icon, $gBadge.Texto) -NoNewline -ForegroundColor $gBadge.Color
            Write-Host ("Carga: $gCargaStr$gWStr").PadRight(24) -ForegroundColor Gray

            if ($null -ne $g.TempVram) {
                $vBadge = Obtener-EstadoBadge $g.TempVram 95
                Write-Host ("  {0,-24} | " -f "GPU Memoria (VRAM)") -NoNewline
                Write-Host ("{0,-16} | " -f "$($g.TempVram) °C") -NoNewline -ForegroundColor $vBadge.Color
                Write-Host ("{0} {1,-6} | " -f $vBadge.Icon, $vBadge.Texto) -NoNewline -ForegroundColor $vBadge.Color
                Write-Host ("Memoria de video").PadRight(24) -ForegroundColor Gray
            }
        }

        # Todos los Discos / SSDs detectados
        foreach ($d in $m.Drives) {
            $ssdBadge = Obtener-EstadoBadge $d.TempMain 70
            $dLabel = "SSD: " + $d.Name
            if ($dLabel.Length -gt 24) { $dLabel = $dLabel.Substring(0, 21) + "..." }
            $ctrlNote = if ($null -ne $d.TempCtrl -and $d.TempCtrl -ne $d.TempMain) { "Ctrl: $($d.TempCtrl)°C" } else { "Temp. compuesta" }
            Write-Host ("  {0,-24} | " -f $dLabel) -NoNewline
            Write-Host ("{0,-16} | " -f "$($d.TempMain) °C") -NoNewline -ForegroundColor $ssdBadge.Color
            Write-Host ("{0} {1,-6} | " -f $ssdBadge.Icon, $ssdBadge.Texto) -NoNewline -ForegroundColor $ssdBadge.Color
            Write-Host $ctrlNote.PadRight(24) -ForegroundColor Gray
        }

        # RAM
        $ramStr = if ($null -ne $m.RamUsedGB) { "$($m.RamUsedGB) GB" } else { "N/A" }
        $ramPctStr = if ($null -ne $m.RamPct) { "$($m.RamPct)%" } else { "N/A" }
        $ramBadge = if ($m.RamPct -ge 90) { @{ Texto = "ALTO  "; Color = "Yellow"; Icon = "[!]" } } else { @{ Texto = "NORMAL "; Color = "Green"; Icon = "[OK]" } }
        Write-Host ("  {0,-24} | " -f "Memoria RAM") -NoNewline
        Write-Host ("{0,-16} | " -f $ramStr) -NoNewline
        Write-Host ("{0} {1,-6} | " -f $ramBadge.Icon, $ramBadge.Texto) -NoNewline -ForegroundColor $ramBadge.Color
        Write-Host ("Uso: $ramPctStr").PadRight(24) -ForegroundColor Gray

        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkCyan
        if ($hayAlerta) {
            Write-Host "  ESTADO: ¡PELIGRO DE RECALENTAMIENTO DETECTADO!                              " -ForegroundColor Red
            Write-Host ("  " + $motivoAlerta).PadRight(78) -ForegroundColor Red
        } else {
            Write-Host "  ESTADO: SISTEMA EN CONDICIÓN SALUDABLE Y ESTABLE.                           " -ForegroundColor Green
            Write-Host "  -> Las temperaturas están en rango seguro.                                  " -ForegroundColor Gray
        }

        if (-not $isAdmin) {
            Write-Host "  [TIP]: Ejecuta 'iniciar_monitor.bat' como Admin para instalar/leer CPU.     " -ForegroundColor Yellow
        }
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host "  [Log] $logPath" -ForegroundColor DarkGray
        Write-Host "  [Ctrl+C] para detener el monitor.                                           " -ForegroundColor DarkGray
        Write-Host "================================================================================" -ForegroundColor Cyan

        if ($SoloUnaVez) { break }
        Start-Sleep -Seconds $Intervalo
    }
} finally {
    if ($computer) { $computer.Close() }
}
