# suporte-pergunta - InputBox na tela do usuario logado; a resposta volta
# ao terminal de quem chamou (sessao SSH do tecnico). A UI exige tarefa
# interativa: o processo deste shell roda na sessao 0, sem acesso a tela.
$Pergunta = ($args -join ' ')
if (-not $Pergunta) { Write-Host 'uso: suporte-pergunta <pergunta>'; exit 1 }
$pub     = 'C:\Users\Public'
$arqResp = "$pub\suporte-resposta.txt"
$ps1Ui   = "$pub\suporte-pergunta-ui.ps1"
Remove-Item $arqResp, $ps1Ui -ErrorAction SilentlyContinue
$p = $Pergunta.Replace("'", "''")
$ui = "Add-Type -AssemblyName Microsoft.VisualBasic`n" +
      "`$r = [Microsoft.VisualBasic.Interaction]::InputBox('$p', 'Suporte Remoto')`n" +
      "if ([string]::IsNullOrEmpty(`$r)) { `$r = '(sem resposta / cancelado)' }`n" +
      "Set-Content -Path '$arqResp' -Value `$r -Encoding UTF8"
[System.IO.File]::WriteAllText($ps1Ui, $ui, (New-Object System.Text.UTF8Encoding $true))

function Tenta([string]$extra) {
    schtasks /create /tn SuporteRemotoPergunta $extra /it /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $ps1Ui" /sc once /st 23:59 /f *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    schtasks /run /tn SuporteRemotoPergunta *> $null
    return ($LASTEXITCODE -eq 0)
}
# tarefa como "Interactive" roda com o usuario logado na tela (sem senha);
# se o sistema recusar, cai para tarefa do proprio tecnico
if (-not (Tenta '/ru Interactive')) { Tenta '' | Out-Null }

Write-Host '>> Pergunta na tela. Aguardando resposta (max 5 min)...'
$t = 300
while (-not (Test-Path $arqResp) -and $t -gt 0) { Start-Sleep 2; $t -= 2 }
schtasks /delete /tn SuporteRemotoPergunta /f *> $null
if (Test-Path $arqResp) {
    Write-Host ('>> Resposta: ' + (Get-Content $arqResp -Raw))
    Remove-Item $arqResp, $ps1Ui -ErrorAction SilentlyContinue
} else {
    Write-Host '>> Sem resposta em 5 min.'
}
