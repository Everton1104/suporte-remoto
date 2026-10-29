---
name: pergunta-cliente
description: Abrir caixa de diálogo na tela do usuário de um PC cliente — pergunta com campo de resposta que volta ao técnico (pergunta.sh) ou aviso com botão OK (mensagem.sh)
---

# Pergunta / mensagem ao usuário do cliente

Abre uma janela **na tela de quem está usando a máquina do cliente** (sessão
logada), para o técnico se comunicar durante o atendimento. Dois modos —
escolha pelo objetivo:

| Técnico quer... | Helper |
|---|---|
| dar um aviso, o usuário só clica OK | `servidor/mensagem.sh` |
| perguntar algo e **receber a resposta** | `servidor/pergunta.sh` |

## Antes de enviar

1. Confirme o cliente alvo (o do atendimento em curso — cheque
   `servidor/clientes.json` se necessário).
2. Túnel aberto? Probe da porta reversa do cliente (exit 0 = aberto):
   `(echo > /dev/tcp/127.0.0.1/<porta>) 2>/dev/null`. Fechado: só abra com
   autorização do técnico (mesma regra do skill `atender`), via
   `POST /painel/acao`.
3. Só Windows, e precisa de **alguém logado na tela** — a janela abre na
   sessão interativa. Sem ninguém, a mensagem não aparece pra ninguém.

## Enviar

```bash
# aviso (sem acentos — codepage do msg.exe embola acentuação)
bash servidor/mensagem.sh <cid> Reinicio agendado para as 18h, salve seu trabalho

# pergunta (acentos OK na pergunta e na resposta; espera até 5 min)
bash servidor/pergunta.sh <cid> Em que horário posso reiniciar a máquina?
```

Atalhos globais do shell do servidor (mesmos helpers, resolvem o cliente por
pedaço do id/máquina/nome; ambíguo lista as opções): `clientes` (lista com
● = túnel aberto), `mensagem 87 <texto>`, `pergunta dep pergunta acentuada`.

`pergunta.sh` bloqueia esperando a resposta (o loop de espera dorme NO
cliente) — chame com timeout generoso na ferramenta Bash (~400000 ms) e
avise o técnico que a pergunta está na tela.

## Reportar ao técnico

- `mensagem.sh`: exit 0 = popup entregue na sessão (confirmação visual é
  com o técnico).
- `pergunta.sh`: mostre a resposta que voltou (linha `>> Resposta:`).
  `(sem resposta / cancelado)` = usuário cancelou ou deixou vazio;
  timeout de 5 min = "Sem resposta em 5 min".

## Direto na sessão do cliente (sem passar pelo servidor)

Plantados no System32 pelo instalador `instalar-cmds <cliente>` (=
`servidor/instalar-suporte-cmds.sh`) **e pelo instalador do agente**
(template-agente.bat, passo 9b — PC novo já nasce com eles; o
desinstalar.ps1 remove junto). Uso dentro do terminal/SSH do cliente:
`suporte-mensagem <texto>` e `suporte-pergunta <pergunta>` — a resposta
imprime no próprio terminal. Fontes em `servidor/cliente-cmds/` (CRLF +
BOM aplicados na instalação; no instalador do agente o web.py embute em
base64 já convertido). O .ps1 interno chama-se
`suporte-pergunta-run.ps1` DE PROPÓSITO: o PowerShell resolve `.ps1`
antes de `.cmd` no PATH e a ExecutionPolicy Restricted bloquearia o
carregamento direto — nome diferente força o .cmd (que chama o powershell
com `-ExecutionPolicy Bypass`). A tarefa interativa usa `/ru Interactive`
(roda como o usuário logado na tela, sem senha). Acentos: texto digitado
na sessão do cliente embola na origem (codepage do shell); resposta
acentuada pode embolar na exibição — o texto íntegro fica em
`C:\Users\Public\suporte-resposta.txt` (UTF-8).

## Como funciona (para debug)

Processo criado via SSH nasce na sessão 0, sem UI — a janela é aberta por
tarefa agendada interativa (`schtasks /create /it`), que roda como o
usuário logado. `mensagem.sh` usa `msg console` direto. `pergunta.sh`
sobe um .ps1 (com BOM — PS 5.1 embola acentos sem ele) por scp, o
InputBox grava a resposta em `C:\Users\Public\suporte-resposta.txt`, o
helper espera e baixa por scp; ao final limpa tarefa e arquivos no
cliente. Se algo falhar, olhe `schtasks /query /tn SuporteRemotoPergunta`
e os arquivos em `C:\Users\Public\` no cliente.
