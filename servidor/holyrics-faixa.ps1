# holyrics-faixa.ps1 — server 2 do PC do som: faixa de 2 linhas em cima do Holyrics
# Porta 91. NAO altera nada no Holyrics: so retransmite o text.json e serve a pagina.
#   http://192.168.0.11:91/          -> pagina (todo o texto em 2 linhas fluidas)
#   http://192.168.0.11:91/text.json -> relay do Holyrics (:90)
# Parametros: ?fg=FFFFFF ?bg=000000
$ErrorActionPreference = 'SilentlyContinue'
$PORTA = 91
$UP = 'http://127.0.0.1:90/view/text.json'

$HTML = @'
<!DOCTYPE html>
<html lang="pt-br"><head><meta charset="utf-8">
<title>Faixa Holyrics</title>
<style>
  html,body{margin:0;padding:0;height:100%;overflow:hidden}
  #faixa{height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center}
  .linha{white-space:nowrap;font-family:Arial,Helvetica,sans-serif;font-weight:bold}
</style></head>
<body>
<div id="faixa"><div class="linha" id="l1"></div><div class="linha" id="l2"></div></div>
<script>
var q=new URLSearchParams(location.search);
var FG=q.get('fg')||'#FFFFFF';
var BG=q.get('bg')||'#000000';
var textoAtual='';
function corLinha(el,txt){
  var vw=document.documentElement.clientWidth;
  var vh=document.documentElement.clientHeight;
  var max=vw*0.98;
  var teto=Math.floor(vh/2*0.92);              // 2 linhas dentro da altura
  if(teto<12){teto=12;}
  var fs=teto;
  el.style.fontSize=fs+'px';el.textContent=txt;
  var w=el.scrollWidth;
  if(w>max){fs=Math.floor(fs*max/w);el.style.fontSize=Math.max(12,fs)+'px';}
}
function render(t){
  var l1=document.getElementById('l1'), l2=document.getElementById('l2');
  var linhas=t.split('\n').map(function(s){return s.replace(/<[^>]*>/g,'').replace(/\s+$/,'');}).filter(function(s){return s.trim()!=='';});
  var fluxo=linhas.join(' ').replace(/\s+/g,' ').trim();
  var palavras=fluxo.split(' ');
  if(!palavras.length||!palavras[0]){l1.textContent='';l2.textContent='';return;}
  if(palavras.length===1){corLinha(l1,palavras[0]);l2.textContent='';return;}
  var total=0;palavras.forEach(function(p){total+=p.length+1;});
  var acc=0,corte=1,melhor=1e9;
  for(var i=0;i<palavras.length-1;i++){
    acc+=palavras[i].length+1;
    var d=Math.abs(acc-(total-acc));
    if(d<melhor){melhor=d;corte=i+1;}
  }
  corLinha(l1,palavras.slice(0,corte).join(' '));
  corLinha(l2,palavras.slice(corte).join(' ')||'');
}
function tick(){
  var x=new XMLHttpRequest();
  x.open('GET','/text.json?'+Date.now(),true);
  x.onload=function(){
    try{
      var j=JSON.parse(x.responseText);
      var t=j.map&&j.map.text!==undefined?j.map.text:'';
      if(t!==textoAtual){textoAtual=t;render(t);}
    }catch(e){}
  };
  x.send();
}
document.body.style.background=BG;
document.body.style.color=FG;
window.addEventListener('resize',function(){render(textoAtual);});
tick();setInterval(tick,1000);
</script></body></html>
'@

$escuta = New-Object System.Net.HttpListener
$escuta.Prefixes.Add("http://*:$PORTA/")
$escuta.Start()
"faixa no ar na porta $PORTA"
while ($escuta.IsListening) {
  $ctx = $escuta.GetContext()
  try {
    $p = $ctx.Request.Url.LocalPath
    if ($p -eq '/reiniciar') {
      $b = [Text.Encoding]::UTF8.GetBytes('ok - reiniciando')
      $ctx.Response.OutputStream.Write($b,0,$b.Length)
      $ctx.Response.Close()
      Start-Sleep -Milliseconds 200
      $escuta.Stop()
      break
    }
    if ($p -eq '/text.json') {
      $web = New-Object System.Net.WebClient
      $b = $web.DownloadData($UP)
      $ctx.Response.ContentType = 'application/json'
      $ctx.Response.Headers.Add('Cache-Control','no-cache')
      $ctx.Response.OutputStream.Write($b,0,$b.Length)
    } else {
      $b = [Text.Encoding]::UTF8.GetBytes($HTML)
      $ctx.Response.ContentType = 'text/html; charset=utf-8'
      $ctx.Response.OutputStream.Write($b,0,$b.Length)
    }
  } catch {}
  try { $ctx.Response.Close() } catch {}
  Start-Sleep -Milliseconds 30
}
