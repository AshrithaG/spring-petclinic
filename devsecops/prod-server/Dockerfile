FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

RUN apt-get update && apt-get install -y \
    systemd systemd-sysv \
    openssh-server \
    openjdk-17-jdk \
    sudo \
    python3 \
    && rm -rf /var/lib/apt/lists/*

RUN cd /lib/systemd/system/sysinit.target.wants/ \
    && ls | grep -v systemd-tmpfiles-setup | xargs rm -f $1 \
    && rm -f /lib/systemd/system/multi-user.target.wants/* \
    && rm -f /etc/systemd/system/*.wants/* \
    && rm -f /lib/systemd/system/local-fs.target.wants/* \
    && rm -f /lib/systemd/system/sockets.target.wants/*udev* \
    && rm -f /lib/systemd/system/sockets.target.wants/*initctl* \
    && rm -f /lib/systemd/system/basic.target.wants/* \
    && rm -f /lib/systemd/system/anaconda.target.wants/*

RUN useradd -m -s /bin/bash deploy \
    && echo 'deploy:deploy123' | chpasswd \
    && echo 'deploy ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

RUN mkdir -p /opt/petclinic && chown deploy:deploy /opt/petclinic

RUN echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config \
    && echo "KbdInteractiveAuthentication yes" >> /etc/ssh/sshd_config \
    && echo "PermitRootLogin no" >> /etc/ssh/sshd_config \
    && systemctl enable ssh \
    && ln -sf /lib/systemd/system/systemd-user-sessions.service \
       /etc/systemd/system/multi-user.target.wants/systemd-user-sessions.service

EXPOSE 22 8080

CMD ["/sbin/init"]
