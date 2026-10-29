#!/usr/bin/env bash
# testar-tunel.sh — teste LOCAL da camada de conexão, sem Cloudflare e sem Windows:
# simula o cliente abrindo o túnel reverso e confere que a porta 10022 responde
# do outro lado. No teste o "cliente" devolve a conexão para o próprio sshd
# (localhost:2222); em produção apontaria para o OpenSSH do Windows (localhost:22).
# uso: testar-tunel.sh <dir-da-sessao>
set -euo pipefail
DIR=${1:?uso: testar-tunel.sh <dir-da-sessao>}
PORTA_SSH=2222
PORTA_REVERSA=10022

# "cliente": abre o túnel reverso em segundo plano (o que o .bat faz no Windows)
ssh -N -R "${PORTA_REVERSA}:localhost:${PORTA_SSH}" \
    -i "$DIR/chave-cliente" -p "$PORTA_SSH" \
    -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
    suporte@localhost &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
sleep 2

# "tecnico": conecta na porta reversa e lê o banner SSH que vem do cliente
BANNER=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORTA_REVERSA}; head -c 20 <&3" || true)

if [[ "$BANNER" == SSH-* ]]; then
    echo "OK: túnel reverso funcionando (banner recebido: $BANNER)"
    exit 0
else
    echo "FALHOU: nada respondeu na porta $PORTA_REVERSA"
    exit 1
fi
