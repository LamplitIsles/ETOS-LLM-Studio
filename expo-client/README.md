# ETOS Expo client (in progress)

This directory contains the first Expo chat client and its connected UI.
Development can use the local synthetic CFL seed host, which persists its
synthetic state without a real account or model. The app has no built-in mock
conversation; an unauthenticated user sees the login screen. Unit tests keep
their process-local fixtures under `tests/fixtures`.
The chat UI composes FlashList and native/Web controls around the CFL data
controller; it does not depend on a bundled chat UI framework.

## iOS 开发（Mac）

项目已为 npm 12 授权固定版本 `react-native-enriched-markdown@1.2.0-nightly-20261109-ca015bcac` 所需的安装脚本。使用环境代理下载该库的原生资源时，Node 需启用环境代理，可运行 `NODE_USE_ENV_PROXY=1 npm ci`。

首次或原生工程需要更新时运行 `npm run ios:prepare`：生成 iOS 工程并使用当前 Ruby 用户目录中已有的 CocoaPods 安装 Pods，不清理缓存。日常在 Mac 上运行 `npm run dev`，让 iPhone 与 Mac 连接同一 WiFi，打开已安装的开发版 App。JS 和界面改动可热重载；原生依赖、配置或原生代码变化时先按需 prepare，再运行 `npm run ios:build` 检查未签名构建。

`npm run ios:build` 执行耗时的未签名编译；用户之后在 Mac 本机运行 `npm run ios:install` 仅签名已有 Debug 产物并安装到唯一已配对、开启开发者模式的 iPhone，不重新编译，安装后不启动 App。若缺少匹配此 App、设备和证书的开发描述文件，请先在 Mac Xcode 中准备开发签名，再运行安装命令。多台时使用 `npm run ios:install -- --device <identifier>`。若安装结果不明，先在设备上核对，再运行 `npm run ios:install:ack` 确认；如需重试，另行运行安装命令。Expo App 使用独立 bundle identifier，不覆盖旧 App。

需要脱离 Metro 的本地版本时，运行 `npm run ios:build:release` 构建未签名 Release；用户可在 Mac 本机运行 `npm run ios:install:release` 签名已有 Release 产物并安装，不重新编译（多台设备同样可加 `-- --device <identifier>`）。Release 内嵌生产 JS 和资源，安装后无需 Metro，真实聊天仍需连接网络。它与 Debug 使用相同的 `studio.etos.expo.dev` bundle ID，会替换当前 Expo 开发版，不覆盖旧 Swift App。此本地签名安装受开发签名有效期限制，不等同于 App Store 分发；OTA 更新尚未上线，不是此流程的前提。安装结果不明时 Debug 和 Release 共用上述确认流程。

构建复用既有 `~/Library/Developer/Xcode/DerivedData/ETOS_LLM_Studio-gbdwtrcvmcilytfthkwwgrxdjqbe`；如需指定另一个**已有**目录，设置 `ETOS_DERIVED_DATA`。默认签名 Team 为 `RL5WAW5828`，可用 `ETOS_DEVELOPMENT_TEAM` 覆盖。Mac 已完成 Expo iOS 原生未签名构建；真实登录和设备交互仍待验证。

## Development

Use Node 22.13+ (22.x), 24.3+ (24.x), 26.x, or 27+; the lockfile was
checked with Node 22.23.2. Run `npm ci`, `npm run typecheck`, and `npm test`.
The WebAuth default-fetch browser regression uses fake passkeys and a disposable
loopback host:

```sh
CHROME_PATH=/usr/bin/google-chrome node --test tests/web-auth-browser.cjs
```
Run `npm run web` on Linux for the explicit synthetic-seed mode. It requires
the CFL test host already running as `node apps/partner/tests/frontend-development-host.ts start 3090`
in its own checkout (Node 24 supports that TypeScript entry). The script never
starts, stops, seeds, resets, or cleans that host. It verifies the loopback
listener's process, fixture marker, and active lock using Linux `/proc` and
`ss`, failing closed if it cannot identify this exact test host. No other
backend is an acceptable target. `localhost:8091` serves the development
proxy and Metro runs on `127.0.0.1:8092`; both ports must be free before
starting. It does not open a browser. Hot reload passes through the proxy;
Expo disables file watching if `CI=1` is set.

