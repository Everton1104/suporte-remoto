# guardiao.ps1 — imortalidade das tarefas SuporteRemoto e mesa-ui (Will).
# Roda a cada 5 min pela tarefa SuporteGuardiao (SYSTEM): se algum dos dois
# morreu (kill manual, crash), relanca pela tarefa agendada.
# Log: C:\Scripts\guardiao.log
# NOTA: mesa-ui checada por EFEITO (porta 8123 escutando) e nao por cmdline —
# filtrar cmdline por substring dava falso "vivo" com qualquer grep/ssh que
# mencionasse o nome do script (aconteceu no primeiro teste).
$log = "C:\Scripts\guardiao.log"
function Log($m) { Add-Content $log ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }
$eu = $PID
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"
if (-not ($procs | Where-Object {$_.CommandLine -like "*SuporteRemoto\agente.ps1*" -and $_.ProcessId -ne $eu})) {
  schtasks /run /tn SuporteRemoto | Out-Null
  Log "agente morto -> relancado"
}
if (-not (Get-NetTCPConnection -LocalPort 8123 -State Listen -ErrorAction SilentlyContinue)) {
  schtasks /run /tn mesa-ui | Out-Null
  Log "mesa-ui morta -> relancada"
}
