"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const renderer = fs.readFileSync(path.join(__dirname, "../src/renderer/app.js"), "utf8");
const pattern = new RegExp(renderer.match(/const IPV4_PATTERN = \/(.+)\/g;/)[1], "g");

test("padrão de IPv4 encontra endereços e ignora versões", () => {
  const text = "connect ETIMEDOUT 192.168.1.50:22 · iOS 15.8.3 · 10.0.0.255 · 999.1.1.1";
  assert.deepEqual(text.match(pattern), ["192.168.1.50", "10.0.0.255"]);
});

test("IPs só chegam à tela pelo componente ofuscado", () => {
  assert.doesNotMatch(renderer, /textContent = `[^`]*entry\.address/);
  assert.doesNotMatch(renderer, /textContent = `[^`]*phoneAddress/);
  assert.match(renderer, /setRedactedText\(\$\("authDevice"\)/);
  assert.match(renderer, /setRedactedText\(\$\("authError"\), error\.message\)/);
  assert.match(renderer, /setRedactedText\(toast, text\)/);
  assert.match(renderer, /const IP_MASK = "•••\.•••\.•••\.•••"/);
});
