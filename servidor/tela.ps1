param(
    [int]$Porta = 28090,        # porta do HttpListener no cliente
    [int]$SessaoMaxMin = 30,    # hard limit: encerra sozinho (esqueceram aberto)
    [int]$SemViewerMin = 10,    # sem ninguem olhando por isto = encerra
    # defaults do stream; o viewer sobrescreve na query do /mjpeg
    # (?w=largura&q=qualidadejpeg&i=intervalo_ms) — perfis da pagina
    [int]$LarguraMax = 1280,
    [int]$Qualidade = 52,
    [int]$Intervalo = 150
)
# tela.ps1 — servidor de tela (MJPEG) + controle (mouse/teclado) na maquina
# do cliente. Subido pelo tecnico via tela.sh, que o dispara com
# schtasks /it: captura de tela e injecao de entrada SO funcionam na
# sessao logada (processo SSH nasce na sessao 0, sem desktop).
#
# Rotas (HttpListener, so loopback, sem depender de privilegio):
#   GET  /mjpeg?w=&q=&i= -> stream multipart/x-mixed-replace (um viewer)
#   POST /input  -> injeta evento de mouse/teclado (JSON)
#   GET  /info   -> {"w":..,"h":..,"fps":..,"kbps":..,"clip":1}
#   GET  /clip   -> texto da area de transferencia do cliente
#   POST /clip   -> escreve texto na area de transferencia do cliente
#   POST /sair   -> encerra o servidor
#
# ARQUITETURA (2 threads): o stream de quadros roda num RUNSPACE dedicado
# (thread .NET no mesmo processo); o loop principal so trata HTTP. Antes o
# listener era single-thread e cada clique esperava a escrita do quadro
# corrente terminar — atraso de ate um frame inteiro por evento. Agora o
# /input responde em milissegundos, independente do stream.
#
# O quadro inclui o PONTEIRO do cliente (GetCursorInfo + DrawIconEx):
# CopyFromScreen sozinho nao desenha cursor — sem isso, no modo assistir o
# tecnico nao ve onde o usuario esta mexendo o mouse.
#
# Limites: keybd_event carrega o caractere unicode num BYTE — acentos do
# pt-BR ok (a e c < 256), emoji nao. UAC/secure-desktop nao aceita injecao
# (igual VNC sem hook de servico): se aparecer o prompt de elevacao, o
# clique nao chega — o usuario local clica. Ctrl+alt+CARACTERE e tratado
# como AltGr (layout pt-BR: @ # $ ... digitam de verdade; atalho ctrl+alt
# real usa tecla nomeada — Tab, F5...).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Inj {
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, UIntPtr extra);
}
public static class Cur {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INFO {
        public int cbSize; public int flags; public IntPtr hCursor; public POINT pt;
    }
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref INFO pci);
    [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr hdc,
        int xLeft, int yTop, IntPtr hIcon, int cxWidth, int cyHeight,
        uint istepIfAniCur, IntPtr hbrFlickerFreeDraw, uint diFlags);
}
"@

$log = 'C:\Users\Public\suporte-tela.log'
# try/catch: com ErrorActionPreference=Stop, um Add-Content falho DENTRO de um
# catch (ex.: log apagado por um parar racing) escaparia e mataria o loop todo
function Log($m) { try { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) } catch {} }
Set-Content -Path $log -Value ("{0} inicio porta={1} (stream em runspace)" -f (Get-Date -Format 'HH:mm:ss'), $Porta)

# flags mouse_event
$F_MOVER     = 0xC001   # MOVE|ABSOLUTE|VIRTUALDESK: x/y 0..65535 no desktop virtual
$F_BAIXAR    = @{ 0 = 0x0002; 1 = 0x0020; 2 = 0x0008 }   # esq/ meio/ dir
$F_SOLTAR    = @{ 0 = 0x0004; 1 = 0x0040; 2 = 0x0010 }
$F_RODA      = 0x0800
# teclas virtuais (o que vem do navegador por nome)
$VK = @{
    'Enter'=13;'Backspace'=8;'Tab'=9;'Escape'=27;'Delete'=46;'Insert'=45;
    'Home'=36;'End'=35;'PageUp'=33;'PageDown'=34;
    'ArrowLeft'=37;'ArrowUp'=38;'ArrowRight'=39;'ArrowDown'=40;
    'Meta'=91;'ContextMenu'=93
}
1..12 | ForEach-Object { $VK["F$_"] = 111 + $_ }

