"""
Monitor de Temperatura y Estabilidad del Sistema (General / Auto-instalable)
Compatible con cualquier PC, Laptop o Surface con Windows 10/11.
"""

import os
import sys
import time
import subprocess
import json
import csv
import threading
import platform
import urllib.request
import zipfile
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LIB_DIR = os.path.join(SCRIPT_DIR, "lib")
DLL_PATH = os.path.join(LIB_DIR, "LibreHardwareMonitorLib.dll")
CSV_PATH = os.path.join(SCRIPT_DIR, "registro_temperaturas.csv")
UMBRAL_ALERTA = 85.0

def ensure_dependencies():
    """Auto-instala psutil y LibreHardwareMonitorLib si faltan."""
    global psutil
    try:
        import psutil as _psutil
        psutil = _psutil
    except ImportError:
        print("[INSTALADOR] Instalando paquete 'psutil'...")
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "psutil", "-q"])
            import psutil as _psutil
            psutil = _psutil
            print("[OK] psutil instalado.")
        except Exception as e:
            print(f"[AVISO] No se pudo instalar psutil ({e}). Usando modo básico.")
            psutil = None

    if not os.path.exists(DLL_PATH):
        print("[INSTALADOR] Descargando LibreHardwareMonitorLib (primera ejecución)...")
        try:
            os.makedirs(LIB_DIR, exist_ok=True)
            zip_path = os.path.join(LIB_DIR, "lhm_temp.zip")
            url = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest/download/LibreHardwareMonitor.zip"
            urllib.request.urlretrieve(url, zip_path)
            with zipfile.ZipFile(zip_path, "r") as zf:
                zf.extractall(LIB_DIR)
            os.remove(zip_path)
            print("[OK] LibreHardwareMonitorLib instalado.")
        except Exception as e:
            print(f"[AVISO] No se pudo descargar LibreHardwareMonitorLib: {e}")

psutil = None

def detect_hardware_names():
    """Detecta dinámicamente CPU, GPU y Placa/Equipo en Windows."""
    info = {
        "cpu": platform.processor() or "Procesador Windows",
        "gpu": "Gráfica Estándar / Integrada",
        "equipo": platform.node() or "PC Windows",
    }
    try:
        cmd = (
            "$c = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name; "
            "$g = (Get-CimInstance Win32_VideoController | Select-Object -First 1).Name; "
            "$b = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1; "
            "Write-Output \"$c|$g|$($b.Manufacturer) $($b.Model)\""
        )
        out = subprocess.check_output(
            ["powershell", "-NoProfile", "-Command", cmd],
            universal_newlines=True,
            creationflags=0x08000000
        ).strip()
        parts = out.split("|")
        if len(parts) >= 3:
            if parts[0].strip(): info["cpu"] = parts[0].strip()
            if parts[1].strip(): info["gpu"] = parts[1].strip()
            if parts[2].strip(): info["equipo"] = parts[2].strip()
    except Exception:
        pass
    return info

HW_INFO = {}

latest_data = {
    "fecha": "",
    "cpu_name": "Detectando...",
    "gpu_name": "Detectando...",
    "equipo": "Detectando...",
    "cpu_temp": None,
    "cpu_load": 0.0,
    "gpu_temp": None,
    "gpu_load": 0.0,
    "gpu_power": None,
    "gpu_fan": None,
    "ram_used_gb": 0.0,
    "ram_total_gb": 0.0,
    "ram_pct": 0.0,
    "estado": "NORMAL",
    "alerta": False,
    "motivo": "",
    "is_admin": False
}

def check_admin():
    try:
        import ctypes
        return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except Exception:
        return False

def get_nvidia_metrics():
    """Lee GPU NVIDIA vía nvidia-smi si está disponible."""
    try:
        cmd = [
            "nvidia-smi",
            "--query-gpu=name,temperature.gpu,utilization.gpu,power.draw,fan.speed",
            "--format=csv,noheader,nounits"
        ]
        out = subprocess.check_output(cmd, universal_newlines=True, creationflags=0x08000000).strip()
        if out:
            parts = [p.strip() for p in out.splitlines()[0].split(",")]
            return {
                "name": parts[0],
                "temp": float(parts[1]),
                "load": float(parts[2]),
                "power": float(parts[3]),
                "fan": int(float(parts[4]))
            }
    except Exception:
        pass
    return None

