import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';

extension VideoConnectionLocalizations on AppLocalizations {
  String videoConnectionError(ScreenShareState state) {
    final spanish = locale.languageCode == 'es';
    final message = switch (state.failure) {
      VideoConnectionFailure.connectionRefused =>
        spanish
            ? 'El dispositivo rechazó la conexión. Comprueba que siga compartiendo y actualiza la lista de dispositivos.'
            : 'The device refused the connection. Check that it is still sharing and refresh the device list.',
      VideoConnectionFailure.connectionTimeout =>
        spanish
            ? 'El dispositivo no respondió. Revisa que estén en la misma red y que el firewall permita BShare.'
            : 'The device did not respond. Check that both devices are on the same network and the firewall allows BShare.',
      VideoConnectionFailure.network =>
        spanish
            ? 'No se pudo establecer la conexión de video. Revisa el firewall y que la red permita la comunicación entre dispositivos.'
            : 'The video connection could not be established. Check the firewall and whether the network allows devices to communicate.',
      VideoConnectionFailure.video =>
        spanish
            ? 'No se recibió imagen después del reintento. Reinicia la transmisión y prueba una resolución menor en el emisor.'
            : 'No video arrived after retrying. Restart sharing and try a lower resolution on the sender.',
      VideoConnectionFailure.signaling =>
        spanish
            ? 'No se pudo iniciar la transmisión. Comprueba que BShare esté actualizado y compartiendo en el otro dispositivo.'
            : 'The stream could not start. Check that BShare is updated and sharing on the other device.',
      null => state.error ?? '',
    };
    return state.endpoint == null ? message : '$message\n${state.endpoint}';
  }
}
