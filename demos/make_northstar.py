#!/usr/bin/env python3
"""Builds Northstar.sqlite, the fictional outdoor-gear shop used for Portbase demos and screenshots.

Every name, address, and order is invented; emails use the reserved example.com/.net/.org domains.
The output is deterministic, so rebuilding gives the same database:

    python3 Demo/make_northstar.py [output path]
"""
import datetime as dt
import json
import os
import random
import sqlite3
import struct
import sys
import zlib

rng = random.Random(2026)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "Northstar.sqlite")
START = dt.date(2024, 11, 1)
END = dt.date(2026, 10, 29)

SCHEMA = """
PRAGMA foreign_keys = ON;

CREATE TABLE categories (
    category_id INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    parent_id   INTEGER REFERENCES categories(category_id)
);

CREATE TABLE products (
    product_id    INTEGER PRIMARY KEY,
    sku           TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    category_id   INTEGER NOT NULL REFERENCES categories(category_id),
    price         NUMERIC NOT NULL CHECK (price > 0),
    cost          NUMERIC NOT NULL,
    weight_grams  INTEGER,
    attributes    JSON,
    launched_on   DATE NOT NULL,
    discontinued  BOOLEAN NOT NULL DEFAULT 0,
    swatch        BLOB
);

CREATE TABLE customers (
    customer_id      INTEGER PRIMARY KEY,
    first_name       TEXT NOT NULL,
    last_name        TEXT NOT NULL,
    email            TEXT NOT NULL UNIQUE,
    city             TEXT NOT NULL,
    country          TEXT NOT NULL,
    signed_up_at     DATETIME NOT NULL,
    loyalty_tier     TEXT NOT NULL DEFAULT 'basecamp' CHECK (loyalty_tier IN ('basecamp', 'trail', 'summit')),
    marketing_opt_in BOOLEAN NOT NULL DEFAULT 0,
    notes            TEXT
);

CREATE TABLE warehouses (
    warehouse_id INTEGER PRIMARY KEY,
    code         TEXT NOT NULL UNIQUE,
    city         TEXT NOT NULL,
    latitude     REAL NOT NULL,
    longitude    REAL NOT NULL
);

CREATE TABLE inventory (
    warehouse_id  INTEGER NOT NULL REFERENCES warehouses(warehouse_id),
    product_id    INTEGER NOT NULL REFERENCES products(product_id),
    on_hand       INTEGER NOT NULL CHECK (on_hand >= 0),
    reorder_point INTEGER NOT NULL,
    counted_at    DATETIME NOT NULL,
    PRIMARY KEY (warehouse_id, product_id)
) WITHOUT ROWID;

CREATE TABLE orders (
    order_id        INTEGER PRIMARY KEY,
    order_number    TEXT NOT NULL UNIQUE,
    customer_id     INTEGER NOT NULL REFERENCES customers(customer_id),
    placed_at       DATETIME NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('pending', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded')),
    channel         TEXT NOT NULL,
    shipping_method TEXT NOT NULL,
    warehouse_id    INTEGER REFERENCES warehouses(warehouse_id),
    subtotal        NUMERIC NOT NULL,
    discount        NUMERIC NOT NULL DEFAULT 0,
    shipping        NUMERIC NOT NULL DEFAULT 0,
    tax             NUMERIC NOT NULL DEFAULT 0,
    total           NUMERIC NOT NULL,
    coupon_code     TEXT,
    shipped_at      DATETIME,
    delivered_at    DATETIME
);

CREATE TABLE order_items (
    order_id   INTEGER NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    line_no    INTEGER NOT NULL,
    product_id INTEGER NOT NULL REFERENCES products(product_id),
    quantity   INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC NOT NULL,
    line_total NUMERIC GENERATED ALWAYS AS (round(quantity * unit_price, 2)) VIRTUAL,
    PRIMARY KEY (order_id, line_no)
);

CREATE TABLE payments (
    payment_id  INTEGER PRIMARY KEY,
    order_id    INTEGER NOT NULL REFERENCES orders(order_id),
    method      TEXT NOT NULL,
    amount      NUMERIC NOT NULL,
    captured_at DATETIME NOT NULL,
    refunded    BOOLEAN NOT NULL DEFAULT 0
);

CREATE TABLE reviews (
    review_id     INTEGER PRIMARY KEY,
    product_id    INTEGER NOT NULL REFERENCES products(product_id),
    customer_id   INTEGER NOT NULL REFERENCES customers(customer_id),
    rating        INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
    title         TEXT NOT NULL,
    body          TEXT,
    helpful_votes INTEGER NOT NULL DEFAULT 0,
    created_at    DATETIME NOT NULL
);

CREATE TABLE support_tickets (
    ticket_id   INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    order_id    INTEGER REFERENCES orders(order_id),
    subject     TEXT NOT NULL,
    priority    TEXT NOT NULL CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    status      TEXT NOT NULL CHECK (status IN ('open', 'waiting', 'resolved')),
    opened_at   DATETIME NOT NULL,
    resolved_at DATETIME
);

CREATE INDEX orders_customer ON orders(customer_id);
CREATE INDEX orders_placed_at ON orders(placed_at);
CREATE INDEX orders_status ON orders(status) WHERE status IN ('pending', 'processing');
CREATE INDEX order_items_product ON order_items(product_id);
CREATE INDEX reviews_product ON reviews(product_id, rating);
CREATE INDEX tickets_open ON support_tickets(status, priority) WHERE status <> 'resolved';

CREATE TRIGGER orders_stamp_shipment AFTER UPDATE OF status ON orders
WHEN NEW.status = 'shipped' AND NEW.shipped_at IS NULL
BEGIN
    UPDATE orders SET shipped_at = datetime('now') WHERE order_id = NEW.order_id;
END;

CREATE VIEW monthly_revenue AS
SELECT strftime('%Y-%m', placed_at) AS month,
       count(*) AS orders,
       round(sum(total), 2) AS revenue,
       round(avg(total), 2) AS average_order
FROM orders
WHERE status NOT IN ('cancelled', 'refunded')
GROUP BY month
ORDER BY month;

CREATE VIEW revenue_by_category AS
SELECT c.name AS category,
       sum(i.quantity) AS units,
       round(sum(i.line_total), 2) AS revenue
FROM order_items i
JOIN orders o USING (order_id)
JOIN products p USING (product_id)
JOIN categories c ON c.category_id = p.category_id
WHERE o.status NOT IN ('cancelled', 'refunded')
GROUP BY c.name
ORDER BY revenue DESC;

CREATE VIEW product_scorecard AS
SELECT p.sku, p.name,
       (SELECT count(*) FROM reviews r WHERE r.product_id = p.product_id) AS reviews,
       (SELECT round(avg(rating), 2) FROM reviews r WHERE r.product_id = p.product_id) AS avg_rating,
       (SELECT sum(on_hand) FROM inventory v WHERE v.product_id = p.product_id) AS on_hand,
       round((p.price - p.cost) * 100.0 / p.price, 1) AS margin_pct
FROM products p
WHERE NOT p.discontinued;

CREATE VIEW customer_lifetime_value AS
SELECT c.customer_id, c.first_name || ' ' || c.last_name AS customer, c.country, c.loyalty_tier,
       count(o.order_id) AS orders,
       round(coalesce(sum(o.total), 0), 2) AS lifetime_value,
       max(o.placed_at) AS last_order_at
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id AND o.status NOT IN ('cancelled', 'refunded')
GROUP BY c.customer_id;

CREATE VIEW low_stock AS
SELECT w.code AS warehouse, p.sku, p.name, v.on_hand, v.reorder_point
FROM inventory v
JOIN warehouses w USING (warehouse_id)
JOIN products p USING (product_id)
WHERE v.on_hand <= v.reorder_point AND NOT p.discontinued
ORDER BY v.on_hand;
"""

