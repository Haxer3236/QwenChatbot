# Qwen Chatbot — Kubernetes Demo

A local chatbot powered by **Qwen2.5-0.5B-Instruct**, running fully offline inside Kubernetes.  
No Hugging Face token required — the model is baked into the Docker image at build time.

---

## Architecture

```
Browser
   │
   ▼  port 8080 (port-forward / NodePort)
┌──────────────────────────────┐
│  frontend  (Deployment)      │  Flask proxy · 128 Mi RAM
│  port 5000                   │
└──────────────┬───────────────┘
               │  ClusterIP  http://backend:5001
               ▼
┌──────────────────────────────┐
│  backend   (Deployment)      │  Qwen2.5-0.5B · bfloat16 · gunicorn
│  port 5001                   │  1.5 Gi RAM request · 2 Gi limit
└──────────────────────────────┘
               │
               ▼
   HPA: 1 → 3 replicas @ CPU > 60 %
```

---

## Kubernetes Concepts

| File | Resource | What it demonstrates |
|---|---|---|
| `00-namespace.yaml` | Namespace | Isolates all resources under `chatbot` |
| `01-backend-deployment.yaml` | Deployment | Pod spec, resource limits, health probes |
| `02-frontend-deployment.yaml` | Deployment | Lightweight proxy; separate from ML workload |
| `03-services.yaml` | Service (ClusterIP + NodePort) | Internal DNS routing + external exposure |
| `04-hpa.yaml` | HorizontalPodAutoscaler | Auto-scales backend pods on CPU load |

---

## Quick Start — EC2

### Prerequisites

| Tool | Min version | Install |
|---|---|---|
| Docker | 24+ | `curl -fsSL https://get.docker.com \| sh` |
| minikube | 1.32+ | see [minikube.sigs.k8s.io](https://minikube.sigs.k8s.io/docs/start/) |
| kubectl | 1.28+ | `sudo snap install kubectl --classic` |

> **EC2 instance recommendation:** `t3.xlarge` (4 vCPU, 16 GB RAM) or larger.  
> Open **port 8080** in your EC2 security group for inbound TCP.

### One-command deploy

```bash
git clone <this-repo>
cd chart-bot-k8s
bash start.sh
```

The script will:
1. Install any missing tools (Docker / minikube / kubectl)
2. Start minikube with 4 CPUs and 4 GB RAM
3. Build both Docker images
4. Load them into minikube
5. Apply all Kubernetes manifests
6. Wait for pods to become ready
7. Start `kubectl port-forward` bound to `0.0.0.0:8080`
8. Print the public URL

> First run downloads the Qwen model (~1.8 GB) at **build time** — subsequent builds use Docker's layer cache.

### Environment overrides

```bash
PORT=9090 MINIKUBE_MEMORY=8192 MINIKUBE_CPUS=4 bash start.sh
```

---

## Manual Step-by-Step

```bash
# 1. Start minikube
minikube start --driver=docker --memory=4096 --cpus=4

# 2. Build images
docker build -t chatbot-backend:latest ./backend
docker build -t chatbot-frontend:latest ./frontend

# 3. Load into minikube
minikube image load chatbot-backend:latest
minikube image load chatbot-frontend:latest

# 4. Deploy
kubectl apply -f k8s/
minikube addons enable metrics-server

# 5. Wait for pods
kubectl rollout status deployment/backend  -n chatbot --timeout=300s
kubectl rollout status deployment/frontend -n chatbot --timeout=60s

# 6. Expose (EC2 — bind all interfaces)
kubectl port-forward --address 0.0.0.0 -n chatbot svc/frontend 8080:80
# Open http://<EC2-public-IP>:8080

# 6b. Local Mac
kubectl port-forward -n chatbot svc/frontend 8080:80 &
# Open http://localhost:8080
```

---

## Verify

```bash
# All pods + HPA
kubectl get pods,hpa -n chatbot

# Backend logs (watch model load on startup)
kubectl logs -n chatbot deployment/backend -f

# Test via curl
curl -s -X POST http://localhost:8080/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "What is Kubernetes?"}' | python3 -m json.tool
```

---

## Simulate HPA Scale-Up

```bash
# Drive CPU up on the backend
kubectl run load --image=busybox --restart=Never -n chatbot -- \
  sh -c 'while true; do wget -qO- http://backend:5001/health; done'

# Watch HPA in real time (separate terminal)
kubectl get hpa backend-hpa -n chatbot -w

# Clean up
kubectl delete pod load -n chatbot
```

---

## Teardown

```bash
kubectl delete namespace chatbot
minikube stop          # pause the VM
# minikube delete      # full removal
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `RemoteDisconnected` on first message | Backend pod not ready yet | Wait 60–90 s after deploy and retry |
| Response cuts off early | `max_new_tokens=64` cap | Increase in `backend/app.py` and rebuild |
| Port 8080 unreachable on EC2 | Security group not open | Add inbound TCP 8080 rule |
| `image load` hangs | Large image over slow link | Be patient — ~3 GB transfer into minikube |
| HPA shows `<unknown>` CPU | metrics-server not ready | Wait 2–3 min after `minikube addons enable metrics-server` |
