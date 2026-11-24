"""conpty.py — pseudo-terminal do Windows (ConPTY) em ctypes puro.

Par do pty.fork() Unix para o terminal web v2 do web.py no servidor
Windows. Sem dependências: o Python embeddable do servidor (py\\) não tem
pip, então CreatePseudoConsole/CreateProcess/ReadFile/WriteFile entram
direto pelo kernel32 com argtypes declarados (sem argtypes o ctypes
empacota int como 32 bits e trunca ponteiros em x64).

Desenho segue o EchoCon da documentação: dois pipes anônimos, o
CreatePseudoConsole consome as pontas "do console" (nós fechamos essas em
seguida — segurá-las vazaria handles e o EOF nunca chegaria), e o processo
nasce preso ao pseudoconsole pelo atributo PROC_THREAD_ATTRIBUTE_
PSEUDOCONSOLE com EXTENDED_STARTUPINFO_PRESENT. A leitura é uma thread
dona do pipe de saída empurrando bytes numa fila: read(timeout) devolve
bytes, b"" no timeout e None quando o processo saiu (o mesmo contrato do
os.read(fd) no caminho Unix, que devolve b"" no EOF).

    p = ConPty(argv, cwd, cols=80, rows=24)
    p.read(15)      # bytes | b"" (nada) | None (morreu)
    p.write(b"dir\r")
    p.resize(cols, rows)
    p.alive / p.pid
    p.terminate()
"""
import ctypes
import ctypes.wintypes as wt
import os
import queue
import threading
import time

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

# diagnóstico de campo (23/11): rastro dos nascimentos/mortes num log
# simples — liga criando o arquivo sentinela conpty-debug.on ao lado do módulo
_SENTINELA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "conpty-debug.on")


def _dbg_ativo():
    return os.path.exists(_SENTINELA)


def _dbg(msg):
    if not _dbg_ativo():
        return
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "conpty-debug.txt"), "a", encoding="utf-8") as f:
            f.write("%.1f %s\n" % (time.time(), msg))
    except OSError:
        pass

PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
EXTENDED_STARTUPINFO_PRESENT = 0x00080000
WAIT_TIMEOUT = 0x102


class STARTUPINFOW(ctypes.Structure):     # wintypes não traz: declaração na mão
    _fields_ = [("cb", wt.DWORD), ("lpReserved", wt.LPWSTR),
                ("lpDesktop", wt.LPWSTR), ("lpTitle", wt.LPWSTR),
                ("dwX", wt.DWORD), ("dwY", wt.DWORD),
                ("dwXSize", wt.DWORD), ("dwYSize", wt.DWORD),
                ("dwXCountChars", wt.DWORD), ("dwYCountChars", wt.DWORD),
                ("dwFillAttribute", wt.DWORD), ("dwFlags", wt.DWORD),
                ("wShowWindow", wt.WORD), ("cbReserved2", wt.WORD),
                ("lpReserved2", ctypes.c_void_p),
                ("hStdInput", wt.HANDLE), ("hStdOutput", wt.HANDLE),
                ("hStdError", wt.HANDLE)]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", wt.HANDLE), ("hThread", wt.HANDLE),
                ("dwProcessId", wt.DWORD), ("dwThreadId", wt.DWORD)]


class STARTUPINFOEXW(ctypes.Structure):
    _fields_ = [("StartupInfo", STARTUPINFOW),
                ("lpAttributeList", ctypes.c_void_p)]


