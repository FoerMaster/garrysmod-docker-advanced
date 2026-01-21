FROM ubuntu:22.04

LABEL MAINTAINER="FOER"

# Base deps for SteamCMD (incl. i386 libs)
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get -y upgrade \
    && apt-get -y --no-install-recommends install \
    curl \
    ca-certificates \
    lib32stdc++6 \
    libtinfo5:i386 \
    inotify-tools \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# Create user/group
RUN groupadd -g 1000 steam \
    && useradd -m -d /gmodserv -u 1000 -g steam steam

# Copy scripts as root, set permissions
COPY sync_gmod.sh /gmodserv/sync_gmod.sh
COPY entrypoint.sh /gmodserv/entrypoint.sh
RUN chmod +x /gmodserv/sync_gmod.sh /gmodserv/entrypoint.sh

# Pre-create directories SteamCMD will write to, then hand ownership to steam
RUN mkdir -p /gmodserv/steamcmd /gmodserv/Steam \
    && chown -R steam:steam /gmodserv

USER steam
ENV HOME=/gmodserv

WORKDIR /gmodserv/steamcmd

RUN curl -fsSL -o steamcmd_linux.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    && tar -xvzf steamcmd_linux.tar.gz \
    && rm steamcmd_linux.tar.gz

ARG STEAM_BRANCH=dev
RUN set -eu; \
    attempts=5; \
    i=1; \
    while [ "$i" -le "$attempts" ]; do \
      echo "SteamCMD attempt $i/$attempts"; \
      if [ "$STEAM_BRANCH" = "public" ] || [ -z "$STEAM_BRANCH" ]; then \
        if ./steamcmd.sh \
          +force_install_dir /gmodserv \
          +login anonymous \
          +app_update 4020 validate \
          +quit; then \
          break; \
        fi; \
      else \
        if ./steamcmd.sh \
          +force_install_dir /gmodserv \
          +login anonymous \
          +app_update 4020 -beta "$STEAM_BRANCH" validate \
          +quit; then \
          break; \
        fi; \
      fi; \
      if [ "$i" -eq "$attempts" ]; then \
        echo "SteamCMD failed after $attempts attempts"; \
        exit 1; \
      fi; \
      echo "SteamCMD failed, retrying in 15s..."; \
      sleep 15; \
      i=$((i + 1)); \
    done

# Run server
WORKDIR /gmodserv
ENTRYPOINT ["./entrypoint.sh"]
