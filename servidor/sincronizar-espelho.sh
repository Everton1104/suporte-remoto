#!/usr/bin/env bash
# sincronizar-espelho.sh — publica o espelho DO TERMUX no servidor ATIVO.
#
# Modelo (Everton, 24/11): o Termux é o servidor de verdade — a administração
# toda (atualizar-espelho.sh, claude, skills) roda nele. O servidor web que
# publica o painel é uma réplica descartável: hoje um PC, amanhã outro, e
# NADA pode ter vínculo com máquina específica. O alvo do sync vem todo de
# servidor-ativo.conf — quando o servidor mudar de casa, edita o conf.
#
# Envia: binários (cloudflared×3, openssh, curl+ca) + versoes.json.
# --debs: inclui static/deb (tela Linux). O iso do WinPE NÃO vai (2,5 GB,
# não muda com este fluxo).
set -euo pipefail

BASE=$(cd "$(dirname "$0")" && pwd)
ST="$BASE/static"
CONF="$BASE/servidor-ativo.conf"
DEBS=0
[ "${1:-}" = "--debs" ] && DEBS=1

[ -f "$CONF" ] || { echo "falta $CONF (modelo: cabecalho do proprio conf no git)"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"
: "${CID:?}${USUARIO:?}${PASTA:?}${HOST_CF:?}${PORTA_CF:?}"

CHAVE="$BASE/clientes/$CID/chave-tecnico"
[ -f "$CHAVE" ] || { echo "chave do servidor ativo não encontrada: $CHAVE"; exit 1; }
KH="$BASE/clientes/__termux__/known_hosts-servidor-ativo"
SSHO=(-p "$PORTA_CF" -i "$CHAVE"
      -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=accept-new
      -o ConnectTimeout=15)

# access cf de pé? (mesmo caminho que o técnico usa pra operar o servidor)
if ! timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORTA_CF" 2>/dev/null; then
    echo "subindo cloudflared access -> $HOST_CF (porta $PORTA_CF)"
    setsid nohup cloudflared access tcp --hostname "$HOST_CF" \
        --url localhost:"$PORTA_CF" >/tmp/cf-access-$PORTA_CF.log 2>&1 &
    for _ in $(seq 12); do
        timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORTA_CF" 2>/dev/null && break
        sleep 1
    done
fi

echo "== conferindo acesso ao servidor ativo ($CID) =="
ssh "${SSHO[@]}" "$USUARIO@localhost" "echo ok" >/dev/null

echo "== publicando espelho =="
ARQ=(cloudflared-windows-amd64.exe cloudflared-linux-amd64
     cloudflared-linux-arm64 openssh-win64.zip curl.exe
     curl-ca-bundle.crt versoes.json)
scp -P "$PORTA_CF" -i "$CHAVE" \
    -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=accept-new \
    "${ARQ[@]/#/$ST/}" "$USUARIO@localhost:$PASTA/static/"

if [ "$DEBS" -eq 1 ]; then
    echo "== publicando .deb (tela Linux) =="
    scp -r -P "$PORTA_CF" -i "$CHAVE" \
        -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=accept-new \
        "$ST/deb" "$USUARIO@localhost:$PASTA/static/"
fi

echo "== conferindo versão lá =="
# cat serve nos dois shells (alias no PowerShell, binário no Linux) — e
# nada de "2>nul", que quebra PowerShell via ssh (lição do adjundiai87)
ssh "${SSHO[@]}" "$USUARIO@localhost" "cat $PASTA/static/versoes.json"
echo "sincronizado."
