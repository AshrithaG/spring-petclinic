# DevSecOps Pipeline for Spring PetClinic

Demo video: <https://drive.google.com/file/d/1jL85_NXHebUxwilYhl81haEZ1Po4K1-9/view?usp=sharing>

This project builds a complete DevSecOps pipeline around the Spring PetClinic application. A code push to GitHub is picked up by Jenkins, built and tested, analyzed by SonarQube, deployed to a production VM with Ansible, smoke tested, and finally scanned by OWASP ZAP. Prometheus collects Jenkins metrics and Grafana visualizes them.

All five tools run as Docker containers on one custom bridge network called devsecops-net. Containers reach each other by name, for example http://sonarqube:9000 or http://zap:8090. The production web server is deliberately not a container. It is a real Ubuntu VM, because that is what the assignment asks for and because it forces the deployment to work over SSH like a real remote server would.

| Concern | Tool | Where it runs |
|---|---|---|
| Continuous integration | Jenkins with Blue Ocean | Docker container |
| Static analysis | SonarQube | Docker container |
| Dynamic security scan | OWASP ZAP | Docker container |
| Metrics collection | Prometheus | Docker container |
| Dashboards | Grafana | Docker container |
| Production deployment | Ansible, invoked by Jenkins | Ubuntu VM |

## Repository layout

```
Jenkinsfile                       pipeline definition, checked out by Jenkins on every build
devsecops/
  bootstrap.sh                    fully automated setup, one command, no manual clicks
  docker-compose.yml              the five tool containers plus the custom network
  docker-compose.auto.yml         overlay used only by bootstrap.sh
  jenkins/
    Dockerfile                    Jenkins LTS plus Ansible, curl, jq and all plugins
    plugins.txt                   plugin list installed at image build time
    casc.yaml                     Jenkins Configuration as Code, used by bootstrap.sh
  prometheus/prometheus.yml       scrape config for the Jenkins metrics endpoint
  grafana/
    provisioning/                 auto-provisioned data source and dashboard loader
    dashboards/jenkins.json       custom Jenkins dashboard
  ansible/
    ansible.cfg
    deploy-petclinic.yml          playbook that installs Java and runs the app as a service
    templates/petclinic.service.j2
  vm/
    Vagrantfile                   VM definition for the Vagrant path
    multipass-cloud-init.yml      VM init for the Multipass path
```

## Prerequisites

- Docker Desktop with at least 4 GB of memory. SonarQube alone needs about 2 GB and gets killed with exit code 137 if Docker has less.
- A hypervisor for the production VM. On Apple Silicon Macs use Multipass, since VirtualBox images for x86 do not boot there. On Intel machines Vagrant with VirtualBox works and a Vagrantfile is included.
- A GitHub account and git.

## Option A: fully automated setup

Everything below in Option B can be done with a single command. The script creates the deploy key, launches the production VM, configures SonarQube through its API, and starts Jenkins preconfigured through Configuration as Code. There is no setup wizard, no manual plugin installation, no clicking through credential screens. The pipeline job is created automatically and the first build is queued on boot.

```bash
git clone https://github.com/<YOUR_USER>/spring-petclinic.git
cd spring-petclinic/devsecops
./bootstrap.sh https://github.com/<YOUR_USER>/spring-petclinic.git
```

What the script does, step by step:

1. Generates an SSH keypair at vm/jenkins_key if one does not exist. Jenkins later uses this key to reach the VM.
2. Launches an Ubuntu 22.04 VM named petclinic-prod with Multipass and authorizes the public key for the ubuntu user through cloud-init.
3. Starts only SonarQube first and waits until its API reports UP. It then changes the default admin password, because SonarQube refuses to work with admin/admin, generates a global analysis token, and registers the webhook that lets the pipeline receive quality gate results. All of this happens through the SonarQube REST API.
4. Writes a .env file containing the admin credentials, the token, the VM address and the repository URL. Docker Compose reads this file automatically. The file is gitignored because it contains secrets.
5. Starts the whole stack with the docker-compose.auto.yml overlay. That overlay disables the Jenkins setup wizard and points Jenkins at jenkins/casc.yaml. The casc file creates the admin user, both credentials (the SSH key comes in as a Docker secret, the token from the environment), the SonarQube server entry, and the pipeline job itself. The job definition ends with queue(), so the first build starts without anyone pressing a button.

When the script prints its summary, the first build is already running. It can be watched at http://localhost:8081/job/spring-petclinic/ or in Blue Ocean. After it finishes the application is live at the VM address the script printed.

To start over from scratch: `docker compose down -v` and `multipass delete --purge petclinic-prod`, then run the script again.

## Option B: manual setup

These are the same steps the script automates. They are documented so the setup can be understood and reproduced by hand.

### 1. Fork and clone

Fork https://github.com/spring-projects/spring-petclinic on GitHub, then clone your fork. Make sure origin points at your fork and not at the upstream project, otherwise pushes and polling will not work:

```bash
git remote set-url origin https://github.com/<YOUR_USER>/spring-petclinic.git
```

