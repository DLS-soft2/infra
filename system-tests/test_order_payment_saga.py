import time
import uuid

import httpx
import pytest

ORDER_SERVICE_URL = "http://localhost:18001"
PAYMENT_SERVICE_URL = "http://localhost:18002"

AUTH_HEADERS = {
    "X-User-Id": str(uuid.uuid4()),
    "X-User-Roles": "customer",
}

SAGA_TIMEOUT_SECONDS = 60
POLL_INTERVAL_START = 0.5
POLL_INTERVAL_MAX = 4.0
POLL_BACKOFF_FACTOR = 1.5


def wait_for_health(base_url: str, label: str, timeout: int = 90) -> None:
    """Poll a service's /health endpoint until it responds 200."""
    deadline = time.monotonic() + timeout
    interval = 1.0
    last_err = None
    while time.monotonic() < deadline:
        try:
            resp = httpx.get(f"{base_url}/health", timeout=5)
            if resp.status_code == 200:
                return
        except httpx.HTTPError as exc:
            last_err = exc
        time.sleep(interval)
        interval = min(interval * 1.5, 5.0)
    pytest.fail(f"{label} did not become healthy within {timeout}s: {last_err}")


def test_order_reaches_paid_via_saga():
    """Create an order and verify it transitions to PAID via the Kafka saga.

    Flow: POST order -> OrderCreated (Kafka) -> payment-service authorizes
    -> PaymentAuthorized (Kafka) -> order-service transitions to PAID.
    """
    wait_for_health(ORDER_SERVICE_URL, "order-service")
    wait_for_health(PAYMENT_SERVICE_URL, "payment-service")

    order_body = {
        "restaurant_id": str(uuid.uuid4()),
        "delivery_address": "123 Test Street",
        "items": [
            {
                "menu_item_id": str(uuid.uuid4()),
                "name": "Test Burger",
                "quantity": 2,
                "unit_price": 9.99,
            }
        ],
    }

    create_resp = httpx.post(
        f"{ORDER_SERVICE_URL}/api/v1/orders/",
        json=order_body,
        headers=AUTH_HEADERS,
        timeout=15,
    )
    assert create_resp.status_code == 201, (
        f"Order creation failed: {create_resp.status_code} {create_resp.text}"
    )

    order = create_resp.json()
    order_id = order["id"]
    assert order["status"] == "PENDING"

    deadline = time.monotonic() + SAGA_TIMEOUT_SECONDS
    interval = POLL_INTERVAL_START
    final_status = None

    while time.monotonic() < deadline:
        time.sleep(interval)
        get_resp = httpx.get(
            f"{ORDER_SERVICE_URL}/api/v1/orders/{order_id}",
            headers=AUTH_HEADERS,
            timeout=10,
        )
        assert get_resp.status_code == 200
        final_status = get_resp.json()["status"]
        if final_status == "PAID":
            break
        interval = min(interval * POLL_BACKOFF_FACTOR, POLL_INTERVAL_MAX)

    assert final_status == "PAID", (
        f"Order {order_id} did not reach PAID within {SAGA_TIMEOUT_SECONDS}s "
        f"(final status: {final_status})"
    )
