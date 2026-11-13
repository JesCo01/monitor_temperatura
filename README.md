# 🛡️ Monitor de Temperaturas y Estabilidad del Sistema (Windows)

Monitor ligero, **general y auto-instalable** para supervisar temperaturas y carga de **CPU, GPU (NVIDIA / AMD / Intel), Discos SSD/NVMe y RAM** en cualquier PC, Laptop o Microsoft Surface con Windows 10/11.

Ideal para **trabajo remoto** cuando necesitas vigilar que el equipo no se sobrecaliente ni se cuelgue.

---

## ✨ Características

* **Detección automática de hardware:** Identifica automáticamente tu procesador, placa/modelo de equipo, tarjetas gráficas (dedicadas o integradas) y unidades SSD/NVMe.
* **Auto-instalable:** En la primera ejecución descarga automáticamente `LibreHardwareMonitorLib` (en `lib/`) e instala `psutil` si usas el modo Python. No requiere instaladores pesados.
* **Alertas térmicas:** Pitido de advertencia y aviso visual en rojo si algún componente supera los **85 °C**.
* **Registro continuo:** Guarda el historial en `registro_temperaturas.csv` para revisar picos térmicos.
* **Panel Web incluido:** Consulta el estado desde el navegador (`http://localhost:8080`).

---

## 🚀 Inicio Rápido

```bash
git clone <URL_DE_TU_REPOSITORIO>
cd monitor_temperatura
```

Luego tienes 3 formas de ejecutarlo:

1. **Consola Completa (Recomendado):**  
   Haz doble clic en **`iniciar_monitor.bat`** y acepta el permiso de Administrador (necesario en Windows para leer los sensores internos de núcleos de la CPU).
2. **Modo Normal (Sin permiso de Admin):**  
   Haz doble clic en **`iniciar_modo_normal.bat`** para ver GPU, carga de CPU y RAM sin ventanas UAC.
3. **Panel Web Visual:**  
   Haz doble clic en **`iniciar_servidor_web.bat`** y abre `http://localhost:8080` en tu navegador.
