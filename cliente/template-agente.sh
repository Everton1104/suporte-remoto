#!/usr/bin/env bash
# ============================================================
#  SUPORTE REMOTO - INSTALADOR DO AGENTE PERMANENTE (Linux)
#
#  Instala ACESSO REMOTO PERMANENTE de suporte tecnico
#  (Everton - ssh.evertonrs.com.br). O tecnico so entra quando
#  voce pedir atendimento, e cada entrada dele fica registrada
#  em /opt/suporte-remoto/agente.log
#  Para remover a qualquer momento:
#  sudo /opt/suporte-remoto/desinstalar.sh
# ============================================================
set -uo pipefail

URL=__URL_BASE__
DOMINIO=__DOMINIO__
PORTA_PROXY=__PORTA_PROXY__
DIR=/opt/suporte-remoto

# --- 0) elevacao: sudo UMA vez = consentimento ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Precisa de administrador: o terminal pede a senha UMA unica vez (sudo)."
    if command -v sudo >/dev/null 2>&1; then exec sudo -E bash "$0"; fi
    echo "Sem sudo. Rode como root: su -c 'bash $0'" >&2
    exit 1
fi

echo "Instalando o agente de suporte remoto (automatico)..."

# --- 1) sshd do Linux (persistente, sobe com o sistema) ---
if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    echo "Instalando OpenSSH Server..."
    if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y openssh-server
    elif command -v yum     >/dev/null 2>&1; then yum install -y openssh-server
    elif command -v pacman  >/dev/null 2>&1; then pacman -S --noconfirm openssh
    elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install openssh-server
    else echo "Gerenciador de pacotes desconhecido - instale openssh-server e rode de novo" >&2; exit 1; fi
fi
(systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null) \
    || pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd || true

# login do tecnico: root por chave (só mexe no sshd se PermitRootLogin for 'no')
EFETIVO=$(sshd -T 2>/dev/null | awk 'tolower($1)=="permitrootlogin"{print $2}')
DROPIN=/etc/ssh/sshd_config.d/00-suporte-remoto.conf
mkdir -p "$DIR"; chmod 700 "$DIR"
if [ "$EFETIVO" = "no" ]; then
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PermitRootLogin prohibit-password\n' > "$DROPIN"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    touch "$DIR/flag-dropin"   # o desinstalador desfaz isto
fi

# --- 2) chave do tunel (gerada AQUI, persistente) + cloudflared ---
[ -f "$DIR/chave-tunel" ] || ssh-keygen -q -t ed25519 -N '' -f "$DIR/chave-tunel" -C suporte-remoto
if [ ! -x "$DIR/cloudflared" ]; then
    case "$(uname -m)" in
        x86_64)        ARQ=amd64 ;;
        aarch64|arm64) ARQ=arm64 ;;
        armv7l|armv6l) ARQ=arm ;;
        *) echo "Arquitetura nao suportada: $(uname -m)" >&2; exit 1 ;;
    esac
    echo "Baixando cloudflared..."
    URL_GH="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARQ"
    ok_cf(){ [ "$(stat -c%s "$DIR/cloudflared" 2>/dev/null || echo 0)" -ge 5000000 ]; }
    # espelho nosso primeiro (amd64/arm64); arm 32-bit só existe no GitHub
    case "$ARQ" in
        amd64|arm64) curl -fsSL -o "$DIR/cloudflared" "$URL/arquivos/cloudflared-linux-$ARQ" || true ;;
    esac
    ok_cf || curl -fsSL -o "$DIR/cloudflared" "$URL_GH" || wget -q -O "$DIR/cloudflared" "$URL_GH" || true
    ok_cf || { rm -f "$DIR/cloudflared"; echo "Falha ao baixar cloudflared" >&2; exit 1; }
    chmod +x "$DIR/cloudflared"
fi

# --- 3) registra no servidor (idempotente: mesma chave = mesmo cliente) ---
echo "Registrando no servidor..."
NOME=$(hostname)
R=$(curl -fsS --max-time 20 -X POST -H 'Content-Type: application/json' \
    -d "{\"nome\":\"$NOME\",\"maquina\":\"$NOME\",\"so\":\"linux\",\"usuario\":\"root\",\"chave_tunel\":\"$(cat "$DIR/chave-tunel.pub")\"}" \
    "$URL/agente/registrar") || { echo "FALHOU: registro no servidor. Internet? Tente de novo." >&2; exit 1; }
printf '%s' "$R" > "$DIR/registro.json"
PUBTEC=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin)["pubkey_tecnico"])')

