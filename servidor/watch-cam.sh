#!/usr/bin/env bash
# watch-cam.sh — mantem o elo cam.evertonrs.com.br -> Will:8123 de pe:
# se o ssh -L morrer (reboot do Will ou do servidor), relanca em ate 30s.
BASE=$(cd "$(dirname "$0")" && pwd)
ID=adjundiai39-8a17
while :; do
  if ! curl -s --max-time 8 -o /dev/null http://127.0.0.1:8123/estado; then
    pgrep -f "127.0.0.1:8123:127.0.0.1:8123" >/dev/null 2>&1 || \
    nohup ssh -p 10027 -i "$BASE/clientes/$ID/chave-tecnico" \
      -o UserKnownHostsFile="$BASE/clientes/$ID/known_hosts" \
      -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=4 -o ExitOnForwardFailure=yes \
      -N -L 127.0.0.1:8123:127.0.0.1:8123 som@localhost >>/tmp/tunel-mesa.log 2>&1 &
    echo "$(date '+%F %T') tunel religado" >> /tmp/watch-cam.log
  fi
  sleep 30
done
