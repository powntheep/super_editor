import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_composer.dart';
import 'package:super_editor/src/core/document_layout.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/core/editor.dart';
import 'package:super_editor/src/default_editor/box_component.dart';
import 'package:super_editor/src/default_editor/document_scrollable.dart';
import 'package:super_editor/src/default_editor/selection_upstream_downstream.dart';
import 'package:super_editor/src/default_editor/text_tools.dart';
import 'package:super_editor/src/document_operations/selection_operations.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/flutter/flutter_scheduler.dart';
import 'package:super_editor/src/infrastructure/multi_tap_gesture.dart';

import '../infrastructure/document_gestures_interaction_overrides.dart';

/// Governs mouse gesture interaction with a document, such as scrolling
/// a document with a scroll wheel, tapping to place a caret, and
/// tap-and-dragging to create an expanded selection.
///
/// See also: super_editor's touch gesture support.

/// Document gesture interactor that's designed for mouse input, e.g.,
/// drag to select, and mouse wheel to scroll.
///
///  - selects content on single, double, and triple taps
///  - selects content on drag, after single, double, or triple tap
///  - scrolls with the mouse wheel
///  - sets the cursor style based on hovering over text and other
///    components
///  - automatically scrolls up or down when the user drags near
///    a boundary
///
/// Whenever a selection change caused by a [SelectionReason.userInteraction] happens,
/// [DocumentMouseInteractor] auto-scrolls the editor to make the selection region visible.
class DocumentMouseInteractor extends StatefulWidget {
  const DocumentMouseInteractor({
    Key? key,
    this.focusNode,
    required this.editor,
    required this.document,
    required this.getDocumentLayout,
    required this.selectionNotifier,
    required this.selectionChanges,
    this.contentTapHandler,
    required this.autoScroller,
    this.showDebugPaint = false,
    this.child,
  }) : super(key: key);

  final FocusNode? focusNode;

  final Editor editor;
  final Document document;
  final DocumentLayoutResolver getDocumentLayout;
  final Stream<DocumentSelectionChange> selectionChanges;
  final ValueListenable<DocumentSelection?> selectionNotifier;

  /// Optional handler that responds to taps on content, e.g., opening
  /// a link when the user taps on text with a link attribution.
  final ContentTapDelegate? contentTapHandler;

  /// Auto-scrolling delegate.
  final AutoScrollController autoScroller;

  /// Paints some extra visual ornamentation to help with
  /// debugging, when `true`.
  final bool showDebugPaint;

  /// The document to display within this [DocumentMouseInteractor].
  final Widget? child;

  @override
  State createState() => _DocumentMouseInteractorState();
}

class _DocumentMouseInteractorState extends State<DocumentMouseInteractor> with SingleTickerProviderStateMixin {
  late FocusNode _focusNode;

  DocumentSelection? _previousSelection;

  // Tracks user drag gestures for selection purposes.
  SelectionType _selectionType = SelectionType.position;
  Offset? _dragStartGlobal;
  Offset? _dragEndGlobal;
  bool _expandSelectionDuringDrag = false;

  /// Holds which kind of device started a pan gesture, e.g., a mouse or a trackpad.
  PointerDeviceKind? _panGestureDevice;

  late StreamSubscription<DocumentSelectionChange> _selectionSubscription;

  DocumentSelection? get _currentSelection => widget.selectionNotifier.value;

