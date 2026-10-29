# suporte-remoto

Laboratório de suporte técnico remoto com LLM. Sem git por enquanto (fase de testes).

Duas formas de atendimento, coexistindo:

| Modo | O que é | Instalador |
|---|---|---|
| **Agente permanente (v2)** | Fica instalado no cliente, sobe com o sistema; o técnico entra quando o cliente pedir | **/baixar** (`.bat` Windows / `.sh` Linux pelo User-Agent) |
| **Sessão única (v1)** | Efêmero: tudo desfeito ao encerrar, nada fica | **/instalar/sessao** |

## Camadas

| # | Camada | Status |
|---|--------|--------|
| 1 | Web ([web.py](servidor/web.py): downloads + registro + painel) | **pronta** — agente v2 no ar, E2E local aprovado |
| 2 | Conexão (sshd :2222 + túneis reversos :10022 efêmero, :10023+ por cliente) | **pronta** — E2E local nas duas plataformas; Windows real pendente |
| 3 | Inteligência (Claude Code no canal do técnico) | esboço — `atender.sh -c` já dá o gancho |

## Fluxo do agente permanente (o principal)

1. Cliente abre **https://suporte.evertonrs.com.br/baixar** → baixa o instalador do
   agente (`.bat` no Windows, `.sh` no Linux; `?so=windows|linux` força)
2. Cliente executa uma única vez → elevação **uma única vez** (UAC / sudo): isso é o
   consentimento. O instalador:
   - instala e habilita o OpenSSH Server (persistente, sobe com o sistema);
     no Windows ainda define PowerShell como shell padrão do SSH
   - gera a **chave do túnel local** (persistente, nunca sai do cliente) e baixa cloudflared
   - se **registra** no servidor (`POST /agente/registrar`) → ganha `id`, porta reversa
     própria (10023+) e a **chave pública do técnico dele** (uma por cliente)
   - escreve o agente em segundo plano: serviço systemd (Linux) / tarefa agendada SYSTEM
     no boot (Windows), sempre ativo
   - deixa o desinstalador (`desinstalar.sh` / `desinstalar.cmd`) ao lado
3. Daí em diante o agente só **consulta o servidor a cada 20s** (arquitetura B: túnel
   fechado por padrão, só abre sob demanda). O cliente não faz mais nada — chama o
   técnico quando precisar.
4. O técnico abre o **painel** (`/painel?token=…`, token em `servidor/clientes.json`),
   vê o cliente online e clica **conectar** → o agente abre o túnel reverso via
   ssh.evertonrs.com.br. **encerrar** fecha o túnel; **remover** revoga tudo (chave
   no servidor, registro, pasta do cliente).
5. Com o túnel aberto: `servidor/atender.sh <id>` — shell admin direto, sem o cliente
   aceitar coisa alguma (o consentimento foi a instalação).

O túnel fica aberto **só enquanto o técnico quiser** — sem conectar/encerrar no painel,
não existe caminho de acesso ao cliente (a chave dele está presa a `command="/bin/false"`
e só pode escutar a porta dele).

## Painel do técnico

- **https://suporte.evertonrs.com.br/painel** — tela de **login só com senha**;
  a sessão vale 12h num cookie HttpOnly e **sobrevive a restart do serviço** (persistida
  em `servidor/.sessoes.json`; reiniciar não desloga mais). Botão **sair** no canto do
  painel. Errar a senha espera 0,5s (freio de força bruta)
- Credenciais em `servidor/clientes.json` (`login` — a senha é guardada como PBKDF2,
  nunca em texto puro). Na primeira execução uma senha aleatória é gerada e impressa
  **uma vez** no log do serviço (`/var/log/svc/suporte-web.log`). Para trocar: apague o
  campo `login` em `clientes.json` e reinicie o serviço (nova senha sai no log)
- O `token_painel` (mesmo arquivo) continua valendo como **chave de API** — é o que o
  `testar-agente.sh` usa em `/painel/acao`; um link antigo `/painel?token=…` ainda
  funciona: valida uma vez e vira sessão de cookie
