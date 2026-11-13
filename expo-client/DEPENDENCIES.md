# Expo UI dependency handoff

This project uses Expo SDK 58.0.23, React Native 0.88.1, React 19.3.0,
React Native Web 0.21.4 and TypeScript 6.0.3, with the SDK-compatible native
module versions in `package-lock.json`. Expo 58 supports Node 22.13+ (22.x),
24.3+ (24.x), 26.x, or 27+.
`expo install --check` checks SDK version alignment. Native packages are part
of the development build: install or upgrade them before building a new iOS
binary; JavaScript hot reload does not update native code.

## System controls and glass

The project's `src/ui` components use `@expo/ui` for buttons and input,
including SwiftUI buttons and modifiers on iOS. `expo-glass-effect` provides
the native glass surface when available; the surface falls back to an opaque
color when glass is unavailable or Reduce Transparency is enabled. Web uses
the platform-compatible components and fallback surface. `@expo/ui` and
`expo-glass-effect` are MIT-licensed; their dependency trees carry additional
notices. The previous Glassy UI source and its bundled license have been
removed. Native rendering, Reduce Transparency, keyboard behavior and
accessibility on the current iOS UI have not been verified on a device.

## Expo Symbols

`expo-symbols` 58.0.4 (MIT) and its direct `expo-font` SDK peer are installed.
The Web implementation uses `@expo-google-fonts/material-symbols` 0.4.53,
transitively supplied by `expo-symbols`; the package code is MIT and its
bundled font carries the Apache 2.0 license (`LICENSE_FONT`). The regular TTF
is bundled locally, not fetched from Google at runtime. iOS uses system SF
Symbols via Expo's autolinked native module; no separate Symbols config plugin
is needed; autolinking resolves the `ExpoSymbols` and `ExpoFont` pods. Apple
SF Symbols follow [Apple's usage terms](https://developer.apple.com/design/human-interface-guidelines/sf-symbols),
including limits on trademark use; individual symbols vary by iOS version.
A development binary must be rebuilt to include newly added native
modules; hot reload cannot add them.

```tsx
import { SymbolView } from 'expo-symbols';
<SymbolView name={{ ios: 'bubble.left', web: 'chat', android: 'chat' }} size={24} tintColor="#123456" />
```

Provide names for both iOS and Web; a string SF name alone renders no Web
symbol without a fallback. Set an appropriate accessible label on the owning
interactive UI element. Expo loads the Web font asynchronously, leaving an
empty-sized placeholder until it loads. SDK 58 TypeScript and isolated iOS and
Web JS exports with this import passed; the Web export included the font.
This is not native compilation, iOS device verification, or UI acceptance.
See [Expo Symbols](https://docs.expo.dev/versions/v58.0.0/sdk/symbols/).

## Chat UI

The app composes its own chat UI around FlashList, React Native and Expo UI;
the CFL data controller remains responsible for the chat protocol. Gesture
Handler 3.3.0, Reanimated 4.7.1, Worklets 0.13.0, Safe Area Context 5.11.1
and Keyboard Controller 1.22.7 remain direct dependencies for the app and
Reanimated's peer. The root uses `GestureHandlerRootView`, `SafeAreaProvider`
and `KeyboardProvider`. Expo's Babel preset configures the Worklets transform;
avoid a duplicate plugin. Attachment and CFL sticker data come from the app;
voice input remains out of scope. The system camera uses `expo-image-picker`;
`expo-audio` is preinstalled for future playback.

Expo modules and these direct dependencies are MIT-licensed. Their dependency
trees have additional license notices; retain applicable notices when distributing.
Camera WebP preparation uses the already-installed MIT `expo-image-manipulator`
58.0.16. Its source-built iOS pod resolves `SDWebImageWebPCoder` 0.15.0 and
`SDWebImage` 5.21.7 (MIT), plus libwebp 1.6.0 (BSD 3-Clause). Their notices
and the libwebp patent grant are recorded in [third-party notices](../docs/THIRD_PARTY_NOTICES.md);
provide the applicable notices with distributions. Two isolated CocoaPods
installs verified these versions in the lock, not in a built or installed
binary. On-device encoding remains unverified.

## FlashList timeline primitive

`@shopify/flash-list` 2.3.2 is the exact Expo SDK 58 recommended version.
The published package is MIT (retain its `LICENSE.md`); its peers are React,
React Native and `@babel/runtime`, all already present. Its npm archive has
JS/TS only: no iOS podspec, Objective-C/Swift, Android Gradle or Java/Kotlin
module. It uses React Native's existing views and scrolling APIs. v2 requires
React Native's New Architecture; its Web path also supports React Native Web.

Adding this package alone does not add native code requiring a new iOS dev
build, provided the installed binary already has the compatible RN/Fabric
runtime and other required native modules. Verify that binary's actual build
identity rather than inferring it from this checkout. Other native changes
still require a rebuild. The configured Expo Updates runtime uses
`fingerprint`; compare the actual built runtime with the intended update before
distribution, because a runtime mismatch blocks an update even when this list
package itself has no native module. Metro reload and OTA are separate paths.

Import `FlashList` and `type FlashListRef` from `@shopify/flash-list`; use
`useRef<FlashListRef<Message>>(null)` and the list ref's `scrollToEnd`,
`scrollToOffset` or async `scrollToIndex`. Supply a stable message-ID
`keyExtractor`. The current timeline uses `maxItemsInRecyclePool={0}`; if
recycling is enabled later, reset item-scoped state on identity change, clean
up async image resources, and avoid item-specific keys that defeat recycling.
An optional `renderScrollComponent` receives ScrollView props, including a
forwarded ref at runtime: pass all props and the ref to the actual scroll view,
not a mask wrapper. FlashList wraps that component in RN Animated; verify any
Reanimated or masked wrapper's ref, layout and keyboard behavior separately.
`maintainVisibleContentPosition` is enabled by default; its
`startRenderingFromBottom` and `autoscrollToBottomThreshold` are available for
chat. The latter is a fraction of visible length in this version; tune and test
near-bottom following and off-bottom reading rather than assuming defaults
handle every streaming/resize case. See the [v2 usage](https://shopify.github.io/flash-list/docs/usage/)
and [recycling guide](https://shopify.github.io/flash-list/docs/recycling/).

The FlashList timeline does not prove a fix for the reported iOS
transparency/crash. Web behavior, scroll anchors,
keyboard coordination, native build and device behavior need separate UI
and device validation.

## Markdown and math

`react-native-enriched-markdown` 1.2.0-nightly-20261109-ca015bcac and its Web math peer `katex` 0.19.1
are direct, exact dependencies. The renderer is MIT, KaTeX code is MIT and
RaTeX is MIT; KaTeX fonts are SIL OFL 1.1. Preserve the font attribution and
[license notices](https://github.com/erweixin/RaTeX/blob/v0.1.15/THIRD_PARTY_NOTICES.txt)
when distributing. Bundled MD4C and the downloaded tree-sitter runtime and
grammars carry their own notices; retain the applicable notices as well.

The project postinstall applies a temporary patch to that exact nightly. Web
inline images use `object-fit: contain` and the existing `image.borderRadius`;
iOS draws inline images proportionally into the existing transparent box.
Block-image and image authorization behavior are unchanged. Android already
uses proportional inline scaling. The script checks the version and SHA-256
of each original or previously patched file and fails installation on drift;
revisit or remove the patch when upgrading. Do not disable npm lifecycle
scripts when installing. The upstream MIT license and notices remain in the
package. Rebuild the iOS dev client to include the Objective-C change; this is
not an OTA-only fix. iOS native build and device behavior have not been verified.

The package's iOS math is enabled explicitly, as is code highlighting, so the
podspec fails when its required asset markers or framework directory are missing
instead of quietly building without them. Those presence checks are not a full
integrity check of an existing vendor tree. Its npm postinstall can warn and exit
successfully on download failure: inspect its output and ensure both vendor
trees and stamps exist before native builds. Running
`npm rebuild react-native-enriched-markdown` retries installation; the upstream scripts may
skip intact stamped files, so a fresh isolated install is required to recheck
the downloaded archives. It needs network access to GitHub and npm. The
tree-sitter runtime tarball has a pinned SHA-256; grammar package versions are
pinned, but their postinstall downloads are not checked against npm SRI by the
upstream script and are outside this app's lockfile. Treat that as a supply
chain limitation. The isolated install used roughly 41 MB for the iOS RaTeX
tree and 169 MB for grammar sources; these are not app binary sizes.

The pinned nightly npm package pins RaTeX v0.1.15. Its postinstall downloaded and
verified XCFramework SHA-256
`23e4dd2bfe5f81c8efe24e52195435723b0a86c61f100fca7b38068bbf9aae31`
and source SHA-256
`a4296fa21cd40a56543602511bcf417014f4fee7cf5e1eaab58e0ac9610e3f63`.
The installed framework matched the independently restored tree, including
iOS arm64 and simulator arm64/x86_64 slices. Upstream identifies 0.1.11 as
the fix for [GHSA-4hgp-59h5-gvrj](https://github.com/erweixin/RaTeX/security/advisories/GHSA-4hgp-59h5-gvrj)
and [GHSA-4w5h-hx6r-28q7](https://github.com/erweixin/RaTeX/security/advisories/GHSA-4w5h-hx6r-28q7);
0.1.15 is later than the patched release. This is not an on-device test of
malformed inputs. A new iOS dev
build is required; OTA cannot add this native library to an existing build.

For a controlled UI prototype, import `EnrichedMarkdownText` from
`react-native-enriched-markdown` and pass `markdown`, `flavor="github"` and a
validated `onLinkPress` handler. Web resolves the library's Web entry and
uses KaTeX with MathML and `trust: false`. A test-owned Chrome sample rendered
inline and display MathML without a stylesheet; visual parity and
accessibility remain unverified. Directly importing `katex/dist/katex.min.css`
under this SDK's Metro emitted warnings for relative font URLs and exported
no corresponding fonts, so do not assume that import supplies working font
assets; Web font hosting and visual validation remain open.

Treat message Markdown as untrusted. This nightly supplies `resolveImageSource`
for image occurrences in GitHub flavor, including inline, lists and tables.
Return a controlled URI or `{uri: ''}`; `undefined` loads the original URL.
The native parser must be registered: `markdownImageResolverAvailable()`
checks `EnrichedMarkdownParser.collect` and UI must refuse the image branch if
it returns false. This is an availability check, not proof of every renderer
path; session changes require remount and release of generated URIs. Web ignores
resolver headers, and `onImagePress` does not prevent loading. Embedded video
and default links also need independent fail-closed handling. Never pass CFL
bearer headers to arbitrary URLs. SDK 58/RN 0.88.1
typecheck, Web/iOS JS exports and iOS autolinking resolution passed in an
isolated project; Xcode, iOS device behavior and UI acceptance were not tested.
See the [upstream compatibility table](https://docs.swmansion.com/enriched-markdown/misc/compatibility/)
and [Web support guide](https://docs.swmansion.com/enriched-markdown/react-native/guides/web-support/).

## Native iOS tabs

The SDK 58-recommended `react-native-screens` 4.30.1 is a direct dependency
and is MIT-licensed; retain its and transitive dependencies' license notices.
The iOS implementation in `src/NativeTabsFrame.ios.tsx` imports `Tabs` from
`react-native-screens` and uses its public `Tabs.Host` and `Tabs.Screen`.
The installed iOS implementation backs these with `UITabBarController`.
`Tabs.Host` receives the selection state and `tabBarHidden`; each screen
provides its accessibility label and SF Symbol. Web uses the separate
`NativeTabsFrame.tsx` fallback and the app's existing navigation.

Expo Router and its plugin are not used. `index.js` continues to register
`src/App.tsx`, and the existing `etosllmstudio://auth/callback` contract and
iOS bundle identifier are unchanged. `expo-constants` and `expo-linking` remain
transitive dependencies of Expo and `expo-auth-session`, respectively.

A development build that does not already contain this version of
`react-native-screens` must be rebuilt to include its native code; hot reload
cannot add it. Native tab rendering, keyboard and hiding behavior, SF Symbols,
accessibility, OAuth callback delivery and coexistence with an installed ETOS
app still require device or simulator verification. Node requirements are as
stated above. See the
[SDK 58 react-native-screens reference](https://docs.expo.dev/versions/v58.0.0/sdk/screens/).

## SDK selection evidence and limits

Historically, on 2026-11-09, identical isolated samples used the then-planned
Glassy RN source, Chat 6.1.5, and each SDK's recommended peers. Glassy has since
been removed; the findings below explain the SDK selection, not current UI:

- SDK 57.0.32 / RN 0.86.3 / Gesture Handler 2.32.0: original source passed
  TypeScript and Web/iOS JS bundling after `--legacy-peer-deps` was used only
  in that isolated test. Chat 6.1.5 requires Gesture Handler >=3; `npm ls`
  flagged the peer mismatch, and the Web sample failed at
  runtime because `usePanGesture` was unavailable. JS bundling alone was not
  enough to reveal the failure.
- SDK 58.0.23 / RN 0.88.1 / Gesture Handler 3.3.0: peers aligned. Original
  Glassy source bundled on Web/iOS but had ref-type errors. After a
  type-only adaptation, TypeScript and both bundles passed; a local
  Chromium sample rendered the Glassy controls and synthetic chat, accepted
  text input and a tab/button click without page errors.

The samples used no real service, account or model. Browser testing was a
small dependency smoke test, not a product UI or accessibility acceptance.
Those samples did not verify an iOS binary, Xcode build, physical device,
co-installed ETOS callback, or native glass rendering. Raw comparison logs are in the
local temporary directory `/tmp/etos-sdk58-inspect/` while it remains present.
The old SDK 55 was initially chosen from its documented React Native/Node
matrix; it was not required by the spec and was chosen before checking the
latest SDK and Glassy compatibility.

On 2026-11-09, `npm audit` reported five moderate dependency findings in the
Expo CLI / `glob` / `minimatch` chain, with no high or critical findings.
The proposed automated SDK downgrade was not applied because it conflicts
with the tested chat peer requirements. Recheck advisories before release.

## Attachment modules

Expo SDK 58's `expo-image-picker`, `expo-document-picker`,
`expo-image-manipulator`, and `expo-file-system` are installed with their SDK
recommended versions. The image-picker plugin sets photo and camera usage
descriptions and disables microphone permission. Native modules and config
changes require a new iOS development build; JS bundling is not a native or
device test. Expo recommends invoking Web pickers directly from a user gesture
and notes browser cancellation events are not always available. Document
picker cache copying enables immediate native file access. See the official
[ImagePicker](https://docs.expo.dev/versions/v58.0.0/sdk/imagepicker/),
[DocumentPicker](https://docs.expo.dev/versions/v58.0.0/sdk/document-picker/)
and [FileSystem](https://docs.expo.dev/versions/v58.0.0/sdk/filesystem/) docs.

## Update module

SDK 58's `expo-updates` 58.0.21 (MIT) is installed for future self-hosted
updates. `runtimeVersion` uses `fingerprint`; the reserved HTTPS manifest URL
is in `app.json`, with zero launch wait and embedded updates enabled. No
channel or Cloudflare service exists yet. The module and updated native
configuration require a new build; a previously installed build cannot gain
the URL merely from this package. Release-like device verification and
publication remain future work; see README for the protocol and prerequisites.
Normal Metro development is not OTA verification.

`expo-haptics` 58.0.7 (MIT) is installed as an SDK 58 native module. No UI
interaction currently invokes it. A build that lacks the module must be rebuilt;
physical haptics behavior has not been verified. See
[Expo Haptics](https://docs.expo.dev/versions/v58.0.0/sdk/haptics/).

## Additional development-build modules

`expo-clipboard` 58.0.4, `expo-audio` 58.0.11, `@expo/ui` 58.0.27 and
`expo-sharing` 58.0.22 are SDK 58 versions and MIT-licensed; retain their and
transitive dependencies' notices. `expo-asset` 58.0.20 (MIT) is explicitly
declared as the audio module's required peer. The current UI uses `@expo/ui`;
clipboard, audio playback and sharing are reserved for later use.
`expo-audio` is reserved for playback. Its config plugin explicitly disables
iOS microphone permission, Android recording permission, background recording
and background playback; no recording permission is requested by this app.
The haptics module adds Android's `VIBRATE` permission automatically.
`expo-sharing` alone does not implement an incoming-share handler or an iOS
share-extension target. Web sharing and local-file support differ by browser.

Each native module requires rebuilding a development binary that does not
already include it. Native compilation, actual clipboard/audio/share behavior,
SwiftUI rendering and physical device verification remain outstanding. See
Expo's [Clipboard](https://docs.expo.dev/versions/v58.0.0/sdk/clipboard/),
[Audio](https://docs.expo.dev/versions/v58.0.0/sdk/audio/),
[Expo UI](https://docs.expo.dev/versions/v58.0.0/sdk/ui/) and
[Sharing](https://docs.expo.dev/versions/v58.0.0/sdk/sharing/) references.
