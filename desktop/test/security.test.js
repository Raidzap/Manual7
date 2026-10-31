"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const main = fs.readFileSync(path.join(root, "src/main.js"), "utf8");
const preload = fs.readFileSync(path.join(root, "src/preload.js"), "utf8");
const html = fs.readFileSync(path.join(root, "src/renderer/index.html"), "utf8");

test("renderer permanece isolado do Node", () => {
  assert.match(main, /contextIsolation:\s*true/);
  assert.match(main, /nodeIntegration:\s*false/);
  assert.match(main, /sandbox:\s*true/);
  assert.match(html, /Content-Security-Policy/);
  assert.match(html, /connect-src 'none'/);
});

test("PIN não é exposto pela bridge do renderer", () => {
  assert.doesNotMatch(preload, /\bpin\b/i);
  assert.match(main, /delete publicPairing\.pin/);
});

test("saída V4L2 aceita somente dispositivo virtual reconhecido", () => {
  assert.match(main, /\^\\\/dev\\\/video\\d\+\$/);
  assert.match(main, /v4l2loopback/);
  assert.match(main, /spawn\(ffmpeg/);
});

test("chave SSH alterada pede confirmação na interface, sem enviar a senha", () => {
  const app = fs.readFileSync(path.join(root, "src/renderer/app.js"), "utf8");
  assert.doesNotMatch(main, /Remova a chave conhecida/);
  assert.match(main, /keyChanged: true, fingerprint, previousFingerprint: trusted/);
  // The host verifier rejects any key but the trusted one, so ssh2 stops
  // before user authentication.
  assert.match(main, /hostVerifier: \(key\) => \{[\s\S]*?crypto\.timingSafeEqual\(actual, expected\)/);
  assert.match(app, /result\.keyChanged/);
  assert.match(app, /Substituir chave e conectar/);
  assert.match(html, /id="previousFingerprint"/);
});
