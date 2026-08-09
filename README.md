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

> **EC2 instance recommendation:** `t3.large` (2 vCPU, 8 GB RAM) minimum — `t3.xlarge` (4 vCPU, 16 GB) preferred.  
> **Storage:** Set the root EBS volume to **30 GB** at launch (default 8 GB is not enough).  
> Open **port 8080** in your EC2 security group for inbound TCP.

### Launch checklist (AWS Console)

| Setting | Value |
|---|---|
| AMI | Ubuntu 24.04 LTS |
| Instance type | `t3.large` or larger |
| Key pair | your `.pem` file |
| Storage | **30 GB** gp3 |
| Security group | SSH (22) + TCP 8080 from 0.0.0.0/0 |

### One-command deploy

```bash
git clone https://github.com/Raj-pro/test-repo.git
cd test-repo
chmod +x start.sh
./start.sh
```

The script auto-installs Docker, minikube, and kubectl if missing.

> **After Docker installs** the script exits and asks you to re-login.  
> Instead of logging out, run `newgrp docker` in the same shell, then re-run `./start.sh`.

The script will then:
1. Start minikube
2. Build both Docker images (first run downloads Qwen ~1.8 GB — takes 5–10 min)
3. Load images into minikube
4. Apply all Kubernetes manifests
5. Wait for pods to become ready
6. Start `kubectl port-forward` bound to `0.0.0.0:8080`
7. Print the public URL

### Environment overrides

```bash
# On a 2-vCPU instance (t3.large, t3.medium):
MINIKUBE_CPUS=2 ./start.sh

# Custom port or more memory:
PORT=9090 MINIKUBE_MEMORY=8192 MINIKUBE_CPUS=4 ./start.sh
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
