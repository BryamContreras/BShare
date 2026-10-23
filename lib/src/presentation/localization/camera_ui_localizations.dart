import 'package:bshare/src/presentation/localization/app_localizations.dart';

extension CameraUiLocalizations on AppLocalizations {
  String cameraUiText(String key) =>
      _cameraUiValues[locale.languageCode]?[key] ??
      _cameraUiValues['en']![key] ??
      key;
}

const _cameraUiValues = {
  'en': {
    'wifi': 'Wi-Fi',
    'usb': 'USB',
    'wifiHelp':
        'Connect the phone and computer to the same Wi-Fi network. Start the camera on the phone, then choose it here on the computer.',
    'usbHelp':
        'Connect a data cable and enable USB tethering on the phone. On the computer, enter the USB address and port shown on the phone. Video uses the cable network.',
    'usbUnavailable':
        'No USB network detected. Connect the cable and enable USB tethering.',
    'usbAddress': 'USB address',
    'openUsbSettings': 'Open USB tethering',
    'host': 'Phone address',
    'port': 'Port',
    'invalidAddress': 'Enter a valid IP address and port (1–65535).',
    'camera': 'Camera',
    'shareCamera': 'Share camera',
    'watchCamera': 'Watch camera',
    'openBroadcast': 'Open broadcast',
    'openViewer': 'Open viewer',
    'switchCamera': 'Switch camera',
    'cameraReady': 'Camera ready',
    'cameraSharing': 'Sharing camera',
    'cameraWatching': 'Watching camera',
    'cameraBusy': 'Another video session is active',
    'qrCameraBusyTitle': 'Camera in use',
    'qrCameraBusyHelp':
        'Stop sharing from Device camera before scanning a QR code.',
    'openCamera': 'Open Device camera',
    'openScreenSession': 'Open screen sharing',
    'cameraFailed':
        'Could not start the camera. Check camera permission and the connection, then try again.',
    'cameraSwitchFailed': 'Could not switch cameras. Please try again.',
    'cameraMicrophoneFailed':
        'Could not change the microphone. Check microphone permission and try again.',
    'cameraTorchFailed': 'Could not change the flash. Please try again.',
    'watchFailed':
        'Could not connect to the camera. Start sharing on the phone and check the selected connection.',
    'awakeHelp':
        'The microphone starts off; turn it on to share audio with video. The phone stays awake while sharing. After one minute without interaction the display darkens; tap to wake it.',
    'tapToWake': 'Tap to show camera controls',
    'cameraPreview': 'Camera preview',
    'chooseDevice': 'Choose a phone that is sharing its camera.',
    'settings': 'Camera settings',
    'stop': 'Stop',
    'retry': 'Try again',
  },
  'es': {
    'wifi': 'Wi-Fi',
    'usb': 'USB',
    'wifiHelp':
        'Conecta el teléfono y la computadora a la misma red Wi-Fi. Inicia la cámara en el teléfono y luego selecciónalo aquí en la computadora.',
    'usbHelp':
        'Conecta un cable de datos y activa el anclaje a red USB en el teléfono. En la computadora, ingresa la dirección USB y el puerto que muestra el teléfono. El video usa la red del cable.',
    'usbUnavailable':
        'No se detectó una red USB. Conecta el cable y activa el anclaje a red USB.',
    'usbAddress': 'Dirección USB',
    'openUsbSettings': 'Abrir anclaje a red USB',
    'host': 'Dirección del teléfono',
    'port': 'Puerto',
    'invalidAddress': 'Ingresa una dirección IP y un puerto válido (1–65535).',
    'camera': 'Cámara',
    'shareCamera': 'Compartir cámara',
    'watchCamera': 'Ver cámara',
    'openBroadcast': 'Abrir transmisión',
    'openViewer': 'Abrir visor',
    'switchCamera': 'Cambiar cámara',
    'cameraReady': 'Cámara lista',
    'cameraSharing': 'Compartiendo cámara',
    'cameraWatching': 'Viendo cámara',
    'cameraBusy': 'Hay otra sesión de video activa',
    'qrCameraBusyTitle': 'Cámara en uso',
    'qrCameraBusyHelp':
        'Detén la transmisión desde Cámara del dispositivo antes de escanear un código QR.',
    'openCamera': 'Abrir Cámara del dispositivo',
    'openScreenSession': 'Abrir compartir pantalla',
    'cameraFailed':
        'No se pudo iniciar la cámara. Revisa el permiso de cámara y la conexión e inténtalo de nuevo.',
    'cameraSwitchFailed': 'No se pudo cambiar de cámara. Inténtalo de nuevo.',
    'cameraMicrophoneFailed':
        'No se pudo cambiar el micrófono. Revisa el permiso de micrófono e inténtalo de nuevo.',
    'cameraTorchFailed': 'No se pudo cambiar el flash. Inténtalo de nuevo.',
    'watchFailed':
        'No se pudo conectar con la cámara. Inicia la transmisión en el teléfono y revisa la conexión seleccionada.',
    'awakeHelp':
        'El micrófono inicia desactivado; actívalo para compartir audio con el video. El teléfono permanece activo al compartir. Después de un minuto sin interacción, la pantalla se oscurece; tócala para mostrarla.',
    'tapToWake': 'Toca para mostrar los controles de la cámara',
    'cameraPreview': 'Vista previa de la cámara',
    'chooseDevice': 'Elige un teléfono que esté compartiendo su cámara.',
    'settings': 'Ajustes de cámara',
    'stop': 'Detener',
    'retry': 'Reintentar',
  },
};
