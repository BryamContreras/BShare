import 'package:bshare/src/presentation/localization/app_localizations.dart';

extension CameraViewerLocalizations on AppLocalizations {
  String cameraViewerText(String key) =>
      _values[locale.languageCode]?[key] ?? _values['en']![key] ?? key;

  String cameraWhiteBalanceName(String mode) {
    final key = 'whiteBalance-$mode';
    final label = cameraViewerText(key);
    return label == key ? mode.replaceAll('-', ' ') : label;
  }
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
    'controls': 'Camera controls',
    'captureActions': 'Photo and video',
    'preview': 'Preview',
    'previewHelp':
        'Hides only this computer’s preview. The connection, virtual camera and recording keep running.',
    'previewHidden': 'Preview hidden',
    'previewFailed': 'Could not change the preview. Please try again.',
    'photosFolder': 'Photo folder',
    'videosFolder': 'Video folder',
    'chooseFolder': 'Choose folder',
    'preparingFolders': 'Preparing folders…',
    'folderUnavailable': 'Folder unavailable',
    'takePhoto': 'Take photo',
    'takingPhoto': 'Taking photo…',
    'recordVideo': 'Record video',
    'startingRecording': 'Starting recording…',
    'stopRecording': 'Stop recording',
    'recording': 'Recording',
    'savingVideo': 'Saving video…',
    'mediaSaved': 'Saved',
    'mediaFailed':
        'Could not save the photo or video. Check the folder and try again.',
    'folderFailed':
        'Could not change the folder. Choose another folder and try again.',
    'mediaUnsupported':
        'Saving photos and videos is not available on this computer.',
    'mediaNotReady': 'Waiting for camera video…',
    'mirror': 'Mirror',
    'mirrorViewHelp': 'Flip this view horizontally',
    'closeViewer': 'Close viewer',
    'microphone': 'Microphone',
    'microphonePermission':
        'Turn on the microphone on the phone once to grant permission. You can then control it from here.',
    'flash': 'Flash',
    'stopSharing': 'Stop sharing',
    'stopFailed': 'Could not stop sharing. Check the phone and try again.',
    'controlsUnavailable':
        'Update BShare on the phone to control its camera from here.',
    'notConnected': 'Connect to a phone to use its camera controls.',
    'captureUnavailable':
        'Camera adjustments are not available yet. Update BShare on the phone if they remain unavailable.',
    'captureFailed': 'Could not adjust the camera. Please try again.',
    'lens': 'Lens',
    'cameraZoom': 'Camera zoom',
    'cameraZoomHelp':
        'Uses the phone camera. Zoom range and lens switching depend on the device.',
    'zoomUnsupported': 'This camera does not expose adjustable zoom.',
    'whiteBalance': 'White balance',
    'whiteBalanceAuto': 'Automatic white balance',
    'whiteBalanceWarmthHelp':
        'Moving the bar adjusts the camera tone and turns automatic white balance off.',
    'cool': 'Cool',
    'warm': 'Warm',
    'neutral': 'Neutral',
    'whiteBalanceUnsupported':
        'This camera does not expose white balance controls.',
    'whiteBalance-auto': 'Automatic',
    'whiteBalance-incandescent': 'Incandescent',
    'whiteBalance-fluorescent': 'Fluorescent',
    'whiteBalance-warm-fluorescent': 'Warm fluorescent',
    'whiteBalance-daylight': 'Daylight',
    'whiteBalance-cloudy-daylight': 'Cloudy',
    'whiteBalance-twilight': 'Twilight',
    'whiteBalance-shade': 'Shade',
    'brightness': 'Brightness',
    'brightnessEv': 'Brightness (EV compensation)',
    'brightnessEvHelp': 'Adjusts the phone camera’s automatic exposure.',
    'brightnessManualHelp': 'Use automatic exposure to adjust EV compensation.',
    'brightnessUnsupported':
        'This camera does not expose brightness compensation.',
    'exposure': 'Exposure',
    'exposure-auto': 'Automatic',
    'exposure-manual': 'Manual',
    'manualExposureUnsupported':
        'This camera does not expose manual shutter and ISO controls.',
    'shutterTime': 'Shutter time',
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
    'controls': 'Controles de cámara',
    'captureActions': 'Foto y video',
    'preview': 'Previsualización',
    'previewHelp':
        'Oculta solo la previsualización de esta computadora. La conexión, la cámara virtual y la grabación siguen activas.',
    'previewHidden': 'Previsualización oculta',
    'previewFailed':
        'No se pudo cambiar la previsualización. Inténtalo de nuevo.',
    'photosFolder': 'Carpeta de fotos',
    'videosFolder': 'Carpeta de videos',
    'chooseFolder': 'Elegir carpeta',
    'preparingFolders': 'Preparando carpetas…',
    'folderUnavailable': 'Carpeta no disponible',
    'takePhoto': 'Tomar foto',
    'takingPhoto': 'Tomando foto…',
    'recordVideo': 'Grabar video',
    'startingRecording': 'Iniciando grabación…',
    'stopRecording': 'Detener grabación',
    'recording': 'Grabando',
    'savingVideo': 'Guardando video…',
    'mediaSaved': 'Guardado',
    'mediaFailed':
        'No se pudo guardar la foto o el video. Revisa la carpeta e inténtalo de nuevo.',
    'folderFailed':
        'No se pudo cambiar la carpeta. Elige otra carpeta e inténtalo de nuevo.',
    'mediaUnsupported':
        'Guardar fotos y videos no está disponible en esta computadora.',
    'mediaNotReady': 'Esperando el video de la cámara…',
    'mirror': 'Espejo',
    'mirrorViewHelp': 'Voltear horizontalmente la vista',
    'closeViewer': 'Cerrar visor',
    'microphone': 'Micrófono',
    'microphonePermission':
        'Activa el micrófono una vez en el teléfono para darle permiso. Después podrás controlarlo desde aquí.',
    'flash': 'Flash',
    'stopSharing': 'Detener transmisión',
    'stopFailed':
        'No se pudo detener la transmisión. Revisa el teléfono e inténtalo de nuevo.',
    'controlsUnavailable':
        'Actualiza BShare en el teléfono para controlar su cámara desde aquí.',
    'notConnected': 'Conéctate a un teléfono para controlar su cámara.',
    'captureUnavailable':
        'Los ajustes de cámara aún no están disponibles. Actualiza BShare en el teléfono si siguen sin aparecer.',
    'captureFailed': 'No se pudo ajustar la cámara. Inténtalo de nuevo.',
    'lens': 'Lente',
    'cameraZoom': 'Zoom de cámara',
    'cameraZoomHelp':
        'Usa la cámara del teléfono. El rango de zoom y el cambio de lente dependen del dispositivo.',
    'zoomUnsupported': 'Esta cámara no permite ajustar el zoom.',
    'whiteBalance': 'Balance de blancos',
    'whiteBalanceAuto': 'Balance de blancos automático',
    'whiteBalanceWarmthHelp':
        'Al mover la barra se ajusta el tono de la cámara y se desactiva el balance automático.',
    'cool': 'Frío',
    'warm': 'Cálido',
    'neutral': 'Neutro',
    'whiteBalanceUnsupported':
        'Esta cámara no permite ajustar el balance de blancos.',
    'whiteBalance-auto': 'Automático',
    'whiteBalance-incandescent': 'Incandescente',
    'whiteBalance-fluorescent': 'Fluorescente',
    'whiteBalance-warm-fluorescent': 'Fluorescente cálido',
    'whiteBalance-daylight': 'Luz de día',
    'whiteBalance-cloudy-daylight': 'Nublado',
    'whiteBalance-twilight': 'Crepúsculo',
    'whiteBalance-shade': 'Sombra',
    'brightness': 'Brillo',
    'brightnessEv': 'Brillo (compensación EV)',
    'brightnessEvHelp':
        'Ajusta la exposición automática de la cámara del teléfono.',
    'brightnessManualHelp':
        'Activa la exposición automática para ajustar la compensación EV.',
    'brightnessUnsupported': 'Esta cámara no permite compensar el brillo.',
    'exposure': 'Exposición',
    'exposure-auto': 'Automática',
    'exposure-manual': 'Manual',
    'manualExposureUnsupported':
        'Esta cámara no permite ajustar manualmente el obturador y el ISO.',
    'shutterTime': 'Tiempo de obturación',
  },
};
