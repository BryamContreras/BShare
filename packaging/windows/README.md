# Instalador de Windows

El workflow reutilizable `.github/workflows/build-windows.yml` compila con Flutter
3.44.8 y Visual Studio 2022 sobre `windows-2022`. Genera un instalador Inno Setup
para Windows 10/11 x64, con versión tomada de `pubspec.yaml`.

El instalador incluye el ejecutable, los plugins y sus DLL, los recursos Flutter
y las DLL redistribuibles de Microsoft C++ desde `VC/Redist/MSVC` de Visual Studio.
La instalación es por usuario en `%LOCALAPPDATA%\Programs\BShare`, sin solicitar
permisos de administrador. Crea un acceso en Inicio y ofrece un acceso opcional
en el escritorio. El desinstalador conserva los datos de usuario de la app.

El artefacto `BShare-Windows-x64` contiene el `.exe` y su SHA-256. Actualmente no
se aplica firma Authenticode porque el repositorio no dispone de certificado de
firma. No se descarga ni se ejecuta otro instalador de dependencias al instalar.

El job instala el EXE en un directorio temporal, compara todo el contenido con
la compilación, abre BShare, comprueba que crea su ventana, la cierra y
desinstala el programa. Los registros se guardan como
`BShare-Windows-verification`. La prueba no valida transmisiones ni transferencias
con otros dispositivos.

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
actualizaciones. El script local `scripts/build_releases.ps1` usa este mismo
empaquetador para Windows y añade un ZIP portátil con el mismo runtime.

## Referencias

- [Distribución de Flutter para Windows](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows).
- [Despliegue local del runtime de C++](https://learn.microsoft.com/en-us/cpp/windows/walkthrough-deploying-a-visual-cpp-application-to-an-application-local-folder?view=msvc-170).
- [Herramientas de la imagen Windows Server 2022](https://github.com/actions/runner-images/blob/main/images/windows/Windows2022-Readme.md).
- [Instalación sin elevación en Inno Setup](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm).
