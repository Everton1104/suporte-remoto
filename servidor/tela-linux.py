#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# tela-linux.py — servidor de tela (MJPEG) + controle (mouse/teclado) na
# maquina LINUX do cliente. Par do tela.ps1 (Windows): MESMO protocolo HTTP,
# mesmas rotas e auto-limites — web.py/tela.sh/pagina nao mudam.
#
#   GET  /mjpeg?w=&q=&i= -> stream multipart (um viewer; perfil w/q/i)
#   POST /input  -> injeta evento de mouse/teclado (JSON, mesmo formato do .ps1)
#   GET  /info   -> {"w":..,"h":..,"fps":..,"kbps":..,"clip":0/1}
#   GET/POST /clip -> le/escreve a area de transferencia (precisa xclip|xsel)
#   POST /sair   -> encerra o servidor
#
# Dependencias (cascata, nada e instalado por este script):
#   - servidor X11 acessivel (DISPLAY + XAUTHORITY autodetectados: lightdm/
#     gdm/sddm/home do usuario) — Wayland puro nao suportado (mensagem clara)
#   - encoder JPEG: python3-PIL (preferido) OU ffmpeg com x11grab
#   - injecao: XTest via libXtst (sempre presente com X11); xdotool e opcional,
#     so melhora texto unicode/acentos (t=texto e chars sem keycode)
#
# Roda como root ou como o usuario logado; log em /tmp/suporte-tela.log no
# mesmo formato do tela.ps1 (heartbeat "vivo quadros=N" por minuto).
import argparse
import ctypes
import glob
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO

AP = argparse.ArgumentParser()
AP.add_argument("--porta", type=int, default=28090)
AP.add_argument("--intervalo", type=int, default=350)   # ms entre quadros
AP.add_argument("--largura-max", type=int, default=1600)
AP.add_argument("--qualidade", type=int, default=62)
AP.add_argument("--sessao-max-min", type=int, default=30)
AP.add_argument("--sem-viewer-min", type=int, default=10)
ARGS = AP.parse_args()

LOG_PATH = "/tmp/suporte-tela.log"
_LOG_NOVA = [True]  # 1a escrita trunca o log (instancia nova, como o .ps1)


def log(m):
    try:
        with open(LOG_PATH, "w" if _LOG_NOVA[0] else "a") as f:
            _LOG_NOVA[0] = False
            f.write("%s %s\n" % (datetime.now().strftime("%H:%M:%S"), m))
    except OSError:
        pass


log("inicio porta=%d pid=%d" % (ARGS.porta, os.getpid()))


def morre(cod, msg):
    log("ERRO %s" % msg)
    sys.stderr.write(msg + "\n")
    sys.exit(cod)


# ---------------------------------------------------------------- X11 (ctypes)

X11 = ctypes.CDLL("libX11.so.6")
try:
    XTST = ctypes.CDLL("libXtst.so.6")
except OSError:
    XTST = None  # da pra ver a tela sem controlar
X11.XInitThreads()

X11.XOpenDisplay.restype = ctypes.c_void_p
X11.XOpenDisplay.argtypes = [ctypes.c_char_p]
X11.XCloseDisplay.argtypes = [ctypes.c_void_p]
X11.XDefaultRootWindow.restype = ctypes.c_ulong
X11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X11.XDisplayWidth.restype = ctypes.c_int
X11.XDisplayWidth.argtypes = [ctypes.c_void_p]
X11.XDisplayHeight.restype = ctypes.c_int
X11.XDisplayHeight.argtypes = [ctypes.c_void_p]
X11.XAllPlanes.restype = ctypes.c_ulong
X11.XGetImage.restype = ctypes.c_void_p
X11.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                          ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
                          ctypes.c_ulong, ctypes.c_int]
X11.XWarpPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
                             ctypes.c_int, ctypes.c_int, ctypes.c_uint,
                             ctypes.c_uint, ctypes.c_int, ctypes.c_int]
X11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_bool]
X11.XStringToKeysym.restype = ctypes.c_ulong
X11.XStringToKeysym.argtypes = [ctypes.c_char_p]
X11.XKeysymToKeycode.restype = ctypes.c_ubyte
X11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
if XTST:
    XTST.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                          ctypes.c_bool, ctypes.c_ulong]
    XTST.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_ubyte,
                                       ctypes.c_bool, ctypes.c_ulong]


