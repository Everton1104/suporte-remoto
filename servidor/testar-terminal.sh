#!/usr/bin/env bash
# testar-terminal.sh — E2E do TERMINAL WEB do painel, sem Windows e sem outra
# máquina: registra um cliente local, abre o túnel reverso (como o agente faria),
# abre o terminal pelo navegador-simulado (curl): página xterm, stream do PTY
# rodando atender.sh, teclado via POST, redimensionamento e fechamento.
# Assume o web.py rodando em 127.0.0.1:8090 (serviço suporte-web).
set -uo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
URL=${URL:-http://127.0.0.1:8090}
AK=/root/.ssh/authorized_keys
WORK=$(mktemp -d /tmp/teste-terminal.XXXXXX)

falhar() { echo "FALHOU: $1"; limpar_tunel; [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null; exit 1; }
porta_aberta() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
limpar_tunel() { [ -n "${TPID:-}" ] && kill "$TPID" 2>/dev/null; TPID=; }

curl -fsS "$URL/" -o /dev/null || falhar "web.py não responde em $URL"
[ -f "$AK" ] && cp -a "$AK" "$AK.teste-terminal-bak"
"$BASE/setup-sshd.sh" >/dev/null 2>&1 || true

# 1) registra e conecta como o painel faria
ssh-keygen -q -t ed25519 -N '' -f "$WORK/chave-tunel" -C teste-terminal
CORPO="{\"nome\":\"teste-terminal\",\"maquina\":\"$(hostname)\",\"so\":\"linux\",\"usuario\":\"root\",\"chave_tunel\":\"$(cat "$WORK/chave-tunel.pub")\"}"
R=$(curl -fsS -X POST -H 'Content-Type: application/json' -d "$CORPO" "$URL/agente/registrar") || falhar "registrar"
ID=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
PORTA=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin)["porta"])')
PUBTEC=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin)["pubkey_tecnico"])')
mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch "$AK"
grep -qF "$PUBTEC" "$AK" || printf '%s\n' "$PUBTEC" >> "$AK"
TOKEN=$(python3 -c "import json;print(json.load(open('$BASE/clientes.json'))['token_painel'])")
curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "{\"token\":\"$TOKEN\",\"id\":\"$ID\",\"acao\":\"conectar\"}" "$URL/painel/acao" >/dev/null || falhar "conectar"

# 2) túnel reverso (o que o agente real faz via cloudflared)
ssh -N -i "$WORK/chave-tunel" -p 2222 suporte@localhost \
    -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
    -R "${PORTA}:localhost:2222" &
TPID=$!
for i in $(seq 1 10); do porta_aberta "$PORTA" && break; sleep 1; done
porta_aberta "$PORTA" || falhar "porta $PORTA não abriu"

# 3) coluna nome: renomear e conferir que voltou no /painel/dados
curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "{\"token\":\"$TOKEN\",\"id\":\"$ID\",\"nome\":\"Notebook da Tia\"}" "$URL/painel/nome" >/dev/null || falhar "renomear"
curl -fsS "$URL/painel/dados?token=$TOKEN" | grep -q "Notebook da Tia" || falhar "nome não apareceu no painel"

# 4) página do terminal + assets xterm
curl -fsS "$URL/painel/term?cid=$ID&token=$TOKEN" | grep -q "xterm.js" || falhar "página do terminal"
curl -fsS "$URL/xterm.js" -o "$WORK/x.js" || falhar "asset xterm.js"
[ "$(stat -c%s "$WORK/x.js")" -gt 10000 ] || falhar "xterm.js veio truncado"

# 5) o terminal de verdade: stream do PTY + teclado via POST
SID="teste-$(date +%s)"
curl -N -s "$URL/painel/term/stream?cid=$ID&s=$SID&token=$TOKEN" > "$WORK/stream.out" &
SPID=$!
sleep 6   # pré-voo do atender.sh + login ssh
grep -q "shell elevado" "$WORK/stream.out" || falhar "stream não mostrou o pré-voo do atender"
curl -fsS -X POST --data-binary 'echo TERMINAL_OK_$$' "$URL/painel/term/in?s=$SID&token=$TOKEN" >/dev/null
curl -fsS -X POST --data-binary $'\r' "$URL/painel/term/in?s=$SID&token=$TOKEN" >/dev/null
sleep 3
grep -q "TERMINAL_OK_" "$WORK/stream.out" || falhar "comando do terminal não voltou no stream"
curl -fsS -X POST -H 'Content-Type: application/json' -d '{"cols":120,"rows":40}' \
    "$URL/painel/term/size?s=$SID&token=$TOKEN" >/dev/null || falhar "resize"
curl -fsS -X POST "$URL/painel/term/fechar?s=$SID&token=$TOKEN" >/dev/null || falhar "fechar"
sleep 1
wait "$SPID" 2>/dev/null

# 6) desmonta tudo (encerrar + remover + higiene)
limpar_tunel
curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "{\"token\":\"$TOKEN\",\"id\":\"$ID\",\"acao\":\"remover\"}" "$URL/painel/acao" >/dev/null || falhar "remover"
sed -i "\#${PUBTEC}#d" "$AK" 2>/dev/null
if [ -f "$AK.teste-terminal-bak" ]; then
    grep -v 'cliente:' "$AK.teste-terminal-bak" > /tmp/ak-esperado 2>/dev/null || : > /tmp/ak-esperado
    cmp -s "$AK" /tmp/ak-esperado || falhar "authorized_keys do root ficou diferente do original"
    rm -f "$AK.teste-terminal-bak"
fi
rm -rf "$WORK" /tmp/ak-esperado
echo "OK: terminal E2E (página xterm + stream PTY + teclado + resize + fechar + renomear)"
