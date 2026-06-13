import time
import uuid

import httpx
import pytest

ORDER_SERVICE_URL = "http://localhost:18001"
PAYMENT_SERVICE_URL = "http://localhost:18002"
RESTAURANT_SERVICE_URL = "http://localhost:18003"
COURIER_SERVICE_URL = "http://localhost:18004"
AI_SERVICE_URL = "http://localhost:18005"

CUSTOMER_USER_ID = str(uuid.uuid4())
CUSTOMER_HEADERS = {
    "X-User-Id": CUSTOMER_USER_ID,
    "X-User-Roles": "customer",
}

POPS_PIZZA_KEYCLOAK_ID = "aaaaaaaa-1111-2222-3333-000000000003"
RESTAURANT_HEADERS = {
    "X-User-Id": POPS_PIZZA_KEYCLOAK_ID,
    "X-User-Roles": "restaurant",
}

COURIER_HEADERS = {
    "X-User-Id": str(uuid.uuid4()),
    "X-User-Roles": "courier",
}

SEEDED_RESTAURANT_ID = "550e8400-e29b-41d4-a716-446655440001"

PER_TRANSITION_TIMEOUT = 90
POLL_INTERVAL_START = 1.0
POLL_INTERVAL_MAX = 5.0
POLL_BACKOFF_FACTOR = 1.5

# Ordered saga states for the happy path; used to detect "already past" transitions.
HAPPY_PATH_ORDER = ["PENDING", "PAID", "PREPARING", "OUT_FOR_DELIVERY", "DELIVERED"]


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


def _at_or_past(current: str, target: str) -> bool:
    """Return True if current is at or past target in the happy-path order."""
    if current not in HAPPY_PATH_ORDER or target not in HAPPY_PATH_ORDER:
        return current == target
    return HAPPY_PATH_ORDER.index(current) >= HAPPY_PATH_ORDER.index(target)


def poll_order_status(
    order_id: str, target_status: str,
    timeout: int = PER_TRANSITION_TIMEOUT, accept_past: bool = False,
) -> str:
    """Poll GET /api/v1/orders/{id} until the order reaches target_status.

    When accept_past is True, also accept any status that comes after
    target_status in the happy-path order (handles fast transitions).
    """
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
        if accept_past and _at_or_past(final_status, target_status):
            return final_status
        if final_status == target_status:
            return final_status
        interval = min(interval * POLL_BACKOFF_FACTOR, POLL_INTERVAL_MAX)
    return final_status


def test_full_happy_path_delivered():
    """S1: Full saga PENDING -> PAID -> PREPARING -> OUT_FOR_DELIVERY -> DELIVERED.

    1. Create order (PENDING) -> payment-service auto-authorizes -> PAID.
    2. Restaurant owner accepts order -> RestaurantAccepted -> PREPARING.
    3. Courier-service auto-assigns courier on RestaurantAccepted -> OUT_FOR_DELIVERY.
    4. Courier marks delivery complete -> DeliveryCompleted -> DELIVERED.
    5. Snapshots endpoint returns >= 5 entries covering all saga states.
    """
    wait_for_health(ORDER_SERVICE_URL, "order-service")
    wait_for_health(PAYMENT_SERVICE_URL, "payment-service")
    wait_for_health(RESTAURANT_SERVICE_URL, "restaurant-service", path="/actuator/health")
    wait_for_health(COURIER_SERVICE_URL, "courier-service", path="/actuator/health")
    wait_for_health(AI_SERVICE_URL, "ai-service")

    order_body = {
        "restaurant_id": SEEDED_RESTAURANT_ID,
        "delivery_address": "42 Happy Street, Copenhagen",
        "items": [
            {
                "menu_item_id": str(uuid.uuid4()),
                "name": "Margherita Pizza",
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

    # Transition 1: PENDING -> PAID (payment-service auto-authorizes via Kafka)
    status = poll_order_status(order_id, "PAID")
    assert status == "PAID", (
        f"Order did not reach PAID within {PER_TRANSITION_TIMEOUT}s (status: {status})"
    )

    # Transition 2: PAID -> PREPARING (restaurant accepts)
    accept_resp = httpx.post(
        f"{RESTAURANT_SERVICE_URL}/api/v2/restaurants/orders/{order_id}/accept",
        headers=RESTAURANT_HEADERS,
        timeout=15,
    )
    assert accept_resp.status_code == 200, (
        f"Restaurant accept failed: {accept_resp.status_code} {accept_resp.text}"
    )

    # PREPARING can be transient — courier auto-assigns so fast the order
    # may already be OUT_FOR_DELIVERY by the time we poll.
    status = poll_order_status(order_id, "PREPARING", accept_past=True)
    assert _at_or_past(status, "PREPARING"), (
        f"Order did not reach PREPARING within {PER_TRANSITION_TIMEOUT}s (status: {status})"
    )

    # Transition 3: PREPARING -> OUT_FOR_DELIVERY (courier auto-assigned via Kafka)
    status = poll_order_status(order_id, "OUT_FOR_DELIVERY", accept_past=True)
    assert _at_or_past(status, "OUT_FOR_DELIVERY"), (
        f"Order did not reach OUT_FOR_DELIVERY within {PER_TRANSITION_TIMEOUT}s "
        f"(status: {status})"
    )

    # Transition 4: OUT_FOR_DELIVERY -> DELIVERED (courier marks complete)
    complete_resp = httpx.put(
        f"{COURIER_SERVICE_URL}/api/v2/deliveries/{order_id}/complete",
        headers=COURIER_HEADERS,
        timeout=15,
    )
    assert complete_resp.status_code == 200, (
        f"Delivery complete failed: {complete_resp.status_code} {complete_resp.text}"
    )

    status = poll_order_status(order_id, "DELIVERED")
    assert status == "DELIVERED", (
        f"Order did not reach DELIVERED within {PER_TRANSITION_TIMEOUT}s "
        f"(status: {status})"
    )

    # Snapshot audit trail: at least 5 snapshots covering all saga states
    snapshots_resp = httpx.get(
        f"{ORDER_SERVICE_URL}/api/v1/orders/{order_id}/snapshots",
        headers=CUSTOMER_HEADERS,
        timeout=10,
    )
    assert snapshots_resp.status_code == 200
    snapshots = snapshots_resp.json()
    assert len(snapshots) >= 5, (
        f"Expected >= 5 snapshots, got {len(snapshots)}"
    )

    snapshot_statuses = {s["status"] for s in snapshots}
    expected_statuses = {"PENDING", "PAID", "PREPARING", "OUT_FOR_DELIVERY", "DELIVERED"}
    missing = expected_statuses - snapshot_statuses
    assert not missing, (
        f"Snapshots missing statuses: {missing}. "
        f"Found: {snapshot_statuses}"
    )