class XImage(ctypes.Structure):
    _fields_ = [("width", ctypes.c_int), ("height", ctypes.c_int),
                ("xoffset", ctypes.c_int), ("format", ctypes.c_int),
                ("data", ctypes.c_void_p), ("byte_order", ctypes.c_int),
                ("bitmap_unit", ctypes.c_int),
                ("bitmap_bit_order", ctypes.c_int),
                ("bitmap_pad", ctypes.c_int), ("depth", ctypes.c_int),
                ("bytes_per_line", ctypes.c_int),
                ("bits_per_pixel", ctypes.c_int),
                ("red_mask", ctypes.c_ulong), ("green_mask", ctypes.c_ulong),
                ("blue_mask", ctypes.c_ulong), ("obdata", ctypes.c_void_p),
                ("create_image", ctypes.c_void_p),
                ("destroy_image", ctypes.c_void_p),
                ("get_pixel", ctypes.c_void_p),
                ("put_pixel", ctypes.c_void_p),
                ("sub_image", ctypes.c_void_p),
                ("add_pixel", ctypes.c_void_p)]


def _xauth_candidatos(disp_num):
    """Xauthority provaveis para o display :N — root costuma precisar do auth
    do display manager (lightdm/gdm/sddm); usuario comum usa o ~/.Xauthority."""
    n = str(disp_num)
    cands = [os.environ.get("XAUTHORITY")]
    cands += ["/var/run/lightdm/root/:" + n]
    cands += glob.glob("/run/user/*/" + "gdm/Xauthority")
    cands += ["/var/lib/gdm/.Xauthority", "/var/lib/sddm/.Xauthority",
              "/run/sddm/.Xauthority"]
    cands += glob.glob("/home/*/.Xauthority")
    cands += [os.path.expanduser("~/.Xauthority")]
    saida = []
    for c in cands:
        if c and c not in saida and os.path.isfile(c):
            saida.append(c)
    return saida


def achar_x():
    """Abre o 1o display que der: env DISPLAY, depois /tmp/.X11-unix/X*.
    Seta DISPLAY/XAUTHORITY no env do processo (ffmpeg/xdotool herdam)."""
    tentativas = []
    disps = []
    if os.environ.get("DISPLAY"):
        disps.append(os.environ["DISPLAY"])
    disps += sorted((":" + os.path.basename(p)[1:])
                    for p in glob.glob("/tmp/.X11-unix/X*"))
    for d in disps:
        num = d.split(".", 1)[0].lstrip(":")
        for xa in _xauth_candidatos(num) or [None]:
            os.environ["DISPLAY"] = d
            if xa:
                os.environ["XAUTHORITY"] = xa
            h = X11.XOpenDisplay(None)
            tentativas.append("%s (auth=%s)" % (d, xa))
            if h:
                return h, d, xa
            if xa:
                os.environ.pop("XAUTHORITY", None)
    morre(4, "sem acesso ao X11: tentei %s — Wayland puro? usuario logado?"
          % "; ".join(tentativas[:6]))


DISP, DISPLAY_ACHADO, XAUTH_ACHADO = achar_x()
ROOT = X11.XDefaultRootWindow(DISP)
TELA_W = X11.XDisplayWidth(DISP, 0)
TELA_H = X11.XDisplayHeight(DISP, 0)
W_STREAM = min(TELA_W, ARGS.largura_max)
H_STREAM = int(TELA_H * W_STREAM / TELA_W)
log("X %s %dx%d -> stream %dx%d (auth=%s)%s" % (
    DISPLAY_ACHADO, TELA_W, TELA_H, W_STREAM, H_STREAM, XAUTH_ACHADO,
    "" if XTST else " — SEM libXtst: so visual, sem controle"))

XLOCK = threading.Lock()  # Xlib sem XInitThreads-safe por chamada dupla


# ------------------------------------------------------------------ captura

TEM_PIL = False
try:
    from PIL import Image  # noqa: E402
    TEM_PIL = True
except ImportError:
    pass


