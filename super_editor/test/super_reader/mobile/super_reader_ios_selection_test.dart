import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_runners/flutter_test_runners.dart';
import 'package:super_editor/src/infrastructure/platforms/ios/selection_handles.dart';
import 'package:super_editor/src/test/super_editor_test/supereditor_robot.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_reader_test.dart';

import '../reader_test_tools.dart';

void main() {
  group("SuperReader mobile selection >", () {
    group("iOS >", () {
      group("long press >", () {
        testWidgetsOnIos("selects word under finger", (tester) async {
          await tester
              .createDocument()
              // "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod...",
              .withSingleParagraph()
              .withiOSToolbarBuilder((context, mobileToolbarKey, focalPoint) =>
                  IOSTextEditingFloatingToolbar(key: mobileToolbarKey, focalPoint: focalPoint))
              .pump();

          // Ensure that no overlay controls are visible.
          expect(find.byType(IOSSelectionHandle), findsNothing);
          expect(find.byType(IOSTextEditingFloatingToolbar), findsNothing);
          expect(find.byType(IOSRoundedRectangleMagnifyingGlass), findsNothing);

          // Long press on the middle of "conse|ctetur"
          await tester.longPressInParagraph("1", 33);
          await tester.pumpAndSettle();

          // Ensure the word was selected.
          expect(SuperReaderInspector.findDocumentSelection(), isNotNull);
          expect(
            SuperReaderInspector.findDocumentSelection(),
            const DocumentSelection(
              base: DocumentPosition(
                nodeId: "1",
                nodePosition: TextNodePosition(offset: 28),
              ),
              extent: DocumentPosition(
                nodeId: "1",
                nodePosition: TextNodePosition(offset: 39),
              ),
            ),
          );

          // Ensure the drag handles and toolbar are visible, but the magnifier isn't.
          expect(find.byType(IOSSelectionHandle), findsExactly(2));
          expect(find.byType(IOSTextEditingFloatingToolbar), findsOne);
          expect(find.byType(IOSRoundedRectangleMagnifyingGlass), findsNothing);
        });

        testWidgetsOnIos("over handle does nothing", (tester) async {
          await tester
              .createDocument()
              // "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod...",
              .withSingleParagraph()
              .withiOSToolbarBuilder((context, mobileToolbarKey, focalPoint) =>
                  IOSTextEditingFloatingToolbar(key: mobileToolbarKey, focalPoint: focalPoint))
              .pump();

          // Long press on the middle of "do|lor".
          await tester.longPressInParagraph("1", 14);
          await tester.pumpAndSettle();

          // Ensure the word was selected.
          const wordSelection = DocumentSelection(
            base: DocumentPosition(
              nodeId: "1",
              nodePosition: TextNodePosition(offset: 12),
            ),
            extent: DocumentPosition(
              nodeId: "1",
              nodePosition: TextNodePosition(offset: 17),
            ),
          );

          expect(SuperReaderInspector.findDocumentSelection(), isNotNull);
          expect(SuperReaderInspector.findDocumentSelection(), wordSelection);

          // Long-press near the upstream handle, but just before the selected word.
          await tester.longPressInParagraph("1", 11);
          await tester.pumpAndSettle();

          // Ensure that the selection didn't change.
          expect(SuperReaderInspector.findDocumentSelection(), wordSelection);

          // Long-press near the downstream handle, but just after the selected word.
          await tester.longPressInParagraph("1", 18);
          await tester.pumpAndSettle();

          // Ensure that the selection didn't change.
          expect(SuperReaderInspector.findDocumentSelection(), wordSelection);
        });

        testWidgetsOnIos("selects by word when dragging upstream and then back downstream", (tester) async {
          await tester
              .createDocument()
              // "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod...",
              .withSingleParagraph()
              .withiOSToolbarBuilder((context, mobileToolbarKey, focalPoint) =>
                  IOSTextEditingFloatingToolbar(key: mobileToolbarKey, focalPoint: focalPoint))
              .pump();

          // Long press on the middle of "do|lor".
          final gesture = await tester.longPressDownInParagraph("1", 14);
          await tester.pumpAndSettle();

          // Ensure the word was selected.
          const wordSelection = DocumentSelection(
            base: DocumentPosition(
              nodeId: "1",
              nodePosition: TextNodePosition(offset: 12),
            ),
            extent: DocumentPosition(
              nodeId: "1",
              nodePosition: TextNodePosition(offset: 17),
            ),
          );
          expect(SuperReaderInspector.findDocumentSelection(), wordSelection);

          // Ensure the drag handles and magnifier are visible, but the toolbar isn't.
          expect(find.byType(IOSSelectionHandle), findsExactly(2));
          expect(find.byType(IOSRoundedRectangleMagnifyingGlass), findsOne);
          expect(find.byType(IOSTextEditingFloatingToolbar), findsNothing);

          // Drag upstream to the end of the previous word.
          // "Lorem ipsu|m dolor sit amet"
          //            ^ position 10
          //
          // We do this with manual distances because the attempt to look up character
          // offsets was producing unpredictable results.
          const dragIncrementCount = 10;
          const upstreamDragDistance = -130 / dragIncrementCount;
          for (int i = 0; i < dragIncrementCount; i += 1) {
            await gesture.moveBy(const Offset(upstreamDragDistance, 0));
            await tester.pump();
          }

          // Ensure the original word and upstream word are both selected.
          expect(
            SuperReaderInspector.findDocumentSelection(),
            const DocumentSelection(
              base: DocumentPosition(
                nodeId: "1",
                nodePosition: TextNodePosition(offset: 6),
              ),
              extent: DocumentPosition(
                nodeId: "1",
                nodePosition: TextNodePosition(offset: 17),
              ),
            ),
          );

          // Drag back towards the original long-press offset.
          //
          // We do this with manual distances because the attempt to look up character
          // offsets was producing unpredictable results.
          const downstreamDragDistance = 100 / dragIncrementCount;
          for (int i = 0; i < dragIncrementCount; i += 1) {
            await gesture.moveBy(const Offset(downstreamDragDistance, 0));
            await tester.pump();
          }

          // Ensure that only the original word is selected.
          expect(SuperReaderInspector.findDocumentSelection(), wordSelection);

          // Release the gesture so the test system doesn't complain.
          gesture.up();
        });

        testWidgetsOnIos("selects by word when dragging downstream and then back upstream", (tester) async {
          await tester
              .createDocument()
              // "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod...",
              .withSingleParagraph()
              .withiOSToolbarBuilder((context, mobileToolbarKey, focalPoint) =>
                  IOSTextEditingFloatingToolbar(key: mobileToolbarKey, focalPoint: focalPoint))
              .pump();

          // Long press on the middle of "do|lor".
          final gesture = await tester.longPressDownInParagraph("1", 14);
          await tester.pumpAndSettle();

          // Ensure the word was selected.
          const wordSelection = DocumentSelection(
            base: DocumentPosition(
              nodeId: "1",
              nodePosition: TextNodePosition(offset: 12),
            ),
            extent: DocumentPosition(
              nodeId: "1",
              nodePosition: TextNodePosition(offset: 17),
            ),
          );
          expect(SuperReaderInspector.findDocumentSelection(), wordSelection);

          // Ensure the drag handles and magnifier are visible, but the toolbar isn't.
          expect(find.byType(IOSSelectionHandle), findsExactly(2));
          expect(find.byType(IOSRoundedRectangleMagnifyingGlass), findsOne);
          expect(find.byType(IOSTextEditingFloatingToolbar), findsNothing);

          // Drag downstream to the beginning of the next word.
          // "Lorem ipsum dolor s|it amet"
          //                     ^ position 19
          //
          // We do this with manual distances because the attempt to look up character
          // offsets was producing unpredictable results.
          const dragIncrementCount = 10;
          const downstreamDragDistance = 80 / dragIncrementCount;
          for (int i = 0; i < dragIncrementCount; i += 1) {
            await gesture.moveBy(const Offset(downstreamDragDistance, 0));
            await tester.pump();
          }

          // Ensure the original word and downstream word are both selected.
          expect(
            SuperReaderInspector.findDocumentSelection(),
            const DocumentSelection(
              base: DocumentPosition(
                nodeId: "1",
                nodePosition: TextNodePosition(offset: 12),
              ),
              extent: DocumentPosition(
                nodeId: "1",
                nodePosition: TextNodePosition(offset: 21),
              ),
            ),
          );

          // Drag back towards the original long-press offset.
          //
          // We do this with manual distances because the attempt to look up character
          // offsets was producing unpredictable results.
          const upstreamDragDistance = -40 / dragIncrementCount;
          for (int i = 0; i < dragIncrementCount; i += 1) {
            await gesture.moveBy(const Offset(upstreamDragDistance, 0));
            await tester.pump();
          }

          // Ensure that only the original word is selected.
          expect(SuperReaderInspector.findDocumentSelection(), wordSelection);

          // Release the gesture so the test system doesn't complain.
          gesture.up();
        });
      });
    });
  });
}
