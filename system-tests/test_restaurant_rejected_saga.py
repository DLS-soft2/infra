import time
import uuid

import httpx
import pytest

ORDER_SERVICE_URL = "http://localhost:18001"
PAYMENT_SERVICE_URL = "http://localhost:18002"
RESTAURANT_SERVICE_URL = "http://localhost:18003"

CUSTOMER_HEADERS = {
    "X-User-Id": str(uuid.uuid4()),
    "X-User-Roles": "customer",
}

POPS_PIZZA_KEYCLOAK_ID = "aaaaaaaa-1111-2222-3333-000000000003"
RESTAURANT_HEADERS = {
    "X-User-Id": POPS_PIZZA_KEYCLOAK_ID,
    "X-User-Roles": "restaurant",
}

SEEDED_RESTAURANT_ID = "550e8400-e29b-41d4-a716-446655440001"

SAGA_TIMEOUT_SECONDS = 120
POLL_INTERVAL_START = 1.0
POLL_INTERVAL_MAX = 5.0
POLL_BACKOFF_FACTOR = 1.5


def wait_for_health(base_url: str, label: str, path: str = "/health", timeout: int = 90) -> None:
    """Poll a service health endpoint until it responds 200."""
    deadline = time.monotonic() + timeout
    interval = 1.0
    last_err = None
    while time.monotonic() < deadline:
        try:
            resp = httpx.get(f"{base_url}{path}", timeout=5)
            if resp.status_code == 200:
                return
        except httpx.HTTPError as exc:
            last_err = exc
        time.sleep(interval)
        interval = min(interval * 1.5, 5.0)
    pytest.fail(f"{label} did not become healthy within {timeout}s: {last_err}")


def poll_order_status(order_id: str, target_status: str, timeout: int = SAGA_TIMEOUT_SECONDS) -> str:
    """Poll GET /api/v1/orders/{id} until the order reaches target_status."""
    deadline = time.monotonic() + timeout
    interval = POLL_INTERVAL_START
    final_status = None
    while time.monotonic() < deadline:
        time.sleep(interval)
        resp = httpx.get(
            f"{ORDER_SERVICE_URL}/api/v1/orders/{order_id}",
            headers=CUSTOMER_HEADERS,
            timeout=10,
        )
        assert resp.status_code == 200
        final_status = resp.json()["status"]
        if final_status == target_status:
            return final_status
        interval = min(interval * POLL_BACKOFF_FACTOR, POLL_INTERVAL_MAX)
    return final_status


def test_restaurant_rejected_order_cancelled():
    """Restaurant rejects a PAID order -> PaymentRefunded -> CANCELLED.

    1. Create order (PENDING) -> payment-service authorizes -> PAID.
    2. Restaurant owner rejects the order with a reason.
    3. RestaurantRejected event -> payment-service refunds -> PaymentRefunded.
    4. order-service consumes PaymentRefunded -> CANCELLED.
    5. Payment status transitions to REFUNDED.
    """
    wait_for_health(ORDER_SERVICE_URL, "order-service")
    wait_for_health(PAYMENT_SERVICE_URL, "payment-service")
    wait_for_health(RESTAURANT_SERVICE_URL, "restaurant-service", path="/actuator/health")

    order_body = {
        "restaurant_id": SEEDED_RESTAURANT_ID,
        "delivery_address": "10 Rejection Lane, Copenhagen",
        "items": [
            {
                "menu_item_id": str(uuid.uuid4()),
                "name": "Pepperoni Pizza",
                "quantity": 2,
                "unit_price": 50.0,
            }
        ],
    }

    create_resp = httpx.post(
        f"{ORDER_SERVICE_URL}/api/v1/orders/",
        json=order_body,
        headers=CUSTOMER_HEADERS,
        timeout=15,
    )
    assert create_resp.status_code == 201, (
        f"Order creation failed: {create_resp.status_code} {create_resp.text}"
    )

    order = create_resp.json()
    order_id = order["id"]
    assert order["status"] == "PENDING"

    # Wait for PAID before rejecting (restaurant-service needs PendingOrder)
    status = poll_order_status(order_id, "PAID")
    assert status == "PAID", (
        f"Order did not reach PAID within {SAGA_TIMEOUT_SECONDS}s (status: {status})"
    )

    # Restaurant rejects the order
    reject_resp = httpx.post(
        f"{RESTAURANT_SERVICE_URL}/api/v2/restaurants/orders/{order_id}/reject",
        headers=RESTAURANT_HEADERS,
        json={"reason": "Out of ingredients"},
        timeout=15,
    )
    assert reject_resp.status_code == 200, (
        f"Restaurant reject failed: {reject_resp.status_code} {reject_resp.text}"
    )

    # Poll until CANCELLED (RestaurantRejected -> refund -> PaymentRefunded -> CANCELLED)
    final_status = poll_order_status(order_id, "CANCELLED")
    assert final_status == "CANCELLED", (
        f"Order {order_id} did not reach CANCELLED within {SAGA_TIMEOUT_SECONDS}s "
        f"(final status: {final_status})"
    )

    # Verify payment was refunded
    payments_resp = httpx.get(
        f"{PAYMENT_SERVICE_URL}/api/v1/payments/order/{order_id}",
        headers=CUSTOMER_HEADERS,
        timeout=10,
    )
    assert payments_resp.status_code == 200
    payments = payments_resp.json()
    assert len(payments) >= 1, "Expected at least one payment record"
    refunded_payments = [p for p in payments if p["status"] == "REFUNDED"]
    assert len(refunded_payments) >= 1, (
        f"Expected at least one REFUNDED payment, got statuses: "
        f"{[p['status'] for p in payments]}"
    )