class CapturaPIL:
    """XGetImage (ctypes) -> PIL -> JPEG. Sem processos externos."""

    def __init__(self):
        self.planes = X11.XAllPlanes()

    def quadro(self, w=None, q=None):
        w = w or ARGS.largura_max
        q = q or ARGS.qualidade
        with XLOCK:
            xi_p = X11.XGetImage(DISP, ROOT, 0, 0, TELA_W, TELA_H,
                                 self.planes, 2)  # 2 = ZPixmap
        if not xi_p:
            raise RuntimeError("XGetImage falhou (tela travada/protected?)")
        xi = ctypes.cast(xi_p, ctypes.POINTER(XImage)).contents
        try:
            n = xi.height * xi.bytes_per_line
            buf = ctypes.string_at(xi.data, n)
            bpp = xi.bits_per_pixel
            if bpp == 32:
                raw = "BGRA" if xi.red_mask == 0xFF000000 else "BGRX"
            elif bpp == 24:
                raw = "BGR"
            else:
                raise RuntimeError("pixels %dbpp inesperado" % bpp)
            img = Image.frombytes("RGB", (xi.width, xi.height), buf,
                                  "raw", raw, xi.bytes_per_line, 1)
        finally:
            # XDestroyImage e macro: chama o destroy_image da propria struct
            cb = ctypes.cast(xi.destroy_image,
                             ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p))
            cb(xi_p)
        if img.width > w:
            nh = int(img.height * w / img.width)
            img = img.resize((w, nh), Image.LANCZOS)
            img = img.convert("RGB")
        bio = BytesIO()
        img.save(bio, "JPEG", quality=q)
        return bio.getvalue()


