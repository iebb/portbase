# App Store Connect builds

`.github/workflows/app-store-connect.yml` builds the triggering `master` commit
in **iebb/portbase**, or the current `master` commit on a manual run. iOS and
native macOS archive independently on hosted `macos-26` runners. The workflow
uses repository secrets directly, without deployment environments or reviewer
approval gates. A new push queues behind an active release rather than
cancelling an upload.

## Build and signing

- `PortSQLCI` and `PortbaseMacCI` archive with automatic signing in `Release-CI`.
- Existing local Debug/Release signing settings and entitlements are preserved,
  including the transferred app's `9733K94JUG.ad.neko.portsql` iCloud KVS identity.
- Build the committed project and `Package.resolved`; do not run XcodeGen or
  upgrade the vendored MySQL package in CI.
- Use the existing App Store Connect app `6762447018`, bundle `ad.neko.portsql`,
  and development team `7P8CLHDH5G`.
- Import existing signing identities into a temporary keychain and always clean
  up the keychain, P12, and API key. Never create or revoke certificates for CI.
- Export/upload using the system-only `PATH` to avoid Homebrew rsync failures.

Required repository secrets (already configured): `ASC_ISSUER_ID`, `ASC_KEY_ID`,
`ASC_PRIVATE_KEY_BASE64`, `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`, and
`APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`.

`select-release-version.rb` reads authenticated App Store Connect records for
the platform. It chooses at least the source version and highest TestFlight
train, and advances beyond any closed/released Store train. An in-review
version stays open for subsequent build uploads. Build numbers advance beyond
all uploaded builds, including historical Cloud/local builds and reruns.
`PORTBASE_MARKETING_VERSION` can override the train as a repository variable,
but cannot lower it. No version or signing setting is rewritten in source.

## Review handling

The workflow uploads **App Store-eligible** builds first, waits for exact
platform/version/build processing, then verifies internal TestFlight access.
It uses Mithka's `distribute_testflight_groups.rb` pattern with Portbase's
existing lowercase `internal` and `external` groups. Group names can be
changed with `TESTFLIGHT_INTERNAL_GROUP` and `TESTFLIGHT_EXTERNAL_GROUP` variables.

External Beta App Review is requested after upload. Another build in review,
Apple's submission limit, a pending review, or a rejected beta does not fail a
successful upload/internal distribution or prevent later builds. Rejected builds
are not automatically resubmitted. Processing failures, signing/authentication
errors, missing groups, and unavailable internal builds still fail visibly.
The Actions summary records upload identity and actual distribution states.

External review approval is not awaited. App Store version preparation and
public App Review submission remain separate release decisions, as in Mithka;
this workflow does not replace an in-review Store version or automatically
publish a version to customers.

## Local verification

```sh
ruby -Itests/ci -e 'Dir["tests/ci/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
actionlint .github/workflows/app-store-connect.yml
sh scripts/validate-release-inputs.sh
```

Run the full iOS simulator suite, localization semantic tests and vendored MySQL
tests after relevant changes. Keep `project.yml` aligned with the committed
project without changing local signing. Xcode Cloud hooks and schemes have been
removed; GitHub Actions is the build/upload service.