The proxy exposes the synthetic chat, appearance and tightly scoped sticker,
image and file routes needed for explicit user sends. It accepts only the listed development Hosts and a matching Origin,
blocks cross-site requests, drops credentials and forwarded headers, and does
not send cookies or CORS grants back. It verifies the process again before each
connection; these checks prevent accidental use of an ordinary CFL host, not a
malicious process controlled by the same local OS user. No production route,
credential, origin rule, or HTTPS requirement is changed. When changing the proxy or npm script, restart the existing
8091 process explicitly; these files cannot reconfigure a running server.
For exact sticker-media and chat image preview/original GET paths, the proxy
forwards `If-None-Match` and a location-free 304 response to a conditional
request; other seed redirects remain blocked. Web media uses the browser's
normal HTTP cache policy, subject to the server's
headers and authorization. This does not provide offline chat or establish
native iOS cache behavior.

The browser tests use a test-owned synthetic CFL protocol host. In an isolated
checkout, choose a free test-only Metro port and start Metro and the test host
in two terminals:

```sh
EXPO_PUBLIC_ETOS_SYNTHETIC_SEED=1 npx expo start --localhost --port 18092 --max-workers 2
npm run test:ui:host -- 18092
```

The proxy and backend bind only loopback using random ports; the proxy prints
its port. An optional second argument selects a proxy port. In another terminal,
use the printed port and, if needed, a local Chromium executable:

```sh
ETOS_UI_PROXY_PORT=<printed-port> CHROME_PATH=/usr/bin/google-chrome npm run test:ui
```

Run `node tests/composer-ui.cjs` and `node tests/motion-ui.cjs` with the same
environment variables for the other browser checks. Start a fresh test host
for each test so its in-memory conversation is clean. These tests send messages;
never point them at shared development data or a real session.
`tests/ui-test-context.cjs` routes browser HTTP and WebSocket traffic for the
virtual `http://127.0.0.1:8091` origin to `ETOS_UI_PROXY_PORT`, retaining the
required Host and Origin. It rejects the common shared service ports 3090,
5173, 8081, 8082, 8091 and 8092. The host can also be started programmatically with `startFixtureSeedHost()` from
`tests/fixtures/seed-host.ts`; it returns `request`, `setStatus` and `close`.
The pinned Playwright dependency can use Chromium installed with
`npx playwright install chromium`; omit `CHROME_PATH` to use that browser.

For the 180-message FlashList browser regression, start a separate test-only
Metro as above, then start a fresh fixture with 173 extra messages:

```sh
ETOS_UI_SYNTHETIC_EXTRA_MESSAGES=173 npm run test:ui:host -- 18092
```

Use both the printed test-only proxy and fixture control ports:

```sh
ETOS_UI_PROXY_PORT=<proxy-port> ETOS_UI_SYNTHETIC_HOST_PORT=<control-port> CHROME_PATH=/usr/bin/google-chrome node tests/flash-timeline-ui.cjs
```

Never use shared service ports or shared development data for these tests.

The browser checks cover login, navigation, chat, attachment and sticker interactions.
The motion check verifies panel usability with regular and reduced motion; it does not
measure animation frames or validate native iOS behavior.

For a browser on a different computer, forward only the development frontend:
`ssh -N -L 8091:127.0.0.1:8091 gg-vps`, then open
`http://localhost:8091` on that computer. SSH encrypts the remote hop. Keep
3090 and 8092 private; no additional forwarding is needed.
Mac `npm run dev` continues to use port 8081 for the native development build.

For an explicitly allowed phone on the Mac's local network, determine the
Mac's private IPv4 address (for example `192.168.1.23`) and start the server
with exactly that address: `ETOS_SEED_LAN_HOST=192.168.1.23 npm run web`.
On the Mac, run
`ssh -N -g -L 0.0.0.0:8091:127.0.0.1:8091 gg-vps`, then open
`http://192.168.1.23:8091` on the phone. Replace the example address and SSH
alias with your own; the Mac's 8091 must be free, and its firewall must permit
the phone. Stop the SSH command when done. This exposes the synthetic fixture
to the local network without authentication and sends its data in cleartext
between phone and Mac; use it only on a trusted network with synthetic data.
The server still binds 127.0.0.1 and accepts only localhost, 127.0.0.1 or the
single configured RFC1918 IPv4 address, all at port 8091. Changing the Mac IP
requires restarting the server with the new address. The test-only identity
check and fixed CFL destination still apply; no real CFL authentication is
available in this mode.

A LAN HTTP page is not a secure browser context. The synthetic chat uses
`crypto.getRandomValues` for operation IDs when `crypto.randomUUID` is absent;
it fails if secure random bytes are unavailable. Passkeys and other secure
context APIs remain unavailable here. A native device's localhost refers to
the device itself, so this Web-only development path does not configure an
iPhone app. Native testing needs a separately approved reachable endpoint and
retains the existing HTTPS/auth requirements.

