#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Checking prerequisites..."
for cmd in docker vagrant; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: $cmd is not installed."
        exit 1
    fi
done

echo "==> Setting kernel parameter for SonarQube..."
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo sysctl -w vm.max_map_count=262144
fi

echo "==> Building and starting DevSecOps containers..."
docker compose up -d --build

echo "==> Waiting for services to be ready..."
for i in {1..30}; do
    if curl -sf http://localhost:8080/login &>/dev/null; then
        echo "Jenkins is up."
        break
    fi
    echo "  Jenkins not ready yet ($i/30)..."
    sleep 10
done

for i in {1..30}; do
    if curl -sf http://localhost:9000/api/system/status | grep -q '"status":"UP"'; then
        echo "SonarQube is up."
        break
    fi
    echo "  SonarQube not ready yet ($i/30)..."
    sleep 10
done

echo ""
echo "==> Initial Jenkins admin password:"
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo "  (password already set or plugin auto-configured)"

echo ""
echo "==> Services:"
echo "  Jenkins:     http://localhost:8080"
echo "  SonarQube:   http://localhost:9000  (admin/admin)"
echo "  Prometheus:  http://localhost:9090"
echo "  Grafana:     http://localhost:3000  (admin/admin)"
echo "  ZAP:         http://localhost:8090"
echo "  Prod server: http://localhost:8181  (app after deploy)"
echo "  Prod SSH:    ssh deploy@localhost -p 2222  (password: deploy123)"
