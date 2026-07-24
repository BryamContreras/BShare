import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/receive_progress.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/send_progress.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/presentation/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('BShare app renders', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BShareApp()));
    expect(find.text('BShare'), findsWidgets);
  });

  testWidgets('incoming files open the Transfers tab', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BShareApp()),
    );
    await tester.pump();

    container
        .read(receiveProgressProvider.notifier)
        .upsert(
          const ReceiveProgress(
            id: 'incoming-1',
            fileName: 'photo.jpg',
            receivedBytes: 0,
            totalBytes: 1024,
            bytesPerSecond: 0,
            status: TransferProgressStatus.queued,
          ),
        );
    await tester.pump();
    await tester.pump();

    expect(find.text('Transfer progress'), findsOneWidget);
    expect(find.text('photo.jpg'), findsOneWidget);
  });

  testWidgets('Send keeps selection and shows progress only in Transfers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(pickedFilesProvider.notifier).set(const [
      SelectedTransferFile(
        path: '/tmp/selected-document.pdf',
        name: 'selected-document.pdf',
        size: 2048,
      ),
    ]);
    container
        .read(sendProgressProvider.notifier)
        .upsert(
          const SendProgress(
            id: '/tmp/active-transfer.zip',
            fileName: 'active-transfer.zip',
            sentBytes: 512,
            totalBytes: 4096,
            bytesPerSecond: 1024,
            status: TransferProgressStatus.sending,
          ),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BShareApp()),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(container.read(pickedFilesProvider), hasLength(1));

    final sendNavigationItem = find.ancestor(
      of: find.text('Send').first,
      matching: find.byType(InkWell),
    );
    expect(sendNavigationItem, findsOneWidget);
    tester.widget<InkWell>(sendNavigationItem).onTap!();
    await tester.pumpAndSettle();
    expect(container.read(pickedFilesProvider), hasLength(1));
    expect(find.text('Target device'), findsOneWidget);

    expect(find.text('selected-document.pdf'), findsOneWidget);
    expect(find.text('active-transfer.zip'), findsNothing);

    final transfersNavigationItem = find.ancestor(
      of: find.text('Transfers').first,
      matching: find.byType(InkWell),
    );
    expect(transfersNavigationItem, findsOneWidget);
    tester.widget<InkWell>(transfersNavigationItem).onTap!();
    await tester.pumpAndSettle();

    expect(find.text('active-transfer.zip'), findsOneWidget);
    expect(container.read(pickedFilesProvider), hasLength(1));
  });

  for (final size in [
    const Size(320, 568),
    const Size(360, 780),
    const Size(393, 852),
    const Size(800, 600),
    const Size(1280, 800),
  ]) {
    testWidgets('Home and Send fit at ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const ProviderScope(child: BShareApp()));
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Send').last);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
  }
}
