#!/bin/bash
set -e

./sync_gmod.sh &

PORT=${GMOD_PORT:-27015}
TICKRATE=${GMOD_TICKRATE:-32}
MAXPLAYERS=${GMOD_MAXPLAYERS:-16}
MAP=${GMOD_MAP:-gm_construct}
GAMEMODE=${GMOD_GAMEMODE:-sandbox}

ARGS=()

ARGS+=("-port" "$PORT")
ARGS+=("-tickrate" "$TICKRATE")
ARGS+=("-maxplayers" "$MAXPLAYERS")

if [ "$GMOD_INSECURE" = "true" ]; then
    ARGS+=("-insecure")
fi

if [ -n "$GAMEMODE" ]; then
    ARGS+=("+gamemode" "$GAMEMODE")
fi

ARGS+=("+map" "$MAP")

exec ./srcds_run \
  -game garrysmod \
  -console \
  -norestart \
  -strictportbind \
  "${ARGS[@]}" \
  "$@"