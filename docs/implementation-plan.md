# Distributed Rabbit — Minikube + ArgoCD + Federation Implementation Plan

> Target: convert the `docker-compose`-based federation demo into a Kubernetes-native,
> GitOps-managed deployment running on minikube.

---

## Phase 1 — Minikube: Containerise and run on K8s

**Goal:** Every service from `docker-compose.yml` runs inside minikube via plain K8s
manifests (`Deployment`, `Service`, `ConfigMap`, `Secret`). No operators yet — just raw
RabbitMQ containers with the federation plugin enabled, same as the current Docker setup.

### 1.1 Prerequisites & tooling

- [ ] Start minikube cluster (`minikube start --cpus=4 --memory=8192`)
- [ ] Enable `ingress` addon (`minikube addons enable ingress`)

### 1.2 Directory structure

```
k8s/
  ├─ base/
  │   ├─ namespace.yaml
  │   ├─ rabbit1-deployment.yaml
  │   ├─ rabbit1-service.yaml
  │   ├─ rabbit2-deployment.yaml
  │   ├─ rabbit2-service.yaml
  │   ├─ producer-configmap.yaml
  │   ├─ producer-deployment.yaml
  │   ├─ consumer-configmap.yaml
  │   ├─ consumer-deployment.yaml
  │   ├─ setup-job.yaml          (one-shot Job replacing setup container)
  │   └─ kustomization.yaml
  └─ overlays/
      └─ minikube/
          ├─ kustomization.yaml
          └─ ingress.yaml
```

### 1.3 RabbitMQ nodes (`rabbit1`, `rabbit2`)

- [ ] **Deployment** per node, running `rabbitmq:3-management` image.
  - `RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS=-rabbitmq_management path_prefix "/rabbit1"` (or `/rabbit2`)
    so both management UIs work behind a single Ingress.
  - Mount `enabled_plugins` via ConfigMap (content: `[rabbitmq_management, rabbitmq_federation,
    rabbitmq_federation_management]` → `/etc/rabbitmq/enabled_plugins`).
  - Resource requests/limits: 256Mi–512Mi mem, 200m–500m CPU.
  - Probes: `httpGet` on management port (`/api/aliveness-test/%2f`).

- [ ] **Service** per node (ClusterIP):
  - `rabbit1`: AMQP `5672`, management `15672`.
  - `rabbit2`: AMQP `5672`, management `15672`.
    (No port collision needed — they are separate Services.)

### 1.4 Setup Job (replaces `rabbitmq/setup` container)

- [ ] **Job** `rabbit-setup`, one-shot, uses `curlimages/curl`.
  - Waits for both nodes alive (`/api/aliveness-test/%2f`).
  - Creates `federation.in` exchange on `rabbit1` **and** `rabbit2`.
  - Creates `consumer.queue` on `rabbit2`, binds to `federation.in`.
  - Creates `rabbit1-upstream` on `rabbit2` pointing to `amqp://guest:guest@rabbit1`.
  - Applies `federation-policy` on `rabbit2` for pattern `^federation\.in$`.
  - ConfigMap or Secret for RabbitMQ admin credentials.

### 1.5 Producer

- [ ] **Deployment** built from `./producer/Dockerfile`.
  - Build strategy: either `docker build` → push to local minikube registry or `minikube image build`.
  - Env: `MESSENGER_TRANSPORT_DSN=amqp://guest:guest@rabbit1:5672/%2f` via ConfigMap/Secret.
  - Resource requests/limits: 128Mi–256Mi mem, 100m–200m CPU.
  - Runs `php bin/console messenger:consume` as a long-lived worker *or* kept as a CLI-only
    pod (triggered manually). For a demo, keeping the CLI approach (`kubectl exec`) is fine;
    for production add a CronJob or Deployment with a loop.

### 1.6 Consumer

- [ ] **Deployment** built from `./consumer/Dockerfile`.
  - Env: `MESSENGER_TRANSPORT_DSN=amqp://guest:guest@rabbit2:5672/%2f`.
  - Command: `php bin/console messenger:consume consumer -vv`.
  - Persistent volume for `/app/var/log` (writes `consumed.log`).
  - Resource requests/limits: 128Mi–256Mi mem, 100m–200m CPU.

### 1.7 Smoke test

- [ ] `kubectl apply -k k8s/overlays/minikube`
- [ ] Verify all pods are `Running` / `Completed`.
- [ ] `kubectl exec -it deploy/producer -- php bin/console app:produce "hello k8s"`
- [ ] Check consumer logs for the consumed message → confirms full flow works.

---

## Phase 2 — ArgoCD: Install and GitOps-ify

**Goal:** ArgoCD runs on minikube and reconciles the `k8s/` manifests from this Git
repository. A manual `kubectl apply` is replaced by an `Application` CR that points at
the repo.

