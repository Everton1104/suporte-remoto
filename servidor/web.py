#!/usr/bin/env python3
"""web.py — camada web do suporte remoto (v2: agente permanente + registro).

Rotas do cliente final:
  /  /baixar            -> instalador do AGENTE permanente (.bat/.sh pelo UA)
  /instalar/sessao      -> instalador de sessão única (fluxo efêmero original)
Rotas do agente instalado:
  POST /agente/registrar   -> registra o cliente, atribui porta e devolve a
                              pubkey do técnico dele (idempotente por chave)
  GET  /agente/estado?id=  -> poll do agente: {"conectar": bool, "porta": n}
  POST /agente/remover     -> desinstalação: revoga e apaga o registro
Rotas do técnico:
  GET  /painel             -> tela de login (ou o painel, se a sessão do cookie valer)
  POST /painel/login       -> valida a senha e cria a sessão (cookie HttpOnly)
  GET  /painel/sair        -> encerra a sessão
  GET  /painel/dados       -> JSON da lista (uso do painel)
  POST /painel/acao        -> {"token","id","acao": conectar|encerrar|remover}
                              (token ainda vale p/ API e testes; no navegador é a sessão)
  POST /painel/nome        -> {"id","nome"}: renomeia o cliente (coluna editável)
  GET  /painel/term?cid=   -> página do terminal xterm do cliente
  GET  /painel/term/stream?cid=&s= -> PTY do atender.sh, saída em stream até fechar
  POST /painel/term/in?s=  -> teclas (corpo cru) | size (cols/rows) | fechar
  GET  /painel/tela?cid=   -> página da tela ao vivo do cliente (MJPEG)
  GET  /painel/tela/stream?cid= -> relay do stream do tela.ps1 (túnel reverso)
  POST /painel/tela/in     -> evento de mouse/teclado (controle remoto)
  POST /painel/tela/parar  -> derruba listener no cliente + ssh -L
  POST /painel/verificar   -> reconsulta o GitHub na hora (alimenta o aviso)
  POST /painel/atualizar   -> roda atualizar-espelho.sh em background; o
                              progresso aparece no banner (poll de 5s do painel)
  GET  /xterm.js /xterm.css /xterm-fit.js -> assets do terminal (servidor/static)

Credenciais em servidor/clientes.json (reg.login, senha PBKDF2); o token_painel
segue como chave de API. Sessões em memória: reiniciar o serviço desloga.

Registro em servidor/clientes.json; chaves do técnico por cliente em
servidor/clientes/<id>/. Portas reversas: 10023+ (10022 = sessão única).
Roda em 127.0.0.1:8090, publicado no Cloudflare Tunnel como
suporte.evertonrs.com.br.
"""
import base64
import fcntl
import hashlib
import hmac
import json
import os
import pty
import queue
import re
import secrets
import select
import signal
import socket
import sys
import struct
import subprocess
import termios
import threading
import time
import urllib.request
from datetime import datetime, timedelta
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

BASE = os.path.dirname(os.path.abspath(__file__))
PORTA = 8090
REGISTRO = os.path.join(BASE, "clientes.json")
DIR_CLIENTES = os.path.join(BASE, "clientes")
AK_TUNEL = "/home/suporte/.ssh/authorized_keys"
PORTA_BASE = 10023      # 10022 fica para o fluxo de sessão única
LIMITE_CLIENTES = 50
URL_BASE = os.environ.get("URL_BASE", "https://suporte.evertonrs.com.br")
DOMINIO = os.environ.get("DOMINIO", "ssh.evertonrs.com.br")
PORTA_PROXY = 2222
LOCK = threading.Lock()
SESSOES = {}          # id da sessão -> datetime em que expira (login do painel)
ARQ_SESSOES = os.path.join(BASE, ".sessoes.json")   # sobrevive a restart do serviço
SESSAO_HS = 12        # horas de validade da sessão
TERMINAIS = {}        # s (uuid do navegador) -> {"pid","fd","cid","ultima"}
TERMINAL_MAX = 3      # terminais simultâneos (threads do servidor)
TERMINAL_IDLE_S = 30 * 60   # terminal sem tráfego por 30min é fechado
# sessões claude VIVAS: o processo mora no servidor (como no code-server) —
# F5/fechar aba só desanexa a janela; reabrir anexa no processo em curso
CLAUDE_SESSOES = {}
CLAUDE_BUF_MAX = 512 * 1024   # scrollback por sessão (reanexo mostra isto)
_CLAUDE_CRIAR_LOCK = threading.Lock()
# tela do cliente (MJPEG + controle): o listener vive no cliente (tela.ps1
# sobe via schtasks /it na sessão logada) e chega até aqui por um ssh -L
# que o tela.sh mantém. Aqui só registramos quem está olhando, pra derrubar
# tudo quando ninguém mais está.
TELAS = {}                 # cid -> {"ativos": int, "ultima": ts}
_TELA_IDLE_S = 45          # sem viewer por isto = derruba listener + ssh -L
ARQ_VERSOES = os.path.join(BASE, "static", "versoes.json")   # versão do espelho
ARQUIVOS_MIRROR = {   # rota /arquivos/<nome> -> content-type (whitelist fechada)
    "openssh-win64.zip": "application/zip",
    "cloudflared-windows-amd64.exe": "application/octet-stream",
    "cloudflared-linux-amd64": "application/octet-stream",
    "cloudflared-linux-arm64": "application/octet-stream",
    # bootstrap do instalador: máquinas sem curl (Win < 1803) baixam o
    # nosso com certutil antes de qualquer outra coisa
    "curl.exe": "application/octet-stream",
    "curl-ca-bundle.crt": "application/octet-stream",
}
ATUALIZACOES = {}     # nome -> {"espelho","atual"} quando o GitHub tem versão nova
CHECAGEM = {"quando": 0.0, "erro": ""}
# botão "atualizar agora" do aviso: roda atualizar-espelho.sh em background e
# o rabo do log alimenta o banner do painel (o /painel/dados já roda a cada 5s)
ATUALIZAR = {"rodando": False, "ok": None, "fim": 0.0}
ARQ_ATUALIZAR_LOG = os.path.join(BASE, ".atualizar-espelho.log")
_ATUALIZAR_LOCK = threading.Lock()


def agora():
    return datetime.now().isoformat(timespec="seconds")


def hash_senha(senha, salt):
    return hashlib.pbkdf2_hmac("sha256", (senha or "").encode(),
                               bytes.fromhex(salt), 200_000).hex()


def senha_ok(reg, senha):
    lg = reg.get("login") or {}
    if "salt" not in lg:
        return False
    return hmac.compare_digest(hash_senha(senha, lg["salt"]), lg.get("senha_hash") or "")


def nova_sessao():
    sid = secrets.token_urlsafe(24)
    SESSOES[sid] = datetime.now() + timedelta(hours=SESSAO_HS)
    _salvar_sessoes()
    return sid


def _salvar_sessoes():
    tmp = ARQ_SESSOES + ".tmp"
    with open(tmp, "w") as f:
        json.dump({k: v.isoformat() for k, v in SESSOES.items()}, f)
    os.replace(tmp, ARQ_SESSOES)


def _carregar_sessoes():
    try:
        with open(ARQ_SESSOES) as f:
            brutas = json.load(f)
    except (OSError, ValueError):
        return
    exp = datetime.now()
    for sid, v in brutas.items():
        try:
            SESSOES[sid] = datetime.fromisoformat(v)
        except ValueError:
            pass
    for sid in [k for k, v in SESSOES.items() if v < exp]:
        SESSOES.pop(sid)
    if brutas:
        _salvar_sessoes()


def carregar():
    if os.path.exists(REGISTRO):
        with open(REGISTRO) as f:
            reg = json.load(f)
        novo = False
    else:
        reg = {"token_painel": secrets.token_urlsafe(12), "clientes": {}}
        print("painel: token de API %s" % reg["token_painel"], flush=True)
        novo = True
    if "login" not in reg:
        # primeira vez (ou reset): senha aleatória impressa UMA vez no log
        senha = secrets.token_urlsafe(8)
        salt = secrets.token_hex(8)
        reg["login"] = {"usuario": "everton", "salt": salt,
                        "senha_hash": hash_senha(senha, salt)}
        print("painel: senha do painel '%s' — anote (para trocar: "
              "apague reg.login em clientes.json e reinicie)" % senha, flush=True)
        novo = True
    if novo:
        salvar(reg)
    return reg


def salvar(reg):
    tmp = REGISTRO + ".tmp"
    with open(tmp, "w") as f:
        json.dump(reg, f, indent=1, sort_keys=True)
    os.replace(tmp, REGISTRO)


def slug(texto):
    s = re.sub(r"[^a-z0-9]+-", "-", (texto or "cliente").lower()).strip("-")[:20]
    return s or "cliente"


def registrar(dados):
    """Registra um agente novo (ou devolve o existente, se a chave já conhece)."""
    chave = dados.get("chave_tunel")
    if isinstance(chave, list):     # PowerShell às vezes manda array de linhas do arquivo
        chave = " ".join(x.strip() for x in chave if isinstance(x, str))
    if not isinstance(chave, str):
        print("registrar: chave_tunel estranho (%s): %r"
              % (type(chave).__name__, chave), flush=True)
        raise ValueError("chave_tunel deve ser texto — baixe o instalador de novo")
    chave = chave.strip()
    if not chave or len(chave.split()) < 2:
        print("registrar: payload incompleto: %r" % (dados,), flush=True)
        raise ValueError("chave_tunel ausente")
    with LOCK:
        reg = carregar()
        for cid, c in reg["clientes"].items():
            if c["chave_tunel_pub"] == chave.split()[1]:
                c["ultimo_contato"] = agora()
                salvar(reg)
                return cid, c["porta"], _pub_tecnico(cid)
        if len(reg["clientes"]) >= LIMITE_CLIENTES:
            raise ValueError("limite de clientes atingido")

        cid = "%s-%s" % (slug(dados.get("nome") or dados.get("maquina")), secrets.token_hex(2))
        porta = max([c["porta"] for c in reg["clientes"].values()] + [PORTA_BASE - 1]) + 1

        d = os.path.join(DIR_CLIENTES, cid)
        os.makedirs(d, exist_ok=True)
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "cliente:%s:tecnico" % cid,
             "-f", os.path.join(d, "chave-tecnico")], check=True)

        linha = chave.split()
        linha[2:] = ["cliente:%s:tunel" % cid]
        with open(AK_TUNEL, "a") as ak:
            ak.write('restrict,port-forwarding,permitlisten="%d",permitopen="127.0.0.1:1",'
                     'command="/bin/false" %s\n' % (porta, " ".join(linha)))

        c = {
            "nome": dados.get("nome") or dados.get("maquina") or "cliente",
            "maquina": dados.get("maquina") or "?",
            "so": dados.get("so") or "?",
            "usuario": dados.get("usuario") or "root",
            "porta": porta,
            "chave_tunel_pub": chave.split()[1],
            "conectar": False,
            "registrado_em": agora(),
            "ultimo_contato": agora(),
        }
        reg["clientes"][cid] = c
        salvar(reg)
        print("cliente novo: %s (%s, porta %d)" % (cid, c["so"], porta), flush=True)
        return cid, porta, _pub_tecnico(cid)


