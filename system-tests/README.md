# System-Level Cooperation Test

Proves that order-service and payment-service cooperate through Kafka
to advance the order saga from PENDING to PAID.

## What It Proves

1. Both services boot against real PostgreSQL and Kafka (no mocks).
2. Creating an order via REST triggers an `OrderCreated` Kafka event.
3. payment-service consumes the event, authorizes the payment, and
   publishes `PaymentAuthorized` back to Kafka.
4. order-service consumes the payment event and transitions the order
   status to `PAID`.

## Prerequisites

- Docker (with Compose v2)
- Python 3.11+

## Run

```bash
cd infra/system-tests
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
docker compose -f docker-compose.test.yaml up -d --build --wait
pytest test_order_payment_saga.py -v
docker compose -f docker-compose.test.yaml down -v
```

Or as a single command (cleanup runs even if the test fails):

```bash
cd infra/system-tests && \
  python -m venv .venv && source .venv/bin/activate && \
  pip install -r requirements.txt && \
  docker compose -f docker-compose.test.yaml up -d --build --wait && \
  pytest test_order_payment_saga.py -v ; \
  docker compose -f docker-compose.test.yaml down -v
```
