#!/usr/bin/env bash
# tunel-will.sh — túnel reverso do Termux (proot) pro servidor Windows do Will.
#
# O servidor do painel migrou pro PC do Will (23/11), mas o cérebro (claude,
# skills, histórico) continua NESTE celular. Este túnel expõe o sshd local
# (2222) na porta 10030 do localhost do Will — o web.py do Will abre
# ssh.exe -p 10030 pra dar o terminal "servidor" (shell do Termux) e o modo
# claude (claude CLI daqui, com as skills operar/atender).
#
# Rotas, em ordem de preferência:
#   1. LAN direta (192.168.0.39) — mesma rede do Will, sem internet no meio
#   2. Cloudflare (ssh.evertonrs.com.br via cloudflared access) — celular
#      fora de casa / LAN indisponível
# Loop infinito com reconexão; roda sob runit (sv will-tunel) ou à mão.
#
# ESTADO (24/11): NÃO USADO na v1 — o web.py conecta DIRETO no celular pela
# LAN (root@192.168.0.99:2222), que funciona. Este túnel fica de reserva:
# o ssh.exe do Windows atravessando listener -R do sshd do Will quebra com
# "banner exchange: Connection refused" (o canal abre e o banner flui — um
# probe TCP cru lê o SSH-2.0 — mas o ssh.exe fecha antes). Reproduz em LAN
# e via Cloudflare; bug não caçado até aqui. Se o celular precisar ser
# alcançado de fora da LAN, caçar isso primeiro.
set -u

BASE=$(cd "$(dirname "$0")" && pwd)
CHAVE_WILL="$BASE/clientes/adjundiai39-8a17/chave-tecnico"
KH="$BASE/clientes/__termux__/known_hosts-will"
PORTA_REMOTA=10030          # no localhost do Will
DESTINO=127.0.0.1:2222      # suporte-sshd deste proot

OPCOES=(-N
    -R "127.0.0.1:${PORTA_REMOTA}:${DESTINO}"
    -i "$CHAVE_WILL"
    -o UserKnownHostsFile="$KH"
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=20 -o ServerAliveCountMax=3
    -o ExitOnForwardFailure=yes
    -o ConnectTimeout=10)

log() { echo "$(date '+%m/%d %H:%M:%S') $*"; }

while true; do
    # 1) LAN: o Will responde na 22?
    if timeout 3 bash -c "exec 3<>/dev/tcp/192.168.0.39/22" 2>/dev/null; then
        ROTA="lan"
        log "conectando via LAN (192.168.0.39)"
        ssh "${OPCOES[@]}" som@192.168.0.39
    else
        ROTA="cloudflare"
        log "LAN indisponível — conectando via Cloudflare"
        ssh -o ProxyCommand="cloudflared access ssh --hostname ssh.evertonrs.com.br" \
            "${OPCOES[@]}" som@ssh.evertonrs.com.br
    fi
    log "túnel caiu (rota $ROTA, rc=$?) — religando em 5s"
    sleep 5
done
