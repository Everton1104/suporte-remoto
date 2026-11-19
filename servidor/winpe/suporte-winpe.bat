@echo off
setlocal EnableExtensions
title Suporte Remoto - WinPE
REM ============================================================
REM  SUPORTE REMOTO - modo WinPE (Hiren's BootCD PE / WinPE 10)
REM  Chave de sessao: winpe-20261111-1853
REM
REM  Diferente do instalador normal (instala o OpenSSH Server como
REM  recurso do Windows): aqui o OpenSSH PORTATIL e extraido e o
REM  sshd.exe roda direto, como processo de console. Nao usa
REM  certutil nem curl - tudo via PowerShell (presente no WinPE).
REM
REM  Zip do OpenSSH: primeiro procura ao lado deste .bat (pendrive,
REM  funciona sem internet), senao baixa do espelho do servidor.
REM  Tudo vive em %%TEMP%% (disco de RAM do WinPE): reiniciou, sumiu.
REM
REM  Esta janela e o painel da sessao. Pressione N para encerrar.
REM ============================================================

set "WORK=%TEMP%\suporte-winpe"
set "URL_BASE=https://suporte.evertonrs.com.br"

REM beacons: cada passo "canta" no servidor (wpe-beacons.log). As rotinas
REM :beacon/:beaconarq ficam NO FIM do arquivo — corpo de sub-rotina no
REM caminho linear do bat e executado de retes a retes e o exit /b dela
REM mata o script em silencio (bug de 11/11: o bat morria antes do banner)

echo.
echo   SUPORTE REMOTO - modo WinPE (winpe-20261111-1853)
call :beacon 01-inicio
echo   Preparando (automatico), aguarde...
echo   Voce esta logado como: %USERNAME%
echo.

REM --- 1) acha o zip do OpenSSH: pendrive ao lado do .bat, senao espelho ---
REM    SUPLIVRE aponta pra pasta do instalador de sessao que nos chamou
:acharzip
set "ZIP=%~dp0openssh-winpe-v95.zip"
if exist "%ZIP%" goto temzip
if defined SUPLIVRE if exist "%SUPLIVRE%openssh-winpe-v95.zip" set "ZIP=%SUPLIVRE%openssh-winpe-v95.zip"
if exist "%ZIP%" goto temzip
if not exist "%WORK%" mkdir "%WORK%"
set "ZIP=%WORK%\openssh-winpe-v95.zip"
if exist "%ZIP%" goto temzip
echo   Baixando OpenSSH portatil do espelho...
powershell -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri '%URL_BASE%/arquivos/openssh-winpe-v95.zip' -OutFile '%ZIP%'}catch{ Write-Host '   (' $_.Exception.Message ')' ; exit 1 }"
if not errorlevel 1 goto temzip
echo   Download com validacao de certificado falhou - WinPE as vezes nao tem
echo   a CA raiz. Tentando mais uma vez sem validar o certificado...
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; [Net.ServicePointManager]::ServerCertificateValidationCallback={$true}; try{ Invoke-WebRequest -UseBasicParsing -Uri '%URL_BASE%/arquivos/openssh-winpe-v95.zip' -OutFile '%ZIP%'}catch{ Write-Host '   (' $_.Exception.Message ')' ; exit 1 }"
if errorlevel 1 (
    echo.
    echo   FALHOU o download. Opcoes: verifique a rede deste WinPE com
    echo   ipconfig, ou copie openssh-winpe-v95.zip para a mesma pasta deste
    echo   .bat no pendrive e rode de novo.
    pause
    exit /b 1
)
:temzip
call :beacon 02-zip-ok
if not exist "%ZIP%" goto zipruim
for %%F in ("%ZIP%") do if %%~zF LSS 1000000 goto zipruim
REM    integridade: SHA256 embutido pelo gerar-winpe.sh. Download que
REM    chega corrompido extrai exe quebrado (popup 0xc0000142) porque
REM    o Expand-Archive NAO valida CRC. Vale pro pendrive tambem.
echo   Verificando integridade do zip...
powershell -NoProfile -Command "if((Get-FileHash -Algorithm SHA256 '%ZIP%').Hash -ne 'bd48fe985d400402c278c485db20e6a82bc4c7f7d8e0ef5a81128f523096530c'){Write-Host '   hash nao confere - arquivo corrompido'; exit 1}" || goto zipruim

