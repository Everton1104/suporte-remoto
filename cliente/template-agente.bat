@echo off
setlocal EnableExtensions
title Suporte Remoto - Instalador

REM ============================================================
REM  SUPORTE REMOTO - INSTALADOR DO AGENTE PERMANENTE
REM
REM  Isto instala ACESSO REMOTO PERMANENTE de suporte tecnico
REM  (Everton - ssh.evertonrs.com.br). O tecnico so entra quando
REM  voce pedir atendimento, e cada entrada dele fica registrada
REM  em C:\Program Files\SuporteRemoto\agente.log
REM  Para remover a qualquer momento:
REM  C:\Program Files\SuporteRemoto\desinstalar.cmd
REM ============================================================

REM --- 0) elevacao: UAC = consentimento unico ---
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo   Este programa precisa de permissao de administrador.
    echo   O Windows vai pedir confirmacao - clique em SIM.
    powershell -NoProfile -Command "try{Start-Process -FilePath '%~f0' -Verb RunAs}catch{exit 1}"
    if errorlevel 1 (
        echo   Permissao negada. Nada foi alterado neste computador.
        pause
    )
    exit /b
)

set "DIR=C:\Program Files\SuporteRemoto"
set "AK=C:\ProgramData\ssh\administrators_authorized_keys"
set "URL=__URL_BASE__"

echo.
echo   Instalando o agente de suporte remoto (automatico)...
echo.

REM --- 1) baixador, em ordem de preferencia: (a) curl do proprio Windows
REM     (10 1803+); (b) o curl EMBUTIDO neste .bat (base64 decodificado
REM     com certutil) - maquina velha sem curl nao baixa nada a mais;
REM     (c) espelho no servidor via certutil (existe em TODO Windows
REM     desde o Vista). O nosso exe e build LibreSSL: HTTPS precisa do
REM     bundle CA do lado (o curl do Windows usa o store nativo).
where curl >nul 2>&1 || goto curldl
set "CURL=curl"
set "CURLCA= "
goto curlok
:curldl
set "CBIN=%TEMP%\suporte-curl"
if not exist "%CBIN%" mkdir "%CBIN%"
echo   Este Windows nao tem curl - preparando o embutido (uns segundos)...
call :curl-embutido
if not exist "%CBIN%\curl.exe" goto curlnet
if not exist "%CBIN%\curl-ca-bundle.crt" goto curlnet
goto curlchk
:curlnet
echo   curl embutido indisponivel - baixando do espelho...
certutil -urlcache -split -f "%URL%/arquivos/curl-ca-bundle.crt" "%CBIN%\curl-ca-bundle.crt" >nul
certutil -urlcache -split -f "%URL%/arquivos/curl.exe" "%CBIN%\curl.exe" >nul
:curlchk
if not exist "%CBIN%\curl.exe" goto curlruim
if not exist "%CBIN%\curl-ca-bundle.crt" goto curlruim
for %%F in ("%CBIN%\curl.exe") do if %%~zF LSS 3000000 goto curlruim
"%CBIN%\curl.exe" --version >nul 2>&1 || goto curlruim
set "CURL=%CBIN%\curl.exe"
set "CURLCA=--cacert "%CBIN%\curl-ca-bundle.crt""
goto curlok
:curlruim
echo   FALHOU: sem curl no Windows e nem o embutido nem o espelho
echo   responderam. Internet/proxy ok? Tente de novo.
pause
exit /b 1
:curlok

REM --- 2) OpenSSH Server (zip espelhado no nosso servidor = segundos;
REM     Windows Update fica como plano B se o nosso servidor nao responder) ---
sc query sshd >nul 2>&1
if errorlevel 1 (
    echo   Instalando OpenSSH Server...
    call :baixar "%TEMP%\openssh.zip" "%URL%/arquivos/openssh-win64.zip" "OpenSSH" || call :baixar "%TEMP%\openssh.zip" "https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip" "OpenSSH"
    if not errorlevel 1 (
        powershell -NoProfile -Command "Expand-Archive -Force \"$env:TEMP\openssh.zip\" 'C:\Program Files'" >nul
        powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\OpenSSH-Win64\install-sshd.ps1" >nul
        netsh advfirewall firewall show rule name="OpenSSH-sshd" >nul 2>&1 || netsh advfirewall firewall add rule name="OpenSSH-sshd" dir=in action=allow protocol=TCP localport=22 >nul
    ) else (
        echo   Nosso servidor nao respondeu - Windows Update entao ^(demora minutos^)...
        powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0" >nul
    )
)
sc config sshd start= auto >nul 2>&1
sc query sshd | findstr /I "RUNNING" >nul || net start sshd >nul

