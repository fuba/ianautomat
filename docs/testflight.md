# Internal TestFlight

The bundle ID is `dev.fuba.ianautomat`. Use the Apple Developer team that owns this ID and an Xcode account with distribution access. The first upload requires an iOS app record in App Store Connect. Suggested values are **ianautomat** for the name, **Japanese** for the primary language, **dev.fuba.ianautomat** for the bundle ID, and **ianautomat-ios** for the SKU.

```sh
scripts/testflight.sh prepare TEAM_ID 1
scripts/testflight.sh upload TEAM_ID 1
```

The first command creates the archive, exports an internal-only IPA, and verifies its distribution signature. It creates a new directory for the build number. The second command can be retried after creating the app record, and verifies the archive before uploading it. Both commands write logs under `build/ios-distribution/1/`. Use a higher build number for subsequent builds.

After processing, assign the build and the intended Apple Account to an internal TestFlight group. Open the invitation or TestFlight on the iPhone using the invited account, then install and open ianautomat. Smoke test **Continue with ChatGPT**, choose a model, and run `Make a three-item packing checklist`. Check one item, relaunch the app, and confirm the saved tool and checked item appear in the run. See [Apple's internal TestFlight guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers).

## Initial delivery

Version 0.1.0, build 1. iPhone simulator tests and signed IPA verification were performed on Xcode 27.2. The first upload attempt reported that the App Store Connect record did not exist. TestFlight processing, tester assignment, installation on a physical iPhone, and authenticated inference are pending.
