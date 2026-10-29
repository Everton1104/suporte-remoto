---
name: tela
description: Tela ao vivo do cliente no painel (MJPEG ~2-4 fps) com controle de mouse/teclado — regras de uso, limitações e debug (tela.ps1 no cliente, tela.sh no servidor)
---

# Tela ao vivo + controle remoto

Botão **tela** no painel (habilitado com túnel aberto + cliente online).
Windows, exige **alguém logado na sessão** — captura e injeção só
funcionam fora da sessão 0.

## Regras

- **Ver** é passivo. **Controlar** (botão "controlar" na página) passa a
  injetar mouse/teclado na máquina do cliente — avise o usuário antes
  (popup do skill `pergunta-cliente`).
- Fechar túnel é sempre decisão do técnico no painel, como sempre.
- Ao terminar, feche a página (ou botão "parar") — o janitor derruba o
  listener 45s depois e o `tela.ps1` se autolimita: 30 min de sessão,
  10 min sem viewer.

## Antivírus (lição de campo, 29/10/2026)

O **AMSI do Windows Defender bloqueia o tela.ps1 no parse** — captura de
tela + servidor HTTP já é assinatura de spyware de tela (a versão
só-visual também cai; o exit é 1 **sem escrever o log**). Por decisão do
técnico (dono da frota), o `tela.sh subir` adiciona
`Add-MpPreference -ExclusionPath C:\Users\Public\suporte-tela.ps1`
(cirúrgica: só este arquivo; reversível; o desinstalador do agente
remove). **Nunca tentar burlar o AMSI** — técnica de malware; a exclusão
transparente é o caminho legítimo. Em AV não-Defender o cmdlet não existe
e o erro é engolido (a tela pode não subir — investigar caso a caso).

Outras pegadinhas já embutidas no tela.sh: `/ru Interactive` **não
resolve SID** nas máquinas adjundiai (erro "mapeamento entre nomes de
conta e SIDs" → fallback para `/it` puro, que funciona porque o usuário
do túnel é o logado; se forem usuários diferentes a UI não sobe); o kill
de powershells precisa da guarda `-ne $PID` (a linha de comando da própria
sessão contém 'suporte-tela.ps1' — sem a guarda ela se mata: exit 255
silencioso); e o probe de "tela no ar" é um GET `/info` HTTP (o socket do
`ssh -L` aceita conexão mesmo com o listener morto no cliente — probe de
TCP puro dá falso positivo).

## Limitações conhecidas

- ~2–4 fps (captura + JPEG em PowerShell) — cliques chegam com atraso
  de ~0,3–1 s.
- **UAC/secure desktop não aceita injeção** (igual VNC sem hook de
  serviço): se aparecer prompt de elevação, quem clica é o usuário.
- Sessão travada (Win+L) = quadro congelado/preto.
- Teclado: acentos pt-BR OK; emoji não (keybd_event carrega o caractere
  num byte). F5/F12/ctrl+r ficam no navegador do técnico.

## Como funciona (para debug)

- `servidor/tela.ps1` roda NO CLIENTE (sobe pelo `tela.sh` com
  `schtasks /it` — mesma manha do `pergunta.sh`): HttpListener em
  localhost:28090 servindo MJPEG e injetando entrada (mouse_event/
  keybd_event).
- `servidor/tela.sh <cid> subir|parar|pronto` mantém um `ssh -L` da
  porta local (porta reversa + 20000) até o listener.
- `web.py` faz o relay em `/painel/tela/stream` e encaminha eventos em
  `/painel/tela/in`. Um viewer por cliente.
- Log no cliente: `C:\Users\Public\suporte-tela.log`.
- Claude não enxerga pixels: o stream é para o navegador do técnico;
  para checar estado use `tela.sh <cid> pronto`.
