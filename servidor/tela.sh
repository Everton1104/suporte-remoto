#!/usr/bin/env bash
# tela.sh — sobe/derruba o servidor de tela (MJPEG + controle de mouse/
# teclado) no cliente Windows e o traz pra uma porta local do servidor
# pelo túnel reverso que já existe.
#
# uso:   tela.sh <id-cliente> subir|parar|pronto
# porta local do servidor = porta reversa do cliente + 20000 (30023+)
set -euo pipefail

BASE=$(cd "$(dirname "$0")" && pwd)
ID=${1:?uso: tela.sh <id-cliente> subir|parar|pronto}
ACAO=${2:?uso: tela.sh <id-cliente> subir|parar|pronto}

MAPA=$(python3 -c "
import json
c = json.load(open('$BASE/clientes.json'))['clientes']['$ID']
print(c['porta'], c.get('usuario') or 'root')")
PORTA=$(printf '%s' "$MAPA" | awk '{print $1}')
USUARIO=$(printf '%s' "$MAPA" | awk '{print $2}')
PORTA_LOCAL=$((PORTA + 20000))
CHAVE="$BASE/clientes/$ID/chave-tecnico"
KHOST="-o UserKnownHostsFile=$BASE/clientes/$ID/known_hosts"
KSSH="-o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
ATENDER="bash $BASE/atender.sh $ID"
PIDF="$BASE/clientes/$ID/tela-ssh.pid"

case "$ACAO" in

subir)
    # serializa subir/parar por cliente: o timeout de 90s do web.py mata so o
    # wrapper python e o bash daqui segue ORFAO — completa scp/tarefa DEPOIS,
    # competindo com o subir seguinte (Set-Content da instancia nova trunca o
    # log da velha, http.sys entrega o viewer pra instancia errada = stream
    # 200 sem quadro nenhum). flock sai sozinho quando o orfao morrer.
    exec 9>>"$BASE/clientes/$ID/tela.lock"
    flock -w 75 9 || { echo "FALHOU: outro tela.sh deste cliente rodando" >&2; exit 1; }
    # mata instancia anterior (tarefa de sessao passada pode ter deixado
    # powershell vivo segurando a porta) e sobe o .ps1 na sessao logada:
    # captura/injecao SO funcionam fora da sessao 0. /ru Interactive roda
    # COMO o usuario logado na tela (usuario do tunel costuma ser outro —
    # sem isso a tarefa /it nunca dispara); fallback sem /ru se o sistema
    # recusar. -ne $PID: o kill abaixo casaria com ESTA sessao (a linha de
    # comando contem 'suporte-tela.ps1') e se mataria (exit 255 silencioso).
    # Add-MpPreference: o AMSI do Defender barra o script (captura+HTTP =
    # assinatura de spyware de tela, mesmo sem injecao) — exclusao deste
    # arquivo, autorizada pelo tecnico (dono da frota) em 29/10; em AV nao
    # Defender o cmdlet nao existe e o erro e engolido
    scp -q -P "$PORTA" -i "$CHAVE" $KHOST \
        "$BASE/tela.ps1" "$USUARIO@localhost:C:/Users/Public/suporte-tela.ps1"
    $ATENDER -c "Add-MpPreference -ExclusionPath 'C:\Users\Public\suporte-tela.ps1' >\$null 2>&1; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object {\$_.CommandLine -like '*suporte-tela.ps1*' -and \$_.ProcessId -ne \$PID} | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force } >\$null 2>&1; \$tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\Public\suporte-tela.ps1'; schtasks /create /tn SuporteRemotoTela /tr \$tr /sc once /st 23:59 /it /ru Interactive /f >\$null 2>&1; if (\$LASTEXITCODE -ne 0) { schtasks /create /tn SuporteRemotoTela /tr \$tr /sc once /st 23:59 /it /f >\$null 2>&1 }; schtasks /run /tn SuporteRemotoTela" >/dev/null

    # encaminhamento persistente: porta local do servidor -> listener no
    # cliente (localhost:28090 — o Host tem que bater com o prefixo do
    # HttpListener, que roda sem privilegio so em localhost). Forward velho
    # de um subir anterior segura a porta local e responde pelo listener ja
    # morto: derruba ANTES — com ExitOnForwardFailure o ssh novo morreria
    # calado sem conseguir bindar.
    pkill -f -- "-L 127.0.0.1:${PORTA_LOCAL}:localhost:28090" 2>/dev/null || true
    ssh -N $KSSH $KHOST -i "$CHAVE" -p "$PORTA" \
        -L "127.0.0.1:${PORTA_LOCAL}:localhost:28090" "$USUARIO@localhost" \
        >/dev/null 2>&1 &
    echo $! > "$PIDF"

    # espera o LISTENER responder de verdade (probe HTTP: o socket do ssh -L
    # aceita conexao mesmo com o cliente la atras morto — e exit 0 do curl
    # aceita QUALQUER resposta, ate erro; so JSON comeca com '{')
    for _ in $(seq 40); do
        resp=$(curl -s -m 2 -H 'Host: localhost:28090' \
                "http://127.0.0.1:$PORTA_LOCAL/info" 2>/dev/null) || true
        case "$resp" in
            '{'*) echo "tela no ar: 127.0.0.1:$PORTA_LOCAL (cid=$ID)"
                  exit 0;;
        esac
        sleep 0.5
    done
    echo "FALHOU: tela no ar nao respondeu (tarefa /it sobe? alguem logado?)" >&2
    "$0" "$ID" parar >&2 || true
    exit 1
    ;;

parar)
    # encerra o servidor no cliente pelo proprio encaminhamento (204 e sai)
    curl -s -m 3 -X POST "http://127.0.0.1:$PORTA_LOCAL/sair" \
        -H "Host: localhost:28090" >/dev/null 2>&1 || true
    [ -f "$PIDF" ] && { kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; }
    pkill -f -- "-L 127.0.0.1:${PORTA_LOCAL}:localhost:28090" 2>/dev/null || true
    # higiene no cliente: tarefa, processo e arquivos
    $ATENDER -c "schtasks /delete /tn SuporteRemotoTela /f >\$null 2>&1; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object {\$_.CommandLine -like '*suporte-tela.ps1*' -and \$_.ProcessId -ne \$PID} | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force } >\$null 2>&1; Remove-Item C:\Users\Public\suporte-tela.ps1, C:\Users\Public\suporte-tela.log -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
    echo "tela encerrada (cid=$ID)"
    ;;

pronto)
    (echo > /dev/tcp/127.0.0.1/"$PORTA_LOCAL") 2>/dev/null \
        && echo "sim: 127.0.0.1:$PORTA_LOCAL" || { echo "nao"; exit 1; }
    ;;

esac
