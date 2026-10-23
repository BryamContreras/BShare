import 'app_localizations.dart';

extension CameraBroadcastLocalizations on AppLocalizations {
  String cameraBroadcastText(String key) =>
      _values[locale.languageCode]?[key] ?? _values['en']?[key] ?? key;
}

const _values = {
  'en': {
    'hidePreview': 'Hide preview',
    'showPreview': 'Show preview',
    'previewHidden': 'Preview hidden',
    'sharingContinues': 'Your camera is still being shared.',
    'cameraStopped': 'Camera sharing has ended',
    'returnToCamera': 'Return to Device camera',
    'stopFailed': 'Could not stop the camera. Please try again.',
    'enableFlash': 'Turn flash on',
    'disableFlash': 'Turn flash off',
    'flashUnavailable': 'Flash unavailable for this camera',
    'enableMicrophone': 'Turn microphone on',
    'disableMicrophone': 'Turn microphone off',
  },
  'es': {
    'hidePreview': 'Ocultar vista previa',
    'showPreview': 'Mostrar vista previa',
    'previewHidden': 'Vista previa oculta',
    'sharingContinues': 'La cámara continúa transmitiendo.',
    'cameraStopped': 'La transmisión de la cámara finalizó',
    'returnToCamera': 'Volver a Cámara del dispositivo',
    'stopFailed': 'No se pudo detener la cámara. Inténtalo de nuevo.',
    'enableFlash': 'Activar flash',
    'disableFlash': 'Desactivar flash',
    'flashUnavailable': 'Flash no disponible en esta cámara',
    'enableMicrophone': 'Activar micrófono',
    'disableMicrophone': 'Desactivar micrófono',
  },
};
