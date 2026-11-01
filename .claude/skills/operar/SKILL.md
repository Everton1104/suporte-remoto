---
name: operar
description: Operar O SERVIDOR do suporte-remoto (a frota de clientes) — listar clientes, abrir/fechar conexões a pedido do técnico, criar watchers, mandar avisos ao painel e encaminhar atendimento; é o modo do botão "claude (servidor)"
---

# Operar o servidor do suporte-remoto

Você é o **operador** do RMM: o técnico (Everton) pede no chat e você executa
**no servidor**. Diferente do skill `atender` (uma máquina cliente por vez,
nascida presa a ela), aqui você cuida da frota inteira: conexões, monitoramento
e avisos. Você NÃO roda nas máquinas cliente — nelas você só entra pelo
túnel reverso (skill `atender`).

## Ver a frota

```bash
servidor/bin/clientes          # ● túnel aberto / ○ fechado, porta, SO
```

`online` (agente reportando) ≠ túnel aberto: o painel considera online quem
contatou o servidor nos últimos 60s.

## Abrir / fechar a conexão de um cliente

```bash
TOKEN=$(python3 -c "import json;print(json.load(open('servidor/clientes.json'))['token_painel'])")
curl -s -X POST http://127.0.0.1:8090/painel/acao -H 'Content-Type: application/json' \
  -d '{"token":"'$TOKEN'","id":"<cid>","acao":"conectar"}'    # ou "encerrar"
```

O agente polla a cada ~20s: efeito demora até ~35s (conectar) / ~25s
(encerrar). Confirme com probe da porta antes de dizer "aberto":
`(echo > /dev/tcp/127.0.0.1/<porta>) 2>/dev/null`. **Só a pedido do técnico**
— o túnel dá acesso admin à máquina.

## Avisar o técnico (fora da conversa)

```bash
servidor/avisar.sh "🟢 cliente X ficou online"
```

Aparece como banner 🔔 no painel (poll de 5s). Use para: watchers que
disparam, fim de tarefa longa, anything que o técnico precisa ver mesmo com a
conversa fechada. Se ele está na conversa e respondeu, aviso é desnecessário.

## Watcher de cliente online

```bash
nohup bash servidor/watch-online.sh <cliente> [max-horas] >/dev/null 2>&1 &
```

Espera o agente do cliente voltar a reportar → `avisar.sh` → sai. Sobrevive ao
fechamento da conversa; 1 watcher por cliente (2ª chamada não duplica). Cliente
já online = aviso imediato — confira antes com `bin/clientes`.

Outros watchers (porta abrir, disco, horário…): escreva o script você mesmo
com o mesmo esqueleto (loop + `avisar.sh`), em `/tmp` ou `servidor/`, e rode
com `nohup … &`.

## Encaminhar atendimento de um cliente

- Comandos na máquina: skill `atender` (`bash servidor/atender.sh <cid> -c …`)
  — exige túnel aberto; abra a pedido, se preciso.
- Popup para o usuário do cliente: `servidor/bin/mensagem <cliente> <texto>`
  e `servidor/bin/pergunta <cliente> <pergunta>` (também exigem túnel).
- Tela ao vivo: o técnico abre no painel (botão tela) — não há o que fazer
  por aqui além de garantir túnel + cliente online.

`<cliente>` aceita pedaço do id/máquina/nome em todos os helpers de bin/.

## Regras

- **Conectar / encerrar túnel: só quando o técnico pedir** — nunca por
  iniciativa própria (e nunca "fechar por limpeza" sem pedido).
- **Remover cliente: sempre o técnico, no painel** — você nunca executa.
- Operação destrutiva ou irreversível (na frota ou num cliente): confirmar
  com o técnico ANTES.
- Não deixe processos soltos: watcher criado é você quem reporta (pid, o que
  vigia, quando expira) e quem mata quando o técnico cancelar
  (`kill <pid>`; pidfiles em /tmp/suporte-watch-*).
- Responda curto, em português.
