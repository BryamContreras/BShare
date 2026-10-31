import 'package:bshare/src/presentation/localization/app_localizations.dart';

extension ScreenViewerLocalizations on AppLocalizations {
  String screenViewerText(String key) =>
      _values[locale.languageCode]?[key] ?? _values['en']![key] ?? key;
}

const _values = {
  'en': {
    'fullscreen': 'Fullscreen',
    'exitFullscreen': 'Exit fullscreen',
    'failed': 'Could not change fullscreen. Please try again.',
  },
  'es': {
    'fullscreen': 'Pantalla completa',
    'exitFullscreen': 'Salir de pantalla completa',
    'failed': 'No se pudo cambiar la pantalla completa. Inténtalo de nuevo.',
  },
};
