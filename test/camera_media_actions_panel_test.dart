import 'dart:io';

import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/camera_media_actions_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'folder picker opens an existing ancestor without creating the destination',
    () async {
      final root = await Directory.systemTemp.createTemp('bshare-picker-');
      try {
        final destination = p.join(root.path, 'Pictures', 'BShare');
        expect(await cameraMediaPickerDirectory(destination), root.path);
        expect(await Directory(destination).exists(), isFalse);
        expect(await cameraMediaPickerDirectory('relative-path'), isNull);
        expect(await cameraMediaPickerDirectory(null), isNull);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  Future<void> mount(
    WidgetTester tester,
    CameraMediaActionsPanel panel, {
    TextScaler? scaler,
    bool reducedMotion = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: scaler, disableAnimations: reducedMotion),
          child: child!,
        ),
        home: Scaffold(body: SizedBox(width: 260, child: panel)),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'preview is first and directory choices stay separate from capture actions',
    (tester) async {
      var photos = 0;
      var videos = 0;
      var snapshots = 0;
      var recordings = 0;
      bool? preview;
      await mount(
        tester,
        CameraMediaActionsPanel(
          previewEnabled: true,
          streamReady: true,
          photoDirectory: '/Pictures/BShare',
          videoDirectory: '/Movies/BShare',
          onPreviewChanged: (value) => preview = value,
          onChoosePhotoFolder: () => photos++,
          onChooseVideoFolder: () => videos++,
          onTakePhoto: () => snapshots++,
          onToggleRecording: () => recordings++,
        ),
      );
      final toggle = find.byKey(const ValueKey('camera-viewer-preview'));
      final photo = find.byKey(const ValueKey('camera-take-photo'));
      final photoPath = find.byKey(const ValueKey('camera-photo-directory'));
      final record = find.byKey(const ValueKey('camera-record-video'));
      final videoPath = find.byKey(const ValueKey('camera-video-directory'));
      expect(
        tester.getTopLeft(toggle).dy,
        lessThan(tester.getTopLeft(photo).dy),
      );
      expect(
        tester.getBottomLeft(photo).dy,
        lessThan(tester.getTopLeft(photoPath).dy),
      );
      expect(
        tester.getBottomLeft(photoPath).dy,
        lessThan(tester.getTopLeft(record).dy),
      );
      expect(
        tester.getBottomLeft(record).dy,
        lessThan(tester.getTopLeft(videoPath).dy),
      );
      await tester.tap(toggle);
      expect(preview, isFalse);
      await tester.tap(find.byKey(const ValueKey('camera-photo-folder')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('camera-video-folder')),
      );
      await tester.tap(find.byKey(const ValueKey('camera-video-folder')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('camera-take-photo')),
      );
      await tester.tap(find.byKey(const ValueKey('camera-take-photo')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('camera-record-video')),
      );
      await tester.tap(find.byKey(const ValueKey('camera-record-video')));
      expect([photos, videos, snapshots, recordings], [1, 1, 1, 1]);
      expect(find.text('/Pictures/BShare'), findsOneWidget);
      expect(find.text('/Movies/BShare'), findsOneWidget);
    },
  );

  testWidgets(
    'recording exposes duration and Stop even if remote video disappears',
    (tester) async {
      var stops = 0;
      await mount(
        tester,
        CameraMediaActionsPanel(
          previewEnabled: false,
          recording: true,
          elapsed: const Duration(hours: 1, minutes: 2, seconds: 3),
          onPreviewChanged: (_) {},
          onChoosePhotoFolder: () {},
          onChooseVideoFolder: () {},
          onTakePhoto: () {},
          onToggleRecording: () => stops++,
        ),
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('camera-video-folder')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('camera-take-photo')),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('camera-record-video')),
      );
      await tester.tap(find.byKey(const ValueKey('camera-record-video')));
      expect(stops, 1);
      expect(find.text('Grabando · 1:02:03'), findsOneWidget);
      expect(find.text('Detener grabación'), findsOneWidget);
    },
  );

  testWidgets('finalizing disables duplicate operations and shows progress', (
    tester,
  ) async {
    await mount(
      tester,
      CameraMediaActionsPanel(
        previewEnabled: true,
        streamReady: true,
        recording: true,
        savingVideo: true,
        onPreviewChanged: (_) {},
        onChoosePhotoFolder: () {},
        onChooseVideoFolder: () {},
        onTakePhoto: () {},
        onToggleRecording: () {},
      ),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('camera-record-video')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('camera-take-photo')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('camera-photo-folder')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Guardando video…'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('camera-viewer-preview')),
          )
          .onChanged,
      isNotNull,
    );
  });

  testWidgets(
    'saved footer stays fixed and readable while a short enlarged menu scrolls',
    (tester) async {
      tester.view.physicalSize = const Size(260, 260);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(
        tester,
        CameraMediaActionsPanel(
          previewEnabled: true,
          streamReady: true,
          photoDirectory: '/a/very/long/directory/for/photos/BShare',
          videoDirectory: '/a/very/long/directory/for/videos/BShare',
          errorMessage: 'No se pudo guardar. Elige otra carpeta.',
          lastSavedPath: '/Pictures/BShare/photo.jpg',
          onPreviewChanged: (_) {},
          onChoosePhotoFolder: () {},
          onChooseVideoFolder: () {},
          onTakePhoto: () {},
          onToggleRecording: () {},
        ),
        scaler: const TextScaler.linear(1.5),
      );
      final saved = find.byKey(const ValueKey('camera-media-saved'));
      final footer = find.byKey(const ValueKey('camera-media-saved-footer'));
      final footerRect = tester.getRect(footer);
      expect(footerRect.bottom, lessThanOrEqualTo(260));
      expect(saved.hitTestable(), findsOneWidget);
      final title = tester.widget<Text>(
        find.byKey(const ValueKey('camera-media-saved-title')),
      );
      final path = tester.widget<SelectableText>(
        find.byKey(const ValueKey('camera-media-saved-path')),
      );
      expect(title.data, 'Guardado:');
      expect(title.style!.fontSize, greaterThan(path.style!.fontSize!));
      await tester.drag(
        find.byKey(const ValueKey('camera-viewer-actions-scroll')),
        const Offset(0, -800),
      );
      await tester.pump();
      expect(tester.getRect(footer), footerRect);
      expect(saved.hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-media-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  CameraMediaActionsPanel notification(
    String path, {
    Duration elapsed = Duration.zero,
  }) => CameraMediaActionsPanel(
    previewEnabled: true,
    lastSavedPath: path,
    elapsed: elapsed,
    onPreviewChanged: (_) {},
    onChoosePhotoFolder: () {},
    onChooseVideoFolder: () {},
    onTakePhoto: () {},
    onToggleRecording: () {},
  );

  testWidgets(
    'saved notices expire after ten seconds and only a new file restarts the deadline',
    (tester) async {
      const first = '/Pictures/first.jpg';
      const second = '/Videos/second.mp4';
      const third = '/Pictures/third.jpg';
      await mount(tester, notification(first));
      final slot = find.byKey(const ValueKey('camera-media-saved-footer'));
      await tester.pump(const Duration(seconds: 9));
      expect(find.text(first), findsOneWidget);
      await mount(
        tester,
        notification(first, elapsed: const Duration(seconds: 9)),
      );
      await tester.pump(const Duration(seconds: 1));
      final visibleHeight = tester.getSize(slot).height;
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.getSize(slot).height,
        allOf(greaterThan(0), lessThan(visibleHeight)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(first), findsNothing);
      expect(tester.getSize(slot).height, 0);
      await mount(tester, notification(second));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(seconds: 8));
      expect(find.text(second), findsOneWidget);
      await mount(tester, notification(third));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(seconds: 9));
      expect(find.text(third), findsOneWidget);
      expect(find.text(second), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('camera-media-saved')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reduced motion skips transitions and leaving cancels the saved notice',
    (tester) async {
      await mount(
        tester,
        notification('/Pictures/first.jpg'),
        reducedMotion: true,
      );
      await tester.pump(const Duration(seconds: 10));
      expect(find.byKey(const ValueKey('camera-media-saved')), findsNothing);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('camera-media-saved-footer')))
            .height,
        0,
      );
      await mount(
        tester,
        notification('/Pictures/next.jpg'),
        reducedMotion: true,
      );
      expect(find.text('/Pictures/next.jpg'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 12));
      expect(tester.takeException(), isNull);
    },
  );
}