# --------------------------------------------------------------- injecao
function Mover($x, $y) {
    [Inj]::mouse_event($F_MOVER, [int][Math]::Round([double]$x * 65535),
                                       [int][Math]::Round([double]$y * 65535), 0, [UIntPtr]::Zero)
}

function InjetaTecla($e) {
    # AltGr no Windows chega como ctrl+alt juntos: se o evento e caractere
    # (sem tecla nomeada), digita o caractere — nao forma atalho nenhum.
    $altgr = ($e.ctrl -and $e.alt -and -not $e.k -and $e.c -and
              ([string]$e.c).Length -eq 1)
    # modificadores cercam a tecla; shift nao precisa ir no evento de
    # caractere — o navegador ja manda o caractere ja maiusculo
    $mods = @()
    if (-not $altgr) {
        if ($e.ctrl)  { $mods += 17 }
        if ($e.alt)   { $mods += 18 }
        if ($e.meta)  { $mods += 91 }
        if ($e.shift -and $e.k) { $mods += 16 }   # so com tecla nomeada (Enter, F5...)
    }
    foreach ($m in $mods) { [Inj]::keybd_event([byte]$m, 0, 0, [UIntPtr]::Zero) }
    if ($e.k -and $VK.ContainsKey([string]$e.k)) {
        $vk = $VK[[string]$e.k]
        [Inj]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 12
        [Inj]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
    } elseif ($e.c -and ([string]$e.c).Length -eq 1) {
        $ch = [int][char][string]$e.c
        if ($altgr -or -not ($e.ctrl -or $e.alt)) {
            # caractere puro (ou AltGr): unicode direto
            if ($ch -le 255) {
                [Inj]::keybd_event(0, [byte]$ch, 4, [UIntPtr]::Zero)
                Start-Sleep -Milliseconds 12
                [Inj]::keybd_event(0, [byte]$ch, 6, [UIntPtr]::Zero)
            }
        } else {
            # atalho (ctrl+c, alt+tab...): tem que ser tecla virtual, unicode
            # com ctrl pressionado nao forma o atalho
            if ($ch -ge 97 -and $ch -le 122) { $ch -= 32 }
            [Inj]::keybd_event([byte]$ch, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 12
            [Inj]::keybd_event([byte]$ch, 0, 2, [UIntPtr]::Zero)
        }
    }
    [array]::Reverse($mods)
    foreach ($m in $mods) { [Inj]::keybd_event([byte]$m, 0, 2, [UIntPtr]::Zero) }
}

function Injetar($e) {
    switch ([string]$e.t) {
        'move'   { Mover $e.x $e.y }
        'down'   { if ($null -ne $e.x) { Mover $e.x $e.y }
                   [Inj]::mouse_event($F_BAIXAR[[int]$e.b], 0, 0, 0, [UIntPtr]::Zero) }
        'up'     { if ($null -ne $e.x) { Mover $e.x $e.y }
                   [Inj]::mouse_event($F_SOLTAR[[int]$e.b], 0, 0, 0, [UIntPtr]::Zero) }
        'click'  { Mover $e.x $e.y
                   [Inj]::mouse_event($F_BAIXAR[[int]$e.b], 0, 0, 0, [UIntPtr]::Zero)
                   Start-Sleep -Milliseconds 30
                   [Inj]::mouse_event($F_SOLTAR[[int]$e.b], 0, 0, 0, [UIntPtr]::Zero) }
        'scroll' { [Inj]::mouse_event($F_RODA, 0, 0, [uint32](120 * [int]$e.d), [UIntPtr]::Zero) }
        'key'    { InjetaTecla $e }
        'texto'  { foreach ($c in [string]$e.s.ToCharArray()) {
                       $n = [int]$c
                       if ($n -le 255) {
                           [Inj]::keybd_event(0, [byte]$n, 4, [UIntPtr]::Zero)
                           [Inj]::keybd_event(0, [byte]$n, 6, [UIntPtr]::Zero)
                           Start-Sleep -Milliseconds 8
                       }
                   } }
    }
}

# ------------------------------------------------- estado compartilhado
# synchronized: escrito pelo loop principal (perfil/tela/rodando) e pelo
# runspace do stream (stats) sem lock explicito — cada chave e atomica e
# as races possiveis (fps contado +-1 quadro) so afetam o display do /info
$estado = [hashtable]::Synchronized(@{
    rodando    = $true
    tela       = $null            # contexto HTTP do viewer (um por vez)
    perfil     = @{ w = $LarguraMax; q = $Qualidade; i = $Intervalo }
    quadros    = 0
    winQuadros = 0; winBytes = [long]0
    winT0      = Get-Date; fps = 0; kbps = 0
    streamVivo = Get-Date         # janitor do main: runspace parado = viewer preso
    ultimoQuadro = Get-Date
})

# ------------------------------------------------------- runspace do stream
# self-contained (nao enxerga funcoes/variaveis deste script): recebe so o
# $estado. Os Add-Type acima ficam no AppDomain do processo, visivel aqui.
$blocoStream = {
param($es)
$ErrorActionPreference = 'Stop'
function Log($m) { try { Add-Content -Path 'C:\Users\Public\suporte-tela.log' -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) } catch {} }

$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
         Where-Object { $_.MimeType -eq 'image/jpeg' }
$crlf = [byte[]](13,10)

# buffers persistentes: (re)criar bitmap+graphics+encoderparams a cada quadro
# era o maior custo depois do encode. So recria quando resolucao ou perfil
# mudam ($chave), e o MemoryStream reaproveita SetLength(0).
$script:chaveBuf = $null
$script:bmpG = $null; $script:gG = $null
$script:bmpP = $null; $script:gP = $null
$script:jp = $null; $script:jpQ = -1
$script:ms = New-Object System.IO.MemoryStream

function GaranteJpeg($q) {
    if ($q -ne $script:jpQ) {
        $script:jp = New-Object System.Drawing.Imaging.EncoderParameters 1
        $script:jp.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
            [System.Drawing.Imaging.Encoder]::Quality, [long]$q)
        $script:jpQ = $q
    }
}