Image and document pickers, image manipulation and native file access use the
SDK 58 modules in the lockfile. Photo and camera usage descriptions are
configured; microphone permission is disabled. Document selection uses a
cache copy; no app iCloud entitlement is configured. Adding
these native modules requires rebuilding the iOS development binary; neither the
native build nor an iPhone picker has been verified here. The seed proxy must be
restarted to load its new routes. Unit tests use only test-owned fixtures or
independent fake hosts; the running shared seed was not inspected for sticker
or attachment contents.

See [DEPENDENCIES.md](DEPENDENCIES.md) for the Expo SDK, system controls,
peer dependencies, licensing, and platform validation limits.

## UI integration

- Synthetic seed Web: when `developmentSeedAvailable()` from
  `src/cfl/seed.web.ts` is true, `createDevelopmentSeedChat()` returns the
  same `{controller, media}` interface. The flag is compiled into the bundle
  only by `npm run web`, and the guard also requires `__DEV__` and the exact
  HTTP loopback origin or the explicitly configured private LAN origin. It uses
  an isolated synthetic recovery journal per origin. `developmentSeedStatus()`
  checks the fake owner's status without credentials; it is not real CFL
  authentication. If unavailable, do not substitute fixture data. Do not call
  real `WebAuth` for the seed.
- A chat client supplies `{controller, media}`.
  `controller.start()`, `subscribe(listener)`, `snapshot()`, `loadOlder()`,
  `send(text)`, `reconcile()`, and `stop()` form the integration surface.
  Always unsubscribe and stop on disposal. Use `snapshot.view` for the current
  server-ordered window and streaming reply, `snapshot.history` for earlier
  pages, and `snapshot.pending` for accepted local operations.
  `snapshot.failure === 'access_denied'` requires a new explicit login;
  unavailable connections retry without treating a network outage as logout. Preserve the
  message and operation IDs when presenting these arrays; deduplicate any local
  item once its server `operationId` appears. A pending `submitted` item is
  retained until it is visible in the server view. `unknown` is not a user
  failure; the controller looks it up and never automatically resends it.
- After the controller has started and its chat view is established, call
  `loadAppearance(media, controller.scope())` from `src/cfl/appearance.ts`.
  It returns `{companionName, userName, companionAvatar, backgrounds}` (the
  last two fields are booleans) or `null` when appearance is unavailable on
  that host. For an advertised asset, call `loadAppearanceImage(media, kind,
  controller.scope())`, where `kind` is `companionAvatar`, `landscape` or
  `portrait`. It returns `{bytes, contentType}` or `null` on 404. The CFL host
  itself can serve the other orientation when one background is missing.
  These functions use the same authenticated native or same-origin Web media
  transport, reject redirects and untrusted appearance paths, and enforce
  64 KiB metadata, 5 MiB avatar and 20 MiB background limits while streaming.
  They reject stale session results with `session_changed`, authorization
  failures with `access_denied`, and invalid metadata or images with
  `invalid_appearance` or `invalid_media`. Capture a fresh scope per request;
  also ignore results after the owning UI unmounts and revoke UI object URLs.
- For the composer, keep `media` typed as `ApiTransport`. Call
  `pickImages(scope)` or `pickFiles(scope)` from `src/cfl/drafts.ts` directly
  in a user gesture. They return `AttachmentDraft[] | null`; `null` is a
  cancellation. Each draft has a stable `id`, `name`, `size`, `mediaType`,
  `kind`, `uri` (local preview), `body` and idempotent `release()`. Call
  `release()` when a draft is removed, retired or its owner is disposed; Web
  revokes its picker object URL, while native only removes a recognized
  DocumentPicker cache copy. Drop references after release. Web browsers may
  never report a canceled picker; retain the draft while waiting. iOS uses
  the compatible photo representation where available; CFL accepts JPEG,
  PNG, WebP and GIF, so unsupported or oversized selections are rejected.
