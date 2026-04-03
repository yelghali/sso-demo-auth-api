"""
SSO Demo - Unified API service.
Responds based on SERVICE_NAME env var (orders, users, products).
"""
from flask import Flask, jsonify, request
import os

app = Flask(__name__)

SERVICE_NAME = os.getenv("SERVICE_NAME", "unknown")
CLUSTER_NAME = os.getenv("CLUSTER_NAME", "unknown")
INGRESS_TYPE = os.getenv("INGRESS_TYPE", "unknown")

MOCK_DATA = {
    "orders": [
        {"id": 1, "product": "Widget A", "quantity": 5, "status": "shipped", "total": 149.95},
        {"id": 2, "product": "Widget B", "quantity": 3, "status": "pending", "total": 89.97},
        {"id": 3, "product": "Gadget C", "quantity": 1, "status": "delivered", "total": 249.99},
    ],
    "users": [
        {"id": 1, "name": "Alice Johnson", "email": "alice@example.com", "role": "admin"},
        {"id": 2, "name": "Bob Smith", "email": "bob@example.com", "role": "editor"},
        {"id": 3, "name": "Carol Williams", "email": "carol@example.com", "role": "viewer"},
    ],
    "products": [
        {"id": 1, "name": "Widget A", "price": 29.99, "category": "widgets", "stock": 142},
        {"id": 2, "name": "Widget B", "price": 29.99, "category": "widgets", "stock": 89},
        {"id": 3, "name": "Gadget C", "price": 249.99, "category": "gadgets", "stock": 23},
    ],
    "legacy": [
        {"id": 1, "system": "ERP", "endpoint": "/api/v1/invoices", "status": "active"},
        {"id": 2, "system": "CRM", "endpoint": "/api/v1/contacts", "status": "active"},
        {"id": 3, "system": "HR", "endpoint": "/api/v1/employees", "status": "deprecated"},
    ],
}


@app.route("/", methods=["GET"])
@app.route(f"/{SERVICE_NAME}", methods=["GET"])
def get_data():
    return jsonify({
        "service": SERVICE_NAME,
        "cluster": CLUSTER_NAME,
        "ingress": INGRESS_TYPE,
        "count": len(MOCK_DATA.get(SERVICE_NAME, [])),
        "data": MOCK_DATA.get(SERVICE_NAME, []),
    })


@app.route("/health", methods=["GET"])
@app.route(f"/{SERVICE_NAME}/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy", "service": SERVICE_NAME, "cluster": CLUSTER_NAME})


@app.route(f"/{SERVICE_NAME}/<path:subpath>", methods=["GET"])
def prefixed_catchall(subpath):
    """Handle prefixed paths like /orders/items when routed via path-based ingress."""
    return jsonify({
        "service": SERVICE_NAME,
        "cluster": CLUSTER_NAME,
        "ingress": INGRESS_TYPE,
        "path": f"/{SERVICE_NAME}/{subpath}",
        "count": len(MOCK_DATA.get(SERVICE_NAME, [])),
        "data": MOCK_DATA.get(SERVICE_NAME, []),
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