def get_lhm_temps():
    """Lee temperatura de CPU y GPU vía LibreHardwareMonitorLib."""
    if not os.path.exists(DLL_PATH):
        return None, None
    try:
        ps_cmd = f"""
        Get-ChildItem -Path '{LIB_DIR}' -Filter '*.dll' | Unblock-File -ErrorAction SilentlyContinue
        Add-Type -Path '{DLL_PATH}'
        $c = [LibreHardwareMonitor.Hardware.Computer]::new()
        $c.IsCpuEnabled = $true
        $c.IsGpuEnabled = $true
        $c.Open()
        $cpuT = $null; $gpuT = $null
        foreach ($hw in $c.Hardware) {{
            $hw.Update()
            if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) {{
                foreach ($s in $hw.Sensors) {{
                    if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $s.Value -gt 1) {{
                        if ($s.Name -eq 'CPU Package' -or $null -eq $cpuT) {{ $cpuT = [math]::Round($s.Value, 1) }}
                    }}
                }}
            }} elseif ($hw.HardwareType.ToString() -like 'Gpu*') {{
                foreach ($s in $hw.Sensors) {{
                    if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $s.Value -gt 1) {{
                        if ($s.Name -eq 'GPU Core' -or $null -eq $gpuT) {{ $gpuT = [math]::Round($s.Value, 1) }}
                    }}
                }}
            }}
        }}
        $c.Close()
        if ($null -eq $cpuT) {{
            try {{
                $tz = Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction SilentlyContinue
                if ($tz) {{
                    $maxAcpi = ($tz | ForEach-Object {{ ($_.CurrentTemperature - 2732) / 10.0 }} | Where-Object {{ $_ -gt 10 -and $_ -lt 125 }} | Measure-Object -Maximum).Maximum
                    if ($maxAcpi) {{ $cpuT = [math]::Round($maxAcpi, 1) }}
                }}
            }} catch {{}}
        }}
        Write-Output "$cpuT,$gpuT"
        """
        out = subprocess.check_output(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_cmd],
            universal_newlines=True,
            creationflags=0x08000000
        ).strip()
        if out and "," in out:
            c_str, g_str = out.split(",", 1)
            c_val = float(c_str) if c_str.strip() else None
            g_val = float(g_str) if g_str.strip() else None
            return c_val, g_val
    except Exception:
        pass
    return None, None

