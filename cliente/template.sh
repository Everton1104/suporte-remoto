#!/usr/bin/env bash
# ============================================================
#  SUPORTE REMOTO - sessão __SESSION__  (cliente Linux)
#  Cliente: __CLIENTE__
#
#  Fluxo automático após UMA senha (sudo — o consentimento):
#    prepara servidor SSH -> abre túnel seguro -> atendimento
#    -> ao fim remove TUDO desta sessão (chave, serviço,
#    arquivos temporários)
#
#  Este terminal é o painel da sessão: pode ser minimizado.
#  Tecle N nele para encerrar o suporte a qualquer momento.
# ============================================================
set -uo pipefail

# --- 0) sem privilégios? pede sudo (senha UMA vez = consentimento) ---
if [ "$(id -u)" -ne 0 ]; then
    cat <<'TXT'

  Este programa precisa de permissão de administrador.
  O terminal vai pedir a senha UMA única vez — daí em diante
  tudo é automático. Nada mais será pedido a você.
TXT
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0"
    else
        echo "  Sem sudo disponível. Rode como root: su -c 'bash $0'" >&2
        exit 1
    fi
fi

WORK=$(mktemp -d /tmp/suporte-remoto.XXXXXX)
STATE=/var/lib/suporte-remoto
FLAG=$STATE/encerrar
MARCADOR=$STATE/sshd-instalado
AK_ROOT=/root/.ssh/authorized_keys
DROPIN=/etc/ssh/sshd_config.d/00-suporte-remoto.conf

DOMINIO=__DOMINIO__
PORTA_PROXY=__PORTA_PROXY__                    # porta local do cloudflared (igual à do sshd do servidor)
PORTA_REVERSA=__PORTA_REVERSA__                # abre NO servidor, cai neste PC
PORTA_SSHD=${SUPORTE_PORTA_SSHD:-22}           # sshd deste cliente
SEM_CLOUDFLARED=${SUPORTE_SEM_CLOUDFLARED:-0}  # 1 = conexão direta (LAN/teste)

INSTALAMOS=0; RODAVA=0; MUDOU_ROOT=0
SSH_PID=; CF_PID=

mkdir -p "$STATE"

# ============ LIMPEZA — sessão única, sem rastros de acesso ============
cleanup() {
    trap - EXIT INT TERM
    [ -n "$SSH_PID" ] && kill "$SSH_PID" 2>/dev/null
    [ -n "$CF_PID" ] && kill "$CF_PID" 2>/dev/null
    sleep 1
    rm -f "$FLAG"

    # remove a chave do técnico desta sessão (deixa o resto como estava)
    [ -f "$AK_ROOT" ] && sed -i "/sessao:__SESSION__:tecnico/d" "$AK_ROOT"
    [ -s "$AK_ROOT" ] || rm -f "$AK_ROOT"

    # sshd: remove se fomos nós que instalamos; senão restaura o estado
    if [ "$INSTALAMOS" = 1 ]; then
        echo "  Removendo OpenSSH Server..."
        systemctl stop ssh sshd 2>/dev/null
        if   command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get purge -y openssh-server
        elif command -v dnf     >/dev/null 2>&1; then dnf remove -y openssh-server
        elif command -v yum     >/dev/null 2>&1; then yum remove -y openssh-server
        elif command -v pacman  >/dev/null 2>&1; then pacman -Rns --noconfirm openssh
        elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive remove openssh-server
        fi
        rm -f "$MARCADOR"
        rmdir --ignore-fail-on-non-empty "$STATE" 2>/dev/null
    elif [ "$RODAVA" = 0 ]; then
        systemctl stop ssh 2>/dev/null || systemctl stop sshd 2>/dev/null
    fi

    # desfaz o ajuste temporário de PermitRootLogin, se houve
    if [ -e "$DROPIN" ]; then
        rm -f "$DROPIN"
        if [ "$INSTALAMOS" = 0 ]; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        fi
    fi

    rm -rf "$WORK"
    ssh-keygen -R "[localhost]:$PORTA_PROXY" >/dev/null 2>&1
    ssh-keygen -R "[127.0.0.1]:$PORTA_PROXY" >/dev/null 2>&1

    echo
    echo "  Sessão encerrada. Nenhum acesso restante neste computador."
}
trap cleanup EXIT
trap 'exit 0' INT TERM

echo
echo "  SUPORTE REMOTO - sessão __SESSION__"
echo "  Preparando (automático), aguarde..."
echo

