# ianautomat

ianautomat runs a goal against the ChatGPT Responses API and saves the resulting notes, checklists, and calculators as native tools. The control center supports pause, resume, stop, step limits, local history, and sharing. Checklists and calculators can be used offline after creation. The goal composer uses the system keyboard, including dictation when enabled. In Shortcuts, ianautomat can open the app or return the latest goal log after device authentication.

Requires iOS 17.4 or later. This project is the iPhone counterpart to [fuba/anautomat](https://github.com/fuba/anautomat). This port uses the iOS app sandbox and public frameworks. Other apps' screens, arbitrary taps, floating controls, and Android's Starlark device APIs are unavailable. A goal that needs them stops with a blocked result. To chain ianautomat with actions from other apps, use the Shortcuts app.

## Account and data

Use **Continue with ChatGPT** and approve ChatGPT plan usage. The app opens an iOS authentication session and accepts the OpenAI loopback callback only on the phone. It verifies the ID token and stores each registration in the device Keychain. Goals, generated tool titles, and requests are sent directly to OpenAI. Tool contents, completed checklist items, and local logs stay in the app's protected storage unless shared through iOS. The app uses Apple's operating-system cryptography and networking frameworks and has no third-party runtime dependencies.

## Build and test

Install Xcode and XcodeGen. Run these from the repository root, using an installed simulator from `xcrun simctl list devices`.

```sh
xcodegen generate
xcodebuild -project ianautomat.xcodeproj -scheme ianautomat \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build/ios-test -parallel-testing-enabled NO test
```

The tests cover OAuth state and PKCE, a real loopback TCP callback, RS256 signature and OIDC claims, iOS Keychain storage, streaming completion, tool validation, arithmetic, history, the system authentication prompt, and draft recovery after relaunch. A signed-in ChatGPT session is required to verify real model selection and inference end to end.

## TestFlight

See the [internal TestFlight instructions](docs/testflight.md).

## License

[MIT](LICENSE). The app icon uses the original anautomat [mark](design/android-use-icon.svg).
