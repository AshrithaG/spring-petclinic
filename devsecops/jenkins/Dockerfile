# Custom Jenkins controller image for the petclinic DevSecOps pipeline.
#
# Adds on top of the official LTS image:
#   - Ansible + OpenSSH client, so the pipeline can deploy to the
#     production VM with ansible-playbook over SSH
#   - curl / jq, used by the pipeline to drive the ZAP REST API
#   - All required plugins pre-installed from plugins.txt
#
# JDK 21 runs Jenkins itself and is also used by ./mvnw to build
# petclinic (pom targets Java 17; compiling with a newer JDK is fine).

FROM jenkins/jenkins:lts-jdk21

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        openssh-client \
        sshpass \
        curl \
        jq \
        git && \
    pip3 install --no-cache-dir --break-system-packages ansible-core && \
    ansible-galaxy collection install ansible.posix community.general && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-install Jenkins plugins so no manual plugin hunting is needed
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

USER jenkins
