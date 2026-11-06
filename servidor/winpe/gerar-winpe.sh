#!/usr/bin/env bash
# gerar-winpe.sh — renderiza o instalador do modo WinPE (Hiren's BootCD PE):
#   * par de chaves DEDICADO ao modo WinPE (a publica vai no .bat, a privada
#     fica aqui e conecta DIRETO no sshd da maquina WinPE pela LAN — sem
#     cloudflared, sem tunel reverso; atender.sh nao se aplica)
#   * .bat pronto com CRLF (pegadinha do cmd.exe), publicado no espelho
#     /arquivos/suporte-winpe.bat
# uso: ./gerar-winpe.sh        (regenerar a chave: rm chave-tecnico* e rode de novo)
set -euo pipefail

BASE=$(cd "$(dirname "$0")" && pwd)
URL_BASE=${URL_BASE:-https://suporte.evertonrs.com.br}
ID="winpe-$(date +%Y%m%d)"

# par de chaves fixo do modo WinPE (rotacionavel apagando os arquivos)
if [ ! -f "$BASE/chave-tecnico" ]; then
    echo "== gerando par de chaves dedicado do modo WinPE =="
    ssh-keygen -q -t ed25519 -N '' -C "suporte:winpe" -f "$BASE/chave-tecnico"
fi
chmod 600 "$BASE/chave-tecnico"

PUBKEY=$(cat "$BASE/chave-tecnico.pub")

# integridade do zip: o .bat compara com Get-FileHash no WinPE
# (download corrompido = exe quebrado = 0xc0000142)
ZIP="$BASE/../static/openssh-winpe-v95.zip"
[ -f "$ZIP" ] || { echo "ERRO: $ZIP ausente ( rode atualizar-espelho.sh )"; exit 1; }
SHA=$(sha256sum "$ZIP" | awk '{print $1}')

sed -e "s|__URL_BASE__|$URL_BASE|g" \
    -e "s|__PUBKEY_TECNICO__|$PUBKEY|" \
    -e "s|__ID__|$ID|g" \
    -e "s|__SHA256_ZIP__|$SHA|" \
    "$BASE/template-winpe.bat" \
  | sed 's/$/\r/' > "$BASE/suporte-winpe.bat"

cp "$BASE/suporte-winpe.bat" "$BASE/../static/suporte-winpe.bat"
echo "== ok: static/suporte-winpe.bat ($ID, $(wc -c < "$BASE/suporte-winpe.bat") bytes) =="
echo "== conectar do servidor: ssh -i $BASE/chave-tecnico Administrator@<ip-do-winpe> =="
