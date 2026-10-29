# desinstalar.ps1 - remove o agente de suporte remoto por completo
$ErrorActionPreference = 'SilentlyContinue'
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
$adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
       ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm) {
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$MyInvocation.MyCommand.Path
    exit
}
Write-Host 'Removendo o agente de suporte remoto...'
schtasks /delete /tn SuporteRemoto /f
Get-Process cloudflared,ssh -ErrorAction SilentlyContinue | Stop-Process -Force
# o agente roda a partir desta pasta e mantem agente.ps1 aberto (lock que ja
# impediu overwrite em campo) - mata-lo antes de apagar. -ne $PID porque este
# script pode ter sido CHAMADO pelo agente: matar o pai nao mata este processo
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*agente.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
try {
    $id = (Get-Content (Join-Path $d 'registro.json') | ConvertFrom-Json).id
    Invoke-RestMethod -Uri '__URL_BASE__/agente/remover' -Method Post -ContentType 'application/json' `
        -Body (@{id=$id} | ConvertTo-Json) | Out-Null
} catch {}
$ak = "$env:ProgramData\ssh\administrators_authorized_keys"
if (Test-Path $ak) {
    (Get-Content $ak) | Where-Object { $_ -notmatch 'cliente:' } | Set-Content $ak
    icacls $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
    if ((Get-Item $ak).Length -eq 0) { Remove-Item $ak -Force }
}
Write-Host 'Removendo arquivos...'
Set-Location $env:SystemRoot
# este script roda DESTE diretorio e o powershell segura o proprio .ps1 -
# quem apaga a pasta e um cmd destacado, 3s depois, quando este processo ja
# saiu e soltou o lock (mesma razao do -ne $PID acima)
Start-Process cmd -WindowStyle Hidden -ArgumentList '/c',('ping -n 4 127.0.0.1 >nul & rmdir /s /q "{0}"' -f $d)
Write-Host 'Pronto: nenhum acesso remoto de suporte resta neste computador.'
