# Mesa Feelworld LivePro L1 — PC do Will (adjundiai39-8a17)

Rodízio automático de câmeras (cam1=1min / cam2=2min vigente; config em
`C:\Scripts\mesa-config.json`). Script de referência: `mesa-feelworld-l1-ui.ps1`
(v5) — cópia do que roda no Will em `C:\Scripts\mesa-ui.ps1`.

Protocolo e aprendizados completos: memória do projeto (feelworld-l1-protocolo-udp).
Regra de ouro: **nunca enviar o poll F1 40 01 (status 22) — envenena a L1**.

## O que está instalado (Will)

- Tarefa agendada `mesa-ui` (ONSTART, SYSTEM) → `C:\Scripts\mesa-svc.cmd`
  (wrapper em loop, relança em 5s) → `C:\Scripts\mesa-ui.ps1` (HTTP :8123)
- `C:\Scripts\mesa-config.json` (tempos + estado, retomado no boot)
- `C:\Scripts\mesa-remove.bat` — **desinstalador completo do serviço**
- Regra de firewall "Mesa UI 8123" (acesso direto pela LAN)

## Acesso remoto

`https://cam.evertonrs.com.br` → cloudflared (ingress no
`/root/.cloudflared/config.yml`) → `ssh -L 127.0.0.1:8123:...` (porta 10027,
túnel reverso do cliente) → UI no Will. Watchdog que religa o ssh:
`servidor/watch-cam.sh`, rodando como **serviço runit `watch-cam` no Termux**
(`var/service/watch-cam/run`, log `/var/log/svc/watch-cam.log`) — sobrevive a
reboot do servidor (22/11). Hosts do WTG tem linha `# mesa-cam` apontando o
domínio pra edge da Cloudflare (remover quando o DNS propagar).

## Desmontagem total (fim da maratona)

1. **Serviço no Will**: rodar `C:\Scripts\mesa-remove.bat` localmente
   (remove tarefa, arquivos e regra de firewall)
2. **Túnel/acesso**: pedir ao operador (claude-servidor) para encerrar o elo —
   mata o watchdog `watch-cam.sh`, remove o ingress `cam.evertonrs.com.br` do
   cloudflared e a linha do hosts do WTG
3. Túnel reverso do cliente (botão do painel) fecha a qualquer momento — não
   faz parte do serviço da mesa
