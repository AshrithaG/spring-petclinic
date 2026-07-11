#!/usr/bin/env bash
set -euo pipefail

# One command setup for the whole DevSecOps pipeline.
#
# What it does, in order:
#   1. generates the SSH deploy key if it does not exist
#   2. creates the production VM with Multipass and authorizes the key
#   3. starts SonarQube, sets the admin password, creates an analysis
#      token and the Jenkins webhook through the SonarQube API
#   4. writes a .env file with everything the containers need
#   5. starts the full stack with Jenkins preconfigured through
#      Configuration as Code. No setup wizard, no manual clicks.
#      The pipeline job is created automatically and the first build
#      is queued on boot.
#
# Usage:
#   ./bootstrap.sh [repo-url]
#
# For a completely clean rerun:
#   docker compose down -v && multipass delete --purge petclinic-prod

cd "$(dirname "$0")"

REPO_URL="${1:-https://github.com/AshrithaG/spring-petclinic.git}"
VM_NAME="petclinic-prod"
KEY_FILE="vm/jenkins_key"
SONAR_URL="http://localhost:9000"
JENKINS_URL="http://localhost:8081"
ADMIN_PASS="${ADMIN_PASS:-Petclinic!23}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1"; exit 1; }; }
need docker
need multipass
need curl
need python3
need ssh-keygen

echo "[1/5] deploy key"
if [ ! -f "$KEY_FILE" ]; then
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C jenkins-deploy
  echo "  generated $KEY_FILE"
else
  echo "  $KEY_FILE already exists"
fi

echo "[2/5] production VM"
if ! multipass info "$VM_NAME" >/dev/null 2>&1; then
  PUB_KEY=$(cat "$KEY_FILE.pub")
  CLOUD_INIT=$(mktemp)
  cat > "$CLOUD_INIT" <<EOF
users:
  - default
  - name: ubuntu
    ssh_authorized_keys:
      - $PUB_KEY
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
EOF
  multipass launch 22.04 --name "$VM_NAME" --cpus 2 --memory 2G --disk 10G \
    --cloud-init "$CLOUD_INIT"
  rm -f "$CLOUD_INIT"
else
  echo "  VM $VM_NAME already exists"
fi
PROD_HOST=$(multipass info "$VM_NAME" --format json | python3 -c \
  "import sys, json; print(json.load(sys.stdin)['info']['$VM_NAME']['ipv4'][0])")
echo "  VM address: $PROD_HOST"

echo "[3/5] SonarQube"
docker compose up -d sonarqube
echo "  waiting for SonarQube to come up (first boot takes a minute or two)"
until curl -s "$SONAR_URL/api/system/status" | grep -q '"UP"'; do sleep 5; done

# the default admin/admin password must be changed before the API is usable
if curl -s -u admin:admin "$SONAR_URL/api/authentication/validate" | grep -q '"valid":true'; then
  curl -sf -u admin:admin -X POST \
    "$SONAR_URL/api/users/change_password?login=admin&previousPassword=admin&password=$ADMIN_PASS" > /dev/null
  echo "  admin password set"
fi

TOKEN_NAME="jenkins-$(date +%s)"
SONAR_TOKEN=$(curl -sf -u "admin:$ADMIN_PASS" -X POST \
  "$SONAR_URL/api/user_tokens/generate?name=$TOKEN_NAME&type=GLOBAL_ANALYSIS_TOKEN" \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])")
echo "  analysis token created"

if ! curl -sf -u "admin:$ADMIN_PASS" "$SONAR_URL/api/webhooks/list" | grep -q sonarqube-webhook; then
  curl -sf -u "admin:$ADMIN_PASS" -X POST \
    "$SONAR_URL/api/webhooks/create?name=jenkins&url=http://jenkins:8080/sonarqube-webhook/" > /dev/null
  echo "  webhook created"
fi

echo "[4/5] environment file"
cat > .env <<EOF
JENKINS_ADMIN_ID=admin
JENKINS_ADMIN_PASSWORD=$ADMIN_PASS
SONAR_TOKEN=$SONAR_TOKEN
PROD_HOST=$PROD_HOST
REPO_URL=$REPO_URL
EOF
echo "  wrote .env"

echo "[5/5] full stack"
docker compose -f docker-compose.yml -f docker-compose.auto.yml up -d --build
echo "  waiting for Jenkins"
until curl -sf -o /dev/null "$JENKINS_URL/login"; do sleep 5; done

echo
echo "Done. The pipeline job was created and the first build is already queued."
echo
echo "  Jenkins     $JENKINS_URL      admin / $ADMIN_PASS"
echo "  SonarQube   $SONAR_URL        admin / $ADMIN_PASS"
echo "  Grafana     http://localhost:3000   admin / admin"
echo "  Prometheus  http://localhost:9090"
echo "  App (after first build)  http://$PROD_HOST:8080"
echo
echo "Watch the build: $JENKINS_URL/job/spring-petclinic/"
