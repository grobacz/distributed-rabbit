# RabbitMQ Federation — GitOps/Production Plan

> Source: ChatGPT discussion (share/69fcdd1a-3550-838f-9b07-b2a48dd917de)  
> Context: Mapping the current `docker-compose` federation demo to a production Kubernetes / GitOps workflow.

---

## High-Level Approach

Manage RabbitMQ federation as **Kubernetes topology resources**, reconciled by **ArgoCD**.

**Key components:**

| Layer | Tool |
|-------|------|
| RabbitMQ clusters | RabbitMQ Cluster Operator |
| Exchanges, queues, bindings, policies, federation upstreams | RabbitMQ Messaging Topology Operator |
| Git reconciliation | ArgoCD |

**Data flow:**

```
Infra repo (CRDs)
      │
      ▼
  ArgoCD
      │
      ▼
RabbitMQ Messaging Topology Operator
      │
      ▼
RabbitMQ Management API
      │
      ▼
RabbitMQ federation plugin / topology
```

> Federation is configured on the **downstream** RabbitMQ, pointing to an **upstream** RabbitMQ. Federation links connect to upstreams similarly to an application connection and can target a vhost, use TLS, and use authentication.

---

## Repo Layout

```
infra repo
  └─ rabbitmq/
      ├─ base/
      │   ├─ topology-operator/
      │   ├─ common-vhosts/
      │   └─ common-users/
      ├─ overlays/
      │   └─ prod-eu/
      │       ├─ rabbit-a/
      │       │   ├─ exchanges/
      │       │   ├─ queues/
      │       │   ├─ bindings/
      │       │   └─ federation/
      │       └─ rabbit-b/
      │           ├─ exchanges/
      │           ├─ queues/
      │           ├─ bindings/
      │           └─ federation/
      ├─ cluster-a/
      │   ├─ exchanges.yaml
      │   ├─ queues.yaml
      │   ├─ bindings.yaml
      │   ├─ federation-upstreams.yaml
      │   └─ federation-policies.yaml
      └─ cluster-b/
          ├─ exchanges.yaml
          ├─ queues.yaml
          ├─ bindings.yaml
          ├─ federation-upstreams.yaml
          └─ federation-policies.yaml
```

Use **Kustomize** or **Helm** to generate repeated mappings. Keep secrets (upstream AMQP URIs) in External Secrets, Sealed Secrets, SOPS, or Vault.

---

## CRD Examples

### Exchange

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: Exchange
metadata:
  name: orders-events
spec:
  name: orders.events
  type: topic
  durable: true
  rabbitmqClusterReference:
    name: rabbit-a
```

### Queue

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: Queue
metadata:
  name: orders-local
spec:
  name: orders.local
  durable: true
  rabbitmqClusterReference:
    name: rabbit-a
```

### Binding

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: Binding
metadata:
  name: orders-events-to-local
spec:
  source: orders.events
  destination: orders.local
  destinationType: queue
  routingKey: "orders.#"
  rabbitmqClusterReference:
    name: rabbit-a
```

### Federation Upstream

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: Federation
metadata:
  name: rabbit-b-upstream
spec:
  name: rabbit-b-upstream
  uriSecret:
    name: rabbit-b-amqp-uri
  rabbitmqClusterReference:
    name: rabbit-a
```

### Federation Policy

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: Policy
metadata:
  name: federate-orders-events
spec:
  name: federate-orders-events
  pattern: "^orders\\.events$"
  applyTo: exchanges
  priority: 10
  definition:
    federation-upstream: rabbit-b-upstream
  rabbitmqClusterReference:
    name: rabbit-a
```

---

## Cross-Cluster Exchange Routing Model

```
cluster-a receives/consumes:
  Exchange: orders.events
  Federation upstream: cluster-b
  Policy: federate selected exchanges from cluster-b

cluster-b receives/consumes:
  Exchange: billing.events
  Federation upstream: cluster-a
  Policy: federate selected exchanges from cluster-a
```

---

## Symfony Messenger Configuration

Keep the app simple — Symfony publishes to its local RabbitMQ exchange. Federation handles cross-cluster movement transparently.

```yaml
framework:
  messenger:
    transports:
      orders:
        dsn: '%env(MESSENGER_TRANSPORT_DSN)%'
        options:
          exchange:
            name: orders.events
            type: topic
```

---

## Ownership Split

| App Teams Own | Platform/IaC Owns |
|---------------|-------------------|
| Exchange name | RabbitMQ clusters |
| Queue name | Federation upstreams |
| Binding keys | Policies |
| Message contract | Secrets |
| | Cross-region routing rules |

---

## ArgoCD Sync Waves

Ordering is critical for predictable reconciliation:

| Wave | Resources |
|------|-----------|
| 0 | RabbitMQCluster |
| 1 | Users / Permissions / Vhosts |
| 2 | Exchanges / Queues |
| 3 | Bindings |
| 4 | Federation Upstreams / Policies |

---

## Mapping to Current Demo

| Demo Concept | GitOps Equivalent |
|--------------|-------------------|
| `rabbitmq/setup/run.sh` (HTTP API) | RabbitMQ Messaging Topology Operator CRDs |
| `docker-compose.yml` services | RabbitMQCluster CRDs + Deployments |
| `enabled_plugins` volume mount | RabbitMQCluster `additionalPlugins` field |
| Manual `make up` | ArgoCD sync |
| `federation.in` exchange | `Exchange` CRD |
| `consumer.queue` | `Queue` CRD |
| `rabbit1-upstream` | `Federation` CRD |
| `federation-policy` | `Policy` CRD |
| `guest:guest` credentials | `Secret` + External Secrets |
| Producer/consumer Symfony apps | Standard K8s Deployments with `MESSENGER_TRANSPORT_DSN` env var |