def _pub_tecnico(cid):
    with open(os.path.join(DIR_CLIENTES, cid, "chave-tecnico.pub")) as f:
        return f.read().strip()


def estado(cid):
    with LOCK:
        reg = carregar()
        c = reg["clientes"].get(cid)
        if not c:
            return None
        c["ultimo_contato"] = agora()
        salvar(reg)
        # remover: auto-desinstalacao pendente — agente executa neste poll e
        # confirma via POST /agente/remover; ate la, tunel nao abre mais
        return {"conectar": bool(c.get("conectar")), "porta": c["porta"],
                "remover": bool(c.get("remover"))}


def acao_painel(token, cid, acao):
    """Ação via token de API (testes/scripts); o navegador usa sessão."""
    reg = carregar()
    if not hmac.compare_digest(token or "", reg["token_painel"]):
        raise PermissionError("token invalido")
    return acao_autorizada(cid, acao)


def acao_autorizada(cid, acao):
    with LOCK:
        reg = carregar()
        c = reg["clientes"].get(cid)
        if not c:
            raise KeyError("cliente desconhecido: %s" % cid)
        if acao == "conectar":
            c["conectar"] = True
            salvar(reg)
            return "conectando %s" % cid
        if acao == "encerrar":
            c["conectar"] = False
            salvar(reg)
            return "encerrado %s" % cid
        if acao == "remover":
            if c.get("remover"):
                # 2º clique: máquina nunca voltou pra se desinstalar — revoga tudo
                # na mão (chave, registro, pasta do técnico)
                revogar(cid, reg)
                return "removido %s (forçado — agente nunca confirmou)" % cid
            # 1º clique: pede auto-desinstalacao; flag fica no servidor e o
            # agente executa no primeiro poll que der (offline = fica esperando).
            # Acesso ja corta na hora: conectar obrigatoriamente falso
            c["remover"] = True
            c["conectar"] = False
            salvar(reg)
            return "desinstalação pendente %s (roda no próximo contato do agente)" % cid
        raise ValueError("acao desconhecida: %s" % acao)


def renomear(cid, nome):
    """Nome amigável dado pelo técnico (coluna "nome" do painel, editável)."""
    nome = (nome or "").strip()[:40]
    with LOCK:
        reg = carregar()
        c = reg["clientes"].get(cid)
        if not c:
            raise KeyError("cliente desconhecido: %s" % cid)
        c["nome"] = nome or c.get("maquina") or "cliente"
        salvar(reg)
        return "nome: %s" % c["nome"]


def remover_agente(cid):
    """Desinstalação pelo agente (id é o segredo do cliente)."""
    with LOCK:
        reg = carregar()
        if cid not in reg["clientes"]:
            raise KeyError("cliente desconhecido")
        revogar(cid, reg)


def revogar(cid, reg):
    c = reg["clientes"].pop(cid)
    salvar(reg)
    with open(AK_TUNEL) as f:
        linhas = [l for l in f if "cliente:%s:tunel" % cid not in l]
    with open(AK_TUNEL, "w") as f:
        f.writelines(linhas)
    subprocess.run(["rm", "-rf", os.path.join(DIR_CLIENTES, cid)], check=False)
    print("cliente removido: %s" % cid, flush=True)
    return c


# ---------------- espelho de binários + verificação de versões ----------------

API_RELEASES = {
    "cloudflared": "https://api.github.com/repos/cloudflare/cloudflared/releases/latest",
    "openssh": "https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases?per_page=1",
}


def _ler_versoes():
    """Versões dos binários espelhados em static/ (gravadas por atualizar-espelho.sh)."""
    try:
        with open(ARQ_VERSOES) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def checar_atualizacoes():
    """Compara o espelho com as últimas releases no GitHub; alimenta o banner do painel."""
    CHECAGEM["quando"] = time.time()
    CHECAGEM["erro"] = ""
    espelho = _ler_versoes()
    for nome, api in API_RELEASES.items():
        try:
            req = urllib.request.Request(api, headers={"User-Agent": "suporte-remoto"})
            with urllib.request.urlopen(req, timeout=15) as r:
                rel = json.loads(r.read().decode())
            tag = (rel[0] if isinstance(rel, list) else rel).get("tag_name") or ""
        except Exception as exc:      # sem internet: próxima checagem tenta de novo
            CHECAGEM["erro"] = "%s: %s" % (nome, exc)
            continue
        if tag and tag != espelho.get(nome):
            ATUALIZACOES[nome] = {"espelho": espelho.get(nome) or "?", "atual": tag}
        else:
            ATUALIZACOES.pop(nome, None)


def _thread_atualizacoes():
    while True:
        try:
            checar_atualizacoes()
        except Exception:
            pass
        time.sleep(6 * 3600)


def _rabo_atualizar():
    """Últimas linhas do log da atualização em curso (banner do painel)."""
    try:
        with open(ARQ_ATUALIZAR_LOG, errors="replace") as f:
            return [l for l in f.read().splitlines() if l.strip()][-6:]
    except OSError:
        return []


def _atualizar_espelho():
    """Roda atualizar-espelho.sh pelo botão do painel; log vai para o banner."""
    with open(ARQ_ATUALIZAR_LOG, "w") as log:
        try:
            # grupo próprio de processos: no timeout o killPG mata o curl
            # junto (um curl órfão disputaria os .tmp com a rodada seguinte)
            p = subprocess.Popen(["bash", os.path.join(BASE, "atualizar-espelho.sh")],
                                 stdout=log, stderr=subprocess.STDOUT,
                                 cwd=BASE, start_new_session=True)
            try:
                ATUALIZAR["ok"] = p.wait(timeout=1800) == 0
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    p.kill()
                p.wait()
                log.write("== 30min e não terminou — processo morto ==\n")
                ATUALIZAR["ok"] = False
        except Exception as exc:      # bash sumiu, disco cheio...
            log.write("disparar o script falhou: %s\n" % exc)
            ATUALIZAR["ok"] = False
    ATUALIZAR["fim"] = time.time()
    ATUALIZAR["rodando"] = False
    checar_atualizacoes()             # renova (ou limpa) o aviso com o espelho novo


def dados_painel():
    reg = carregar()
    agora_ = datetime.now()
    out = []
    for cid, c in sorted(reg["clientes"].items()):
        try:
            delta = (agora_ - datetime.fromisoformat(c["ultimo_contato"])).total_seconds()
        except Exception:
            delta = 1e9
        out.append({
            "id": cid, "nome": c["nome"], "maquina": c["maquina"], "so": c["so"],
            "porta": c["porta"], "conectar": bool(c.get("conectar")),
            "remover": bool(c.get("remover")),
            "online": delta < 60, "tunel": tunel_aberto(c["porta"]),
            "ultimo_contato": c["ultimo_contato"],
        })
    # online no topo; dentro de cada grupo, ordem alfabética pelo nome
    # (ordem serve ao painel web E à extensão do VSCode — ambas listam isso).
    # NÃO ordenar por último contato: ele muda a cada poll e os cards dançam.
    out.sort(key=lambda c: (not c["online"], (c["nome"] or "").lower(), c["id"]))
    return {"clientes": out, "versoes": {
        "espelho": _ler_versoes(), "atualizacoes": ATUALIZACOES,
        "quando": CHECAGEM["quando"], "erro": CHECAGEM["erro"],
        # estado do botão "atualizar agora": idade calculada AQUI porque o
        # relógio do celular que abre o painel não é o do servidor
        "atualizando": dict(ATUALIZAR,
                            idade=(time.time() - ATUALIZAR["fim"]
                                   if ATUALIZAR["fim"] else None),
                            log=_rabo_atualizar()),
    }}


def tunel_aberto(porta):
    try:
        s = socket.create_connection(("127.0.0.1", porta), timeout=0.5)
        s.close()
        return True
    except OSError:
        return False


# ---------------- terminal web (xterm) ----------------

def abrir_terminal(cid, claude=False, sess=None, retomar=False):
    """Abre um PTY: atender.sh <cid> (shell do cliente no navegador) ou, em
    modo claude, o Claude Code do próprio servidor — que alcança o cliente
    pelo túnel reverso via skill /atender, como se morasse na máquina dele.
    Com sess (uuid do sessionStorage da página): primeira abertura fixa o id
    da conversa (--session-id) e o reload retoma (--resume) — a conversa
    sobrevive ao F5 porque o CLI persiste o histórico em disco."""
    reg = carregar()
    if cid not in reg["clientes"]:
        raise KeyError("cliente desconhecido: %s" % cid)
    if len(TERMINAIS) + len(CLAUDE_SESSOES) >= TERMINAL_MAX:
        raise ValueError("já há %d terminais abertos — feche algum" % TERMINAL_MAX)
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.environ["TERM"] = "xterm-256color"
            if claude:
                # roda no diretório do projeto: herda skills e CLAUDE.md,
                # que ensinam a operar o cliente (o túnel é reverso — o
                # Claude nunca precisa estar instalado no PC do cliente).
                # Nasce EM modo atendimento: cliente no system prompt, o
                # técnico chega digitando só o problema
                c = reg["clientes"][cid]
                args = ["claude"]
                if sess and all(ch in "0123456789abcdefABCDEF-" for ch in sess):
                    # uuid válido: fixa ou retoma a conversa (validação à mão:
                    # sess vem da URL e vira argv — nada de enfeite).
                    # resume de conversa nunca persistida (processo morreu antes
                    # da 1ª gravação) falha na hora e a página ficava presa no
                    # "encerrada" — cai pra session-id: mesma uuid, conversa nova
                    if retomar:
                        arq = os.path.expanduser(
                            "~/.claude/projects/-root-CODE-suporte-remoto/%s.jsonl" % sess)
                        args += ["--resume", sess] if os.path.exists(arq) \
                            else ["--session-id", sess]
                    else:
                        args += ["--session-id", sess]
                ctx = ("Modo ATENDIMENTO. Cliente: %s (%s, %s, usuario %s), tunel "
                       "reverso na porta %d do localhost. Opere a maquina pelo skill "
                       "'atender' deste projeto (probe do tunel antes de tudo; comandos "
                       "por atender.sh -c). REGRA DE OURO: todo comando de maquina (disco, "
                       "processo, rede, arquivo, servico) roda NO CLIENTE via "
                       "'bash servidor/atender.sh %s -c ...' — NUNCA no servidor local "
                       "onde voce roda; shell local so para os helpers do skill atender "
                       "(probe da porta, /painel/acao, logs /var/log/svc). ABRIR tunel "
                       "so com autorizacao do tecnico; FECHAR tunel e sempre do "
                       "tecnico, no painel — nunca execute 'encerrar' voce mesmo. "
                       "Operacao destrutiva ou irreversivel (remover, parar servico, "
                       "reiniciar): confirme com o tecnico no chat ANTES. Nao faca "
                       "nada ate o tecnico pedir; responda curto em portugues."
                       % (cid, c.get("nome") or cid, c.get("so") or "?",
                          c.get("usuario") or "?", c["porta"], cid))
                os.chdir(os.path.join(BASE, ".."))
                os.execvp("claude", args + ["--append-system-prompt", ctx])
            os.execvp("bash", ["bash", os.path.join(BASE, "atender.sh"), cid])
        except BaseException:
            pass
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    return pid, fd