  final _mouseCursor = ValueNotifier<MouseCursor>(SystemMouseCursors.text);
  Offset? _lastHoverOffset;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _selectionSubscription = widget.selectionChanges.listen(_onSelectionChange);
    _previousSelection = widget.selectionNotifier.value;
    widget.autoScroller
      ..addListener(_updateDragSelection)
      ..addListener(_updateMouseCursorAtLatestOffset);
    widget.contentTapHandler?.addListener(_updateMouseCursorAtLatestOffset);
  }

  @override
  void didUpdateWidget(DocumentMouseInteractor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (widget.selectionNotifier != oldWidget.selectionNotifier) {
      _previousSelection = widget.selectionNotifier.value;
    }
    if (widget.selectionChanges != oldWidget.selectionChanges) {
      _selectionSubscription.cancel();
      _selectionSubscription = widget.selectionChanges.listen(_onSelectionChange);
    }
    if (widget.autoScroller != oldWidget.autoScroller) {
      oldWidget.autoScroller
        ..removeListener(_updateDragSelection)
        ..removeListener(_updateMouseCursorAtLatestOffset);
      widget.autoScroller
        ..addListener(_updateDragSelection)
        ..addListener(_updateMouseCursorAtLatestOffset);
    }
    if (widget.contentTapHandler != oldWidget.contentTapHandler) {
      oldWidget.contentTapHandler?.removeListener(_updateMouseCursorAtLatestOffset);
      widget.contentTapHandler?.addListener(_updateMouseCursorAtLatestOffset);
    }
  }

  @override
  void dispose() {
    widget.contentTapHandler?.removeListener(_updateMouseCursorAtLatestOffset);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    _selectionSubscription.cancel();
    widget.autoScroller
      ..removeListener(_updateDragSelection)
      ..removeListener(_updateMouseCursorAtLatestOffset);
    super.dispose();
  }

  /// Returns the layout for the current document, which answers questions
  /// about the locations and sizes of visual components within the layout.
  DocumentLayout get _docLayout => widget.getDocumentLayout();

  Offset _getDocOffsetFromGlobalOffset(Offset globalOffset) {
    return _docLayout.getDocumentOffsetFromAncestorOffset(globalOffset);
  }

  bool get _isShiftPressed =>
      (RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
          RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftRight) ||
          RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shift)) &&
      // TODO: this condition doesn't belong here. Move it to where it applies
      _currentSelection != null;

  void _onSelectionChange(DocumentSelectionChange selectionChange) {
    if (!mounted) {
      return;
    }

    if (selectionChange.reason != SelectionReason.userInteraction) {
      // The selection changed, but it isn't caused by an user interaction.
      // We don't want auto-scroll.
      return;
    }
    if (selectionChange.selection == _previousSelection) {
      // The selection hasn't actually changed. We don't want to auto-scroll.
      return;
    }
    _previousSelection = selectionChange.selection;

    final selection = widget.selectionNotifier.value;
    if (selection == null) {
      return;
    }

    final node = widget.document.getNodeById(selection.extent.nodeId);
    if (node is BlockNode) {
      // We don't want auto-scroll block components.
      return;
    }

    // Use a post-frame callback to "ensure selection extent is visible"
    // so that any pending visual document changes can happen before
    // attempting to calculate the visual position of the selection extent.
    onNextFrame((_) {
      editorGesturesLog.finer("Ensuring selection extent is visible because the doc selection changed");

      final globalExtentRect = _getSelectionExtentAsGlobalRect();
      if (globalExtentRect != null) {
        widget.autoScroller.ensureGlobalRectIsVisible(globalExtentRect);
      }
    });
  }

  Rect? _getSelectionExtentAsGlobalRect() {
    final selection = _currentSelection;
    if (selection == null) {
      return null;
    }

    // The reason that a Rect is used instead of an Offset is
    // because things like Images and Horizontal Rules don't have
    // a clear selection offset. They are either entirely selected,
    // or not selected at all.
    final selectionExtentRectInDoc = _docLayout.getRectForPosition(
      selection.extent,
    );
    if (selectionExtentRectInDoc == null) {
      editorGesturesLog.warning(
          "Tried to ensure that position ${selection.extent} is visible on screen but no bounding box was returned for that position.");
      return null;
    }

    final globalTopLeft = _docLayout.getGlobalOffsetFromDocumentOffset(selectionExtentRectInDoc.topLeft);
    return Rect.fromLTWH(
        globalTopLeft.dx, globalTopLeft.dy, selectionExtentRectInDoc.width, selectionExtentRectInDoc.height);
  }

  void _onTapUp(TapUpDetails details) {
    editorGesturesLog.info("Tap up on document");
    final docOffset = _getDocOffsetFromGlobalOffset(details.globalPosition);
    editorGesturesLog.fine(" - document offset: $docOffset");
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    editorGesturesLog.fine(" - tapped document position: $docPosition");

    _focusNode.requestFocus();

    if (docPosition == null) {
      editorGesturesLog.fine("No document content at ${details.globalPosition}.");
      _clearSelection();
      return;
    }

    if (widget.contentTapHandler != null) {
      final result = widget.contentTapHandler!.onTap(docPosition);
      if (result == TapHandlingInstruction.halt) {
        // The custom tap handler doesn't want us to react at all
        // to the tap.
        return;
      }
    }

    final tappedComponent = _docLayout.getComponentByNodeId(docPosition.nodeId)!;
    final expandSelection = _isShiftPressed && _currentSelection != null;

    if (!tappedComponent.isVisualSelectionSupported()) {
      _moveToNearestSelectableComponent(
        docPosition.nodeId,
        tappedComponent,
        expandSelection: expandSelection,
      );
      return;
    }

    if (expandSelection) {
      // The user tapped while pressing shift and there's an existing
      // selection. Move the extent of the selection to where the user tapped.
      widget.editor.execute([
        ChangeSelectionRequest(
          _currentSelection!.copyWith(
            extent: docPosition,
          ),
          SelectionChangeType.expandSelection,
          SelectionReason.userInteraction,
        ),
      ]);
    } else {
      // Place the document selection at the location where the
      // user tapped.
      _selectionType = SelectionType.position;
      _selectPosition(docPosition);
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    editorGesturesLog.info("Double tap down on document");
    final docOffset = _getDocOffsetFromGlobalOffset(details.globalPosition);
    editorGesturesLog.fine(" - document offset: $docOffset");
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    editorGesturesLog.fine(" - tapped document position: $docPosition");

    if (docPosition != null && widget.contentTapHandler != null) {
      final result = widget.contentTapHandler!.onDoubleTap(docPosition);
      if (result == TapHandlingInstruction.halt) {
        // The custom tap handler doesn't want us to react at all
        // to the tap.
        return;
      }
    }

    if (docPosition != null) {
      final tappedComponent = _docLayout.getComponentByNodeId(docPosition.nodeId)!;
      if (!tappedComponent.isVisualSelectionSupported()) {
        return;
      }
    }

    _selectionType = SelectionType.word;
    _clearSelection();

    if (docPosition != null) {
      bool didSelectContent = _selectWordAt(
        docPosition: docPosition,
        docLayout: _docLayout,
      );

      if (!didSelectContent) {
        didSelectContent = _selectBlockAt(docPosition);
      }

      if (!didSelectContent) {
        // Place the document selection at the location where the
        // user tapped.
        _selectPosition(docPosition);
      }
    }

    _focusNode.requestFocus();
  }

  bool _selectWordAt({
    required DocumentPosition docPosition,
    required DocumentLayout docLayout,
  }) {
    final newSelection = getWordSelection(docPosition: docPosition, docLayout: docLayout);
    if (newSelection != null) {
      widget.editor.execute([
        ChangeSelectionRequest(
          newSelection,
          SelectionChangeType.expandSelection,
          SelectionReason.userInteraction,
        ),
      ]);
      return true;
    } else {
      return false;
    }
  }

  bool _selectBlockAt(DocumentPosition position) {
    if (position.nodePosition is! UpstreamDownstreamNodePosition) {
      return false;
    }

    widget.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: position.nodeId,
            nodePosition: const UpstreamDownstreamNodePosition.upstream(),
          ),
          extent: DocumentPosition(
            nodeId: position.nodeId,
            nodePosition: const UpstreamDownstreamNodePosition.downstream(),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);

    return true;
  }

  void _onDoubleTap() {
    editorGesturesLog.info("Double tap up on document");
    _selectionType = SelectionType.position;
  }

  void _onTripleTapDown(TapDownDetails details) {
    editorGesturesLog.info("Triple down down on document");
    final docOffset = _getDocOffsetFromGlobalOffset(details.globalPosition);
    editorGesturesLog.fine(" - document offset: $docOffset");
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    editorGesturesLog.fine(" - tapped document position: $docPosition");

    if (docPosition != null && widget.contentTapHandler != null) {
      final result = widget.contentTapHandler!.onTripleTap(docPosition);
      if (result == TapHandlingInstruction.halt) {
        // The custom tap handler doesn't want us to react at all
        // to the tap.
        return;
      }
    }

    if (docPosition != null) {
      final tappedComponent = _docLayout.getComponentByNodeId(docPosition.nodeId)!;
      if (!tappedComponent.isVisualSelectionSupported()) {
        return;
      }
    }

    _selectionType = SelectionType.paragraph;
    _clearSelection();

    if (docPosition != null) {
      final didSelectParagraph = _selectParagraphAt(
        docPosition: docPosition,
        docLayout: _docLayout,
      );
      if (!didSelectParagraph) {
        // Place the document selection at the location where the
        // user tapped.
        _selectPosition(docPosition);
      }
    }

    _focusNode.requestFocus();
  }

  bool _selectParagraphAt({
    required DocumentPosition docPosition,
    required DocumentLayout docLayout,
  }) {
    final newSelection = getParagraphSelection(docPosition: docPosition, docLayout: docLayout);
    if (newSelection != null) {
      widget.editor.execute([
        ChangeSelectionRequest(
          newSelection,
          SelectionChangeType.expandSelection,
          SelectionReason.userInteraction,
        ),
      ]);
      return true;
    } else {
      return false;
    }
  }

  void _onTripleTap() {
    editorGesturesLog.info("Triple tap up on document");
    _selectionType = SelectionType.position;
  }

  void _selectPosition(DocumentPosition position) {
    editorGesturesLog.fine("Setting document selection to $position");
    widget.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: position,
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
  }

  void _onPanStart(DragStartDetails details) {
    editorGesturesLog.info("Pan start on document, global offset: ${details.globalPosition}, device: ${details.kind}");

    _panGestureDevice = details.kind;

    if (_panGestureDevice == PointerDeviceKind.trackpad) {
      // After flutter 3.3, dragging with two fingers on a trackpad triggers a pan gesture.
      // This gesture should scroll the document and keep the selection unchanged.
      return;
    }

    _dragStartGlobal = details.globalPosition;

    widget.autoScroller.enableAutoScrolling();

    if (_isShiftPressed) {
      _expandSelectionDuringDrag = true;
    }

    if (!_isShiftPressed) {
      // Only clear the selection if the user isn't pressing shift. Shift is
      // used to expand the current selection, not replace it.
      editorGesturesLog.fine("Shift isn't pressed. Clearing any existing selection before panning.");
      _clearSelection();
    }

    _focusNode.requestFocus();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    editorGesturesLog
        .info("Pan update on document, global offset: ${details.globalPosition}, device: $_panGestureDevice");

    if (_panGestureDevice == PointerDeviceKind.trackpad) {
      // The user dragged using two fingers on a trackpad.
      // Scroll the document and keep the selection unchanged.
      // We multiply by -1 because the scroll should be in the opposite
      // direction of the drag, e.g., dragging up on a trackpad scrolls
      // the document to downstream direction.
      _scrollVertically(details.delta.dy * -1);
      return;
    }

    setState(() {
      _dragEndGlobal = details.globalPosition;

      _updateDragSelection();

      widget.autoScroller.setGlobalAutoScrollRegion(
        Rect.fromLTWH(_dragEndGlobal!.dx, _dragEndGlobal!.dy, 1, 1),
      );
    });
  }

  void _onPanEnd(DragEndDetails details) {
    editorGesturesLog.info("Pan end on document, device: $_panGestureDevice");

    if (_panGestureDevice == PointerDeviceKind.trackpad) {
      // The user ended a pan gesture with two fingers on a trackpad.
      // We already scrolled the document.
      widget.autoScroller.goBallistic(-details.velocity.pixelsPerSecond.dy);
      return;
    }
    _onDragEnd();
  }

  void _onPanCancel() {
    editorGesturesLog.info("Pan cancel on document");
    _onDragEnd();
  }

  void _onDragEnd() {
    setState(() {
      _dragStartGlobal = null;
      _dragEndGlobal = null;
      _expandSelectionDuringDrag = false;
    });

    widget.autoScroller.disableAutoScrolling();
  }

  /// Scrolls the document vertically by [delta] pixels.
  void _scrollVertically(double delta) {
    widget.autoScroller.jumpBy(delta);
    _updateDragSelection();
  }

  /// We prevent SingleChildScrollView from processing mouse events because
  /// it scrolls by drag by default, which we don't want. However, we do
  /// still want mouse scrolling. This method re-implements a primitive
  /// form of mouse scrolling.
  void _scrollOnMouseWheel(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _scrollVertically(event.scrollDelta.dy);
    }
  }

  /// Beginning with Flutter 3.3.3, we are responsible for starting and
  /// stopping scroll momentum. This method cancels any scroll momentum
  /// in our scroll controller.
  void _cancelScrollMomentum() {
    widget.autoScroller.goIdle();
  }

  void _updateDragSelection() {
    if (_dragEndGlobal == null) {
      // User isn't dragging. No need to update drag selection.
      return;
    }

    final dragStartInDoc =
        _getDocOffsetFromGlobalOffset(_dragStartGlobal!) + Offset(0, widget.autoScroller.deltaWhileAutoScrolling);
    final dragEndInDoc = _getDocOffsetFromGlobalOffset(_dragEndGlobal!);
    editorGesturesLog.finest(
      '''
Updating drag selection:
 - drag start in doc: $dragStartInDoc
 - drag end in doc: $dragEndInDoc''',
    );

    _selectRegion(
      documentLayout: _docLayout,
      baseOffsetInDocument: dragStartInDoc,
      extentOffsetInDocument: dragEndInDoc,
      selectionType: _selectionType,
      expandSelection: _expandSelectionDuringDrag,
    );

    if (widget.showDebugPaint) {
      setState(() {
        // Repaint the debug UI.
      });
    }
  }

  void _selectRegion({
    required DocumentLayout documentLayout,
    required Offset baseOffsetInDocument,
    required Offset extentOffsetInDocument,
    required SelectionType selectionType,
    bool expandSelection = false,
  }) {
    editorGesturesLog.info("Selecting region with selection mode: $selectionType");
    DocumentSelection? selection = documentLayout.getDocumentSelectionInRegion(
      baseOffsetInDocument,
      extentOffsetInDocument,
    );
    DocumentPosition? basePosition = selection?.base;
    DocumentPosition? extentPosition = selection?.extent;
    editorGesturesLog.fine(" - base: $basePosition, extent: $extentPosition");

    if (basePosition == null || extentPosition == null) {
      _clearSelection();
      return;
    }

    if (selectionType == SelectionType.paragraph) {
      final baseParagraphSelection = getParagraphSelection(
        docPosition: basePosition,
        docLayout: documentLayout,
      );
      if (baseParagraphSelection == null) {
        _clearSelection();
        return;
      }
      basePosition = baseOffsetInDocument.dy < extentOffsetInDocument.dy
          ? baseParagraphSelection.base
          : baseParagraphSelection.extent;

      final extentParagraphSelection = getParagraphSelection(
        docPosition: extentPosition,
        docLayout: documentLayout,
      );
      if (extentParagraphSelection == null) {
        _clearSelection();
        return;
      }
      extentPosition = baseOffsetInDocument.dy < extentOffsetInDocument.dy
          ? extentParagraphSelection.extent
          : extentParagraphSelection.base;
    } else if (selectionType == SelectionType.word) {
      final baseWordSelection = getWordSelection(
        docPosition: basePosition,
        docLayout: documentLayout,
      );
      if (baseWordSelection == null) {
        _clearSelection();
        return;
      }
      basePosition = baseWordSelection.base;

      final extentWordSelection = getWordSelection(
        docPosition: extentPosition,
        docLayout: documentLayout,
      );
      if (extentWordSelection == null) {
        _clearSelection();
        return;
      }
      extentPosition = extentWordSelection.extent;
    }

    widget.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection(
          // If desired, expand the selection instead of replacing it.
          base: expandSelection ? _currentSelection?.base ?? basePosition : basePosition,
          extent: extentPosition,
        ),
        SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
    ]);

    editorGesturesLog.fine("Selected region: $_currentSelection");
  }

  void _clearSelection() {
    editorGesturesLog.fine("Clearing document selection");
    widget.editor.execute([
      const ClearSelectionRequest(),
    ]);
  }

  void _moveToNearestSelectableComponent(
    String nodeId,
    DocumentComponent component, {
    bool expandSelection = false,
  }) {
    moveSelectionToNearestSelectableNode(
      editor: widget.editor,
      document: widget.document,
      documentLayoutResolver: widget.getDocumentLayout,
      currentSelection: widget.selectionNotifier.value,
      startingNode: widget.document.getNodeById(nodeId)!,
      expand: expandSelection,
    );

    if (!expandSelection) {
      _selectionType = SelectionType.position;
    }
  }

  void _onMouseMove(PointerHoverEvent event) {
    _cancelScrollMomentum();
    _updateMouseCursor(event.position);
    _lastHoverOffset = event.position;
  }

  void _updateMouseCursorAtLatestOffset() {
    if (_lastHoverOffset == null) {
      return;
    }
    _updateMouseCursor(_lastHoverOffset!);
  }

  void _updateMouseCursor(Offset globalPosition) {
    final docOffset = _getDocOffsetFromGlobalOffset(globalPosition);
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    if (docPosition == null) {
      _mouseCursor.value = SystemMouseCursors.text;
      return;
    }

    final cursorForContent = widget.contentTapHandler?.mouseCursorForContentHover(docPosition);
    _mouseCursor.value = cursorForContent ?? SystemMouseCursors.text;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _scrollOnMouseWheel,
      onPointerHover: _onMouseMove,
      onPointerDown: (event) => _cancelScrollMomentum(),
      onPointerPanZoomStart: (event) => _cancelScrollMomentum(),
      child: _buildCursorStyle(
        child: _buildGestureInput(
          child: widget.child ?? const SizedBox(),
        ),
      ),
    );
  }

  Widget _buildCursorStyle({
    required Widget child,
  }) {
    return ValueListenableBuilder(
      valueListenable: _mouseCursor,
      builder: (context, value, child) {
        return MouseRegion(
          cursor: _mouseCursor.value,
          onExit: (_) => _lastHoverOffset = null,
          child: child,
        );
      },
      child: child,
    );
  }

  Widget _buildGestureInput({
    required Widget child,
  }) {
    final gestureSettings = MediaQuery.maybeOf(context)?.gestureSettings;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        TapSequenceGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapSequenceGestureRecognizer>(
          () => TapSequenceGestureRecognizer(),
          (TapSequenceGestureRecognizer recognizer) {
            recognizer
              ..onTapUp = _onTapUp
              ..onDoubleTapDown = _onDoubleTapDown
              ..onDoubleTap = _onDoubleTap
              ..onTripleTapDown = _onTripleTapDown
              ..onTripleTap = _onTripleTap
              ..gestureSettings = gestureSettings;
          },
        ),
        PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
          () => PanGestureRecognizer(),
          (PanGestureRecognizer recognizer) {
            recognizer
              ..onStart = _onPanStart
              ..onUpdate = _onPanUpdate
              ..onEnd = _onPanEnd
              ..onCancel = _onPanCancel
              ..gestureSettings = gestureSettings;
          },
        ),
      },
      child: child,
    );
  }
}

/// Paints a rectangle border around the given `selectionRect`.
class DragRectanglePainter extends CustomPainter {
  DragRectanglePainter({
    this.selectionRect,
    Listenable? repaint,
  }) : super(repaint: repaint);

  final Rect? selectionRect;
  final Paint _selectionPaint = Paint()
    ..color = const Color(0xFFFF0000)
    ..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    if (selectionRect != null) {
      canvas.drawRect(selectionRect!, _selectionPaint);
    }
  }

  @override
  bool shouldRepaint(DragRectanglePainter oldDelegate) {
    return oldDelegate.selectionRect != selectionRect;
  }
}
