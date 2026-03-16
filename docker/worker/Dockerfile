FROM ruby:4-trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    nodejs \
    npm \
    openssh-server \
    ripgrep \
    sudo \
  && rm -rf /var/lib/apt/lists/*

RUN npm install --global @mariozechner/pi-coding-agent

RUN useradd -m -s /bin/bash symphony \
  && install -d -m 700 /home/symphony/.ssh \
  && install -d -m 755 /home/symphony/.pi/agent/skills \
  && install -d -m 755 /run/symphony/ssh /var/run/sshd

COPY sshd.conf /etc/ssh/sshd_config.d/symphony-worker.conf
COPY entrypoint.sh /usr/local/bin/symphony-worker
RUN chmod 755 /usr/local/bin/symphony-worker

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/symphony-worker"]
