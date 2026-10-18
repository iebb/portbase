# PortSQL archival decisions

This repository is archived. If work resumes, treat the decisions below as project invariants. Make changes only when explicitly requested, verify any live App Store or CI state again, and preserve unrelated dirty work.

## Repository and project structure

- Use `master`; do not create or refer to a `main` branch.
- PortSQL targets iOS 18 with Swift 6 on iPhone and iPad. Mac Catalyst is not supported.
- `project.yml` is the intended XcodeGen source of truth. Keep it and `PortSQL.xcodeproj` aligned when adding sources, resources, or dependencies.
- Do not run XcodeGen blindly: inspect the committed configuration-specific signing and entitlement settings first. Reconcile them into `project.yml` and verify the generated Release settings before replacing the project file. Preserve the transferred app's iCloud KVS entitlement unless an explicit release decision changes it.
- Inspect `git status` before every change and stage exact paths or hunks. Never discard or absorb unrelated metadata, version, signing, entitlement, Fastlane, or handoff work.
- Never commit generated archives or local build products, including `build/`, `.deriveddata*`, IPAs, xcarchives, dSYMs, code signatures, provisioning profiles, or package `.build` directories.
- The vendored `Packages/mysql-nio` code contains intentional transport and data-correctness fixes. Do not replace or upgrade it without porting its TLS fallback controls, result metadata handling, temporal decoding, typed-value behavior, and regression tests.

## Transport and secret handling

- Keep exactly four explicit transport modes: required TLS with system CAs, required TLS with a private CA, Prefer TLS, and plaintext only. System-CA TLS is the default mode, but a CA that isn't in the system trust store is not a dead end: when a server's chain fails verification as untrusted, Portbase fetches the CA the server presents (aborting that handshake before credentials are sent) and offers it for trust on first use, as managed databases (DigitalOcean, RDS, Azure) use their own CAs. Only after the user confirms the CA's name, SHA-256 fingerprint, and expiry is it stored in the Keychain and the profile switched to private-CA mode. Never trust a CA without that confirmation, never offer it when the certificate doesn't name the host or is outside its validity, and keep full chain and hostname verification afterward so a different CA fails again.
- Prefer TLS may fall back only when the server reports that TLS is unsupported. Certificate validation, TLS negotiation, authentication, and post-handshake errors must never trigger a downgrade.
- Plaintext must remain a separate, explicit choice with a persistent warning in the editor and server list. Never infer or silently enable it.
- Private-CA TLS must retain full hostname verification and verify the chain against the validated private CA as the trust roots (BoringSSL verification, like libpq `sslrootcert` or MySQL `--ssl-ca`). Do not add it to the system roots instead: that routes verification through Apple's verifier, which rejects private-CA server certificates lacking the serverAuth extended key usage, such as DigitalOcean managed-database certificates. Reject missing or malformed certificates, embedded private keys, and input larger than 1 MiB. Continue supporting PEM/CRT/CER and binary DER import.
- Database passwords, SSH passwords, SSH private keys, SSH passphrases, and private CA material belong in Keychain, never in files. Each device always keeps its own copy. While Sync Passwords and Keys is on (a per-device setting, on by default), each secret is also a versioned iCloud Keychain item (value or cleared, change date, device), which syncs end-to-end encrypted. `SyncedSlot` reconciles the two copies three-way against the iCloud version the device last agreed with: a change on one side is taken over, and when both changed, the later change wins and the other value is kept as a conflict for the user to review in the connection editor. Never show conflicting secret values. Secrets that come from storage or memory rather than the editor may only fill an empty Keychain slot. Turning sync off asks whether to remove the iCloud copies. Bookmark JSON/iCloud payloads must contain only redacted placeholders, never secret material. Connections, saved queries, and charts sync as unencrypted iCloud data, and AI settings as the encrypted iCloud Drive file. Both merge field by field (`JSONFieldMerge`), with lists of identified entries merged entry by entry and removals kept as dated tombstones, so edits two devices make to different fields both survive; keep new synced fields compatible with that.
- Direct TLS connections to an IP address rely on IP-SAN validation. TLS over SSH must validate the original database DNS hostname; TLS-over-SSH profiles whose database host is an IP address fail closed until an explicit certificate identity override is designed.
- SSH uses a loopback forward and trust-on-first-use SHA-256 host-key pinning. A changed host key must fail closed. Trusted host keys sync through iCloud Keychain only when the user turns on Sync Trusted SSH Host Keys (off by default). Host keys are never merged by date: when two devices trust different keys for a server, each keeps its own, which still refuses any other key, until the user picks one or forgets the key. Preserve bounded connection/authentication timeouts, in-flight tunnel deduplication, cancellation, and partial-channel cleanup.
- SSH private-key support is limited to the formats implemented and tested by `SSHTunnelPrivateKeyParser`; do not claim encrypted private-key compatibility without adding it and testing it.

