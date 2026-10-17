# Portbase 2.0 App Review notes

Portbase is a user-controlled database client for iPhone, iPad, and native macOS.
No Portbase account or sign-in is required. Review does not require access to a
real database server or any private credentials.

## Offline review

1. On Home, choose **New SQLite Database** and name it `Review Demo`.
2. In Console, run the following read-only query:

```sql
SELECT 'Japan' AS region, 1240.50 AS revenue
UNION ALL SELECT 'Germany', 980.25
UNION ALL SELECT 'Canada', 760.00;
```

3. Inspect the typed results, copy or export them, and use the chart button in
   Results to configure and save a chart with `region` on X and `revenue` on Y.
4. To review table browsing, primary keys, row editing, indexes, and saved charts
   with a larger fictional dataset, import this optional local SQLite file:
   https://raw.githubusercontent.com/iebb/portbase/master/AppStore/2.0.0/Northstar_Demo.sqlite

The `Northstar Demo` store and all customers, products, orders, and totals shown
in the screenshots are fictional. The sample is a local SQLite file; it has no
server endpoint, account, password, or external service dependency. It is a
review fixture, not a database automatically included on first launch.

## Other engines and safety

Users may add their own MySQL, MariaDB, PostgreSQL, MongoDB, Redis, ClickHouse,
or Elasticsearch server. Engine capabilities differ, as described in the listing.
Database operations require an explicit user action. Writes use the app's normal
confirmation and execution policies; saved charts do not run automatically.

Connection passwords, SSH secrets, and private CA material stay in this device's
Keychain. iCloud syncs connection settings with secrets redacted, saved queries,
and chart configurations. Query history, results, and local SQLite files remain
on this device.

The Mac build is a native universal app for Apple Silicon and Intel.