class CapturaFFmpeg:
    """ffmpeg -f x11grab -> MJPEG no stdout; thread le o pipe e guarda so o
    ULTIMO frame (viewer lento nao acumula latencia)."""

    SOI, EOI = b"\xff\xd8", b"\xff\xd9"

    def __init__(self):
        vf = ("scale=%d:-2" % ARGS.largura_max
              if TELA_W > ARGS.largura_max else "null")
        self.proc = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error",
             "-f", "x11grab", "-framerate", "8", "-draw_mouse", "1",
             "-i", DISPLAY_ACHADO, "-an", "-vf", vf,
             "-f", "mjpeg", "-q:v", str(max(2, 10 - ARGS.qualidade // 10)),
             "pipe:1"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.lock = threading.Lock()
        self.ultimo = None
        threading.Thread(target=self._le, daemon=True).start()

    def _le(self):
        buf = b""
        try:
            while True:
                pedaco = self.proc.stdout.read(65536)
                if not pedaco:
                    break
                buf += pedaco
                while True:
                    i = buf.find(self.SOI)
                    if i < 0:
                        buf = buf[-1:]
                        break
                    j = buf.find(self.EOI, i + 2)
                    if j < 0:
                        buf = buf[i:]
                        break
                    with self.lock:
                        self.ultimo = buf[i:j + 2]
                    buf = buf[j + 2:]
        except OSError:
            pass
        with self.lock:
            self.ultimo = None

    def quadro(self, w=None, q=None):
        # w/q do perfil vem do processo ffmpeg (fixo no launch): a query do
        # viewer so afeta o pacing — captura ja em 6fps no pipe
        for _ in range(50):  # espera ate ~10s por um frame
            with self.lock:
                f = self.ultimo
            if f:
                return f
            if self.proc.poll() is not None:
                raise RuntimeError("ffmpeg morreu (x11grab presente?)")
            time.sleep(0.2)
        raise RuntimeError("ffmpeg nao entregou frame (10s)")


if TEM_PIL:
    CAPTURA = CapturaPIL()
    log("captura: XGetImage+PIL")
elif shutil.which("ffmpeg"):
    CAPTURA = CapturaFFmpeg()
    log("captura: ffmpeg x11grab")
else:
    morre(3, "sem encoder JPEG no cliente: instale python3-pil (ou ffmpeg)")


# ------------------------------------------------------------------ injecao

# teclas nomeadas que a pagina manda -> keysyms X11
KEYSYMS = {
    "Enter": 0xFF0D, "Backspace": 0xFF08, "Tab": 0xFF09, "Escape": 0xFF1B,
    "Delete": 0xFFFF, "Insert": 0xFF63, "Home": 0xFF50, "End": 0xFF57,
    "PageUp": 0xFF55, "PageDown": 0xFF56,
    "ArrowLeft": 0xFF51, "ArrowUp": 0xFF52, "ArrowRight": 0xFF53,
    "ArrowDown": 0xFF54,
    "Meta": 0xFFEB, "ContextMenu": 0xFF67,   # Super_L / Menu (paridade .ps1)
}
for _i in range(1, 13):
    KEYSYMS["F%d" % _i] = 0xFFBE + _i - 1
MODS = {"ctrl": 0xFFE3, "alt": 0xFFE9, "shift": 0xFFE1,   # Control_L Alt_L Shift_L
        "meta": 0xFFEB}                                    # Super_L
TEM_XDOTOOL = bool(shutil.which("xdotool"))


def _keycode(sym):
    return X11.XKeysymToKeycode(DISP, sym)


def _tecla(keycode, baixo):
    with XLOCK:
        XTST.XTestFakeKeyEvent(DISP, keycode, baixo, 0)
        X11.XSync(DISP, False)


def _botao(b, baixo):
    with XLOCK:
        XTST.XTestFakeButtonEvent(DISP, b, baixo, 0)
        X11.XSync(DISP, False)


def mover(x, y):
    with XLOCK:
        X11.XWarpPointer(DISP, 0, ROOT, 0, 0, 0, 0,
                         int(float(x) * TELA_W), int(float(y) * TELA_H))
        X11.XSync(DISP, False)


def injeta_tecla(e):
    if not XTST:
        return
    # shift so acompanha tecla NOMEADA (Enter, F5...) — no evento de caractere
    # o navegador ja manda o char maiusculo (paridade com o .ps1)
    nomes = ["ctrl", "alt", "meta"] + (["shift"] if e.get("k") else [])
    mods = [MODS[m] for m in nomes if e.get(m)]
    for m in mods:
        _tecla(_keycode(m), True)
    try:
        nome, c = e.get("k"), str(e.get("c") or "")
        if nome and nome in KEYSYMS:
            kc = _keycode(KEYSYMS[nome])
            if kc:
                _tecla(kc, True)
                time.sleep(0.012)
                _tecla(kc, False)
        elif len(c) == 1:
            # ctrl+alt+caractere = AltGr (pt-BR): keysym unicode direto,
            # nao forma atalho — paridade com o .ps1
            if (e.get("ctrl") and e.get("alt")) and not nome:
                kc = _keycode(ord(c))
            elif (e.get("ctrl") or e.get("alt")) and c.lower().isalpha():
                kc = _keycode(ord(c.lower()))     # atalho = tecla fisica
            else:
                kc = _keycode(ord(c))             # keysym unicode direto
                if not kc and TEM_XDOTOOL:
                    subprocess.run(["xdotool", "type", "--delay", "0", c],
                                   timeout=3, stderr=subprocess.DEVNULL)
                    return
            if kc:
                _tecla(kc, True)
                time.sleep(0.012)
                _tecla(kc, False)
            else:
                log("tecla sem keycode: %r" % c)
    finally:
        for m in reversed(mods):
            _tecla(_keycode(m), False)


def injeta_texto(s):
    if TEM_XDOTOOL:
        subprocess.run(["xdotool", "type", "--delay", "0", "--", str(s)],
                       timeout=3, stderr=subprocess.DEVNULL)
        return
    for c in str(s):
        kc = _keycode(ord(c))
        if kc:
            _tecla(kc, True)
            _tecla(kc, False)
            time.sleep(0.008)


def injetar(e):
    if not XTST:
        return
    t = e.get("t")
    if t == "move":
        mover(e["x"], e["y"])
    elif t in ("down", "up"):
        if e.get("x") is not None:
            mover(e["x"], e["y"])
        _botao(int(e.get("b", 0)) + 1, t == "down")
    elif t == "click":
        mover(e["x"], e["y"])
        _botao(int(e.get("b", 0)) + 1, True)
        time.sleep(0.03)
        _botao(int(e.get("b", 0)) + 1, False)
    elif t == "scroll":
        b = 5 if int(e.get("d", 1)) > 0 else 4  # 5=baixo 4=cima (X11)
        _botao(b, True)
        _botao(b, False)
    elif t == "key":
        injeta_tecla(e)
    elif t == "texto":
        injeta_texto(e.get("s", ""))


# ------------------------------------------------------------------ servidor

ESTADO = {"viewer": False, "quadros": 0, "ultimo_viewer": time.time(),
          "win_quadros": 0, "win_bytes": 0, "win_t0": time.time(),
          "fps": 0, "kbps": 0, "clip": 0}
ELOCK = threading.Lock()
INICIO = time.time()
RODANDO = [True]

# clipboard de texto (paridade .ps1): exige xclip OU xsel no cliente
_CLIPCMD = shutil.which("xclip"), shutil.which("xsel")


def clip_get():
    # clipboard vazio (ou com nao-texto) devolve rc!=0 + stdout vazio: nao
    # e erro — devolve "". Erro de verdade (sem xclip, timeout) vira excecao
    if shutil.which("xclip"):
        r = subprocess.run(["xclip", "-selection", "clipboard", "-o"],
                           capture_output=True, timeout=3)
        return r.stdout.decode("utf-8", "replace")
    if shutil.which("xsel"):
        r = subprocess.run(["xsel", "-b", "-o"], capture_output=True, timeout=3)
        return r.stdout.decode("utf-8", "replace")
    raise RuntimeError("sem xclip/xsel no cliente")


def clip_set(txt):
    if shutil.which("xclip"):
        cmd = ["xclip", "-selection", "clipboard"]
    elif shutil.which("xsel"):
        cmd = ["xsel", "-b", "-i"]
    else:
        raise RuntimeError("sem xclip/xsel no cliente")
    subprocess.run(cmd, input=txt.encode(), timeout=3)


ESTADO["clip"] = 1 if (_CLIPCMD[0] or _CLIPCMD[1]) else 0


def _rst(sock):
    """Fecha com RST (abort do .ps1): close limpo dava flush de headers 200
    e o navegador ficava 'carregando' pra sempre."""
    try:
        sock.setsockopt(__import__("socket").SOL_SOCKET,
                        __import__("socket").SO_LINGER,
                        __import__("struct").pack("ii", 1, 0))
        sock.close()
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "suporte-tela/1"

    def log_message(self, *_a):
        pass

    def _resp(self, cod, corpo=b"", ctype="text/plain"):
        self.send_response(cod)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(corpo)))
        self.send_header("Connection", "close")
        self.end_headers()
        if corpo:
            self.wfile.write(corpo)

    def do_GET(self):
        rota = self.path.split("?")[0]
        if rota == "/info":
            # stats da janela atual (a pagina le a cada ~2s; reset junto)
            agora = time.time()
            with ELOCK:
                seg = agora - ESTADO["win_t0"]
                if seg >= 1.0:
                    ESTADO["fps"] = int(round(ESTADO["win_quadros"] / seg))
                    ESTADO["kbps"] = int(round(ESTADO["win_bytes"] / seg / 1024))
                    ESTADO["win_quadros"] = 0
                    ESTADO["win_bytes"] = 0
                    ESTADO["win_t0"] = agora
                corpo = json.dumps({"w": W_STREAM, "h": H_STREAM,
                                    "fps": ESTADO["fps"],
                                    "kbps": ESTADO["kbps"],
                                    "clip": ESTADO["clip"]}).encode()
            self._resp(200, corpo, "application/json")
        elif rota == "/clip":
            try:
                self._resp(200, clip_get().encode("utf-8"),
                           "text/plain; charset=utf-8")
            except Exception as exc:
                self._resp(500, ("clip: %s" % exc).encode())
        elif rota == "/mjpeg":
            self._mjpeg()
        else:
            self._resp(404, b"??")

    def _mjpeg(self):
        # perfil da conexao: ?w=largura&q=qualidade&i=intervalo_ms (clamp;
        # no backend ffmpeg so o i tem efeito — captura fixa no launch)
        p = dict(a.split("=", 1) for a in self.path.split("?")[1].split("&")
                 if "=" in a) if "?" in self.path else {}
        try:
            w = min(1920, max(640, int(p.get("w", ARGS.largura_max))))
        except ValueError:
            w = ARGS.largura_max
        try:
            q = min(80, max(30, int(p.get("q", ARGS.qualidade))))
        except ValueError:
            q = ARGS.qualidade
        try:
            iv = min(1000, max(60, int(p.get("i", ARGS.intervalo))))
        except ValueError:
            iv = ARGS.intervalo
        with ELOCK:
            if ESTADO["viewer"]:
                self._resp(409, b"viewer ja conectado")
                return
            ESTADO["viewer"] = True
        try:
            # captura de PROVA antes de comprometer o viewer (paridade .ps1):
            # sem isto, falha pos-headers = 200 vazio = pagina carregando eterno
            try:
                CAPTURA.quadro(w, q)
            except Exception as exc:
                log("ERRO captura: %s" % exc)
                self._resp(500, ("captura falhou: %s" % exc).encode())
                return
            self.send_response(200)
            self.send_header("Content-Type",
                             "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Connection", "close")
            self.end_headers()
            log("viewer conectado (w=%d q=%d i=%d)" % (w, q, iv))
            self.connection.settimeout(3)
            frame = None
            while RODANDO[0]:
                t0 = time.time()
                if frame is None:
                    frame = CAPTURA.quadro(w, q)
                cab = (b"--frame\r\nContent-Type: image/jpeg\r\n"
                       b"Content-Length: %d\r\n\r\n" % len(frame))
                self.wfile.write(cab + frame + b"\r\n")
                self.wfile.flush()
                with ELOCK:
                    ESTADO["quadros"] += 1
                    ESTADO["ultimo_viewer"] = time.time()
                    ESTADO["win_quadros"] += 1
                    ESTADO["win_bytes"] += len(frame)
                frame = None
                # pacing: dorme so o que sobrou do intervalo-alvo
                resto = iv / 1000.0 - (time.time() - t0)
                if resto > 0:
                    time.sleep(resto)
        except Exception as exc:
            log("viewer desconectou (%s)" % exc)
            _rst(self.connection)
        finally:
            with ELOCK:
                ESTADO["viewer"] = False

    def do_POST(self):
        rota = self.path.split("?")[0]
        n = int(self.headers.get("Content-Length") or 0)
        corpo = self.rfile.read(n) if n else b""
        if rota == "/input":
            try:
                ev = json.loads(corpo.decode("utf-8"))
            except ValueError:
                self._resp(400, b"json?")
                return
            if ev:
                if ev.get("t") != "move":
                    log("in t=%s b=%s k=%s c=%s" % (
                        ev.get("t"), ev.get("b"), ev.get("k"), ev.get("c")))
                try:
                    injetar(ev)
                except Exception as exc:
                    log("injetar falhou: %s" % exc)
            with ELOCK:
                ESTADO["ultimo_viewer"] = time.time()
            self._resp(204)
        elif rota == "/clip":
            try:
                clip_set(corpo.decode("utf-8"))
                self._resp(204)
            except Exception as exc:
                log("clip: falhou (%s)" % exc)
                self._resp(500, ("clip: %s" % exc).encode())
        elif rota == "/sair":
            self._resp(204)
            log("pedido /sair")
            threading.Thread(target=self._desligar, daemon=True).start()
        else:
            self._resp(404, b"??")

    def _desligar(self):
        time.sleep(0.3)  # deixa o 204 sair
        RODANDO[0] = False
        log("encerrou")
        os._exit(0)