def _declara():
    k = kernel32
    k.CreatePipe.argtypes = (ctypes.POINTER(wt.HANDLE),
                             ctypes.POINTER(wt.HANDLE), ctypes.c_void_p,
                             wt.DWORD)
    k.CreatePipe.restype = wt.BOOL
    k.CreatePseudoConsole.argtypes = (wt._COORD, wt.HANDLE, wt.HANDLE,
                                      wt.DWORD, ctypes.POINTER(wt.HANDLE))
    k.CreatePseudoConsole.restype = ctypes.c_long
    k.ResizePseudoConsole.argtypes = (wt.HANDLE, wt._COORD)
    k.ResizePseudoConsole.restype = ctypes.c_long
    k.ClosePseudoConsole.argtypes = (wt.HANDLE,)
    k.InitializeProcThreadAttributeList.argtypes = (
        ctypes.c_void_p, wt.DWORD, wt.DWORD, ctypes.POINTER(ctypes.c_size_t))
    k.InitializeProcThreadAttributeList.restype = wt.BOOL
    k.UpdateProcThreadAttribute.argtypes = (
        ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t))
    k.UpdateProcThreadAttribute.restype = wt.BOOL
    k.DeleteProcThreadAttributeList.argtypes = (ctypes.c_void_p,)
    k.CreateProcessW.argtypes = (
        wt.LPCWSTR, wt.LPWSTR, ctypes.c_void_p, ctypes.c_void_p, wt.BOOL,
        wt.DWORD, ctypes.c_void_p, wt.LPCWSTR, ctypes.c_void_p,
        ctypes.c_void_p)
    k.CreateProcessW.restype = wt.BOOL
    k.ReadFile.argtypes = (wt.HANDLE, ctypes.c_void_p, wt.DWORD,
                           ctypes.POINTER(wt.DWORD), ctypes.c_void_p)
    k.ReadFile.restype = wt.BOOL
    k.WriteFile.argtypes = (wt.HANDLE, ctypes.c_void_p, wt.DWORD,
                            ctypes.POINTER(wt.DWORD), ctypes.c_void_p)
    k.WriteFile.restype = wt.BOOL
    k.WaitForSingleObject.argtypes = (wt.HANDLE, wt.DWORD)
    k.WaitForSingleObject.restype = wt.DWORD
    k.TerminateProcess.argtypes = (wt.HANDLE, wt.UINT)
    k.TerminateProcess.restype = wt.BOOL
    k.CloseHandle.argtypes = (wt.HANDLE,)
    k.CloseHandle.restype = wt.BOOL


_declara()


def _cmdline(argv):
    """argv -> linha de comando (aspas só onde precisa; nossos caminhos
    C:\\SuporteRemoto e C:\\Windows\\System32 não têm espaço)."""
    pedaco = []
    for a in argv:
        a = str(a)
        if not a:
            pedaco.append('""')
        elif any(ch in a for ch in ' \t"'):
            pedaco.append('"%s"' % a.replace('"', '\\"'))
        else:
            pedaco.append(a)
    return " ".join(pedaco)


