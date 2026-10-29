#!/usr/bin/env bash
# pergunta.sh — caixa de pergunta (input) na tela do cliente; a resposta
# digitada volta para o terminal do técnico.
#
# Uso:   pergunta.sh <id-cliente> <pergunta...>
# Ex.:   pergunta.sh adjundiai87-e5f9 Em que horario posso reiniciar a maquina?
#
# Como funciona: processo criado via SSH nasce na sessao 0 (sem UI), então
# o helper sobe um .ps1 por scp e o dispara como tarefa agendada interativa
# (schtasks /it), que roda na sessao logada. O .ps1 abre um InputBox
# (OK/Cancelar) e grava a resposta em C:\Users\Public; o helper espera
# (max 5 min), baixa por scp e mostra. Acentos ok na pergunta e na
# resposta. Só Windows, exige alguém logado na tela.
set -euo pipefail

BASE=$(cd "$(dirname "$0")" && pwd)
ID=${1:?uso: pergunta.sh <id-cliente> <pergunta...>}
shift
PERGUNTA=${*:?uso: pergunta.sh <id-cliente> <pergunta...>}
PERGUNTA=${PERGUNTA//\'/\'\'}   # escape de aspas simples pro PowerShell

MAPA=$(python3 -c "
import json
c = json.load(open('$BASE/clientes.json'))['clientes']['$ID']
print(c['porta'], c.get('usuario') or 'root')")
PORTA=$(printf '%s' "$MAPA" | awk '{print $1}')
USUARIO=$(printf '%s' "$MAPA" | awk '{print $2}')
CHAVE="$BASE/clientes/$ID/chave-tecnico"
KHOST="-o UserKnownHostsFile=$BASE/clientes/$ID/known_hosts"
ATENDER="bash $BASE/atender.sh $ID"

PS1_LOCAL=$(mktemp /tmp/suporte-pergunta.XXXXXX.ps1)
RESP_LOCAL=$(mktemp /tmp/suporte-resposta.XXXXXX.txt)
trap 'rm -f "$PS1_LOCAL" "$RESP_LOCAL"' EXIT
{
    printf '\xEF\xBB\xBF'   # BOM: PS 5.1 so respeita acentos com BOM
    cat <<EOF
Add-Type -AssemblyName Microsoft.VisualBasic
\$r = [Microsoft.VisualBasic.Interaction]::InputBox('$PERGUNTA', 'Suporte Remoto')
if ([string]::IsNullOrEmpty(\$r)) { \$r = '(sem resposta / cancelado)' }
Set-Content -Path 'C:\Users\Public\suporte-resposta.txt' -Value \$r -Encoding UTF8
EOF
} > "$PS1_LOCAL"

scp -q -P "$PORTA" -i "$CHAVE" $KHOST \
    "$PS1_LOCAL" "$USUARIO@localhost:C:/Users/Public/suporte-pergunta.ps1"

# limpa resposta anterior e dispara a tarefa interativa na sessao logada
$ATENDER -c 'del C:\Users\Public\suporte-resposta.txt -ErrorAction SilentlyContinue ; schtasks /create /tn SuporteRemotoPergunta /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\Public\suporte-pergunta.ps1" /sc once /st 23:59 /it /f ; schtasks /run /tn SuporteRemotoPergunta'

echo ">> Pergunta na tela do cliente. Aguardando resposta (max 5 min)..." >&2

# espera a resposta (o loop dorme no cliente, nao aqui)
if $ATENDER -c "\$f='C:\Users\Public\suporte-resposta.txt'; \$t=300; while(-not(Test-Path \$f) -and \$t -gt 0){Start-Sleep 2; \$t-=2}; if(Test-Path \$f){exit 0}else{exit 1}"; then
    scp -q -P "$PORTA" -i "$CHAVE" $KHOST \
        "$USUARIO@localhost:C:/Users/Public/suporte-resposta.txt" "$RESP_LOCAL"
    sed -i '1s/^\xEF\xBB\xBF//' "$RESP_LOCAL"   # tira BOM do UTF8 do PS
    echo ">> Resposta: $(cat "$RESP_LOCAL")"
else
    echo ">> Sem resposta em 5 min (ninguem clicou?)." >&2
    EXIT_OK=1
fi

# limpeza no cliente (tarefa + arquivos)
$ATENDER -c 'schtasks /delete /tn SuporteRemotoPergunta /f ; del C:\Users\Public\suporte-pergunta.ps1 -ErrorAction SilentlyContinue ; del C:\Users\Public\suporte-resposta.txt -ErrorAction SilentlyContinue' >/dev/null
exit "${EXIT_OK:-0}"
