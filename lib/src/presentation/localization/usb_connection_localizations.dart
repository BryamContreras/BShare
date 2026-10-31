import 'package:bshare/src/presentation/localization/app_localizations.dart';

extension UsbConnectionLocalizations on AppLocalizations {
  String usbConnectionText(String key) =>
      _usbValues[locale.languageCode]?[key] ?? _usbValues['en']![key] ?? key;
}

const _usbValues = {
  'en': {
    'device': 'Phone connected by USB',
    'refresh': 'Refresh USB devices',
    'loading': 'Looking for USB devices…',
    'empty': 'No Android phone detected by USB.',
    'ready': 'Ready',
    'unauthorized':
        'Unlock the phone and allow USB debugging for this computer.',
    'offline': 'Device offline. Reconnect the USB cable and try again.',
    'unavailable':
        'Could not read USB devices. Check the cable and ADB connection, then refresh.',
    'adbMissing':
        'ADB was not found. Install Android SDK Platform Tools (ADB), check its path, and try again.',
    'androidOnly':
        'USB sharing requires an Android phone. Use Wi-Fi / LAN with iOS.',
    'phoneHelp':
        'Connect a USB data cable, enable USB debugging in Developer options, and authorize this computer on the phone. Start sharing here, then select the phone in BShare on the computer.',
    'computerHelp':
        'Connect the Android phone with a USB data cable, enable USB debugging, and authorize this computer. Start sharing in BShare on the phone, then select it below.',
    'port': 'BShare port on the phone',
    'portHelp': 'Use 53317 unless you changed the port in BShare on the phone.',
    'invalidPort': 'Enter a valid BShare port (1–65535).',
    'watchFailed':
        'Could not connect over USB. Check authorization, the BShare port, and that the phone is sharing.',
    'active': 'Sharing over USB',
    'connecting': 'Connecting over USB…',
  },
  'es': {
    'device': 'Teléfono conectado por USB',
    'refresh': 'Actualizar dispositivos USB',
    'loading': 'Buscando dispositivos USB…',
    'empty': 'No se detectó un teléfono Android por USB.',
    'ready': 'Listo',
    'unauthorized':
        'Desbloquea el teléfono y permite la depuración USB para esta computadora.',
    'offline':
        'Dispositivo desconectado. Vuelve a conectar el cable USB e inténtalo de nuevo.',
    'unavailable':
        'No se pudieron leer los dispositivos USB. Revisa el cable y la conexión ADB y actualiza la lista.',
    'adbMissing':
        'No se encontró ADB. Instala Android SDK Platform Tools (ADB), revisa su ruta e inténtalo de nuevo.',
    'androidOnly':
        'La transmisión por USB requiere un teléfono Android. Usa Wi-Fi / LAN con iOS.',
    'phoneHelp':
        'Conecta un cable USB de datos, activa la depuración USB en Opciones de desarrollador y autoriza esta computadora en el teléfono. Inicia la transmisión aquí y selecciona el teléfono en BShare de la computadora.',
    'computerHelp':
        'Conecta el teléfono Android con un cable USB de datos, activa la depuración USB y autoriza esta computadora. Inicia la transmisión en BShare del teléfono y selecciónalo abajo.',
    'port': 'Puerto de BShare en el teléfono',
    'portHelp':
        'Usa 53317 salvo que hayas cambiado el puerto en BShare del teléfono.',
    'invalidPort': 'Ingresa un puerto de BShare válido (1–65535).',
    'watchFailed':
        'No se pudo conectar por USB. Revisa la autorización, el puerto de BShare y que el teléfono esté transmitiendo.',
    'active': 'Transmitiendo por USB',
    'connecting': 'Conectando por USB…',
  },
};
