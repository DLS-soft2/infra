# DLS-2 Infrastructure

Shared infrastructure setup for DLS-2 microservices using Docker Compose.

## What's Included

- **Kafka** - (port 9092)
- **Kafka UI** - (port 8080)

## Usage in Services

Services can connect to Kafka using:

```
KAFKA_BOOTSTRAP_SERVERS=kafka:9092
```
