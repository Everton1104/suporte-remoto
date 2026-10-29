#!/usr/bin/env bash
# testar-linux.sh — E2E LOCAL do cliente Linux: este próprio Debian faz o papel
# do cliente (o sshd :2222 é o "sshd do cliente"; ssh direto, sem cloudflared).
# Roda o instalador .sh de verdade: gera sessão -> instala chave no root ->
# abre túnel reverso -> técnico conecta com a chave efêmera -> encerra pelo
# flag -> confere que a limpeza desfaz tudo. Precisa rodar como root.
set -uo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
PORTA_REVERSA=10022
AK=/root/.ssh/authorized_keys
LOG=/tmp/suporte-teste-linux.log

[ "$(id -u)" = 0 ] || { echo "rode como root"; exit 1; }
"$BASE/setup-sshd.sh" >/dev/null 2>&1 || true

porta_aberta() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

falhar() { echo "FALHOU: $1"; echo "--- log do cliente ($LOG):"; tail -30 "$LOG" 2>/dev/null; exit 1; }

# 1) sessão nova apontando pra cá (sem Cloudflare)
DOMINIO=127.0.0.1 "$BASE/gerar-sessao.sh" teste-linux >/dev/null || falhar "gerar-sessao.sh"
ID=$(basename "$(cat "$BASE/sessoes/.ultima")")
DIR="$BASE/sessoes/$ID"
INSTALADOR="$DIR/suporte-$ID.sh"
[ -f "$INSTALADOR" ] || falhar "instalador .sh não gerado"

# 2) backup do authorized_keys do root para comparar depois
[ -f "$AK" ] && cp -a "$AK" "$AK.teste-linux-bak"

# 3) cliente: roda o instalador de verdade (sai pelo flag do técnico)
SUPORTE_SEM_CLOUDFLARED=1 SUPORTE_PORTA_SSHD=2222 bash "$INSTALADOR" >"$LOG" 2>&1 &
CPID=$!

# 4) túnel reverso aberto?
for i in $(seq 1 20); do porta_aberta "$PORTA_REVERSA" && break; sleep 1; done
porta_aberta "$PORTA_REVERSA" || falhar "porta $PORTA_REVERSA não abriu"

# 5) técnico: comando pela chave efêmera (pass-through admin)
RES=$("$BASE/atender.sh" "$ID" root -c 'id -u' 2>/dev/null) || RES=x
[ "$RES" = "0" ] || falhar "técnico não conseguiu shell root (retornou: $RES)"

# 6) técnico encerra via flag (como documentado no README)
mkdir -p /var/lib/suporte-remoto
echo fim > /var/lib/suporte-remoto/encerrar
for i in $(seq 1 20); do kill -0 "$CPID" 2>/dev/null || break; sleep 1; done
kill -0 "$CPID" 2>/dev/null && { kill "$CPID"; falhar "instalador não saiu com o flag"; }

# 7) limpeza confere?
porta_aberta "$PORTA_REVERSA" && falhar "porta $PORTA_REVERSA continua aberta"
grep -q "sessao:$ID:tecnico" "$AK" 2>/dev/null && falhar "chave do técnico ficou no authorized_keys do root"
if [ -f "$AK.teste-linux-bak" ]; then
    grep -v 'sessao:' "$AK.teste-linux-bak" > /tmp/ak-esperado || true
    if [ -e "$AK" ]; then
        cmp -s "$AK" /tmp/ak-esperado || falhar "authorized_keys do root ficou diferente do original"
    else
        [ -s /tmp/ak-esperado ] && falhar "authorized_keys do root sumiu com conteúdo original dentro"
    fi
else
    [ ! -e "$AK" ] || falhar "authorized_keys do root foi criado e não removido"
fi
rm -f "$AK.teste-linux-bak" /tmp/ak-esperado

# 8) revoga a chave do túnel no servidor
"$BASE/encerrar-sessao.sh" "$ID" >/dev/null
echo "OK: cliente Linux E2E (instalador -> túnel -> shell root -> flag -> limpeza)"
