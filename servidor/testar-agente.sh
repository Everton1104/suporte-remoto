#!/usr/bin/env bash
# testar-agente.sh — E2E do circuito do AGENTE PERMANENTE, sem Windows e sem
# outra máquina: simula um agente de verdade contra o web.py local.
# registrar -> idempotência -> painel manda conectar -> túnel reverso ->
# técnico entra pelo atender (modo agente) -> encerrar -> remover -> limpo.
# Assume o web.py rodando em 127.0.0.1:8090 (serviço suporte-web).
set -uo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
URL=${URL:-http://127.0.0.1:8090}
AK=/root/.ssh/authorized_keys
AK_TUNEL=/home/suporte/.ssh/authorized_keys
WORK=$(mktemp -d /tmp/teste-agente.XXXXXX)

falhar() { echo "FALHOU: $1"; [ -n "${TPID:-}" ] && kill "$TPID" 2>/dev/null; exit 1; }
porta_aberta() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

curl -fsS "$URL/" -o /dev/null || falhar "web.py não responde em $URL"
[ -f "$AK" ] && cp -a "$AK" "$AK.teste-agente-bak"
"$BASE/setup-sshd.sh" >/dev/null 2>&1 || true

# 1) registra (o que o instalador do cliente faz)
ssh-keygen -q -t ed25519 -N '' -f "$WORK/chave-tunel" -C teste-agente
CORPO="{\"nome\":\"teste-agente\",\"maquina\":\"$(hostname)\",\"so\":\"linux\",\"usuario\":\"root\",\"chave_tunel\":\"$(cat "$WORK/chave-tunel.pub")\"}"
R=$(curl -fsS -X POST -H 'Content-Type: application/json' -d "$CORPO" "$URL/agente/registrar") || falhar "registrar"
ID=$(printf '%s' "$R"  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
PORTA=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin)["porta"])')
PUBTEC=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin)["pubkey_tecnico"])')
[ -n "$ID" ] && [ -n "$PORTA" ] && [ -n "$PUBTEC" ] || falhar "resposta do registrar incompleta: $R"

# 2) idempotência: mesma chave → mesmo cliente
R2=$(curl -fsS -X POST -H 'Content-Type: application/json' -d "$CORPO" "$URL/agente/registrar") || falhar "re-registrar"
ID2=$(printf '%s' "$R2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
[ "$ID" = "$ID2" ] || falhar "idempotência quebrada ($ID != $ID2)"

# 3) instala a chave do técnico no root (o que o instalador do cliente faz)
mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch "$AK"
grep -qF "$PUBTEC" "$AK" || printf '%s\n' "$PUBTEC" >> "$AK"

# 4) estado inicial: conectar=false
curl -fsS "$URL/agente/estado?id=$ID" | grep -q '"conectar": false' || falhar "estado inicial"

# 5) painel manda conectar
TOKEN=$(python3 -c "import json;print(json.load(open('$BASE/clientes.json'))['token_painel'])")
ACAO="{\"token\":\"$TOKEN\",\"id\":\"$ID\",\"acao\":\"%s\"}"
curl -fsS -X POST -H 'Content-Type: application/json' -d "$(printf "$ACAO" conectar)" "$URL/painel/acao" >/dev/null || falhar "ação conectar"
curl -fsS "$URL/agente/estado?id=$ID" | grep -q '"conectar": true' || falhar "flag conectar não chegou"
curl -fsS "$URL/painel/dados?token=$TOKEN" | grep -q "\"$ID\"" || falhar "painel não lista o cliente"

# 6) agente abre o túnel (ssh direto no sshd local; em produção via cloudflared)
TPID=
ssh -N -i "$WORK/chave-tunel" -p 2222 suporte@localhost \
    -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
    -R "${PORTA}:localhost:2222" &
TPID=$!
for i in $(seq 1 10); do porta_aberta "$PORTA" && break; sleep 1; done
porta_aberta "$PORTA" || falhar "porta $PORTA não abriu"

# 7) técnico entra pelo atender (modo agente: id -> porta/usuário do registro)
RES=$("$BASE/atender.sh" "$ID" -c 'id -u' 2>/dev/null) || RES=x
[ "$RES" = "0" ] || falhar "atender modo agente (retornou: $RES)"

# 8) painel encerra e remove; servidor deve revogar tudo
curl -fsS -X POST -H 'Content-Type: application/json' -d "$(printf "$ACAO" encerrar)" "$URL/painel/acao" >/dev/null || falhar "ação encerrar"
curl -fsS "$URL/agente/estado?id=$ID" | grep -q '"conectar": false' || falhar "flag encerrar"
kill "$TPID" 2>/dev/null; TPID=
curl -fsS -X POST -H 'Content-Type: application/json' -d "$(printf "$ACAO" remover)" "$URL/painel/acao" >/dev/null || falhar "ação remover"
grep -q "cliente:$ID:tunel" "$AK_TUNEL" && falhar "chave do túnel não foi revogada"
[ -d "$BASE/clientes/$ID" ] && falhar "pasta do cliente não foi apagada"
curl -s "$URL/agente/estado?id=$ID" | grep -q "desconhecido" || falhar "cliente ainda responde no estado"

# 9) authorized_keys do root volta ao que era
sed -i "\#${PUBTEC}#d" "$AK" 2>/dev/null   # higiene (o remover do painel não mexe aqui)
if [ -f "$AK.teste-agente-bak" ]; then
    grep -v 'cliente:' "$AK.teste-agente-bak" > /tmp/ak-esperado 2>/dev/null || : > /tmp/ak-esperado
    if [ -e "$AK" ]; then cmp -s "$AK" /tmp/ak-esperado || falhar "authorized_keys do root ficou diferente do original"
    else [ -s /tmp/ak-esperado ] && falhar "authorized_keys do root sumiu com conteúdo original"; fi
    rm -f "$AK.teste-agente-bak"
fi
rm -rf "$WORK" /tmp/ak-esperado
echo "OK: agente E2E (registro -> conectar -> túnel -> atender -> encerrar -> remover)"
