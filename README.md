# Arranque Limpio

**Español** · [English](README.en.md)

App de barra de menús para macOS que indica:

1. **Si el Mac ha terminado de arrancar** y ningún servicio del sistema da problemas
   (Siri, Time Machine, Spotlight, iCloud, Fotos, XProtect, actualizaciones, WindowServer, Dock/Finder…).
2. **Qué procesos o apps consumen CPU o memoria de forma exagerada**, con opción de cerrarlos.

## Icono en la barra de menús

Es el mismo símbolo que el de la app (botón de encendido) con un pequeño distintivo:

| Distintivo | Significado |
|---|---|
| reloj | Arrancando o terminando tareas de arranque (indexado, sincronización…) |
| ✓ | Arranque terminado, todo en orden |
| ! | Hay avisos (fallos de servicios, cierres inesperados…) |

El **color** indica el consumo según los umbrales de *Ajustes*: monocromo si todo está dentro de los
límites, **naranja** si algún proceso supera el umbral de CPU o memoria (o hay presión de memoria) y
**rojo** si lo duplica o la presión de memoria es crítica.

### Clic derecho: pausar / reanudar

Con clic derecho (o ctrl+clic) sobre el icono aparece un menú para **pausar la monitorización**:
la app sigue en la barra de menús, pero detiene el temporizador y libera el historial, así que no
consume CPU. El icono se atenúa y muestra un distintivo de pausa. Desde el mismo menú se
**reanuda**, se abre el panel o se sale de la app. La pausa se recuerda aunque reinicies el Mac.

## Qué detecta

- **Fase de arranque**: tiempo desde el encendido, carga global y servicios típicos de arranque trabajando.
- **Servicios atascados o inestables**: reinicios en bucle (el proceso cambia de PID una y otra vez),
  fallos/bloqueos y avisos de "uso excesivo de CPU" que macOS registra en `DiagnosticReports`.
- **Time Machine congelado**: copia en curso sin progreso durante más de 15 minutos (`tmutil status`).
- **Consumo exagerado**: CPU media del último minuto por encima del umbral, memoria por encima del
  umbral, o memoria que crece sin parar (posible fuga). Los procesos auxiliares se agrupan con su app, y también las herramientas sin icono que lanza una app del mismo fabricante (p. ej. Claude Code dentro de Claude).
- **Memoria del sistema**: presión de memoria, swap, y procesos cerrados por falta de memoria (Jetsam).
- **Otros**: kernel panic o apagado atascado en el reinicio anterior, apps colgadas, procesos bloqueados en E/S.

Los umbrales (por defecto 80 % de CPU = 0,8 núcleos, y 4 GB de memoria) se cambian en *Ajustes*,
donde también se elige cada cuánto se actualiza (1 s – 1 min, por defecto 3 s) y se activan las
notificaciones y el arranque al iniciar sesión.

## Avisos: detalles y omitir

- **Ver detalles** despliega la información ampliada de cada aviso. Los informes de diagnóstico solo
  se analizan al desplegarlos:
  - *Apagado atascado*: descifra el volcado de `spindump` y lista los procesos que seguían activos,
    marcando los de terceros como probable causa (y avisa si había un disco externo montado).
  - *Cierres y cuelgues*: fecha, tipo de excepción y función donde falló; los repetidos se agrupan (×N).
  - *Falta de memoria (Jetsam)*: qué procesos cerró macOS, por qué y cuál era el que más memoria usaba.
  - *Consumo de CPU/memoria*: los procesos concretos de la app, con PID, CPU y memoria.
  - *Servicios*: informes de CPU excesiva o fallos, reinicios en bucle y sus procesos ahora mismo.
  - Botones para abrir el informe en Consola, verlo completo o mostrarlo en Finder.
- **✕ (omitir)** oculta ese aviso. Si el problema se repite (aparece un informe nuevo, o un consumo
  alto vuelve a darse tras haber desaparecido), el aviso vuelve a mostrarse. Los avisos omitidos no
  cuentan para el color del icono ni generan notificaciones; *Mostrar de nuevo* los recupera.

## Compilar e instalar

Requiere Xcode o las Command Line Tools (Swift 5.9+), macOS 14 o posterior.

```bash
./build.sh            # crea build/Arranque Limpio.app
./build.sh --install  # además la copia a /Applications y la abre
```

Diagnóstico por terminal sin abrir la interfaz:

```bash
"/Applications/Arranque Limpio.app/Contents/MacOS/ArranqueLimpio" --report --details
```

No necesita permisos especiales. Solo puede cerrar procesos de tu usuario; para los del sistema
ofrece copiar el comando `sudo killall …`.

## Licencia

Copyright © 2026 Borja Arias.

Distribuido bajo la [PolyForm Noncommercial License 1.0.0](LICENSE):

- **Uso sin ánimo de lucro: libre.** Puedes usar, modificar y compartir la app para uso personal,
  aficiones, investigación, educación, ONG u organismos públicos.
- **Uso comercial: requiere autorización previa.** Cualquier uso con fines de lucro (venderla,
  integrarla en un producto o servicio, o usarla en una empresa) no está cubierto por esta licencia
  y necesita un acuerdo de licencia comercial con el autor.

Para solicitar una licencia comercial, contacta a través de [github.com/fbamedina](https://github.com/fbamedina).
