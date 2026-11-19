# agente.ps1 - Suporte Remoto Everton (agente permanente, Windows)
# Roda como SYSTEM via tarefa agendada "SuporteRemoto". Mantem o tunel reverso
# aberto SOMENTE enquanto o tecnico pedir pelo painel (poll a cada 20s).
# Cada evento fica registrado em agente.log ao lado deste arquivo.
$ErrorActionPreference = 'SilentlyContinue'
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg = Get-Content (Join-Path $d 'registro.json') | ConvertFrom-Json
$url = '__URL_BASE__'
$log = Join-Path $d 'agente.log'
function Log($m) { ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Add-Content -Path $log }
# ultimas linhas do stderr do cloudflared/ssh entram no agente.log (diagnostico sem RDP)
function Ult($arq, $n) { if (Test-Path $arq) { Get-Content $arq -Tail $n | ForEach-Object { Log "  | $_" } } }

Log "agente iniciado (id=$($reg.id) porta=$($reg.porta) pid=$PID)"
# zumbi de execucao anterior pode estar segurando a porta do proxy local (2222)
Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
# cliente ssh: o zip espelhado instala em Program Files\OpenSSH-Win64 (e poe no
# PATH da maquina); preferir o caminho explicito e nao depender do PATH herdar
$sshExe = 'ssh'
if (Test-Path 'C:\Program Files\OpenSSH-Win64\ssh.exe') { $sshExe = 'C:\Program Files\OpenSSH-Win64\ssh.exe' }
$cf = $null
$ssh = $null
while ($true) {
    $e = $null
    try { $e = Invoke-RestMethod -TimeoutSec 10 -Uri "$url/agente/estado?id=$($reg.id)" } catch {}
    # painel pediu remocao: auto-desinstalacao. Funciona ate offline — a flag
    # fica no servidor e este ramo roda no primeiro poll que der conta.
    # desinstalar.ps1 mata este processo, apaga a pasta e chama /agente/remover
    # para revogar o resto (chave do tunel, registro).
    if ($null -ne $e -and $e.remover) {
        Log "servidor pediu desinstalacao - executando desinstalar.ps1"
        Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $d 'desinstalar.ps1')
        exit
    }
    # auto-update do cloudflared: servidor manda cf_versao no estado; se
    # divergir do cf-versao.txt local, baixa o exe novo do espelho e troca
    # (somente com tunel fechado, pra nao derrubar sessao em andamento)
    if ($null -ne $e -and $e.cf_versao -and $null -eq $ssh) {
        $arq_versao = Join-Path $d 'cf-versao.txt'
        $versao_local = ''
        if (Test-Path $arq_versao) { $versao_local = (Get-Content $arq_versao -Raw).Trim() }
        if ($versao_local -ne "$($e.cf_versao)".Trim()) {
            Log "atualizando cloudflared para $($e.cf_versao) (local: $versao_local)"
            try {
                $novo = Join-Path $env:TEMP 'cloudflared-novo.exe'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri "$url/arquivos/cloudflared-windows-amd64.exe" -OutFile $novo -UseBasicParsing -TimeoutSec 120
                if ((Get-Item $novo).Length -gt 5000000) {
                    Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
                    Start-Sleep -Seconds 1
                    Move-Item $novo (Join-Path $d 'cloudflared.exe') -Force
                    Set-Content $arq_versao "$($e.cf_versao)"
                    Log "cloudflared atualizado para $($e.cf_versao)"
                } else { Log "download veio truncado, tentarei de novo no proximo poll" }
            } catch { Log "falha ao atualizar cloudflared: $($_.Exception.Message)" }
        }
    }
    # cloudflared morto com túnel pedido: recomeça (antes o agente travava para sempre)
    if ($null -ne $cf -and $cf.HasExited) {
        Log "cloudflared caiu (exit $($cf.ExitCode)):"
        Ult (Join-Path $d 'cloudflared.log') 4
        $cf = $null
    }
    if ($null -ne $e -and $e.conectar -and $null -eq $ssh) {
        if ($null -eq $cf) {
            Log "subindo cloudflared"
            $cf = Start-Process -FilePath (Join-Path $d 'cloudflared.exe') -WindowStyle Hidden -PassThru `
                -RedirectStandardError (Join-Path $d 'cloudflared.log') `
                -ArgumentList @('access','tcp','--hostname','__DOMINIO__','--url','localhost:__PORTA_PROXY__')
            Start-Sleep -Seconds 6
        }
        if ($null -eq $cf) { Log "cloudflared nao subiu (exe existe? antivirus bloqueiou?)" }
        elseif ($cf.HasExited) {
            Log "cloudflared morreu logo ao subir (exit $($cf.ExitCode)):"
            Ult (Join-Path $d 'cloudflared.log') 6
            $cf = $null
        }
        else {
            Log "abrindo tunel reverso (porta $($reg.porta)) - tecnico conectado por ssh"
            $ssh = Start-Process -FilePath $sshExe -WindowStyle Hidden -PassThru `
                -RedirectStandardError (Join-Path $d 'ssh-tunel.log') `
                -ArgumentList @(
                # Start-Process -ArgumentList junta os args com espaco SEM citar:
                # caminho com espaco ("C:\Program Files\...") tem que levar aspas
                # proprias, senao o ssh recebe "C:\Program" e "Files\..." separados
                '-v','-N','-i',('"{0}"' -f (Join-Path $d 'chave-tunel')),'-p','__PORTA_PROXY__','suporte@localhost',
                '-o','StrictHostKeyChecking=accept-new','-o','ExitOnForwardFailure=yes',
                '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=4',
                '-o','HostKeyAlgorithms=ssh-ed25519',
                '-R',("$($reg.porta):localhost:22"))
            if ($null -eq $ssh) { Log "ssh nao subiu (OpenSSH client instalado?)" }
        }
    }
    elseif ($null -ne $e -and -not $e.conectar -and $null -ne $ssh) {
        Log "fechando tunel reverso - tecnico encerrou"
        if ($ssh -and -not $ssh.HasExited) { Stop-Process -Id $ssh.Id -Force }
        $ssh = $null
        if ($cf -and -not $cf.HasExited) { Stop-Process -Id $cf.Id -Force }
        $cf = $null
    }
    elseif ($null -ne $ssh -and $ssh.HasExited) {
        Log "tunel caiu sozinho (exit $($ssh.ExitCode)); ultimas linhas do ssh:"
        Ult (Join-Path $d 'ssh-tunel.log') 8
        $ssh = $null
    }
    Start-Sleep -Seconds 20
}
