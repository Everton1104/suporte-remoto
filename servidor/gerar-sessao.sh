#!/usr/bin/env bash
# gerar-sessao.sh — cria uma sessão de suporte:
#   * chave do CLIENTE (embutida no .bat; no servidor só pode abrir túnel, nada mais)
#   * chave do TÉCNICO (o par fica aqui; a pública vai dentro do .bat e é instalada no Windows)
#   * renderiza o .bat pronto para enviar ao cliente
# uso: DOMINIO=ssh.seudominio.com ./gerar-sessao.sh <nome-do-cliente>
set -euo pipefail

[ $# -eq 1 ] || { echo "uso: $0 <nome-do-cliente>"; exit 1; }
CLIENTE=$1
PORTA_REVERSA=10022   # porta que abre AQUI e cai no PC do cliente
PORTA_PROXY=2222      # porta local do cloudflared no cliente (mesma do nosso sshd)
DOMINIO=${DOMINIO:-ssh.evertonrs.com.br}
URL_BASE=${URL_BASE:-https://suporte.evertonrs.com.br}
USER_TUNEL=suporte
BASE=$(cd "$(dirname "$0")" && pwd)

ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 2)"
DIR="$BASE/sessoes/$ID"
mkdir -p "$DIR"

# chave B (cliente→servidor): autentica o cliente no nosso sshd
ssh-keygen -q -t ed25519 -N '' -C "sessao:$ID:cliente" -f "$DIR/chave-cliente"
# chave A (técnico→cliente): autentica o técnico no OpenSSH do Windows do cliente
ssh-keygen -q -t ed25519 -N '' -C "sessao:$ID:tecnico" -f "$DIR/chave-tecnico"

# registra a chave do cliente no sshd:
#   restrict        → desliga pty, execução, encaminhamentos, tudo
#   permitlisten    → reabilita apenas abrir a porta reversa
#   command         → qualquer tentativa de execução cai no /bin/false
printf 'restrict,port-forwarding,permitlisten="%s",permitopen="127.0.0.1:1",command="/bin/false" %s\n' \
    "$PORTA_REVERSA" "$(cat "$DIR/chave-cliente.pub")" \
    >> "/home/$USER_TUNEL/.ssh/authorized_keys"

# chave privada do cliente em base64 para embutir no .bat (o Windows decodifica com certutil)
B64=$(base64 -w0 "$DIR/chave-cliente")

# renderiza o .bat (a conversão final para CRLF evita pegadinhas do cmd.exe)
sed -e "s|__SESSION__|$ID|g" \
    -e "s|__CLIENTE__|$CLIENTE|g" \
    -e "s|__DOMINIO__|$DOMINIO|g" \
    -e "s|__URL_BASE__|$URL_BASE|g" \
    -e "s|__PORTA_PROXY__|$PORTA_PROXY|g" \
    -e "s|__PORTA_REVERSA__|$PORTA_REVERSA|g" \
    -e "s|__PUBKEY_TECNICO__|$(cat "$DIR/chave-tecnico.pub")|" \
    -e "s|__CHAVE_CLIENTE_B64__|$B64|" \
    "$BASE/../cliente/template.bat" | sed 's/$/\r/' > "$DIR/suporte-$ID.bat"

# versão Linux: mesmo render, sem CRLF, executável
sed -e "s|__SESSION__|$ID|g" \
    -e "s|__CLIENTE__|$CLIENTE|g" \
    -e "s|__DOMINIO__|$DOMINIO|g" \
    -e "s|__PORTA_PROXY__|$PORTA_PROXY|g" \
    -e "s|__PORTA_REVERSA__|$PORTA_REVERSA|g" \
    -e "s|__PUBKEY_TECNICO__|$(cat "$DIR/chave-tecnico.pub")|" \
    -e "s|__CHAVE_CLIENTE_B64__|$B64|" \
    "$BASE/../cliente/template.sh" > "$DIR/suporte-$ID.sh"
chmod 700 "$DIR/suporte-$ID.sh"

echo "$DIR" > "$BASE/sessoes/.ultima"
echo "Sessão $ID criada em $DIR"
echo "Enviar ao cliente: $DIR/suporte-$ID.bat"
echo "Enviar ao cliente (Linux): $DIR/suporte-$ID.sh"
echo "Para revogar depois: $BASE/encerrar-sessao.sh $ID"
