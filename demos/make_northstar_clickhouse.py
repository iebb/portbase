#!/usr/bin/env python3
"""Loads the Northstar demo into ClickHouse for analytics: orders and line items from the SQLite database
make_northstar.py builds, a daily revenue rollup kept by a materialized view, and five million generated
page views to show what columnar queries feel like. It talks to the HTTP interface and needs no client library:

    python3 demos/make_northstar_clickhouse.py [http://127.0.0.1:8123]

The `northstar` database is dropped and rebuilt.
"""
import os
import sqlite3
import sys
import urllib.parse
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8123"


def run(sql, data=None):
    query = urllib.parse.urlencode({"query": sql}) if data is not None else ""
    request = urllib.request.Request(URL + "/?" + query, data=data if data is not None else sql.encode())
    try:
        with urllib.request.urlopen(request) as response:
            return response.read().decode()
    except urllib.error.HTTPError as error:
        raise SystemExit(error.read().decode())


def tsv(value):
    if value is None:
        return "\\N"
    return str(value).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


SCHEMA = [
    "DROP DATABASE IF EXISTS northstar",
    "CREATE DATABASE northstar",
    """CREATE TABLE northstar.orders (
        order_id UInt32,
        order_number String,
        customer_id UInt32,
        country LowCardinality(String),
        placed_at DateTime,
        status LowCardinality(String),
        channel LowCardinality(String),
        shipping_method LowCardinality(String),
        warehouse LowCardinality(String),
        subtotal Decimal(10, 2),
        discount Decimal(10, 2),
        shipping Decimal(10, 2),
        tax Decimal(10, 2),
        total Decimal(10, 2),
        coupon_code Nullable(String)
    ) ENGINE = MergeTree PARTITION BY toYYYYMM(placed_at) ORDER BY (placed_at, order_id)""",
    """CREATE TABLE northstar.order_items (
        order_id UInt32,
        line_no UInt8,
        placed_at DateTime,
        sku LowCardinality(String),
        product LowCardinality(String),
        category LowCardinality(String),
        quantity UInt16,
        unit_price Decimal(10, 2)
    ) ENGINE = MergeTree ORDER BY (placed_at, order_id, line_no)""",
    """CREATE TABLE northstar.daily_revenue (
        day Date,
        channel LowCardinality(String),
        orders UInt64,
        revenue Decimal(18, 2)
    ) ENGINE = SummingMergeTree ORDER BY (day, channel)""",
    """CREATE MATERIALIZED VIEW northstar.daily_revenue_mv TO northstar.daily_revenue AS
        SELECT toDate(placed_at) AS day, channel, count() AS orders, sum(total) AS revenue
        FROM northstar.orders
        WHERE status NOT IN ('cancelled', 'refunded')
        GROUP BY day, channel""",
    """CREATE TABLE northstar.page_views (
        ts DateTime,
        session_id UUID,
        country LowCardinality(String),
        device LowCardinality(String),
        path String,
        referrer LowCardinality(String),
        duration_ms UInt32,
        converted Bool,
        tags Array(LowCardinality(String)),
        properties Map(String, String)
    ) ENGINE = MergeTree PARTITION BY toYYYYMM(ts) ORDER BY (ts, session_id)""",
]

# Five million deterministic page views over the last two years, generated inside ClickHouse: traffic grows
# over time and shifts toward iPhone.
PAGE_VIEWS = """INSERT INTO northstar.page_views
SELECT
    toDateTime('2024-11-01 00:00:00') + toUInt32(63072000 * pow((cityHash64(number, 10) % 1000000) / 1000000, 0.6)) AS ts,
    reinterpretAsUUID(toFixedString(concat(reinterpretAsString(cityHash64(intDiv(number, 7))), reinterpretAsString(cityHash64(intDiv(number, 7), 0))), 16)) AS session_id,
    ['United States', 'Canada', 'Germany', 'United Kingdom', 'Japan', 'France', 'Norway', 'Australia', 'South Korea', 'Switzerland'][1 + cityHash64(intDiv(number, 7), 1) % 10] AS country,
    multiIf(cityHash64(intDiv(number, 7), 2) % 100 < 25 + 20 * dateDiff('second', toDateTime('2024-11-01 00:00:00'), ts) / 63072000, 'iPhone',
            cityHash64(intDiv(number, 7), 2) % 100 < 50, 'Mac', cityHash64(intDiv(number, 7), 2) % 100 < 72, 'Android',
            cityHash64(intDiv(number, 7), 2) % 100 < 88, 'iPad', 'Windows') AS device,
    ['/', '/packs', '/shelter', '/sleep', '/apparel/jackets', '/footwear', '/camp-kitchen', '/lighting', '/cart', '/checkout'][1 + cityHash64(number, 3) % 10] AS path,
    ['direct', 'search', 'newsletter', 'instagram', 'partner'][1 + cityHash64(intDiv(number, 7), 4) % 5] AS referrer,
    200 + cityHash64(number, 5) % 90000 AS duration_ms,
    cityHash64(number, 6) % 37 = 0 AS converted,
    arraySlice(['returning', 'mobile', 'promo', 'loyalty', 'gift'], 1, cityHash64(number, 7) % 3) AS tags,
    map('ab_test', ['control', 'new-checkout'][1 + cityHash64(intDiv(number, 7), 8) % 2], 'app_version', '2.' || toString(cityHash64(number, 9) % 3)) AS properties
FROM numbers(5000000)"""


def main():
    for statement in SCHEMA:
        run(statement)

    source = sqlite3.connect(os.path.join(HERE, "Northstar.sqlite"))
    orders = source.execute(
        "SELECT o.order_id, o.order_number, o.customer_id, c.country, o.placed_at, o.status, o.channel, o.shipping_method, "
        "w.code, o.subtotal, o.discount, o.shipping, o.tax, o.total, o.coupon_code "
        "FROM orders o JOIN customers c USING (customer_id) LEFT JOIN warehouses w USING (warehouse_id) ORDER BY o.order_id")
    run("INSERT INTO northstar.orders FORMAT TabSeparated", "\n".join("\t".join(tsv(v) for v in row) for row in orders).encode())
    items = source.execute(
        "SELECT i.order_id, i.line_no, o.placed_at, p.sku, p.name, c.name, i.quantity, i.unit_price "
        "FROM order_items i JOIN orders o USING (order_id) JOIN products p USING (product_id) JOIN categories c ON c.category_id = p.category_id")
    run("INSERT INTO northstar.order_items FORMAT TabSeparated", "\n".join("\t".join(tsv(v) for v in row) for row in items).encode())
    run(PAGE_VIEWS)
    run("OPTIMIZE TABLE northstar.daily_revenue FINAL")

    print(run("SELECT name, total_rows, formatReadableSize(total_bytes) FROM system.tables WHERE database = 'northstar' "
              "AND engine NOT LIKE '%View' ORDER BY name FORMAT PrettyCompactNoEscapes"))


if __name__ == "__main__":
    main()