def _matar_terminal(t):
    try:
        os.close(t["fd"])
    except OSError:
        pass
    try:
        os.kill(t["pid"], signal.SIGHUP)
    except ProcessLookupError:
        pass


def _claude_reader(cid, t):
    """Único dono do fd da sessão claude: lê o PTY, alimenta o scrollback e
    replica a cada inscrito. Processo sair -> EOF (None) a todos e limpeza."""
    while True:
        try:
            dados = os.read(t["fd"], 65536)
        except OSError:
            dados = b""
        if not dados:
            break
        with t["lock"]:
            t["buffer"] += dados
            if len(t["buffer"]) > CLAUDE_BUF_MAX:
                del t["buffer"][:len(t["buffer"]) - CLAUDE_BUF_MAX]
            t["ultima"] = time.time()
            for q in list(t["subs"]):
                q.put(bytes(dados))
    with t["lock"]:
        for q in list(t["subs"]):
            q.put(None)
        t["subs"] = set()
    time.sleep(1)          # dá tempo das streams drenarem o EOF
    if CLAUDE_SESSOES.get(cid) is t:
        CLAUDE_SESSOES.pop(cid, None)
    try:
        os.close(t["fd"])
    except OSError:
        pass
    print("sessão claude saiu (cid=%s)" % cid, flush=True)


def _claude_pegar(cid, sess=None, retomar=False):
    """Sessão claude viva do cliente — cria se não houver. Um processo por
    cliente: segunda aba anexa na mesma, não nasce outra."""
    t = CLAUDE_SESSOES.get(cid)
    if t:
        return t, False
    if len(TERMINAIS) + len(CLAUDE_SESSOES) >= TERMINAL_MAX:
        raise ValueError("já há %d terminais abertos — feche algum" % TERMINAL_MAX)
    with _CLAUDE_CRIAR_LOCK:
        t = CLAUDE_SESSOES.get(cid)   # outra thread pode ter criado no meio
        if t:
            return t, False
        pid, fd = abrir_terminal(cid, True, sess, retomar)
        t = {"pid": pid, "fd": fd, "cid": cid, "claude": True, "csess": sess,
             "buffer": bytearray(), "subs": set(), "lock": threading.Lock(),
             "ultima": time.time()}
        CLAUDE_SESSOES[cid] = t
        threading.Thread(target=_claude_reader, args=(cid, t), daemon=True).start()
    return t, True


def _janitor_terminais():
    while True:
        time.sleep(60)
        alvo = dict(TERMINAIS)
        alvo.update(CLAUDE_SESSOES)
        for sid, t in list(alvo.items()):
            # claude aguenta 2h parado: o processo atravessa F5 — colher cedo
            # demais seria interromper atendimento que só está esperando o técnico
            limite = 2 * 60 * 60 if t.get("claude") else TERMINAL_IDLE_S
            if time.time() - t["ultima"] > limite:
                print("terminal fechado por inatividade (cid=%s)" % t["cid"], flush=True)
                TERMINAIS.pop(sid, None)
                if CLAUDE_SESSOES.get(t["cid"]) is t:
                    CLAUDE_SESSOES.pop(t["cid"], None)
                _matar_terminal(t)
        for cid in list(TELAS):
            t = TELAS[cid]
            # 45s sem viewer = rotina; hard-cap de 5 min derruba ate com
            # ativos>0 — handler travado (que segura atos e responde 409 pra
            # todo mundo) nao pode viciar a tela deste cliente
            if (t["ativos"] <= 0 and time.time() - t["ultima"] > _TELA_IDLE_S) \
                    or time.time() - t["ultima"] > 300:
                TELAS.pop(cid, None)
                print("tela fechada por inatividade (cid=%s)" % cid, flush=True)
                _tela_parar(cid)


# ---------------- tela do cliente (MJPEG + controle) ----------------

def _tela_porta_local(cid):
    return carregar()["clientes"][cid]["porta"] + 20000


_SUB_RESETA_SIGCHLD = (
    "import signal, subprocess, sys; "
    "signal.signal(signal.SIGCHLD, signal.SIG_DFL); "
    "sys.exit(subprocess.call(sys.argv[1:]))")


def _sub_tela(argv, timeout):
    """Roda tela.sh via um python intermediario que devolve SIGCHLD ao
    default. O boot do web.py seta SIGCHLD=SIG_IGN (anti-zombie dos pty
    dos terminais) e essa disposicao se propaga por fork+exec: o bash do
    tela.sh herdava SIGCHLD ignorado, nao conseguia esperar os proprios
    filhos e morria no meio do scp com saida vazia — e o wait do Python
    com SIG_IGN nao le o rc real (fabrica 0), entao o retorno deste
    wrapper tambem e sempre rc=0: sucesso se le pela SAIDA ("tela no
    ar"), nunca pelo rc. resetar via signal.signal direto aqui nao da:
    handler roda em thread de request e signal so funciona na main
    thread — dai o processo extra com main thread propria."""
    return subprocess.run([sys.executable, "-c", _SUB_RESETA_SIGCHLD] + list(argv),
                          capture_output=True, text=True, timeout=timeout)


def _tela_subir(cid):
    """Sobe o tela.ps1 no cliente + o ssh -L (tela.sh subir)."""
    t0 = time.time()
    try:
        r = _sub_tela([os.path.join(BASE, "tela.sh"), cid, "subir"], 90)
    except subprocess.TimeoutExpired:
        raise RuntimeError("tela.sh subir não respondeu (90s)")
    if "tela no ar" not in (r.stdout or ""):
        raise RuntimeError((r.stderr or r.stdout or "sem saída").strip())
    print("tela: subir ok (cid=%s) em %.1fs: %s" % (
        cid, time.time() - t0, (r.stdout or "").strip()), flush=True)


def _tela_parar(cid):
    try:
        _sub_tela([os.path.join(BASE, "tela.sh"), cid, "parar"], 45)
    except Exception as exc:
        print("tela: parar falhou (cid=%s): %s" % (cid, exc), flush=True)


def _tela_http(cid, pedido, corpo=b""):
    """POST cru no listener do cliente, pelo encaminhamento do tela.sh.
    O Host header tem que ser localhost:28090: o HttpListener do .ps1 roda
    sem urlacl de admin e casa o prefixo por host, não por IP."""
    cab = ("POST %s HTTP/1.0\r\nHost: localhost:28090\r\n"
           "Content-Type: application/json\r\nContent-Length: %d\r\n"
           "Connection: close\r\n\r\n" % (pedido, len(corpo)))
    with socket.create_connection(("127.0.0.1", _tela_porta_local(cid)), timeout=6) as s:
        s.sendall(cab.encode() + corpo)
        s.settimeout(6)
        try:
            return s.recv(256)
        except OSError:
            return b""


# ---------------- instaladores ----------------

def bloco_curl_b64(destino):
    """Linhas `> file echo <chunk>` que materializam o curl.exe + bundle CA
    de dentro do .bat (base64 decodificado pelo certutil do cliente). É o
    plano A da máquina sem curl: nada sai da rede antes do passo 2. Sem os
    binários em static/ (clone novo sem espelho), devolve [] — o .bat cai
    direto no plano B (download via certutil). `destino` é a var batch do
    diretório (%CBIN% no agente, %WORK% na sessão)."""
    linhas = []
    for nome in ("curl.exe", "curl-ca-bundle.crt"):
        try:
            with open(os.path.join(BASE, "static", nome), "rb") as f:
                b64 = base64.b64encode(f.read()).decode()
        except OSError:
            return []
        arq_b64 = "%s\\%s.b64" % (destino, nome)
        for i in range(0, len(b64), 4000):        # linha cmd tem limite de 8191
            linhas.append('%s "%s" echo %s' % (">" if i == 0 else ">>", arq_b64, b64[i:i + 4000]))
        linhas.append('certutil -decode "%s" "%s\\%s" >nul' % (arq_b64, destino, nome))
        linhas.append('del "%s" >nul 2>&1' % arq_b64)
    return linhas


def cmds_cliente_b64(nome, bom=False):
    """Base64 de um comando suporte-* de servidor/cliente-cmds para embutir
    no instalador: CRLF sempre (+BOM no .ps1) — cmd e PS 5.1 no cliente
    esperam essa codificação."""
    with open(os.path.join(BASE, "cliente-cmds", nome)) as f:
        t = f.read().replace("\r\n", "\n").replace("\n", "\r\n")
    if bom:
        t = "﻿" + t
    return base64.b64encode(t.encode("utf-8")).decode()


