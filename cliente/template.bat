@echo off
setlocal EnableExtensions
title Suporte Remoto
REM ============================================================
REM  SUPORTE REMOTO - sessao __SESSION__
REM  Cliente: __CLIENTE__
REM
REM  Fluxo automatico apos UM clique de confirmacao (UAC):
REM    [Sim] -> prepara servidor SSH -> abre tunel seguro ->
REM    aguarda/realiza atendimento -> ao fim remove TUDO
REM    desta sessao (chave, servico, arquivos temporarios)
REM
REM  Esta janela e o painel da sessao: pode ser minimizada.
REM  Pressione N nela para encerrar o suporte a qualquer momento.
REM ============================================================

REM --- 0) sem privilegios? se reeleva via UAC (1 clique) e sai ---
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo   Este programa precisa de permissao de administrador.
    echo   O Windows vai pedir confirmacao - clique em SIM.
    powershell -NoProfile -Command "try{Start-Process -FilePath '%~f0' -Verb RunAs}catch{exit 1}"
    if errorlevel 1 (
        echo.
        echo   Permissao negada. Nada foi alterado neste computador.
        pause
    )
    exit /b
)

set "WORK=%TEMP%\suporte-remoto"
set "AK=C:\ProgramData\ssh\administrators_authorized_keys"
set "MARCADOR=%ProgramData%\suporte-remoto.instalado"
set "FLAG=%ProgramData%\suporte-remoto.encerrar"

echo.
echo   SUPORTE REMOTO - sessao __SESSION__
echo   Preparando (automatico), aguarde...
echo.

REM --- 1) registra o estado original do servico SSH (para restaurar depois) ---
REM    INSTALAMOS=1 -> fomos nos que instalamos (agora ou numa sessao
REM    anterior fechada de brusco: o marcador em ProgramData conta a historia)
REM    RODAVA=1    -> o servico ja estava rodando antes de nos chegarmos
set "INSTALAMOS=0"
set "RODAVA=0"
if exist "%MARCADOR%" set "INSTALAMOS=1"
sc query sshd >nul 2>&1
if errorlevel 1 (
    set "INSTALAMOS=1"
) else (
    sc query sshd | findstr /I "RUNNING" >nul && set "RODAVA=1"
)

REM --- 2) auto-limpeza: tira chaves de sessoes antigas que ficaram para tras ---
if exist "%AK%" (
    findstr /V /C:"sessao:" "%AK%" > "%AK%.novo"
    move /y "%AK%.novo" "%AK%" >nul
    icacls "%AK%" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" >nul
)

REM --- 3) garante o servidor SSH do Windows rodando (OpenSSH Server, Win10 1809+) ---
sc query sshd >nul 2>&1
if errorlevel 1 (
    echo   Instalando OpenSSH Server, pode demorar alguns minutos...
    powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0" >nul
    powershell -NoProfile -Command "Set-Service sshd -StartupType Automatic" >nul
    type nul > "%MARCADOR%"
)
sc query sshd | findstr /I "RUNNING" >nul || net start sshd >nul

REM --- 4) instala a chave publica do tecnico (direito de diagnostico desta sessao) ---
echo __PUBKEY_TECNICO__>> "%AK%"
icacls "%AK%" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" >nul

REM --- 5) baixa o cloudflared (binario oficial assinado pela Cloudflare) ---
if not exist "%WORK%" mkdir "%WORK%"
if not exist "%WORK%\cloudflared.exe" (
    echo   Baixando cloudflared...
    curl -L -o "%WORK%\cloudflared.exe" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe
)

REM --- 6) reconstrui a chave efemera desta sessao (veio embutida em base64) ---
>  "%WORK%\chave.b64" echo __CHAVE_CLIENTE_B64__
certutil -decode "%WORK%\chave.b64" "%WORK%\chave_cliente" >nul

REM --- 7) tunel local ate o servidor (SSH via HTTPS da Cloudflare) ---
start "suporte-remoto tunel" /min "%WORK%\cloudflared.exe" access tcp --hostname __DOMINIO__ --url localhost:__PORTA_PROXY__
timeout /t 6 /nobreak >nul

REM --- 8) tunel REVERSO em segundo plano: a porta __PORTA_REVERSA__ do servidor
REM        passa a apontar de volta para este PC ---
start /b ssh -N -i "%WORK%\chave_cliente" -p __PORTA_PROXY__ ^
    -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes ^
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 ^
    -R __PORTA_REVERSA__:localhost:22 suporte@localhost

echo.
echo   ============================================================
echo     SESSAO ATIVA  (sessao __SESSION__)
echo     Usuario do Windows: %USERNAME%
echo     Pode minimizar esta janela e avisar o tecnico.
echo     Pressione N para encerrar o suporte a qualquer momento.
echo   ============================================================
echo.

REM --- 9) aguarda: tecla N / tecnico encerrar / conexao cair ---
:espera
choice /C SN /D S /T 3 /N >nul
if errorlevel 2 goto limpeza
if exist "%FLAG%" goto limpeza
tasklist /FI "IMAGENAME eq ssh.exe" 2>nul | find /I "ssh.exe" >nul || goto limpeza
goto espera

REM ============ LIMPEZA - sessao unica, sem rastros de acesso ============
:limpeza
echo.
echo   Encerrando e removendo componentes desta sessao...

taskkill /F /IM ssh.exe >nul 2>&1
taskkill /IM cloudflared.exe /F >nul 2>&1
del "%FLAG%" >nul 2>&1

REM remove a chave do tecnico (deixa o arquivo como estava antes)
if exist "%AK%" (
    findstr /V /C:"sessao:__SESSION__:tecnico" "%AK%" > "%AK%.novo"
    move /y "%AK%.novo" "%AK%" >nul
    icacls "%AK%" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" >nul
    for %%A in ("%AK%") do if %%~zA equ 0 del "%AK%" >nul 2>&1
)

REM servidor SSH: remove se fomos nos que instalamos;
REM se ja existia, so para se nao estava rodando antes
if "%INSTALAMOS%"=="1" (
    echo   Removendo OpenSSH Server, pode demorar um pouco...
    net stop sshd >nul 2>&1
    powershell -NoProfile -Command "Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0" >nul
    del "%MARCADOR%" >nul 2>&1
) else if "%RODAVA%"=="0" (
    net stop sshd >nul 2>&1
)

REM apaga tudo que baixou/gerou (inclusive o cloudflared) e o host conhecido
rd /s /q "%WORK%" >nul 2>&1
if exist "%USERPROFILE%\.ssh\known_hosts" ssh-keygen -R "[localhost]:__PORTA_PROXY__" >nul 2>&1

echo.
echo   Sessao encerrada. Nenhum acesso restante neste computador.
pause
exit /b 0
