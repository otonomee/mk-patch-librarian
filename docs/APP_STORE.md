# Mac App Store Builds

App Store builds come from the Xcode project in `App/`, which wraps the Swift package as a local package dependency. Sources stay in SwiftPM; the project adds only the app target, its Info.plist, entitlements, privacy manifest, and icon. `bundle.sh` remains the quick unsandboxed development build.

## Layout

| Path | Purpose |
|---|---|
| `App/MKPatchLibrarian.xcodeproj` | macOS app target linking the package's `MKSoundEditorKit` library product |
| `App/Version.xcconfig` | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` — the only place the version is set |
| `App/MKPatchLibrarian/Info.plist` | category, encryption declaration, font path |
| `App/MKPatchLibrarian/MKPatchLibrarian.entitlements` | App Sandbox + user-selected read-only file access |
| `App/MKPatchLibrarian/PrivacyInfo.xcprivacy` | no tracking, no collected data, UserDefaults reason `CA92.1` |
| `App/MKPatchLibrarian/AppIcon.icon` | Icon Composer icon; regenerate the layer with `swift Scripts/GenerateIcon.swift <png> --foreground` |
| `docs/PRIVACY.md` | privacy policy text to host and link from App Store Connect |

The bundle identifier is `com.otonomee.mkpatchlibrarian`. Change `PRODUCT_BUNDLE_IDENTIFIER` in the target's build settings if you register a different one.

## Sandbox notes

- CoreMIDI needs no entitlement. The sandboxed build finds the synth behind a USB-MIDI interface and reads/writes SysEx normally.
- Imports through `NSOpenPanel` work under `files.user-selected.read-only`. Drag-and-drop should get the same access (macOS grants a sandbox extension to dropped files) but hasn't been tested in the sandboxed build yet.
- Session state lives in `~/Library/Containers/com.otonomee.mkpatchlibrarian/Data/Library/Application Support/MKSoundEditor/`, separate from the development build's `~/Library/Application Support/MKSoundEditor/`.

## Submitting

Requires an active Apple Developer Program membership.

1. In [App Store Connect](https://appstoreconnect.apple.com), create the app record with the bundle ID above (register it under Certificates, Identifiers & Profiles first if Xcode doesn't do it for you).
2. Open `App/MKPatchLibrarian.xcodeproj`. In the MKPatchLibrarian target's **Signing & Capabilities** tab, choose your team. Automatic signing creates the Apple Distribution and Mac Installer Distribution certificates and the provisioning profile.
3. Bump `App/Version.xcconfig` if needed (each upload needs a new `CURRENT_PROJECT_VERSION`).
4. **Product → Archive**, then in the Organizer **Distribute App → App Store Connect → Upload**.
5. In App Store Connect: privacy policy URL (host `docs/PRIVACY.md`), App Privacy answers ("Data Not Collected"), screenshots, description, pricing, and age rating, then submit for review.

Command-line equivalent for step 4, once a team is set:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project App/MKPatchLibrarian.xcodeproj -scheme MKPatchLibrarian \
  -configuration Release -archivePath build/MKPatchLibrarian.xcarchive archive
```
