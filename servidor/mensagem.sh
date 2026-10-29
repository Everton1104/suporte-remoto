#!/usr/bin/env bash
# mensagem.sh — popup com botão OK na tela do cliente (sessão console).
#
# Uso:   mensagem.sh <id-cliente> <texto da mensagem...>
# Ex.:   mensagem.sh adjundiai87-e5f9 Bom dia, vou reiniciar em 10 minutos
#
# Usa o msg.exe do Windows: caixa simples na sessão logada, o usuário
# fecha clicando em OK. /time:3600 mantém a caixa na tela até 1h
# aguardando o clique. Acentos chegam embolados (codepage do cmd) —
# escreva sem acento. Só Windows.
set -euo pipefail

BASE=$(cd "$(dirname "$0")" && pwd)

ID=${1:?uso: mensagem.sh <id-cliente> <texto da mensagem>}
shift
TEXTO=${*:?uso: mensagem.sh <id-cliente> <texto da mensagem>}

bash "$BASE/atender.sh" "$ID" -c "msg console /time:3600 $TEXTO"