def gerar_instalador_agente(linux):
    """Renderiza o instalador do agente permanente (um arquivo só)."""
    if linux:
        caminho = render("template-agente.sh", {"__URL_BASE__": URL_BASE, "__DOMINIO__": DOMINIO,
                                                "__PORTA_PROXY__": str(PORTA_PROXY)})
        return "suporte-agente.sh", caminho.encode()
    ps1 = render("agente.ps1", {"__URL_BASE__": URL_BASE, "__DOMINIO__": DOMINIO,
                                "__PORTA_PROXY__": str(PORTA_PROXY)})
    des = render("desinstalar.ps1", {"__URL_BASE__": URL_BASE})
    bat = render("template-agente.bat", {"__URL_BASE__": URL_BASE, "__DOMINIO__": DOMINIO,
                                         "__PORTA_PROXY__": str(PORTA_PROXY),
                                         "__AGENTE_PS1_B64__": base64.b64encode(ps1.encode()).decode(),
                                         "__DESINSTALAR_PS1_B64__": base64.b64encode(des.encode()).decode(),
                                         "__MSG_CMD_B64__": cmds_cliente_b64("suporte-mensagem.cmd"),
                                         "__PERG_CMD_B64__": cmds_cliente_b64("suporte-pergunta.cmd"),
                                         "__PERG_PS1_B64__": cmds_cliente_b64("suporte-pergunta-run.ps1", bom=True),
                                         "__CURL_EMBUTIDO__": "\n".join(bloco_curl_b64("%CBIN%"))})
    return "suporte-agente.bat", bat.encode()


def render(nome, subs):
    with open(os.path.join(BASE, "..", "cliente", nome)) as f:
        t = f.read()
    for k, v in subs.items():
        t = t.replace(k, v)
    return t


def gerar_instalador_sessao(linux):
    """Fluxo efêmero original: sessão nova a cada download."""
    subprocess.run([os.path.join(BASE, "limpar-sessoes.sh")], capture_output=True, check=False)
    r = subprocess.run([os.path.join(BASE, "gerar-sessao.sh"), "web"],
                       capture_output=True, text=True, check=True)
    marcador = "Enviar ao cliente (Linux):" if linux else "Enviar ao cliente:"
    for linha in r.stdout.splitlines():
        if linha.startswith(marcador):
            caminho = linha.split(":", 1)[1].strip()
            with open(caminho, "rb") as f:
                return os.path.basename(caminho), f.read()
    raise RuntimeError("gerar-sessao.sh nao devolveu o caminho do instalador")


PAGINA_LOGIN = """<!doctype html><meta charset=utf-8>
<title>Suporte Remoto — entrar</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>
 body{font-family:system-ui,sans-serif;background:#111;color:#eee;display:flex;
      justify-content:center;align-items:center;min-height:100vh;margin:0}
 form{background:#1b1b1b;padding:2rem;border-radius:8px;width:min(320px,90vw)}
 h2{margin:0 0 1rem;font-size:1.1rem}
 input{width:100%;box-sizing:border-box;padding:8px;margin:4px 0 12px;
       border:1px solid #333;border-radius:4px;background:#111;color:#eee}
 button{width:100%;padding:9px;cursor:pointer;border:0;border-radius:4px;
        background:#3c8;border-color:#3c8;color:#041;font-weight:600}
 .erro{color:#c66;margin-bottom:12px;font-size:14px;min-height:1em}
</style>
<form method=post action=/painel/login>
 <h2>Suporte Remoto</h2>
 <div class=erro>__ERRO__</div>
 <label>Senha<input type=password name=senha autofocus
        autocomplete=current-password required></label>
 <button>Entrar</button>
</form>"""

PAGINA_PAINEL = """<!doctype html><meta charset=utf-8>
<title>Suporte Remoto — clientes</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>
 body{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:1.5rem;
      max-width:100vw;overflow-x:hidden}
 table{border-collapse:collapse;width:100%;font-size:14px}
 th,td{padding:6px 10px;border-bottom:1px solid #333;text-align:left}
 tr.on td:first-child{color:#5c5}
 button{margin-right:4px;padding:4px 10px;cursor:pointer}
 .off{color:#777}
 .st{font-size:11px;font-weight:600;padding:2px 8px;border-radius:99px;
     letter-spacing:.5px;white-space:nowrap;margin-left:8px}
 .st.on{background:#2c8;color:#041}
 .st.off{background:#3a3a3a;color:#999}
 .sair{color:#777;font-size:13px;float:right;text-decoration:none}
 .nome{cursor:pointer;text-decoration:underline dotted #777}
 .term{background:#26304a;color:#fff;border:0;border-radius:4px}
 .term:disabled{background:#1d2333;color:#556;cursor:not-allowed}
 .telab{background:#2c6e49;color:#fff;border:0;border-radius:4px}
 .telab:disabled{background:#1d2333;color:#556;cursor:not-allowed}
 .conectar{background:#2c8;color:#041;border:0;border-radius:4px;font-weight:600}
 .conectar:disabled{background:#283528;color:#577;cursor:not-allowed;font-weight:400}
 .encerrar{background:#c33;color:#fff;border:0;border-radius:4px;font-weight:600}
 .remover{background:#8a2626;color:#fff;border:0;border-radius:4px}
 .conectando{background:#444;color:#ddd;border:0;border-radius:4px;cursor:wait}
 .pontos i{font-style:normal;animation:pisca 1.2s infinite;opacity:0}
 .pontos i:nth-child(2){animation-delay:.2s}
 .pontos i:nth-child(3){animation-delay:.4s}
 @keyframes pisca{0%,60%,100%{opacity:0}30%{opacity:1}}
 .aviso{background:#411;border:1px solid #933;border-radius:4px;padding:8px 12px;
        font-size:13px;margin:0 0 10px;overflow-wrap:anywhere}
 .aviso.baixando{background:#132a3f;border-color:#38618c}
 .aviso.ok{background:#142;border-color:#2c8}
 .aviso button{vertical-align:middle;margin-left:6px}
 .aviso code{overflow-wrap:anywhere}
 .vermsg{color:#777;font-size:12px;margin-left:8px}
 /* celular: cada cliente vira um cartão — tabela de 9 colunas não cabe */
 @media(max-width:760px){
  body{margin:.8rem}
  table,tbody,tr,td{display:block;width:100%}
  thead{display:none}
  table{font-size:15px}
  tr{border:1px solid #333;border-radius:8px;padding:10px 12px;margin-bottom:12px;
     background:#161616}
  tr.on{border-left:4px solid #2c8}
  tr.off{border-left:4px solid #555}
  td{border:0;padding:3px 0;display:flex;justify-content:space-between;
     align-items:center;gap:10px;overflow-wrap:anywhere}
  td:first-child{font-size:17px;font-weight:600;margin-bottom:4px;flex-wrap:wrap}
  td:nth-child(2)::before{content:"id"}
  td:nth-child(3)::before{content:"máquina"}
  td:nth-child(4)::before{content:"SO"}
  td:nth-child(5)::before{content:"porta"}
  td:nth-child(6)::before{content:"túnel"}
  td:nth-child(7)::before{content:"último contato"}
  td:nth-child(n+2):nth-child(-n+7)::before{color:#888;font-size:12px}
  /* ações: conectar no topo, terminal embaixo, remover no rodapé */
  td:last-child{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:8px}
  td:last-child button{margin:0;width:100%;padding:12px 6px;font-size:15px}
  td:last-child button:first-child{grid-column:1/-1;order:-2}
  td:last-child button:nth-child(2){grid-column:1/-1;order:2}
  td:last-child button:nth-child(3){order:-1}
  td:last-child button:nth-child(4){order:-1}
 }
</style>
<h2>Clientes instalados <a class=sair href=/painel/sair>sair</a></h2>
<div id=aviso class=aviso style=display:none></div>
<div style=margin-bottom:10px>
 <button class=term onclick=verificar()>procurar atualização</button>
 <span id=vermsg class=vermsg></span>
</div>
<table id=t><thead><tr>
 <th>nome</th><th>id</th><th>máquina</th><th>SO</th><th>porta</th>
 <th>túnel</th><th>último contato</th><th></th>
</tr></thead><tbody></tbody></table>
<script>
const esc=s=>String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
// clique em conectar fica "conectando..." até o probe do túnel confirmar (ou 90s);
// clique em encerrar fica "encerrando..." até o probe ver a porta fechar (ou 90s)
const pendente={};
const pendenteEnc={};
async function carregar(){
  const r = await fetch('/painel/dados');
  if (!r.ok) { location.href = '/painel'; return; }
  const d = await r.json();
  for(const k in pendente) if(Date.now()-pendente[k]>90000) delete pendente[k];
  for(const k in pendenteEnc) if(Date.now()-pendenteEnc[k]>90000) delete pendenteEnc[k];
  document.querySelector('#t tbody').innerHTML = d.clientes.map(c=>{
   if(c.tunel) delete pendente[c.id]; else delete pendenteEnc[c.id];
   const semTunel = c.online ? 'sem túnel — conecte o cliente primeiro'
                             : 'cliente offline — o agente não reporta ao servidor';
   return `
   <tr class="${c.online?'on':'off'}">
    <td class=nome title="clique para renomear"
        onclick="renomear('${esc(c.id)}','${esc(c.nome)}')">${esc(c.nome)}<span
        class="st ${c.online?'on':'off'}">${c.online?'online':'offline'}</span></td>
    <td>${esc(c.id)}</td><td>${esc(c.maquina)}</td><td>${esc(c.so)}</td><td>${c.porta}</td>
    <td>${c.tunel?'ABERTO':'—'}</td><td>${c.ultimo_contato}</td>
    <td>
      ${c.remover
        ? `<button class=encerrar disabled title="auto-desinstala no próximo contato do agente">pend. remoção</button>`
        : (c.tunel
          ? (pendenteEnc[c.id]
            ? `<button class=conectando disabled title="fechando o túnel — o agente desfaz em até ~25s">encerrando<span class=pontos><i>.</i><i>.</i><i>.</i></span></button>`
            : `<button class=encerrar onclick="acao('${esc(c.id)}','encerrar')">encerrar</button>`)
          : (pendente[c.id]
            ? `<button class=conectando disabled title="abrindo o túnel — o agente responde em até ~35s">conectando<span class=pontos><i>.</i><i>.</i><i>.</i></span></button>`
            : (c.online
              ? `<button class=conectar onclick="acao('${esc(c.id)}','conectar')">conectar</button>`
              : `<button class=conectar disabled title="cliente offline — o agente não reporta ao servidor">conectar</button>`)))}
      <button class=remover
        onclick="acao('${esc(c.id)}','remover')">${c.remover?'forçar':'remover'}</button>
      <button class=term ${(c.tunel&&c.online)
        ? `onclick="location.href='/painel/term?cid=${esc(c.id)}'"`
        : `disabled title="${semTunel}"`}>terminal</button>
      <button class=telab ${(c.tunel&&c.online)
        ? `onclick="location.href='/painel/tela?cid=${esc(c.id)}'"`
        : `disabled title="${semTunel}"`}>tela</button>
    </td>
   </tr>`}).join('') || '<tr><td colspan=8 class=off>nenhum cliente instalado ainda</td></tr>';
  versoes(d);
}
function versoes(d){
  const v=d.versoes||{}, a=v.atualizacoes||{}, upd=v.atualizando||{},
        el=document.getElementById('aviso'), nomes=Object.keys(a);
  el.className='aviso';
  const log=(upd.log||[]).filter(Boolean);
  if(upd.rodando){
    el.classList.add('baixando');
    el.innerHTML='⬇ baixando das fontes e regravando o espelho — '
      +esc(log[log.length-1]||'iniciando...')
      +'<span class=pontos><i>.</i><i>.</i><i>.</i></span>'
      +'<br><small>não feche a página — o banner sai sozinho quando terminar</small>';
    el.style.display='block'; return;
  }
  if(upd.ok===true && upd.idade!=null && upd.idade<60){
    el.classList.add('ok');
    el.innerHTML='✔ espelho atualizado'; el.style.display='block'; return;
  }
  if(!nomes.length){ el.style.display='none'; return; }
  el.innerHTML='⚠ atualização disponível: '+nomes.map(k=>
    esc(k+' '+a[k].espelho+' → '+a[k].atual)).join(' · ')
   +(upd.ok===false?' — <b>última tentativa falhou:</b> '
     +esc(log.slice(-2).join(' | ')):'')
   +' <button class=conectar onclick=atualizarAgora()>'
   +(upd.ok===false?'tentar de novo':'atualizar agora')+'</button>';
  el.style.display='block';
}
async function atualizarAgora(){
  const m=document.getElementById('vermsg'); m.textContent='disparando...';
  try{
    const r=await fetch('/painel/atualizar',{method:'POST'});
    if(!r.ok) throw 0;
    m.textContent=(await r.json()).iniciado
      ?'baixando — o banner mostra o progresso':'já estava rodando';
  }catch(e){ m.textContent='falhou — sessão expirada?'; }
  carregar();
}
async function verificar(){
  const m=document.getElementById('vermsg'); m.textContent='consultando GitHub...';
  try{
    const r=await fetch('/painel/verificar',{method:'POST'});
    if(!r.ok) throw 0;
    const j=await r.json();
    m.textContent=j.erro?('falhou: '+esc(j.erro))
      :(Object.keys(j.atualizacoes).length?'⚠ há atualização (aviso acima)':'tudo atualizado');
  }catch(e){ m.textContent='falhou — sessão expirada?'; }
  carregar();
}
async function acao(id,a){
  if(a==='remover' && !confirm('Remover '+id+'? O agente se desinstala sozinho no próximo contato (offline = fica pendente). Se já está pendente, isto força a revogação imediata.')) return;
  const r=await fetch('/painel/acao',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({id:id,acao:a})});
  if(r.ok && a==='conectar') pendente[id]=Date.now();
  if(r.ok && a==='encerrar') pendenteEnc[id]=Date.now();
  carregar();
}
async function renomear(id,atual){
  const novo = prompt('Nome deste cliente:',atual);
  if(novo===null) return;               // cancelar não apaga o nome
  await fetch('/painel/nome',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({id:id,nome:novo})});
  carregar();
}
setInterval(carregar,5000); carregar();
</script>"""


