param(
    [int]$Porta = 28090,        # porta do HttpListener no cliente
    [int]$Intervalo = 350,      # ms entre quadros (alvo; captura soma por cima)
    [int]$LarguraMax = 1600,    # escala a captura p/ banda (~100-200 KB/quadro)
    [int]$Qualidade = 62,       # qualidade JPEG
    [int]$SessaoMaxMin = 30,    # hard limit: encerra sozinho (esqueceram aberto)
    [int]$SemViewerMin = 10     # sem ninguem olhando por isto = encerra
)
# tela.ps1 — servidor de tela (MJPEG) + controle (mouse/teclado) na maquina
# do cliente. Subido pelo tecnico via tela.sh, que o dispara com
# schtasks /it: captura de tela e injecao de entrada SO funcionam na
# sessao logada (processo SSH nasce na sessao 0, sem desktop).
#
# Rotas (HttpListener, so loopback, sem depender de privilegio):
#   GET  /mjpeg  -> stream multipart/x-mixed-replace (um viewer por vez)
#   POST /input  -> injeta evento de mouse/teclado (JSON)
#   GET  /info   -> {"w":..,"h":..} do ultimo quadro capturado
#   POST /sair   -> encerra o servidor
#
# Limites: keybd_event carrega o caractere unicode num BYTE — acentos do
# pt-BR ok (á é ç < 256), emoji nao. UAC/secure-desktop nao aceita injecao
# (igual VNC sem hook de servico): se aparecer o prompt de elevacao, o
# clique nao chega — o usuario local clica.
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
"@

$log = 'C:\Users\Public\suporte-tela.log'
function Log($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
Set-Content -Path $log -Value ("{0} inicio porta={1}" -f (Get-Date -Format 'HH:mm:ss'), $Porta)

# flags mouse_event
$F_MOVER     = 0xC001   # MOVE|ABSOLUTE|VIRTUALDESK: x/y 0..65535 no desktop virtual
$F_BAIXAR    = @{ 0 = 0x0002; 1 = 0x0020; 2 = 0x0008 }   # esq/ meio/ dir
$F_SOLTAR    = @{ 0 = 0x0004; 1 = 0x0040; 2 = 0x0010 }
$F_RODA      = 0x0800
# teclas virtuais (o que vem do navegador por nome)
$VK = @{
    'Enter'=13;'Backspace'=8;'Tab'=9;'Escape'=27;'Delete'=46;'Insert'=45;
    'Home'=36;'End'=35;'PageUp'=33;'PageDown'=34;
    'ArrowLeft'=37;'ArrowUp'=38;'ArrowRight'=39;'ArrowDown'=40
}
1..12 | ForEach-Object { $VK["F$_"] = 111 + $_ }

$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
         Where-Object { $_.MimeType -eq 'image/jpeg' }
$jpegParams = New-Object System.Drawing.Imaging.EncoderParameters 1
$jpegParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
    [System.Drawing.Imaging.Encoder]::Quality, [long]$Qualidade)

function Capturar {
    # desktop virtual = todas as monitoras numa imagem so; a escala mantem
    # a proporcao, entao coordenada normalizada (0..1) da pagina casa com a
    # tela cheia mesmo depois de reduzir
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    if ($bmp.Width -gt $LarguraMax) {
        $nw = $LarguraMax
        $nh = [int]($bmp.Height * $nw / $bmp.Width)
        $peq = New-Object System.Drawing.Bitmap($nw, $nh)
        $g2 = [System.Drawing.Graphics]::FromImage($peq)
        $g2.DrawImage($bmp, 0, 0, $nw, $nh)
        $g2.Dispose(); $bmp.Dispose(); $bmp = $peq
    }
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, $codec, $jpegParams)
    $b = $ms.ToArray()
    $bmp.Dispose(); $ms.Dispose()
    return ,$b
}

function Mover($x, $y) {
    [Inj]::mouse_event($F_MOVER, [int][Math]::Round([double]$x * 65535),
                                       [int][Math]::Round([double]$y * 65535), 0, [UIntPtr]::Zero)
}

