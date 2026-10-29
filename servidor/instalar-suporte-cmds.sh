#!/usr/bin/env bash
# instalar-suporte-cmds.sh — planta suporte-mensagem e suporte-pergunta no
# System32 do cliente, para uso DENTRO da sessão dele (terminal/SSH/túnel),
# sem passar pelo servidor. CRLF + BOM são adicionados na hora (cmd e
# PS 5.1 esperam isso).
# uso: instalar-suporte-cmds.sh <id-cliente>   (atalho: instalar-cmds 87)
set -euo pipefail
BASE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
ID=${1:?uso: instalar-suporte-cmds.sh <id-cliente>}
MAPA=$(python3 -c "
import json
c = json.load(open('$BASE/clientes.json'))['clientes']['$ID']
print(c['porta'], c.get('usuario') or 'root')")
PORTA=$(printf '%s' "$MAPA" | awk '{print $1}')
USUARIO=$(printf '%s' "$MAPA" | awk '{print $2}')
CHAVE="$BASE/clientes/$ID/chave-tecnico"
KHOST="-o UserKnownHostsFile=$BASE/clientes/$ID/known_hosts"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for f in suporte-mensagem.cmd suporte-pergunta.cmd; do
    sed 's/$/\r/' "$BASE/cliente-cmds/$f" > "$TMP/$f"
done
{ printf '\xEF\xBB\xBF'; sed 's/$/\r/' "$BASE/cliente-cmds/suporte-pergunta-run.ps1"; } > "$TMP/suporte-pergunta-run.ps1"

# sshd sem Subsystem sftp reprova o scp moderno ("Connection closed");
# -O usa o protocolo legado, que todo sshd tem — fallback do server2
scp -q -P "$PORTA" -i "$CHAVE" $KHOST \
    "$TMP/suporte-mensagem.cmd" "$TMP/suporte-pergunta.cmd" "$TMP/suporte-pergunta-run.ps1" \
    "$USUARIO@localhost:C:/Windows/System32/" ||
scp -O -q -P "$PORTA" -i "$CHAVE" $KHOST \
    "$TMP/suporte-mensagem.cmd" "$TMP/suporte-pergunta.cmd" "$TMP/suporte-pergunta-run.ps1" \
    "$USUARIO@localhost:C:/Windows/System32/"
echo ">> comandos plantados no System32 de $ID"
echo ">> dentro da sessao do cliente: suporte-mensagem <texto> | suporte-pergunta <pergunta>"
