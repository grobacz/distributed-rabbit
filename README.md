# Distributed Rabbit — Federation Demo

A demo project showing RabbitMQ federation between two nodes, with a Symfony producer app publishing messages to the upstream node and a Symfony consumer app receiving them from the downstream node after federation. Includes a **bidirectional response flow** where the consumer sends confirmation messages back to the producer.

## Architecture

### Unidirectional Request Flow (Phase 3 — Operators)

```
┌──────────────────┐         ┌──────────────────┐
│   RabbitMQ #1    │         │   RabbitMQ #2    │
│   (upstream)     │         │   (downstream)   │
│                  │         │                  │
│  exchange:       │  fed    │  exchange:       │
│    federation.in │◄────────│  federation.in   │
│                  │         │       │ bind     │
│                  │         │       ▼          │
│                  │         │  queue:          │
│                  │         │    consumer.queue│
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

### Bidirectional Response Flow

```
         REQUEST (rabbit1 → rabbit2)                RESPONSE (rabbit2 → rabbit1)

┌──────────────────┐         ┌──────────────────┐         ┌──────────────────┐
│   RabbitMQ #1    │         │   RabbitMQ #2    │         │   RabbitMQ #1    │
│   (upstream)     │         │   (downstream)   │         │   (downstream)   │
│                  │         │                  │         │                  │
│  exchange:       │  fed    │  exchange:       │         │  exchange:       │
│    federation.in │◄────────│  federation.in   │         │    federation.out│
│                  │         │       │ bind     │         │        │ bind    │
│                  │         │       ▼          │         │        ▼         │
│                  │         │  queue:          │         │  queue:          │
│                  │         │    consumer.queue│         │    response.queue│
│                  │         │                  │         │                  │
│  exchange:       │         │  exchange:       │  fed    │                  │
│    federation.out│◄────────│  federation.out  │◄────────│                  │
│       │ bind     │         │                  │         │                  │
│       ▼          │         │                  │         │                  │
│  queue:          │         │                  │         │                  │
│    response.queue│         │                  │         │                  │
└───────▲──────────┘         └───────▲──────────┘         └──────────────────┘
        │                            │                            │
        │ publish                    │ consume + confirm          │ consume
        │                            │                            │
┌───────┴──────────┐         ┌──────┴───────────┐         ┌──────┴───────────┐
│   PRODUCER app   │         │   CONSUMER app   │         │   PRODUCER app   │
│   (Symfony)      │         │   (Symfony)      │         │   confirmation   │
│                  │         │                  │         │   sidecar        │
│  app:produce     │         │  messenger:consume      │  messenger:consume│
│  "<text>"        │         │  consumer               │  confirmation    │
│                  │         │  → var/log/consumed.log │  → var/log/      │
│                  │         │  → dispatch             │    confirmed.log  │
│                  │         │    ConfirmationMessage  │                  │
└──────────────────┘         └──────────────────┘         └──────────────────┘
```

**Request message flow:**

1. `app:produce "<text>"` dispatches a `FederationMessage` via Symfony Messenger
2. Messenger publishes to `federation.in` exchange on RabbitMQ #1
3. RabbitMQ #2 has a federation link that pulls messages from RabbitMQ #1
4. On RabbitMQ #2, `federation.in` is bound to `consumer.queue`
5. Consumer's `messenger:consume consumer` worker picks up the message, logs it, and dispatches a `ConfirmationMessage`

**Response message flow:**

6. `ConfirmationMessage` is published to `federation.out` exchange on RabbitMQ #2
7. RabbitMQ #1 has a federation link that pulls messages from RabbitMQ #2
8. On RabbitMQ #1, `federation.out` is bound to `response.queue`
9. Producer's `messenger:consume confirmation` sidecar worker picks up the confirmation and logs it

## Prerequisites

- Docker & Docker Compose (for local development)
- minikube + kubectl (for Kubernetes)
- Make (optional, for convenience commands)

## Quick Start (Docker Compose)

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

## Usage (Docker Compose)

### Start infrastructure

```bash
make up
```

This starts:
- **rabbit1** — RabbitMQ #1 (upstream) — management UI at http://localhost:15672
- **rabbit2** — RabbitMQ #2 (downstream) — management UI at http://localhost:15673
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

## Kubernetes + ArgoCD Deployment

The project includes Kubernetes manifests for running the federation demo on minikube, managed by ArgoCD in a GitOps workflow. The RabbitMQ infrastructure is managed by the **RabbitMQ Cluster Operator** and **RabbitMQ Messaging Topology Operator**.

### Architecture on Kubernetes

| Layer | Technology |
|-------|-----------|
| RabbitMQ clusters | RabbitMQ Cluster Operator (`RabbitmqCluster` CRD) |
| Exchanges, queues, bindings, upstreams, policies | RabbitMQ Messaging Topology Operator (`Exchange`, `Queue`, `Binding`, `Federation`, `Policy` CRDs) |
| Git reconciliation | ArgoCD with sync waves |
| App orchestration | Kustomize overlays |

### ArgoCD Sync Waves

| Wave | Resources |
|------|-----------|
| 0 | `RabbitmqCluster` (rabbit1, rabbit2) |
| 1 | `Secret` (rabbit1-amqp-uri, rabbit2-amqp-uri) |
| 2 | `Exchange`, `Queue` |
| 3 | `Binding` |
| 4 | `Federation`, `Policy` |
| 5 | Producer / Consumer Deployments |

### Deploy on minikube

```bash
# Start minikube
minikube start --cpus=4 --memory=8192
minikube addons enable ingress

