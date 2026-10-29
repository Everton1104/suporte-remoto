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

# renderiza o .bat: sed troca os campos, e o python final embute o curl
# (base64 em echos de 4 KB — inviável no sed) e converte pra CRLF
# (pegadinha do cmd.exe)
sed -e "s|__SESSION__|$ID|g" \
    -e "s|__CLIENTE__|$CLIENTE|g" \
    -e "s|__DOMINIO__|$DOMINIO|g" \
    -e "s|__URL_BASE__|$URL_BASE|g" \
    -e "s|__PORTA_PROXY__|$PORTA_PROXY|g" \
    -e "s|__PORTA_REVERSA__|$PORTA_REVERSA|g" \
    -e "s|__PUBKEY_TECNICO__|$(cat "$DIR/chave-tecnico.pub")|" \
    -e "s|__CHAVE_CLIENTE_B64__|$B64|" \
    "$BASE/../cliente/template.bat" > "$DIR/.bat-parcial"
python3 - "$DIR/.bat-parcial" "$DIR/suporte-$ID.bat" "$BASE/static" <<'PY'
import base64, os, sys
parcial, saida, static = sys.argv[1:4]
t = open(parcial, encoding="utf-8").read()
linhas = []
for nome in ("curl.exe", "curl-ca-bundle.crt"):
    try:
        with open(os.path.join(static, nome), "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
    except OSError:
        b64 = ""          # espelho ausente: .bat cai no download via certutil
    arq = f"%WORK%\\{nome}.b64"     # f-string: % é literal (em %-format seria erro)
    for i in range(0, len(b64), 4000):
        op = ">" if i == 0 else ">>"
        linhas.append(f'{op} "{arq}" echo {b64[i:i + 4000]}')
    linhas.append(f'certutil -decode "{arq}" "%WORK%\\{nome}" >nul')
    linhas.append(f'del "{arq}" >nul 2>&1')
t = t.replace("__CURL_EMBUTIDO__", "\n".join(linhas))
with open(saida, "w", encoding="utf-8", newline="") as f:
    f.write(t.replace("\r\n", "\n").replace("\n", "\r\n"))
PY
rm -f "$DIR/.bat-parcial"

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
