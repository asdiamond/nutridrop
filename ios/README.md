# Nutridrop iOS

## Open The Project

Open the Xcode project file, not the `ios/` directory:

```bash
open ios/nutridrop.xcodeproj
```

The repository layout is:

```text
ios/
├── nutridrop.xcodeproj/
└── nutridrop/
    ├── Assets.xcassets/
    ├── AuthSession.swift
    ├── ContentView.swift
    ├── Info.plist
    └── nutridropApp.swift
```

## WorkOS AuthKit

The app uses the official WorkOS iOS SDK as a public OAuth client. Sign-in opens
the WorkOS-hosted AuthKit page in `ASWebAuthenticationSession`, validates the
OAuth state, and exchanges the authorization code with PKCE. No API key or
backend is involved.

- Environment: Staging
- Application: `Nutridrop iOS`
- Client ID: `client_01M1M5XYKEKDP98RTMBQKMXC1H`
- Redirect URI: `app.nutridrop://auth/callback`
- Swift package: `https://github.com/workos/workos-ios`, version `0.6.0`

The WorkOS user and session tokens are stored together in an
`AfterFirstUnlockThisDeviceOnly` Keychain item. Signing out deletes this local
item. Token refresh and remote session revocation will be added when the app
starts making authenticated backend requests.

## Current Apple Configuration

- App Store Connect app: Nutridrop
- Bundle ID: `app.nutridrop`
- Apple developer team ID: `Z9369NJFAQ`
- Xcode target and scheme: `nutridrop`
- Marketing version: `1.0`
- Current build number: `1`
- Supported device families: iPhone and iPad
- Current deployment target: iOS `26.2`
- Xcode Cloud: not configured
- TestFlight internal testing: configured and verified on a personal iPhone

The architecture document describes iOS 18 as the intended minimum deployment
target. The generated Xcode project currently requires iOS 26.2, so lower the
deployment target before the app needs to support iOS 18 devices.

## Signing

Debug uses automatic signing with the paid Apple developer team. Directly
installing a Debug build on an iPhone requires that device to be registered with
the developer team. Simulator builds do not require a registered device.

Release uses manual signing:

- Signing certificate: Apple Distribution
- Provisioning profile: `dist-2`
- Bundle ID: `app.nutridrop`

The distribution certificate, its private key, and the provisioning profile are
local signing material and are not committed to this repository. On a new Mac:

1. Add the developer Apple ID under **Xcode > Settings > Accounts**.
2. Install or create the Apple Distribution certificate. A certificate created
   on another Mac also requires its private key to be exported and imported.
3. Download the `dist-2` profile from Certificates, Identifiers & Profiles.
4. Double-click the `.mobileprovision` file, or use **Download Manual Profiles**
   in Xcode's account settings.
5. Confirm that the target's Release signing configuration selects `dist-2`.

The provisioning profile's App ID must exactly match `app.nutridrop`.

## App Store Connect

App Store Connect is available at:

<https://appstoreconnect.apple.com/>

The App Store Connect app, registered Bundle ID, Xcode target, and provisioning
profile all use `app.nutridrop`.

The generated Info.plist sets:

```text
ITSAppUsesNonExemptEncryption = NO
```

This is correct while the app only uses encryption supplied by Apple's operating
system, such as HTTPS/TLS through standard Apple networking APIs. Reassess this
value if the app later implements its own encryption algorithms.

## App Icon

The AppIcon asset contains a temporary 1024 by 1024 PNG at:

```text
ios/nutridrop/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

Xcode derives the required iPhone and iPad icon sizes from this image. A
replacement icon should be a 1024 by 1024 PNG without transparency and can use
the same filename.

## Publish A TestFlight Build

Each upload must have a build number that has not previously been uploaded for
the same marketing version.

1. Open `ios/nutridrop.xcodeproj` in Xcode.
2. Select the `nutridrop` target.
3. Open **General > Identity**.
4. Increment **Build**, for example from `1` to `2`.
5. Keep **Version** at `1.0` until a new user-facing version is needed.
6. Select **Product > Destination > Any iOS Device** from the macOS menu bar.
7. Select **Product > Archive**.
8. In Organizer, select the newest archive and click **Distribute App**.
9. Choose **App Store Connect**, then **Upload**.
10. Keep the normal distribution defaults, complete validation, and upload.
11. Open **App Store Connect > Apps > Nutridrop > TestFlight**.
12. Wait for Apple to finish processing the build. This usually takes several
    minutes but can take longer.
13. Add the ready build to the existing internal testing group if App Store
    Connect does not add it automatically.
14. Open TestFlight on the iPhone and install or update Nutridrop.

TestFlight invites an Apple ID, not a device UDID. Internal TestFlight installs
and updates are wireless and do not require the iPhone to be registered as a
development device. TestFlight builds expire after 90 days.

## Version Numbers

The marketing version is the user-facing release version. The build number
identifies individual uploads:

```text
Version 1.0, Build 1
Version 1.0, Build 2
Version 1.0, Build 3
Version 1.1, Build 4
```

Build numbers should always increase. Uploading the same version and build
number twice is rejected.

## Capabilities

No special Apple capabilities are enabled yet. The planned app will eventually
need at least:

- HealthKit for writing nutrition data to Apple Health.
- Push Notifications for background synchronization hints.

Enable capabilities in both the Apple developer identifier and Xcode when they
are implemented. After changing entitlements, regenerate and download the App
Store provisioning profile so it contains the same capabilities.

## Troubleshooting

### No Development Provisioning Profile

Automatic Debug signing cannot generate a development profile until the team
has a registered device. This does not prevent TestFlight distribution when the
Release configuration uses the App Store distribution profile.

### Profile App ID Does Not Match

Confirm that all of these use exactly `app.nutridrop`:

- Xcode's Product Bundle Identifier
- Apple developer Bundle ID
- App Store Connect app
- App Store provisioning profile

The full App ID may be displayed as `Z9369NJFAQ.app.nutridrop`; the prefix is the
Apple team ID and is not part of Xcode's bundle identifier.

### Missing Icons Or CFBundleIconName

Confirm that `AppIcon.appiconset/Contents.json` references `AppIcon.png`, then
create a new archive. Fixes do not modify archives that were already created.

### Uploaded Build Is Not Visible

An upload that succeeds in Xcode must still be processed by Apple before it
appears in TestFlight. Check the correct App Store Connect app and wait before
uploading another build. If another upload is necessary, increment the build
number first.

### Organizer Does Not Open

Open it from **Window > Organizer** in the macOS menu bar.
