---
name: atender
description: Operar um PC cliente do suporte-remoto pelo túnel SSH reverso — listar clientes, abrir túnel, executar comandos, copiar arquivos e diagnosticar Windows e Linux remotamente
---

# Atender cliente do suporte-remoto

Você (Claude) roda no **servidor** (Termux/proot Debian, onde estão web.py e o
cloudflared). Os PCs cliente são alcançados por **túnel SSH reverso** — você
nunca precisa estar instalado neles. O técnico assiste tudo pelo terminal do
painel; comande como se estivesse na frente da máquina dele.

## Regra de ouro

Todo comando de máquina roda **NO CLIENTE**, via `atender.sh -c` — o servidor
onde você roda **nunca** é o alvo. Se o técnico pede disco, processo, rede,
arquivo ou serviço, é do cliente. Shell local do servidor só para os helpers
deste skill (probe da porta, `/painel/acao`, logs `/var/log/svc`).

## Registro e estado

- `servidor/clientes.json` — um dict por cliente: `id`, `porta`, `usuario`,
  `so`, `conectar`. No topo do arquivo, `token_painel` = token da API.
- Túnel aberto? Probe da porta reversa (exit 0 = aberto):
  `(echo > /dev/tcp/127.0.0.1/<porta>) 2>/dev/null`
- O agente polla o servidor a cada 20s: mudança de estado demora até 20s para
  fazer efeito. Tenha paciência antes de concluir que falhou.

## Abrir / fechar túnel

```bash
curl -s -X POST http://127.0.0.1:8090/painel/acao \
  -H 'Content-Type: application/json' \
  -d '{"token":"<token_painel>","id":"<cid>","acao":"conectar"}'
```

Ações: `conectar` | `encerrar`. **Peça confirmação do técnico antes de abrir** —
o túnel dá acesso admin à máquina dele. Espere a porta abrir (probe acima).

## Executar no cliente

```bash
bash servidor/atender.sh <cid> -c '<comando>'
```

- Cada chamada é uma sessão SSH **nova**: `cd` e variáveis NÃO persistem entre
  chamadas — use caminhos absolutos e blocos `cmd /c "a && b"`.
- O usuário é o registrado no cliente (`usuario` no clientes.json).
- Modo interativo (pré-voo + shell direto): `bash servidor/atender.sh <cid>`.

### Windows — o DefaultShell é PowerShell 5.1

- **Não existe `&&` nem `||`** no PS 5.1; encadear via `cmd /c "a && b"`.
- Variáveis de ambiente do cmd só expandem dentro do cmd: `cmd /c "echo %OS%"`.
- Elevação: `cmd /c "whoami /groups | findstr S-1-16-12288"` (exit 0 = token
  High = admin pleno). `net session` dá **falso negativo** se o serviço
  Server/LanmanServer estiver parado.
- `icacls` com **SIDs** (`*S-1-5-18`, `*S-1-5-32-544`), nunca nomes — máquina
  de domínio sem contato com o DC não resolve "Administrators".
- Acentos embolados na saída = codepage cp850; ignore ou force UTF-8 no cliente
  (`[Console]::OutputEncoding=[Text.Encoding]::UTF8`).
- `findstr` com dois argumentos soltos trata o **2º como arquivo** — um padrão só.
- Logs do agente no cliente: `C:\Program Files\SuporteRemoto\agente.log`
  (+ `cloudflared.log`, `ssh-tunel.log` — stderr dos processos do túnel).
- O relógio do cliente pode estar horas atrasado em relação ao servidor —
  aplique o offset ao cruzar `agente.log` com logs daqui.

### Linux

Comandos diretos; root = `id -u` devolve 0.

## Copiar arquivos pelo túnel

```bash
scp -P <porta> -i servidor/clientes/<cid>/chave-tecnico \
  -o UserKnownHostsFile=servidor/clientes/<cid>/known_hosts \
  <arquivo> <usuario>@localhost:<destino>
```

## Regras

- **Nunca burlar UAC** — e não precisa: logon SSH em conta admin já recebe token
  elevado.
- Comando destrutivo (remover arquivo, parar serviço, reiniciar máquina):
  **confirmar com o técnico antes**, sempre.
- **Abrir túnel**: só com autorização explícita do técnico.
- **Fechar túnel**: decisão e ação do técnico, no painel — **nunca** execute
  `encerrar` você mesmo (no máximo, lembre o técnico de fechar ao terminar).
