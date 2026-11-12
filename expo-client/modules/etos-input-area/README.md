# Experimental iOS input-view panel

The existing `InputArea` is a Fabric host with ordered composer/panel slots.
The optional `KeyboardPanel` mounts one RN child into an owned UIKit
`UIInputView`; UIKit may present that surface as the composer's input view.
The module does not read user data or write any list inset/offset. The 145b
native scroll-lease experiment has been removed: it stopped on normal layout
changes and the suggested native history-anchor fallback did not exist.

The input-view stacking change has a limited iPhone validation: the attachment
close button responded and the panel closed, and the user reported sticker panel
scrolling and grouping worked. Sticker sending was not tested; the subsequent
diagnostic cleanup has not yet been built or tested on iOS. KBC 1.22.7 listens
to UIKit keyboard-will-show/hide notifications and tracks keyboard movement. Whether every custom input-view
presentation, equal-height switch and `reloadInputViews` generates the expected
notifications and motion is a device question; do not infer it from source or
from a JS test. FlashList MVCP and KCSV can both write offsets, so this is not a
claim of a strict single offset writer or proven conflict-free behavior.

## API

Check `keyboardPanelAvailable()` on iOS before rendering `KeyboardPanel`; it
requires both native request and dismiss functions. It is false on Web and on
older development binaries. Preserve the existing UI fallback in those cases.
Do not eagerly resolve the new native view in an old binary.

Keep `<KeyboardPanel scopeGeneration={generation}>` mounted under the existing
InputArea's panel slot while the session is active. Give it one non-collapsible
RN child with the desired explicit panel height; place its placeholder so the
hidden UIKit surface does not add layout height to the composer. Capture the
current InputArea host, KeyboardPanel and composer TextInput React tags from
mounted refs/layout. Both views must be descendants of the same mounted host.
On session change, including A→B→A, change the non-secret generation and remount
the panel. Its child is mounted in the UIKit input view, which may be outside
the normal React root window; RN touch, layout, accessibility and native sheet
presentation must be verified on a device.

```ts
await requestKeyboardPanel({
  hostTag, panelTag, inputTag, generation,
  mode: 'panel', // 'keyboard' restores the system keyboard
  height: panelHeight, // finite points, 1..1000
  current: isCurrentSessionAndOperation,
});
await dismissKeyboardPanel({ hostTag, panelTag, inputTag, generation, current });
```

Calls are explicit user actions and use only the exact native views addressed by
the tags. When already focused, switching sets the input view and requests
`reloadInputViews`; when unfocused, it chooses the input view first and requests
first responder. Failure to focus returns `input_not_focused`. Dismiss removes
only this panel's input view and resigns only the addressed composer if it is
still first responder; it does not resign an unrelated search input. If a
foreign input view owns the composer, the module returns
`input_owned_elsewhere`. A failed resign returns `dismiss_refused`. Generation
change, unmount or window detachment relinquishes only the module's own input
view.

`requested` acknowledges the main-thread request, not actual focus, keyboard
presentation, animation or a particular frame. A native error/lost response is
`unavailable`, which does not prove no mutation occurred; do not replay it
automatically. A late result returns `session_changed` when `current()` has
been invalidated, but cannot undo work already dispatched on the native main
queue. Serialize explicit UI actions, invalidate on unmount/session change,
and do not allow a stale operation to update the current UI. RN 0.88 may replace
the underlying UITextView when multiline changes or reset its inputView when
certain props change; the next explicit request must resolve the current tag
again. Do not assume a retained backing view remains valid.

The existing `probeInputAreaTargets({hostTag, scrollTag, inputTag, current})`
remains available for read-only iOS diagnostics; it resolves only the supplied
views and returns fixed status/boolean fields, without reading text. The d084
probe observation was a single snapshot, not proof of the new panel's behavior.

## Input-view stacking

Before the stacking change, four taps in the attachment close area reached a
separate input-surface subtree and did not invoke the close action. The records
did not identify that branch or establish its ordering.

