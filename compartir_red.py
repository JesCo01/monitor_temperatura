"""
Servidor de Red Local con Contraseña para compartir monitor_temperatura.zip
Contraseña por defecto: Teo2025
Puerto: 9090
"""

import os
import socket
import urllib.parse
import hashlib
from http.server import HTTPServer, BaseHTTPRequestHandler
from http.cookies import SimpleCookie

PASSWORD = os.environ.get("SHARE_PASSWORD", "Teo2025")
PORT = int(os.environ.get("SHARE_PORT", "9090"))
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ZIP_NAME = "monitor_temperatura.zip"
ZIP_PATH = os.path.join(SCRIPT_DIR, ZIP_NAME)
AUTH_TOKEN = hashlib.sha256(f"teo_salt_{PASSWORD}".encode()).hexdigest()

LOGIN_HTML = """<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Descarga Segura - Red Local</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: #0d1117; color: #c9d1d9;
            display: flex; justify-content: center; align-items: center;
            height: 100vh; margin: 0;
        }
        .box {
            background: #161b22; border: 1px solid #30363d;
            border-radius: 12px; padding: 32px; width: 100%; max-width: 360px;
            box-shadow: 0 8px 24px rgba(0,0,0,0.4); text-align: center;
        }
        h2 { margin-top: 0; color: #fff; }
        input[type="password"] {
            width: 100%; padding: 12px; margin: 14px 0;
            border-radius: 8px; border: 1px solid #30363d;
            background: #0d1117; color: #fff; font-size: 16px;
            box-sizing: border-box;
        }
        button {
            width: 100%; padding: 12px; border: none; border-radius: 8px;
            background: #238636; color: #fff; font-size: 16px; font-weight: 600;
            cursor: pointer;
        }
        button:hover { background: #2ea043; }
        .err { color: #f85149; font-size: 14px; margin-bottom: 10px; }
    </style>
</head>
<body>
    <div class="box">
        <h2>🔒 Acceso Privado</h2>
        <p style="color:#8b949e; font-size:14px;">Ingresa la clave para descargar el Monitor de Temperatura</p>
        {ERROR}
        <form method="POST" action="/login">
            <input type="password" name="password" placeholder="Contraseña" autofocus required>
            <button type="submit">Entrar</button>
        </form>
    </div>
</body>
</html>
"""

DOWNLOAD_HTML = """<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Descargar Monitor de Temperatura</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: #0d1117; color: #c9d1d9;
            display: flex; justify-content: center; align-items: center;
            height: 100vh; margin: 0;
        }
        .box {
            background: #161b22; border: 1px solid #30363d;
            border-radius: 12px; padding: 32px; width: 100%; max-width: 440px;
            box-shadow: 0 8px 24px rgba(0,0,0,0.4); text-align: center;
        }
        h2 { margin-top: 0; color: #fff; }
        .btn {
            display: inline-block; width: 100%; padding: 14px; margin-top: 16px;
            border-radius: 8px; background: #1f6feb; color: #fff;
            text-decoration: none; font-size: 16px; font-weight: 600;
            box-sizing: border-box;
        }
        .btn:hover { background: #388bfd; }
        .info {
            text-align: left; background: #0d1117; border: 1px solid #30363d;
            border-radius: 8px; padding: 14px; margin-top: 20px; font-size: 13px; color: #8b949e;
        }
    </style>
</head>
<body>
    <div class="box">
        <h2>📦 Monitor de Temperatura</h2>
        <p style="color:#8b949e;">Archivo listo para descargar en tu laptop:</p>
        <p style="color:#fff; font-weight:600;">{ZIP_NAME} ({SIZE_MB} MB)</p>
        <a class="btn" href="/download/{ZIP_NAME}">⬇️ Descargar ZIP ahora</a>
        <div class="info">
            <b>Pasos en tu otra laptop:</b><br>
            1. Descarga y descomprime el archivo ZIP.<br>
            2. Abre la carpeta <code>monitor_temperatura</code>.<br>
            3. Haz doble clic en <code>iniciar_monitor.bat</code>.
        </div>
    </div>
</body>
</html>
"""

class ShareHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{self.client_address[0]}] {args[0]}")

    def is_authenticated(self):
        cookie_header = self.headers.get("Cookie", "")
        if cookie_header:
            c = SimpleCookie()
            c.load(cookie_header)
            if "auth" in c and c["auth"].value == AUTH_TOKEN:
                return True
        return False

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            if not self.is_authenticated():
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(LOGIN_HTML.replace("{ERROR}", "").encode("utf-8"))
                return

            size_mb = round(os.path.getsize(ZIP_PATH) / (1024 * 1024), 2) if os.path.exists(ZIP_PATH) else 0
            html = DOWNLOAD_HTML.replace("{ZIP_NAME}", ZIP_NAME).replace("{SIZE_MB}", str(size_mb))
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(html.encode("utf-8"))

        elif self.path == f"/download/{ZIP_NAME}":
            if not self.is_authenticated():
                self.send_response(302)
                self.send_header("Location", "/")
                self.end_headers()
                return

            if not os.path.exists(ZIP_PATH):
                self.send_error(404, "ZIP no encontrado")
                return

            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Disposition", f'attachment; filename="{ZIP_NAME}"')
            self.send_header("Content-Length", str(os.path.getsize(ZIP_PATH)))
            self.end_headers()
            with open(ZIP_PATH, "rb") as f:
                while chunk := f.read(65536):
                    self.wfile.write(chunk)
        else:
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()

    def do_POST(self):
        if self.path == "/login":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8", errors="ignore")
            params = urllib.parse.parse_qs(body)
            pwd = params.get("password", [""])[0]

            if pwd == PASSWORD:
                self.send_response(302)
                self.send_header("Set-Cookie", f"auth={AUTH_TOKEN}; Path=/; HttpOnly")
                self.send_header("Location", "/")
                self.end_headers()
            else:
                self.send_response(401)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                err = '<div class="err">Contraseña incorrecta</div>'
                self.wfile.write(LOGIN_HTML.replace("{ERROR}", err).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

def get_local_ips():
    ips = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127."):
                ips.append(ip)
    except:
        pass
    return list(dict.fromkeys(ips))

if __name__ == "__main__":
    print("=" * 65)
    print("  SERVIDOR DE RED LOCAL ACTIVO")
    print("=" * 65)
    for ip in get_local_ips():
        print(f"  -> Enlace: http://{ip}:{PORT}")
    print(f"  -> Clave : {PASSWORD}")
    print("=" * 65)
    server = HTTPServer(("0.0.0.0", PORT), ShareHandler)
    server.serve_forever()