Log "stream: runspace no ar"
while ($es.rodando) {
    $es.streamVivo = Get-Date
    $ctx = $es.tela
    if ($null -eq $ctx) { Start-Sleep -Milliseconds 120; continue }
    $p = $es.perfil
    $w = [int]$p.w; $q = [int]$p.q; $i = [int]$p.i
    $t0 = Get-Date
    try {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $chave = "$($vs.Width)x$($vs.Height)@$w"
        if ($chave -ne $script:chaveBuf) {
            if ($script:gG)  { try { $script:gG.Dispose() } catch {} }
            if ($script:bmpG){ try { $script:bmpG.Dispose() } catch {} }
            if ($script:gP)  { try { $script:gP.Dispose() } catch {} }
            if ($script:bmpP){ try { $script:bmpP.Dispose() } catch {} }
            $script:bmpG = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
            $script:gG = [System.Drawing.Graphics]::FromImage($script:bmpG)
            if ($vs.Width -gt $w) {
                $nh = [int]($vs.Height * $w / $vs.Width)
                $script:bmpP = New-Object System.Drawing.Bitmap($w, $nh)
                $script:gP = [System.Drawing.Graphics]::FromImage($script:bmpP)
            } else { $script:bmpP = $null; $script:gP = $null }
            $script:chaveBuf = $chave
        }
        GaranteJpeg $q
        $script:gG.CopyFromScreen($vs.X, $vs.Y, 0, 0, $script:bmpG.Size)

        # ponteiro do cliente DESENHADO no quadro (antes do resize: a posicao
        # e em coordenadas de tela e o tamanho escala junto)
        $ci = New-Object Cur+INFO
        $ci.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][Cur+INFO])
        if ([Cur]::GetCursorInfo([ref]$ci) -and (($ci.flags -band 1) -ne 0) -and
            ($ci.hCursor -ne [IntPtr]::Zero)) {
            $hdc = $script:gG.GetHdc()
            try { [void][Cur]::DrawIconEx($hdc, $ci.pt.X - $vs.X, $ci.pt.Y - $vs.Y,
                                          $ci.hCursor, 0, 0, 0, [IntPtr]::Zero, 3) }
            finally { $script:gG.ReleaseHdc($hdc) }
        }

        $dest = $script:bmpG
        if ($script:bmpP) {
            $script:gP.DrawImage($script:bmpG, 0, 0, $script:bmpP.Width, $script:bmpP.Height)
            $dest = $script:bmpP
        }
        $script:ms.SetLength(0)
        $script:ms.Position = 0
        $dest.Save($script:ms, $codec, $script:jp)
        $b = $script:ms.ToArray()

        $cab = [Text.Encoding]::ASCII.GetBytes(
            "--frame`r`nContent-Type: image/jpeg`r`nContent-Length: $($b.Length)`r`n`r`n")
        # Write com timeout: viewer que para de drenar (aba background) nao
        # pode travar a thread — 3s sem drenar = viewer morto, Abort e segue
        $out = $ctx.Response.OutputStream
        $ok = $out.WriteAsync($cab, 0, $cab.Length).Wait(3000)
        if ($ok) { $ok = $out.WriteAsync($b, 0, $b.Length).Wait(3000) }
        if ($ok) { $ok = $out.WriteAsync($crlf, 0, 2).Wait(3000) }
        if (-not $ok) { throw "viewer nao drena o stream (write 3s)" }
        $out.Flush()
        $es.ultimoQuadro = Get-Date
        $es.quadros++
        $es.winQuadros++
        $es.winBytes += $b.Length
    } catch {
        Log "viewer desconectou ($($_.Exception.Message))"
        # Abort, nao Close: Close da flush nos headers 200 pendentes e termina
        # limpo — o navegador via "200 ok" sem um quadro e ficava carregando
        # eternamente. Abort descarta e derruba a conexao.
        try { $ctx.Response.Abort() } catch {}
        $es.tela = $null
    }
    # pacing: dorme so o que sobrou do intervalo-alvo deste perfil
    $resto = [int]$i - ((Get-Date) - $t0).TotalMilliseconds
    if ($resto -gt 0) { Start-Sleep -Milliseconds $resto }
}
Log "stream: encerrou"
}

