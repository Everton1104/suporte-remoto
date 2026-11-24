#!/usr/bin/env bash
# atualizar-espelho.sh — traz as últimas versões (cloudflared + OpenSSH + curl
# + .deb da tela Linux) para servidor/static/ e regrava versoes.json. É o
# script que o painel manda rodar quando aparece o aviso de atualização
# (checagem a cada 6h + botão no painel). `--debs` roda só a parte .deb (sem
# re-baixar os binários grandes).
set -euo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
ST="$BASE/static"
UA='suporte-remoto-espelho'
SOMENTE_DEBS=0
[ "${1:-}" = "--debs" ] && SOMENTE_DEBS=1

tag(){ curl -fsSL -H "User-Agent: $UA" "$1" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; print(d["tag_name"])'; }
baixa(){ # url destino
    curl -fsSL -o "$2.tmp" "$1"
    [ "$(stat -c%s "$2.tmp")" -ge 5000000 ] || { rm -f "$2.tmp"; echo "  $2: baixou truncado!" >&2; exit 1; }
    mv "$2.tmp" "$2"; echo "  $(basename "$2") ok ($(stat -c%s "$2") bytes)"
}

if [ "$SOMENTE_DEBS" -eq 0 ]; then

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

fi

# ===== .deb para clientes Linux (tela: encoder JPEG do tela-linux.py) =====
# O servidor é arm64 e os clientes amd64 — apt-get download aqui traria a
# arquitetura errada. Baixa direto do pool do Debian pela URL do índice
# Packages (binary-amd64): versão, nome do arquivo e sha256 saem do próprio
# índice; a checagem do web.py é um HEAD neste índice (Last-Modified mudou =
# repositório mudou = aviso no painel; barato e sem parse de versão).
# Suites alvo = as que a frota usa (trixie=Debian 13, bookworm=Debian 12).
# A instalação no cliente é cirúrgica: só os pacotes que lá faltam.
echo "== .deb tela Linux =="
DEBS="python3-pil libjpeg62-turbo liblcms2-2 libwebpdemux2 libwebpmux3 libtiff6 libfreetype6"
for SUITE in trixie bookworm; do
    DIR="$ST/deb/$SUITE-amd64"
    IDX="$ST/deb/Packages-$SUITE-amd64.gz"
    mkdir -p "$DIR"
    if ! curl -fsSL -o "$IDX" "https://deb.debian.org/debian/dists/$SUITE/main/binary-amd64/Packages.gz"; then
        echo "  $SUITE: índice Packages indisponível (pulando)" >&2
        continue
    fi
    # Last-Modified do índice = impressão digital do repositório nesta data;
    # o web.py checa por HEAD e compara com o que está aqui
    curl -fsSI "https://deb.debian.org/debian/dists/$SUITE/main/binary-amd64/Packages.gz" \
        | grep -i '^last-modified:' | cut -d' ' -f2- | tr -d '\r' > "$DIR/indice-lm"
    python3 - "$IDX" "$DIR" $DEBS <<'PY'
import gzip, hashlib, os, subprocess, sys
idx, dir = sys.argv[1], sys.argv[2]
pacs = sys.argv[3:]
info = {}
for stanza in gzip.open(idx, "rt", errors="replace").read().split("\n\n"):
    d = dict(l.split(": ", 1) for l in stanza.splitlines() if ": " in l)
    if d.get("Package") in pacs and d.get("Architecture") in ("amd64", "all"):
        info.setdefault(d["Package"], d)
falta = [p for p in pacs if p not in info]
if falta:
    sys.exit("  %s: fora do índice: %s" % (os.path.basename(dir), falta))
versao = ""
for p in pacs:
    d = info[p]
    nome = os.path.basename(d["Filename"])
    arq = os.path.join(dir, nome)
    subprocess.run(["curl", "-fsSL", "-o", arq + ".tmp",
                    "https://deb.debian.org/debian/" + d["Filename"]], check=True)
    if hashlib.sha256(open(arq + ".tmp", "rb").read()).hexdigest() != d["SHA256"]:
        sys.exit("  %s: sha256 NÃO confere" % p)
    os.rename(arq + ".tmp", arq)
    print("  %s/%s ok (%s bytes)" % (os.path.basename(dir), nome,
                                     os.path.getsize(arq)))
    if p == "python3-pil":
        versao = d["Version"]
open(os.path.join(dir, "versao"), "w").write(versao)
PY
done

PARES=()
[ "$SOMENTE_DEBS" -eq 0 ] && PARES+=("cloudflared=$CF" "openssh=$OS" "curl=$CURLV")
for SUITE in trixie bookworm; do
    [ -f "$ST/deb/$SUITE-amd64/versao" ] && PARES+=("deb-$SUITE=$(cat "$ST/deb/$SUITE-amd64/versao")")
done
python3 - "$ST/versoes.json" "${PARES[@]}" <<'PY'
import json, sys
try:
    versoes = json.load(open(sys.argv[1]))
except Exception:
    versoes = {}
for par in sys.argv[2:]:
    k, v = par.split("=", 1)
    versoes[k] = v
with open(sys.argv[1], "w") as f:
    json.dump(versoes, f, indent=1)
print("versoes.json:", versoes)
PY

echo
echo "== claude CLI deste Termux (o cérebro do operador) =="
# junto do espelho por pedido do Everton (24/11): uma rotina só atualiza
# tudo do servidor. `claude update` resolve a instalação (npm global aqui);
# timeout 5min aguenta rede lenta sem pendurar a rotina; falha não derruba
# o resto — sessões abertas seguem na versão em memória, a nova vale pra
# próximas.
if command -v claude >/dev/null 2>&1; then
    echo "  antes: $(claude --version 2>/dev/null | head -1)"
    if timeout 300 claude update; then
        echo "  depois: $(claude --version 2>/dev/null | head -1)"
    else
        echo "  claude update falhou (rc=$?) — atualize à mão" >&2
    fi
else
    echo "  claude não está no PATH" >&2
fi

echo
echo "Espelho atualizado. Rodando pelo painel (botão 'atualizar agora') o aviso"
echo "sai sozinho; pelo terminal, clique em 'procurar atualização' para limpar."
echo "Publicar no servidor ativo: bash servidor/sincronizar-espelho.sh"
