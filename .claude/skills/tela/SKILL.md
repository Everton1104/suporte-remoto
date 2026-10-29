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
