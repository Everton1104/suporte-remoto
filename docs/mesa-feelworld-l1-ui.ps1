# mesa-ui.ps1 - v5 - Site local de troca automatica de cameras da mesa Feelworld L1
# Tempos POR camera (ex: 5 min cam1, 10 min cam2). Opcodes validos em campo (19/11):
#   select 7318 = preview | TAKE 7800 = executa | frame <T ADDR SN CMD D1 D2 D3 D4 CK>
# v4: NAO usar o poll F1 40 01 (status 22) — na L1 ele envenena o controlador:
#     a mesa passa a ACKar sem executar ate que OUTRO socket conecte. Descoberto
#     em campo 19/11 (testado: socket limpo executa, socket que usou F1 nao).
# v5: reenvio cego — select+take e enviado 2x em toda troca (1.5s de intervalo):
#     cobre a falha transitoria "ACK sem executar" sem ler status da mesa.
# Roda como tarefa agendada (mesa-ui) — renasce no reboot. Porta 8123 (0.0.0.0).
param(
  [string]$Mesa = "192.168.0.83",
  [int]$PortaUDP = 1000,
  [int]$PortaHTTP = 8123
)
Add-Type -AssemblyName System.Web
$ErrorActionPreference = "SilentlyContinue"
$script:udp   = New-Object Net.Sockets.UdpClient(0)   # porta efemera: controlador "novo" a cada restart
$script:udp.Client.ReceiveTimeout = 2500
$script:dest  = New-Object Net.IPEndPoint([Net.IPAddress]::Parse($Mesa), $PortaUDP)
$script:sn    = 0
$script:sessao = $false
$script:rodando = $false
$script:atual  = 1
$script:proxima = (Get-Date)
$script:log    = @()
$script:efeito = 1   # 0=corte, 1..8 transicoes
$script:cfgArq = "C:\Scripts\mesa-config.json"
# config: por camera { on, min } — minutos (aceita 0.5 = 30s)
$script:cfg = @{
  cams = @(
    @{ n=1; on=$true;  min=5 },
    @{ n=2; on=$true;  min=10 },
    @{ n=3; on=$false; min=15 },
    @{ n=4; on=$false; min=15 }
  )
  rodando = $false
}
if (Test-Path $script:cfgArq) {
  try {
    $c = Get-Content $script:cfgArq -Raw | ConvertFrom-Json
    $script:cfg.cams = $c.cams
    if ($c.PSObject.Properties["rodando"]) { $script:cfg.rodando = [bool]$c.rodando }
  } catch {}
}
function SalvarCfg {
  $script:cfg | ConvertTo-Json -Depth 4 | Set-Content $script:cfgArq -Encoding ASCII
}
# desinstalador: apaga tarefa, arquivos e regra de firewall (botao do site chama)
if (-not (Test-Path "C:\Scripts\mesa-remove.bat")) {
  Set-Content "C:\Scripts\mesa-remove.bat" "@echo off`r`ntimeout /t 3 /nobreak >nul`r`nschtasks /delete /tn mesa-ui /f`r`nnetsh advfirewall firewall delete rule name=""Mesa UI 8123"" >nul 2>&1`r`ndel /f /q ""C:\Scripts\mesa-ui.ps1"" ""C:\Scripts\mesa-ui.log"" ""C:\Scripts\mesa-config.json"" ""C:\Scripts\mesa-remove.bat"""
}
function Log($m) {
  $l = "{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $m
  $script:log += $l
  if ($script:log.Count -gt 200) { $script:log = $script:log[-100..-1] }
  Add-Content -Path "C:\Scripts\mesa-ui.log" -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
}
# a mesa demora ~1-2s p/ responder e a resposta pode encalhar no socket —
# drena qualquer encalhada ANTES de enviar, e espera ate 2.5s pela certa
function Drena {
  $script:udp.Client.ReceiveTimeout = 60
  try {
    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
    while ($true) { [void]$script:udp.Receive([ref]$ep) }
  } catch {}
  $script:udp.Client.ReceiveTimeout = 2500
}
function Envia([string]$cmd) {
  Drena
  $b = [Text.Encoding]::ASCII.GetBytes($cmd)
  [void]$script:udp.Send($b, $b.Length, $script:dest)
  try {
    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
    $r = $script:udp.Receive([ref]$ep)
    Start-Sleep -Milliseconds 700
    return [Text.Encoding]::ASCII.GetString($r)
  } catch { return $null }
}
# monta frame com SN incremental e checksum (soma dos 7 bytes mod 256)
function Cmd([string]$hex) {
  $bytes = @()
  for ($i = 0; $i -lt $hex.Length; $i += 2) { $bytes += [Convert]::ToByte($hex.Substring($i, 2), 16) }
  $bytes = @(0x00, $script:sn) + $bytes
  $script:sn = ($script:sn + 1) % 256
  $soma = 0; foreach ($b in $bytes) { $soma += $b }
  return ("<T{0}{1:X2}>" -f (($bytes | ForEach-Object { "{0:X2}" -f $_ }) -join ""), ($soma -band 0xFF))
}
function AbreSessao {
  $script:sn = 0
  $r = Envia (Cmd "6866010000")
  $script:sessao = ($r -like "*<F*")
  Log "sessao: $r"
  return $script:sessao
}
function EfeitoSet([int]$ef) { return Envia (Cmd ("7806{0:X2}0000" -f $ef)) }
# troca de programa: select(preview) + TAKE
# a mesa so aceita UM controlador: se o app XPOSE (ou outro) conectar, a sessao
# da UI morre — respostas com ffffffff ou vazias => reconecta e tenta de novo
function Ruim($r) { return (-not $r -or $r -like "*FFFFFF*") }
# le o estado real da mesa (status 22): envia F1 40 01 00 00 e espera o
# datagrama de 22 bytes — byte[0]=preview-1, byte[2]=live(PGM)-1
# envia select(preview)+TAKE, reconectando quando a resposta vem ruim
function SelectTake([int]$cam) {
  $hex = "7318{0:X2}0000" -f ($cam - 1)
  $r1 = Envia (Cmd $hex)
  if (Ruim $r1) { AbreSessao | Out-Null; $r1 = Envia (Cmd $hex) }
  $r2 = Envia (Cmd "7800000000")
  if (Ruim $r2) {
    AbreSessao | Out-Null
    $r1 = Envia (Cmd $hex)
    $r2 = Envia (Cmd "7800000000")
  }
  return "$r1|$r2"
}
# v5: 2 rodadas cegas de select+take — a 2a cobre a falha transitoria "ACK sem
# executar" (se a 1a pegou, a 2a e um no-op visual: preview==programa)
function Trocar([int]$cam) {
  if (-not $script:sessao) { AbreSessao | Out-Null }
  $a = SelectTake $cam
  Start-Sleep -Milliseconds 1500
  $b = SelectTake $cam
  $script:atual = $cam
  Agendar
  Log "camera $cam (1=$a 2=$b)"
}
function Agendar {
  $c = $script:cfg.cams | Where-Object { $_.n -eq $script:atual }
  $min = 5; if ($c) { $min = [double]$c.min }
  $script:proxima = (Get-Date).AddMinutes($min)
}
function ProxCam {
  $ons = @($script:cfg.cams | Where-Object { $_.on } | Sort-Object n)
  if ($ons.Count -eq 0) { return $script:atual }
  $depois = @($ons | Where-Object { $_.n -gt $script:atual })
  if ($depois.Count -gt 0) { return [int]$depois[0].n }
  return [int]$ons[0].n
}
$HTML = @'
<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mesa de Corte</title>
<style>
:root{--bg:#0f1115;--card:#1a1e27;--ac:#4f8cff;--ok:#3ecf8e;--tx:#e8eaf0;--mu:#8a93a6}
*{box-sizing:border-box;margin:0}
body{background:var(--bg);color:var(--tx);font:15px/1.45 system-ui,sans-serif;padding:18px;max-width:720px;margin:auto}
h1{font-size:19px;margin-bottom:4px} h1 span{color:var(--mu);font-size:13px;font-weight:400}
.sub{color:var(--mu);font-size:13px;margin-bottom:14px}
.card{background:var(--card);border-radius:12px;padding:16px;margin-bottom:14px}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--mu);margin-bottom:12px}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
button{background:#2a3040;color:var(--tx);border:0;border-radius:9px;padding:11px 18px;font-size:15px;cursor:pointer}
button:hover{background:#343b4f}
button.pri{background:var(--ac);color:#fff;font-weight:600}
button.stop{background:#e5484d;color:#fff;font-weight:600}
button.unin{background:transparent;border:1px solid #e5484d;color:#e5484d;padding:9px 14px;font-size:13px}
button.sel{outline:2px solid var(--ok)}
input[type=number]{background:#0d1017;border:1px solid #2a3040;color:var(--tx);border-radius:9px;padding:10px 12px;font-size:16px;width:100px}
select{background:#0d1017;border:1px solid #2a3040;color:var(--tx);border-radius:9px;padding:10px 12px;font-size:15px}
.status{display:flex;gap:26px;margin-bottom:6px;font-size:14px;flex-wrap:wrap}
.status b{font-size:24px;display:block}
.cam{display:flex;gap:12px;align-items:center;padding:10px 0;border-bottom:1px solid #242a38;flex-wrap:wrap}
.cam:last-child{border-bottom:0}
.cam .nome{font-size:16px;font-weight:600;width:86px}
.cam .nome.on{color:var(--tx)} .cam .nome.off{color:var(--mu);text-decoration:line-through}
.chave{position:relative;width:46px;height:26px;background:#2a3040;border-radius:99px;cursor:pointer;transition:.2s;flex-shrink:0}
.chave::after{content:"";position:absolute;top:3px;left:3px;width:20px;height:20px;border-radius:50%;background:#8a93a6;transition:.2s}
.chave.on{background:rgba(79,140,255,.4)} .chave.on::after{left:23px;background:var(--ac)}
.lbl{color:var(--mu);font-size:13px}
#log{background:#0d1017;border-radius:9px;padding:12px;font:12.5px/1.6 ui-monospace,monospace;height:170px;overflow:auto;color:#a8b3c7;white-space:pre-wrap}
.pill{display:inline-block;padding:2px 10px;border-radius:99px;font-size:12px;background:#2a3040;color:var(--mu)}
.pill.on{background:rgba(62,207,142,.15);color:var(--ok)}
</style></head><body>
<h1>Mesa de Corte <span>— troca automática</span></h1>
<div class="sub">Feelworld L1 · altera o programa com transição</div>
<div class="card"><h2>Automático</h2>
  <div class="status">
    <div>Estado <b id="est">-</b></div>
    <div>Câmera atual <b id="cam">-</b></div>
    <div>Próxima troca <b id="cnt">-</b></div>
  </div>
  <div class="row" style="margin-top:12px">
    <button class="pri" id="btnIni">&#9654; Iniciar</button>
    <button class="stop" id="btnPar">&#9620; Parar</button>
  </div>
</div>
<div class="card"><h2>Câmeras — tempo de cada uma</h2><div id="cams"></div>
  <div class="row" style="margin-top:12px">
    <span class="lbl">Efeito da transição</span>
    <select id="efeito">
      <option value="0">corte seco</option><option value="1" selected>1 · fade</option>
      <option value="2">2</option><option value="3">3</option><option value="4">4</option>
      <option value="5">5</option><option value="6">6</option><option value="7">7</option><option value="8">8</option>
    </select>
  </div>
</div>
<div class="card"><h2>Log</h2><div id="log">...</div></div>
<script>
const $=s=>document.querySelector(s);
let cams=[];
async function api(q){await fetch('/cmd?'+q);att()}
async function att(){
  try{
    const e=await(await fetch('/estado')).json();
    $('#est').textContent=e.rodando?'rodando':'parado';
    $('#est').style.color=e.rodando?'#3ecf8e':'#8a93a6';
    $('#cam').textContent=e.atual;
    $('#cnt').textContent=e.rodando?Math.max(0,Math.ceil(e.falta))+'s':'-';
    cams=e.cams;
    if(!$('#cams').children.length){
      $('#cams').innerHTML=cams.map(c=>`
        <div class="cam" data-n="${c.n}">
          <div class="chave ${c.on?'on':''}"></div>
          <div class="nome ${c.on?'on':'off'}">Câmera ${c.n}</div>
          <input type="number" min="0.5" step="0.5" value="${c.min}" style="width:80px"> <span class="lbl">min</span>
          <button data-troca="${c.n}">Trocar agora</button>
        </div>`).join('');
      document.querySelectorAll('.chave').forEach(el=>el.onclick=()=>{
        const n=+el.parentElement.dataset.n;api('a=on&c='+n+'&v='+(el.classList.contains('on')?0:1))});
      document.querySelectorAll('[data-troca]').forEach(b=>b.onclick=()=>api('a=cam&v='+b.dataset.troca));
      document.querySelectorAll('.cam input').forEach(i=>i.onchange=()=>api('a=tempo&c='+i.parentElement.dataset.n+'&m='+i.value));
    }
    document.querySelectorAll('.cam').forEach(el=>{
      const c=cams.find(x=>x.n===+el.dataset.n);
      el.querySelector('.chave').classList.toggle('on',!!c.on);
      const nm=el.querySelector('.nome');nm.className='nome '+(c.on?'on':'off');
      el.querySelector('[data-troca]').classList.toggle('sel',+c.n===e.atual);
      const inp=el.querySelector('input');if(document.activeElement!==inp)inp.value=c.min;
    });
    $('#efeito').value=e.efeito;
    $('#log').textContent=e.log.join('\n');$('#log').scrollTop=9e9;
  }catch(err){}
}
setInterval(att,1000);att();
$('#btnIni').onclick=()=>api('a=iniciar');$('#btnPar').onclick=()=>api('a=parar');
$('#efeito').onchange=()=>api('a=efeito&v='+$('#efeito').value);
</script></body></html>
'@
function Resp([Net.Sockets.NetworkStream]$st, [string]$tipo, [string]$corpo) {
  $b = [Text.Encoding]::UTF8.GetBytes($corpo)
  $h = "HTTP/1.1 200 OK`r`nContent-Type: $tipo; charset=utf-8`r`nContent-Length: $($b.Length)`r`nConnection: close`r`n`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($h)
  $st.Write($hb, 0, $hb.Length); $st.Write($b, 0, $b.Length); $st.Flush()
}
function EstadoJSON {
  $cfgOut = @($script:cfg.cams | ForEach-Object { @{ n=[int]$_.n; on=[bool]$_.on; min=[double]$_.min } })
  @{
    rodando = $script:rodando; atual = $script:atual; efeito = $script:efeito
    falta = [int](($script:proxima - (Get-Date)).TotalSeconds)
    cams = $cfgOut; log = @($script:log | Select-Object -Last 40)
  } | ConvertTo-Json -Compress -Depth 4
}
function AcharCam([int]$n) { return ($script:cfg.cams | Where-Object { [int]$_.n -eq $n }) }
Log "servidor UI v5 no ar (mesa $Mesa, porta $PortaHTTP, reenvio duplo)"
# retoma o rodizio se estava rodando quando a UI caiu/reiniciou (so para com "Parar" ou desinstalar)
if ($script:cfg.rodando) {
  $script:rodando = $true
  Agendar
  Log "retomado: rodizio ATIVO"
}
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $PortaHTTP)
$listener.Start()
AbreSessao | Out-Null
while ($true) {
  if ($listener.Pending()) {
    $c = $listener.AcceptTcpClient(); $c.ReceiveTimeout = 800
    $st = $c.GetStream(); $buf = New-Object System.Collections.Generic.List[byte]
    try {
      $tmp = New-Object byte[] 4096
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while ($sw.ElapsedMilliseconds -lt 700) {
        if ($st.DataAvailable) {
          $n = $st.Read($tmp, 0, $tmp.Length); for ($i = 0; $i -lt $n; $i++) { $buf.Add($tmp[$i]) }
          $txt0 = [Text.Encoding]::ASCII.GetString($buf.ToArray()); if ($txt0 -match "`r`n`r`n") { break }
        } else { Start-Sleep -Milliseconds 20 }
      }
      $req = [Text.Encoding]::ASCII.GetString($buf.ToArray())
      $linha = ($req -split "`r`n")[0]
      if ($linha -match "^GET (\S+)") {
        $url = $Matches[1]
        if ($url -eq "/" -or $url -like "/index*") { Resp $st "text/html" $HTML }
        elseif ($url -like "/estado*") { Resp $st "application/json" (EstadoJSON) }
        elseif ($url -like "/cmd*") {
          $q = [System.Web.HttpUtility]::ParseQueryString(($url -split "\?", 2)[1])
          $a = $q["a"]; $v = $q["v"]; $cN = $q["c"]; $m = $q["m"]
          switch ($a) {
            "iniciar"  { AbreSessao | Out-Null
                          $script:rodando = $true; $script:cfg.rodando = $true; SalvarCfg
                          Agendar; Log "automatico INICIADO" }
            "parar"    { $script:rodando = $false; $script:cfg.rodando = $false; SalvarCfg
                          Log "automatico PARADO" }
            "cam"      { if ($v) { Trocar ([int]$v) } }
            "on"       { $cc = AcharCam ([int]$cN)
                         if ($cc) { $cc.on = ([int]$v -eq 1); SalvarCfg; Log "camera $cN " + ($(if ($cc.on) {"ATIVADA"} else {"desativada"})) } }
            "tempo"    { $cc = AcharCam ([int]$cN)
                         if ($cc -and $m) { $cc.min = [double]$m; SalvarCfg
                           if ($script:atual -eq [int]$cN) { Agendar }
                           Log "camera $cN = $m min" } }
            "efeito"   { if ($v -ne $null) { $script:efeito = [int]$v; EfeitoSet $script:efeito | Out-Null; Log "efeito = $v" } }
            "sair"     { Log "encerrando"; Resp $st "application/json" '{"ok":true}'; $c.Close(); $listener.Stop(); exit 0 }
            "desinstalar" { Log "DESINSTALANDO (botao do site)"
                            Resp $st "application/json" '{"ok":true,"msg":"desinstalando"}'
                            Start-Process cmd.exe -ArgumentList '/c','C:\Scripts\mesa-remove.bat' -WindowStyle Hidden
                            $c.Close(); $listener.Stop(); exit 0 }
          }
          Resp $st "application/json" '{"ok":true}'
        }
        else { Resp $st "text/plain" "?" }
      }
    } catch {}
    $c.Close()
  }
  if ($script:rodando) {
    if ((Get-Date) -ge $script:proxima) {
      $novo = ProxCam
      if ($novo -ne $script:atual) { Trocar $novo }
      else { Agendar }
    }
  }
  Start-Sleep -Milliseconds 150
}
