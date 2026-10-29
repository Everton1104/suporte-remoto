// Suporte Remoto — painel dos PCs cadastrados, dentro do VSCode.
// Mesma API do painel web (/painel/dados e /painel/acao com token_painel),
// servida localmente pelo web.py; terminal/claude abrem no terminal integrado
// rodando atender.sh / claude no diretório do projeto.
// Duas superfícies, mesmo conteúdo: view na activity bar (sidebar) e o
// comando "Suporte: Clientes", que abre o painel numa aba completa.
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

const vistas = new Set();   // webviews ativas (sidebar + painel em aba)
let tokenCache = null;      // token_painel lido de clientes.json

function baseDir() {
  return vscode.workspace.getConfiguration('suporte').get('baseDir')
    || '/root/CODE/suporte-remoto';
}
function porta() {
  return vscode.workspace.getConfiguration('suporte').get('porta') || 8090;
}

// token sai do próprio registro — nada de segredo embutido na extensão
function token() {
  try {
    const reg = JSON.parse(
      fs.readFileSync(path.join(baseDir(), 'servidor', 'clientes.json'), 'utf8'));
    tokenCache = reg.token_painel;
  } catch (e) { /* usa cache antigo se o arquivo sumir */ }
  return tokenCache;
}

async function dados() {
  const r = await fetch(
    `http://127.0.0.1:${porta()}/painel/dados?token=${encodeURIComponent(token() || '')}`);
  if (!r.ok) throw new Error('dados ' + r.status);
  return r.json();
}

async function acao(id, a) {
  const r = await fetch(`http://127.0.0.1:${porta()}/painel/acao`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: token(), id: id, acao: a })
  });
  if (!r.ok) throw new Error('acao ' + a + ' → ' + r.status);
}

async function renomear(id, novo) {
  const r = await fetch(`http://127.0.0.1:${porta()}/painel/nome`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: token(), id: id, nome: novo })
  });
  if (!r.ok) throw new Error('nome → ' + r.status);
}

function abrirTerminal(id, claude) {
  // id vem da nossa própria lista, mas vira argv: só libera [A-Za-z0-9-]
  if (!/^[A-Za-z0-9-]+$/.test(id)) { vscode.window.showErrorMessage('suporte: id inválido'); return; }
  const base = baseDir();
  const cmd = claude
    ? `cd '${base}' && exec claude`
    : `exec bash '${base}/servidor/atender.sh' '${id}'`;
  const t = vscode.window.createTerminal({
    name: claude ? `claude: ${id}` : `suporte: ${id}`,
    shellPath: 'bash', shellArgs: ['-c', cmd]
  });
  t.show();
}

async function refresh() {
  if (!vistas.size) return;
  let msg;
  try {
    const d = await dados();
    msg = { tipo: 'dados', clientes: d.clientes };
  } catch (e) {
    // web.py fora do ar? próxima rodada do cron tenta de novo
    msg = { tipo: 'dados', clientes: [{
      id: 'erro', nome: 'servidor sem resposta (' + e.message + ')',
      maquina: '-', so: '-', porta: 0, tunel: false, online: false,
      ultimo_contato: '-', remover: false
    }] };
  }
  for (const w of vistas) {
    try { w.postMessage(msg); } catch (e) { /* vista já foi de base */ }
  }
}

// liga uma webview (da sidebar ou do painel em aba) ao mesmo HTML e às
// mesmas ações; devolve função para desligar do conjunto do poll
function montarWebview(wv) {
  wv.html = fs.readFileSync(path.join(__dirname, 'webview.html'), 'utf8');
  vistas.add(wv);
  const troca = wv.onDidReceiveMessage(async m => {
    try {
      if (m.tipo === 'acao') { await acao(m.id, m.acao); refresh(); }
      else if (m.tipo === 'nome') { await renomear(m.id, m.nome); refresh(); }
      else if (m.tipo === 'term') { abrirTerminal(m.id, m.claude); }
    } catch (e) {
      vscode.window.showErrorMessage('suporte: ' + e.message);
    }
  });
  refresh();
  return () => { vistas.delete(wv); troca.dispose(); };
}

function mostrarPainel() {
  const painel = vscode.window.createWebviewPanel(
    'suporte.painel.aba', 'Suporte Remoto', vscode.ViewColumn.Active,
    { enableScripts: true, retainContextWhenHidden: true });
  const desmontar = montarWebview(painel.webview);
  painel.onDidDispose(desmontar);
}

function activate(ctx) {
  ctx.subscriptions.push(
    vscode.commands.registerCommand('suporte.clientes', mostrarPainel));

  // view da activity bar: resolve na primeira abertura e fica viva
  ctx.subscriptions.push(vscode.window.registerWebviewViewProvider(
    'suporte.painel',
    {
      resolveWebviewView(vw) {
        vw.webview.options = { enableScripts: true };
        ctx.subscriptions.push(montarWebview(vw.webview));
      }
    },
    { webviewOptions: { retainContextWhenHidden: true } }
  ));

  const barra = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
  barra.text = '$(remote-explorer) suporte';
  barra.tooltip = 'Abrir o painel de clientes do suporte-remoto';
  barra.command = 'suporte.clientes';
  barra.show();
  ctx.subscriptions.push(barra);

  ctx.subscriptions.push({ dispose: () => vistas.clear() });
  setInterval(refresh, 5000);
}
module.exports = { activate };
