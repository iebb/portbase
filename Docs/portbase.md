# Portbase

Portbase is the new display name of PortSQL. The bundle ID, Keychain entries, iCloud identifiers, subscription product IDs, and local storage directories retain their existing identifiers, so an update keeps saved connections, queries, charts, and purchases. The Xcode target and scheme remain `PortSQL`.

The 1.4.0 update adds five engines to MySQL, PostgreSQL, and MongoDB:

| Engine | Connection and queries | Data tools |
| --- | --- | --- |
| MariaDB | Native MySQL protocol, engine-aware SQL safety, retained consoles, manual commit and rollback | Table and schema browsing, identified row edits, transactional import, streaming export, charts |
| SQLite | Native SQLite3; create files or import a consistent snapshot into protected local storage | Tables, views, indexes, triggers, foreign keys, identified row edits, transactional import, streaming export, charts |
| Redis | RESP2, ACL username/password, database selection, one command per run | SCAN key browser; string, hash, list, set, sorted-set and stream inspection; binary-safe commands and values; expiration and reviewed writes; tables and charts |
| ClickHouse | Native HTTP/HTTPS SQL, Basic authentication | Database/table/column browsing, typed tables, charts, reviewed SQL writes |
| Elasticsearch | Native HTTP/HTTPS JSON requests; Basic, API key or bearer authentication | Index mappings, search documents, typed tables, aggregations and charts, reviewed document writes |

Network profiles keep required TLS with system CAs as the default, private CAs with hostname verification, Prefer TLS, and explicit plaintext. Redis and HTTP protocols cannot safely negotiate an unsupported-TLS fallback; their Prefer TLS mode still requires TLS. SSH connections use the existing loopback tunnel and original database certificate hostname. Redirects cannot forward HTTP credentials elsewhere.

SQLite snapshots preserve committed WAL data and do not depend on the original file afterwards. Local files are independent of bookmarks and can be selected or deleted in Manage Local Files. They are not uploaded to iCloud. Generated and hidden columns cannot be edited or imported. Each command uses its own connection; manual console transactions and automatic column type changes are unavailable for SQLite.

Redis has no SQL-style rollback, so its writes use an exact command preview and confirmation. Unknown, administrative, scripting, subscription and blocking commands are refused. The key browser uses SCAN rather than KEYS. Redis Cluster/Sentinel discovery and transparent redirection are not implemented; use a standalone endpoint. Writes are never replayed after a connection failure.

ClickHouse and Elasticsearch do not expose SQL transaction controls or identified-row editors. Complete-result import/export is available for MySQL, MariaDB, PostgreSQL, SQLite and MongoDB; the other engines can export the currently loaded result as CSV or JSON. ClickHouse positional bindings are not supported. Elasticsearch supports reviewed document requests, rather than unrestricted cluster administration.

Materialized result tables are capped at 10,000 rows with explicit truncation. Redis and HTTP responses also have a bounded byte limit and fail clearly when it is exceeded. Charts run manually with read-only policy and use the same typed result tables as the data viewer.

This is native support for eight engines, not JDBC driver parity with DataGrip. Oracle, SQL Server, Cassandra, DynamoDB and other DataGrip engines require additional native drivers and are not advertised as supported.

## Verification

The combined iOS Simulator suite passed 129 maintained tests and one temporary screenshot review. Live fixtures covered all eight engines, including private-CA hostname verification and failed-trust cases for Redis, MongoDB and HTTP. All 46 vendored MySQL tests passed. Twenty focused checks passed after the final editor, authentication and chart refinements, followed by the three HTTP integration checks after removing an unnecessary Elasticsearch privilege check.

Six simulator renders were reviewed for Redis values and commands, Elasticsearch documents, tables and charts, and SQLite files, including phone and wide layouts. The temporary screenshot harness was removed. Validation used the iPhone Duo simulator and hosted layouts; no physical-device check was performed.

All 30 localization catalogs passed validation, localization semantic tests passed, and the redacted source scan found no credentials beyond a synthetic URI parser fixture. The signed archive uses the release iOS 27.0 SDK, supports iOS 18 and later, and preserves the transferred app's iCloud KVS entitlement. Duo simulator checks used the 27.1 beta runtime; the shipping binary uses adaptive phone and wide layouts without depending on beta-only device APIs.

Portbase 1.4.0 (1) was submitted on September 22, 2026 and independently verified as Waiting for Review. The Portbase name and descriptions match in all ten store locales. This submission replaces the queued 1.3.0 review and retains automatic release after approval. Exact build and review identifiers are recorded in [the release record](../AppStore/1.4.0/release.json).

The same build was resubmitted after replacing the store screenshots with 10 iPhone and 10 iPad captures. All 20 images reached COMPLETE with matching source checksums, dimensions and order. Other locales inherit the English screenshots. See the [gallery](../ReviewScreenshots/README.md) and [upload manifest](../AppStore/1.4.0/screenshots.json).

## Build 2 purchase removal

App Review later rejected build 1. App Store Connect had no in-app purchases or subscription groups, so the purchase screen could show no products. Build 2 removes the purchase screen, all purchase entry points, and StoreKit startup work. Saved connections and all chart styles are available without a purchase. Settings retains Library Storage.

The 1.4.0 descriptions and release notes now state that connection saves and chart styles are unrestricted. All ten storefront keyword lists include PortSQL and SQL alongside supported database engines; each stays within Apple's 100-byte limit. Existing iPhone and iPad screenshots do not show the removed purchase screen and remain in place.

The build 2 iOS Simulator suite passed 127 tests with 11 integration tests skipped because their external services were not running. The vendored MySQL package passed all 46 tests against a local MySQL fixture. Both phone and iPad Settings views were inspected in simulators, 30 localization catalogs passed `plutil`, and redacted source scans found no leaks. The signed Release archive retains the iCloud KVS entitlement. Exact source hashes are in [the build 2 source manifest](../AppStore/1.4.0/build-2-source.json). Build 2 was resubmitted on September 23 and verified as Waiting for Review; its IDs and validation are in [the resubmission record](../AppStore/1.4.0/resubmission.json).

## 1.5.0 workspace tools

The ten additions are server search and filters, profile duplication, editor line numbers and navigation, SQL comment toggling, script file opening and sharing, execution outcomes and durations in history, editable saved-query context, complete cell inspection and export, loaded-row filtering, and a dedicated MongoDB index inspector. Their entry points and limits are documented in [workspace tools](workspace-tools.md).

The full simulator suite passed 125 tests with 11 external-service tests skipped. The final 16 focused checks and all 46 vendored MySQL tests passed. Native UI checks passed on iPhone, iPad, and iPhone Duo simulators, including a live MongoDB index fixture. All 30 localization catalogs passed validation. Nine focused tests were added for the new behavior; the screenshot harness remains outside the repository. No physical-device check was performed.

Portbase 1.5.0 (2) was submitted on October 3, 2026 JST and independently verified as Waiting for Review, with automatic release after approval. The previously approved 1.4.0 release remains available. The ten localized listings retain PortSQL and SQL keywords, and twenty store screenshots were verified against their source checksums, dimensions, ordering, and delivered pixels. See the [release record](../AppStore/1.5.0/release.json), [source manifest](../AppStore/1.5.0/source.json), and [screenshot gallery](../ReviewScreenshots/README.md).