REM --- 3) PowerShell como shell padrao do SSH (comandos caem direto nele) ---
reg add "HKLM\SOFTWARE\OpenSSH" /v DefaultShell /t REG_SZ /d "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" /f >nul

REM --- 4) pasta de trabalho + chave do tunel (gerada AQUI, persistente) ---
REM     o zip do passo 2 ja trouxe o cliente ssh inteiro (ssh, ssh-keygen) e o
REM     install-sshd poe a pasta no PATH da maquina: usar esses binarios deixa o
REM     Windows Update FORA do caminho - so entra se faltar o zip E o cliente
if not exist "%DIR%" mkdir "%DIR%"
set "KEYGEN=C:\Program Files\OpenSSH-Win64\ssh-keygen.exe"
if not exist "%KEYGEN%" (
    set "KEYGEN=ssh-keygen"
    where ssh-keygen >nul 2>&1 || powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" >nul
)
if not exist "%DIR%\chave-tunel" "%KEYGEN%" -q -t ed25519 -N "" -f "%DIR%\chave-tunel" -C "suporte-remoto"
REM     o cliente ssh do Windows so usa chave com ACL apertada E dono SYSTEM
REM     (dono = usuario que instalou reprova o cheque quando a tarefa roda
REM     como SYSTEM). SIDs e nao nomes: maquina de dominio sem contato com
REM     o DC nao resolve "Administrators" (reprovou em campo nessa situacao).
REM     O /inheritance:r NAO tira o ACE explicito do usuario que gerou a
REM     chave (materializado do CREATOR OWNER no keygen) - tem que /remove,
REM     senao o ssh reprova a propria chave (reprovou no adjundiai11, virgem)
icacls "%DIR%\chave-tunel" /inheritance:r /grant "*S-1-5-18:F" "*S-1-5-32-544:F" >nul 2>&1
icacls "%DIR%\chave-tunel" /remove "%USERDOMAIN%\%USERNAME%" >nul 2>&1
icacls "%DIR%\chave-tunel" /setowner "*S-1-5-18" >nul 2>&1

REM --- 5) cloudflared (do nosso espelho; GitHub como plano B) ---
REM     re-baixa se faltar, vier truncado (< 5 MB) ou quebrado (nao executa):
REM     uma instalacao cancelada no meio do download deixa arquivo parcial
if not exist "%DIR%\cloudflared.exe" goto cfdl
for %%F in ("%DIR%\cloudflared.exe") do if %%~zF LSS 5000000 goto cfdl
"%DIR%\cloudflared.exe" --version >nul 2>&1 || goto cfdl
goto cfok
:cfdl
call :baixar "%DIR%\cloudflared.exe" "%URL%/arquivos/cloudflared-windows-amd64.exe" "cloudflared" || call :baixar "%DIR%\cloudflared.exe" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" "cloudflared"
if not exist "%DIR%\cloudflared.exe" (
    echo   FALHOU: download do cloudflared. Internet/proxy ok? Tente de novo.
    pause
    exit /b 1
)
:cfok

REM --- 6) registra no servidor (idempotente: mesma chave = mesmo cliente) ---
REM     JSON montado à mão: chave_tunel via ConvertTo-Json garante string escapada
REM     (hashtable + ConvertTo-Json no PS 5.1 já mandou objeto onde era string)
echo   Registrando no servidor...
powershell -NoProfile -Command "$pub = (Get-Content '%DIR%\chave-tunel.pub') -join ' '; $b = '{\"nome\":\"%COMPUTERNAME%\",\"maquina\":\"%COMPUTERNAME%\",\"so\":\"windows\",\"usuario\":\"%USERNAME%\",\"chave_tunel\":' + ($pub | ConvertTo-Json) + '}'; $r = Invoke-RestMethod -Uri '%URL%/agente/registrar' -Method Post -ContentType 'application/json' -Body $b; $r | ConvertTo-Json | Set-Content -Path '%DIR%\registro.json'"
if not exist "%DIR%\registro.json" (
    echo   FALHOU: nao deu para registrar no servidor. Internet ok? Tente de novo.
    pause
    exit /b 1
)

REM --- 7) instala a chave publica do tecnico DESTE cliente ---
for /f "usebackq delims=" %%K in (`powershell -NoProfile -Command "(Get-Content '%DIR%\registro.json' | ConvertFrom-Json).pubkey_tecnico"`) do set "PUBTEC=%%K"
if not exist "%AK%" type nul > "%AK%"
findstr /C:"%PUBTEC%" "%AK%" >nul || >> "%AK%" echo %PUBTEC%
icacls "%AK%" /inheritance:r /grant "*S-1-5-32-544:F" "*S-1-5-18:F" >nul