PAGINA_TERMINAL = """<!doctype html><meta charset=utf-8>
<title>Suporte Remoto — terminal</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<link rel=stylesheet href=/xterm.css>
<style>
 body{margin:0;background:#111;color:#eee;font-family:system-ui,sans-serif}
 #barra{padding:6px 10px;font-size:13px;background:#1b1b1b;border-bottom:1px solid #333;
        display:flex;gap:10px;align-items:center}
 #alt{background:#5a3c8c;border:0;border-radius:4px;padding:3px 10px;cursor:pointer;
      color:#fff;font-weight:600}
 .sair{color:#777;text-decoration:none;margin-left:auto}
 #t{position:fixed;inset:40px 0 0 0}
 /* caixa de mensagem do modo claude (modelo vscode): digitação local num
    input de verdade, linha inteira viaja atômica — sem sincronizar
    letra a letra com o TUI pelo túnel */
 #chatbar{display:none;position:fixed;left:0;right:0;bottom:0;gap:8px;padding:8px 10px;
          background:#1b1b1b;border-top:1px solid #333;align-items:center;z-index:5}
 body.claude #chatbar{display:flex}
 body.claude #t{inset:40px 0 60px 0}
 /* claude: a chatbar é a única entrada — esconde o textarea que o xterm cria
    para capturar teclado (no celular ele aparece como um 2º input) */
 body.claude .xterm-helper-textarea{display:none!important}
 #msg{flex:1;min-width:0;background:#111;border:1px solid #333;color:#eee;padding:10px;
      border-radius:6px;font-size:15px}
 #enviarmsg{background:#2c8;border:0;border-radius:6px;padding:10px 16px;color:#041;
            font-weight:600;cursor:pointer}
 #escbtn{background:#333;color:#ccc;border:0;border-radius:6px;padding:10px 12px;
         cursor:pointer}
</style>
<div id=barra><span id=titulo>terminal</span>
 <button id=alt title="trocar entre shell do cliente e claude"></button>
 <a class=sair href=/painel>voltar ao painel</a></div>
<div id=t></div>
<div id=chatbar><button id=escbtn title="tecla Esc — interrompe o claude">esc</button>
 <input id=msg placeholder="mensagem para o claude — Enter envia" autocomplete=off>
 <button id=enviarmsg>enviar</button></div>
<script src=/xterm.js></script><script src=/xterm-fit.js></script>
<script>
const qs=new URLSearchParams(location.search), cid=qs.get('cid'), s=crypto.randomUUID();
const modoClaude=qs.get('claude')==='1';
if(modoClaude) document.body.classList.add('claude');
// conversa do claude sobrevive ao F5: id no sessionStorage (morre junto com
// a aba). Primeira abertura fixa o id; reload retoma com --resume
let csess='', retomar=0;
if(modoClaude){
  const k='claude-sess-'+cid, prev=sessionStorage.getItem(k);
  csess=prev||crypto.randomUUID();
  sessionStorage.setItem(k,csess);
  retomar=prev?1:0;
}
document.getElementById('titulo').textContent=(modoClaude?'claude — ':'terminal — ')+cid;
// botão de alternância: shell do cliente <--> claude (mesma página, recarrega
// no outro modo — cada modo é um processo próprio no PTY)
const alt=document.getElementById('alt');
alt.textContent=modoClaude?'shell':'claude';
alt.onclick=()=>location.href='/painel/term?cid='+encodeURIComponent(cid)
  +(modoClaude?'':'&claude=1');
const term=new Terminal({cursorBlink:true,fontSize:14,theme:{background:'#111'}});
const fit=new FitAddon.FitAddon(); term.loadAddon(fit);
term.open(document.getElementById('t')); fit.fit();
// digitação: enfileira e envia UM fetch por vez, em ordem — em paralelo os
// POSTs chegavam fora de ordem e o comando ia embaralhado/cortado no PTY
let fila=[], enviando=false;
function bombear(){
  if(enviando||!fila.length) return;
  enviando=true;
  fetch('/painel/term/in?s='+s+'&cid='+encodeURIComponent(cid),{method:'POST',body:fila.shift()})
    .catch(()=>{})
    .finally(()=>{enviando=false;bombear();});
}
term.onData(d=>{fila.push(d);bombear();});
// caixa de mensagem (modo claude): a linha inteira entra na fila, e o Enter
// vai num POST separado logo depois — junto no mesmo corpo ele se perde
function enviarMsg(){
  const inp=document.getElementById('msg'), v=inp.value;
  if(!v) return;
  fila.push(v);
  setTimeout(()=>{fila.push('\\r');bombear();},400);
  inp.value=''; inp.focus();
}
document.getElementById('enviarmsg').addEventListener('click',enviarMsg);
document.getElementById('msg').addEventListener('keydown',e=>{
  if(e.key==='Enter'){e.preventDefault();enviarMsg();}
});
document.getElementById('escbtn').addEventListener('click',()=>{fila.push('\\x1b');bombear();});
term.onResize(({cols,rows})=>fetch('/painel/term/size?s='+s+'&cid='+encodeURIComponent(cid),
  {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({cols,rows})}));
window.addEventListener('resize',()=>fit.fit());
// teclado virtual (Android/iOS): o xterm não ganha foco sozinho — todo toque
// na área do terminal foca e abre o teclado
const focar=()=>term.focus();
document.getElementById('t').addEventListener('click',focar);
document.getElementById('t').addEventListener('touchend',e=>{e.preventDefault();focar();});
// F5/aba fechada: shell morre com a aba; claude FICA VIVO no servidor
// (reatanexável — igual sessão do code-server), o janitor colhe depois
addEventListener('pagehide',()=>{
  if(modoClaude) return;
  try{
    navigator.sendBeacon('/painel/term/fechar?s='+s
      +(qs.get('token')?'&token='+encodeURIComponent(qs.get('token')):''));
  }catch(e){}});
(async()=>{
  let r;
  try{
    const ctl=new AbortController();
    const relogio=setTimeout(()=>ctl.abort(),15000);
    r=await fetch('/painel/term/stream?cid='+encodeURIComponent(cid)+'&s='+s
      +(modoClaude?'&claude=1&sess='+csess+(retomar?'&retomar=1':''):''),{signal:ctl.signal});
    clearTimeout(relogio);
    // anexou numa sessão viva: guarda a conversa REAL dela (pode ter nascido
    // noutra aba) pra retomadas futuras
    if(modoClaude){const cs=r.headers.get('X-Claude-Sess');
      if(cs) sessionStorage.setItem('claude-sess-'+cid,cs);}
  }catch(e){
    term.write('\\r\\n<< stream não conectou ('+e+') — atualize a página (F5) >>');return;
  }
  if(!r.ok){term.write('\\r\\n<< '+(await r.text()).trim()+' >>');return;}
  fit.fit();
  if(modoClaude) document.getElementById('msg').focus(); else focar();
  fetch('/painel/term/size?s='+s+'&cid='+encodeURIComponent(cid),{method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({cols:term.cols,rows:term.rows})});
  __SETUP__
  const rd=r.body.getReader(), dec=new TextDecoder();
  const t0=Date.now();
  try{
    while(true){const {done,value}=await rd.read();if(done)break;
      term.write(dec.decode(value,{stream:true}));}
  }catch(e){}
  // retomada que morre na hora = conversa irretomável: limpa o uuid pra o
  // próximo F5 nascer limpo em vez de insistir no --resume quebrado
  if(modoClaude&&retomar&&Date.now()-t0<5000){
    sessionStorage.removeItem('claude-sess-'+cid);
    term.write('\\r\\n<< conversa não pôde ser retomada — F5 abre uma nova >>');
  } else term.write(modoClaude
    ?'\\r\\n<< sessão claude encerrada — F5 retoma a conversa >>'
    :'\\r\\n<< desconectado — conecte o cliente no painel e atualize (F5) >>');
})();
</script>"""


