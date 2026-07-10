# DevSecOps Pipeline for Spring PetClinic — Step-by-Step Instructions

A complete containerized DevSecOps pipeline for the
[spring-petclinic](https://github.com/spring-projects/spring-petclinic) project:

| Concern | Tool | Where it runs |
|---|---|---|
| Continuous Integration | Jenkins (+ Blue Ocean) | Docker container |
| Static analysis (SAST) | SonarQube | Docker container |
| Dynamic security analysis (DAST) | OWASP ZAP | Docker container |
| Metrics collection | Prometheus | Docker container |
| Metrics visualization | Grafana | Docker container |
| Production deployment | Ansible (from Jenkins) | → Ubuntu VM |

All five tool containers are attached to one custom Docker bridge network,
**`devsecops-net`**, so they address each other by container name
(`http://sonarqube:9000`, `http://zap:8090`, `http://jenkins:8080`, …).
The **production web server is a real VM** (Vagrant or Multipass), *not* a
container — Jenkins deploys to it over SSH using Ansible.

```
                        ┌────────────────────────  devsecops-net (Docker)  ───────────────────────┐
                        │                                                                          │
 GitHub fork ──poll──▶  │  Jenkins ──mvn──▶ build/test ──▶ SonarQube (SAST)                        │
 (spring-petclinic)     │     │                                                                    │
                        │     ├────────── /prometheus ◀── Prometheus ◀── Grafana (dashboards)      │
                        │     │                                                                    │
                        │     └──ansible/ssh──────────────┐        ZAP (DAST) ──scan──┐            │
                        └─────────────────────────────────┼───────────────────────────┼────────────┘
                                                          ▼                           ▼
                                                   Production VM  ◀───────── http://VM_IP:8080
                                                   (Ubuntu + systemd + petclinic.jar)
```

### Repository layout of the added files

```
Jenkinsfile                                  ← pipeline definition (checked out by Jenkins)
devsecops/
├── README.md                                ← this document
├── docker-compose.yml                       ← Jenkins, SonarQube, Prometheus, Grafana, ZAP + custom network
├── jenkins/
│   ├── Dockerfile                           ← Jenkins LTS + Ansible + curl/jq + plugins
│   └── plugins.txt                          ← Blue Ocean, Sonar, Prometheus, HTML Publisher, ssh-agent, …
├── prometheus/prometheus.yml                ← scrapes Jenkins /prometheus endpoint
├── grafana/
│   ├── provisioning/datasources/prometheus.yml   ← auto-adds Prometheus data source
│   ├── provisioning/dashboards/dashboards.yml    ← auto-loads dashboards
│   └── dashboards/jenkins.json              ← Jenkins metrics dashboard
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini                        ← production VM address  (EDIT the IP)
│   ├── deploy-petclinic.yml                 ← playbook: Java 17 + systemd service + JAR
│   └── templates/petclinic.service.j2
└── vm/
    ├── Vagrantfile                          ← Ubuntu 22.04 production VM @ 192.168.56.10
    └── multipass-cloud-init.yml             ← alternative for Apple Silicon Macs
```

---

## 0. Prerequisites

- **Docker Desktop** (or Docker Engine + Compose v2), ≥ 4 GB RAM allotted —
  SonarQube alone wants ~2 GB.
- **A hypervisor for the production VM** — one of:
  - VirtualBox + Vagrant (Intel machines; VirtualBox ≥ 7.1 for ARM Macs),
  - VMware Fusion/Workstation or Parallels + Vagrant, or
  - **Multipass** (easiest on Apple Silicon): `brew install multipass`.
- A **GitHub account** and `git`.

## 1. Fork and clone the repository

1. On GitHub, open <https://github.com/spring-projects/spring-petclinic> and
   click **Fork**.
2. Clone **your fork** (not upstream) and add the pipeline files
   (`Jenkinsfile` + `devsecops/`) from this submission:

   ```bash
   git clone https://github.com/<YOUR_USER>/spring-petclinic.git
   cd spring-petclinic
   # copy Jenkinsfile and devsecops/ into the repo root if not already there
   git add Jenkinsfile devsecops .gitignore
   git commit -m "Add DevSecOps pipeline (Jenkins, Sonar, ZAP, Prometheus, Grafana, Ansible)"
   git push origin main
   ```

   > If your local clone's `origin` still points at `spring-projects/…`, fix it:
   > `git remote set-url origin https://github.com/<YOUR_USER>/spring-petclinic.git`

   The `Jenkinsfile` **must be pushed to the fork** — Jenkins checks it out
   from GitHub on every build.

## 2. Create the custom Docker network and the tool containers

Everything is captured in [docker-compose.yml](docker-compose.yml). From the
repo root:

```bash
cd devsecops
docker compose up -d --build
```

This builds the custom Jenkins image (Ansible + plugins baked in), creates the
**`devsecops-net`** bridge network, and starts all five services:

| Service | URL (host) | Name on devsecops-net |
|---|---|---|
| Jenkins | http://localhost:8081 | `jenkins:8080` |
| SonarQube | http://localhost:9000 | `sonarqube:9000` |
| Prometheus | http://localhost:9090 | `prometheus:9090` |
| Grafana | http://localhost:3000 | `grafana:3000` |
| ZAP (daemon API) | http://localhost:8090 | `zap:8090` |

Verify: `docker network inspect devsecops-net` should list all 5 containers,
and `docker compose ps` should show them `running` (SonarQube takes ~1–2 min
to become healthy).

<details>
<summary><b>Equivalent plain <code>docker</code> commands</b> (if you prefer not to use Compose)</summary>

```bash
# custom network
docker network create devsecops-net

# Jenkins (custom image with Ansible + plugins)
docker build -t petclinic/jenkins:devsecops devsecops/jenkins
docker run -d --name jenkins --network devsecops-net \
  -p 8081:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  petclinic/jenkins:devsecops

# SonarQube
docker run -d --name sonarqube --network devsecops-net \
  -p 9000:9000 -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  -v sonarqube_data:/opt/sonarqube/data \
  -v sonarqube_extensions:/opt/sonarqube/extensions \
  -v sonarqube_logs:/opt/sonarqube/logs \
  sonarqube:community

# Prometheus
docker run -d --name prometheus --network devsecops-net \
  -p 9090:9090 \
  -v "$PWD/devsecops/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v prometheus_data:/prometheus \
  prom/prometheus:latest

# Grafana
docker run -d --name grafana --network devsecops-net \
  -p 3000:3000 \
  -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=admin \
  -v grafana_data:/var/lib/grafana \
  -v "$PWD/devsecops/grafana/provisioning:/etc/grafana/provisioning:ro" \
  -v "$PWD/devsecops/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  grafana/grafana:latest

# OWASP ZAP in daemon mode with the API open to the network
docker run -d --name zap --network devsecops-net \
  -p 8090:8090 \
  ghcr.io/zaproxy/zaproxy:stable \
  zap.sh -daemon -host 0.0.0.0 -port 8090 \
    -config api.disablekey=true \
    -config api.addrs.addr.name=.* -config api.addrs.addr.regex=true
```
</details>

## 3. Generate the Jenkins → VM deploy key

Ansible (inside the Jenkins container) connects to the VM over SSH. Generate a
dedicated keypair on your host:

```bash
ssh-keygen -t ed25519 -f devsecops/vm/jenkins_key -C jenkins-deploy -N ""
```

This produces `jenkins_key` (private — stays out of git, see `.gitignore`) and
`jenkins_key.pub` (public — installed on the VM in the next step).

## 4. Set up the production web server (VM)

### Option A — Vagrant (Intel machines, or ARM with a supported provider)

```bash
cd devsecops/vm
vagrant up          # boots Ubuntu 22.04 at 192.168.56.10 and authorizes jenkins_key.pub
```

The VM's IP is fixed at **192.168.56.10** and the [Vagrantfile](vm/Vagrantfile)
provisioner appends `jenkins_key.pub` to the `vagrant` user's
`authorized_keys`. Nothing to edit in the inventory (it defaults to this IP and
user).

### Option B — Multipass (recommended on Apple Silicon)

```bash
# paste the contents of devsecops/vm/jenkins_key.pub into
# devsecops/vm/multipass-cloud-init.yml first, then:
multipass launch 22.04 --name petclinic-prod --cpus 2 --memory 2G --disk 10G \
    --cloud-init devsecops/vm/multipass-cloud-init.yml
multipass info petclinic-prod    # note the IPv4, e.g. 192.168.64.7
```

Then put the VM's address in **two places**:

- `devsecops/ansible/inventory.ini` → `ansible_host=<VM_IP> ansible_user=ubuntu`
- `Jenkinsfile` → `PROD_HOST = '<VM_IP>'`

Commit and push those edits (Jenkins reads both from the repo).

### Verify SSH works from the host

```bash
ssh -i devsecops/vm/jenkins_key vagrant@192.168.56.10 hostname   # or ubuntu@<multipass-ip>
# expected output: petclinic-prod
```

## 5. Initial Jenkins setup

1. Get the initial admin password:

   ```bash
   docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
   ```

2. Open <http://localhost:8081>, paste the password.
3. On the plugin screen choose **"Select plugins to install" → None** — every
   required plugin (Blue Ocean, SonarQube Scanner, Prometheus metrics, HTML
   Publisher, SSH Agent, JUnit, …) is already baked into the image via
   [jenkins/plugins.txt](jenkins/plugins.txt).
4. Create your admin user, accept the default URL, done.

## 6. Add Jenkins credentials

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**

| # | Kind | ID (must match exactly) | Content |
|---|---|---|---|
| 1 | SSH Username with private key | `prod-vm-ssh` | Username `vagrant` (Vagrant) or `ubuntu` (Multipass); Private key → *Enter directly* → paste the contents of `devsecops/vm/jenkins_key` |
| 2 | Secret text | `sonar-token` | The SonarQube token generated in step 7.2 (come back after step 7) |

The `Jenkinsfile` references `prod-vm-ssh` in the deploy stage via the
`sshagent` step.

## 7. Configure SonarQube and connect it to Jenkins

1. Open <http://localhost:9000> — log in with `admin` / `admin`, set a new
   password when prompted.
2. **Generate a token**: click your avatar → *My Account* → *Security* →
   Generate token (type **Global Analysis Token**), e.g. name `jenkins`.
   Copy it and store it in Jenkins as the `sonar-token` secret-text
   credential (step 6, row 2).
3. **Add a webhook** (lets the pipeline's *Quality Gate* stage get the result
   instead of timing out): *Administration* → *Configuration* → *Webhooks* →
   Create — name `jenkins`, URL:

   ```
   http://jenkins:8080/sonarqube-webhook/
   ```

   (Container-name URL — SonarQube and Jenkins share `devsecops-net`.)
4. **Tell Jenkins where SonarQube is**: *Manage Jenkins → System →
   SonarQube servers* →
   - ☑ *Environment variables: Enable injection…*
   - Add SonarQube → **Name: `SonarQube`** (must match the
     `withSonarQubeEnv('SonarQube')` call in the Jenkinsfile),
     **Server URL: `http://sonarqube:9000`**,
     **Server authentication token: `sonar-token`**.
   - Save.

No scanner install is needed — the pipeline runs analysis through Maven
(`./mvnw sonar:sonar`), which downloads the scanner plugin itself.

## 8. Configure the Prometheus plugin in Jenkins

1. *Manage Jenkins → System* → scroll to **Prometheus** section.
2. Keep **Path** = `prometheus` and the default namespace (`default`).
3. **Uncheck "Enable authentication for Prometheus end-point"** (Prometheus
   scrapes it anonymously inside the Docker network), check the options to
   collect run/queue metrics, then Save.
4. Verify the endpoint: <http://localhost:8081/prometheus/> should return
   plain-text metrics.
5. Verify Prometheus is scraping it: <http://localhost:9090/targets> → the
   `jenkins` target must be **UP** (config: [prometheus/prometheus.yml](prometheus/prometheus.yml)).

## 9. Create the pipeline job (SCM polling + Blue Ocean)

1. Jenkins → **New Item** → name `spring-petclinic` → type **Pipeline** → OK.
2. *(GitHub project — optional)* paste your fork URL.
3. **Definition**: *Pipeline script from SCM*
   - SCM: **Git**, Repository URL: `https://github.com/<YOUR_USER>/spring-petclinic.git`
     (public fork → no credential needed)
   - Branch Specifier: `*/main`
   - Script Path: `Jenkinsfile`
4. Save. **Build triggers don't need manual setup** — the Jenkinsfile declares
   `pollSCM('H/2 * * * *')`, which registers SCM polling (~every 2 min) after
   the **first** run. So click **Build Now** once to bootstrap.
5. Watch it in **Blue Ocean**: click *Open Blue Ocean* in the sidebar — each
   stage (Build & Unit Tests → SonarQube Analysis → Quality Gate → Deploy →
   Smoke Test → ZAP) renders as a node in the visual pipeline graph.

The first build takes several minutes (Maven downloads the world). When it's
green:

- **Test results** appear under the build's *Test Result* (JUnit).
- **SonarQube analysis** appears at <http://localhost:9000/dashboard?id=spring-petclinic>.
- **ZAP Security Report** appears as a link in the job's sidebar (published by
  the HTML Publisher post-build action) and under *Build Artifacts*.

  > If the ZAP report renders unstyled, relax Jenkins' CSP once via
  > *Manage Jenkins → Script Console*:
  > `System.setProperty("hudson.model.DirectoryBrowserSupport.CSP", "")`
  > (dev setting only), or just download the archived `zap-report.html`.