### 2.1 Install ArgoCD on minikube

- [x] `kubectl create namespace argocd`
- [x] `kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`
- [x] Wait for all pods ready.
- [x] Expose ArgoCD UI via `kubectl port-forward` or an Ingress:
  ```yaml
  # k8s/overlays/minikube/argocd-ingress.yaml
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  ...
  ```
- [x] Retrieve initial admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

### 2.2 ArgoCD Application manifest

- [x] Create `argocd/` directory in the repo:
  ```
  argocd/
    ├─ apps/
    │   └─ distributed-rabbit.yaml
    └─ kustomization.yaml
  ```
- [x] **Application** resource:
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: distributed-rabbit
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: https://github.com/grobacz/distributed-rabbit.git
      targetRevision: main
      path: k8s/overlays/minikube
    destination:
      server: https://kubernetes.default.svc
      namespace: distributed-rabbit
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```
  (The exact `path` depends on whether Phase 1 or Phase 3 manifests are used.)

### 2.3 "App of Apps" pattern (optional but recommended)

- [x] Root `Application` in `argocd/` that points at `argocd/apps/` directory.
  This way adding a new app is just dropping a YAML file — ArgoCD picks it up.

### 2.4 Commit, push, verify

- [x] Commit all K8s + ArgoCD manifests.
- [x] `kubectl apply -f argocd/root-application.yaml` (bootstrap App of Apps).
- [x] UI shows all resources green, synced.
- [x] Prove GitOps loop: change a label in Git, push, ArgoCD auto-syncs.

---

## Phase 3 — RabbitMQ Federation via GitOps (Operators)

**Goal:** Replace raw RabbitMQ containers and the `setup` Job with:
- **RabbitMQ Cluster Operator** — manages RabbitMQ clusters as `RabbitmqCluster` CRDs.
- **RabbitMQ Messaging Topology Operator** — manages exchanges, queues, bindings,
  federation upstreams, and policies as CRDs (per `docs/federation-gitops-plan.md`).
- Application Deployments (producer/consumer) stay the same; only RabbitMQ infra changes.

### 3.1 Install operators

- [ ] **RabbitMQ Cluster Operator** (helm chart or static manifest):
  ```bash
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm install rmq-cluster-operator bitnami/rabbitmq-cluster-operator -n rabbitmq-system --create-namespace
  ```
  Alternatively: apply the upstream manifest from
  `https://github.com/rabbitmq/cluster-operator/releases/`.

- [ ] **RabbitMQ Messaging Topology Operator**:
  ```bash
  kubectl apply -f https://github.com/rabbitmq/messaging-topology-operator/releases/latest/download/messaging-topology-operator.yaml
  ```

### 3.2 Directory structure for Phase 3 manifests

```
k8s/
  ├─ base/                              (app Deployments — kept from Phase 1)
  │   ├─ namespace.yaml
  │   ├─ producer-configmap.yaml
  │   ├─ producer-deployment.yaml
  │   ├─ consumer-configmap.yaml
  │   ├─ consumer-deployment.yaml
  │   └─ kustomization.yaml
  └─ overlays/
      └─ minikube/
          ├─ kustomization.yaml
          ├─ ingress.yaml
          └─ rabbitmq/
              ├─ cluster-rabbit1.yaml          # RabbitmqCluster CRD
              ├─ cluster-rabbit2.yaml          # RabbitmqCluster CRD
              ├─ exchange-federation-in.yaml   # Exchange CRD × 2
              ├─ queue-consumer.yaml           # Queue CRD
              ├─ binding-consumer.yaml         # Binding CRD
              ├─ federation-upstream.yaml      # Federation CRD
              ├─ federation-policy.yaml        # Policy CRD
              └─ rabbitmq-secret.yaml          # guest credentials Secret
```

### 3.3 RabbitmqCluster CRDs

- [ ] **`cluster-rabbit1.yaml`**:
  ```yaml
  apiVersion: rabbitmq.com/v1beta1
  kind: RabbitmqCluster
  metadata:
    name: rabbit1
  spec:
    replicas: 1
    resources:
      requests: { cpu: "200m", memory: "512Mi" }
      limits: { cpu: "500m", memory: "1Gi" }
    additionalPlugins:
      - rabbitmq_management
      - rabbitmq_federation
      - rabbitmq_federation_management
  ```
- [ ] **`cluster-rabbit2.yaml`** — identical but `name: rabbit2`.

> Note: The operator auto-creates Services (`rabbit1`, `rabbit1-nodes`) and a default
> `guest` user Secret. The cluster status exposes the default user Secret name.

### 3.4 Topology CRDs — mapping the demo

