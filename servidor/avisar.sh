#!/usr/bin/env bash
# avisar.sh — mostra um AVISO no painel do técnico (banner 🔔 no topo, junto
# do poll de 5s). Quem usa: watchers (watch-online.sh), manutenção, e o
# claude operador — qualquer coisa que precise cutucar o técnico sem ele
# estar olhando uma conversa.
# uso: avisar.sh <texto...>
set -euo pipefail
BASE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[ $# -ge 1 ] || { echo "uso: avisar.sh <texto...>"; exit 1; }
python3 - "$BASE/avisos.jsonl" "$*" <<'EOF'
import datetime, fcntl, json, sys
with open(sys.argv[1], "a", encoding="utf-8") as f:
    fcntl.flock(f, fcntl.LOCK_EX)          # watchers em paralelo não se pisam
    f.write(json.dumps({"quando": datetime.datetime.now().isoformat(timespec="seconds"),
                        "texto": sys.argv[2][:300]}, ensure_ascii=False) + "\n")
EOF
