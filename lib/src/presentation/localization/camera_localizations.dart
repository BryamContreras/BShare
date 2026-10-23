import 'app_localizations.dart';

extension CameraLocalizations on AppLocalizations {
  String cameraText(String key) =>
      _cameraValues[locale.languageCode]?[key] ??
      _cameraValues['en']?[key] ??
      key;
}

const _cameraValues = {
  'en': {
    'deviceCamera': 'Device camera',
    'deviceCameraHelp': 'Share your device camera with a computer.',
    'frontCamera': 'Front camera',
    'backCamera': 'Rear camera',
    'cameraSettings': 'Device camera',
    'cameraSettingsHelp':
        'Configure the rear and front cameras separately. Changes apply the next time you start the camera or switch cameras. Resolution preserves proportions; actual resolution and frame rate depend on camera support and connection. Maximum: 60 FPS.',
    'cameraResolution': 'Resolution',
    'cameraFrameRate': 'Frame rate',
    'camerasUnavailable':
        'Cameras are unavailable. Check camera access and try again.',
  },
  'es': {
    'deviceCamera': 'Cámara del dispositivo',
    'deviceCameraHelp':
        'Comparte la cámara del dispositivo con una computadora.',
    'frontCamera': 'Cámara frontal',
    'backCamera': 'Cámara trasera',
    'cameraSettings': 'Cámara del dispositivo',
    'cameraSettingsHelp':
        'Configura la cámara trasera y la frontal por separado. Los cambios se aplican al iniciar o cambiar la cámara. La resolución conserva las proporciones; la resolución y frecuencia reales dependen de la cámara y la conexión. Máximo: 60 FPS.',
    'cameraResolution': 'Resolución',
    'cameraFrameRate': 'Frecuencia',
    'camerasUnavailable':
        'No se pudo acceder a las cámaras. Revisa el permiso de cámara y vuelve a intentar.',
  },
};
