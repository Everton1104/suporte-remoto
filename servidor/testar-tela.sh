#!/usr/bin/env bash
# testar-tela.sh — bateria de CAMPO da tela remota contra um cliente real
# (Windows ou Linux), pelo túnel reverso. Valida o protocolo novo sem
# mexer na máquina do usuário: input só move o mouse 1px (tecla F13 é
# propositalmente inexistente no mapa VK) e o clipboard é restaurado.
#
# uso:   testar-tela.sh <id-cliente>
# precisa: túnel do cliente online (porta reversa aberta)
set -euo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
ID=${1:?uso: testar-tela.sh <id-cliente>}

MAPA=$(python3 -c "
import json
c = json.load(open('$BASE/clientes.json'))['clientes']['$ID']
print(c['porta'], c.get('usuario') or 'root', c.get('so') or 'windows')")
PORTA=$(printf '%s' "$MAPA" | awk '{print $1}')

porta_aberta() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
porta_aberta "$PORTA" || { echo "FALHOU: túnel de $ID offline (porta $PORTA)"; exit 1; }

echo "== subindo a tela (tela.sh subir) =="
time "$BASE/tela.sh" "$ID" subir

PORTA_LOCAL=$((PORTA + 20000))
H='Host: localhost:28090'

echo
echo "== /info (shape novo: w h fps kbps clip) =="
INFO=$(curl -fsS -m 5 -H "$H" "http://127.0.0.1:$PORTA_LOCAL/info")
echo "$INFO"
echo "$INFO" | python3 -c '
import json,sys
j = json.load(sys.stdin)
assert {"w","h","fps","kbps","clip"} <= set(j), "campos faltando: %s" % sorted(j)
print("OK: /info válido")'

echo
echo "== stream 6s (perfil fluido w=1152 q=46 i=80): frames/taxa reais =="
curl -s -m 6 -H "$H" "http://127.0.0.1:$PORTA_LOCAL/mjpeg?w=1152&q=46&i=80" -o /tmp/tela-teste.mjpg || true
python3 - <<'EOF'
d = open('/tmp/tela-teste.mjpg','rb').read()
n = d.count(b'\xff\xd8')          # SOI: um por frame JPEG
kb = len(d)/1024
print("frames=%d bytes=%.0fKB → %.1f fps · %.0f KB/s · ~%.0f KB/frame" % (
    n, kb, n/6, kb/6, (kb/n if n else 0)))
assert n >= 3, "poucos frames (%d) — stream engasgado" % n
print("OK: stream entregando quadros")
EOF

echo
echo "== /input: latência de resposta (10 moves) =="
T0=$(date +%s%N)
for i in $(seq 10); do
    curl -s -m 5 -X POST -H "$H" -H 'Content-Type: application/json' \
         -d '{"t":"move","x":0.5,"y":0.5}' \
         "http://127.0.0.1:$PORTA_LOCAL/input" -o /dev/null
done
T1=$(date +%s%N)
echo "média: $(( (T1-T0)/10000000 )) ms por evento (meta: < 150ms — sem espera de frame)"
R=$(curl -s -m 5 -X POST -H "$H" -H 'Content-Type: application/json' \
     -d '{"t":"key","k":"F13"}' -o /dev/null -w '%{http_code}' \
     "http://127.0.0.1:$PORTA_LOCAL/input")
[ "$R" = "204" ] && echo "OK: /input tecla → 204 (F13 não existe no mapa: nada digitado)" \
              || { echo "FALHOU: /input tecla → $R"; exit 1; }

echo
echo "== /clip roundtrip (restaura o original no fim) =="
ORIGINAL=$(curl -fsS -m 5 -H "$H" "http://127.0.0.1:$PORTA_LOCAL/clip" || true)
curl -s -m 5 -X POST -H "$H" -H 'Content-Type: text/plain' \
     --data-binary 'suporte-tela-teste-123' \
     "http://127.0.0.1:$PORTA_LOCAL/clip" -o /dev/null
VOLTOU=$(curl -fsS -m 5 -H "$H" "http://127.0.0.1:$PORTA_LOCAL/clip")
if [ "$VOLTOU" = "suporte-tela-teste-123" ]; then
    echo "OK: clipboard escreveu e leu de volta"
else
    echo "FALHOU: clipboard roundtrip → '$VOLTOU'"
fi
curl -s -m 5 -X POST -H "$H" -H 'Content-Type: text/plain' \
     --data-binary "$ORIGINAL" "http://127.0.0.1:$PORTA_LOCAL/clip" -o /dev/null || true
echo "(clipboard original restaurado)"

echo
echo "== stats depois do tráfego =="
curl -fsS -m 5 -H "$H" "http://127.0.0.1:$PORTA_LOCAL/info"; echo

echo
"$BASE/tela.sh" "$ID" parar
echo
echo "TUDO OK — validar no navegador: painel → tela (perfis, cursor, clipboard, tela cheia)"