# Install operators
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/download/v2.20.1/cluster-operator.yml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl apply -f https://github.com/rabbitmq/messaging-topology-operator/releases/latest/download/messaging-topology-operator.yaml

# Apply all resources
kubectl apply -k k8s/overlays/minikube

# Verify
kubectl get pods -n distributed-rabbit
kubectl get rabbitmqcluster -n distributed-rabbit
```

### Verify bidirectional flow

```bash
# Produce a message
kubectl exec -it deploy/producer -n distributed-rabbit -c producer -- php bin/console app:produce "hello k8s"

# Check consumer logs
kubectl logs -f deploy/consumer -n distributed-rabbit

# Check confirmation logs
kubectl exec -it deploy/producer -n distributed-rabbit -c confirmation-consumer -- cat /app/var/log/confirmed.log
```

### Install ArgoCD (GitOps)

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Expose ArgoCD UI via Ingress (or use port-forward)
kubectl apply -f k8s/overlays/minikube/argocd-ingress.yaml

# Bootstrap the App of Apps
kubectl apply -f argocd/root-application.yaml

# Retrieve initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

ArgoCD will now auto-sync any changes pushed to the `k8s/` manifests in this repository.

## Federation Setup Details

### Docker Compose

The `rabbitmq/setup/run.sh` script runs inside a container and configures:

1. **Exchanges** — `federation.in` (type: `direct`, durable) on both nodes
2. **Queue** — `consumer.queue` (durable) on RabbitMQ #2, bound to `federation.in`
3. **Upstream** — `rabbit1-upstream` on RabbitMQ #2, pointing to `amqp://guest:guest@rabbit1`
4. **Policy** — `federation-policy` on RabbitMQ #2, matching `^federation\.in$`, applying the upstream

### Kubernetes (Operators)

The topology is declared as CRDs and reconciled by the Messaging Topology Operator:

- **Exchange** CRDs — `federation.in` on both clusters, `federation.out` on both clusters
- **Queue** CRDs — `consumer.queue` on rabbit2, `response.queue` on rabbit1
- **Binding** CRDs — exchange-to-queue bindings
- **Federation** CRDs — upstream definitions referencing URI secrets
- **Policy** CRDs — pattern matching for federation

You can verify federation status via:

```bash
# On rabbit1 (response flow)
kubectl exec rabbit1-server-0 -n distributed-rabbit -- rabbitmqctl eval 'rabbit_federation_status:status().'

# On rabbit2 (request flow)
kubectl exec rabbit2-server-0 -n distributed-rabbit -- rabbitmqctl eval 'rabbit_federation_status:status().'
```

The link status should be `running`.

## Key Files

### Infrastructure

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | All services (rabbit1, rabbit2, setup, producer, consumer) |
| `rabbitmq/setup/run.sh` | Automated federation configuration via HTTP API (Docker Compose only) |
| `rabbitmq/rabbit1/enabled_plugins` | Enables federation plugin on node 1 |
| `rabbitmq/rabbit2/enabled_plugins` | Enables federation plugin on node 2 |
| `k8s/base/` | Base K8s manifests (producer/consumer deployments, configmaps) |
| `k8s/overlays/minikube/rabbitmq/` | Operator CRDs (clusters, topology) |
| `k8s/overlays/minikube/ingress.yaml` | Ingress for management UIs |
| `argocd/` | ArgoCD Application manifests for GitOps management |
| `Makefile` | Convenience commands |

### Producer App

| Path | Purpose |
|------|---------|
| `producer/src/Command/ProduceCommand.php` | CLI command `app:produce <text>` |
| `producer/src/Message/FederationMessage.php` | Request message DTO |
| `producer/src/Message/ConfirmationMessage.php` | Confirmation message DTO |
| `producer/src/MessageHandler/ConfirmationMessageHandler.php` | Logs confirmation messages |
| `producer/config/packages/messenger.yaml` | AMQP transports (federation publish, confirmation consume) |

### Consumer App

| Path | Purpose |
|------|---------|
| `consumer/src/MessageHandler/FederationMessageHandler.php` | Handles messages, logs them, dispatches confirmation |
| `consumer/src/Message/FederationMessage.php` | Message DTO (must match producer) |
| `consumer/src/Message/ConfirmationMessage.php` | Confirmation DTO (must match producer) |
| `consumer/config/packages/messenger.yaml` | AMQP transports (consumer consume, response publish) |

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

**Confirmation messages not arriving?**
- Check both federation links are running (rabbit1-upstream and rabbit2-upstream)
- Verify the `response.queue` exists on rabbit1 and is bound to `federation.out`
- Check the producer sidecar is running: `kubectl logs -f deploy/producer -n distributed-rabbit -c confirmation-consumer`

**Want to test federation resilience?**
1. Stop rabbit1: `docker compose stop rabbit1` (or `kubectl delete pod rabbit1-server-0 -n distributed-rabbit`)
2. Produce messages (they'll queue locally on rabbit1 when it restarts)
3. Start rabbit1: `docker compose start rabbit1` (or wait for the operator to recreate the pod)
4. Federated messages should flow to rabbit2 automatically