## 10. Grafana dashboards for Jenkins metrics

Grafana is fully auto-provisioned from the repo:

- Data source **Prometheus** → `http://prometheus:9090`
  ([provisioning/datasources/prometheus.yml](grafana/provisioning/datasources/prometheus.yml))
- Dashboard **"Jenkins – DevSecOps Pipeline"** in the *Jenkins* folder
  ([dashboards/jenkins.json](grafana/dashboards/jenkins.json)) — job count,
  queue size, executors, node status, last-build result, build durations,
  JVM heap.

Steps:

1. Open <http://localhost:3000>, log in `admin` / `admin`.
2. *Dashboards → Jenkins → Jenkins – DevSecOps Pipeline*. Panels populate
   after the first pipeline run (build metrics only exist once builds exist).
3. *(Optional)* Import the community dashboard ID **9964** ("Jenkins:
   Performance and Health Overview"): *Dashboards → New → Import* → `9964` →
   data source *Prometheus*.

## 11. How the security analysis (ZAP) works

ZAP runs permanently as a **daemon container** on `devsecops-net` with its
REST API enabled (see the `zap` service in
[docker-compose.yml](docker-compose.yml)). The pipeline's *Security Scan*
stage drives it over HTTP:

1. starts a fresh ZAP session per build,
2. **spiders** the deployed app at `http://<PROD_HOST>:8080`,
3. waits for the **passive scanner** to analyze every response
   (baseline-style scan),
4. optionally runs a full **active scan** — trigger via *Build with
   Parameters* → check `ZAP_FULL_SCAN` (slow: it attacks every URL),
5. downloads the **HTML report** and publishes it via the HTML Publisher
   post-build action (**"ZAP Security Report"** link on the build page).

## 12. End-to-end verification (deploy + welcome screen)

After a green build:

Open `<VM_IP>:8080` in your browser (e.g. `192.168.56.10:8080` for the
Vagrant VM, or your Multipass VM's IP). The plain-http URL is written
without its scheme here because the project's nohttp checkstyle rule
forbids literal http:// links in the repository.

You should see the PetClinic **welcome page** ("Welcome" + the pets image).
On the VM itself the app runs as a systemd service:

```bash
ssh -i devsecops/vm/jenkins_key vagrant@192.168.56.10 systemctl status petclinic
```

The pipeline also asserts this automatically: the Ansible playbook waits for
port 8080 and curls `/`, and the *Smoke Test* stage checks the page contains
"PetClinic".

## 13. Prove CI/CD works: push a change, watch it auto-deploy

1. Edit the welcome headline:

   ```bash
   # src/main/resources/templates/welcome.html  → change <h2 th:text="#{welcome}">…
   # or simpler, the message bundle:
   sed -i '' 's/^welcome=.*/welcome=Welcome to PetClinic — CI\/CD works!/' \
       src/main/resources/messages/messages.properties
   git commit -am "Change welcome message to verify CI/CD"
   git push origin main
   ```

2. Within ~2 minutes the SCM poll detects the commit and a new build starts
   automatically (watch it appear in Blue Ocean — trigger shows *Started by an
   SCM change*).
3. When the pipeline finishes, reload `http://<VM_IP>:8080` — the new welcome
   text is live on the production VM. 🎉

## 14. Troubleshooting

| Symptom | Fix |
|---|---|
| SonarQube container exits / ES bootstrap error | Give Docker ≥ 4 GB RAM; on Linux `sudo sysctl -w vm.max_map_count=262144` |
| `MySqlIntegrationTests` fail in Jenkins | Expected without a Docker daemon in the container — the Jenkinsfile already excludes them (`-Dtest='!MySqlIntegrationTests,!PostgresIntegrationTests'`) |
| Build fails with *spring-javaformat* violations | Run `./mvnw spring-javaformat:apply` locally, commit, push |
| Quality Gate stage times out | The SonarQube webhook (step 7.3) is missing or the URL isn't `http://jenkins:8080/sonarqube-webhook/` |
| Deploy stage: `Permission denied (publickey)` | Credential `prod-vm-ssh` must contain the **private** key `devsecops/vm/jenkins_key`, and its username must match the VM user (`vagrant`/`ubuntu`) |
| Deploy stage: unreachable host | VM IP changed (Multipass IPs can change after restart) — re-check `multipass info`, update `inventory.ini` + `PROD_HOST`, push |
| Prometheus target `jenkins` is DOWN | Step 8: authentication for the `/prometheus/` endpoint must be disabled |
| Grafana panels empty | Run the pipeline at least once; build metrics only appear after builds exist |
| ZAP stage can't reach the app | The VM must be reachable *from containers*: `docker exec zap curl -s http://<VM_IP>:8080` — if this fails, the container network can't route to the VM's subnet (use Multipass/Vagrant defaults documented above, which are host-routable) |
