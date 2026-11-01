#!/usr/bin/env bash
# testar-operador.sh — E2E do modo OPERADOR (botão "claude (servidor)"), sem
# Windows e sem gastar sessão do claude: página do operador, avisar.sh →
# banner no /painel/dados, watch-online.sh disparado pelo poll do agente,
# dedup de watcher e poda do avisos.jsonl. Assume o web.py rodando em
# 127.0.0.1:8090 (serviço suporte-web). A sessão claude de verdade (spawn,
# stream, resume) fica fora do teste de rotina — é validada na mão.
set -uo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
URL=${URL:-http://127.0.0.1:8090}
WORK=$(mktemp -d /tmp/teste-operador.XXXXXX)

falhar() {
  echo "FALHOU: $1"
  [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
  [ -f "$BASE/avisos.jsonl.teste-bak" ] && { mv "$BASE/avisos.jsonl.teste-bak" \
      "$BASE/avisos.jsonl" 2>/dev/null || rm -f "$BASE/avisos.jsonl"; }
  [ -n "${CID:-}" ] && for i in 1 2; do curl -fsS -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"token\":\"${TOKEN:-}\",\"id\":\"$CID\",\"acao\":\"remover\"}" \
      "$URL/painel/acao" >/dev/null 2>&1; done
  rm -rf "$WORK"; exit 1
}

curl -fsS "$URL/" -o /dev/null || falhar "web.py não responde em $URL"
[ -f "$BASE/avisos.jsonl" ] && cp -a "$BASE/avisos.jsonl" "$BASE/avisos.jsonl.teste-bak"

# 1) avisar.sh → aviso visível no /painel/dados
bash "$BASE/avisar.sh" "aviso de teste OPERADOR_$(date +%s)" || falhar "avisar.sh"
AVIS=$(curl -fsS "$URL/painel/dados?token=$(python3 -c "import json;print(json.load(open('$BASE/clientes.json'))['token_painel'])")")
echo "$AVIS" | grep -q "aviso de teste OPERADOR_" || falhar "aviso não apareceu no /painel/dados"

# 2) página do operador: xterm + título 'servidor'; sem claude=1 não existe
TOKEN=$(python3 -c "import json;print(json.load(open('$BASE/clientes.json'))['token_painel'])")
curl -fsS "$URL/painel/term?cid=__operador__&claude=1&token=$TOKEN" \
  | grep -q "xterm.js" || falhar "página do operador"
curl -fsS "$URL/painel/term?cid=__operador__&claude=1&token=$TOKEN" \
  | grep -q "operador=cid==='__operador__'" || falhar "JS do operador ausente"
curl -s -o /dev/null -w '%{http_code}' "$URL/painel/term?cid=__operador__&token=$TOKEN" \
  | grep -q 404 || falhar "operador sem claude=1 deveria ser 404"

# 3) cliente de teste (registro real; sem túnel — watcher só olha o registro)
ssh-keygen -q -t ed25519 -N '' -f "$WORK/chave" -C teste-operador
R=$(curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"nome\":\"teste-operador\",\
\"maquina\":\"$(hostname)\",\"so\":\"linux\",\"usuario\":\"root\",\
\"chave_tunel\":\"$(cat "$WORK/chave.pub")\"}" "$URL/agente/registrar") || falhar "registrar"
CID=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
# nasce online; envelhece o contato pra ficar offline (transição de verdade)
python3 - "$BASE/clientes.json" "$CID" <<'EOF'
import datetime, json, os, sys
arq, cid = sys.argv[1:]
reg = json.load(open(arq))
reg["clientes"][cid]["ultimo_contato"] = \
    (datetime.datetime.now() - datetime.timedelta(minutes=5)).isoformat(timespec="seconds")
# atômico igual ao salvar() do web.py: escrita direta deixava o arquivo
# truncado por um instante e o /painel/dados dava 500 (lista some no painel)
tmp = arq + ".tmp"
json.dump(reg, open(tmp, "w"), indent=1, sort_keys=True)
os.replace(tmp, arq)
EOF

# 4) watcher: dispara quando o "agente" volta a pollar (/agente/estado)
nohup bash "$BASE/watch-online.sh" "$CID" > "$WORK/watch.log" 2>&1 &
WPID=$!
sleep 2
grep -q "vigando" "$WORK/watch.log" || falhar "watcher não nasceu: $(cat "$WORK/watch.log")"
# dedup: segunda chamada com o mesmo cliente vivo não duplica
DUP=$(bash "$BASE/watch-online.sh" "$CID" 2>&1)
echo "$DUP" | grep -q "já há watcher" || falhar "dedup do watcher: $DUP"
# agente acorda → online → aviso
curl -fsS "$URL/agente/estado?id=$CID" >/dev/null || falhar "poll do agente"
OK=0
for i in $(seq 1 8); do
  sleep 5
  grep -q "$CID) ficou online" "$BASE/avisos.jsonl" && OK=1 && break
done
[ "$OK" = 1 ] || falhar "watcher não avisou (log: $(cat "$WORK/watch.log"))"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=

# 5) poda do avisos.jsonl: >400 linhas → fica com as últimas 150
python3 - "$BASE/avisos.jsonl" <<'EOF'
import datetime, json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for i in range(450):
        f.write(json.dumps({"quando": "2020-01-01T00:%02d:%02d" % (i // 60, i % 60),
                            "texto": "poda %d" % i}) + "\n")
EOF
curl -fsS "$URL/painel/dados?token=$TOKEN" >/dev/null || falhar "dados com avisos grandes"
[ "$(wc -l < "$BASE/avisos.jsonl")" -eq 150 ] || falhar "poda: $(wc -l < "$BASE/avisos.jsonl") linhas"

# 6) desmonta: cliente de teste embora (pendente + forçado) e avisos originais
for i in 1 2; do curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"token\":\"$TOKEN\",\"id\":\"$CID\",\"acao\":\"remover\"}" \
  "$URL/painel/acao" >/dev/null || falhar "remover ($i)"; done
python3 -c "import json,sys;sys.exit(0 if '$CID' not in json.load(open('$BASE/clientes.json'))['clientes'] else 1)" \
  || falhar "cliente de teste ficou no registro"
if [ -f "$BASE/avisos.jsonl.teste-bak" ]; then
  mv "$BASE/avisos.jsonl.teste-bak" "$BASE/avisos.jsonl"
else
  rm -f "$BASE/avisos.jsonl"
fi
rm -rf "$WORK" /tmp/suporte-watch-$CID.pid
echo "OK: operador E2E (página + avisar.sh → painel + watcher online + dedup + poda)"
