/// The source-text strip above the results in the standalone lookup window:
/// the sentence the lookup came from (screen OCR, text selected in another
/// app), tappable word by word through [SourceLookupTextPanel].
///
/// Three things the bare panel could not do:
///  - it can be collapsed to a one-line preview, by hand or by default;
///  - a long sentence (a whole OCR block) scrolls inside a bounded strip instead
///    of pushing the results out of the window;
///  - it scrolls away with the results: the results are a WebView with their
///    own scrolling, so the strip leaves while they are scrolled down and comes
///    back at their top (see [SourceStripScrollAway]).
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// How far the results must be able to scroll, beyond the strip's own height,
/// before scrolling them hides the strip.
///
/// Hiding the strip gives its height back to the results, which shortens how far
/// they can scroll. With less room than this the results would be pinned back to
/// their top, which brings the strip back, which takes the room away again.
const double kSourceStripScrollAwayMargin = 24;

/// Whether the strip is scrolled away, fed with the results' scroll position.
class SourceStripScrollAway {
  bool _hidden = false;

  bool get hidden => _hidden;

  /// Applies one scroll sample of the results; returns whether [hidden]
  /// changed.
  ///
  /// The strip comes back whenever the results are at their top, including when
  /// a new lookup re-renders them there. It only leaves on a scroll the user
  /// made, and only when the results stay scrollable after taking its height.
  bool update({
    required double pixels,
    required double maxScrollExtent,
    required double stripHeight,
    required bool userDriven,
  }) {
    final bool next;
    if (pixels <= 0) {
      next = false;
    } else if (_hidden) {
      next = true;
    } else {
      next =
          userDriven &&
          maxScrollExtent > stripHeight + kSourceStripScrollAwayMargin;
    }
    if (next == _hidden) return false;
    _hidden = next;
    return true;
  }

  /// Shows the strip again (a new sentence arrived).
  void reset() => _hidden = false;
}

class SourceLookupStrip extends StatelessWidget {
  const SourceLookupStrip({
    required this.text,
    required this.collapsed,
    required this.scrolledAway,
    required this.onToggleCollapsed,
    required this.panel,
    required this.maxExpandedHeight,
    super.key,
  });

  final String text;
  final bool collapsed;
  final bool scrolledAway;
  final VoidCallback onToggleCollapsed;

  /// The tappable [SourceLookupTextPanel] shown while expanded.
  final Widget panel;

  /// Past this height the expanded sentence scrolls inside the strip.
  final double maxExpandedHeight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    final Widget toggle = SizedBox(
      width: 40,
      height: 36,
      child: FushiIconButton(
        key: const ValueKey<String>('source_lookup_strip_toggle'),
        icon: collapsed ? FushiIcons.expandMore : FushiIcons.expandLess,
        enabledColor: FushiDesignTokens.of(context).surfaces.onVariant,
        size: 20,
        tooltip: t.lookup_source_text_toggle,
        padding: EdgeInsets.zero,
        onTap: onToggleCollapsed,
      ),
    );
    final Widget body = collapsed
        ? Semantics(
            button: true,
            label: t.lookup_source_text_toggle,
            child: GestureDetector(
              key: const ValueKey<String>('source_lookup_strip_preview'),
              behavior: HitTestBehavior.opaque,
              onTap: onToggleCollapsed,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 0, 4),
                child: Text(
                  text.trim().replaceAll(RegExp(r'\s+'), ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          )
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxExpandedHeight),
            child: SingleChildScrollView(child: panel),
          );
    return ClipRect(
      child: AnimatedSize(
        duration: duration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: scrolledAway
            ? const SizedBox(width: double.infinity, height: 0)
            : Row(
                crossAxisAlignment: collapsed
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: body),
                  toggle,
                ],
              ),
      ),
    );
  }
}