- Painel em si: lista de clientes (**nome** editável — clique na célula para batizar
  o cliente, salva no registro; sem nome vem o nome da máquina), id, máquina, SO,
  porta, agente online com último contato <60s, túnel aberto), auto-refresh 5s,
  botões conectar / encerrar / remover (remover pede confirmação). `atender.sh <id>`
  lê porta e usuário do próprio registro
- **Terminal no navegador**: botão **terminal** de cada cliente abre `/painel/term`
  — um xterm.js (o mesmo do code-server, servido local de `servidor/static/`)
  conectado a um PTY rodando `atender.sh <id>` no servidor. Saída via stream HTTP
  (fecha = encerra), teclado via POST; máximo 3 simultâneos; 30min sem tráfego
  fecha sozinho; tudo sob a mesma sessão do painel. Precisa do túnel **conectado**
  (o pré-voo do atender avisa se não estiver). No celular: toque na área do
  terminal (ou no botão **⌨ teclado**) para abrir o teclado virtual — ou use a
  **barra de comando** acima do terminal (input nativo, teclado garantido; Enter
  envia a linha)
- **Espelho de binários + aviso de atualização**: OpenSSH (Windows) e cloudflared
  (todas as arquiteturas) ficam espelhados no nosso servidor em `/arquivos/…` —
  os instaladores baixam de **nós** (GitHub/Windows Update viram plano B de
  emergência), então a instalação não depende de terceiros. O painel consulta o
  GitHub a cada 6h (e na hora, pelo botão **procurar atualização**); versão nova
  → banner vermelho com o comando a rodar: `servidor/atualizar-espelho.sh`,
  que rebaixa os binários e regrava `servidor/static/versoes.json`

## Fluxo da sessão única (alternativa, tudo efêmero)

Mesma raiz (`/instalar/sessao` ou `/baixar/sessao`): gera chaves efêmeras novas a cada
download, janela de status com botão de pânico (**N** encerra), e ao terminar desfaz
**tudo** que fez (seção Rastros abaixo). Útil quando o cliente não quer nada instalado.
`atender.sh <id> <usuario>` conecta na porta 10022 com a chave efêmera da sessão.

## Admin e UAC (pass-through do técnico)

- O shell que o técnico recebe já vem **elevado** (token High): login SSH como
  administrador no Windows não passa pelo UAC. Registro, serviços, DISM, drivers,
  `msiexec /qn` — roda direto, **sem nenhuma confirmação na tela do cliente**.
  Conferir: `net session` (o [atender.sh](servidor/atender.sh) já testa no pré-voo).
- Linux: paridade total — a chave do técnico entra no `authorized_keys` do **root**
  (login só por chave, sem senha). Se o sshd estiver com `PermitRootLogin no`, o
  instalador aplica `prohibit-password` num drop-in e o desinstalador desfaz.
- O único UAC/sudo é o clique inicial do instalador — que é o consentimento.
  Redirecionar ou suprimir o consentimento do cliente é técnica de malware; não se
  faz, e não é preciso: o shell admin não pede nada.
- Programas só-gráficos não têm tela nesta camada (é shell, não desktop remoto):
  usar as flags silenciosas (`/S`, `/qn`, `-q`) — também sem prompt algum.
- Decidir "aceitar alteração" é papel do **técnico**, não do cliente: é a camada 3
  (LLM propõe → whitelist roda sozinha → o resto pede [s/N] **no Termux do técnico**).

## WinRM: avaliado e descartado

Por que o transporte é **OpenSSH** e não WinRM: o WinRM exige listener de entrada
(atrás de NAT precisaria... do mesmo túnel SSH, ou seja, SSH de qualquer jeito);
no workgroup pede conta com senha; sofre com `LocalAccountTokenFilterPolicy` e
TrustedHosts; não existe no Linux; e a própria Microsoft está movendo o PowerShell
remoting para SSH. SSH dá as duas plataformas, chave pública sem senha, arquivos via
scp/sftp e token admin de graça.

## Encerramento

- **Agente permanente**: não há encerramento — o túnel abre e fecha pelas ações do
  painel. Para tirar tudo do cliente: `desinstalar.sh` / `desinstalar.cmd` locais, que
  também avisam o servidor (`POST /agente/remover`) para revogar a chave do túnel e
  apagar o registro.
