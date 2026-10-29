# Suporte Remoto — painel no VSCode

Painel dos PCs cadastrados no suporte-remoto, dentro do VSCode/code-server.
Mesma API do painel web (`/painel/dados` e `/painel/acao` com o `token_painel`
lido direto de `servidor/clientes.json`), sem nada embutido na extensão.

## O que faz

- Lista os clientes como o painel: nome, status online/offline, porta,
  túnel aberto, último contato — atualiza a cada 5s
- **conectar / encerrar** túnel (com os mesmos estados intermediários
  "conectando…" e "encerrando…" do painel) e **remover** (auto-desinstalação
  remota, com confirmação)
- **terminal** abre o shell do cliente num terminal integrado, via
  `servidor/atender.sh` (pré-voo, detecção de Windows/Linux e elevação)
- **claude** abre o Claude Code no terminal integrado, no diretório do
  projeto — ele opera o cliente pelo skill `atender`

## Como abrir

- Paleta de comandos → **Suporte: Clientes**
- Ou pelo item `suporte` na barra de status

## Configurações

| chave | padrão | descrição |
|---|---|---|
| `suporte.baseDir` | `/root/CODE/suporte-remoto` | diretório do projeto |
| `suporte.porta` | `8090` | porta local do web.py |

## Instalar no code-server

```
code-server --install-extension servidor/extensoes/suporte-remoto-0.1.0.vsix
```
(ou "Install from VSIX" na aba de extensões) e recarregar a janela.