- After `capturePhoto(current)` returns one iOS camera draft, call
  `prepareCameraPhoto(view, existingDrafts, photo, current)` from
  `src/cfl/camera-photo.ts` before adding it to the UI. It consumes `photo`:
  on success the caller owns and must eventually release the returned draft;
  on failure or `session_changed` the function releases the camera draft and
  any recognized new ImageManipulator cache file. It never releases existing
  drafts. Prevent concurrent selection/sending while it runs, and recheck the
  current session and latest view after awaiting; if the result can no longer
  be used, release it. A compliant original is returned unchanged. Only an
  over-budget camera image is encoded once as full-size WebP at quality 0.8,
  if advertised by the service; no automatic retries or uploads occur.
  `CameraPhotoError.code` distinguishes `images_unavailable`,
  `camera_image_count_limit`, `camera_image_budget_exhausted`,
  `camera_webp_unsupported`, `camera_image_too_large`, and
  `camera_encoding_failed`. For `camera_image_too_large`, `actualBytes` and
  `maxBytes` are the encoded file size and effective single/remaining total
  limit. Other invalid draft errors and `session_changed` remain distinct.
  WebP encoding can alter original EXIF, HDR, color and fine detail; real iOS
  capture, orientation and CFL/agent interpretation still require device tests.
- On iOS, call `capturePhoto(current)` from `src/cfl/drafts.ts` after the
  user requests the system camera. It requests camera permission and returns
  the same `AttachmentDraft[] | null` shape (`null` means canceled). A denied
  permission throws `CameraPermissionError` with code
  `camera_permission_denied` and `canAskAgain`; another platform throws
  `camera_unavailable`. Combine a fresh `controller.scope()` with the
  component's mounted/client identity in `current`; scope alone does not
  detect an unmounted component. A late permission or camera result is
  discarded and throws `session_changed`. Merge the result with existing
  drafts and call `validateDrafts` before showing it; release rejected,
  removed or disposed drafts. Camera files are deleted only when recognized
  as ImagePicker-owned UUID files in its cache; otherwise they remain in the
  OS-managed cache. Captured pictures use the existing upload and send path.
- `validateDrafts(view, drafts)` from `src/cfl/intake.ts` checks both media
  sets against the current server capabilities before any upload. Use it when
  adding selections and again on send; preserve existing drafts on failure.
  Contract hard ceilings are six images (8 MB each, 24 MB total) and six
  files (100 MB each, 200 MB total); the server may advertise lower limits.
  Image preview/model JPEGs are limited to 160 KB/320 KB respectively.
  `sendDrafts(controller, media, text, drafts)` from `src/cfl/composer.ts`
  prepares images and streams files with one operation ID, then journals the
  complete references before one chat dispatch. It resolves to
  `{origin, sessionId, operationId, state}` where state is `submitted`, `observed`, `failed`, or
  `unknown`. Before dispatch, rejection means keep text and drafts; on
  `failed`, keep them for explicit user action. On `submitted`/`observed`,
  clear the composer but retain preview resources until no timeline item needs
  them, then release. On `unknown`, keep the operation identity separate from
  any new draft and never re-dispatch it. The current UI locks its composer;
  a later UI change must preserve the unknown operation independently and must
  not mistake a new user action for a retry of it. On snapshot updates, call
  `await controller.operationStatus({origin, sessionId, operationId})`.
  This method uses
  a persisted receipt or an actual matching message in the current view or
  loaded history. A missing pending entry is never proof of observation.
  It returns `unknown` when the origin/session is not active, after stop,
  when storage cannot be read, or when evidence is absent. Recheck component
  lifetime and session after awaiting it. Switching back to the session and
  restarting the controller allows journaled receipts to be checked again.
  Reconnect reconciles by ID only; it never reuploads or resubmits. Picker data
  and previews are in memory/cache and do not survive an app restart as drafts:
  tell the user the selected files need to be chosen again if an operation is
  explicitly known to have failed. If the result remains unknown, explain that
  it is being checked; do not silently create a new operation or upload again.
  A returned `unknown` does not guarantee an entry is still in the journal:
  an observed message may already have retired it, or storage may be unavailable.
  Staged references do not guarantee that the server still retains their bytes.
