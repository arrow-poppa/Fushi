import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/source_lookup_strip.dart';

/// The source strip in the standalone lookup window scrolls away with the
/// results (a WebView with its own scrolling) and comes back at their top.
void main() {
  SourceStripScrollAway scrolled({
    double pixels = 40,
    double max = 600,
    double strip = 120,
    bool user = true,
  }) {
    final SourceStripScrollAway state = SourceStripScrollAway();
    state.update(
      pixels: pixels,
      maxScrollExtent: max,
      stripHeight: strip,
      userDriven: user,
    );
    return state;
  }

  test('a user scroll down the results hides the strip', () {
    expect(scrolled().hidden, isTrue);
  });

  test('back at the top of the results the strip returns', () {
    final SourceStripScrollAway state = scrolled();
    final bool changed = state.update(
      pixels: 0,
      maxScrollExtent: 600,
      stripHeight: 120,
      userDriven: true,
    );
    expect(changed, isTrue);
    expect(state.hidden, isFalse);
  });

  test('stays hidden while the results are still scrolled', () {
    final SourceStripScrollAway state = scrolled();
    // Hiding gave the strip's height back to the results, so they can scroll
    // less now; that must not bring the strip back.
    expect(
      state.update(
        pixels: 30,
        maxScrollExtent: 50,
        stripHeight: 0,
        userDriven: true,
      ),
      isFalse,
    );
    expect(state.hidden, isTrue);
  });

  test('a programmatic scroll (re-render, restored position) keeps it', () {
    expect(scrolled(user: false).hidden, isFalse);
  });

  test('results too short to stay scrollable without the strip keep it', () {
    // Hiding 120 px from a 130 px scroll range would leave 10 px: the results
    // would snap back to their top and the strip would bounce in and out.
    expect(scrolled(max: 130).hidden, isFalse);
    expect(
      scrolled(max: 120 + kSourceStripScrollAwayMargin + 1).hidden,
      isTrue,
    );
  });

  test('reset shows the strip again', () {
    final SourceStripScrollAway state = scrolled()..reset();
    expect(state.hidden, isFalse);
  });
}
