import 'package:bshare/src/presentation/localization/app_localizations.dart';

extension CameraViewerLocalizations on AppLocalizations {
  String cameraViewerText(String key) =>
      _values[locale.languageCode]?[key] ?? _values['en']![key] ?? key;
}

const _values = {
  'en': {
    'connecting': 'Connecting to camera…',
    'watching': 'Watching camera',
    'ended': 'Camera transmission ended',
    'failed': 'Could not connect to the camera. Check the phone and try again.',
    'stop': 'Stop',
    'stopping': 'Stopping…',
    'showControls': 'Show camera controls',
  },
  'es': {
    'connecting': 'Conectando con la cámara…',
    'watching': 'Viendo cámara',
    'ended': 'La transmisión de la cámara terminó',
    'failed':
        'No se pudo conectar con la cámara. Revisa el teléfono e inténtalo de nuevo.',
    'stop': 'Detener',
    'stopping': 'Deteniendo…',
    'showControls': 'Mostrar controles de la cámara',
  },
};