The Jenkinsfile and the devsecops folder must be committed and pushed to the fork. Jenkins pulls the Jenkinsfile from GitHub on every build, so a local copy is not enough.

### 2. Create the network and the containers

```bash
cd devsecops
docker compose up -d --build
```

This builds the custom Jenkins image and starts all five services on devsecops-net:

| Service | URL on the host | Name inside the network |
|---|---|---|
| Jenkins | http://localhost:8081 | jenkins:8080 |
| SonarQube | http://localhost:9000 | sonarqube:9000 |
| Prometheus | http://localhost:9090 | prometheus:9090 |
| Grafana | http://localhost:3000 | grafana:3000 |
| ZAP | http://localhost:8090 | zap:8090 |

Jenkins is published on host port 8081 instead of 8080 because 8080 is taken surprisingly often. Inside the network it is still jenkins:8080, which matters for the Prometheus scrape config and the SonarQube webhook.

Check with `docker compose ps` that all five are up. SonarQube needs a minute or two. `docker network inspect devsecops-net` should list all five containers.

The same setup without Compose, as plain docker commands:

```bash
docker network create devsecops-net

docker build -t petclinic/jenkins:devsecops devsecops/jenkins
docker run -d --name jenkins --network devsecops-net \
  -p 8081:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  petclinic/jenkins:devsecops

docker run -d --name sonarqube --network devsecops-net \
  -p 9000:9000 -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  -v sonarqube_data:/opt/sonarqube/data \
  -v sonarqube_extensions:/opt/sonarqube/extensions \
  -v sonarqube_logs:/opt/sonarqube/logs \
  sonarqube:community

docker run -d --name prometheus --network devsecops-net \
  -p 9090:9090 \
  -v "$PWD/devsecops/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v prometheus_data:/prometheus \
  prom/prometheus:latest

docker run -d --name grafana --network devsecops-net \
  -p 3000:3000 \
  -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=admin \
  -v grafana_data:/var/lib/grafana \
  -v "$PWD/devsecops/grafana/provisioning:/etc/grafana/provisioning:ro" \
  -v "$PWD/devsecops/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  grafana/grafana:latest

docker run -d --name zap --network devsecops-net \
  -p 8090:8090 \
  ghcr.io/zaproxy/zaproxy:stable \
  zap.sh -daemon -host 0.0.0.0 -port 8090 \
    -config api.disablekey=true \
    -config api.addrs.addr.name=.* -config api.addrs.addr.regex=true
```

ZAP runs as a long lived daemon with its REST API open to the network. The pipeline talks to this API instead of starting a new ZAP container per build, which keeps the build fast and needs no docker socket inside Jenkins.

### 3. Generate the deploy key

```bash
ssh-keygen -t ed25519 -f devsecops/vm/jenkins_key -C jenkins-deploy -N ""
```

The private key stays on the machine and later goes into a Jenkins credential. The public key goes onto the VM. Both files are gitignored.

### 4. Create the production VM

With Multipass, first paste the contents of jenkins_key.pub into devsecops/vm/multipass-cloud-init.yml, then:

```bash
multipass launch 22.04 --name petclinic-prod --cpus 2 --memory 2G --disk 10G \
    --cloud-init devsecops/vm/multipass-cloud-init.yml
multipass info petclinic-prod
```

Note the IPv4 address. With Vagrant instead, `cd devsecops/vm && vagrant up` boots the VM at the fixed address 192.168.56.10 and installs the key automatically.

The pipeline reads the VM address from the PROD_HOST value in the Jenkinsfile. It defaults to the Multipass address used during development. For a different VM either edit that default and push, or set PROD_HOST_OVERRIDE as an environment variable on the Jenkins container, which is what the automated setup does. For the Vagrant path also set PROD_USER_OVERRIDE to vagrant, since the login user differs.

Verify SSH works before going further:

```bash
ssh -i devsecops/vm/jenkins_key ubuntu@<VM_IP> hostname
```

If this prints petclinic-prod the key setup is correct. On newer macOS versions the Terminal may need the Local Network permission for this to work, the containers are not affected by that setting.

### 5. First Jenkins start

Get the initial password and open http://localhost:8081:

```bash
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

On the plugin screen choose Select plugins to install and then None. Every needed plugin is already baked into the image through plugins.txt, installing more here only costs time. Create the admin user and accept the default URL.

### 6. Credentials

Under Manage Jenkins, Credentials, Global, add two entries. The IDs have to match exactly because the Jenkinsfile references them.

1. Kind SSH Username with private key. ID prod-vm-ssh. Username ubuntu for Multipass or vagrant for Vagrant. Private key entered directly, paste the contents of devsecops/vm/jenkins_key.
2. Kind Secret text. ID sonar-token. The token is created in the next step, so come back for this one.

### 7. SonarQube

Open http://localhost:9000, log in with admin and admin, set a new password when asked.

Generate a token under My Account, Security. Type Global Analysis Token. Copy it immediately, it is shown once. Store it in Jenkins as the sonar-token credential.

Create a webhook under Administration, Configuration, Webhooks with the URL http://jenkins:8080/sonarqube-webhook/ so the quality gate result reaches the pipeline. Without it the Quality Gate stage waits until its timeout.

Then in Jenkins under Manage Jenkins, System, section SonarQube servers, enable the environment variable injection and add a server named SonarQube with URL http://sonarqube:9000 and the sonar-token credential. The name matters, withSonarQubeEnv('SonarQube') in the Jenkinsfile looks it up.

No scanner installation is needed. The analysis runs through Maven with mvnw sonar:sonar, which fetches the scanner on its own.

About the quality gate policy. The gate result is evaluated in its own stage but a failed gate marks the build UNSTABLE instead of aborting it. The reason is that the gate judges the inherited petclinic baseline, and blocking every deployment on day one because of old findings would stop delivery without making the code better. The signal stays visible in yellow. To make the gate strict, change abortPipeline to true and remove the catchError wrapper in the Quality Gate stage.

### 8. Prometheus and Grafana

The Prometheus plugin is already installed and exposes metrics at http://localhost:8081/prometheus/ with its default settings. Prometheus scrapes that path inside the network, the config is in prometheus/prometheus.yml. Verify at http://localhost:9090/targets that the jenkins target shows UP.

Grafana needs no manual setup at all. The data source and a Jenkins dashboard are provisioned from files at startup. Log in at http://localhost:3000 with admin and admin and open Dashboards, Jenkins. The build panels stay empty until the first build has run, which is expected. The community dashboard 9964, Jenkins Performance and Health Overview, can be imported additionally under Dashboards, New, Import.

### 9. The pipeline job

Create a new item of type Pipeline named spring-petclinic. Under Pipeline choose Pipeline script from SCM, SCM Git, the URL of your fork, branch */main, script path Jenkinsfile. Save and press Build Now once.

The first manual build matters because the pollSCM trigger declared inside the Jenkinsfile only registers after a run. From then on Jenkins checks GitHub every two minutes and builds on its own.

The first build takes several minutes because Maven downloads all dependencies. Later builds take around two minutes. Blue Ocean under Open Blue Ocean shows the stages as a graph.

### 10. What the pipeline does

1. Build and unit tests through the Maven wrapper. Two integration test classes are excluded because they need a Docker daemon through Testcontainers, which the Jenkins container does not have. The stage also deletes the ZAP report of the previous run first, because the repository enforces a nohttp checkstyle rule that rejects any leftover file containing plain http URLs. Both of these were found the hard way through failing builds.
2. SonarQube analysis through Maven.
3. Quality gate check as described above.
4. Deployment. Ansible runs inside the Jenkins container, connects to the VM as declared by PROD_HOST with an inline inventory, installs Java 17 if needed, copies the JAR, and runs the app as a systemd service. The service restarts on failure and survives VM reboots. The playbook waits for port 8080 and checks the welcome page before reporting success.
5. Smoke test with curl against the deployed page.
6. ZAP scan. The pipeline opens a fresh ZAP session, spiders the deployed site, waits for the passive scanner to finish, and downloads the HTML report. The report is published on the build page through the HTML Publisher post-build action and also archived as an artifact. A full active scan can be enabled per build with the ZAP_FULL_SCAN parameter, it is off by default because it takes long.

### 11. End to end verification

After a green build open http://<VM_IP>:8080 in a browser, the PetClinic welcome page must appear. On the VM itself `systemctl status petclinic` shows the running service.

To verify the automation, change something visible and push it:

```bash
sed -i '' 's/^welcome=.*/welcome=Welcome to PetClinic - CI CD works/' \
    src/main/resources/messages/messages.properties
git commit -am "Change welcome message"
git push origin main
```

Within about two minutes a new build starts on its own, the cause on the build page reads Started by an SCM change. After it finishes, reloading the VM page shows the new text.

## Troubleshooting

| Problem | Cause and fix |
|---|---|
| SonarQube container exits with 137 | Docker has too little memory, give it 4 GB or more |
| Integration tests fail in Jenkins | Expected without Docker in the container, the Jenkinsfile already excludes MySqlIntegrationTests and PostgresIntegrationTests |
| Build fails on nohttp checkstyle | The repo forbids plain http URLs in files. Watch out for leftover reports in the workspace and for documentation containing http links with IP addresses |
| Build fails on spring-javaformat | Run ./mvnw spring-javaformat:apply, commit, push |
| Quality Gate stage times out | The SonarQube webhook is missing or has the wrong URL, it must be http://jenkins:8080/sonarqube-webhook/ |
| Deploy fails with Permission denied | The prod-vm-ssh credential does not contain the right private key or the username does not match the VM user |
| Deploy cannot reach the VM | Multipass IPs can change after a host reboot, check multipass info and update PROD_HOST |
| Prometheus target down | The metrics endpoint moved or authentication got enabled in the plugin settings, defaults work |
| Grafana panels empty | No builds yet, run the pipeline once |
| ZAP report looks unstyled in Jenkins | The Jenkins content security policy strips the styling, the archived zap-report.html artifact renders fine when downloaded |
| ZAP cannot reach the app | The containers must be able to route to the VM address, test with docker exec zap curl http://<VM_IP>:8080 |
