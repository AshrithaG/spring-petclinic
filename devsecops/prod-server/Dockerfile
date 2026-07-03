FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server \
    openjdk-17-jdk \
    sudo \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir /var/run/sshd

RUN useradd -m -s /bin/bash deploy \
    && echo 'deploy:deploy123' | chpasswd \
    && echo 'deploy ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

RUN mkdir -p /opt/petclinic && chown deploy:deploy /opt/petclinic

RUN echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config \
    && echo "KbdInteractiveAuthentication yes" >> /etc/ssh/sshd_config \
    && echo "PermitRootLogin no" >> /etc/ssh/sshd_config

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D", "-e"]