CATEGORIES = [
    (1, "Packs", None), (2, "Shelter", None), (3, "Sleep", None), (4, "Apparel", None),
    (5, "Footwear", None), (6, "Camp Kitchen", None), (7, "Lighting", None),
    (8, "Jackets", 4), (9, "Base Layers", 4), (10, "Accessories", 4),
]

# (name, category, price, cost, grams, attributes)
PRODUCTS = [
    ("Ridgeline 45 Pack", 1, 219.00, 92.40, 1380, {"volume_l": 45, "frame": "internal", "colors": ["slate", "ember"]}),
    ("Ridgeline 65 Pack", 1, 269.00, 112.10, 1720, {"volume_l": 65, "frame": "internal", "colors": ["slate", "moss"]}),
    ("Switchback 22 Daypack", 1, 119.00, 44.80, 640, {"volume_l": 22, "hydration": True, "colors": ["ember", "ink"]}),
    ("Cirrus 18 Running Vest", 1, 139.00, 51.20, 280, {"volume_l": 18, "flasks": 2}),
    ("Scree Sling 6", 1, 49.00, 16.30, 210, {"volume_l": 6}),
    ("Halcyon 2 Tent", 2, 449.00, 188.00, 1490, {"capacity": 2, "season": 3, "poles": "DAC NSL"}),
    ("Halcyon 3 Tent", 2, 529.00, 221.50, 1860, {"capacity": 3, "season": 3}),
    ("Polar Ridge 2 Tent", 2, 689.00, 301.00, 2650, {"capacity": 2, "season": 4}),
    ("Driftwood Tarp", 2, 159.00, 52.00, 420, {"size_m": [3, 3]}),
    ("Lantern Bivy", 2, 239.00, 96.00, 520, {"capacity": 1}),
    ("Aurora 15 Down Bag", 3, 389.00, 168.00, 980, {"comfort_c": -4, "fill_power": 850}),
    ("Aurora 30 Down Bag", 3, 329.00, 140.00, 760, {"comfort_c": 2, "fill_power": 850}),
    ("Meadow Synthetic Bag", 3, 169.00, 61.00, 1240, {"comfort_c": 4, "fill": "synthetic"}),
    ("Cloudrest Air Pad", 3, 159.00, 58.00, 450, {"r_value": 4.2, "length_cm": 183}),
    ("Cloudrest Wide Pad", 3, 189.00, 70.00, 560, {"r_value": 4.2, "length_cm": 196, "width_cm": 64}),
    ("Pillowy Camp Pillow", 3, 39.00, 11.00, 90, {}),
    ("Tundra Down Parka", 8, 379.00, 151.00, 690, {"fill_power": 800, "hood": True}),
    ("Squall Rain Shell", 8, 249.00, 94.00, 340, {"membrane": "3L", "pit_zips": True}),
    ("Fernway Wind Shell", 8, 119.00, 39.00, 110, {"packable": True}),
    ("Ember Fleece Hoodie", 8, 129.00, 42.00, 420, {"weight_gsm": 200}),
    ("Glacier Insulated Vest", 8, 159.00, 57.00, 260, {"fill": "synthetic"}),
    ("Merino 150 Crew", 9, 89.00, 31.00, 140, {"wool_pct": 100}),
    ("Merino 250 Zip", 9, 119.00, 42.00, 260, {"wool_pct": 100}),
    ("Alpine Grid Fleece", 9, 99.00, 33.00, 300, {"weight_gsm": 130}),
    ("Basecamp Tights", 9, 79.00, 26.00, 180, {}),
    ("Summit Beanie", 10, 34.00, 9.50, 70, {"material": "merino"}),
    ("Trailhead Cap", 10, 29.00, 7.80, 60, {}),
    ("Cascade Gloves", 10, 59.00, 19.00, 110, {"touchscreen": True}),
    ("Lightfoot Socks 3-Pack", 10, 45.00, 13.00, 150, {"pairs": 3}),
    ("Talus Hiking Boot", 5, 229.00, 98.00, 1180, {"waterproof": True, "drop_mm": 10}),
    ("Talus Mid Boot", 5, 199.00, 84.00, 1020, {"waterproof": True, "drop_mm": 8}),
    ("Skyrunner Trail Shoe", 5, 159.00, 61.00, 590, {"drop_mm": 6, "lug_mm": 5}),
    ("Camp Slide", 5, 49.00, 14.00, 300, {}),
    ("Jetfire Stove", 6, 129.00, 47.00, 380, {"fuel": "isobutane", "boil_time_s": 100}),
    ("Titanium Pot 750", 6, 54.00, 19.00, 105, {"capacity_ml": 750}),
    ("Fold-Flat Kitchen Set", 6, 79.00, 27.00, 520, {"pieces": 9}),
    ("Clearwater Filter", 6, 44.00, 14.00, 85, {"liters_per_min": 1.7}),
    ("Spork Duo", 6, 14.00, 3.20, 18, {}),
    ("Beacon 400 Headlamp", 7, 59.00, 20.00, 82, {"lumens": 400, "rechargeable": True}),
    ("Beacon 900 Headlamp", 7, 99.00, 35.00, 110, {"lumens": 900, "rechargeable": True}),
    ("Glowworm Lantern", 7, 49.00, 15.00, 160, {"lumens": 250}),
    ("Solar Panel 10W", 7, 89.00, 34.00, 340, {"watts": 10}),
    ("Ridgeline 40 Pack (2023)", 1, 189.00, 84.00, 1350, {"volume_l": 40}),
    ("Halcyon 1 Tent (2023)", 2, 349.00, 160.00, 1210, {"capacity": 1}),
]
DISCONTINUED = {"Ridgeline 40 Pack (2023)", "Halcyon 1 Tent (2023)"}
SEASONAL_WINTER = {"Tundra Down Parka", "Aurora 15 Down Bag", "Polar Ridge 2 Tent", "Summit Beanie", "Cascade Gloves", "Merino 250 Zip", "Glacier Insulated Vest"}
SEASONAL_SUMMER = {"Halcyon 2 Tent", "Halcyon 3 Tent", "Switchback 22 Daypack", "Skyrunner Trail Shoe", "Clearwater Filter", "Trailhead Cap", "Cirrus 18 Running Vest", "Camp Slide"}