- Create `new StickerClient(media, sessionId, current)` from
  `src/cfl/stickers.ts`, where `current` combines component lifetime with a
  fresh `controller.scope()`. `page('packs' | 'pack' | 'favorites' | 'search',
  {cursor, limit, packId, query})` provides validated pages and `nextCursor`;
  `media(version, 'thumbnail' | 'original')` returns bounded image bytes or
  null on 404 (page limit 30; thumbnail 160 KB, original 5 MiB).
  `favorite(stickerId, favorite)` adds or removes a catalog sticker;
  `favoriteImage(imageRef)` adds an available chat image, reusing its existing
  sticker ID when present. Both return a validated `{sticker, favorite}` and
  use the same scoped authentication; pass an `AbortSignal` as the optional
  fourth constructor argument. A cancelled, failed or stale request may have
  committed: refresh the favorites page to determine the state and never
  automatically repeat the mutation. Serialize favorite changes and discard
  older in-flight favorites pages when a change starts, so a late page cannot
  overwrite the refreshed state. Call `sendSticker(controller, media, {id, version})` on the
  user's selection for the existing immediate-send behavior; its outcome uses
  the same states as `sendDrafts`. Display a sent/historical sticker via its
  message image attachment ID with `loadImage(media, id, scope, 'original')`;
  that preserves original animation and transparency. `StickerClient.media`
  reads the catalog, which need not match a message snapshot. `loadFile(media, ref, scope)`
  from `src/cfl/files.ts` provides bounded bytes or null for a missing file;
  large file downloads may temporarily occupy memory up to the CFL size limit.
  Treat filenames and MIME values as untrusted and render historical files
  readably even when downloading is unavailable.
- `loadImage(media, attachmentId, controller.scope())` returns bounded image
  bytes and MIME type, checks the captured session lifetime after each await,
  and falls back from preview to original only on 404. Errors distinguish
  missing, access denied, invalid media, stale session, and unavailable.
  Render images, sticker references and file names on their original message;
  voice, `ui`, and other unsupported content remain visible placeholders.
  Do not treat unsupported objects as message text. Revoke any UI-created
  object URLs and do not embed authentication tokens in image URLs.
- `loadMarkdownImage(source, media, {workspaceImages, isCurrent, signal})`
  from `src/cfl/markdown-image.ts` reads the original Markdown image destination.
  Set `workspaceImages` only when the current chat view capability is true;
  combine a fresh `controller.scope()` with component lifetime for `isCurrent`.
  Workspace paths use the shared CFL encoding contract. Relative and absolute
  URLs on the configured CFL origin are restricted to known image API routes
  and fetched through the authenticated transport. Cross-origin HTTP(S) uses a
  separate credential-free, no-redirect fetch; byte loading validates MIME, a
  20 MiB limit and session lifetime. Browser cross-origin fetch needs CORS.
  `classifyMarkdownImage(source, media.origin, {workspaceImages, isCurrent,
  signal})` returns `{kind: 'api', path}` or `{kind: 'external', url}`. A Web
  resolver may return only the validated external `url` directly to an `img`,
  avoiding the cross-origin fetch/CORS requirement; use `loadMarkdownImage` for
  API sources and all iOS sources. Recheck scope and cancellation before
  returning a resolver result, and remove the image on session change/unmount.
  Direct browser image requests follow browser cookie, redirect, referrer,
  mixed-content and privacy policies; the app does not attach a CFL bearer, but
  cannot impose the byte loader's MIME/size/redirect checks or cancel a request
  already handed to the browser. A remote URL may redirect. This API prepares
  that Web integration; the current UI must explicitly use the classifier.
  Use `createMarkdownImageUri(image, isCurrent, signal)` for a Web Blob URL or
  iOS unique temporary cache file; call its idempotent `release()` on removal,
  session change and unmount. Late resources are released. A process crash may
  leave an iOS cache file until the OS clears cache; no unrelated cache is touched.
  On iOS, check `markdownImageResolverAvailable()` before enabling the nightly
  GitHub-flavor resolver; a missing parser otherwise falls back to untrusted URLs.
  Always return a controlled URI or `{uri: ''}`, never `undefined` for failure.
- Real iOS: `createNativeAuth()`; call `select(httpsOrigin)` then `signIn()`
  only on explicit user action. Pass that same auth and origin to
  `createNativeChat(origin, auth)` from `factory.native.ts`. Stop the old
  controller before switching origin, signing out, or replacing authorization.
  `signOut()` deletes this app's own grant; it deliberately does not sign out
  the shared CFL browser session. `tokenFor` binds a bearer to its selected
  origin. The native store uses a separate Keychain service and device-only
  accessibility. Its rotating refresh is marked pending before dispatch; a
  lost response requires a new login and is never replayed.
- Real Web: `WebAuth` in `web-auth.ts` uses the current document's origin and
  CFL's Passkey/cookie endpoints. `status`, `signIn`, `pair`, and `signOut`
  require explicit UI invocation. `createWebChat()` accepts only the current
  HTTPS origin. Web sign-out revokes CFL grants associated with that browser
  session; successful new passkey pairing replaces the old passkey and revokes
  old sessions/grants. Do not use pairing as a harmless connectivity test.
  The synthetic dev proxy is never real CFL auth; use its separate API above.