$runspaceStream = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$runspaceStream.Open()
$psStream = [powershell]::Create()
$psStream.Runspace = $runspaceStream
$null = $psStream.AddScript($blocoStream.ToString()).AddArgument($estado)
$hStream = $psStream.BeginInvoke()

# ----------------------------------------------------------- loop principal
$escuta = New-Object System.Net.HttpListener
# prefixo localhost nao exige urlacl de administrador; o Host header das
# chamadas tem que bater com "localhost" (web.py/tela.sh ja mandam assim)
$escuta.Prefixes.Add("http://localhost:$Porta/")
try { $escuta.Start() } catch {
    Log "ERRO ouvindo porta ${Porta}: $($_.Exception.Message)"
    $estado.rodando = $false
    try { $psStream.Stop() } catch {}
    exit 1
}
Log "ouvindo localhost:$Porta"

$ultimoViewer = Get-Date
$inicio = Get-Date
$ultimoBat = Get-Date
$rodando = $true

function PerfisSeguros($qs) {
    # w/q/i da query do /mjpeg com clamp — nada de trust no que veio
    $w = if ($qs['w'] -match '^\d+$') { [Math]::Min(1920, [Math]::Max(640, [int]$qs['w'])) } else { $LarguraMax }
    $q = if ($qs['q'] -match '^\d+$') { [Math]::Min(80, [Math]::Max(30, [int]$qs['q'])) } else { $Qualidade }
    $i = if ($qs['i'] -match '^\d+$') { [Math]::Min(1000, [Math]::Max(60, [int]$qs['i'])) } else { $Intervalo }
    return @{ w = $w; q = $q; i = $i }
}