Per the table in `docs/federation-gitops-plan.md` (lines 224–236):

| Demo Concept | CRD | Spec |
|---|---|---|
| `federation.in` exchange ← rabbit1 | `Exchange` | name: `federation.in`, type: `direct`, durable, cluster: `rabbit1` |
| `federation.in` exchange ← rabbit2 | `Exchange` | name: `federation.in`, type: `direct`, durable, cluster: `rabbit2` |
| `consumer.queue` ← rabbit2 | `Queue` | name: `consumer.queue`, durable, cluster: `rabbit2` |
| queue ↔ exchange bind | `Binding` | source: `federation.in`, destination: `consumer.queue`, cluster: `rabbit2` |
| upstream to rabbit1 | `Federation` | name: `rabbit1-upstream`, uriSecret pointing to rabbit1 creds, cluster: `rabbit2` |
| federation policy | `Policy` | pattern: `^federation\.in$`, applyTo: `exchanges`, `federation-upstream: rabbit1-upstream`, cluster: `rabbit2` |

- [ ] **Exchange** — 2 resources (one per cluster, identical spec).
- [ ] **Queue** — 1 resource on `rabbit2`.
- [ ] **Binding** — 1 resource on `rabbit2`.
- [ ] **Federation** — needs a URI Secret:
  ```yaml
  apiVersion: v1
  kind: Secret
  metadata:
    name: rabbit1-amqp-uri
  stringData:
    uri: "amqp://guest:guest@rabbit1.distributed-rabbit.svc:5672/%2f"
  ```
- [ ] **Policy** — applies federation to matching exchanges on `rabbit2`.

### 3.5 ArgoCD sync wave ordering

Apply `argocd.argoproj.io/sync-wave` annotations as defined in the spec (lines 209–220):

| Wave | Resources |
|------|-----------|
| **0** | `RabbitmqCluster` (rabbit1, rabbit2) |
| **1** | Secrets (rabbit credentials) |
| **2** | `Exchange` CRDs |
| **2** | `Queue` CRDs |
| **3** | `Binding` CRDs |
| **4** | `Federation` (upstreams) |
| **4** | `Policy` (federation policies) |

Application Deployments (producer/consumer) can sync at wave **5** — they need
RabbitMQ and the topology to be ready first.

### 3.6 Update ArgoCD Application

- [ ] Change `source.path` in the Application to point at the Phase 3 overlay path.
- [ ] Or create a separate Application for the rabbitmq topology resources:
  ```
  argocd/apps/
    ├─ distributed-rabbit-apps.yaml      (producer + consumer Deployments)
    └─ distributed-rabbit-infra.yaml     (RabbitmqClusters + topology CRDs)
  ```

### 3.7 Verify

- [ ] All ArgoCD-managed resources show `Synced` and `Healthy`.
- [ ] `kubectl exec -it deploy/producer -- php bin/console app:produce "operator test"`
- [ ] Consumer log shows the message → federation works through operator-managed topology.
- [ ] Check RabbitMQ management UI: exchanges, queues, upstreams, policies all present.

---

## Summary of Files to Create

```
distributed-rabbit/
├── k8s/
│   ├── base/
│   │   ├── namespace.yaml
│   │   ├── producer-configmap.yaml
│   │   ├── producer-deployment.yaml
│   │   ├── consumer-configmap.yaml
│   │   ├── consumer-deployment.yaml
│   │   └── kustomization.yaml
│   └── overlays/
│       └── minikube/
│           ├── kustomization.yaml
│           ├── ingress.yaml
│           ├── rabbitmq/
│           │   ├── cluster-rabbit1.yaml
│           │   ├── cluster-rabbit2.yaml
│           │   ├── exchange-federation-in.yaml
│           │   ├── queue-consumer.yaml
│           │   ├── binding-consumer.yaml
│           │   ├── federation-upstream.yaml
│           │   ├── federation-policy.yaml
│           │   └── rabbitmq-secret.yaml
│           └── argocd-resources/
│               └── (ingress, etc.)
├── argocd/
│   ├── apps/
│   │   ├── distributed-rabbit-infra.yaml
│   │   └── distributed-rabbit-apps.yaml
│   └── kustomization.yaml  (optional root app)
└── docs/
    └── implementation-plan.md  (this file)
```

---

## Execution Order (Recommended)

1. **Phase 1 first** — get everything running on minikube with plain manifests.
   Validate the federation flow works end-to-end.
2. **Phase 2 next** — install ArgoCD and point it at the Phase 1 manifests. Validate
   GitOps reconciliation (change → push → sync).
3. **Phase 3 last** — swap raw RabbitMQ for operators. This is an infra refactor; the
   app Deployments and the observable behaviour (produce → federate → consume) must
   not change.
