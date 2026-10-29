#!/usr/bin/env bash
# atualizar-espelho.sh — traz as últimas versões (cloudflared + OpenSSH) para
# servidor/static/ e regrava versoes.json. É o script que o painel manda rodar
# quando aparece o aviso de atualização (checagem a cada 6h + botão no painel).
set -euo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
ST="$BASE/static"
UA='suporte-remoto-espelho'

tag(){ curl -fsSL -H "User-Agent: $UA" "$1" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; print(d["tag_name"])'; }
baixa(){ # url destino
    curl -fsSL -o "$2.tmp" "$1"
    [ "$(stat -c%s "$2.tmp")" -ge 5000000 ] || { rm -f "$2.tmp"; echo "  $2: baixou truncado!" >&2; exit 1; }
    mv "$2.tmp" "$2"; echo "  $(basename "$2") ok ($(stat -c%s "$2") bytes)"
}

echo "== cloudflared =="
CF=$(tag https://api.github.com/repos/cloudflare/cloudflared/releases/latest)
echo "última: $CF"
baixa "https://github.com/cloudflare/cloudflared/releases/download/$CF/cloudflared-windows-amd64.exe" "$ST/cloudflared-windows-amd64.exe"
baixa "https://github.com/cloudflare/cloudflared/releases/download/$CF/cloudflared-linux-amd64"      "$ST/cloudflared-linux-amd64"
baixa "https://github.com/cloudflare/cloudflared/releases/download/$CF/cloudflared-linux-arm64"      "$ST/cloudflared-linux-arm64"
chmod +x "$ST"/cloudflared-linux-*

echo "== OpenSSH (Windows) =="
OS=$(tag 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases?per_page=1')
echo "última: $OS"
baixa "https://github.com/PowerShell/Win32-OpenSSH/releases/download/$OS/OpenSSH-Win64.zip" "$ST/openssh-win64.zip"

python3 - "$CF" "$OS" "$ST/versoes.json" <<'PY'
import json, sys
versoes = {"cloudflared": sys.argv[1], "openssh": sys.argv[2]}
with open(sys.argv[3], "w") as f:
    json.dump(versoes, f, indent=1)
print("versoes.json:", versoes)
PY

echo
echo "Espelho atualizado. Para limpar o aviso do painel, clique em"
echo "'procurar atualização' (a checagem automática também roda a cada 6h)."
