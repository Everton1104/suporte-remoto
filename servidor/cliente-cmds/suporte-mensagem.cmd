@echo off
rem suporte-mensagem - popup com botao OK para o usuario logado na tela.
rem Uso (dentro da sessao do cliente): suporte-mensagem <texto sem acentos>
if "%~1"=="" (
    echo uso: suporte-mensagem ^<texto sem acentos^>
    exit /b 1
)
msg console /time:3600 %*