## Database safety and data semantics

- Route database execution through `DatabaseService` and an explicit `DatabaseExecutionPolicy`. Charts, browsing, Explain, editors, and future automation must not bypass this boundary.
- Read-only protection is defense in depth: use engine-aware SQL classification, a read-only execution policy, and a server-side read-only session. Read-only profiles and read-only call sites must block mutations even if the UI is bypassed.
- Keep `SQLSafetyService` engine-aware. Preserve top-level statement/`WHERE` analysis, PostgreSQL literal and JSON-operator handling, MySQL comment-mode handling, executable comments, `SELECT INTO`, and confirmation for writes or schema changes.
- Bind user values as native prepared parameters. Never interpolate parameter values into SQL. Named-parameter scanning must ignore literals/comments, preserve explicit `NULL` versus empty strings, and reject ambiguous mixing with native placeholders.
- Mutations that expect a row count must execute transactionally and roll back before commit when the actual count is missing or different. A row editor save expects exactly one affected row.
- Row editing is allowed only with explicit Explorer-generated single-table provenance and a usable primary or unique identifier. Do not infer writable provenance from arbitrary Studio SQL or joins.
- Preserve `QueryCell` type information through display, accessibility, editing, CSV, and JSON. SQL `NULL`, empty text, binary bytes, numeric values, and temporal values are distinct. Unsupported binary fields remain read-only and are omitted from inserts.
- Keep temporal values round-trippable without changing date/time shape, timezone meaning, sign, duration days, or PostgreSQL microseconds.
- Schema mutations must quote identifiers, validate types, show the exact DDL, and use transactions where supported. MySQL column edits remain disabled when complete metadata cannot be preserved.
- Keep the default query timeout at 30 seconds, clamp requested timeouts to 1–300 seconds, close connections on timeout/cancellation, and cap materialized results at 10,000 rows with explicit truncation state.

## Product and interface decisions

- Saved chart cards do not auto-run when a view appears. They use explicit loading, content, missing-query, missing-connection, idle, and error states, with manual Run and Edit actions.
- Database browse/chart/Explain call sites use read-only execution even when their bookmark is otherwise writable.
- Preserve Dynamic Type layouts, 44-point interactive targets, meaningful VoiceOver labels, typed NULL/empty-cell announcements, and adaptive iPad result widths.
- iPhone and iPad both use the bottom Liquid Glass tab bar: the root `TabView` gets a compact horizontal size class (which keeps the iPadOS bar off the top, where it covered page toolbars) and each page gets the real size class back. On regular widths, workspaces give results the rest of the screen (`workspaceFillsHeight`), and connection badges sit in the navigation bar's connection button.
- Free supports three saved bookmarks. Pro unlocks unlimited bookmarks and premium line/area chart styles. Enforce this at action/model boundaries, not only by hiding UI.
- Recompute StoreKit access from verified current entitlements after transaction updates; revoked, refunded, expired, or upgraded transactions must not leave stale access enabled.

## Localization and verification

- Maintain exact catalog parity for `en`, `de`, `es`, `fr`, `ja`, `ko`, `pt-BR`, `ru`, `zh-Hans`, and `zh-Hant`, including placeholders and `.stringsdict` plural forms.
- SwiftUI literals may localize automatically, but model, service, view-model, computed, plural, error, accessibility, and result-summary strings must use the localization helpers explicitly.
- After relevant changes, regenerate the project only after resolving the Release entitlement rule above, then run the full iOS simulator test suite and the vendored MySQL package tests.
- Validate every strings and stringsdict catalog with `plutil`, run the localization semantic tests, run `git diff --check`, and perform a redacted secret scan before publishing.

## Release automation

- GitHub Actions follows changes to `master`, builds the triggering commit, and uses the shared `PortSQLCI` and `PortbaseMacCI` schemes. Xcode Cloud is retired; do not reconnect it. Use repository secrets without environment reviewer gates. Upload App Store-eligible builds before TestFlight distribution; external Beta App Review must not block successful uploads or internal testing.
- GitHub Actions imports the existing signing bundle into a temporary keychain and uses automatic provisioning for `Release-CI`. Preserve existing local Debug/Release signing settings and entitlements. Do not manually create, revoke, or replace certificates as part of routine CI repair, or copy signing keys into the repository.
- Choose an App Store-compatible marketing version at runtime rather than uploading into a closed or lower version train.
- Keep the system export tool path (`/usr/bin:/bin:/usr/sbin:/sbin`) for archive export to avoid Homebrew `rsync` incompatibilities.