FIRST = ["Ava", "Liam", "Maya", "Noah", "Zoë", "Ethan", "Priya", "Mateo", "Hana", "Lucas", "Amara", "Oliver", "Sofia", "Kai",
         "Ingrid", "Jonas", "Chloé", "Rafael", "Leila", "Theo", "Aisha", "Finn", "Elena", "Diego", "Nora", "Arjun", "Freya",
         "Malik", "Isla", "Søren", "Yuki", "Camila", "Henrik", "Ines", "Tariq", "Mila", "Elias", "Ruby", "Omar", "June",
         "Beatriz", "Callum", "Anouk", "Tomás", "Wren", "Emeka", "Saoirse", "Kenji", "Astrid", "Gabriel"]
LAST = ["Okafor", "Lindqvist", "Moreau", "Tanaka", "Fernández", "Novak", "Haddad", "Kowalski", "Bergstrom", "Nakamura",
        "Rossi", "Mensah", "Dubois", "Chen", "Patel", "O'Brien", "Schmidt", "Silva", "Kim", "Larsen", "Ivanova", "Walsh",
        "Costa", "Müller", "Abebe", "Hughes", "Jensen", "Kaur", "Reyes", "Sato", "Andersen", "Bauer", "Quinn", "Ortiz",
        "Nguyen", "Farah", "Holm", "Petrov", "Lambert", "Mori"]