function InjetaTecla($e) {
    # modificadores (ctrl/alt) cercam a tecla; shift nao precisa ir no
    # evento de caractere — o navegador ja manda o caractere ja maiusculo
    $mods = @()
    if ($e.ctrl)  { $mods += 17 }
    if ($e.alt)   { $mods += 18 }
    if ($e.shift -and $e.k) { $mods += 16 }   # so com tecla nomeada (Enter, F5...)
    foreach ($m in $mods) { [Inj]::keybd_event([byte]$m, 0, 0, [UIntPtr]::Zero) }
    if ($e.k -and $VK.ContainsKey([string]$e.k)) {
        $vk = $VK[[string]$e.k]
        [Inj]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 12
        [Inj]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
    } elseif ($e.c -and ([string]$e.c).Length -eq 1) {
        $ch = [int][char][string]$e.c
        if ($e.ctrl -or $e.alt) {
            # atalho (ctrl+c, alt+tab...): tem que ser tecla virtual, unicode
            # com ctrl pressionado nao forma o atalho
            if ($ch -ge 97 -and $ch -le 122) { $ch -= 32 }
            [Inj]::keybd_event([byte]$ch, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 12
            [Inj]::keybd_event([byte]$ch, 0, 2, [UIntPtr]::Zero)
        } elseif ($ch -le 255) {
            [Inj]::keybd_event(0, [byte]$ch, 4, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 12
            [Inj]::keybd_event(0, [byte]$ch, 6, [UIntPtr]::Zero)
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

$escuta = New-Object System.Net.HttpListener
# prefixo localhost nao exige urlacl de administrador; o Host header das
# chamadas tem que bater com "localhost" (web.py/tela.sh ja mandam assim)
$escuta.Prefixes.Add("http://localhost:$Porta/")
try { $escuta.Start() } catch {
    Log "ERRO ouvindo porta ${Porta}: $($_.Exception.Message)"
    exit 1
}
Log "ouvindo localhost:$Porta"

$script:tela = $null          # contexto do viewer MJPEG (um por vez)
$ultimoViewer = Get-Date
$ultimoQuadro = Get-Date
$crlf = [byte[]](13, 10)
$rodando = $true

$script:quadros = 0
function EscreveQuadro {
    try {
        $b = Capturar
        $cab = [Text.Encoding]::ASCII.GetBytes(
            "--frame`r`nContent-Type: image/jpeg`r`nContent-Length: $($b.Length)`r`n`r`n")
        # Write com timeout: se o viewer parar de drenar (aba do navegador em
        # background/engasgada), o Write sincrono bloqueava PARA SEME a unica
        # thread daqui — quadros E entrada morriam juntos ("travou"). 3s sem
        # drenar = viewer morto: Abort e libera o loop (a pagina reconecta).
        $out = $tela.Response.OutputStream
        $ok = $out.WriteAsync($cab, 0, $cab.Length).Wait(3000)
        if ($ok) { $ok = $out.WriteAsync($b, 0, $b.Length).Wait(3000) }
        if ($ok) { $ok = $out.WriteAsync($crlf, 0, 2).Wait(3000) }
        if (-not $ok) { throw "viewer nao drena o stream (write 3s)" }
        $out.Flush()
        $script:ultimoQuadro = Get-Date
        $script:quadros++
    } catch {
        Log "viewer desconectou ($($_.Exception.Message))"
        # Abort, nao Close: Close da flush nos headers 200 pendentes e termina
        # o chunked limpo — o navegador via "200 ok" sem um quadro e ficava
        # carregando eternamente. Abort descarta tudo e derruba a conexao.
        try { $tela.Response.Abort() } catch {}
        $script:tela = $null
    }
}

$inicio = Get-Date
$ultimoBat = Get-Date
while ($rodando -and $escuta.IsListening) {
    if (((Get-Date) - $inicio).TotalMinutes -ge $SessaoMaxMin) { Log "fim: sessao maxima"; break }
    # heartbeat no log: se "travar" de novo, o log mostra se o loop morreu
    # (linhas param) ou seguiu vivo (quadros continuam contando)
    if (((Get-Date) - $ultimoBat).TotalSeconds -ge 60) {
        Log "vivo quadros=$($script:quadros) viewer=$($null -ne $tela)"
        $ultimoBat = Get-Date
    }
    $task = $escuta.GetContextAsync()
    while (-not $task.Wait(150)) {
        if (-not $rodando) { break }
        if ($null -ne $tela) {
            if (((Get-Date) - $ultimoQuadro).TotalMilliseconds -ge $Intervalo) {
                EscreveQuadro
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
            if ($null -ne $tela) {
                $ctx.Response.StatusCode = 409
                $ctx.Response.Close()
            } else {
                # captura de PROVA antes de comprometer o viewer: se CopyFromScreen
                # nao rola nesta sessao (task caiu na sessao 0), responder 200
                # multipart vazio deixava o <img> "carregando" pra sempre —
                # multipart sem fim nao dispara onerror no navegador. 500 com o
                # motivo vira 502 honesto la no relay.
                $falha = $null
                try { $null = Capturar } catch { $falha = $_.Exception.Message }
                if ($falha) {
                    Log "ERRO captura: $falha"
                    $ctx.Response.StatusCode = 500
                    $ctx.Response.ContentType = 'text/plain'
                    $b = [Text.Encoding]::UTF8.GetBytes("captura falhou: $falha")
                    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
                    $ctx.Response.Close()
                } else {
                    $r = $ctx.Response
                    $r.StatusCode = 200
                    $r.ContentType = 'multipart/x-mixed-replace; boundary=frame'
                    $r.SendChunked = $true
                    $tela = $ctx                # headers saem no 1o write
                    $ultimoViewer = Get-Date
                    Log "viewer conectado"
                }
            }
        } elseif ($metodo -eq 'POST' -and $caminho -eq '/input') {
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
            $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
            $w = [Math]::Min($vs.Width, $LarguraMax)
            $h = [int]($vs.Height * $w / $vs.Width)
            $corpo = [Text.Encoding]::UTF8.GetBytes(('{{"w":{0},"h":{1}}}' -f $w, $h))
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.OutputStream.Write($corpo, 0, $corpo.Length)
            $ctx.Response.Close()
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

if ($null -ne $tela) { try { $tela.Response.Abort() } catch {} }
try { $escuta.Stop() } catch {}
Log "encerrou"
