import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppLocalizations {
  const AppLocalizations(this.locale);

  final Locale locale;

  static const supportedLocales = [Locale('en'), Locale('es')];
  static const delegate = _AppLocalizationsDelegate();

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  String t(String key) {
    return _values[locale.languageCode]?[key] ?? _values['en']![key] ?? key;
  }

  String transferStatus(TransferProgressStatus status, {String? message}) {
    final label = t('transferStatus.${status.name}');
    final detail = message?.trim();
    if (status == TransferProgressStatus.failed &&
        detail != null &&
        detail.isNotEmpty) {
      return '$label: $detail';
    }
    return label;
  }

  String screenStatus(String status) {
    final key = 'screenStatus.$status';
    final translated = t(key);
    return translated == key ? status : translated;
  }

  static const _values = {
    'en': {
      'home': 'Home',
      'send': 'Send',
      'receive': 'Receive',
      'transfers': 'Transfers',
      'transfersCompact': 'Transfers',
      'screen': 'Screen',
      'settings': 'Settings',
      'back': 'Back',
      'history': 'History',
      'connectedToLan': 'Connected to LAN',
      'noNetworkDetected': 'No network detected',
      'checkingLan': 'Checking LAN...',
      'networkUnavailable': 'Network status unavailable',
      'unknownNetwork': 'Unknown network',
      'sendSubtitle': 'Select files and send them to nearby devices.',
      'receiveSubtitle': 'Make this device visible and accept incoming files.',
      'screenSubtitle': 'Share or watch a screen in real time.',
      'settingsUnavailable': 'Settings unavailable',
      'settingsDeviceSection': 'Device',
      'settingsAppearanceSection': 'Appearance',
      'deviceName': 'Device name',
      'preferredPort': 'Preferred port',
      'preferredPortHelp':
          'Used the next time you start Receive. If busy, the next available port is used.',
      'automaticReceive': 'Automatic receive',
      'automaticReceiveHelp': 'Accept files without prompting.',
      'theme': 'Theme',
      'system': 'System',
      'light': 'Light',
      'dark': 'Dark',
      'language': 'Language',
      'english': 'English',
      'spanish': 'Spanish',
      'downloadFolder': 'Download folder',
      'chooseFolder': 'Choose folder',
      'saveSettings': 'Save settings',
      'clearHistory': 'Clear history',
      'settingsSaved': 'Settings saved',
      'settingsSaveFailed': 'Could not save settings. Please try again.',
      'screenCaptureSettings': 'Screen sharing',
      'screenResolution': 'Resolution',
      'screenNativeResolution': 'Original resolution',
      'screenFrameRate': 'Frame rate',
      'screenCaptureSettingsHelp':
          'Applies to the next stream. Resolution limits the shorter edge and preserves the screen proportions. Higher values use more battery and network capacity; actual frame rate depends on the device and connection.',
      'screenStartFailed':
          'Could not start screen sharing. Check permissions and your connection, then try again.',
      'targetDevice': 'Target device',
      'refreshDevices': 'Refresh devices',
      'searchingNearbyDevices': 'Searching for nearby devices',
      'discoveryPreparing': 'Preparing device search',
      'discoveryEmpty': 'No devices found yet',
      'discoveryFoundOne': '1 device available',
      'discoveryFoundMany': '{count} devices available',
      'savedDeviceNotDetected':
          'Saved destination; not detected on this network yet.',
      'discoveryFailed': 'Could not search for devices',
      'discoveryFailedHelp':
          'Check your local network connection (Wi-Fi or Ethernet), then refresh to try again.',
      'discoveryAutomaticHelp':
          'Open Receive on the other device and use the same local network (Wi-Fi or Ethernet). If you change networks, tap Refresh.',
      'scanDirectQr': 'Scan direct QR',
      'scanQr': 'Scan QR',
      'pointCameraAtQr': 'Point the camera at the BShare QR code',
      'connectingDirectNetwork': 'Connecting to the BShare network...',
      'turnOnWifiToConnect': 'Turn on Wi-Fi, then return to BShare.',
      'openingWifiSettings': 'Opening Wi-Fi connection...',
      'waitingForDirectNetwork': 'Join the BShare network, then return here.',
      'directWifiManualHelp':
          'Android did not connect automatically. Open Wi-Fi, join the BShare network, then return to BShare.',
      'openWifi': 'Open Wi-Fi',
      'retryScan': 'Scan again',
      'invalidBShareQr': 'This is not a valid BShare QR code',
      'cameraPermissionTitle': 'Camera access needed',
      'cameraUnavailableTitle': 'Camera unavailable',
      'cameraUnavailableHelp':
          'Check camera permission and close other apps using the camera, then try again.',
      'openAppSettings': 'Open settings',
      'files': 'Files',
      'clearSelectedFiles': 'Clear selected files',
      'noFilesSelected': 'No files selected',
      'removeFile': 'Remove file',
      'sending': 'Sending',
      'clearCompletedTransfers': 'Clear completed transfers',
      'resume': 'Resume',
      'pause': 'Pause',
      'cancel': 'Cancel',
      'app': 'App',
      'apps': 'Apps',
      'file': 'File',
      'media': 'Media',
      'folder': 'Folder',
      'albums': 'Albums',
      'recent': 'Recent',
      'addSelected': 'Add selected',
      'noMediaFound': 'No photos or videos found',
      'mediaLoadFailed': 'Could not load your photos and videos',
      'mediaSelectionFailed': 'Could not prepare the selected media',
      'mediaPermissionTitle': 'Photo access needed',
      'mediaPermissionBody':
          'Allow BShare to show your photos and videos by album.',
      'openSettings': 'Open settings',
      'retry': 'Retry',
      'deviceVisible': 'Device visible',
      'receiverStopped': 'Receiver stopped',
      'port': 'Port',
      'savingTo': 'Saving to',
      'startReceiver': 'Start receiver',
      'stop': 'Stop',
      'directNetworkReady': 'BShare network ready',
      'scanToSendDirect':
          'Scan this code from Send to connect and send directly.',
      'temporaryNetwork': 'Temporary network',
      'password': 'Password',
      'transferProgress': 'Transfer progress',
      'noActiveTransfers': 'No active transfers',
      'pendingTransfers': 'Waiting for your approval',
      'outgoingTransfers': 'Outgoing',
      'incomingTransfers': 'Incoming',
      'receiverBusy':
          'The receiver stays on while incoming transfers are pending or active.',
      'openBShareFolder': 'Open BShare folder',
      'from': 'From',
      'accept': 'Accept',
      'reject': 'Reject',
      'transferHistory': 'Transfer history',
      'noTransfersYet': 'No transfers yet',
      'devices': 'Devices',
      'availableDevices': 'Available devices',
      'refresh': 'Refresh',
      'searchingLocalNetwork': 'Searching on the local network...',
      'shareScreen': 'Share screen',
      'watch': 'Watch',
      'yourScreen': 'Your screen',
      'remoteScreen': 'Remote screen',
      'openFocusedViewer': 'Open focused viewer',
      'openFullscreen': 'Open fullscreen',
      'searchingLan': 'Searching on LAN',
      'screenSharingMobile': 'Your screen is being shared',
      'closeViewer': 'Close viewer',
      'senderDisconnected': 'The sender has disconnected.',
      'scrollToTop': 'Back to top',
      'addSelectedApps': 'Add selected apps',
      'appsLoadFailed': 'Could not load apps',
      'searchApps': 'Search apps',
      'noAppsFound': 'No apps found',
      'storage': 'Storage',
      'openFolderFailed': 'Could not open this folder',
      'storagePermissionRequired':
          'Allow access to files to use this folder or receive files. Camera and screen sharing do not need this permission.',
      'storageAccessFailed':
          'Could not access the selected folder. Check its permissions and try again.',
      'receiverStartFailed':
          'Could not start receiving. Check permissions and your connection, then try again.',
      'videoReceiverOnly':
          'File reception is off. Start receiving to allow files.',
      'goUp': 'Go up',
      'selectThisFolder': 'Select this folder',
      'transferStatus.queued': 'Queued',
      'transferStatus.sending': 'Sending',
      'transferStatus.receiving': 'Receiving',
      'transferStatus.paused': 'Paused',
      'transferStatus.cancelled': 'Cancelled',
      'transferStatus.completed': 'Completed',
      'transferStatus.failed': 'Failed',
      'screenStatus.Idle': 'Idle',
      'screenStatus.Opening viewer...': 'Opening viewer...',
      'screenStatus.Starting screen capture...': 'Starting screen capture...',
      'screenStatus.Sharing screen on LAN': 'Sharing screen on LAN',
      'screenStatus.Screen share stopped': 'Screen share stopped',
      'screenStatus.Screen share ended': 'Screen share ended',
      'screenStatus.Connecting to screen share...':
          'Connecting to screen share...',
      'screenStatus.Watching remote screen': 'Watching remote screen',
      'screenStatus.Could not connect': 'Could not connect',
      'screenStatus.Retrying compatible video...': 'Retrying compatible video…',
      'screenStatus.Connecting to camera share...': 'Connecting to camera…',
      'screenStatus.Watching remote camera': 'Watching camera',
    },
    'es': {
      'home': 'Inicio',
      'send': 'Enviar',
      'receive': 'Recibir',
      'transfers': 'Transferencias',
      'transfersCompact': 'Actividad',
      'screen': 'Pantalla',
      'settings': 'Ajustes',
      'back': 'Volver',
      'history': 'Historial',
      'connectedToLan': 'Conectado a la LAN',
      'noNetworkDetected': 'No se detectó red',
      'checkingLan': 'Revisando LAN...',
      'networkUnavailable': 'Estado de red no disponible',
      'unknownNetwork': 'Red desconocida',
      'sendSubtitle': 'Selecciona archivos y envíalos a dispositivos cercanos.',
      'receiveSubtitle':
          'Haz visible este dispositivo y acepta archivos entrantes.',
      'screenSubtitle': 'Comparte o mira una pantalla en tiempo real.',
      'settingsUnavailable': 'Ajustes no disponibles',
      'settingsDeviceSection': 'Dispositivo',
      'settingsAppearanceSection': 'Apariencia',
      'deviceName': 'Nombre del dispositivo',
      'preferredPort': 'Puerto preferido',
      'preferredPortHelp':
          'Se usará la próxima vez que actives Recibir. Si está ocupado, se usará el siguiente disponible.',
      'automaticReceive': 'Recepción automática',
      'automaticReceiveHelp': 'Aceptar archivos sin preguntar.',
      'theme': 'Tema',
      'system': 'Sistema',
      'light': 'Claro',
      'dark': 'Oscuro',
      'language': 'Idioma',
      'english': 'Inglés',
      'spanish': 'Español',
      'downloadFolder': 'Carpeta de descarga',
      'chooseFolder': 'Elegir carpeta',
      'saveSettings': 'Guardar ajustes',
      'clearHistory': 'Borrar historial',
      'settingsSaved': 'Ajustes guardados',
      'settingsSaveFailed':
          'No se pudieron guardar los ajustes. Vuelve a intentar.',
      'screenCaptureSettings': 'Compartir pantalla',
      'screenResolution': 'Resolución',
      'screenNativeResolution': 'Resolución original',
      'screenFrameRate': 'Frecuencia de cuadros',
      'screenCaptureSettingsHelp':
          'Se aplica a la próxima transmisión. La resolución limita el lado corto y conserva las proporciones de la pantalla. Los valores altos consumen más batería y red; la frecuencia real depende del dispositivo y la conexión.',
      'screenStartFailed':
          'No se pudo compartir la pantalla. Revisa los permisos y la conexión y vuelve a intentar.',
      'targetDevice': 'Dispositivo destino',
      'refreshDevices': 'Actualizar dispositivos',
      'searchingNearbyDevices': 'Buscando dispositivos cercanos',
      'discoveryPreparing': 'Preparando búsqueda de dispositivos',
      'discoveryEmpty': 'Aún no se encontraron dispositivos',
      'discoveryFoundOne': '1 dispositivo disponible',
      'discoveryFoundMany': '{count} dispositivos disponibles',
      'savedDeviceNotDetected':
          'Destino guardado; aún no detectado en esta red.',
      'discoveryFailed': 'No se pudieron buscar dispositivos',
      'discoveryFailedHelp':
          'Revisa la conexión a la red local (Wi-Fi o Ethernet) y pulsa actualizar para volver a intentar.',
      'discoveryAutomaticHelp':
          'Abre Recibir en el otro dispositivo y usa la misma red local (Wi-Fi o Ethernet). Si cambias de red, pulsa Actualizar.',
      'scanDirectQr': 'Escanear QR directo',
      'scanQr': 'Escanear QR',
      'pointCameraAtQr': 'Apunta la cámara al código QR de BShare',
      'connectingDirectNetwork': 'Conectando a la red BShare...',
      'turnOnWifiToConnect': 'Activa Wi-Fi y vuelve a BShare.',
      'openingWifiSettings': 'Abriendo conexión Wi-Fi...',
      'waitingForDirectNetwork': 'Únete a la red BShare y vuelve aquí.',
      'directWifiManualHelp':
          'Android no conectó automáticamente. Abre Wi-Fi, únete a la red BShare y vuelve a BShare.',
      'openWifi': 'Abrir Wi-Fi',
      'retryScan': 'Escanear otra vez',
      'invalidBShareQr': 'Este no es un código QR válido de BShare',
      'cameraPermissionTitle': 'Se necesita acceso a la cámara',
      'cameraUnavailableTitle': 'Cámara no disponible',
      'cameraUnavailableHelp':
          'Revisa el permiso de cámara y cierra otras apps que la estén usando. Luego vuelve a intentar.',
      'openAppSettings': 'Abrir ajustes',
      'files': 'Archivos',
      'clearSelectedFiles': 'Limpiar archivos seleccionados',
      'noFilesSelected': 'No hay archivos seleccionados',
      'removeFile': 'Quitar archivo',
      'sending': 'Enviando',
      'clearCompletedTransfers': 'Limpiar transferencias completadas',
      'resume': 'Reanudar',
      'pause': 'Pausar',
      'cancel': 'Cancelar',
      'app': 'App',
      'apps': 'Apps',
      'file': 'Archivo',
      'media': 'Media',
      'folder': 'Carpeta',
      'albums': 'Álbumes',
      'recent': 'Recientes',
      'addSelected': 'Agregar seleccionados',
      'noMediaFound': 'No se encontraron fotos o videos',
      'mediaLoadFailed': 'No se pudieron cargar tus fotos y videos',
      'mediaSelectionFailed':
          'No se pudieron preparar los medios seleccionados',
      'mediaPermissionTitle': 'Se necesita acceso a fotos',
      'mediaPermissionBody':
          'Permite que BShare muestre tus fotos y videos por álbum.',
      'openSettings': 'Abrir ajustes',
      'retry': 'Reintentar',
      'deviceVisible': 'Dispositivo visible',
      'receiverStopped': 'Receptor detenido',
      'port': 'Puerto',
      'savingTo': 'Guardando en',
      'startReceiver': 'Iniciar receptor',
      'stop': 'Detener',
      'directNetworkReady': 'Red BShare lista',
      'scanToSendDirect':
          'Escanea este código desde Enviar para conectar y enviar directo.',
      'temporaryNetwork': 'Red temporal',
      'password': 'Contraseña',
      'transferProgress': 'Progreso de transferencia',
      'noActiveTransfers': 'No hay transferencias activas',
      'pendingTransfers': 'Esperando tu aprobación',
      'outgoingTransfers': 'Salientes',
      'incomingTransfers': 'Entrantes',
      'receiverBusy':
          'El receptor se mantiene encendido mientras haya transferencias entrantes pendientes o activas.',
      'openBShareFolder': 'Abrir carpeta BShare',
      'from': 'De',
      'accept': 'Aceptar',
      'reject': 'Rechazar',
      'transferHistory': 'Historial de transferencias',
      'noTransfersYet': 'Aún no hay transferencias',
      'devices': 'Dispositivos',
      'availableDevices': 'Dispositivos disponibles',
      'refresh': 'Actualizar',
      'searchingLocalNetwork': 'Buscando en la red local...',
      'shareScreen': 'Compartir pantalla',
      'watch': 'Ver',
      'yourScreen': 'Tu pantalla',
      'remoteScreen': 'Pantalla remota',
      'openFocusedViewer': 'Abrir visor enfocado',
      'openFullscreen': 'Abrir pantalla completa',
      'searchingLan': 'Buscando en LAN',
      'screenSharingMobile': 'Se está compartiendo tu pantalla',
      'closeViewer': 'Cerrar visor',
      'senderDisconnected': 'El emisor se ha desconectado.',
      'scrollToTop': 'Volver arriba',
      'addSelectedApps': 'Agregar apps seleccionadas',
      'appsLoadFailed': 'No se pudieron cargar las apps',
      'searchApps': 'Buscar apps',
      'noAppsFound': 'No se encontraron apps',
      'storage': 'Almacenamiento',
      'openFolderFailed': 'No se pudo abrir esta carpeta',
      'storagePermissionRequired':
          'Permite el acceso a archivos para usar esta carpeta o recibir archivos. Compartir cámara y pantalla no necesita este permiso.',
      'storageAccessFailed':
          'No se pudo acceder a la carpeta seleccionada. Revisa sus permisos e inténtalo de nuevo.',
      'receiverStartFailed':
          'No se pudo iniciar la recepción. Revisa los permisos y la conexión e inténtalo de nuevo.',
      'videoReceiverOnly':
          'La recepción de archivos está desactivada. Iníciala para recibir archivos.',
      'goUp': 'Subir',
      'selectThisFolder': 'Seleccionar esta carpeta',
      'transferStatus.queued': 'En cola',
      'transferStatus.sending': 'Enviando',
      'transferStatus.receiving': 'Recibiendo',
      'transferStatus.paused': 'Pausado',
      'transferStatus.cancelled': 'Cancelado',
      'transferStatus.completed': 'Completado',
      'transferStatus.failed': 'Falló',
      'screenStatus.Idle': 'Inactivo',
      'screenStatus.Opening viewer...': 'Abriendo visor...',
      'screenStatus.Starting screen capture...':
          'Iniciando captura de pantalla...',
      'screenStatus.Sharing screen on LAN': 'Compartiendo pantalla en LAN',
      'screenStatus.Screen share stopped': 'Pantalla compartida detenida',
      'screenStatus.Screen share ended': 'La transmisión ha finalizado',
      'screenStatus.Connecting to screen share...':
          'Conectando a la pantalla compartida...',
      'screenStatus.Watching remote screen': 'Viendo pantalla remota',
      'screenStatus.Could not connect': 'No se pudo conectar',
      'screenStatus.Retrying compatible video...':
          'Reintentando con video compatible…',
      'screenStatus.Connecting to camera share...': 'Conectando con la cámara…',
      'screenStatus.Watching remote camera': 'Viendo cámara',
    },
  };
}

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales.any(
      (supported) => supported.languageCode == locale.languageCode,
    );
  }

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture(AppLocalizations(locale));
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