while ($rodando -and $escuta.IsListening) {
    if (((Get-Date) - $inicio).TotalMinutes -ge $SessaoMaxMin) { Log "fim: sessao maxima"; break }
    $task = $escuta.GetContextAsync()
    while (-not $task.Wait(150)) {
        if (-not $rodando) { break }
        # heartbeat no log: se "travar" de novo, o log mostra se o loop morreu
        # (linhas param) ou seguiu vivo. Aqui no loop interno: assistindo sem
        # input nenhum, o externo nunca iterava
        if (((Get-Date) - $ultimoBat).TotalSeconds -ge 60) {
            Log "vivo quadros=$($estado.quadros) viewer=$($null -ne $estado.tela) fps=$($estado.fps)"
            $ultimoBat = Get-Date
        }
        if ($null -ne $estado.tela) {
            # runspace do stream morreu com viewer pendurado? mata o viewer
            # (a pagina reconecta) — e se o runspace em si morreu, encerra: o
            # web.py re-sobe limpo na proxima conexao
            if ($psStream.InvocationStateInfo.State -ne 'Running') {
                Log "runspace do stream morreu — encerrando"
                try { $estado.tela.Response.Abort() } catch {}
                $estado.tela = $null
                $rodando = $false
                break
            }
            if (((Get-Date) - $estado.streamVivo).TotalSeconds -gt 12) {
                Log "stream sem sinal 12s — derrubando viewer p/ reconectar"
                try { $estado.tela.Response.Abort() } catch {}
                $estado.tela = $null
            }
        } elseif (((Get-Date) - $ultimoViewer).TotalMinutes -ge $SemViewerMin) {
            Log "fim: sem viewer por $SemViewerMin min"
            $rodando = $false
            break
        }
    }
    if (-not $rodando) { break }
    $ctx = $task.Result
    $caminho = $ctx.Request.Url.LocalPath
    $metodo = $ctx.Request.HttpMethod
    try {
        if ($metodo -eq 'GET' -and $caminho -eq '/mjpeg') {
            if ($null -ne $estado.tela) {
                $ctx.Response.StatusCode = 409
                $ctx.Response.Close()
            } else {
                # captura de PROVA antes de comprometer o viewer: se CopyFromScreen
                # nao rola nesta sessao (task caiu na sessao 0), responder 200
                # multipart vazio deixava o <img> "carregando" pra sempre —
                # multipart sem fim nao dispara onerror no navegador. 500 com o
                # motivo vira 502 honesto la no relay.
                $falha = $null
                try {
                    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
                    $pb = New-Object System.Drawing.Bitmap(16, 16)
                    $pg = [System.Drawing.Graphics]::FromImage($pb)
                    $pg.CopyFromScreen($vs.X, $vs.Y, 0, 0, $pb.Size)
                    $pg.Dispose(); $pb.Dispose()
                } catch { $falha = $_.Exception.Message }
                if ($falha) {
                    Log "ERRO captura: $falha"
                    $ctx.Response.StatusCode = 500
                    $ctx.Response.ContentType = 'text/plain'
                    $b = [Text.Encoding]::UTF8.GetBytes("captura falhou: $falha")
                    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
                    $ctx.Response.Close()
                } else {
                    # perfil da conexao: ?w=largura&q=qualidade&i=intervalo_ms
                    $qs = @{}
                    foreach ($par in $ctx.Request.Url.Query.TrimStart('?').Split('&')) {
                        if ($par) { $kv = $par.Split([char[]]'=', 2)
                            if ($kv.Length -eq 2) { $qs[$kv[0]] = $kv[1] } }
                    }
                    $estado.perfil = PerfisSeguros $qs
                    $r = $ctx.Response
                    $r.StatusCode = 200
                    $r.ContentType = 'multipart/x-mixed-replace; boundary=frame'
                    $r.SendChunked = $true
                    $estado.tela = $ctx           # headers saem no 1o write do runspace
                    $ultimoViewer = Get-Date
                    Log "viewer conectado (w=$($estado.perfil.w) q=$($estado.perfil.q) i=$($estado.perfil.i))"
                }
            }
        } elseif ($metodo -eq 'POST' -and $caminho -eq '/input') {
            # respondido pelo loop principal: nunca espera a escrita do quadro
            $leitor = New-Object IO.StreamReader($ctx.Request.InputStream,
                                                 [Text.Encoding]::UTF8)
            $ev = $leitor.ReadToEnd() | ConvertFrom-Json
            if ($ev) {
                if ($ev.t -ne 'move') { Log "in t=$($ev.t) b=$($ev.b) k=$($ev.k) c=$($ev.c)" }
                Injetar $ev
            }
            $ultimoViewer = Get-Date
            $ctx.Response.StatusCode = 204
            $ctx.Response.Close()
        } elseif ($metodo -eq 'GET' -and $caminho -eq '/info') {
            # stats da janela atual (reset a cada leitura ~2s da pagina).
            # poll da pagina aberta = viewer vivo (segura o limite de 10min)
            $agora = Get-Date
            $ultimoViewer = $agora
            $seg = ($agora - $estado.winT0).TotalSeconds
            if ($seg -ge 1.0) {
                $estado.fps = [int][Math]::Round($estado.winQuadros / $seg)
                $estado.kbps = [int][Math]::Round($estado.winBytes / $seg / 1024)
                $estado.winQuadros = 0
                $estado.winBytes = [long]0
                $estado.winT0 = $agora
            }
            $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
            $w = [Math]::Min($vs.Width, [int]$estado.perfil.w)
            $h = [int]($vs.Height * $w / $vs.Width)
            $corpo = [Text.Encoding]::UTF8.GetBytes(
                ('{{"w":{0},"h":{1},"fps":{2},"kbps":{3},"clip":1}}' -f
                 $w, $h, $estado.fps, $estado.kbps))
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.OutputStream.Write($corpo, 0, $corpo.Length)
            $ctx.Response.Close()
        } elseif ($caminho -eq '/clip') {
            # area de transferencia de TEXTO do cliente (AnyDesk-like): o
            # tecnico cola um comando/URL sem digitar. Get/Set-Clipboard
            # exigem STA — powershell.exe 5.1 sobe STA por padrao (o schtasks
            # do tela.sh nao passa -mta)
            if ($metodo -eq 'GET') {
                try {
                    $txt = [string](Get-Clipboard -Raw)
                    $b = [Text.Encoding]::UTF8.GetBytes($txt)
                    $ctx.Response.ContentType = 'text/plain; charset=utf-8'
                    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
                } catch {
                    $ctx.Response.StatusCode = 500
                    $b = [Text.Encoding]::UTF8.GetBytes("clip: $($_.Exception.Message)")
                    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
                }
                $ctx.Response.Close()
            } else {
                $leitor = New-Object IO.StreamReader($ctx.Request.InputStream,
                                                     [Text.Encoding]::UTF8)
                $txt = $leitor.ReadToEnd()
                if ($txt) { Set-Clipboard -Value $txt }
                Log "clip: escrito $($txt.Length) chars"
                $ctx.Response.StatusCode = 204
                $ctx.Response.Close()
            }
        } elseif ($metodo -eq 'POST' -and $caminho -eq '/sair') {
            $ctx.Response.StatusCode = 204
            $ctx.Response.Close()
            $rodando = $false
            Log "pedido /sair"
        } else {
            $ctx.Response.StatusCode = 404
            $ctx.Response.Close()
        }
    } catch {
        try { $ctx.Response.Close() } catch {}
    }
}

$estado.rodando = $false
if ($null -ne $estado.tela) { try { $estado.tela.Response.Abort() } catch {} }
try { $escuta.Stop() } catch {}
try { $psStream.Stop() } catch {}
try { $runspaceStream.Close() } catch {}
Log "encerrou"