- **Sessão única**: cliente pressiona **N** na janela de status; técnico cria o
  marcador de fim (`C:\ProgramData\suporte-remoto.encerrar` /
  `/var/lib/suporte-remoto/encerrar`); ou queda de conexão (ServerAliveInterval).
  Em qualquer caso o instalador desfaz tudo e `encerrar-sessao.sh <id>` revoga no
  servidor.

## Infraestrutura real

- **suporte.evertonrs.com.br** → `http://127.0.0.1:8090` — [web.py](servidor/web.py), serviço
  runit `suporte-web` (respawn automático). Downloads, registro de agentes e painel
- **ssh.evertonrs.com.br** → `tcp://localhost:2222` — camada de conexão no mesmo túnel
- Ambos no túnel único do code-server (`/root/.cloudflared/config.yml`, backup `config.yml.bak-20261026`)
- **Serviços runit no Termux base** (`/data/data/com.termux/files/usr/var/service/`):
  `suporte-web` (web.py) e `suporte-sshd` (sshd :2222 — `setup-sshd.sh --no-start` +
  `sshd -D` supervisionado, cai = runit religa). Ambos rodam no Debian via proot;
  cada respawn abre uma instância proot nova
- **Boot do Termux:** o `.bashrc` sobe o `runsvdir` se ele não estiver de pé (e segura
  `termux-wake-lock`); há também `~/.termux/boot/start-runit.sh`, que entra em ação se
  o app **Termux:Boot** estiver instalado (sobe tudo ao ligar o Android, sem abrir o
  Termux). Obs.: o antigo `start-code` é stub e não inicia mais nada — quem traz os
  serviços de volta é o runsvdir
- **Quirks do proot:** shutdown gracioso do cloudflared trava — reiniciar com
  `kill -9 $(pgrep -x cloudflared)`; o `sv restart suporte-web` também pode engasgar
  no TERM (o proot wrapper não morre e deixa o python órfão) — se o status ficar em
  "got TERM", `kill -9` nos pids envolvidos que o runit renasce com o código novo
- [limpar-sessoes.sh](servidor/limpar-sessoes.sh) roda a cada download de sessão: revoga chaves com
  mais de 2h (sessão baixada e nunca usada) e apaga pastas de sessão com mais de 24h
- **Atualizar o Termux de dentro do proot:** o `pkg` se recusa a rodar como root (e no
  proot tudo parece root). Padrão que funciona: serviço runit one-shot (o run script
  se marca `sv o` antes de trabalhar) rodando `pkg update/upgrade` com o uid real do
  app, log em `~/pkg-upgrade.log`; ao terminar, remova o serviço. Debian: apt normal.

## Portas

- **2222** — sshd do projeto (usuário dedicado `suporte`, publicado em ssh.evertonrs.com.br)
- **10022** — porta reversa da sessão única
- **10023, 10024, …** — uma porta reversa por cliente registrado (agente permanente);
  o `remover` do painel/devolve a alocação (próximo cliente reaproveita o número mais alto+1)
- **8090** — web.py
- **8080** — code-server

## Arquivos do projeto

- `servidor/web.py` — web + registro + painel; `clientes.json` = registro de agentes;
  `servidor/clientes/<id>/chave-tecnico` = chave privada do técnico daquele cliente
- `servidor/atualizar-espelho.sh` — traz as últimas versões (cloudflared + OpenSSH)
  para `servidor/static/` e regrava `versoes.json` (o aviso do painel manda rodar)
- `servidor/atender.sh` — duplo modo: `atender.sh <id>` (agente: lê porta/usuário do
  registro) ou `atender.sh <id> <usuario>` (sessão única, porta 10022); `-c 'cmd'`
  executa comando único; pré-voo detecta plataforma e privilégio
- `cliente/agente.ps1` — agente Windows (poll 20s, abre/fecha túnel, loga eventos)
- `cliente/desinstalar.ps1` + `desinstalar.cmd` gerado — remoção completa no Windows
- `cliente/template-agente.bat` / `cliente/template-agente.sh` — instaladores do agente
  (os .ps1 vão embutidos em base64 no .bat; renderizados pelo web.py na hora)
- Sessão única: `cliente/template.bat` / `cliente/template.sh` + `servidor/gerar-sessao.sh`

