# PortSQL Handoff

Last updated: 2026-06-06

## Current State

PortSQL is an iOS SQL client for MySQL and PostgreSQL. The active App Store version prepared in this workspace is:

- App: PortSQL
- Apple ID: 6762447018
- Bundle ID: `ad.neko.portsql`
- Version: `1.2.2`
- Build: `3`
- Developer team: `7P8CLHDH5G` / Kitta Ltd
- Last known App Store Connect state: submitted on 2026-05-31 and shown as `Waiting for Review`

Before making release decisions, re-check App Store Connect because review status can change after submission.

## Repository Rules

- Use `master` instead of `main`.
- Project generation is driven by `project.yml`.
- Do not revert existing local changes unless explicitly asked. The current working tree is intentionally dirty from the release work.

## Major Recent Changes

- Added SSH tunnel support using SwiftNIO SSH.
- Wired SSH tunnel endpoints into MySQL/PostgreSQL connection flow.
- Added support for password auth and unencrypted OpenSSH Ed25519/ECDSA private keys.
- Added known-host fingerprint storage and mismatch rejection.
- Added query parameter/export service fixes.
- Added stronger SQL safety checks for mutating statements, comments, strings, and missing `WHERE`.
- Improved SQL assist suggestions around table/column context.
- Added visualization/export/localization/keychain test coverage.
- Added 10 in-app localization bundles.
- Bumped version/build to `1.2.2` / `3`.
- Fixed transferred-app iCloud KVS entitlement:
  - `com.apple.developer.ubiquity-kvstore-identifier`
  - `9733K94JUG.ad.neko.portsql`

## Important Files

- `project.yml` - XcodeGen source of truth.
- `PortSQL/Services/SSHTunnelService.swift` - SSH tunnel implementation.
- `PortSQL/Services/DatabaseService.swift` - database connection routing, including tunnel endpoints.
- `PortSQL/Services/SQLSafetyService.swift` - SQL safety checks.
- `PortSQL/Services/SQLAssistService.swift` - autocomplete/suggestion behavior.
- `PortSQL/Services/QueryParameterService.swift` - parameter handling and CSV export.
- `PortSQL/Services/KeychainService.swift` - keychain storage plus DEBUG fallback for tests.
- `PortSQL/Services/Localization.swift` - localization helper.
- `PortSQL/*.lproj/Localizable.strings` - app localizations.
- `PortSQLTests/*` - focused tests for SSH, SQL safety, assist, export, visualization, localization, keychain, and catalog coverage.

## Local Build Notes

Regenerate the Xcode project after editing `project.yml`:

```sh
xcodegen generate
```

Run tests:

```sh
xcodebuild test \
  -scheme PortSQL \
  -destination 'platform=iOS Simulator,name=iPhone 16 Plus,OS=18.5' \
  CODE_SIGNING_ALLOWED=NO
```

The last full test run before submission passed:

- 32 tests
- 0 failures

Archive:

```sh
rm -rf build/PortSQL.xcarchive build/export
xcodebuild \
  -scheme PortSQL \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/PortSQL.xcarchive \
  -allowProvisioningUpdates \
  archive
```

Export/upload needs a system-only `PATH`; otherwise Xcode can fail during IPA packaging because `/usr/bin/rsync` starts the Homebrew `rsync` server side and the options are incompatible.

```sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild \
  -exportArchive \
  -archivePath build/PortSQL.xcarchive \
  -exportPath build/export-xcode \
  -exportOptionsPlist build/ExportOptions.plist \
  -allowProvisioningUpdates
```

Upload used the same system-only `PATH` with `build/UploadOptions.plist`.

## App Store Connect Notes

Release work completed on 2026-05-31:

- Created App Store version `1.2.2`.
- Uploaded build `3`.
- Waited for build processing.
- Attached build `3` to version `1.2.2`.
- Updated all 10 App Store metadata localizations:
  - English (U.S.)
  - Chinese (Simplified)
  - Chinese (Traditional)
  - French
  - German
  - Japanese
  - Korean
  - Portuguese (Brazil)
  - Russian
  - Spanish (Spain)
- Submitted the review item.
- App Store Connect displayed `Waiting for Review`.

The prior Apple warning `ITMS-90076: Potential Loss of Keychain Access` was expected after developer-team transfer. The app identifier moved from old team `9733K94JUG` to new team `7P8CLHDH5G`, so keychain access can be lost across the transfer. The iCloud KVS entitlement remains on the old prefix and was fixed accordingly.

## Known Caveats

- Private-key SSH support is currently limited to unencrypted OpenSSH Ed25519/ECDSA keys.
- Passphrase-protected private keys are not implemented.
- Some newly added in-app localization keys may still use English fallback text where a translation was missing.
- The worktree contains generated build artifacts under `build/`; decide whether to keep or delete them before committing.
- Review notes in App Store Connect contain a test database connection. Do not copy secrets into public docs or screenshots.
- Existing warnings to clean up later:
  - `RootView.swift` Sendable warnings around optional Binding helpers.
  - `DatabaseService.swift` warning for deprecated `PostgresData` `CustomStringConvertible`.
  - Swift package dependency warnings from Xcode/NIO.

## Suggested Next Steps

1. Re-check App Store Connect for the current review state.
2. Decide whether to commit the current dirty worktree as one release commit or split it by feature:
   - SSH tunnel
   - SQL safety/export/assist fixes
   - localization/App Store metadata
   - tests
3. Remove or ignore generated `build/` artifacts before committing unless they are intentionally needed.
4. Add passphrase-protected key support if SSH key auth is a priority.
5. Replace English fallback localization strings with native translations.