LOCAL_NAMES = {
    "Japan": [("美咲", "佐藤"), ("陽翔", "鈴木"), ("結衣", "高橋"), ("蓮", "伊藤")],
    "South Korea": [("서연", "김"), ("민준", "박"), ("지우", "이")],
    "Taiwan": [("怡君", "陳"), ("家豪", "林"), ("雅婷", "黃")],
}
PLACES = [
    ("Denver", "United States", 9), ("Seattle", "United States", 9), ("Portland", "United States", 6), ("Boulder", "United States", 4),
    ("Salt Lake City", "United States", 5), ("Asheville", "United States", 3), ("Burlington", "United States", 2),
    ("Vancouver", "Canada", 6), ("Calgary", "Canada", 4), ("Montréal", "Canada", 3), ("Squamish", "Canada", 2),
    ("Munich", "Germany", 4), ("Innsbruck", "Austria", 3), ("Chamonix", "France", 2), ("Lyon", "France", 2),
    ("Zürich", "Switzerland", 3), ("Bergen", "Norway", 2), ("Tromsø", "Norway", 1), ("Stockholm", "Sweden", 2),
    ("Edinburgh", "United Kingdom", 3), ("Keswick", "United Kingdom", 1), ("Queenstown", "New Zealand", 2),
    ("Hobart", "Australia", 2), ("Sapporo", "Japan", 2), ("Matsumoto", "Japan", 1), ("Seoul", "South Korea", 2),
    ("Taipei", "Taiwan", 1), ("Reykjavík", "Iceland", 1),
]
NOTES = [None] * 30 + [
    "Prefers delivery to the trailhead shop in town.", "Leave parcels with the neighbour at no. 12 📦",
    "Guide service — ships in bulk before each season.", "Asked about warranty on a 2023 tent pole.",
    "Club account: Ridge Runners hiking club.", "Allergic to wool; recommend synthetic layers.",
    "VIP since launch week.", "Gift orders around December — wrap by default 🎁",
]
REVIEW_TITLES = {
    5: ["Exactly what I needed", "Worth every gram", "Bomber build quality", "My new favourite piece of kit", "Five trips in and still perfect"],
    4: ["Great, with one small gripe", "Solid and comfortable", "Very good value", "Would buy again"],
    3: ["Does the job", "Fine for the price", "Mixed feelings"],
    2: ["Fit runs small", "Zipper snagged on day two"],
    1: ["Returned it", "Not for wet climates"],
}
REVIEW_BODIES = [None, None,
    "Took it across the Lofoten traverse — dry, warm, and packs down small.",
    "Carried 14 kg comfortably for three days. Hip belt could be wider.",
    "Survived a properly windy night above the tree line.",
    "Lighter than my old one by almost half.",
    "Sizing guide was spot on.",
    "Colour is darker than the photos.",
    "Customer service swapped the size with no fuss.",
]
TICKET_SUBJECTS = ["Where is my order?", "Wrong size delivered", "Return label request", "Warranty claim: broken buckle",
                   "Change shipping address", "Missing item in parcel", "Question about tent footprint", "Coupon didn't apply",
                   "Damaged on arrival", "Exchange for a different colour"]
