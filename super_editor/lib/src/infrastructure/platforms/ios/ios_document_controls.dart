import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:follow_the_leader/follow_the_leader.dart';
import 'package:overlord/follow_the_leader.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_composer.dart';
import 'package:super_editor/src/core/document_layout.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/default_editor/document_gestures_touch_ios.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/content_layers.dart';
import 'package:super_editor/src/infrastructure/documents/document_layers.dart';
import 'package:super_editor/src/infrastructure/documents/selection_leader_document_layer.dart';
import 'package:super_editor/src/infrastructure/flutter/flutter_scheduler.dart';
import 'package:super_editor/src/infrastructure/multi_listenable_builder.dart';
import 'package:super_editor/src/infrastructure/platforms/ios/selection_handles.dart';
import 'package:super_editor/src/infrastructure/platforms/mobile_documents.dart';
import 'package:super_editor/src/infrastructure/touch_controls.dart';
import 'package:super_text_layout/super_text_layout.dart';

class DocumentKeys {
  static const mobileToolbar = ValueKey("document_mobile_toolbar");
  static const magnifier = ValueKey("document_magnifier");
  static const iOsCaret = ValueKey("document_ios_caret");
  static const androidCaret = ValueKey("document_android_caret");
  static const androidCaretHandle = ValueKey("document_android_caret_handle");
  static const upstreamHandle = ValueKey("document_upstream_handle");
  static const downstreamHandle = ValueKey("document_downstream_handle");

  DocumentKeys._();
}

/// An application overlay that displays an iOS-style toolbar.
class IosFloatingToolbarOverlay extends StatefulWidget {
  const IosFloatingToolbarOverlay({
    Key? key,
    required this.shouldShowToolbar,
    required this.toolbarFocalPoint,
    required this.floatingToolbarBuilder,
    this.createOverlayControlsClipper,
    this.showDebugPaint = false,
  }) : super(key: key);

  final ValueListenable<bool> shouldShowToolbar;

  /// The focal point, which determines where the toolbar is positioned, and
  /// where the toolbar points.
  ///
  /// In the case that the associated [Leader] has meaningful width and height,
  /// the toolbar focuses on the center of the [Leader]'s bounding box.
  final LeaderLink toolbarFocalPoint;

  /// Creates a clipper that applies to overlay controls, preventing
  /// the overlay controls from appearing outside the given clipping
  /// region.
  ///
  /// If no clipper factory method is provided, then the overlay controls
  /// will be allowed to appear anywhere in the overlay in which they sit
  /// (probably the entire screen).
  final CustomClipper<Rect> Function(BuildContext overlayContext)? createOverlayControlsClipper;

  /// Builder that constructs the floating toolbar that's displayed above
  /// selected text.
  ///
  /// Typically, this bar includes actions like "copy", "cut", "paste", etc.
  final DocumentFloatingToolbarBuilder floatingToolbarBuilder;

  final bool showDebugPaint;

  @override
  State createState() => _IosFloatingToolbarOverlayState();
}

