@echo off
rem suporte-pergunta - caixa de input na tela do usuario logado; a resposta
rem digitada volta para este terminal. Uso: suporte-pergunta <pergunta>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0suporte-pergunta-run.ps1" %*
