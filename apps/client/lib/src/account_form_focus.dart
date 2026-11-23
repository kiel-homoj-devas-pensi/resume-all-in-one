import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Keeps the decorated account field (including validation) above the keyboard.
/// EditableText's caret scrolling alone can leave its label or error clipped.
mixin AccountFormFocus<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  final _accountFocusNodes = <TextEditingController, FocusNode>{};
  Timer? _accountRevealTimer;
  int _accountRevealEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  FocusNode accountFocus(TextEditingController controller) =>
      _accountFocusNodes.putIfAbsent(controller, () {
        final node = FocusNode();
        node.addListener(() {
          if (node.hasFocus) revealAccountField();
        });
        return node;
      });

  void focusAccountField(TextEditingController controller) {
    accountFocus(controller).requestFocus();
    revealAccountField();
  }

  @override
  void didChangeMetrics() => revealAccountField();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    revealAccountField();
  }

  void revealAccountField() {
    final epoch = ++_accountRevealEpoch;
    void afterLayout() => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _accountRevealEpoch) return;
      for (final node in _accountFocusNodes.values) {
        if (!node.hasFocus || node.context == null) continue;
        node.context!.visitAncestorElements((element) {
          if (element.widget is! InputDecorator) return true;
          final field = element.findRenderObject()! as RenderBox;
          final viewport = RenderAbstractViewport.of(field);
          // Oversized help/errors remain scrollable; keep the label and input
          // at the top rather than centering a block taller than the viewport.
          Scrollable.ensureVisible(
            element,
            alignment: field.size.height > viewport.paintBounds.height
                ? 0
                : 0.5,
          );
          return false;
        });
        break;
      }
    });

    afterLayout();
    // Recheck after Dialog inset and InputDecorator error animations settle.
    // This is bounded and never changes focus or the keyboard's visibility.
    _accountRevealTimer?.cancel();
    _accountRevealTimer = Timer(const Duration(milliseconds: 250), () {
      afterLayout();
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  bool onAccountFormScroll(ScrollStartNotification notification) {
    if (notification.dragDetails != null) {
      // Deliberately scrolling to an action must win over a pending reveal.
      _accountRevealEpoch++;
      _accountRevealTimer?.cancel();
    }
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accountRevealTimer?.cancel();
    for (final node in _accountFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }
}
