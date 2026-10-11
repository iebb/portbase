# Xcode Cloud

Xcode Cloud replaces `.github/workflows/nightly-testflight.yml`. The release
workflow watches changes to `master` and archives both apps for internal and
external TestFlight distribution. There are no test actions or manual-start
conditions. A branch-change trigger avoids nightly uploads of unchanged commits.

## Schemes and signing

- `PortSQLCloud`: iOS archive in Release-Cloud.
- `PortbaseMacCloud`: native macOS archive in Release-Cloud.
- Both Cloud archives use automatic signing and team `7P8CLHDH5G`.
- Existing `PortSQL` and `PortbaseMac` schemes keep their local release settings.
  The Mac Release configuration retains the `Portbase Mac App Store` profile.
- Cloud and local builds share the existing entitlements, including the
  transferred app's `9733K94JUG.ad.neko.portsql` iCloud KVS identity.

The committed project and `Package.resolved` are used directly. Cloud builds do
not run XcodeGen, upgrade packages, or replace the vendored MySQL transport fixes.
Keep `project.yml` and the generated project aligned when editing configurations.

## Build hooks

`ci_scripts/ci_post_clone.sh` checks the project, dependency lockfile, vendored
package, entitlements, and localization catalogs. `ci_pre_xcodebuild.sh` selects
an open marketing version immediately before each archive. It changes only the
selected app's Release-Cloud configuration in the temporary clone. The version
is at least the source version and newer than the published platform version;
the initial Mac release uses its source version while no Mac version is live.

For an intentional version train, set the non-secret Cloud environment variable
`PORTBASE_MARKETING_VERSION` to a numeric `X.Y.Z`. Values below the open train are
rejected. Xcode Cloud owns build numbering, provisioning, signing, export, and
upload. No GitHub Actions signing bundle or App Store Connect key is needed.

## Service configuration

Use the existing Portbase app record (`6762447018`) and repository
`kitta-co/portsql`, with `PortSQL.xcodeproj` as the container:

1. Enable a branch-change start condition for exactly `master`.
2. Select release Xcode 27 and a compatible macOS environment.
3. Enable Clean and restrict workflow editing so archives are App Store eligible.
4. Archive `PortSQLCloud` for any iOS device and `PortbaseMacCloud` for any Mac,
   with the TestFlight and App Store distribution audience.
5. Add internal and external TestFlight post-actions for each archive, using the
   existing `internal` and `external` groups. External beta review and public
   App Store review remain separate submission steps.

Public Swift package repositories can be fetched without installing the Xcode
Cloud GitHub app in their owners' organizations. Do not request access to Apple,
Vapor, MongoDB, or other public package owners to resolve public dependencies.

Apple documentation: [custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts),
[dependencies](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud),
[distribution workflows](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution).
