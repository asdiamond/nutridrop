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
    ├── APIClient.swift
     ├── AuthSession.swift
     ├── ConnectClient.swift
    ├── ContentView.swift
    ├── Info.plist
    └── nutridropApp.swift
```

## WorkOS Connect

iOS and MCP clients use Connect OAuth access tokens for the same backend
resource. iOS is a public, first-party application using Authorization Code
with S256 PKCE. There is no client secret or WorkOS SDK dependency.

- Client ID: `client_01M1QJ50TXNKGVX06Q0CD98VPZ`
- Issuer: `https://resilient-quest-95-staging.authkit.app`
- Redirect: `app.nutridrop://auth/callback`
- Explicit resource: `https://nutridrop-mcp-staging.diamondaleksandr.workers.dev/mcp`
- Scopes: `openid offline_access`

`ConnectClient.swift` builds the authorization URL and performs form-encoded
code and refresh exchanges. `AuthSession.swift` opens `ASWebAuthenticationSession`,
validates the callback and state, and stores tokens in one
`AfterFirstUnlockThisDeviceOnly` Keychain item. Refresh requests are serialized;
replacement refresh tokens are persisted before use.

`APIClient.swift` calls `GET /v1/session` and receives `{ "userId": "user_..." }`
from the backend's single Connect verifier. No MCP requests, profile requests,
or ID-token parsing are needed in iOS. Access-token expiry is decoded locally
only to schedule refresh 60 seconds before expiration. Signing out deletes the
local session; it does not sign out the WorkOS browser session.

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

Push Notifications is enabled in Xcode. Debug signs with the development APNs
entitlement and uploads `sandbox`; Release signs with production and uploads
`production`. Enable Push Notifications for `app.nutridrop` in the Apple developer
portal and regenerate the manual `dist-2` distribution profile before TestFlight.
Remote Notifications background mode is enabled. The notification callback
stores only the last received record ID and receipt time, scoped to the signed-in
user, and displays them in the app. HealthKit writes and record fetching are not
implemented yet.

The app registers with APNs on launch/foreground and after authenticated backend
verification. APNs callbacks upload the current token through authenticated
`PUT /v1/push-token`. The token is held in memory, not persisted in the app.
Registration errors appear on the signed-in screen with a retry button.
No alert permission prompt is needed just to register for silent pushes.

One destination is stored per WorkOS user. The latest successful registration
replaces the prior phone. A token moving to another account is reassigned
atomically. Sign-out makes a best-effort conditional DELETE; offline sign-out
cannot guarantee server-side removal. Future pushes must be data-free wake-up
hints, and all data retrieval must still require authentication.

APNs tokens have no documented fixed TTL. Always obtain the current token from
APNs; after a token change Apple requires an app launch before delivery resumes.
Silent push delivery is best-effort, independently of token validity.

To test: launch a Debug build, sign in, and confirm **Push destination registered**.
Call `record_nutrition` from ChatGPT. Its `notificationStatus` reports submission
to APNs; **Last push received** in iOS confirms actual receipt. Background the app
without force-quitting it to test silent delivery, then reopen to inspect the saved
receipt timestamp. There is no alert banner. Only one destination is active, so
opening another signed-in installation may replace the phone you intended to test.
The current server key is sandbox-only and does not support TestFlight pushes.

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
