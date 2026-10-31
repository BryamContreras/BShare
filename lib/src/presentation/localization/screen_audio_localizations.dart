import 'app_localizations.dart';

extension ScreenAudioLocalizations on AppLocalizations {
  String screenAudioText(String key) =>
      _values[locale.languageCode]?[key] ?? _values['en']?[key] ?? key;
}

const _values = {
  'en': {
    'include': 'Share device audio',
    'help':
        'Send sound from videos, games and music, without the microphone. Requires Android 10 or newer; some apps block audio capture.',
    'off': 'Device audio off',
    'active': 'Device audio on',
    'unsupported': 'Device audio is not supported',
    'permissionDenied': 'Audio permission was not granted',
    'unavailable': 'Device audio could not start',
    'videoOnly': 'Screen video continues without device audio.',
    'restricted': 'Apps that block audio capture will remain silent.',
    'androidPermission':
        'Android asks for audio recording permission to share device sound. BShare does not capture the microphone in this mode.',
  },
  'es': {
    'include': 'Compartir sonido del celular',
    'help':
        'Envía el sonido de videos, juegos y música, sin el micrófono. Requiere Android 10 o posterior; algunas apps bloquean la captura de audio.',
    'off': 'Sonido interno desactivado',
    'active': 'Sonido interno activado',
    'unsupported': 'Sonido interno no compatible',
    'permissionDenied': 'No se concedió el permiso de audio',
    'unavailable': 'No se pudo iniciar el sonido interno',
    'videoOnly': 'La pantalla continúa transmitiéndose sin sonido interno.',
    'restricted':
        'Las apps que bloquean la captura de audio permanecerán en silencio.',
    'androidPermission':
        'Android pide permiso de grabación de audio para compartir el sonido del celular. BShare no captura el micrófono en este modo.',
  },
};