# --- 1) registra o estado original do sshd (para restaurar depois) ---
[ -e "$MARCADOR" ] && INSTALAMOS=1
if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
    pgrep -x sshd >/dev/null 2>&1 && RODAVA=1
else
    INSTALAMOS=1
fi

# --- 2) instala o OpenSSH Server se faltar ---
if [ "$INSTALAMOS" = 1 ] && ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    echo "  Instalando OpenSSH Server (pode demorar um pouco)..."
    if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y openssh-server
    elif command -v yum     >/dev/null 2>&1; then yum install -y openssh-server
    elif command -v pacman  >/dev/null 2>&1; then pacman -S --noconfirm openssh
    elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install openssh-server
    else
        echo "  Gerenciador de pacotes desconhecido — instale openssh-server e rode de novo." >&2
        exit 1
    fi
    mkdir -p "$STATE"; touch "$MARCADOR"
    (systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null) || true
fi

# --- 3) garante o sshd rodando ---
(systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null) \
    || pgrep -x sshd >/dev/null 2>&1 \
    || /usr/sbin/sshd || true
for i in 1 2 3 4 5 6 7 8 9 10; do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORTA_SSHD") 2>/dev/null && break
    sleep 1
done

# --- 4) garante login do técnico (root por chave) ---
#    'prohibit-password' (padrão em quase tudo) já permite chave; só mexe
#    no sshd se estiver 'no' — e desfaz no encerramento
EFETIVO=$(sshd -T 2>/dev/null | awk 'tolower($1)=="permitrootlogin"{print $2}')
if [ "$EFETIVO" = "no" ]; then
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PermitRootLogin prohibit-password\n' > "$DROPIN"
    MUDOU_ROOT=1
    (systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null) || true
fi

# --- 5) auto-limpeza de chaves de sessões antigas + instala a desta sessão ---
mkdir -p /root/.ssh; chmod 700 /root/.ssh
touch "$AK_ROOT"
sed -i '/sessao:/d' "$AK_ROOT"
printf '%s\n' '__PUBKEY_TECNICO__' >> "$AK_ROOT"
chmod 600 "$AK_ROOT"

# --- 6) baixa o cloudflared (binário oficial; pula se conexão direta) ---
if [ "$SEM_CLOUDFLARED" != 1 ]; then
    case "$(uname -m)" in
        x86_64)        ARQ=amd64 ;;
        aarch64|arm64) ARQ=arm64 ;;
        armv7l|armv6l) ARQ=arm ;;
        *) echo "  Arquitetura não suportada: $(uname -m)" >&2; exit 1 ;;
    esac
    URL_CF="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARQ"
    echo "  Baixando cloudflared..."
    curl -fsSL -o "$WORK/cloudflared" "$URL_CF" \
        || wget -q -O "$WORK/cloudflared" "$URL_CF" \
        || { echo "  Falha ao baixar cloudflared" >&2; exit 1; }
    chmod +x "$WORK/cloudflared"
    "$WORK/cloudflared" access tcp --hostname "$DOMINIO" --url "localhost:$PORTA_PROXY" &
    CF_PID=$!
    DESTINO=(suporte@localhost)
    sleep 6
else
    DESTINO=(suporte@"$DOMINIO")
fi

# --- 7) reconstrói a chave efêmera desta sessão (veio embutida em base64) ---
printf '%s' '__CHAVE_CLIENTE_B64__' | base64 -d > "$WORK/chave_cliente"
chmod 600 "$WORK/chave_cliente"

# --- 8) túnel REVERSO: a porta $PORTA_REVERSA do servidor passa a cair neste PC ---
ssh -N -i "$WORK/chave_cliente" -p "$PORTA_PROXY" "${DESTINO[@]}" \
    -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
    -R "${PORTA_REVERSA}:localhost:${PORTA_SSHD}" &
SSH_PID=$!

echo
echo "  ============================================================"
echo "    SESSÃO ATIVA  (sessão __SESSION__)"
echo "    Usuário para o técnico: root"
echo "    Pode minimizar este terminal e avisar o técnico."
echo "    Tecle N para encerrar o suporte a qualquer momento."
echo "  ============================================================"
echo

# --- 9) aguarda: tecla N / técnico encerrar / conexão cair ---
while :; do
    if read -r -s -n 1 -t 3 TECLA 2>/dev/null; then
        [ "$TECLA" = "n" ] || [ "$TECLA" = "N" ] && break
    else
        sleep 1   # stdin sem terminal (executado em segundo plano)
    fi
    [ -e "$FLAG" ] && break
    kill -0 "$SSH_PID" 2>/dev/null || break
done
# a limpeza roda no EXIT
