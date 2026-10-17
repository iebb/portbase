# Portbase

![Portbase — Your Portable DB Client](Docs/images/portbase-github-banner.png)

Portbase is a native database client for iPhone, iPad, and Mac. Browse databases,
run queries, inspect and edit results, and save charts from the same workspace.
The project was previously called PortSQL; its Xcode project and iOS target
retain that name.

[Download on the App Store](https://apps.apple.com/app/id6762447018) ·
[Build workflow](https://github.com/iebb/portbase/actions/workflows/app-store-connect.yml) ·
[Screenshot gallery](ReviewScreenshots/README.md)

## Supported databases

| Database | Tools |
| --- | --- |
| MySQL and MariaDB | SQL consoles, schema browsing, identified row editing, transactions, import and export |
| PostgreSQL | SQL consoles, schema browsing, identified row editing, transactions, import and export |
| SQLite | Local database files, schema browsing, identified row editing, import and export |
| MongoDB | JSON commands, document browsing and editing, aggregation pipelines, index inspection, import and export |
| Redis | SCAN key browsing, typed value inspection, reviewed commands and expiration changes |
| ClickHouse | HTTP/HTTPS SQL queries, database and table browsing, results and charts |
| Elasticsearch | JSON requests, index mappings, search results, aggregations and reviewed document writes |

Engine capabilities differ. Console transactions are available for MySQL,
MariaDB, and PostgreSQL. Redis uses a standalone endpoint; Cluster and Sentinel
discovery are not implemented. ClickHouse and Elasticsearch do not offer the
relational row editor. See [database support and limits](Docs/portbase.md).

## Workspace

- Keep multiple query consoles with restored drafts, saved queries, and searchable
  execution history.
- Use SQL completion, formatting, parameters, Explain, line navigation, and
  keyboard shortcuts.
- Browse tables with filtering and sorting; resize, pin, and hide result columns.
- Inspect full cell values, distinguish NULL from empty text, and stage identified
  row changes for submission together.
- Run saved charts manually and export loaded results as CSV or JSON. Full-query
  export and import are available for the engines listed above.
- Label connections by environment and use read-only profiles when browsing
  production data.

![Portbase native Mac workspace](ReviewScreenshots/2.0.0/macOS/02-sql-console.png)

The interface supports English, German, Spanish, French, Japanese, Korean,
Brazilian Portuguese, Russian, Simplified Chinese, and Traditional Chinese.

## Connections and data safety

Required TLS with system certificate authorities is the default. Profiles also
support private CAs with hostname verification, Prefer TLS, and an explicit
plaintext mode with a persistent warning. An untrusted CA is saved only after
confirmation. Prefer TLS only downgrades when a supported protocol explicitly
reports that TLS is unavailable.

SSH tunnels pin the server's SHA-256 host key on first use and refuse changed
keys. Passwords, SSH keys and passphrases, and private CA material stay in the
device Keychain. Saved connection JSON and iCloud payloads redact those secrets.
Local SQLite files stay on the device.

Read-only execution policies protect browsing, charts, and Explain. Writes use
engine-aware checks and confirmation; relational row edits require an identified
source row. Queries default to a 30-second timeout, and materialized results are
limited to 10,000 rows with explicit truncation.

## Build from source

Use macOS with Xcode 27 or newer and Swift 6 support. The iOS app targets iOS 18
and later; the native Mac app targets macOS 15 and later. Mac Catalyst is not used.

```sh
git clone https://github.com/iebb/portbase.git
cd portbase
open PortSQL.xcodeproj
```

Select `PortSQL` for iPhone/iPad or `PortbaseMac` for Mac. Simulator builds do not
need distribution credentials. For a device build, configure your own signing
team and capabilities in a local checkout. The committed App Store signing and
transferred iCloud identifiers belong to the published app.

Dependencies are resolved with Swift Package Manager. Keep the committed project
lockfile and the vendored `Packages/mysql-nio` package: it contains transport and
typed-value fixes that must survive dependency updates.

`project.yml` is the XcodeGen source of truth. If you regenerate the project,
first compare signing and entitlements with the committed project and follow
[AGENTS.md](AGENTS.md). Ordinary builds can use the committed project directly.

## Tests

Choose an installed iPhone simulator for the iOS suite:

```sh
xcodebuild test \
  -project PortSQL.xcodeproj \
  -scheme PortSQL \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO

ruby -Itests/ci -e 'Dir["tests/ci/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
sh scripts/validate-release-inputs.sh
```

External database integration tests need their corresponding fixtures. Without
those services, the simulator suite skips those checks. The vendored MySQL suite
expects a disposable database; its default fixture is `test_database` with user
`test_username` and password `test_password`:

```sh
cd Packages/mysql-nio
MYSQL_HOSTNAME=127.0.0.1 MYSQL_PORT=3306 swift test
```

Override `MYSQL_DATABASE`, `MYSQL_USERNAME`, and `MYSQL_PASSWORD` for a different
test fixture. Use a disposable database because these tests create and change data.

## Builds and App Store Connect

GitHub Actions builds the exact commit pushed to `master`, or a manually
requested `master` run, for both iOS and native macOS. It uses the `PortSQLCI` and
`PortbaseMacCI` schemes with `Release-CI`, existing signing credentials from
repository secrets, and automatic provisioning. Xcode Cloud is retired.

The workflow selects an open marketing version and unused build number from
App Store Connect, archives and uploads an App Store-eligible build, then verifies
internal TestFlight distribution. External Beta App Review is requested afterward.
Pending review, another build in review, and review submission limits do not block
later uploads or internal testing. Public App Store release submission remains a
separate step.

See [release setup and required secrets](Docs/app-store-connect.md). Build
products, credentials, local previews, and temporary files are excluded from Git.

## Source layout

| Path | Contents |
| --- | --- |
| `PortSQL/` | Shared models, database services, SwiftUI views, and localization catalogs |
| `PortbaseMac/` | Native Mac workspace, editor, grid, and app entry point |
| `PortSQLTests/` | App and service tests |
| `Packages/mysql-nio/` | Vendored MySQL driver and regression tests |
| `scripts/`, `tests/ci/` | Release helpers and automation regression tests |
| `Docs/` | Product notes, workspace details, and release documentation |
| `AppStore/`, `fastlane/`, `ReviewScreenshots/` | Store metadata, historical release records, and maintained screenshots |

Historical release documents record the state at the time of each submission;
check App Store Connect for the current review and distribution state.
