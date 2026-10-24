// Clicks a "Test" button of a switched-off check against the real CGI, served
// over HTTP. Usage: node preview.js page.html perl wrap.pl
const http = require('http');
const fs = require('fs');
const { spawnSync } = require('child_process');
const { chromium } = require('playwright');
const [file, perl, wrap] = process.argv.slice(2);

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') { res.setHeader('Content-Type', 'text/html; charset=utf-8'); return res.end(fs.readFileSync(file)); }
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    const env = Object.assign({}, process.env, { REQUEST_METHOD: 'POST', CONTENT_LENGTH: String(Buffer.byteLength(body)), REMOTE_USER: 'root', HTTP_ACCEPT_LANGUAGE: 'nl' });
    const r = spawnSync(perl, [wrap], { input: body, env });
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    // A slow check, so the busy state can be seen.
    setTimeout(() => res.end(String(r.stdout).replace(/^[\s\S]*?\r?\n\r?\n/, '')), 800);
  });
});

(async () => {
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  p.on('pageerror', e => errors.push(e.message));
  await p.goto('http://127.0.0.1:' + server.address().port + '/index.cgi#checks');
  await p.evaluate(() => { window.marker = 1; });
  const out = {};
  const btn = '#bsw-pv-type-rbl button[data-preview]';
  await p.click(btn);
  out.busy = await p.$eval(btn, el => el.disabled && el.classList.contains('bsw-busy') && el.textContent.trim());
  await p.waitForSelector('#bsw-pv-type-rbl .bsw-members li', { timeout: 20000 });
  out.result = await p.$eval('#bsw-pv-type-rbl .bsw-members li', el => el.textContent);
  out.no_reload = await p.evaluate(() => window.marker === 1);
  out.tab = await p.$eval('.bsw-panel.bsw-active', el => el.getAttribute('data-panel'));
  out.button_ready = await p.$eval(btn, el => !el.disabled);
  out.errors = errors;
  console.log(JSON.stringify(out));
  await b.close();
  server.close();
})().catch(e => { console.log(JSON.stringify({ fatal: String(e) })); process.exit(0); });
