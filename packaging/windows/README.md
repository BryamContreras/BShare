# Instalador de Windows

El workflow reutilizable `.github/workflows/build-windows.yml` compila con Flutter
3.44.8 y Visual Studio 2022 sobre `windows-2022`. Genera un instalador Inno Setup
para Windows 10/11 x64, con versión tomada de `pubspec.yaml`.

El instalador incluye el ejecutable, los plugins y sus DLL, los recursos Flutter
y las DLL redistribuibles de Microsoft C++ desde `VC/Redist/MSVC` de Visual Studio.
La instalación es por usuario en `%LOCALAPPDATA%\Programs\BShare`, sin solicitar
permisos de administrador. Crea un acceso en Inicio y ofrece un acceso opcional
en el escritorio. El desinstalador conserva los datos de usuario de la app.

La release publica el `.exe` directamente junto a `SHA256SUMS.txt`, sin un ZIP
intermedio. Actualmente no se aplica firma Authenticode porque el repositorio no
dispone de certificado de firma. No se descarga ni se ejecuta otro instalador de
dependencias al instalar.

La casilla «Permitir conexiones en redes privadas» está desmarcada inicialmente.
Al seleccionarla, Windows pide autorización de administrador para crear reglas
TCP/UDP de entrada limitadas al ejecutable instalado y a la subred local, solo
en redes privadas. La app sigue ejecutándose con el usuario normal. Se conservan
las reglas de bloqueo existentes; si impiden configurar el acceso, el instalador
informa del fallo y lo registra en `network-setup.log`. La desinstalación solicita
autorización para retirar las reglas creadas por esa instalación.

El job instala el EXE en un directorio temporal, compara todo el contenido con
la compilación, abre BShare, comprueba que crea su ventana, la cierra y
desinstala el programa. Los registros se guardan como
`BShare-Windows-verification`. La prueba no valida transmisiones ni transferencias
con otros dispositivos.

El registro `result.json` se escribe también cuando falla la prueba: conserva
la fase alcanzada y el código de salida. La salida de la app y los eventos de
fallos nativos de Windows ayudan a distinguir errores de instalación, inicio
y cierre. El cierre debe finalizar con código `0`.

## Cierre del motor de Windows

La copia local de Flutter WebRTC incluye un adaptador exclusivo de Windows en
`third_party/flutter_webrtc/windows/engine_aware_messenger.h`. Flutter invalida
el motor del messenger antes de destruir los plugins. El adaptador conserva la
referencia nativa y comprueba su disponibilidad antes de registrar o enviar
mensajes. Los canales siguen desregistrándose normalmente mientras el motor
está activo. También se conserva el task runner hasta finalizar la destrucción
de los objetos WebRTC. Las licencias del código de terceros se conservan.

La prueba nativa de `quality` compila el adaptador y el proxy de eventos reales
con una simulación de esa frontera del motor: verifica el desregistro normal,
el cierre con motor invalidado, los eventos pendientes, los bloqueos de hilos
y la liberación de referencias. La instalación y el cierre reales se comprueban
después en el runner de Windows.

## Compilación local

Desde PowerShell 7, con Flutter 3.44.8, Visual Studio 2022 con las herramientas
de C++ e Inno Setup 6 instalados:

```powershell
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub
./packaging/windows/build-installer.ps1
./packaging/windows/smoke-test.ps1
```

El resultado queda en `dist/windows/`. El identificador de instalación de
`installer/windows/BShare.iss` permanece estable entre versiones para permitir
actualizaciones. El instalador crea por defecto un acceso en el menú Inicio y
ofrece una casilla opcional, desactivada inicialmente, para el escritorio. El
script local `scripts/build_releases.ps1` usa este mismo empaquetador y no crea
archivos ZIP.

## Referencias

- [Distribución de Flutter para Windows](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows).
- [Despliegue local del runtime de C++](https://learn.microsoft.com/en-us/cpp/windows/walkthrough-deploying-a-visual-cpp-application-to-an-application-local-folder?view=msvc-170).
- [Herramientas de la imagen Windows Server 2022](https://github.com/actions/runner-images/blob/main/images/windows/Windows2022-Readme.md).
- [Instalación sin elevación en Inno Setup](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm).
- [Disponibilidad y referencias del messenger nativo de Flutter](https://github.com/flutter/flutter/blob/3.44.8/engine/src/flutter/shell/platform/common/public/flutter_messenger.h).
- [Orden de destrucción del motor de Windows en Flutter 3.44.8](https://github.com/flutter/flutter/blob/3.44.8/engine/src/flutter/shell/platform/windows/flutter_windows_engine.cc).