PAGINA_TELA = """<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>tela — __CID__</title>
<style>
 body{margin:0;background:#0d0f14;color:#eee;font-family:system-ui,sans-serif;
      display:flex;flex-direction:column;height:100vh}
 #barra{display:flex;align-items:center;gap:8px;padding:8px 12px;
        background:#151923;border-bottom:1px solid #222;flex-wrap:wrap}
 #barra .id{font-weight:600;font-size:14px}
 #st{font-size:12px;color:#8f9}
 #st.err{color:#f66}
 button{border:0;border-radius:4px;padding:6px 12px;font-size:13px;cursor:pointer}
 #ctl{background:#26304a;color:#fff}
 #ctl.on{background:#a33;color:#fff;font-weight:600}
 #parar{background:#8a2626;color:#fff}
 #voltar{background:#232a3a;color:#9ab}
 #palco{flex:1;min-height:0;display:flex;align-items:center;justify-content:center;
        position:relative;overflow:hidden}
 #tela{max-width:100%;max-height:100%;user-select:none;-webkit-user-drag:none}
 #tela.controle{cursor:crosshair;outline:2px solid #a33}
 #cursor{position:absolute;pointer-events:none;display:none;color:#f46;
         font-weight:700;font-size:22px;line-height:1;
         transform:translate(-50%,-50%);text-shadow:0 0 4px #000;z-index:2}
 #dica{font-size:11px;color:#667;padding:6px 12px;text-align:center}
</style>
<div id=barra>
 <button id=voltar title="voltar pra lista de PCs">← PCs</button>
 <span class=id>tela — __CID__</span>
 <span id=st>conectando…</span>
 <span style="flex:1"></span>
 <button id=ctl>controlar</button>
 <button id=parar>parar</button>
</div>
<div id=palco><img id=tela alt="tela do cliente"><div id=cursor>+</div></div>
<div id=dica>assistindo — clique em "controlar" para mouse e teclado agirem no
cliente (stream ~2-4 fps; os cliques chegam com um pequeno atraso)</div>
<script>
const cid='__CID__';
const img=document.getElementById('tela'), st=document.getElementById('st'),
      ctl=document.getElementById('ctl'), cursor=document.getElementById('cursor'),
      dica=document.getElementById('dica'), palco=document.getElementById('palco');
let controlando=false;

// fila serial (um fetch por vez — mesmo padrão do terminal) com
// coalescência: um move pendente é substituído pelo mais novo. Evento SEM
// confirmação (504/fetch falho) volta pra fila em vez de se perder — um
// "up" perdido deixava o botao embaixado no cliente e "travava" tudo
const fila=[];
let bombeando=false;
function enviar(ev){
  if(ev.t==='move')
    for(let i=fila.length-1;i>=0;i--) if(fila[i].t==='move'){fila.splice(i,1);break;}
  fila.push(ev);
  bombear();
}
async function bombear(){
  if(bombeando) return;
  bombeando=true;
  while(fila.length){
    const ev=fila.shift();
    let repondo=false;
    try{
      const r=await fetch('/painel/tela/in',{method:'POST',
        headers:{'Content-Type':'application/json'},
        body:JSON.stringify(Object.assign({cid:cid},ev))});
      if(r.status===502){ st.textContent='tela caiu — reconectando…';
                          st.className='err'; img.src=novaConexao(); }
      else if(r.status===504) repondo=true;
    }catch(e){ repondo=true; }
    if(repondo && ev.t!=='move' && (ev.n=(ev.n||0)+1)<3){
      fila.unshift(ev); setTimeout(bombear,500); break;
    }
  }
  bombeando=false;
}

let rede=0,watchdog=0;
function novaConexao(){
  rede=Date.now();
  return '/painel/tela/stream?cid='+encodeURIComponent(cid)+'&r='+rede;
}
img.onload=()=>{ st.textContent='ao vivo'; st.className=''; tentativas=0;
                 clearTimeout(watchdog); };
// erro cedo (subida lenta, viewer em outra aba, listener morto): sem isto
// a pagina ficava PRETA em silencio — agora avisa e reconecta 2x antes de
// desistir; stream que morre depois de vivo → volta pra lista
let tentativas=0;
function semSinal(){
  if(Date.now()-rede>15000){
    st.textContent='stream encerrado — voltando pra lista…'; st.className='err';
    setTimeout(()=>location.href='/painel',2000);
  }else if(tentativas<2){
    tentativas++; st.textContent='conectando… (tentativa '+tentativas+')';
    setTimeout(()=>{ img.src=novaConexao(); arma(); },1500);
  }else{
    st.textContent='tela não respondeu — voltando pra lista…'; st.className='err';
    setTimeout(()=>location.href='/painel',2000);
  }
}
// 200 multipart SEM quadro nenhum: nem onload nem onerror disparam e o <img>
// fica "carregando" eternamente — watchdog reconecta se o 1o quadro nao vier
function arma(){
  clearTimeout(watchdog);
  watchdog=setTimeout(()=>{ if(Date.now()-rede>=13000) semSinal(); },14000);
}
img.onerror=semSinal;
img.src=novaConexao(); arma();

// ---- entrada: coordenadas normalizadas (0..1) casam com o desktop
// virtual do cliente mesmo com a captura reduzida ----
function norm(e){
  const r=img.getBoundingClientRect();
  return {x:Math.min(1,Math.max(0,(e.clientX-r.left)/r.width)),
          y:Math.min(1,Math.max(0,(e.clientY-r.top)/r.height))};
}
function moveCursor(e){
  const p=img.parentElement.getBoundingClientRect(), r=img.getBoundingClientRect();
  cursor.style.left=(r.left-p.left+e.clientX-r.left)+'px';
  cursor.style.top =(r.top -p.top +e.clientY-r.top )+'px';
}
const botao=b=>b===2?2:(b===1?1:0);
let ultMove=0;
// eventos no PALCO (a imagem pode ter bordas ao redor — clique ali era morto)
// e contextmenu no documento: menu do navegador abrindo por cima roubava o
// clique direito
palco.addEventListener('pointermove',e=>{
  if(!controlando) return;
  moveCursor(e);
  if(Date.now()-ultMove<50) return;
  ultMove=Date.now();
  enviar(Object.assign({t:'move'},norm(e)));
});
palco.addEventListener('pointerdown',e=>{
  if(!controlando) return;
  e.preventDefault(); moveCursor(e);
  enviar(Object.assign({t:'down',b:botao(e.button)},norm(e)));
});
palco.addEventListener('pointerup',e=>{
  if(!controlando) return;
  enviar({t:'up',b:botao(e.button)});
});
document.addEventListener('contextmenu',e=>{ if(controlando) e.preventDefault(); });
palco.addEventListener('wheel',e=>{
  if(!controlando) return;
  e.preventDefault();
  enviar({t:'scroll',d:Math.sign(e.deltaY)});
},{passive:false});

// teclado: F5/F12 e ctrl+r ficam no navegador; o resto vai pro cliente.
// caractere vai como unicode (acentos ok); ctrl/alt+letra vira VK no .ps1
const NOME={Enter:1,Backspace:1,Tab:1,Escape:1,Delete:1,Insert:1,Home:1,End:1,
            PageUp:1,PageDown:1,ArrowLeft:1,ArrowUp:1,ArrowRight:1,ArrowDown:1};
document.addEventListener('keydown',e=>{
  if(!controlando) return;
  if(e.key==='F5'||e.key==='F12'||(e.ctrlKey&&e.key.toLowerCase()==='r')) return;
  if(NOME[e.key]||/^F([1-9]|1[0-2])$/.test(e.key)){
    e.preventDefault();
    enviar({t:'key',k:e.key,ctrl:e.ctrlKey,alt:e.altKey,shift:e.shiftKey});
  }else if(e.key.length===1){
    e.preventDefault();
    enviar({t:'key',c:e.key,ctrl:e.ctrlKey,alt:e.altKey});
  }
});

ctl.onclick=()=>{
  if(!controlando){
    if(!confirm('Controlar esta maquina? Cliques e teclas passam a agir no '+
                'PC do cliente. De preferencia avise o usuario antes '+
                '(popup mensagem.sh).')) return;
    controlando=true;
    ctl.textContent='controlando'; ctl.classList.add('on');
    img.classList.add('controle'); cursor.style.display='block';
    dica.textContent='controle ATIVO — mouse e teclado vao para o cliente. '+
                     'Desligue com o mesmo botao.';
  }else{
    controlando=false;
    ctl.textContent='controlar'; ctl.classList.remove('on');
    img.classList.remove('controle'); cursor.style.display='none';
    dica.textContent='assistindo — controle desligado';
  }
};
document.getElementById('voltar').onclick=()=>location.href='/painel';
document.getElementById('parar').onclick=async()=>{
  await fetch('/painel/tela/parar',{method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({cid:cid})});
  st.textContent='encerrado — voltando…'; st.className='err'; img.removeAttribute('src');
  setTimeout(()=>location.href='/painel',700);
};
</script>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            self._get()
        except ValueError as exc:      # payload/parâmetro inválido: erro do cliente
            self._erro(400, str(exc))
        except PermissionError as exc: # sem sessão/token: não é bug do servidor
            self._erro(403, str(exc))
        except Exception as exc:
            self._erro(500, str(exc))

    def do_POST(self):
        try:
            self._post()
        except ValueError as exc:      # payload inválido: culpa do cliente, não bug
            self._erro(400, str(exc))
        except PermissionError as exc: # sem sessão/token: não é bug do servidor
            self._erro(403, str(exc))
        except Exception as exc:
            self._erro(500, str(exc))

    def _get(self):
        url = urlsplit(self.path)
        rota = url.path.rstrip("/")
        qs = parse_qs(url.query)
        if rota in ("", "/baixar"):
            self._download(*self._instalador(url, qs, gerar_instalador_agente))
        elif rota in ("/instalar/sessao", "/baixar/sessao"):
            self._download(*self._instalador(url, qs, gerar_instalador_sessao))
        elif rota == "/agente/estado":
            r = estado((qs.get("id") or [""])[0])
            if r is None:
                self._erro(404, "cliente desconhecido")
            else:
                self._json(r)
        elif rota == "/painel":
            if self._sessao():
                self._html(PAGINA_PAINEL)
            elif hmac.compare_digest((qs.get("token") or [""])[0], carregar()["token_painel"]):
                # bookmark antigo com ?token= valida uma vez e vira sessão de cookie
                self._redirect("/painel", nova_sessao())
            else:
                self._html(PAGINA_LOGIN.replace("__ERRO__", ""))
        elif rota == "/painel/dados":
            if self._sessao() or hmac.compare_digest((qs.get("token") or [""])[0],
                                                     carregar()["token_painel"]):
                self._json(dados_painel())
            else:
                self._erro(403, "sessao expirada — entre de novo")
        elif rota == "/painel/sair":
            sid = self._sessao()
            if sid:
                SESSOES.pop(sid, None)
                _salvar_sessoes()
            self._redirect("/painel", expira=True)
        elif rota in ("/xterm.js", "/xterm.css", "/xterm-fit.js"):
            self._static(rota.lstrip("/"))
        elif rota.startswith("/arquivos/"):
            # binários espelhados aqui (whitelist fechada): os instaladores baixam
            # de nós, não de GitHub/Windows Update — mais rápido e sem dependência
            nome = rota[len("/arquivos/"):]
            if nome in ARQUIVOS_MIRROR:
                self._arquivo(nome)
            else:
                self._erro(404, "arquivo desconhecido")
        elif rota == "/favicon.ico":        # evita 404 no console do navegador
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif rota == "/painel/term":
            if not self._term_auth(qs):
                self._redirect("/painel")
                return
            cid = (qs.get("cid") or [""])[0]
            reg = carregar()
            if cid not in reg["clientes"]:
                self._erro(404, "cliente desconhecido")
                return
            claude = (qs.get("claude") or [""])[0] == "1"
            # PowerShell 5.1 manda acentos na codepage do sistema: força UTF-8 na ida.
            # Só no modo shell — em modo claude o PTY é local e o setup digitaria
            # comandos dentro do TUI
            win = "windows" in (reg["clientes"][cid].get("so") or "").lower()
            setup = ""
            if win and not claude:
                setup = ("setTimeout(()=>fetch('/painel/term/in?s='+s,{method:'POST',"
                         "body:'[Console]::OutputEncoding=[Text.Encoding]::UTF8;"
                         "chcp 65001>$null\\r'}),2500);")
            self._html(PAGINA_TERMINAL.replace("__SETUP__", setup))
        elif rota == "/painel/term/stream":
            if not self._term_auth(qs):
                self._erro(403, "sessao expirada — entre de novo")
                return
            self._stream_terminal((qs.get("cid") or [""])[0], (qs.get("s") or [""])[0],
                                  (qs.get("claude") or [""])[0] == "1",
                                  (qs.get("sess") or [""])[0],
                                  (qs.get("retomar") or [""])[0] == "1")
        elif rota == "/painel/tela":
            if not self._term_auth(qs):
                self._redirect("/painel")
                return
            cid = (qs.get("cid") or [""])[0]
            if cid not in carregar()["clientes"]:
                self._erro(404, "cliente desconhecido")
                return
            self._html(PAGINA_TELA.replace("__CID__", cid))
        elif rota == "/painel/tela/stream":
            if not self._term_auth(qs):
                self._erro(403, "sessao expirada — entre de novo")
                return
            self._stream_tela((qs.get("cid") or [""])[0])
        else:
            self._erro(404, "rota desconhecida")

    def _post(self):
        url = urlsplit(self.path)
        rota = url.path.rstrip("/")
        if rota == "/painel/login":
            n = int(self.headers.get("Content-Length") or 0)
            form = parse_qs(self.rfile.read(n).decode())
            senha = (form.get("senha") or [""])[0]
            if senha_ok(carregar(), senha):
                self._redirect("/painel", nova_sessao())
            else:
                time.sleep(0.5)   # freia tentativa de força bruta
                self._html(PAGINA_LOGIN.replace("__ERRO__", "Usuário ou senha incorretos."), 401)
            return
        # /painel/term/in manda bytes crus (teclas do xterm); o resto é JSON
        corpo = {} if rota == "/painel/term/in" else self._corpo_json()
        if rota == "/agente/registrar":
            c = registrar(corpo)
            self._json({"id": c[0], "porta": c[1], "pubkey_tecnico": c[2]})
        elif rota == "/agente/remover":
            remover_agente(corpo.get("id", ""))
            self._json({"ok": True})
        elif rota == "/painel/acao":
            if self._sessao():
                self._text(acao_autorizada(corpo.get("id", ""), corpo.get("acao", "")))
            else:
                self._text(acao_painel(corpo.get("token", ""), corpo.get("id", ""),
                                       corpo.get("acao", "")))
        elif rota == "/painel/nome":
            if not self._sessao() and not hmac.compare_digest(
                    corpo.get("token", ""), carregar()["token_painel"]):
                raise PermissionError("token invalido")
            self._text(renomear(corpo.get("id", ""), corpo.get("nome", "")))
        elif rota == "/painel/tela/in":
            # evento de mouse/teclado da página da tela: {"cid", "t": ...}
            ev = dict(corpo)
            cid = ev.pop("cid", "")
            if not self._sessao() and not hmac.compare_digest(
                    ev.pop("token", ""), carregar()["token_painel"]):
                self._erro(403, "sem sessão")
                return
            if not cid or cid not in carregar()["clientes"]:
                self._erro(400, "cid ausente ou inválido")
                return
            try:
                r = _tela_http(cid, "/input", json.dumps(ev).encode())
            except OSError as exc:
                self._erro(502, "tela fora do ar: %s" % exc)
                return
            # _tela_http engole timeout de recv devolvendo b"": sem isto a
            # rota dava 204 de evento que o cliente nunca confirmou (o
            # tela.ps1 podia estar congelado num frame) e a pagina perdia
            # o clique — um "up" perdido deixava o botao embaixado la
            if not r or b" 204" not in r.split(b"\r\n")[0]:
                self._erro(504, "cliente não confirmou o evento")
                return
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif rota == "/painel/tela/parar":
            cid = corpo.get("cid", "")
            if not self._sessao() and not hmac.compare_digest(
                    corpo.get("token", ""), carregar()["token_painel"]):
                self._erro(403, "sem sessão")
                return
            if not cid:
                self._erro(400, "cid ausente")
                return
            threading.Thread(target=_tela_parar, args=(cid,), daemon=True).start()
            self._json({"ok": True})
        elif rota == "/painel/verificar":
            # botão "procurar atualização" do painel: consulta o GitHub na hora
            # (a checagem automática roda a cada 6h desde o boot)
            if not self._sessao():
                raise PermissionError("sem sessão")
            checar_atualizacoes()
            self._json({"atualizacoes": ATUALIZACOES, "erro": CHECAGEM["erro"]})
        elif rota == "/painel/atualizar":
            # botão "atualizar agora" do aviso: baixa das fontes e regrava o
            # espelho em background — o banner acompanha pelo /painel/dados
            if not self._sessao():
                raise PermissionError("sem sessão")
            with _ATUALIZAR_LOCK:
                ja = ATUALIZAR["rodando"]
                if not ja:
                    ATUALIZAR.update(rodando=True, ok=None, fim=0.0)
            if not ja:
                threading.Thread(target=_atualizar_espelho, daemon=True).start()
            self._json({"iniciado": not ja})
        else:
            qs = parse_qs(urlsplit(self.path).query)
            if rota == "/painel/term/in":
                if not self._term_auth(qs):
                    raise PermissionError("sem sessão")
                self._term_io(qs, self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            elif rota == "/painel/term/size":
                if not self._term_auth(qs):
                    raise PermissionError("sem sessão")
                self._term_tamanho(qs, corpo)
            elif rota == "/painel/term/fechar":
                if not self._term_auth(qs):
                    raise PermissionError("sem sessão")
                self._term_fechar(qs)
            else:
                self._erro(404, "rota desconhecida")

    def _arquivo(self, nome):
        """Serve um arquivo de servidor/static em stream (rota de whitelist fechada)."""
        caminho = os.path.join(BASE, "static", nome)
        try:
            tamanho = os.stat(caminho).st_size
        except OSError:
            self._erro(404, "arquivo nao encontrado")
            return
        with open(caminho, "rb") as f:
            self.send_response(200)
            self.send_header("Content-Type", ARQUIVOS_MIRROR[nome])
            self.send_header("Content-Length", str(tamanho))
            self.end_headers()
            while True:
                bloco = f.read(65536)
                if not bloco:
                    break
                self.wfile.write(bloco)

    def _stream_tela(self, cid):
        """Relay do MJPEG do cliente: na 1ª conexão sobe o tela.ps1 e o ssh -L
        (tela.sh), depois repassa os bytes do listener pro navegador até a
        aba fechar. Um viewer por cliente (o listener também recusa o 2º)."""
        reg = carregar()
        if cid not in reg["clientes"]:
            self._erro(404, "cliente desconhecido")
            return
        t = TELAS.get(cid)
        if t and t["ativos"] > 0:
            self._erro(409, "tela já aberta em outra aba")
            return
        t = TELAS.setdefault(cid, {"ativos": 0, "ultima": time.time()})
        t["ativos"] += 1
        t["ultima"] = time.time()
        sock = None
        try:
            try:
                r = _tela_http(cid, "/info")      # encaminhamento no ar?
                # resposta vazia/lixo = forward zombie apontando pra listener
                # morto: sem isto o probe "passa" e o relay entrega 200 sem
                # um unico quadro (pagina carregando pra sempre)
                if not r.strip().startswith(b"{"):
                    raise OSError("probe sem resposta real: %r" % r[:60])
            except (OSError, KeyError):
                _tela_subir(cid)                  # primeira vez: sobe tudo
            sock = socket.create_connection(("127.0.0.1", _tela_porta_local(cid)),
                                             timeout=12)
            # HTTP/1.1 obrigatório: com 1.0 o http.sys não tem chunked nem
            # Content-Length e SEGURA o corpo (responde 200 e nenhum quadro
            # — tela preta no navegador; curl sempre falou 1.1, por isso os
            # testes passavam). Em 1.1 vem Transfer-Encoding: chunked e o
            # decodificador adiante repassa o multipart cru.
            sock.sendall(b"GET /mjpeg HTTP/1.1\r\nHost: localhost:28090\r\n"
                         b"Connection: close\r\n\r\n")
            sock.settimeout(20)
            buf = b""
            while b"\r\n\r\n" not in buf:
                pedaco = sock.recv(4096)
                if not pedaco:
                    raise OSError("listener fechou antes dos cabeçalhos")
                buf += pedaco
            cab, resto = buf.split(b"\r\n\r\n", 1)
            linha1 = cab.split(b"\r\n")[0].decode("latin1", "replace")
            if " 200" not in linha1:
                # o corpo do erro vem do tela.ps1 (ex.: "captura falhou: ..."
                # quando nao ha sessao logada) — RuntimeError carrega o motivo
                # ate a pagina como 502 honesto em vez de engolir
                detalhe = resto.strip()[:200].decode("latin1", "replace")
                raise RuntimeError("listener no cliente: %s %s" % (linha1, detalhe))
            ctype = "multipart/x-mixed-replace; boundary=frame"
            for ln in cab.split(b"\r\n")[1:]:
                if ln.lower().startswith(b"content-type:"):
                    ctype = ln.split(b":", 1)[1].decode("latin1").strip()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            # escrita pro navegador com teto: aba engasgada/throttled parava de
            # drenar, o write do relay bloqueava sem timeout, a gente parava de
            # ler do cliente e o listener (single-thread) congelava junto
            self.connection.settimeout(30)
            chunked = b"transfer-encoding: chunked" in cab.lower()
            sobra = resto
            while True:
                if chunked:               # defesa: decodifica antes de repassar
                    while True:
                        i = sobra.find(b"\r\n")
                        if i < 0:
                            break
                        try:
                            n = int(sobra[:i].split(b";")[0].strip(), 16)
                        except ValueError:
                            break
                        if len(sobra) < i + 2 + n + 2:
                            break
                        if n:
                            self.wfile.write(sobra[i + 2:i + 2 + n])
                        sobra = sobra[i + 2 + n + 2:]
                        if n == 0:
                            return
                else:
                    if sobra:
                        self.wfile.write(sobra)
                        sobra = b""
                pedaco = sock.recv(65536)
                if not pedaco:
                    break
                sobra += pedaco
        except BrokenPipeError:
            pass                            # aba fechou — normal
        except OSError as exc:
            print("tela: stream encerrou (cid=%s): %s" % (cid, exc), flush=True)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            # o motivo tem que ir pro log tambem: 502 sem texto no log forcava
            # reproduzir subir na mao pra descobrir o que houve (caso dell)
            print("tela: 502 (cid=%s): %s" % (cid, exc), flush=True)
            self._erro(502, "tela falhou: %s" % exc)
        finally:
            if sock:
                try:
                    sock.close()
                except OSError:
                    pass
            t["ativos"] -= 1
            t["ultima"] = time.time()

    def _instalador(self, url, qs, funcao):
        so = (qs.get("so") or [""])[0].lower()
        ua = self.headers.get("User-Agent", "").lower()
        linux = {"windows": False, "linux": True}.get(so, "windows" not in ua)
        return funcao(linux)

    def _corpo_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def _term_auth(self, qs):
        """Terminal: sessão do painel ou token de API (mesma régua de /painel/dados)."""
        return self._sessao() or hmac.compare_digest((qs.get("token") or [""])[0],
                                                     carregar()["token_painel"])

    def _stream_terminal(self, cid, sid, claude=False, sess=None, retomar=False):
        """Stream da saída do terminal. Shell: PTY atrelado a esta aba (morre
        com ela). Claude: processo VIVO no servidor, chaveado pelo cliente —
        a aba é só uma janela; F5 desanexa, reabrir anexa com o scrollback."""
        print("stream pedido: cid=%s s=%s claude=%s retomar=%s (de %s)" % (cid, sid[:12],
              claude, retomar, self.address_string()), flush=True)
        if not sid:
            raise ValueError("falta o identificador s da sessão de terminal")
        q = None
        if claude:
            t, criada = _claude_pegar(cid, sess, retomar)
            q = queue.Queue()
            with t["lock"]:
                historico = bytes(t["buffer"])   # snapshot + inscrição atômicos
                t["subs"].add(q)
            print("claude %s (cid=%s)" % ("aberto" if criada else "reanexado", cid),
                  flush=True)
        else:
            pid, fd = abrir_terminal(cid, False, None, False)
            t = {"pid": pid, "fd": fd, "cid": cid, "claude": False,
                 "ultima": time.time(), "lock": threading.Lock()}
            TERMINAIS[sid] = t
            print("terminal aberto: %s (de %s)" % (cid, self.address_string()), flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        if claude:
            # uuid da conversa viva — a aba guarda pra retomadas futuras
            self.send_header("X-Claude-Sess", t.get("csess") or "")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            if claude:
                if historico:
                    self.wfile.write(historico)
                    self.wfile.flush()
                while True:
                    try:
                        item = q.get(timeout=15)
                    except queue.Empty:
                        # keepalive: CF corta stream mudo (~100s); ESC esconder
                        # + mostrar cursor = byte na rede, tela idêntica
                        self.wfile.write(b"\x1b[?25l\x1b[?25h")
                        self.wfile.flush()
                        continue
                    if item is None:
                        break
                    self.wfile.write(item)
                    self.wfile.flush()
            else:
                while True:
                    r, _, _ = select.select([t["fd"]], [], [], 15)
                    if not r:
                        self.wfile.write(b"\x1b[?25l\x1b[?25h")
                        self.wfile.flush()
                        continue
                    try:
                        dados = os.read(t["fd"], 65536)
                    except OSError:
                        break
                    if not dados:
                        break
                    t["ultima"] = time.time()
                    self.wfile.write(dados)
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass                                   # navegador fechou a aba
        finally:
            if claude:
                with t["lock"]:
                    t["subs"].discard(q)
            else:
                if TERMINAIS.get(sid) is t:        # não derrubar um terminal novo
                    TERMINAIS.pop(sid, None)
                _matar_terminal(t)
                print("terminal fechado: %s" % cid, flush=True)

    def _term_io(self, qs, dados):
        t = TERMINAIS.get((qs.get("s") or [""])[0])
        if not t:
            # sessão claude vive em registro próprio, chaveado pelo cliente
            t = CLAUDE_SESSOES.get((qs.get("cid") or [""])[0])
        if not t:
            self._erro(404, "terminal inexistente")
            return
        t["ultima"] = time.time()
        if dados:
            # gravação serializada: threads concorrentes escrevendo juntas
            # embaralhavam a digitação no PTY
            with t["lock"]:
                os.write(t["fd"], dados)
        self._json({"ok": True})

    def _term_tamanho(self, qs, corpo):
        t = TERMINAIS.get((qs.get("s") or [""])[0])
        if not t:
            t = CLAUDE_SESSOES.get((qs.get("cid") or [""])[0])
        if not t:
            self._erro(404, "terminal inexistente")
            return
        cols = max(2, min(400, int(corpo.get("cols") or 80)))
        rows = max(2, min(200, int(corpo.get("rows") or 24)))
        fcntl.ioctl(t["fd"], termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self._json({"ok": True})

    def _term_fechar(self, qs):
        t = TERMINAIS.pop((qs.get("s") or [""])[0], None)
        if t:
            _matar_terminal(t)
        self._json({"ok": True})

    def _static(self, nome):
        """Assets fixos do terminal (lista fechada, sem caminho do usuário)."""
        tipos = {"js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8"}
        try:
            with open(os.path.join(BASE, "static", nome), "rb") as f:
                dados = f.read()
        except OSError:
            self._erro(404, "asset não encontrado: %s" % nome)
            return
        self.send_response(200)
        self.send_header("Content-Type", tipos[nome.rsplit(".", 1)[1]])
        self.send_header("Cache-Control", "max-age=86400")
        self.send_header("Content-Length", str(len(dados)))
        self.end_headers()
        self.wfile.write(dados)

    def _sessao(self):
        """Cookie de sessão válido deste pedido, ou None."""
        c = SimpleCookie(self.headers.get("Cookie", ""))
        if "sessao" not in c:
            return None
        sid = c["sessao"].value
        exp = SESSOES.get(sid)
        if exp is None or datetime.now() > exp:
            SESSOES.pop(sid, None)
            return None
        return sid

    def _redirect(self, url, sid=None, expira=False):
        self.send_response(303)
        if sid:
            self.send_header("Set-Cookie",
                             "sessao=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d"
                             % (sid, SESSAO_HS * 3600))
        elif expira:
            self.send_header("Set-Cookie", "sessao=; Path=/; Max-Age=0")
        self.send_header("Location", url)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _download(self, nome, dados):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % nome)
        self.send_header("Content-Length", str(len(dados)))
        self.end_headers()
        self.wfile.write(dados)

    def _json(self, obj):
        dados = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(dados)))
        self.end_headers()
        self.wfile.write(dados)

    def _text(self, msg):
        self._enviar_texto(200, msg)

    def _html(self, pagina, codigo=200):
        self._enviar_texto(codigo, pagina, "text/html; charset=utf-8")

    def _erro(self, codigo, msg):
        self._enviar_texto(codigo, msg + "\n")

    def _enviar_texto(self, codigo, msg, tipo="text/plain; charset=utf-8"):
        dados = msg.encode()
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(dados)))
        self.end_headers()
        self.wfile.write(dados)

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    # terminais são pty.fork: sem ninguém pra waitpid, cada terminal fechado
    # virava zombie até o serviço reiniciar. SIG_IGN no SIGCHLD = kernel
    # ceifa sozinho (web.py nunca espera filhos, então é a forma certa)
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    reg = carregar()
    _carregar_sessoes()
    threading.Thread(target=_janitor_terminais, daemon=True).start()
    threading.Thread(target=_thread_atualizacoes, daemon=True).start()
    print("suporte-remoto web em 127.0.0.1:%d" % PORTA, flush=True)
    print("painel: /painel (senha em clientes.json; espelho: %s)" % _ler_versoes(), flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORTA), Handler).serve_forever()