# --- 4) chave do tecnico DESTE cliente no root ---
mkdir -p /root/.ssh; chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
grep -qF "$PUBTEC" /root/.ssh/authorized_keys || printf '%s\n' "$PUBTEC" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# --- 5) config + agente (poll: so abre tunel quando o tecnico pedir) ---
printf 'URL=%s\nDOMINIO=%s\nPORTA_PROXY=%s\n' "$URL" "$DOMINIO" "$PORTA_PROXY" > "$DIR/config"
cat > "$DIR/agente.sh" <<'AGENTE'
#!/usr/bin/env bash
# agente.sh — mantém o túnel reverso aberto somente enquanto o técnico pedir
# (poll no servidor a cada 20s; eventos vão para agente.log ao lado)
d=$(cd "$(dirname "$0")" && pwd); cd "$d"
. ./config
REG_ID=$(python3 -c 'import json;print(json.load(open("registro.json"))["id"])' 2>/dev/null) || exit 1
REG_PORTA=$(python3 -c 'import json;print(json.load(open("registro.json"))["porta"])' 2>/dev/null) || exit 1
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> agente.log; }

log "agente iniciado (id=$REG_ID porta=$REG_PORTA)"
cf=""; sshpid=""
while :; do
    R=$(curl -fsS --max-time 10 "$URL/agente/estado?id=$REG_ID" 2>/dev/null) || R=
    CON=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("conectar",False))' 2>/dev/null || echo False)
    if [ "$CON" = True ] && [ -z "$sshpid" ]; then
        log "abrindo túnel (técnico conectado)"
        [ -z "$cf" ] && { "$d/cloudflared" access tcp --hostname "$DOMINIO" --url "localhost:$PORTA_PROXY" & cf=$!; sleep 6; }
        ssh -N -i "$d/chave-tunel" -p "$PORTA_PROXY" suporte@localhost \
            -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
            -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
            -o HostKeyAlgorithms=ssh-ed25519 \
            -R "${REG_PORTA}:localhost:22" &
        sshpid=$!
    elif [ "$CON" != True ] && [ -n "$sshpid" ]; then
        log "fechando túnel (técnico encerrou)"
        kill "$sshpid" 2>/dev/null; sshpid=
        [ -n "$cf" ] && kill "$cf" 2>/dev/null; cf=
    fi
    [ -n "$sshpid" ] && ! kill -0 "$sshpid" 2>/dev/null && { log "túnel caiu; novo ciclo tenta de novo"; sshpid=; }
    sleep 20
done
AGENTE
chmod 700 "$DIR/agente.sh"

# --- 6) servico systemd (sempre de pe, desde o boot) ---
cat > /etc/systemd/system/suporte-remoto.service <<UNIDADE
[Unit]
Description=Suporte Remoto Everton (agente de atendimento)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DIR/agente.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIDADE
systemctl daemon-reload && systemctl enable --now suporte-remoto

# --- 7) desinstalador ---
cat > "$DIR/desinstalar.sh" <<'DESINSTALAR'
#!/usr/bin/env bash
# remove o agente de suporte remoto por completo
[ "$(id -u)" = 0 ] || exec sudo bash "$0"
cd /opt/suporte-remoto 2>/dev/null || exit 0
. ./config 2>/dev/null
ID=$(python3 -c 'import json;print(json.load(open("registro.json"))["id"])' 2>/dev/null)
systemctl disable --now suporte-remoto 2>/dev/null
rm -f /etc/systemd/system/suporte-remoto.service
systemctl daemon-reload 2>/dev/null
pkill -f '/opt/suporte-remoto/agente.sh' 2>/dev/null
pkill -f 'cloudflared access' 2>/dev/null
[ -n "$ID" ] && [ -n "$URL" ] && curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"id\":\"$ID\"}" "$URL/agente/remover" >/dev/null 2>&1
sed -i '/cliente:/d' /root/.ssh/authorized_keys 2>/dev/null
[ -s /root/.ssh/authorized_keys ] || rm -f /root/.ssh/authorized_keys
[ -f flag-dropin ] && { rm -f /etc/ssh/sshd_config.d/00-suporte-remoto.conf
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; }
cd /
rm -rf /opt/suporte-remoto
echo "Pronto: nenhum acesso remoto de suporte resta neste computador."
DESINSTALAR
chmod 700 "$DIR/desinstalar.sh"

echo
echo "  ============================================================"
echo "    AGENTE INSTALADO"
echo "    Quando precisar de suporte, apenas chame o tecnico - nao"
echo "    e preciso fazer mais nada. Cada acesso do tecnico fica"
echo "    registrado em $DIR/agente.log"
echo "    Para remover: sudo $DIR/desinstalar.sh"
echo "  ============================================================"