REM --- 8) para o agente antigo ANTES de reescrever os arquivos ---
REM     o powershell em execucao mantem agente.ps1 aberto: sobrescrever com
REM     ele vivo falha em silencio (certutil nao escreve) e a tarefa sobe
REM     com o agente VELHO. Mata tambem zumbis de instalacoes antigas:
REM     apagar a pasta ou schtasks /delete NAO matam processo nenhum, e
REM     orfaos acumulam brigando pela porta do proxy local (2222).
REM     -ne $PID impede o kill de se matar (ele contem 'agente.ps1' na linha)
taskkill /f /im cloudflared.exe >nul 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object {$_.CommandLine -like '*agente.ps1*' -and $_.ProcessId -ne $PID} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='ssh.exe'\" | Where-Object {$_.CommandLine -like '*chave-tunel*'} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
schtasks /end /tn SuporteRemoto >nul 2>&1
schtasks /delete /tn SuporteRemoto /f >nul 2>&1

REM --- 9) escreve o agente e o desinstalador (embutidos em base64) ---
>  "%DIR%\b64.tmp" echo __AGENTE_PS1_B64__
certutil -decode "%DIR%\b64.tmp" "%DIR%\agente.ps1" >nul
>  "%DIR%\b64.tmp" echo __DESINSTALAR_PS1_B64__
certutil -decode "%DIR%\b64.tmp" "%DIR%\desinstalar.ps1" >nul
del "%DIR%\b64.tmp" >nul 2>&1
>  "%DIR%\desinstalar.cmd" echo @echo off
>> "%DIR%\desinstalar.cmd" echo powershell -NoProfile -ExecutionPolicy Bypass -File "%%~dp0desinstalar.ps1"
>> "%DIR%\desinstalar.cmd" echo pause

REM --- 9b) comandos do tecnico no System32: suporte-mensagem (popup OK) e
REM     suporte-pergunta (input com resposta) para uso dentro da sessao do
REM     cliente; CRLF/BOM ja vem embutidos no base64
>  "%DIR%\b64.tmp" echo __MSG_CMD_B64__
certutil -decode "%DIR%\b64.tmp" "C:\Windows\System32\suporte-mensagem.cmd" >nul
>  "%DIR%\b64.tmp" echo __PERG_CMD_B64__
certutil -decode "%DIR%\b64.tmp" "C:\Windows\System32\suporte-pergunta.cmd" >nul
>  "%DIR%\b64.tmp" echo __PERG_PS1_B64__
certutil -decode "%DIR%\b64.tmp" "C:\Windows\System32\suporte-pergunta-run.ps1" >nul
del "%DIR%\b64.tmp" >nul 2>&1

REM --- 10) servico: tarefa agendada no boot, SYSTEM, sempre rodando ---
schtasks /create /tn SuporteRemoto /sc onstart /delay 0001:00 /ru SYSTEM /rl HIGHEST /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%DIR%\agente.ps1\"" >nul
schtasks /run /tn SuporteRemoto >nul 2>&1

echo.
echo   ============================================================
echo     AGENTE INSTALADO
echo     Quando precisar de suporte, apenas chame o tecnico - nao
echo     e preciso fazer mais nada. Cada acesso do tecnico fica
echo     registrado em %DIR%\agente.log
echo     Para remover: %DIR%\desinstalar.cmd
echo   ============================================================
pause
exit /b 0

REM --- baixa mostrando pontos: curl roda em 2o plano e a janela vai
REM     pontuando ate ele terminar - o usuario ve movimento e nao fecha
REM     achando que travou (55 MB podem levar minutos em rede lenta).
REM     %CURL%/%CURLCA% vem do passo 1 (curl do sistema ou o nosso).
REM     uso: call :baixar "destino" "url" "nome amigavel"
:baixar
<nul set /p dummy="   Baixando %~3 "
start "" /b "%CURL%" -sL -f %CURLCA% --connect-timeout 20 --speed-time 30 --speed-limit 51200 -o "%~1" "%~2"
:baiando
ping -n 2 127.0.0.1 >nul
<nul set /p dummy=.
tasklist /fi "imagename eq curl.exe" 2>nul | find /i "curl.exe" >nul && goto baiando
echo.
if exist "%~1" exit /b 0
exit /b 1

REM --- curl.exe + bundle CA embutidos em base64 (linhas geradas pelo
REM     render do web.py, ~1.400 echos de 4 KB cada): certutil -decode
REM     monta os arquivos e o base64 e apagado. Alfabeto base64 nao tem
REM     nenhum caractere especial do cmd, vai cru mesmo. Validacao de
REM     tamanho/execucao fica no passo 1, depois do call.
:curl-embutido
if exist "%CBIN%\curl.exe" exit /b 0
__CURL_EMBUTIDO__
exit /b 0
