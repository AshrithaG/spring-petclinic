# Jenkins controller with Ansible for deployments, curl and jq for the
# ZAP REST API, and all plugins preinstalled. JDK 21 also builds the
# project through the Maven wrapper.

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

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

USER jenkins