def _vigia():
    ultimo_bat = time.time()
    while RODANDO[0]:
        time.sleep(5)
        agora = time.time()
        with ELOCK:
            sem_viewer = (not ESTADO["viewer"] and
                          agora - ESTADO["ultimo_viewer"]
                          >= ARGS.sem_viewer_min * 60)
        if agora - INICIO >= ARGS.sessao_max_min * 60:
            log("fim: sessao maxima")
            break
        if sem_viewer:
            log("fim: sem viewer por %d min" % ARGS.sem_viewer_min)
            break
        if agora - ultimo_bat >= 60:
            with ELOCK:
                log("vivo quadros=%d viewer=%s" % (ESTADO["quadros"],
                                                   ESTADO["viewer"]))
            ultimo_bat = agora
    RODANDO[0] = False
    log("encerrou")
    os._exit(0)


import signal  # noqa: E402
signal.signal(signal.SIGTERM, lambda *_a: os._exit(0))

try:
    SRV = ThreadingHTTPServer(("127.0.0.1", ARGS.porta), Handler)
except OSError as exc:
    morre(1, "ouvindo porta %d: %s" % (ARGS.porta, exc))
SRV.daemon_threads = True
threading.Thread(target=_vigia, daemon=True).start()
log("ouvindo localhost:%d" % ARGS.porta)
try:
    SRV.serve_forever(poll_interval=0.5)
except KeyboardInterrupt:
    pass