class ConPty:
    def __init__(self, argv, cwd=None, cols=80, rows=24):
        self.pid = None
        self._hpc = None
        self._hproc = None
        self._w_in = None
        self._r_out = None
        self._attr = None
        self._wlock = threading.Lock()
        self._fila = queue.Queue()

        r_in, w_in = wt.HANDLE(), wt.HANDLE()      # servidor -> console
        r_out, w_out = wt.HANDLE(), wt.HANDLE()    # console -> servidor
        if not kernel32.CreatePipe(ctypes.byref(r_in), ctypes.byref(w_in),
                                   None, 0):
            raise OSError(ctypes.get_last_error(), "CreatePipe(in)")
        if not kernel32.CreatePipe(ctypes.byref(r_out), ctypes.byref(w_out),
                                   None, 0):
            raise OSError(ctypes.get_last_error(), "CreatePipe(out)")

        hpc = wt.HANDLE()
        hr = kernel32.CreatePseudoConsole(wt._COORD(cols, rows), r_in, w_out,
                                          0, ctypes.byref(hpc))
        if hr != 0:
            raise OSError(hr & 0xFFFFFFFF, "CreatePseudoConsole")
        # o conhost segurou as pontas dele; segurá-las aqui vaza handle e
        # segura o EOF pra sempre (lição do EchoCon)
        kernel32.CloseHandle(r_in)
        kernel32.CloseHandle(w_out)
        self._hpc = hpc.value
        self._w_in, self._r_out = w_in, r_out

        # attribute list: consulta tamanho, aloca, init, pendura o HPCON
        precisa = ctypes.c_size_t()
        kernel32.InitializeProcThreadAttributeList(None, 1, 0,
                                                   ctypes.byref(precisa))
        attr = ctypes.create_string_buffer(precisa.value)
        if not kernel32.InitializeProcThreadAttributeList(attr, 1, 0,
                                                          ctypes.byref(precisa)):
            raise OSError(ctypes.get_last_error(), "InitializeProcThreadAttributeList")
        # lpValue do PSEUDOCONSOLE é O PRÓPRIO handle (valor bruto, como o
        # EchoCon passa hPC direto) — byref aqui entregaria o endereço da
        # variável como HPCON e o filho nasceria sem console: exit 0,
        # output no void, EOF que nunca chega (bug caçado no debug 23/11)
        if not kernel32.UpdateProcThreadAttribute(
                attr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                ctypes.c_void_p(self._hpc), ctypes.sizeof(ctypes.c_void_p),
                None, None):
            raise OSError(ctypes.get_last_error(), "UpdateProcThreadAttribute")
        self._attr = attr

        si = STARTUPINFOEXW()
        si.StartupInfo.cb = ctypes.sizeof(STARTUPINFOEXW)
        si.lpAttributeList = ctypes.cast(attr, ctypes.c_void_p).value
        pi = PROCESS_INFORMATION()
        cmd = ctypes.create_unicode_buffer(_cmdline(argv))
        # bInheritHandles FALSE: o filho conversa só com o pseudoconsole
        if not kernel32.CreateProcessW(
                None, cmd, None, None, False, EXTENDED_STARTUPINFO_PRESENT,
                None, cwd, ctypes.byref(si), ctypes.byref(pi)):
            self.terminate()
            raise OSError(ctypes.get_last_error(),
                          "CreateProcessW: %s" % _cmdline(argv)[:200])
        self.pid = pi.dwProcessId
        self._hproc = pi.hProcess
        kernel32.CloseHandle(pi.hThread)

        threading.Thread(target=self._leitor, daemon=True).start()
        _dbg("nasce pid=%s argv0=%s" % (self.pid, argv[0]))

    def _leitor(self):
        """Único dono do pipe de saída: ReadFile bloqueante -> fila."""
        buf = ctypes.create_string_buffer(65536)
        n = wt.DWORD()
        while True:
            if not kernel32.ReadFile(self._r_out, buf, 65536,
                                     ctypes.byref(n), None):
                break
            if n.value:
                self._fila.put(buf.raw[:n.value])
        self._fila.put(None)          # EOF: o web.py entende como fim
        code = ctypes.c_ulong()       # diagnóstico 23/11: por que o filho morre?
        kernel32.GetExitCodeProcess(self._hproc, ctypes.byref(code))
        _dbg("pid=%s leitor fim exit=0x%08X" % (self.pid, code.value))

    def read(self, timeout):
        """bytes novos | b"" (nada no timeout) | None (processo saiu)."""
        try:
            return self._fila.get(timeout=timeout)
        except queue.Empty:
            return b""

    def write(self, dados):
        with self._wlock:
            n = wt.DWORD()
            buf = ctypes.create_string_buffer(bytes(dados), len(dados))
            if not kernel32.WriteFile(self._w_in, buf, len(dados),
                                      ctypes.byref(n), None):
                raise OSError(ctypes.get_last_error(), "WriteFile(pty)")

    def resize(self, cols, rows):
        if self._hpc:
            kernel32.ResizePseudoConsole(self._hpc, wt._COORD(cols, rows))

    @property
    def alive(self):
        if not self._hproc:
            return False
        return kernel32.WaitForSingleObject(self._hproc, 0) == WAIT_TIMEOUT

    def terminate(self):
        """Fecha o pseudoconsole (CTRL_CLOSE pro filho) e garante a morte
        do processo — o par do SIGHUP do caminho Unix. Idempotente."""
        if self._hpc:
            kernel32.ClosePseudoConsole(self._hpc)
            self._hpc = None
        if self._hproc:
            kernel32.TerminateProcess(self._hproc, 1)
            kernel32.CloseHandle(self._hproc)
            self._hproc = None
        for h in (self._w_in, self._r_out):
            if h:
                kernel32.CloseHandle(h)
        self._w_in = self._r_out = None
        if self._attr:
            kernel32.DeleteProcThreadAttributeList(self._attr)
            self._attr = None
