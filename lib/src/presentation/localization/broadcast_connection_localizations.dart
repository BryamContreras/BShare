import 'app_localizations.dart';

extension BroadcastConnectionLocalizations on AppLocalizations {
  String broadcastConnectionText(String key) =>
      _values[locale.languageCode]?[key] ?? _values['en']?[key] ?? key;
}

const _values = {
  'en': {
    'address': 'IP and port',
    'loading': 'Looking up the broadcast address…',
    'unavailable': 'No broadcast address is available.',
    'copy': 'Copy IP and port',
    'copied': 'Address copied',
  },
  'es': {
    'address': 'IP y puerto',
    'loading': 'Buscando la dirección de transmisión…',
    'unavailable': 'No hay una dirección de transmisión disponible.',
    'copy': 'Copiar IP y puerto',
    'copied': 'Dirección copiada',
  },
};