REM --- 2) extrai e VALIDA: download truncado extrai exe quebrado que
REM     morre com popup "erro na inicializacao do aplicativo". Valida
REM     executando o ssh.exe do proprio zip - mesmas DLLs do sshd.
if not exist "%WORK%\OpenSSH-Win64\ssh.exe" powershell -NoProfile -Command "try{Expand-Archive -LiteralPath '%ZIP%' -DestinationPath '%WORK%' -Force}catch{exit 1}" || goto zipruim
if not exist "%WORK%\OpenSSH-Win64\sshd.exe" goto zipruim
"%WORK%\OpenSSH-Win64\ssh.exe" -V >nul 2>&1 || goto zipruim
call :beacon 03-extraido-ok
pushd "%WORK%\OpenSSH-Win64"

REM WinPE pode nao exportar ProgramData - sshd/ssh-keygen precisam
if not defined ProgramData set "ProgramData=%SystemDrive%\ProgramData"
mkdir "%ProgramData%\ssh" >nul 2>&1

echo   Gerando chaves do host...
ssh-keygen -A -N "" >nul 2>&1
call :beacon 04-chaves-ok
if not exist sshd_config copy /y sshd_config_default sshd_config >nul
call :beacon 05-config-ok

REM --- 3) autoriza o tecnico desta sessao (chave publica, 1 linha) ---
REM    via SID, a prova de idioma do Windows (Administradores/SYSTEM)
> "%ProgramData%\ssh\administrators_authorized_keys" echo ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPawMovoyqDwzhM/4nhmTJ7RzCkFAFCljePgs5sf08EE suporte:winpe
icacls "%ProgramData%\ssh\administrators_authorized_keys" /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" >nul
call :beacon 06-authkeys-ok

REM --- 4) sobe o sshd como processo de console (nao e servico) ---
REM     WinPE pode ter firewall ativo: libera a entrada na porta 22
REM     (sem isso o teste LOCAL passa mas o tecnico nao conecta de fora;
REM     se o servico de firewall nao rodar, o comando falha mudo)
netsh advfirewall firewall add rule name="suporte-winpe-sshd" dir=in action=allow protocol=TCP localport=22 >nul 2>&1
echo   Subindo servidor SSH...
REM     start DIRETO do exe: wrapper cmd /c entre o start e o sshd deu
REM     popup 0xc0000142 em campo (DLL init); direto foi como a porta
REM     22 ja abriu com sucesso nesta mesma maquina
start "sshd suporte" /min sshd.exe -f "%CD%\sshd_config" -E "%WORK%\sshd.log"
call :beacon 08-sshd-startou

REM --- 5) confirma que a porta 22 responde (UMA vez, 5s) ------------
REM     6/11: nesta ISO o sshd.exe morre no nascimento (crash de DLL
REM     init; -t passa, log nem abre). Retentativas e Get-Process
REM     travavam o loop — agora: 1 teste rapido e, sem porta, direto
REM     pro MODO COMANDO REMOTO (o tecnico diagnostica por la).
ping -n 6 127.0.0.1 >nul
powershell -NoProfile -Command "$c=New-Object Net.Sockets.TcpClient; try{$c.Connect('127.0.0.1',22); exit 0}catch{exit 1}finally{$c.Close()}"
if not errorlevel 1 goto portaok
call :beacon 30-FALHOU-porta-22
goto modoshell

:portaok
call :beacon 20-SESSAO-ATIVA
echo   [passo: porta 22 OK]

