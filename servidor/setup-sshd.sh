#!/usr/bin/env bash
# setup-sshd.sh — instala e endurece o servidor SSH do projeto neste Debian (proot).
# Porta 2222, login só por chave, usuário dedicado "suporte"
# (que só pode abrir túnel reverso — nunca ganha shell).
# Obs.: proot não tem netlink, então checagem de porta é via /dev/tcp (sem ss/netstat).
set -euo pipefail

PORTA_SSH=2222
USER_TUNEL=suporte

# confere se uma porta TCP local está aberta (0 = aberta)
porta_aberta() { timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

# 1) usuário dedicado: existe apenas para autenticar o túnel do cliente
if ! id "$USER_TUNEL" >/dev/null 2>&1; then
    useradd -m -s /bin/sh "$USER_TUNEL"
fi
# conta com senha '!' (padrão do useradd) é tratada como locked e bloqueia
# até login por chave quando UsePAM no; '*' = sem senha válida, conta ativa
HASH=$(grep "^${USER_TUNEL}:" /etc/shadow | cut -d: -f2)
[ "$HASH" = '!' ] && usermod -p '*' "$USER_TUNEL"
install -d -m 700 -o "$USER_TUNEL" -g "$USER_TUNEL" "/home/$USER_TUNEL/.ssh"
[ -f "/home/$USER_TUNEL/.ssh/authorized_keys" ] || \
    install -m 600 -o "$USER_TUNEL" -g "$USER_TUNEL" /dev/null "/home/$USER_TUNEL/.ssh/authorized_keys"

# 2) configuração em drop-in (o Include do sshd_config carrega primeiro e,
#    no sshd, o primeiro valor vence — estas opções prevalecem)
cat > /etc/ssh/sshd_config.d/10-suporte-remoto.conf <<CONF
# suporte-remoto — camada de conexão
Port ${PORTA_SSH}
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowTcpForwarding yes
CONF

# 3) chaves de host + diretório de separação de privilégio + validação
ssh-keygen -A
mkdir -p /run/sshd
/usr/sbin/sshd -t

# 4) sobe o sshd (proot não tem systemd — binário direto; só se ainda não estiver
#    ativo). --no-start: usado pelo serviço runit suporte-sshd, que prefere o
#    sshd -D supervisionado em vez do daemon solto
[ "${1:-}" = "--no-start" ] || porta_aberta "$PORTA_SSH" || /usr/sbin/sshd

# 5) verificação final
porta_aberta "$PORTA_SSH" && echo "OK: sshd do projeto ativo na porta ${PORTA_SSH} (usuário de túnel: ${USER_TUNEL})"
