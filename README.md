# Distributed Rabbit — Federation Demo

A demo project showing RabbitMQ federation between two nodes, with a Symfony producer app publishing messages to the upstream node and a Symfony consumer app receiving them from the downstream node after federation.

## Architecture

```
┌──────────────────┐         ┌──────────────────┐
│   RabbitMQ #1    │         │   RabbitMQ #2    │
│   (upstream)     │         │   (downstream)   │
│                  │         │                  │
│  exchange:       │  fed    │  exchange:       │
│    federation.in │◄────────│  federation.in   │
│                  │         │       │ bind     │
│                  │         │       ▼          │
│                  │         │  queue:           │
│                  │         │    consumer.queue │
└───────▲──────────┘         └───────▲──────────┘
        │                            │
        │ publish                    │ consume
        │                            │
┌───────┴──────────┐         ┌──────┴───────────┐
│   PRODUCER app   │         │   CONSUMER app   │
│   (Symfony)      │         │   (Symfony)      │
│                  │         │                  │
│  app:produce     │         │  messenger:consume│
│  "<text>"        │         │  → var/log/      │
│                  │         │    consumed.log   │
└──────────────────┘         └──────────────────┘
```

**Message flow:**

1. `app:produce "<text>"` dispatches a `FederationMessage` via Symfony Messenger
2. Messenger publishes to `federation.in` exchange on RabbitMQ #1
3. RabbitMQ #2 has a federation link that pulls messages from RabbitMQ #1
4. On RabbitMQ #2, `federation.in` is bound to `consumer.queue`
5. Consumer's `messenger:consume` worker picks up the message and logs it

## Prerequisites

- Docker & Docker Compose
- Make (optional, for convenience commands)

## Quick Start

```bash
# Start RabbitMQ nodes + federation setup
make up

# Produce a message (prompts for text)
make produce

# Consume messages (runs until stopped with Ctrl+C)
make consume

# One-shot end-to-end test
make test
```

## Usage

### Start infrastructure

```bash
make up
```

This starts:
- **rabbit1** — RabbitMQ #1 (upstream) — management UI at http://localhost:15672
- **rabbit2** — RabbitMQ #2 (downstream) — management UI at http://localhost:localhost:15673
- **setup** — one-shot container that configures federation (exchange, queue, upstream, policy)

Both management UIs use credentials `guest` / `guest`.

### Produce messages

```bash
docker compose run --rm producer app:produce "your message text here"
```

Or use the Make target:

```bash
make produce
```

### Consume messages

```bash
docker compose run --rm consumer messenger:consume consumer -vv
```

Or:

```bash
make consume
```

Messages are logged to `var/log/consumed.log` inside the consumer container. View the log:

```bash
make consume-log
```

### End-to-end test

```bash
make test
```

This produces a timestamped message, consumes it, and prints the log output.

### Stop everything

```bash
make down
```

### Full reset (removes volumes)

```bash
make reset
```

## Federation Setup Details

The `rabbitmq/setup/run.sh` script runs inside a container and configures:

1. **Exchanges** — `federation.in` (type: `direct`, durable) on both nodes
2. **Queue** — `consumer.queue` (durable) on RabbitMQ #2, bound to `federation.in`
3. **Upstream** — `rabbit1-upstream` on RabbitMQ #2, pointing to `amqp://guest:guest@rabbit1`
4. **Policy** — `federation-policy` on RabbitMQ #2, matching `^federation\.in$`, applying the upstream

You can verify federation status in the RabbitMQ #2 management UI under the **Admin > Federation** tab, or via:

```bash
curl -s -u guest:guest http://localhost:15673/api/federation-links | python3 -m json.tool
```

The link status should be `running`.

## Kubernetes + ArgoCD Deployment

The project includes Kubernetes manifests for running the federation demo on minikube, managed by ArgoCD in a GitOps workflow.

### Deploy on minikube (Phase 1 — plain manifests)

```bash
# Start minikube
minikube start --cpus=4 --memory=8192
minikube addons enable ingress

# Apply all resources
kubectl apply -k k8s/overlays/minikube

# Verify
kubectl get pods -n distributed-rabbit

# Produce a message
kubectl exec -it deploy/producer -n distributed-rabbit -- php bin/console app:produce "hello k8s"

# Check consumer logs
kubectl logs -f deploy/consumer -n distributed-rabbit
```

### Install ArgoCD (Phase 2 — GitOps)

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Expose ArgoCD UI via Ingress (or use port-forward)
kubectl apply -f k8s/overlays/minikube/argocd-ingress.yaml

# Add argocd.local to /etc/hosts pointing at minikube IP
# minikube ip

# Bootstrap the App of Apps
kubectl apply -f argocd/root-application.yaml

# Retrieve initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

ArgoCD will now auto-sync any changes pushed to the `k8s/` manifests in this repository.

## Key Files

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | All services (rabbit1, rabbit2, setup, producer, consumer) |
| `rabbitmq/setup/run.sh` | Automated federation configuration via HTTP API |
| `rabbitmq/rabbit1/enabled_plugins` | Enables federation plugin on node 1 |
| `rabbitmq/rabbit2/enabled_plugins` | Enables federation plugin on node 2 |
| `k8s/` | Kubernetes manifests (deployments, services, jobs, ingress) |
| `argocd/` | ArgoCD Application manifests for GitOps management |
| `producer/src/Command/ProduceCommand.php` | CLI command `app:produce <text>` |
| `producer/src/Message/FederationMessage.php` | Message DTO |
| `producer/config/packages/messenger.yaml` | AMQP transport to `federation.in` on rabbit1 |
| `consumer/src/MessageHandler/FederationMessageHandler.php` | Handler that logs consumed messages |
| `consumer/src/Message/FederationMessage.php` | Message DTO (must match producer) |
| `consumer/config/packages/messenger.yaml` | AMQP transport from `consumer.queue` on rabbit2 |
| `Makefile` | Convenience commands |

## Troubleshooting

**Federation link not running?**
- Check both RabbitMQ nodes are healthy: `curl -u guest:guest http://localhost:15672/api/aliveness-test/%2f`
- Re-run setup: `docker compose up -d setup`

**Messages stuck on RabbitMQ #1?**
- Check federation link status on the management UI or API
- Ensure the exchange name matches exactly (`federation.in`)
- Verify the policy is applied: `curl -s -u guest:guest http://localhost:15673/api/policies | python3 -m json.tool`

**Deserialization errors on consumer?**
- Both apps must use the same `FederationMessage` class structure (same properties, same types)
- Old non-serialized messages in the queue will cause errors — purge with: `curl -u guest:guest -X DELETE http://localhost:15673/api/queues/%2f/consumer.queue/contents`

**Want to test federation resilience?**
1. Stop rabbit1: `docker compose stop rabbit1`
2. Produce messages (they'll queue locally on rabbit1 when it restarts)
3. Start rabbit1: `docker compose start rabbit1`
4. Federated messages should flow to rabbit2 automatically