class _IosFloatingToolbarOverlayState extends State<IosFloatingToolbarOverlay> with SingleTickerProviderStateMixin {
  final _boundsKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.shouldShowToolbar,
      builder: (context, _) {
        return Padding(
          // Remove the keyboard from the space that we occupy so that
          // clipping calculations apply to the expected visual borders,
          // instead of applying underneath the keyboard.
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: ClipRect(
            clipper: widget.createOverlayControlsClipper?.call(context),
            child: SizedBox(
              // ^ SizedBox tries to be as large as possible, because
              // a Stack will collapse into nothing unless something
              // expands it.
              key: _boundsKey,
              width: double.infinity,
              height: double.infinity,
              child: Stack(
                children: [
                  // Build the editing toolbar
                  if (widget.shouldShowToolbar.value) //
                    _buildToolbar(),
                  if (widget.showDebugPaint) //
                    _buildDebugPaint(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildToolbar() {
    return FollowerFadeOutBeyondBoundary(
      link: widget.toolbarFocalPoint,
      boundary: WidgetFollowerBoundary(
        boundaryKey: _boundsKey,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      ),
      child: Follower.withAligner(
        link: widget.toolbarFocalPoint,
        aligner: CupertinoPopoverToolbarAligner(_boundsKey),
        boundary: WidgetFollowerBoundary(
          boundaryKey: _boundsKey,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        ),
        child: widget.floatingToolbarBuilder(context, DocumentKeys.mobileToolbar, widget.toolbarFocalPoint),
      ),
    );
  }

  Widget _buildDebugPaint() {
    return IgnorePointer(
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.yellow.withOpacity(0.2),
      ),
    );
  }
}

/// Controls the display of drag handles, a magnifier, and a
/// floating toolbar, assuming iOS-style behavior for the
/// handles.
class IosDocumentGestureEditingController extends GestureEditingController {
  IosDocumentGestureEditingController({
    required LayerLink documentLayoutLink,
    required super.selectionLinks,
    required super.magnifierFocalPointLink,
    required super.overlayController,
  }) : _documentLayoutLink = documentLayoutLink;

  /// Layer link that's aligned to the top-left corner of the document layout.
  ///
  /// Some of the offsets reported by this controller are based on the
  /// document layout coordinate space. Therefore, to honor those offsets on
  /// the screen, this `LayerLink` should be used to align the controls with
  /// the document layout before applying the offset that sits within the
  /// document layout.
  LayerLink get documentLayoutLink => _documentLayoutLink;
  final LayerLink _documentLayoutLink;

  /// Whether or not a caret should be displayed.
  bool get hasCaret => caretTop != null;

  /// The offset of the top of the caret, or `null` if no caret should
  /// be displayed.
  ///
  /// When the caret is drawn, the caret will have a thickness. That width
  /// should be placed either on the left or right of this offset, based on
  /// whether the [caretAffinity] is upstream or downstream, respectively.
  Offset? get caretTop => _caretTop;
  Offset? _caretTop;

  /// The height of the caret, or `null` if no caret should be displayed.
  double? get caretHeight => _caretHeight;
  double? _caretHeight;

  /// Updates the caret's size and position.
  ///
  /// The [top] offset is in the document layout's coordinate space.
  void updateCaret({
    Offset? top,
    double? height,
  }) {
    bool changed = false;
    if (top != null) {
      _caretTop = top;
      changed = true;
    }
    if (height != null) {
      _caretHeight = height;
      changed = true;
    }

    if (changed) {
      notifyListeners();
    }
  }

  /// Removes the caret from the display.
  void removeCaret() {
    if (!hasCaret) {
      return;
    }

    _caretTop = null;
    _caretHeight = null;
    notifyListeners();
  }

  /// Whether a collapsed handle should be displayed.
  bool get shouldDisplayCollapsedHandle => _collapsedHandleOffset != null;

  /// The offset of the collapsed handle focal point, within the coordinate space
  /// of the document layout, or `null` if no collapsed handle should be displayed.
  Offset? get collapsedHandleOffset => _collapsedHandleOffset;
  Offset? _collapsedHandleOffset;
  set collapsedHandleOffset(Offset? offset) {
    if (offset != _collapsedHandleOffset) {
      _collapsedHandleOffset = offset;
      notifyListeners();
    }
  }

  /// Whether the expanded handles (base + extent) should be displayed.
  bool get shouldDisplayExpandedHandles => _upstreamHandleOffset != null && _downstreamHandleOffset != null;

  double? get upstreamCaretHeight => _upstreamCaretHeight;
  double? _upstreamCaretHeight;
  set upstreamCaretHeight(double? height) {
    if (height != _upstreamCaretHeight) {
      _upstreamCaretHeight = height;
      notifyListeners();
    }
  }

  /// The offset of the upstream handle focal point, within the coordinate space
  /// of the document layout, or `null` if no upstream handle should be displayed.
  Offset? get upstreamHandleOffset => _upstreamHandleOffset;
  Offset? _upstreamHandleOffset;
  set upstreamHandleOffset(Offset? offset) {
    if (offset != _upstreamHandleOffset) {
      _upstreamHandleOffset = offset;
      notifyListeners();
    }
  }

  double? get downstreamCaretHeight => _downstreamCaretHeight;
  double? _downstreamCaretHeight;
  set downstreamCaretHeight(double? height) {
    if (height != _downstreamCaretHeight) {
      _downstreamCaretHeight = height;
      notifyListeners();
    }
  }

  /// The offset of the downstream handle focal point, within the coordinate space
  /// of the document layout, or `null` if no downstream handle should be displayed.
  Offset? get downstreamHandleOffset => _downstreamHandleOffset;
  Offset? _downstreamHandleOffset;
  set downstreamHandleOffset(Offset? offset) {
    if (offset != _downstreamHandleOffset) {
      _downstreamHandleOffset = offset;
      notifyListeners();
    }
  }

  final _magnifierLink = LayerLink();

  @override
  void showMagnifier() {
    _newMagnifierLink = _magnifierLink;
    super.showMagnifier();
  }

  @override
  void hideMagnifier() {
    _newMagnifierLink = null;
    super.hideMagnifier();
  }

  LayerLink? get newMagnifierLink => _newMagnifierLink;
  LayerLink? _newMagnifierLink;
  set newMagnifierLink(LayerLink? link) {
    if (_newMagnifierLink == link) {
      return;
    }

    _newMagnifierLink = link;
    notifyListeners();
  }
}

class FloatingCursorController {
  void dispose() {
    isActive.dispose();
    isNearText.dispose();
    cursorGeometryInViewport.dispose();
    _listeners.clear();
  }

  /// Whether the user is currently interacting with the floating cursor via the
  /// software keyboard.
  final isActive = ValueNotifier<bool>(false);

  /// Whether the floating cursor is currently near text, which impacts whether
  /// or not a standard gray caret should be displayed.
  final isNearText = ValueNotifier<bool>(false);

  /// The offset, width, and height of the active floating cursor.
  final cursorGeometryInViewport = ValueNotifier<Rect?>(null);

  /// Report that the user has activated the floating cursor.
  void onStart() {
    isActive.value = true;
    for (final listener in _listeners) {
      listener.onStart();
    }
  }

  Offset? get offset => _offset;
  Offset? _offset;

  /// Report that the user has moved the floating cursor.
  void onMove(Offset? newOffset) {
    if (newOffset == _offset) {
      return;
    }
    _offset = newOffset;

    for (final listener in _listeners) {
      listener.onMove(newOffset);
    }
  }

  /// Report that the user has deactivated the floating cursor.
  void onStop() {
    isActive.value = false;
    for (final listener in _listeners) {
      listener.onStop();
    }
  }

  final _listeners = <FloatingCursorListener>{};

  void addListener(FloatingCursorListener listener) {
    _listeners.add(listener);
  }

  void removeListener(FloatingCursorListener listener) {
    _listeners.remove(listener);
  }
}

class FloatingCursorListener {
  FloatingCursorListener({
    VoidCallback? onStart,
    void Function(Offset?)? onMove,
    VoidCallback? onStop,
  })  : _onStart = onStart,
        _onMove = onMove,
        _onStop = onStop;

  final VoidCallback? _onStart;
  final void Function(Offset?)? _onMove;
  final VoidCallback? _onStop;

  void onStart() => _onStart?.call();

  void onMove(Offset? newOffset) => _onMove?.call(newOffset);

  void onStop() => _onStop?.call();
}

/// A document layer that positions a leader widget around the user's selection,
/// as a focal point for an iOS-style toolbar display.
///
/// By default, the toolbar focal point [LeaderLink] is obtained from an ancestor
/// [SuperEditorIosControlsScope].
class IosToolbarFocalPointDocumentLayer extends DocumentLayoutLayerStatefulWidget {
  const IosToolbarFocalPointDocumentLayer({
    Key? key,
    required this.document,
    required this.selection,
    required this.toolbarFocalPointLink,
    this.showDebugLeaderBounds = false,
  }) : super(key: key);

  /// The editor's [Document], which is used to find the start and end of
  /// the user's expanded selection.
  final Document document;

  /// The current user's selection within a document.
  final ValueListenable<DocumentSelection?> selection;

  /// The [LeaderLink], which is attached to the toolbar focal point bounds.
  ///
  /// By default, this [LeaderLink] is obtained from an ancestor [SuperEditorIosControlsScope].
  /// If [toolbarFocalPointLink] is non-null, it's used instead of the ancestor value.
  final LeaderLink toolbarFocalPointLink;

  /// Whether to paint colorful bounds around the leader widgets, for debugging purposes.
  final bool showDebugLeaderBounds;

  @override
  DocumentLayoutLayerState<ContentLayerStatefulWidget, Rect> createState() => _IosToolbarFocalPointDocumentLayerState();
}

class _IosToolbarFocalPointDocumentLayerState extends DocumentLayoutLayerState<IosToolbarFocalPointDocumentLayer, Rect>
    with SingleTickerProviderStateMixin {
  DocumentSelection? _selectionUsedForMostRecentLayout;

  @override
  void initState() {
    super.initState();

    widget.selection.addListener(_onSelectionChange);
  }

  @override
  void didUpdateWidget(IosToolbarFocalPointDocumentLayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.selection != oldWidget.selection) {
      oldWidget.selection.removeListener(_onSelectionChange);
      widget.selection.addListener(_onSelectionChange);
    }
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelectionChange);

    super.dispose();
  }

  void _onSelectionChange() {
    final selection = widget.selection.value;
    if (selection == _selectionUsedForMostRecentLayout) {
      // The selection didn't change from what it was the last time we calculated selection bounds.
      return;
    }
    _selectionUsedForMostRecentLayout = selection;

    // The selection changed, which means the selection bounds changed, we need to recalculate the
    // toolbar focal point bounds.
    setStateAsSoonAsPossible(() {
      // The selection bounds, and Leader build, will take place in methods that
      // run in response to setState().
    });
  }

  @override
  Rect? computeLayoutDataWithDocumentLayout(BuildContext context, DocumentLayout documentLayout) {
    final documentSelection = widget.selection.value;
    if (documentSelection == null) {
      return null;
    }

    final selectedComponent = documentLayout.getComponentByNodeId(widget.selection.value!.extent.nodeId);
    if (selectedComponent == null) {
      // Assume that we're in a momentary transitive state where the document layout
      // just gained or lost a component. We expect this method to run again in a moment
      // to correct for this.
      return null;
    }

    return documentLayout.getRectForSelection(
      documentSelection.base,
      documentSelection.extent,
    );
  }

  @override
  Widget doBuild(BuildContext context, Rect? selectionBounds) {
    if (selectionBounds == null) {
      return const SizedBox();
    }

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: selectionBounds,
            child: Leader(
              link: widget.toolbarFocalPointLink,
              child: widget.showDebugLeaderBounds
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          width: 4,
                          color: const Color(0xFFFF00FF),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// A document layer that displays an iOS-style caret and handles.
///
/// This layer positions the caret and handles directly, rather than using
/// `Leader`s and `Follower`s, because their position is based on the document
/// layout, rather than the user's gesture behavior.
class IosHandlesDocumentLayer extends DocumentLayoutLayerStatefulWidget {
  const IosHandlesDocumentLayer({
    super.key,
    required this.document,
    required this.documentLayout,
    required this.selection,
    required this.changeSelection,
    required this.handleColor,
    required this.shouldCaretBlink,
    this.floatingCursorController,
    this.showDebugPaint = false,
  });

  final Document document;

  final DocumentLayout documentLayout;

  final ValueListenable<DocumentSelection?> selection;

  final void Function(DocumentSelection?, SelectionChangeType, String selectionReason) changeSelection;

  /// Color the iOS-style text selection drag handles.
  final Color handleColor;

  /// Whether the caret should blink, whenever the caret is visible.
  final ValueListenable<bool> shouldCaretBlink;

  /// Floating cursor state, used to determine when the floating cursor is active,
  /// during which the regular caret is either hidden, or is displayed as a gray
  /// caret when the floating cursor is far away from its nearest text.
  final FloatingCursorController? floatingCursorController;

  final bool showDebugPaint;

  @override
  DocumentLayoutLayerState<IosHandlesDocumentLayer, DocumentSelectionLayout> createState() =>
      IosControlsDocumentLayerState();
}

@visibleForTesting
class IosControlsDocumentLayerState extends DocumentLayoutLayerState<IosHandlesDocumentLayer, DocumentSelectionLayout>
    with SingleTickerProviderStateMixin {
  /// The diameter of the small circle that appears on the top and bottom of
  /// expanded iOS text handles.
  static const ballDiameter = 8.0;

  // These global keys are assigned to each draggable handle to
  // prevent a strange dragging issue.
  //
  // Without these keys, if the user drags into the auto-scroll area
  // for a period of time, we never receive a
  // "pan end" or "pan cancel" callback. I have no idea why this is
  // the case. These handles sit in an Overlay, so it's not as if they
  // suffered some conflict within a ScrollView. I tried many adjustments
  // to recover the end/cancel callbacks. Finally, I tried adding these
  // global keys based on a hunch that perhaps the gesture detector was
  // somehow getting switched out, or assigned to a different widget, and
  // that was somehow disrupting the callback series. For now, these keys
  // seem to solve the problem.
  final _collapsedHandleKey = GlobalKey();
  final _upstreamHandleKey = GlobalKey();
  final _downstreamHandleKey = GlobalKey();

  late BlinkController _caretBlinkController;

  @override
  void initState() {
    super.initState();
    _caretBlinkController = BlinkController(tickerProvider: this);

    widget.selection.addListener(_onSelectionChange);
    widget.shouldCaretBlink.addListener(_onBlinkModeChange);
    widget.floatingCursorController?.isActive.addListener(_onFloatingCursorActivationChange);

    _onBlinkModeChange();
  }

  @override
  void didUpdateWidget(IosHandlesDocumentLayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.selection != oldWidget.selection) {
      oldWidget.selection.removeListener(_onSelectionChange);
      widget.selection.addListener(_onSelectionChange);
    }

    if (widget.shouldCaretBlink != oldWidget.shouldCaretBlink) {
      oldWidget.shouldCaretBlink.removeListener(_onBlinkModeChange);
      widget.shouldCaretBlink.addListener(_onBlinkModeChange);
    }

    if (widget.floatingCursorController != oldWidget.floatingCursorController) {
      oldWidget.floatingCursorController?.isActive.removeListener(_onFloatingCursorActivationChange);
      widget.floatingCursorController?.isActive.addListener(_onFloatingCursorActivationChange);
    }
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelectionChange);
    widget.shouldCaretBlink.removeListener(_onBlinkModeChange);
    widget.floatingCursorController?.isActive.removeListener(_onFloatingCursorActivationChange);

    _caretBlinkController.dispose();
    super.dispose();
  }

  @visibleForTesting
  Rect? get caret => layoutData?.caret;

  @visibleForTesting
  Color get caretColor => widget.handleColor;

  @visibleForTesting
  bool get isCaretDisplayed => layoutData?.caret != null;

  @visibleForTesting
  bool get isUpstreamHandleDisplayed => layoutData?.upstream != null;

  @visibleForTesting
  bool get isDownstreamHandleDisplayed => layoutData?.downstream != null;

  void _onSelectionChange() {
    setState(() {
      // Schedule a new layout computation because the caret and/or handles need to move.
    });
  }

  void _onBlinkModeChange() {
    if (widget.shouldCaretBlink.value) {
      _caretBlinkController.startBlinking();
    } else {
      _caretBlinkController.stopBlinking();
    }
  }

  void _onFloatingCursorActivationChange() {
    if (widget.floatingCursorController?.isActive.value == true) {
      _caretBlinkController.stopBlinking();
    } else {
      _caretBlinkController.startBlinking();
    }
  }

  @override
  DocumentSelectionLayout? computeLayoutDataWithDocumentLayout(BuildContext context, DocumentLayout documentLayout) {
    final selection = widget.selection.value;
    if (selection == null) {
      return null;
    }

    if (selection.isCollapsed) {
      return DocumentSelectionLayout(
        caret: documentLayout.getRectForPosition(selection.extent)!,
      );
    } else {
      return DocumentSelectionLayout(
        upstream: documentLayout.getRectForPosition(
          widget.document.selectUpstreamPosition(selection.base, selection.extent),
        )!,
        downstream: documentLayout.getRectForPosition(
          widget.document.selectDownstreamPosition(selection.base, selection.extent),
        )!,
        expandedSelectionBounds: documentLayout.getRectForSelection(
          selection.base,
          selection.extent,
        ),
      );
    }
  }

  @override
  Widget doBuild(BuildContext context, DocumentSelectionLayout? layoutData) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: layoutData != null //
            ? _buildHandles(layoutData)
            : const SizedBox(),
      ),
    );
  }

  Widget _buildHandles(DocumentSelectionLayout layoutData) {
    if (widget.selection.value == null) {
      editorGesturesLog.finer("Not building overlay handles because there's no selection.");
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        if (layoutData.caret != null) //
          _buildCollapsedHandle(caret: layoutData.caret!),
        if (layoutData.upstream != null && layoutData.downstream != null) ...[
          _buildUpstreamHandle(
            upstream: layoutData.upstream!,
            debugColor: Colors.green,
          ),
          _buildDownstreamHandle(
            downstream: layoutData.downstream!,
            debugColor: Colors.red,
          ),
        ],
      ],
    );
  }

  Widget _buildCollapsedHandle({
    required Rect caret,
  }) {
    return Positioned(
      key: _collapsedHandleKey,
      left: caret.left,
      top: caret.top,
      child: MultiListenableBuilder(
        listenables: {
          if (widget.floatingCursorController != null) ...{
            widget.floatingCursorController!.isActive,
            widget.floatingCursorController!.isNearText,
          }
        },
        builder: (context) {
          final isShowingFloatingCursor = widget.floatingCursorController?.isActive.value == true;
          final isNearText = widget.floatingCursorController?.isNearText.value == true;
          if (isShowingFloatingCursor && isNearText) {
            // The floating cursor is active and it's near some text. We don't want to
            // paint a collapsed handle/caret.
            return const SizedBox();
          }

          return IOSCollapsedHandle(
            key: DocumentKeys.iOsCaret,
            controller: _caretBlinkController,
            color: isShowingFloatingCursor ? Colors.grey : widget.handleColor,
            caretHeight: caret.height,
          );
        },
      ),
    );
  }

  Widget _buildUpstreamHandle({
    required Rect upstream,
    required Color debugColor,
  }) {
    return Positioned(
      key: _upstreamHandleKey,
      left: upstream.left,
      top: upstream.top - ballDiameter,
      child: FractionalTranslation(
        translation: const Offset(-0.5, 0),
        child: IOSSelectionHandle.upstream(
          key: DocumentKeys.upstreamHandle,
          color: widget.handleColor,
          handleType: HandleType.upstream,
          caretHeight: upstream.height,
          ballRadius: ballDiameter / 2,
        ),
      ),
    );
  }

  Widget _buildDownstreamHandle({
    required Rect downstream,
    required Color debugColor,
  }) {
    return Positioned(
      key: _downstreamHandleKey,
      left: downstream.left,
      top: downstream.top,
      child: FractionalTranslation(
        translation: const Offset(-0.5, 0),
        child: IOSSelectionHandle.downstream(
          key: DocumentKeys.downstreamHandle,
          color: widget.handleColor,
          handleType: HandleType.downstream,
          caretHeight: downstream.height,
          ballRadius: ballDiameter / 2,
        ),
      ),
    );
  }
}

/// Builds a full-screen floating toolbar display, with the toolbar positioned near the
/// [focalPoint], and with the toolbar attached to the given [mobileToolbarKey].
///
/// The [mobileToolbarKey] is used to find the toolbar in the widget tree for various purposes,
/// e.g., within tests to verify the presence or absence of a toolbar. If your builder chooses
/// not to build a toolbar, e.g., returns a `SizedBox()` instead of a toolbar, then the
/// you shouldn't use the [mobileToolbarKey].
///
/// The [mobileToolbarKey] must be attached to the toolbar, not the top-level widget returned
/// from this builder, because the [mobileToolbarKey] might be used to verify the size and location
/// of the toolbar. For example:
///
/// ```dart
/// Widget buildMagnifier(context, mobileToolbarKey, focalPoint) {
///   return Follower(
///     link: focalPoint,
///     child: Toolbar(
///       key: mobileToolbarKey,
///       width: 100,
///       height: 42,
///       magnification: 1.5,
///     ),
///   );
/// }
/// ```
typedef DocumentFloatingToolbarBuilder = Widget Function(
  BuildContext context,
  Key mobileToolbarKey,
  LeaderLink focalPoint,
);

/// Builds a full-screen magnifier display, with the magnifier following the given [focalPoint],
/// and with the magnifier attached to the given [magnifierKey].
///
/// The [magnifierKey] is used to find the magnifier in the widget tree for various purposes,
/// e.g., within tests to verify the presence or absence of a magnifier. If your builder chooses
/// not to build a magnifier, e.g., returns a `SizedBox()` instead of a magnifier, then the
/// you shouldn't use the [magnifierKey].
///
/// The [magnifierKey] must be attached to the magnifier, not the top-level widget returned
/// from this builder, because the [magnifierKey] might be used to verify the size and location
/// of the magnifier. For example:
///
/// ```dart
/// Widget buildMagnifier(context, magnifierKey, focalPoint) {
///   return Follower(
///     link: focalPoint,
///     child: Magnifier(
///       key: magnifierKey,
///       width: 100,
///       height: 42,
///       magnification: 1.5,
///     ),
///   );
/// }
/// ```
typedef DocumentMagnifierBuilder = Widget Function(BuildContext, Key magnifierKey, LeaderLink focalPoint);
