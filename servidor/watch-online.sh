#!/usr/bin/env bash
# watch-online.sh — espera um cliente ficar ONLINE (o agente voltar a
# reportar ao servidor) e avisa o técnico no painel (avisar.sh). Sai depois
# do 1º aviso. Um watcher por cliente: segunda chamada com o mesmo cliente
# vivo não duplica.
# uso: nohup bash servidor/watch-online.sh <cliente> [max-horas] >/dev/null 2>&1 &
#      <cliente> = id/máquina/nome (pedaço, mesma régua de bin/mensagem)
# Detalhe: cliente JÁ online no início = aviso na hora (confira antes com
# bin/clientes). Roda desanexado (nohup): sobrevive à conversa que o criou.
set -uo pipefail
BASE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[ $# -ge 1 ] || { echo "uso: watch-online.sh <cliente> [max-horas]"; exit 1; }
ALVO=$1; MAXH=${2:-12}
case "$MAXH" in ''|*[!0-9]*) echo "max-horas deve ser um número"; exit 1 ;; esac

# resolve o cliente (id/máquina/nome, parcial) — mesmo trecho de bin/mensagem
MAPA=$(python3 -c "
import json,sys
cs=json.load(open(sys.argv[1]))['clientes']
a=sys.argv[2].lower()
h=[(k,c.get('nome','')) for k,c in cs.items() if a in k.lower() or a in c.get('maquina','').lower() or a in c.get('nome','').lower()]
print('\n'.join('%s\t%s'%x for x in h))" "$BASE/clientes.json" "$ALVO")
[ -n "$MAPA" ] || { echo "nenhum cliente casa com '$ALVO'"; exit 1; }
[ "$(printf '%s\n' "$MAPA" | wc -l)" -le 1 ] || {
  echo "ambíguo, casa com:"; printf '%s\n' "$MAPA"; exit 1; }
ID=${MAPA%%$'\t'*}; NOME=${MAPA#*$'\t'}

# 1 watcher por cliente: pidfile com processo vivo
LOCK=/tmp/suporte-watch-$ID.pid
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
  echo "já há watcher para $NOME ($ID), pid $(cat "$LOCK")"; exit 0
fi
echo $$ > "$LOCK"; trap 'rm -f "$LOCK"' EXIT
echo "vigando $NOME ($ID) — aviso no painel quando ficar online (máx ${MAXH}h)"

FIM=$(( $(date +%s) + MAXH*3600 ))
while [ "$(date +%s)" -lt "$FIM" ]; do
  ESTADO=$(python3 - "$BASE/clientes.json" "$ID" <<'EOF' || echo off
import datetime, json, sys
try:
    c = json.load(open(sys.argv[1]))["clientes"].get(sys.argv[2])
except (OSError, ValueError, KeyError):
    c = None
if c is None:
    print("removido"); raise SystemExit
try:
    d = (datetime.datetime.now()
         - datetime.datetime.fromisoformat(c["ultimo_contato"])).total_seconds()
except (KeyError, ValueError):
    d = 1e9
print("online" if d < 60 else "off")
EOF
)
  case "$ESTADO" in
    online) exec bash "$BASE/avisar.sh" "🟢 $NOME ($ID) ficou online" ;;
    removido) echo "cliente removido do registro — watcher encerrado"; exit 0 ;;
  esac
  sleep 15
done
exec bash "$BASE/avisar.sh" "⏳ watcher de $NOME ($ID) expirou (${MAXH}h) sem ficar online"
