#!/usr/bin/env python3
"""Loads the Northstar demo into Redis as the kinds of keys a shop's backend keeps.

Product hashes, carts as lists, tag sets, revenue leaderboards as sorted sets, sessions and rate limits that
expire, counters, and a stream of recent orders, all under the `northstar:` prefix. It reads the SQLite
database make_northstar.py builds and needs no Redis client library:

    python3 demos/make_northstar_redis.py [host] [port] [db]

Keys under `northstar:` in the target database are deleted first.
"""
import json
import os
import random
import socket
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 6379
DB = int(sys.argv[3]) if len(sys.argv) > 3 else 0
rng = random.Random(2026)


class Redis:
    """Just enough RESP to send commands and read replies."""

    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port))
        self.file = self.sock.makefile("rb")

    def __call__(self, *args):
        parts = [str(a).encode() if not isinstance(a, bytes) else a for a in args]
        self.sock.sendall(b"*%d\r\n" % len(parts) + b"".join(b"$%d\r\n%s\r\n" % (len(p), p) for p in parts))
        return self.reply()

    def reply(self):
        line = self.file.readline().rstrip(b"\r\n")
        kind, rest = line[:1], line[1:]
        if kind == b"+":
            return rest.decode()
        if kind == b"-":
            raise RuntimeError(rest.decode())
        if kind == b":":
            return int(rest)
        if kind == b"$":
            size = int(rest)
            return None if size < 0 else self.file.read(size + 2)[:-2].decode()
        if kind == b"*":
            return [self.reply() for _ in range(int(rest))]
        raise RuntimeError("Unexpected reply %r" % line)


def main():
    source = sqlite3.connect(os.path.join(HERE, "Northstar.sqlite"))
    source.row_factory = sqlite3.Row
    r = Redis(HOST, PORT)
    r("SELECT", DB)
    cursor = "0"
    while True:
        cursor, keys = r("SCAN", cursor, "MATCH", "northstar:*", "COUNT", 1000)
        if keys:
            r("DEL", *keys)
        if cursor == "0":
            break

    stock = {row[0]: row[1] for row in source.execute("SELECT product_id, sum(on_hand) FROM inventory GROUP BY product_id")}
    rating = {row[0]: row[1] for row in source.execute("SELECT product_id, round(avg(rating), 2) FROM reviews GROUP BY product_id")}
    products = list(source.execute(
        "SELECT p.*, c.name AS category FROM products p JOIN categories c USING (category_id)"))
    for p in products:
        key = "northstar:product:" + p["sku"]
        r("HSET", key, "name", p["name"], "category", p["category"], "price", "%.2f" % p["price"],
          "stock", stock.get(p["product_id"], 0), "rating", rating.get(p["product_id"], ""),
          "discontinued", int(p["discontinued"]))
        attributes = json.loads(p["attributes"]) if p["attributes"] else {}
        tags = {p["category"].lower().replace(" ", "-")} | {k.replace("_", "-") for k in attributes}
        r("SADD", "northstar:product:%s:tags" % p["sku"], *sorted(tags))
        r("SADD", "northstar:category:" + p["category"].lower().replace(" ", "-"), p["sku"])

    customers = [row[0] for row in source.execute("SELECT customer_id FROM customers ORDER BY random() LIMIT 40")]
    skus = [p["sku"] for p in products if not p["discontinued"]]
    for customer in customers:
        r("RPUSH", "northstar:cart:%d" % customer, *rng.sample(skus, rng.randint(1, 4)))
        r("EXPIRE", "northstar:cart:%d" % customer, rng.randint(3600, 7 * 86400))
    for _ in range(25):
        token = "%032x" % rng.getrandbits(128)
        session = {"customer_id": rng.choice(customers), "device": rng.choice(["iPhone", "iPad", "Mac", "Android", "Web"]),
                   "locale": rng.choice(["en-US", "de-DE", "ja-JP", "fr-FR", "en-GB"]), "cart_items": rng.randint(0, 5)}
        r("SET", "northstar:session:" + token, json.dumps(session), "EX", rng.randint(600, 86400))
    for _ in range(12):
        r("SET", "northstar:ratelimit:api:203.0.113.%d" % rng.randint(1, 254), rng.randint(1, 120), "EX", rng.randint(5, 60))

    for month, in source.execute("SELECT DISTINCT strftime('%Y-%m', placed_at) FROM orders ORDER BY 1 DESC LIMIT 6"):
        rows = source.execute(
            "SELECT c.first_name || ' ' || c.last_name, round(sum(o.total), 2) FROM orders o JOIN customers c USING (customer_id) "
            "WHERE strftime('%Y-%m', o.placed_at) = ? AND o.status NOT IN ('cancelled', 'refunded') "
            "GROUP BY o.customer_id ORDER BY 2 DESC LIMIT 50", (month,))
        args = []
        for name, total in rows:
            args += [total, name]
        r("ZADD", "northstar:leaderboard:revenue:" + month, *args)
    args = []
    for sku, units in source.execute(
            "SELECT p.sku, sum(i.quantity) FROM order_items i JOIN products p USING (product_id) GROUP BY p.sku"):
        args += [units, sku]
    r("ZADD", "northstar:leaderboard:units", *args)

    daily = source.execute("SELECT date(placed_at), count(*) FROM orders WHERE placed_at >= date('2026-10-29', '-30 day') GROUP BY 1")
    args = [item for row in daily for item in row]
    r("HSET", "northstar:stats:orders:daily", *args)
    total, revenue = source.execute("SELECT count(*), round(sum(total), 2) FROM orders WHERE status NOT IN ('cancelled', 'refunded')").fetchone()
    r("SET", "northstar:counter:orders", total)
    r("SET", "northstar:counter:revenue", "%.2f" % revenue)
    r("SET", "northstar:config:feature-flags", json.dumps({"new_checkout": True, "apple_pay": True, "gift_cards": False}))

    for row in source.execute("SELECT order_number, customer_id, status, channel, total FROM orders ORDER BY order_id DESC LIMIT 200"):
        r("XADD", "northstar:stream:orders", "*", "order", row[0], "customer", row[1], "status", row[2],
          "channel", row[3], "total", "%.2f" % row[4])
    r("XGROUP", "CREATE", "northstar:stream:orders", "fulfilment", "0")

    count = 0
    cursor = "0"
    while True:
        cursor, keys = r("SCAN", cursor, "MATCH", "northstar:*", "COUNT", 1000)
        count += len(keys)
        if cursor == "0":
            break
    print("%d keys under northstar: in db %d" % (count, DB))


if __name__ == "__main__":
    main()
