#!/usr/bin/env bash
# atualizar-espelho.sh — traz as últimas versões (cloudflared + OpenSSH + curl) para
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

echo "== curl (Windows) =="
# bootstrap do instalador (máquinas Win < 1803 chegam sem curl). Versão
# PINADA: o layout do zip do curl.se muda sem aviso — subir de versão é
# trocar CURLV aqui e conferir que o exe saiu no nome esperado. O exe é
# estático (não precisa da libcurl-x64.dll) mas é build LibreSSL: o bundle
# CA do Mozilla vem separado porque ele não usa o store do Windows.
CURLV=8.23.0_6
curl -fsSL -o "$ST/curl-win64.zip" "https://curl.se/windows/dl-${CURLV}/curl-${CURLV}-win64-mingw.zip"
python3 - "$ST/curl-win64.zip" "$ST/curl.exe" <<'PY'
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1])
exe = [n for n in z.namelist() if n.endswith("/bin/curl.exe")][0]
open(sys.argv[2], "wb").write(z.read(exe))
PY
rm -f "$ST/curl-win64.zip"
[ "$(stat -c%s "$ST/curl.exe")" -ge 3000000 ] || { echo "  curl.exe saiu truncado!" >&2; exit 1; }
echo "  curl.exe ok ($(stat -c%s "$ST/curl.exe") bytes)"
curl -fsSL -o "$ST/curl-ca-bundle.crt" https://curl.se/ca/cacert.pem
[ "$(stat -c%s "$ST/curl-ca-bundle.crt")" -ge 100000 ] || { echo "  curl-ca-bundle.crt saiu truncado!" >&2; exit 1; }
echo "  curl-ca-bundle.crt ok ($(stat -c%s "$ST/curl-ca-bundle.crt") bytes)"

python3 - "$CF" "$OS" "$CURLV" "$ST/versoes.json" <<'PY'
import json, sys
versoes = {"cloudflared": sys.argv[1], "openssh": sys.argv[2], "curl": sys.argv[3]}
with open(sys.argv[4], "w") as f:
    json.dump(versoes, f, indent=1)
print("versoes.json:", versoes)
PY

echo
echo "Espelho atualizado. Para limpar o aviso do painel, clique em"
echo "'procurar atualização' (a checagem automática também roda a cada 6h)."
