#!/bin/bash
# start.sh — build, deploy, and expose the Qwen chatbot on minikube
set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── config (override via env) ─────────────────────────────────────────────────
PORT=${PORT:-8080}
MINIKUBE_MEMORY=${MINIKUBE_MEMORY:-4096}
MINIKUBE_CPUS=${MINIKUBE_CPUS:-4}

# ── 1. prerequisites ──────────────────────────────────────────────────────────
log "Checking prerequisites..."

install_docker() {
    warn "Docker not found. Installing..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    warn "Docker installed. You may need to log out and back in for group changes."
    warn "Re-run this script after re-logging in."
    exit 0
}

install_minikube() {
    warn "minikube not found. Installing..."
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
    log "minikube installed."
}

install_kubectl() {
    warn "kubectl not found. Installing..."
    curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    log "kubectl installed."
}

command -v docker    &>/dev/null || install_docker
command -v minikube  &>/dev/null || install_minikube
command -v kubectl   &>/dev/null || install_kubectl

# ── 2. start minikube ─────────────────────────────────────────────────────────
if minikube status 2>/dev/null | grep -q "Running"; then
    log "Minikube already running."
else
    log "Starting minikube (memory=${MINIKUBE_MEMORY}MB, cpus=${MINIKUBE_CPUS})..."
    minikube start --driver=docker \
        --memory="${MINIKUBE_MEMORY}" \
        --cpus="${MINIKUBE_CPUS}"
fi

# ── 3. build images ───────────────────────────────────────────────────────────
log "Building backend image (first run downloads Qwen — ~3 GB, may take 5-10 min)..."
docker build -t chatbot-backend:latest ./backend

log "Building frontend image..."
docker build -t chatbot-frontend:latest ./frontend

# ── 4. load images into minikube ──────────────────────────────────────────────
log "Loading images into minikube (this copies ~3 GB — be patient)..."
minikube image load chatbot-backend:latest
minikube image load chatbot-frontend:latest

# ── 5. apply manifests ────────────────────────────────────────────────────────
log "Applying Kubernetes manifests..."
kubectl apply -f k8s/

# ── 6. enable metrics-server (required for HPA) ───────────────────────────────
log "Enabling metrics-server..."
minikube addons enable metrics-server

# ── 7. wait for rollout ───────────────────────────────────────────────────────
log "Waiting for frontend to be ready..."
kubectl rollout status deployment/frontend -n chatbot --timeout=120s

log "Waiting for backend to be ready (model loads from baked cache ~30-60 s)..."
kubectl rollout status deployment/backend -n chatbot --timeout=300s

# ── 8. summary ────────────────────────────────────────────────────────────────
echo ""
kubectl get pods    -n chatbot
echo ""
kubectl get svc     -n chatbot
echo ""
kubectl get hpa     -n chatbot
echo ""

# ── 9. port-forward ───────────────────────────────────────────────────────────
# Bind on 0.0.0.0 so EC2 public IP can reach the UI.
# Make sure port 8080 is open in your EC2 security group.
PUBLIC_IP=$(curl -sf http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "localhost")

log "Starting port-forward on 0.0.0.0:${PORT} ..."
echo ""
echo -e "  ${GREEN}Open in browser:${NC}  http://${PUBLIC_IP}:${PORT}"
echo -e "  ${YELLOW}Keep this terminal open.${NC}  Ctrl+C to stop."
echo ""

kubectl port-forward --address 0.0.0.0 -n chatbot svc/frontend "${PORT}":80
