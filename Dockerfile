FROM buildpack-deps:noble

ARG HOST_UID=501
ARG HOST_GID=20

# buildpack-deps:noble provides: git, curl, wget, gcc, g++, make, file,
# unzip, openssh-client, ca-certificates, tzdata, procps, and dev libraries.
# Add sysadmin/networking/editor tools it doesn't include:
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        tmux jq sudo less vim-tiny man-db \
        dnsutils iputils-ping net-tools netcat-openbsd \
        htop tree rsync lsof strace zip \
        python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI (for nested yolo — client only, connects to host daemon via socket)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Non-root user matching host UID/GID for file ownership
RUN groupadd -g ${HOST_GID} claude_group 2>/dev/null || true \
    && useradd -m -u ${HOST_UID} -g ${HOST_GID} -s /bin/bash claude \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude

# Claude Code — native install (version arg busts cache when host upgrades)
USER claude
ARG CLAUDE_VERSION
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- ${CLAUDE_VERSION}
ENV PATH="/home/claude/.local/bin:${PATH}"

# Tmux config
COPY --chown=claude:${HOST_GID} tmux.conf /home/claude/.tmux.conf

# Entrypoint
USER root
COPY --chown=claude:${HOST_GID} entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER claude
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
