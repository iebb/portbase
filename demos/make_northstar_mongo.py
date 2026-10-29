#!/usr/bin/env python3
"""Loads the Northstar demo into MongoDB as documents, from the SQLite database make_northstar.py builds.

Orders embed their line items and payment, products embed their stock and rating summary, and warehouses
carry GeoJSON points, so the data looks the way a document store would hold it. Needs pymongo:

    python3 demos/make_northstar_mongo.py [mongodb://127.0.0.1:27017/northstar]

The target database is dropped and rebuilt.
"""
import datetime as dt
import json
import os
import sqlite3
import sys
from decimal import Decimal

from bson import Binary, Decimal128
from pymongo import ASCENDING, DESCENDING, GEOSPHERE, TEXT, IndexModel, MongoClient

HERE = os.path.dirname(os.path.abspath(__file__))
URI = sys.argv[1] if len(sys.argv) > 1 else "mongodb://127.0.0.1:27017/northstar"


def money(value):
    return Decimal128(Decimal(str(value)).quantize(Decimal("0.01")))


def when(text):
    return dt.datetime.fromisoformat(text).replace(tzinfo=dt.timezone.utc) if text else None


def main():
    source = sqlite3.connect(os.path.join(HERE, "Northstar.sqlite"))
    source.row_factory = sqlite3.Row
    client = MongoClient(URI)
    db = client.get_default_database("northstar")
    client.drop_database(db.name)

    categories = {row["category_id"]: dict(row) for row in source.execute("SELECT * FROM categories")}
    warehouses = {row["warehouse_id"]: dict(row) for row in source.execute("SELECT * FROM warehouses")}
    db.warehouses.insert_many([{
        "_id": w["code"], "city": w["city"],
        "location": {"type": "Point", "coordinates": [w["longitude"], w["latitude"]]},
    } for w in warehouses.values()])

    stock = {}
    for row in source.execute("SELECT * FROM inventory"):
        stock.setdefault(row["product_id"], []).append({
            "warehouse": warehouses[row["warehouse_id"]]["code"], "onHand": row["on_hand"],
            "reorderPoint": row["reorder_point"], "countedAt": when(row["counted_at"])})
    ratings = {row[0]: (row[1], row[2]) for row in source.execute(
        "SELECT product_id, count(*), round(avg(rating), 2) FROM reviews GROUP BY product_id")}
    products = {}
    documents = []
    for row in source.execute("SELECT * FROM products"):
        category = categories[row["category_id"]]
        parent = categories.get(category["parent_id"])
        products[row["product_id"]] = row
        count, average = ratings.get(row["product_id"], (0, None))
        document = {
            "_id": row["sku"], "name": row["name"],
            "category": {"name": category["name"], "parent": parent["name"]} if parent else {"name": category["name"]},
            "price": money(row["price"]), "cost": money(row["cost"]),
            "weightGrams": row["weight_grams"],
            "attributes": json.loads(row["attributes"]) if row["attributes"] else {},
            "launchedOn": when(row["launched_on"] + " 00:00:00"),
            "discontinued": bool(row["discontinued"]),
            "stock": stock.get(row["product_id"], []),
            "rating": {"average": average, "count": count},
        }
        if row["swatch"] is not None:
            document["swatch"] = Binary(row["swatch"])
        documents.append(document)
    db.products.insert_many(documents)

    customers = {}
    documents = []
    for row in source.execute("SELECT * FROM customers"):
        customers[row["customer_id"]] = row
        document = {
            "_id": row["customer_id"],
            "name": {"first": row["first_name"], "last": row["last_name"]},
            "email": row["email"],
            "address": {"city": row["city"], "country": row["country"]},
            "signedUpAt": when(row["signed_up_at"]),
            "loyaltyTier": row["loyalty_tier"],
            "marketingOptIn": bool(row["marketing_opt_in"]),
        }
        if row["notes"]:
            document["notes"] = row["notes"]
        documents.append(document)
    db.customers.insert_many(documents)

    items = {}
    for row in source.execute("SELECT * FROM order_items ORDER BY order_id, line_no"):
        product = products[row["product_id"]]
        items.setdefault(row["order_id"], []).append({
            "sku": product["sku"], "name": product["name"], "quantity": row["quantity"],
            "unitPrice": money(row["unit_price"]), "lineTotal": money(row["line_total"])})
    payments = {row["order_id"]: row for row in source.execute("SELECT * FROM payments")}
    documents = []
    for row in source.execute("SELECT * FROM orders ORDER BY order_id"):
        customer = customers[row["customer_id"]]
        shipping = {"method": row["shipping_method"], "cost": money(row["shipping"])}
        if row["warehouse_id"]:
            shipping["warehouse"] = warehouses[row["warehouse_id"]]["code"]
        if row["shipped_at"]:
            shipping["shippedAt"] = when(row["shipped_at"])
        if row["delivered_at"]:
            shipping["deliveredAt"] = when(row["delivered_at"])
        document = {
            "_id": row["order_number"],
            "customer": {"id": customer["customer_id"], "name": customer["first_name"] + " " + customer["last_name"],
                         "country": customer["country"]},
            "placedAt": when(row["placed_at"]), "status": row["status"], "channel": row["channel"],
            "items": items.get(row["order_id"], []),
            "totals": {"subtotal": money(row["subtotal"]), "discount": money(row["discount"]),
                       "tax": money(row["tax"]), "total": money(row["total"])},
            "shipping": shipping,
        }
        if row["coupon_code"]:
            document["coupon"] = row["coupon_code"]
        payment = payments.get(row["order_id"])
        if payment:
            document["payment"] = {"method": payment["method"], "capturedAt": when(payment["captured_at"]),
                                   "refunded": bool(payment["refunded"])}
        documents.append(document)
    db.orders.insert_many(documents)

    db.reviews.insert_many([{
        "_id": row["review_id"], "sku": products[row["product_id"]]["sku"], "customerId": row["customer_id"],
        "rating": row["rating"], "title": row["title"], **({"body": row["body"]} if row["body"] else {}),
        "helpfulVotes": row["helpful_votes"], "createdAt": when(row["created_at"]),
    } for row in source.execute("SELECT * FROM reviews")])

    documents = []
    for row in source.execute("SELECT t.*, o.order_number FROM support_tickets t LEFT JOIN orders o USING (order_id)"):
        history = [{"at": when(row["opened_at"]), "event": "opened"}]
        if row["resolved_at"]:
            history.append({"at": when(row["resolved_at"]), "event": "resolved"})
        document = {"_id": row["ticket_id"], "customerId": row["customer_id"], "subject": row["subject"],
                    "priority": row["priority"], "status": row["status"], "history": history}
        if row["order_number"]:
            document["orderId"] = row["order_number"]
        documents.append(document)
    db.support_tickets.insert_many(documents)

    db.customers.create_indexes([IndexModel([("email", ASCENDING)], unique=True),
                                 IndexModel([("address.country", ASCENDING), ("loyaltyTier", ASCENDING)])])
    db.orders.create_indexes([
        IndexModel([("customer.id", ASCENDING), ("placedAt", DESCENDING)]),
        IndexModel([("placedAt", DESCENDING)]),
        IndexModel([("items.sku", ASCENDING)]),
        IndexModel([("status", ASCENDING)], name="open_orders",
                   partialFilterExpression={"status": {"$in": ["pending", "processing"]}}),
    ])
    db.products.create_indexes([IndexModel([("category.name", ASCENDING), ("price", DESCENDING)])])
    db.reviews.create_indexes([IndexModel([("sku", ASCENDING), ("rating", DESCENDING)]),
                               IndexModel([("title", TEXT), ("body", TEXT)], name="review_text")])
    db.warehouses.create_indexes([IndexModel([("location", GEOSPHERE)])])
    db.command({"create": "monthly_revenue", "viewOn": "orders", "pipeline": [
        {"$match": {"status": {"$nin": ["cancelled", "refunded"]}}},
        {"$group": {"_id": {"$dateToString": {"format": "%Y-%m", "date": "$placedAt"}},
                    "orders": {"$sum": 1}, "revenue": {"$sum": "$totals.total"}}},
        {"$sort": {"_id": 1}},
    ]})

    for name in sorted(db.list_collection_names()):
        print("%-16s %6d" % (name, db[name].count_documents({})))


if __name__ == "__main__":
    main()