## Rastros no cliente

**Agente permanente (por design, tudo visível e reversível):** pasta
`C:\Program Files\SuporteRemoto` / `/opt/suporte-remoto` (chaves, agente, log, registro,
desinstalador), OpenSSH Server habilitado, chave do técnico no `administrators_authorized_keys`
/ `~root/.ssh/authorized_keys` (comentário `cliente:<id>:tecnico`), tarefa agendada
`SuporteRemoto` / serviço systemd `suporte-remoto`. Log local `agente.log` registra cada
abertura/fechamento de túnel. O desinstalador tira tudo e o servidor revoga a chave.

**Sessão única (tudo desfeito ao encerrar):**

| Item | Ao terminar |
|---|---|
| OpenSSH Server | desinstalado (só se foi ele quem instalou; senão restaura o estado) |
| Chave do técnico (authorized_keys) | removida; arquivo apagado se ficou vazio |
| cloudflared.exe + chaves no %TEMP% | pasta toda apagada |
| known_hosts | entrada removida |
| Logs de eventos do Windows | ficam (instalação/desinstalação) — intencional, transparência |

Fechamento brusco: a limpeza não roda, mas o acesso cai junto com a sessão; a próxima
sessão auto-limpa chaves antigas e o marcador em `%ProgramData%` faz o sshd ser removido
no fim dela. Sem túnel ativo não há caminho de acesso. No Linux a lógica é a mesma
(drop-in de PermitRootLogin desfeito, openssh-server removido só se foi o instalador).

## Segurança

- Chave do cliente no sshd: `restrict,port-forwarding,permitlisten="<porta dele>",permitopen="127.0.0.1:1",command="/bin/false"`
  → só abre o túnel reverso na própria porta; sem shell, sem execução, sem forward local
- Uma chave de túnel e uma porta por cliente (agente); chave do técnico única por cliente
  e guardada só no servidor (`servidor/clientes/<id>/`)
- Senha desabilitada no sshd (só chave pública); registro idempotente pela chave do túnel
- UAC é inevitável (burlá-lo é técnica de malware — não fazer)
- Chrome/Edge vão avisar que .bat "pode ser perigoso" — esperado; transparência é a resposta
- **Limitação assumida do laboratório:** `POST /agente/registrar` é aberto (sem auth) —
  quem descobrir a URL pode registrar uma máquina na fila (limite `LIMITE_CLIENTES=50`).
  Próximo passo: exigir um código de instalação que o técnico dê ao cliente
- Estado do servidor é auditável: `clientes.json` (quem tem acesso, desde quando,
  último contato) + `agente.log` no cliente (quando o técnico entrou/saiu)

## Teste local (sem Cloudflare e sem outra máquina)

    servidor/setup-sshd.sh
    servidor/gerar-sessao.sh teste
    servidor/testar-tunel.sh "$(cat servidor/sessoes/.ultima)"
    servidor/encerrar-sessao.sh "$(basename "$(cat servidor/sessoes/.ultima)")"
    servidor/testar-linux.sh    # E2E da sessão única no Linux: roda o instalador de verdade
    servidor/testar-agente.sh   # E2E do agente: registro -> conectar -> túnel -> atender -> encerrar -> remover
    servidor/testar-terminal.sh # E2E do terminal web: xterm + stream PTY + teclado + resize + renomear

## Limitações / próximos passos

- [ ] Testar o .bat do agente e o da sessão num Windows real (UAC + SmartScreen/Defender)
- [ ] Testar o .sh do agente num Linux desktop real (sudo + systemd + openssh-server)
- [ ] Instalar o app **Termux:Boot** (Play Store/F-Droid) para subir os serviços ao
      ligar o Android sem abrir o Termux — o script `~/.termux/boot/start-runit.sh`
      já está no lugar esperando
- [ ] Auth no `/agente/registrar` (código de instalação dado pelo técnico ao cliente)
- [ ] Auto-timeout da flag `conectar` (agente esquecido ligado com túnel aberto)
- [ ] Camada 3: IA = Claude Code no canal do técnico (Ollama descartado): comandos
      propostos passam pela aprovação no Termux e rodam via `atender.sh -c`;
      histórico visível no cliente ainda é ideia pendente
