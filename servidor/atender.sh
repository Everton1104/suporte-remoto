#!/usr/bin/env bash
# atender.sh — terminal pass-through do técnico na máquina do cliente.
#
# Dois modos:
#   atender.sh <id-cliente> [-c "comando"]            agente permanente
#       porta, usuário e plataforma vêm do registro (servidor/clientes.json)
#   atender.sh <id-sessao> <usuario> [-c "comando"]   sessão única (fluxo efêmero)
#
# O login já vem com privilégio pleno: no Windows, conta de administrador
# recebe token elevado (o OpenSSH do Windows não filtra UAC); no Linux, a
# chave vive no authorized_keys do root. Nada do que roda aqui pede
# confirmação na tela do cliente.
set -euo pipefail

BASE=$(cd "$(dirname "$0")" && pwd)

# --- modo: agente permanente ou sessão única ---
CMD=
if [ $# -ge 2 ] && [ "$2" != "-c" ] && [ -d "$BASE/sessoes/$1" ]; then
    MODO="sessão única"
    ID=$1
    USUARIO=$2
    DIR="$BASE/sessoes/$ID"
    PORTA_REVERSA=10022
    if [ "${3:-}" = -c ]; then CMD=${4:?uso: atender.sh <id-sessao> <usuario> -c "comando"}; fi
else
    MODO="agente"
    ID=${1:?uso: atender.sh <id-cliente> [-c comando]  |  atender.sh <id-sessao> <usuario> [-c comando]}
    DIR="$BASE/clientes/$ID"
    [ -f "$DIR/chave-tecnico" ] || { echo "Cliente '$ID' não encontrado em $BASE/clientes/"; exit 1; }
    MAPA=$(python3 -c "
import json
c = json.load(open('$BASE/clientes.json'))['clientes']['$ID']
print(c['porta'], c.get('usuario') or 'root')")
    PORTA_REVERSA=$(printf '%s' "$MAPA" | awk '{print $1}')
    USUARIO=$(printf '%s' "$MAPA" | awk '{print $2}')
    if [ "${2:-}" = -c ]; then CMD=${3:?uso: atender.sh <id-cliente> -c "comando"}; fi
fi

CHAVE="$DIR/chave-tecnico"
[ -f "$CHAVE" ] || { echo "Sessão $ID não encontrada em $DIR"; exit 1; }

# TOFU por cliente/sessão: cada máquina tem host key própria; guardar na
# pasta certa evita colisão com máquinas anteriores no known_hosts do técnico
OPTS=(-p "$PORTA_REVERSA" -i "$CHAVE"
    -o UserKnownHostsFile="$DIR/known_hosts" -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

if [ -n "$CMD" ]; then
    exec ssh "${OPTS[@]}" "$USUARIO@localhost" "$CMD"
fi

echo "== pré-voo: $MODO $ID -> $USUARIO@localhost:$PORTA_REVERSA =="
# plataforma: "cmd /c echo %OS%" funciona no cmd E no PowerShell (que não
# expande %OS% sozinho — e o DefaultShell do agente é PowerShell); no Linux
# não existe cmd e devolve vazio
PLATAFORMA=$(ssh "${OPTS[@]}" "$USUARIO@localhost" 'cmd /c echo %OS%' 2>/dev/null) || PLATAFORMA=
if [ -z "$PLATAFORMA" ]; then
    echo "!! não conectou — túnel ativo? agente conectado? painel em ordem?" >&2; exit 1
fi
if printf '%s' "$PLATAFORMA" | grep -q Windows_NT; then
    SO=Windows
    # elevação pelo nível de integridade do token: 12288 (High) = admin
    # com token pleno. "net session" parecia o probe natural mas depende do
    # serviço Server/LanmanServer rodar - máquina com ele parado dá falso
    # "sem elevação" (aconteceu em campo, adjundiai11). SID não se traduz,
    # findstr casa em qualquer idioma do Windows. UM padrão só: findstr
    # com dois argumentos soltos trata o segundo como ARQUIVO a abrir
    if ssh "${OPTS[@]}" "$USUARIO@localhost" 'cmd /c "whoami /groups | findstr S-1-16-12288 >nul 2>&1"' >/dev/null 2>&1; then
        NIVEL=ELEVADO
    else
        NIVEL=SEM-ELEVACAO
    fi
else
    SO=Linux
    NIVEL=$(ssh "${OPTS[@]}" "$USUARIO@localhost" 'id -u' 2>/dev/null || true)
    [ "$NIVEL" = 0 ] && NIVEL=ELEVADO || NIVEL=SEM-ELEVACAO
fi
case "$NIVEL" in
    ELEVADO)      echo "== shell elevado ($SO): admin pleno, cliente não é perturbado ==" ;;
    SEM-ELEVACAO) echo "!! sem privilégio — Windows: conta admin / Linux: conectar como root" ;;
    *)            echo "!! resultado inesperado do pré-voo: $NIVEL" ;;
esac
exec ssh "${OPTS[@]}" "$USUARIO@localhost"