The recovery journal uses AsyncStorage and contains pending message text,
operation IDs, and staged attachment references/metadata, not tokens or file bytes; it is app-local but not encrypted. Origin and
session IDs scope recovery. If persistent storage fails, sending must fail
before dispatch; unknown operations are queried by ID, never replayed. An
absent operation is not proof of failure and may remain unknown indefinitely.
The new contract has no `finalizeSubmission`: an attempt-scoped delivery result
or lookup can establish submission/failure, while a matching message establishes
observation. Older unversioned terminal journal states are treated as unknown
until established again. User-initiated retry of failed messages is not
implemented yet.

## Future self-hosted updates

`expo-updates` is installed, `runtimeVersion` uses Expo's `fingerprint`
policy, and the next native build reserves the confirmed manifest URL
`https://updates.lamplit.run/v1/manifest`. **OTA is not available yet:** the
self-hosted service is not deployed and there is no channel or published
update. Metro hot reload in a normal development build is separate from OTA
distribution.

The intended future service is self-hosted on Cloudflare; no EAS project is
required by this preparation. Before distributing updates, establish the
compatible runtime and platform, any release channel and its request-header
contract, service and asset hosting, publishing access, and signing/trust
policy. A custom server
must implement [Expo Updates protocol v1](https://docs.expo.dev/technical-specs/expo-updates-1/),
including compatible manifest responses and the launch bundle and assets.
The protocol selects by platform and runtime version; a channel is an
additional server-defined convention, not an automatic Cloudflare feature.
For example, a future server could agree to use an `expo-channel-name` header
in `updates.requestHeaders`, but neither that header nor a channel is
configured here. Expo's [custom-server example](https://github.com/expo/custom-expo-updates-server)
is a demonstration, not a production-ready Cloudflare deployment.

An existing installed build without this URL cannot gain it merely through
Metro; regenerate the native configuration and rebuild/install it. The
configured zero launch wait selects a locally available update while the
normal launch check runs; Expo's embedded-update and anti-bricking protections
remain enabled. This is the intended release behavior when the server is
unavailable, not a verified iOS startup result. A normal development build
loads JavaScript from Metro and does not establish release OTA behavior. An
OTA update can replace compatible JS and assets, not add native modules or
iOS permissions. Camera permission, `expo-updates`, and the URL require a new
native build. Test a separately configured release-like build against the
actual server and device after authorization. See
[Expo Updates SDK 58](https://docs.expo.dev/versions/v58.0.0/sdk/updates/).

## Authentication and release limitations

The registered CFL public OAuth client only permits
`etosllmstudio://auth/callback`. Expo Go cannot customize this scheme; iOS needs
an Expo development build with a separate bundle identifier and this scheme.
Apple documents that ASWebAuthenticationSession routes its callback to the
calling session even if schemes collide; ordinary deep links with a duplicated
scheme have undefined routing. Co-installation with existing ETOS, the native
network stack and authorization flow have **not** been validated on an iPhone.
A local iOS build requires macOS/Xcode; the unsigned native build has completed on Mac. Signing, installation, and real device validation for this Expo client remain to be verified.

CFL requires its canonical origin for Passkey RP, browser session, HTTP and
WebSocket. An Expo server at a different localhost port is not that origin and
cannot directly authenticate against a remote CFL. Do not rewrite Origin,
weaken CSRF checks, proxy credentials across origins, or put tokens in URLs.
Real Web use requires later authorized same-origin serving/routing on CFL. Its
current published frontend artifact selection and contract validation do not
already support an arbitrary Expo export; no remote frontend was deployed. A
future replacement must also preserve CFL's `/consent` authorization flow
and its current login page behavior for native OAuth; supplying chat assets
alone is not a complete frontend replacement.

The locally vendored `@lamplit/contracts` snapshot and its license are in
`vendor/contracts`; it is not currently published to npm. Update it together
with protocol tests. This project is not yet a replacement for ETOS or Lamplit
App. No real account, real model, production deployment, iOS device, or
co-installed app was tested here.

### 会话图片与近期表情的数据接口

聊天图片可用 `controller.readImage(media, attachmentId, active, variant, signal)`；`variant` 为 `preview`（默认）或 `original`。调用方在每个组件生命周期创建 AbortController，卸载时设 `active = false` 并 `abort()`；会话切换或 controller.stop 时缓存和在途读取被清除。原图片仍经现有认证 transport、禁止重定向、MIME 和大小检查；仅成功结果在本 controller 内按 transport/origin/附件/变体保存内存副本，最多 48 项、16 MB，30 天到期，最多 16 个不同在途读取，其余按 FIFO 等待；卸载取消等待项。调用方取得的是独立字节副本。应用内副本的 30 天内命中不会向 CFL 重新核验，已明确接受这一新鲜度/撤权边界；已收到 401/403 或认证失效时清理，不将错误降级为旧内容。它不改变 HTTP 缓存语义、不写磁盘，也不提供离线聊天。UI 须接线调用此接口；旧的 `loadImage` 本身不使用该缓存。

`recentStickers(controller)` 从当前 snapshot 已加载的历史及消息提取用户和 agent 最近最多 30 个按 ID 去重的表情，保留最新消息的版本和附件引用；它不是全历史或跨重启记录。显示历史快照可用条目的 `image.attachmentId` 和 `original` 读取。点击时同步调用 `recentStickerIdentity(controller, recent, item)`；返回 null 说明身份不属于该 controller/会话代际或未观察，应忽略。取得身份后立即交给现有 `sendSticker(controller, media, identity)`，由 stage 在服务端核验实际版本与可用性，不要求目录页先加载。`resolveRecentSticker` 只是可选的当前目录页信息，`unresolved` 不代表删除；stage 的访问拒绝、不可用及其他异常沿原发送错误路径处理，未知聊天提交只核对、不自动重发。stage 响应丢失本身也可能留下服务端暂存。


### 聊天历史搜索

`controller.search(query)` 与 `controller.searchRead(id)` 调用当前在线连接的既有只读搜索协议；`cancelSearch()` 在搜索界面关闭时使未完成结果失效（并不保证取消服务端 RPC）。新搜索使旧搜索和旧详情失效，新详情使旧详情失效；切换会话、停止或断连后迟到结果不可使用。错误包括 `offline`、`session_changed`、`search_superseded`、`search_unavailable`，以及现有输入/响应校验和后端错误，调用方应区分失效结果与可展示错误。查询去除首尾空白后须非空，协议限制输入最多 500 字符、返回最多 20 条，详情上下文最多 17 项和 12,000 个 Unicode 码点。搜索结果记录 ID 是服务端不透明历史身份，可能来自授权档案内其他历史会话，不能当作当前聊天消息 ID；`searchRead` 的 `context.targetSourceRecordIndex` 对应上下文项目，可用于展示和定位，目标未必在截取的项目里。授权范围由服务端决定，搜索不会切换聊天或写入任何设置。

### 模型设置数据接口

`new ModelSettingsClient(controller, media).load()` 只读返回 `{ sessionId, currentModel, fast, busy }`；`MODEL_CHOICES` 列出 CFL 当前支持的三个可写选项，当前模型即使不在列表中也可展示。用户明确选择后，调用 `select(snapshot, { model, fast })`；必须传该 controller、transport 与在线连接最近读取返回的原快照，不能复制或复用已消费的快照。提交使用 `sessionId/expectedModel/expectedFast`，同一 controller 并发提交及提交时读取会被拒绝。

返回 `saved` 时使用其 `snapshot`；`stale_model` / `model_busy` 为明确冲突，接口会只读刷新一次并在可用时返回 `snapshot`，刷新失败则为 null，提示用户刷新或等待；`access_denied`、`invalid_request`、`invalid_model` 表示相应拒绝。`unknown` 表示请求可能已生效：提示结果未确认，由用户读取当前设置并检查，不自动重发。读取只反映当时状态，没有操作回执，不能证明先前迟到的写入不会随后生效；任何进一步修改都必须由用户重新明确选择。断连/会话变化后的迟到提交结果也为 `unknown`；读取错误使用 `offline`、`session_changed`、`model_superseded`、`model_settings_unsupported`、`model_settings_unavailable`、`invalid_model_settings` 或 `access_denied`，前端应自行处理失效和关闭。此接口不修改背景或语音设置。开发 seed 只额外开放该路径的 GET/POST；正在运行的代理须由管理者重启后才会加载新的服务端白名单。

### 背景设置数据接口

在线时创建 `new BackgroundSettingsClient(controller, media, active)`；实例绑定创建时的来源、会话与连接，`active` 可结合组件生命周期，卸载时调用 `client.dispose()`，picker 应传 `client.current` 以在切换或卸载时丢弃迟到选择。`load()` 读取 `{ landscape, portrait }` 配置标志；不存在的一边在 CFL 图片读取时可以回退到另一边。用户明确选择后，`save('landscape' | 'portrait', asset)` 接受已有选图的 `{ body: Blob, mediaType, size }`，不接管资产：调用方等待 Promise 结束后在所有结果下 `release()` 自己的草稿；取消选择无需调用 save。客户端最多读取 20 MiB，校验实际长度、PNG/JPEG/WebP/GIF MIME 和文件签名；完整解码、单帧和 4,000 万像素限制由 CFL 检查，CFL 以不超过 2560 像素长边的 WebP 保存。提交会产生有界内存副本；原文件不被修改。未新增依赖，现用 expo-image-picker 58.0.10 与 expo-file-system 58.0.13 许可均为 MIT。

`saved` 带配置标志，调用方随后使用现有 `loadAppearance` 和 `loadAppearanceImage` 重新加载可显示的服务端图像，并在每次 await 后核对 `client.current()`；当前 App 的 appearance effect 只在 client/session 改变时触发，UI 接线需要显式刷新。`background_settings_busy`、`invalid_background`、`invalid_background_type`、`background_too_large` 为明确拒绝，适合提示稍后再试、图片无效、格式不支持或超过 20 MiB；预检错误直接抛出同名错误或 `background_read_failed`。`unknown` 表示可能已保存，网络错误、断连、会话或组件失效及派发后的 401/403 都可能如此；提示用户刷新检查，绝不自动重发。没有 CAS 或操作回执，重读只表示当下状态，不能证明迟到的写入已经结束。`background_write_pending` 防同一 controller 的并发保存；`load()` 还可能抛 `session_changed`、`background_superseded`、`access_denied`、`background_settings_unsupported`、`background_settings_unavailable`、`invalid_background_settings`。合成宿主仅模拟存取与回退，不模拟服务器的真实解码及 WebP 转换。新的开发代理白名单需由管理者择机重启后生效。

### 语音输出设置数据接口

`new TtsSettingsClient(controller, media, active?)` 绑定当前连接与会话；界面卸载时 `dispose()`，后续 `current()` 永久为 false。`load()` 读取 CFL 的共享 TTS 快照，`save({ provider, voice, speed })` 只在用户明确保存时调用：provider 为 `minimax`、`alibaba`、`bytedance` 或 `elevenlabs`；voice 去除首尾空白后非空、最多 512 字符。minimax/bytedance 的 speed 为 null 或 0.5–2，alibaba/elevenlabs 必须为 null。配置影响 CFL 后续为所有客户端生成的 agent 语音，不意味着本 Expo 已支持播放或录音。

`setKey(provider, apiKey)` 只接受后三种 provider，由用户明确提交；key 必须通过请求体发送给 CFL，除此之外数据层不存储、记录或回显它，结果仅含状态。调用方应清空输入，不要把 key 写入状态持久化或日志；JavaScript 字符串无法保证物理擦除。已派发写入的 401/403、网络中断、scope 失效、损坏响应或 5xx 返回 `unknown`，提示用户检查，不自动重发；重读 `configured` 或设置不能证明此前请求已结束或新的 key 已被采用。`tts_settings_busy` 和相应 `invalid_tts_settings` / `invalid_tts_key` 是明确拒绝；GET 不支持抛 `tts_unsupported`，测试 seed 的 key 写入也返回 `tts_unsupported`。

`listElevenLabsVoices(cursor?)` 仅由用户点击查询或下一页时调用，返回 `{ voices, nextCursor }`；真实 CFL 会请求外部 ElevenLabs，可能受到配额或费用限制。它不会在构造、load、save 或 setKey 时自动执行。请求/结果有严格 schema、游标、大小和来源检查；同一 controller 同时只允许一个设置写入，新写入会使在途旧读取失效。读取错误包括 `offline`、`session_changed`、`tts_write_pending`、`tts_superseded`、`access_denied`、`tts_unsupported`、`tts_unavailable`、`tts_key_required`、`invalid_tts_response` 和 `invalid_tts_cursor`。

为防误用真实密钥或 provider，固定的 3090 合成开发代理只开放 TTS settings GET/POST，不转发 key 或 ElevenLabs 声音列表；这两项在该 seed 中不可用。仅测试专属代理启用精确的合成 key/list 路径，fixture 只接受 `fixture-` 开头的合成 key、只保存已配置布尔并返回合成声音，不联网。运行中的代理需由管理者择机重启才会加载新白名单。此数据层无新依赖；预装的 `expo-audio` 58.0.11 为 MIT，但此次没有实现播放或新增原生能力。
