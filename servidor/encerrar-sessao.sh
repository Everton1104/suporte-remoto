#!/usr/bin/env bash
# encerrar-sessao.sh — revoga a chave de uma sessão (remove do authorized_keys)
set -euo pipefail
[ $# -eq 1 ] || { echo "uso: $0 <id-da-sessao>"; exit 1; }
ID=$1
AK=/home/suporte/.ssh/authorized_keys
sed -i "/sessao:$ID/d" "$AK"
echo "Chave da sessão $ID revogada."