echo.
echo   ============================================================
echo     SESSAO WINPE ATIVA  (winpe-20261111-1853)
echo     IPs desta maquina:
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1'} | ForEach-Object { Write-Host ('      ' + $_.IPAddress) }"
echo     Avise o tecnico do IP acima. Pode minimizar esta janela.
echo     Para encerrar: feche esta janela ou Ctrl+C. Ao reiniciar a
echo     maquina, tudo desta sessao e apagado.
echo   ============================================================
echo.

REM --- 6) mantem a sessao viva ate o sshd cair ou fechar a janela ---
REM     WinPE pode nao ter choice nem timeout: ping faz o papel de sleep.
:espera
ping -n 6 127.0.0.1 >nul
powershell -NoProfile -Command "if(Get-Process sshd -ErrorAction SilentlyContinue){exit 0}else{exit 1}"
if errorlevel 1 goto limpeza
goto espera

:zipruim
if "%RETRY%"=="1" goto zipruimfim
echo   O zip veio incompleto ou a extracao falhou - limpando e
echo   tentando de novo com download novo...
set "RETRY=1"
rd /s /q "%WORK%\OpenSSH-Win64" >nul 2>&1
del /f /q "%WORK%\openssh-winpe-v95.zip" >nul 2>&1
del /f /q "%~dp0openssh-winpe-v95.zip" >nul 2>&1
goto acharzip
:zipruimfim
echo.
echo   FALHOU: openssh-winpe-v95.zip chegou corrompido duas vezes.
echo   Internet instavel? Tente de novo mais tarde ou copie o
echo   arquivo pelo pendrive de outra maquina.
pause
exit /b 1

REM ============ LIMPEZA ============
:limpeza
echo.
echo   Encerrando e removendo componentes desta sessao...
netsh advfirewall firewall delete rule name="suporte-winpe-sshd" >nul 2>&1
popd >nul 2>&1
taskkill /F /IM sshd.exe >nul 2>&1
taskkill /F /IM ssh-auth.exe >nul 2>&1
taskkill /F /IM ssh-shellhost.exe >nul 2>&1
del /f /q "%ProgramData%\ssh\administrators_authorized_keys" >nul 2>&1
del /f /q "%WORK%\openssh-winpe-v95.zip" >nul 2>&1
rd /s /q "%WORK%" >nul 2>&1
echo   Sessao encerrada. (WinPE e volatil: ao reiniciar nada sobra.)
pause
exit /b 0

:modoshell
echo   ============================================================
echo     MODO COMANDO REMOTO ATIVO (sshd nao sobe neste PE)
echo     Deixe esta janela ABERTA: o tecnico controla a maquina
echo     pelo servidor (busca comando a cada ~7s e devolve a
echo     saida). Fechou a janela ou reiniciou, encerrou.
echo   ============================================================
call :beacon 40-MODO-COMANDO-ATIVO
:msloop
powershell -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $r=(iwr -UseBasicParsing '%URL_BASE%/wpecmd/667a727b04979af77ce6b040' -TimeoutSec 8).Content; if($r -and $r -ne 'vazio'){ $o=(iex $r 2>&1|Out-String); $t=$o.Substring(0,[Math]::Min(3000,$o.Length)); iwr -UseBasicParsing ('%URL_BASE%/wpebeacon/OUT-'+[uri]::EscapeDataString($t)) -TimeoutSec 8|Out-Null }}catch{}"
ping -n 4 127.0.0.1 >nul
goto msloop

REM ---- sub-rotinas de beacon (NO FIM: nunca no caminho linear!) ----
:beacon
powershell -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; iwr -UseBasicParsing ('%URL_BASE%/wpebeacon/'+[uri]::EscapeDataString('%~1')) -TimeoutSec 4}catch{}" >nul 2>&1
exit /b
:beaconarq
powershell -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $l=Get-Content '%~1' -Raw; if($l){iwr -UseBasicParsing ('%URL_BASE%/wpebeacon/'+[uri]::EscapeDataString($l.Substring(0,[Math]::Min(2000,$l.Length)))) -TimeoutSec 4}}catch{}" >nul 2>&1
exit /b