The current candidate preserves Fabric's order among its mounted children and
places the sole owned child at the front when mounted or when the input surface
enters a window, only if it is still a direct child in that same window. It
neither inspects nor mutates UIKit's private views, installs an RN touch handler,
nor replaces UIKit hit testing. It does change the owned child's relative
stacking; normal system keyboard transitions and other interactions still
require device validation. It does not continuously override later UIKit changes.

With the stacking candidate installed, a subsequent device observation hit the
SwiftUI close control and executed the close action; the user also reported that
sticker scrolling and grouping worked. This is limited evidence: sticker sending,
other system controls and this later diagnostic-cleanup build remain unverified.
A source or JS test cannot validate UIKit subview order or iOS compilation.

## Orc integration candidate

- Keep FlashList's `maintainVisibleContentPosition` enabled: native
  `captureHistoryAnchor` currently returns null. The abandoned scroll lease is
  not an alternative history anchor. The candidate keeps KCSV's keyboard
  handling without adding another scroll writer. On the native-panel path the
  composer uses an `Animated.View` translated by `keyboard.height`; that
  translation and KCSV updates freeze during the sticker-search handoff.
  `KeyboardStickyView` remains in the older iOS binary fallback.
- On the iOS candidate path, request the UIKit panel/keyboard instead of the
  old `EmojiPanel` height animation and `emojiVisibleHeight`-driven extra
  padding. Feed KCSV only the normal composer clearance, not an additional
  panel height: the test hypothesis is that UIKit presents the panel as the
  keyboard and KBC reports that geometry. Preserve multiline composer updates,
  normal user drag and existing FlashList behavior. The existing KBC 1.22.7
  extra-padding/ref timing issue can still affect composer height changes;
  this candidate does not prove it is fixed.
- For a panel height, retain the most recent **actual system keyboard** height
  measured for the composer in the current window. Do not overwrite that value
  with custom-panel or search-sheet keyboard events. When no real measurement
  exists (first launch or hardware keyboard), an explicitly provisional panel
  height is necessary; it is not the real keyboard height. Check safe-area
  accounting, orientation and unequal panel/keyboard heights on device.
- The sticker search sheet is hosted outside the UIKit input-view subtree.
  The candidate dismisses the composer before presenting search and waits for
  the SwiftUI sheet's `onDismiss` before restoring the panel for the current
  session. It coordinates focus with callbacks and a read-only native probe,
  not a timer. The separate search keyboard, frozen KCSV and composer
  translation still need device checks.
- Validate visible panel and composer at rest and throughout open, close,
  panel→keyboard and keyboard→panel, including from an initially closed
  keyboard. Cover search open/close, touch and selection inside the panel,
  input growth, stream/image remeasurement, prepend/history anchoring, long and
  short lists, non-bottom reading, user drag, cancellation, session switch and
  old binary fallback. Compare actual composer, newest bubble, inset/offset and
  keyboard/panel frames with the observed 300/151-point failure; use synthetic
  content and never log text or credentials.

There is no supported FlashList API here to hand every internal MVCP correction
and every keyboard offset update to one native writer. A strict single offset
writer would require a coordinated FlashList/RN integration or patch with a
real mount/anchor handoff; the prior per-frame lease did not provide that.
This candidate instead preserves the established components and tests whether
the UIKit input view eliminates the separate panel-padding path.

## Build and evidence

To validate the candidate in the existing app, use the established Mac
`npm run ios:prepare`, `npm run ios:build`, then, with a matching device and
signing, `npm run ios:install`. Reuse the DerivedData path documented by the
project; do not create another Swift cache. The diagnostic cleanup removes a
Swift source file; if the existing CocoaPods project still references that
file, refresh it with `npm run ios:prepare` or the project's existing `pod install`
flow before rebuilding. The native change requires a rebuilt
dev binary. Existing 18093 Metro can be reused if reachable and configured for
the binary; this module starts no service. JS/type tests and autolinking do not
compile Swift or establish device behavior.

The Fabric mounting pattern follows `expo-glass-effect`'s `GlassContainer`; its
MIT license is reproduced in `EXPO-LICENSE`. Local podspec source metadata is
not fetched when Expo autolinking installs this pod from its local path.
