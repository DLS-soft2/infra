# System-Level Cooperation Tests

Proves that microservices cooperate through Kafka to advance the order
saga across multiple paths: happy path, payment failure, and restaurant
rejection with compensating refund.

## Test Scenarios

### Order -> PAID (`test_order_payment_saga.py`)

Verifies order-service and payment-service cooperate through Kafka.
Creates an order and asserts it transitions from PENDING to PAID via
the OrderCreated -> PaymentAuthorized event chain.

### Full Happy Path -> DELIVERED (`test_happy_path_delivered.py`)

Exercises the complete saga: PENDING -> PAID -> PREPARING ->
OUT_FOR_DELIVERY -> DELIVERED. After auto-payment, the restaurant
accepts the order, courier-service auto-assigns a courier, and a
courier marks the delivery complete. Asserts the snapshot audit trail
contains entries for all five states.

### Payment Failed -> CANCELLED (`test_payment_failed_saga.py`)

Creates an order with total > 10000 (the payment-service rejection
threshold). Asserts the order transitions to CANCELLED via
PaymentFailed and that the payment record has status FAILED.

### Restaurant Rejected -> Refund -> CANCELLED (`test_restaurant_rejected_saga.py`)

Creates an order, waits for PAID, then the restaurant rejects it.
Verifies the compensating action chain: RestaurantRejected ->
payment-service refunds -> PaymentRefunded -> order CANCELLED. Asserts
the payment record transitions to REFUNDED.

## Prerequisites

- Docker (with Compose v2)
- Python 3.11+

## Run

```bash
cd infra/system-tests
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Individual scenarios (conftest auto-starts the saga compose stack):

```bash
pytest test_order_payment_saga.py -v          # PENDING -> PAID
pytest test_payment_failed_saga.py -v         # PaymentFailed -> CANCELLED
pytest test_happy_path_delivered.py -v        # full happy path -> DELIVERED
pytest test_restaurant_rejected_saga.py -v    # RestaurantRejected -> CANCELLED
```

All scenarios together:

```bash
pytest -v
```

The conftest fixture boots the 8-service saga stack on first test
invocation and tears it down with `docker compose down -v` after the
session completes.