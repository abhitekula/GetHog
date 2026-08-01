# Bundled rrweb-player

GetHog's native replay player must work with no network access, so rrweb-player is
vendored here rather than loaded from a CDN. `index.html` is loaded with
`WKWebView.loadFileURL(_:allowingReadAccessTo:)` and references both assets with
relative paths, so nothing in this folder may reach the network at runtime.

## Contents

| File                  | Source                                    | SHA-256 (first 16) |
| --------------------- | ----------------------------------------- | ------------------ |
| `rrweb-player.min.js` | `rrweb-player@2.1.1` `dist/rrweb-player.umd.min.cjs` | `d522d74c6dd2feca` |
| `rrweb-player.css`    | `rrweb-player@2.1.1` `dist/style.css`     | `760311ccb2da5389` |
| `index.html`          | written for GetHog                        | —                  |

Both vendored files are byte-for-byte copies of the published npm tarball
(`https://registry.npmjs.org/rrweb-player/-/rrweb-player-2.1.1.tgz`,
SHA-256 `844c45658b1f4bb718f44a42ad8fad1dec0f654180b1769254fb7aecbc5c49cf`).
rrweb-player is MIT licensed; its notice names the rrweb contributors. See the
repository-wide [third-party notices](../../../THIRD_PARTY_NOTICES.md) for its
license text.

The **UMD** build is used deliberately: an ES-module `import` from a `file://`
origin is subject to CORS in WebKit, while a plain `<script src>` is not.
`style.css` is self-contained — its only image is an inline `data:` URI.

## Refreshing to a newer rrweb-player

```sh
curl -L -o rrweb-player.tgz \
  https://registry.npmjs.org/rrweb-player/-/rrweb-player-<version>.tgz
tar xzf rrweb-player.tgz
cp package/dist/rrweb-player.umd.min.cjs rrweb-player.min.js
cp package/dist/style.css                rrweb-player.css
```

Then re-check the three assumptions `index.html` makes about the library:

1. the UMD global is `window.rrwebPlayer`, with the component on `.default`;
2. `showController: false` hides the controller's DOM but still mounts the
   component, so `play` / `pause` / `goto` / `setSpeed` / `toggleSkipInactive`
   and the `ui-update-*` events keep working;
3. `addEvent()` appends to a playing timeline, which is what progressive
   loading depends on.

If any of those change, `ReplayPlayerView` degrades to its "Replay unavailable"
card and the session timeline keeps working — but the shim needs updating.