COUPONS = ["TRAIL10", "SUMMIT15", "WELCOME10", "BLACKFRIDAY25", "SPRINGMELT", "FREESHIP"]


def swatch(rgb):
    """A 16×16 solid PNG, so the BLOB column holds real image bytes."""
    raw = b"".join(b"\x00" + bytes(rgb) * 16 for _ in range(16))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def stamp(day, hour=None):
    hour = rng.choices(range(24), weights=[1, 1, 1, 1, 1, 2, 3, 5, 6, 7, 8, 8, 9, 8, 8, 8, 8, 9, 10, 11, 10, 8, 5, 3])[0] if hour is None else hour
    return dt.datetime.combine(day, dt.time(hour, rng.randrange(60), rng.randrange(60)))


def iso(moment):
    return moment.strftime("%Y-%m-%d %H:%M:%S")


def season_weight(day):
    # Outdoor retail: a summer peak, a bigger holiday peak, and steady growth.
    month_factor = {1: 0.8, 2: 0.75, 3: 0.9, 4: 1.0, 5: 1.15, 6: 1.3, 7: 1.35, 8: 1.2, 9: 0.95, 10: 0.95, 11: 1.45, 12: 1.7}[day.month]
    growth = 1 + 0.75 * (day - START).days / (END - START).days
    weekend = 1.15 if day.weekday() >= 5 else 1.0
    spike = 3.2 if (day.month == 11 and 24 <= day.day <= 30) else 1.0
    return month_factor * growth * weekend * spike


