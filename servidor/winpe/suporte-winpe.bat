@echo off
setlocal EnableExtensions
title Suporte Remoto - WinPE
REM ============================================================
REM  SUPORTE REMOTO - modo WinPE (Hiren's BootCD PE / WinPE 10)
REM  Chave de sessao: winpe-20261103
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

echo.
echo   SUPORTE REMOTO - modo WinPE (winpe-20261103)
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
pushd "%WORK%\OpenSSH-Win64"

REM WinPE pode nao exportar ProgramData - sshd/ssh-keygen precisam
if not defined ProgramData set "ProgramData=%SystemDrive%\ProgramData"
mkdir "%ProgramData%\ssh" >nul 2>&1

echo   Gerando chaves do host...
ssh-keygen -A -N "" >nul 2>&1
if not exist sshd_config copy /y sshd_config_default sshd_config >nul

REM --- 3) autoriza o tecnico desta sessao (chave publica, 1 linha) ---
REM    via SID, a prova de idioma do Windows (Administradores/SYSTEM)
> "%ProgramData%\ssh\administrators_authorized_keys" echo ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPawMovoyqDwzhM/4nhmTJ7RzCkFAFCljePgs5sf08EE suporte:winpe
icacls "%ProgramData%\ssh\administrators_authorized_keys" /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" >nul

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
ping -n 4 127.0.0.1 >nul

REM --- 5) confirma que a porta 22 responde ---
powershell -NoProfile -Command "$c=New-Object Net.Sockets.TcpClient; try{$c.Connect('127.0.0.1',22); exit 0}catch{exit 1}finally{$c.Close()}"
if errorlevel 1 (
    echo.
    echo   FALHOU: o sshd nao abriu a porta 22. Diagnostico completo:
    "%CD%\sshd.exe" -t -f "%CD%\sshd_config" > "%WORK%\sshd-teste.txt" 2>&1
    powershell -NoProfile -Command "if(Test-Path '%WORK%\sshd-teste.txt'){Get-Content '%WORK%\sshd-teste.txt'}"
    powershell -NoProfile -Command "if(Test-Path '%WORK%\sshd.err'){Get-Content '%WORK%\sshd.err'}"
    powershell -NoProfile -Command "if(Test-Path '%WORK%\sshd.log'){Get-Content '%WORK%\sshd.log' -Tail 10}"
    echo   ---
    echo   Host keys presentes em %ProgramData%\ssh :
    dir /b "%ProgramData%\ssh\ssh_host_*" 2>nul
    echo   ---
    pause
    goto limpeza
)

echo.
echo   ============================================================
echo     SESSAO WINPE ATIVA  (winpe-20261103)
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
tasklist /FI "IMAGENAME eq sshd.exe" 2>nul | find /I "sshd.exe" >nul || goto limpeza
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