def poll_system():
    global latest_data
    is_admin = check_admin()
    latest_data["is_admin"] = is_admin
    latest_data["fecha"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    latest_data["cpu_name"] = HW_INFO.get("cpu", "CPU")
    latest_data["gpu_name"] = HW_INFO.get("gpu", "GPU")
    latest_data["equipo"] = HW_INFO.get("equipo", "PC")

    if psutil:
        mem = psutil.virtual_memory()
        latest_data["ram_used_gb"] = round(mem.used / (1024**3), 1)
        latest_data["ram_total_gb"] = round(mem.total / (1024**3), 1)
        latest_data["ram_pct"] = round(mem.percent, 1)
        latest_data["cpu_load"] = round(psutil.cpu_percent(interval=None), 1)

    nv = get_nvidia_metrics()
    if nv:
        latest_data["gpu_name"] = nv["name"]
        latest_data["gpu_temp"] = nv["temp"]
        latest_data["gpu_load"] = nv["load"]
        latest_data["gpu_power"] = nv["power"]
        latest_data["gpu_fan"] = nv["fan"]
    else:
        latest_data["gpu_temp"] = None
        latest_data["gpu_load"] = None
        latest_data["gpu_power"] = None
        latest_data["gpu_fan"] = None

    cpu_t, gpu_t_lhm = get_lhm_temps()
    latest_data["cpu_temp"] = cpu_t
    if latest_data["gpu_temp"] is None and gpu_t_lhm is not None:
        latest_data["gpu_temp"] = gpu_t_lhm

    alerta = False
    motivo = []
    if latest_data["cpu_temp"] and latest_data["cpu_temp"] >= UMBRAL_ALERTA:
        alerta = True
        motivo.append(f"CPU CRÍTICA ({latest_data['cpu_temp']}°C)")
    if latest_data["gpu_temp"] and latest_data["gpu_temp"] >= UMBRAL_ALERTA:
        alerta = True
        motivo.append(f"GPU CRÍTICA ({latest_data['gpu_temp']}°C)")

    latest_data["alerta"] = alerta
    latest_data["motivo"] = " | ".join(motivo)
    latest_data["estado"] = "CRÍTICO" if alerta else "NORMAL"

    try:
        header_needed = not os.path.exists(CSV_PATH)
        with open(CSV_PATH, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            if header_needed:
                writer.writerow(["Fecha_Hora", "CPU_Temp_C", "CPU_Carga_Pct", "GPU_Nombre", "GPU_Temp_C", "RAM_Usada_GB", "RAM_Pct", "Estado"])
            writer.writerow([
                latest_data["fecha"],
                latest_data["cpu_temp"] or "",
                latest_data["cpu_load"],
                latest_data["gpu_name"],
                latest_data["gpu_temp"] or "",
                latest_data["ram_used_gb"],
                latest_data["ram_pct"],
                latest_data["estado"]
            ])
    except Exception:
        pass

    if alerta:
        try:
            import winsound
            winsound.Beep(1200, 300)
        except Exception:
            pass

    return latest_data

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Monitor Térmico del Sistema</title>
    <style>
        :root { --bg: #0d1117; --card: #161b22; --border: #30363d; --text: #c9d1d9; --accent: #58a6ff; --green: #2ea043; --yellow: #d29922; --red: #f85149; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 20px; display: flex; flex-direction: column; align-items: center; }
        .container { max-width: 820px; width: 100%; }
        header { text-align: center; margin-bottom: 24px; border-bottom: 1px solid var(--border); padding-bottom: 14px; }
        h1 { margin: 0 0 8px 0; color: #fff; font-size: 24px; }
        .meta { color: #8b949e; font-size: 13px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); gap: 15px; margin-bottom: 20px; }
        .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 18px; }
        .card-title { font-size: 12px; text-transform: uppercase; color: #8b949e; margin-bottom: 6px; }
        .hw-sub { font-size: 12px; color: var(--accent); margin-bottom: 8px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .temp-display { font-size: 36px; font-weight: bold; margin: 4px 0; }
        .temp-normal { color: var(--green); }
        .temp-warm { color: var(--yellow); }
        .temp-hot { color: var(--red); }
        .details { font-size: 13px; color: #8b949e; margin-top: 10px; border-top: 1px solid #21262d; padding-top: 8px; }
        .banner { padding: 14px 20px; border-radius: 8px; font-weight: 600; margin-bottom: 20px; text-align: center; }
        .banner-normal { background: rgba(46, 160, 67, 0.15); border: 1px solid var(--green); color: #56d364; }
        .banner-alert { background: rgba(248, 81, 73, 0.2); border: 1px solid var(--red); color: #ff7b72; }
        .footer { text-align: center; font-size: 12px; color: #8b949e; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🛡️ Monitor de Estabilidad Térmica</h1>
            <div class="meta" id="equipo-meta">Detectando hardware...</div>
        </header>
        <div id="banner" class="banner banner-normal">Verificando estado térmico...</div>
        <div class="grid">
            <div class="card">
                <div class="card-title">Procesador (CPU)</div>
                <div class="hw-sub" id="cpu-name">--</div>
                <div id="cpu-temp" class="temp-display temp-normal">-- °C</div>
                <div class="details">Carga CPU: <span id="cpu-load">--%</span><br><small id="cpu-note" style="color:#d29922;"></small></div>
            </div>
            <div class="card">
                <div class="card-title">Tarjeta Gráfica (GPU)</div>
                <div class="hw-sub" id="gpu-name">--</div>
                <div id="gpu-temp" class="temp-display temp-normal">-- °C</div>
                <div class="details" id="gpu-details">Carga: --%</div>
            </div>
            <div class="card">
                <div class="card-title">Memoria RAM</div>
                <div class="hw-sub">Sistema</div>
                <div id="ram-pct" class="temp-display" style="color: var(--accent);">-- %</div>
                <div class="details">En uso: <span id="ram-used">-- GB</span> / <span id="ram-total">-- GB</span></div>
            </div>
        </div>
        <div class="footer">Última actualización: <span id="last-update">--</span></div>
    </div>
    <script>
        function updateColor(elem, temp) {
            elem.className = "temp-display";
            if (!temp) { elem.classList.add("temp-normal"); return; }
            if (temp >= 85) elem.classList.add("temp-hot");
            else if (temp >= 75) elem.classList.add("temp-warm");
            else elem.classList.add("temp-normal");
        }
        async function fetchMetrics() {
            try {
                const res = await fetch('/api/metrics');
                const d = await res.json();
                document.getElementById('equipo-meta').innerText = d.equipo + " • Actualización cada 2s";
                document.getElementById('cpu-name').innerText = d.cpu_name;
                document.getElementById('gpu-name').innerText = d.gpu_name;

                const cpuElem = document.getElementById('cpu-temp');
                if (d.cpu_temp) {
                    cpuElem.innerText = d.cpu_temp + " °C";
                    cpuElem.style.fontSize = "36px";
                    updateColor(cpuElem, d.cpu_temp);
                    document.getElementById('cpu-note').innerText = "";
                } else {
                    cpuElem.innerText = d.is_admin ? "Sin sensor" : "Req. Admin";
                    cpuElem.style.fontSize = "24px";
                    document.getElementById('cpu-note').innerText = d.is_admin ? "" : "Ejecuta como Admin para temp de CPU";
                }
                document.getElementById('cpu-load').innerText = d.cpu_load + "%";

                const gpuElem = document.getElementById('gpu-temp');
                if (d.gpu_temp) {
                    gpuElem.innerText = d.gpu_temp + " °C";
                    gpuElem.style.fontSize = "36px";
                    updateColor(gpuElem, d.gpu_temp);
                } else {
                    gpuElem.innerText = "Integrada";
                    gpuElem.style.fontSize = "24px";
                }
                let gDet = "Carga: " + (d.gpu_load !== null ? d.gpu_load + "%" : "N/A");
                if (d.gpu_power !== null) gDet += " | " + d.gpu_power + " W";
                if (d.gpu_fan !== null) gDet += " | Fan: " + d.gpu_fan + "%";
                document.getElementById('gpu-details').innerText = gDet;

                document.getElementById('ram-pct').innerText = d.ram_pct + " %";
                document.getElementById('ram-used').innerText = d.ram_used_gb + " GB";
                document.getElementById('ram-total').innerText = d.ram_total_gb + " GB";

                const banner = document.getElementById('banner');
                if (d.alerta) {
                    banner.className = "banner banner-alert";
                    banner.innerText = "⚠️ ¡ALERTA TÉRMICA! " + d.motivo;
                } else {
                    banner.className = "banner banner-normal";
                    banner.innerText = "🟢 SISTEMA SEGURO Y ESTABLE";
                }
                document.getElementById('last-update').innerText = d.fecha;
            } catch (e) {}
        }
        setInterval(fetchMetrics, 2000);
        fetchMetrics();
    </script>
</body>
</html>
"""

class MetricsHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_TEMPLATE.encode("utf-8"))
        elif self.path == "/api/metrics":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(latest_data).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

def main():
    global HW_INFO
    import argparse
    parser = argparse.ArgumentParser(description="Monitor de Temperatura de PC (General)")
    parser.add_argument("--web", action="store_true", help="Iniciar servidor web con panel gráfico")
    parser.add_argument("--port", type=int, default=8080, help="Puerto del servidor web")
    parser.add_argument("--once", action="store_true", help="Ejecutar una sola vez y salir")
    args = parser.parse_args()

    ensure_dependencies()
    HW_INFO = detect_hardware_names()

    if args.web:
        def poller():
            while True:
                poll_system()
                time.sleep(2)
        threading.Thread(target=poller, daemon=True).start()
        print(f"[*] Panel Web disponible en: http://localhost:{args.port}")
        HTTPServer(("0.0.0.0", args.port), MetricsHandler).serve_forever()
        return

    try:
        while True:
            d = poll_system()
            os.system("cls" if os.name == "nt" else "clear")
            print("=" * 76)
            print("        MONITOR DE TEMPERATURAS Y ESTABILIDAD DEL SISTEMA")
            print("=" * 76)
            print(f"  Equipo      : {d['equipo']}")
            print(f"  Procesador  : {d['cpu_name']}")
            print(f"  Gráfica     : {d['gpu_name']}")
            print(f"  Hora / Modo : {d['fecha']} | {'Admin' if d['is_admin'] else 'Normal'}")
            print("-" * 76)
            cpu_t = f"{d['cpu_temp']} °C" if d['cpu_temp'] else ("Sin sensor" if d['is_admin'] else "Req. Admin")
            gpu_t = f"{d['gpu_temp']} °C" if d['gpu_temp'] else "Integrada/N/A"
            print(f"  CPU         : {cpu_t:<14} | Carga: {d['cpu_load']}%")
            print(f"  GPU         : {gpu_t:<14} | Carga: {d['gpu_load'] if d['gpu_load'] is not None else 'N/A'}%")
            print(f"  RAM         : {d['ram_pct']}%          | {d['ram_used_gb']} GB / {d['ram_total_gb']} GB")
            print("-" * 76)
            print(f"  ESTADO      : {'¡ALERTA! ' + d['motivo'] if d['alerta'] else 'NORMAL Y SEGURO'}")
            print("=" * 76)
            if args.once:
                break
            time.sleep(2)
    except KeyboardInterrupt:
        print("\nMonitor detenido.")

if __name__ == "__main__":
    main()