def build():
    if os.path.exists(OUT):
        os.remove(OUT)
    db = sqlite3.connect(OUT)
    db.executescript(SCHEMA)

    db.executemany("INSERT INTO categories VALUES (?, ?, ?)", CATEGORIES)

    products = []
    for index, (name, category, price, cost, grams, attributes) in enumerate(PRODUCTS, start=1):
        sku = "NS-%s-%03d" % ("".join(w[0] for w in name.split() if w[0].isalpha())[:3].upper(), index)
        launched = START - dt.timedelta(days=rng.randrange(60, 700)) if "(2023)" in name else START + dt.timedelta(days=rng.randrange(-200, 420))
        color = (rng.randrange(40, 200), rng.randrange(60, 180), rng.randrange(40, 160))
        products.append(dict(id=index, name=name, price=price, launched=launched, discontinued=name in DISCONTINUED))
        db.execute("INSERT INTO products VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                   (index, sku, name, category, price, cost, grams if rng.random() > 0.05 else None,
                    json.dumps(attributes, ensure_ascii=False) if attributes else None,
                    launched.isoformat(), int(name in DISCONTINUED), swatch(color) if rng.random() > 0.15 else None))

    warehouses = [(1, "DEN-1", "Denver", 39.7392, -104.9903), (2, "RNO-2", "Reno", 39.5296, -119.8138),
                  (3, "ROT-1", "Rotterdam", 51.9244, 4.4777)]
    db.executemany("INSERT INTO warehouses VALUES (?, ?, ?, ?, ?)", warehouses)
    for warehouse_id, *_ in warehouses:
        for product in products:
            reorder = rng.choice([10, 15, 20, 25, 40])
            on_hand = 0 if product["discontinued"] else max(0, int(rng.gauss(reorder * 3.2, reorder * 1.1)))
            counted = stamp(END - dt.timedelta(days=rng.randrange(0, 6)))
            db.execute("INSERT INTO inventory VALUES (?, ?, ?, ?, ?)", (warehouse_id, product["id"], on_hand, reorder, iso(counted)))

    # Customers sign up over the whole period, a little faster as the shop grows.
    customers = []
    used_emails = set()
    for customer_id in range(1, 1601):
        city, country = rng.choices([(c, n) for c, n, _ in PLACES], weights=[w for *_, w in PLACES])[0]
        if country in LOCAL_NAMES and rng.random() < 0.6:
            first, last = rng.choice(LOCAL_NAMES[country])
            local = "%s.%d" % (rng.choice(["hiker", "trail", "summit", "camp"]), customer_id)
        else:
            first, last = rng.choice(FIRST), rng.choice(LAST)
            local = "%s.%s" % (first, last)
            local = local.lower().replace("'", "").translate(str.maketrans("öüëéèóáíøç", "oueeeoaioc"))
        email = "%s@%s" % (local, rng.choice(["example.com", "example.net", "example.org"]))
        while email in used_emails:
            email = "%s%d@%s" % (local, rng.randrange(10, 99), email.split("@")[1])
        used_emails.add(email)
        offset = int((rng.random() ** 0.8) * ((END - START).days + 300)) - 300
        signed_up = stamp(START + dt.timedelta(days=offset))
        customers.append(dict(id=customer_id, signed_up=signed_up, orders=0, spend=0.0))
        db.execute("INSERT INTO customers VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                   (customer_id, first, last, email, city, country, iso(signed_up), "basecamp",
                    int(rng.random() < 0.55), rng.choice(NOTES)))

    # Orders: a few per day early on, rising to dozens around the holidays.
    order_id = 0
    payment_id = 0
    review_id = 0
    ticket_id = 0
    loyal = [c for c in customers if rng.random() < 0.25]
    day = START
    while day <= END:
        count = max(0, int(rng.gauss(9 * season_weight(day), 2.5)))
        available = [p for p in products if p["launched"] <= day and not (p["discontinued"] and day > dt.date(2025, 6, 1))]
        signed = [c for c in customers if c["signed_up"].date() <= day]
        for _ in range(count):
            if not signed:
                break
            order_id += 1
            customer = rng.choice(loyal) if loyal and rng.random() < 0.35 and loyal[0]["signed_up"].date() <= day else rng.choice(signed)
            if customer["signed_up"].date() > day:
                customer = rng.choice(signed)
            placed = stamp(day)
            age = (END - day).days
            status = ("pending" if age == 0 else "processing" if age <= 2 else "shipped" if age <= 6 else
                      rng.choices(["delivered", "cancelled", "refunded"], weights=[94, 3.5, 2.5])[0])
            if age <= 6 and rng.random() < 0.04:
                status = "cancelled"
            weights = []
            for p in available:
                w = 1.0
                if p["name"] in SEASONAL_WINTER:
                    w *= 2.4 if day.month in (11, 12, 1, 2) else 0.5
                if p["name"] in SEASONAL_SUMMER:
                    w *= 2.2 if day.month in (5, 6, 7, 8) else 0.6
                if p["price"] < 60:
                    w *= 1.8
                weights.append(w)
            lines = rng.choices([1, 2, 3, 4], weights=[52, 28, 14, 6])[0]
            picked = []
            for product in rng.choices(available, weights=weights, k=lines):
                if product not in picked:
                    picked.append(product)
            items = []
            for line_no, product in enumerate(picked, start=1):
                quantity = rng.choices([1, 2, 3], weights=[82, 14, 4])[0]
                if product["price"] < 50 and rng.random() < 0.2:
                    quantity += 2
                unit = product["price"]
                if day.month == 11 and 24 <= day.day <= 30 and rng.random() < 0.6:
                    unit = round(unit * 0.8, 2)
                items.append((order_id, line_no, product["id"], quantity, unit))
            subtotal = round(sum(q * u for *_, q, u in items), 2)
            coupon = rng.choice(COUPONS) if rng.random() < 0.14 else None
            discount = round(subtotal * {"TRAIL10": .10, "SUMMIT15": .15, "WELCOME10": .10, "BLACKFRIDAY25": .25, "SPRINGMELT": .12, "FREESHIP": 0}[coupon], 2) if coupon else 0
            method = rng.choices(["standard", "express", "pickup", "freight"], weights=[68, 22, 7, 3])[0]
            shipping = 0 if subtotal >= 150 or coupon == "FREESHIP" or method == "pickup" else {"standard": 8.95, "express": 19.95, "freight": 49.0}[method]
            tax = round((subtotal - discount) * rng.choice([0, 0.0725, 0.0825, 0.19, 0.2, 0.1]), 2)
            total = round(subtotal - discount + shipping + tax, 2)
            warehouse = 3 if customer["id"] % 7 in (2, 5) else rng.choice([1, 2])
            shipped = delivered = None
            if status in ("shipped", "delivered", "refunded"):
                shipped = placed + dt.timedelta(hours=rng.randrange(6, 60))
            if status in ("delivered", "refunded"):
                delivered = shipped + dt.timedelta(days=rng.randrange(1, 7), hours=rng.randrange(0, 10))
            channel = rng.choices(["web", "ios_app", "marketplace", "pop_up_store"], weights=[55, 25 + (day.year - 2024) * 8, 12, 4])[0]
            db.execute("INSERT INTO orders VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       (order_id, "NS-%06d" % (100000 + order_id * 7 % 900000), customer["id"], iso(placed), status, channel,
                        method, warehouse, subtotal, discount, shipping, tax, total, coupon,
                        iso(shipped) if shipped else None, iso(delivered) if delivered else None))
            db.executemany("INSERT INTO order_items (order_id, line_no, product_id, quantity, unit_price) VALUES (?, ?, ?, ?, ?)", items)
            if status not in ("pending", "cancelled"):
                payment_id += 1
                db.execute("INSERT INTO payments VALUES (?, ?, ?, ?, ?, ?)",
                           (payment_id, order_id, rng.choices(["card", "apple_pay", "paypal", "gift_card", "klarna"], weights=[48, 24, 16, 5, 7])[0],
                            total, iso(placed + dt.timedelta(seconds=rng.randrange(2, 90))), int(status == "refunded")))
            if status in ("delivered", "refunded"):
                customer["orders"] += 1
                customer["spend"] += total
            if status == "delivered" and rng.random() < 0.28:
                review_id += 1
                product = rng.choice(picked)
                quality = 0.4 if "(2023)" in product["name"] else (0.0 if product["id"] % 5 else -0.6)
                rating = max(1, min(5, round(rng.gauss(4.3 + quality, 0.9))))
                when = delivered + dt.timedelta(days=rng.randrange(2, 40))
                if when.date() <= END:
                    db.execute("INSERT INTO reviews VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                               (review_id, product["id"], customer["id"], rating, rng.choice(REVIEW_TITLES[rating]),
                                rng.choice(REVIEW_BODIES), int(rng.expovariate(0.25)), iso(when)))
            if rng.random() < 0.045:
                ticket_id += 1
                opened = placed + dt.timedelta(days=rng.randrange(1, 15), hours=rng.randrange(0, 12))
                resolved = opened + dt.timedelta(hours=rng.randrange(1, 96))
                open_now = resolved.date() > END or (END - opened.date()).days < 5
                state = rng.choice(["open", "waiting"]) if open_now else "resolved"
                db.execute("INSERT INTO support_tickets VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                           (ticket_id, customer["id"], order_id if rng.random() > 0.08 else None, rng.choice(TICKET_SUBJECTS),
                            rng.choices(["low", "normal", "high", "urgent"], weights=[20, 55, 20, 5])[0], state,
                            iso(opened), iso(resolved) if state == "resolved" else None))
        day += dt.timedelta(days=1)

    for customer in customers:
        tier = "summit" if customer["spend"] >= 1500 else "trail" if customer["orders"] >= 3 or customer["spend"] >= 500 else "basecamp"
        db.execute("UPDATE customers SET loyalty_tier = ? WHERE customer_id = ?", (tier, customer["id"]))

    db.commit()
    db.execute("ANALYZE")
    db.execute("VACUUM")
    db.close()


if __name__ == "__main__":
    build()
    db = sqlite3.connect(OUT)
    for table in ["customers", "products", "orders", "order_items", "payments", "reviews", "support_tickets", "inventory"]:
        print("%-16s %6d" % (table, db.execute("SELECT count(*) FROM %s" % table).fetchone()[0]))
    print("size %.1f MB → %s" % (os.path.getsize(OUT) / 1e6, OUT))
