"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const main = fs.readFileSync(path.join(__dirname, "../src/main.js"), "utf8");
const renderer = fs.readFileSync(path.join(__dirname, "../src/renderer/app.js"), "utf8");
const html = fs.readFileSync(path.join(__dirname, "../src/renderer/index.html"), "utf8");

test("aguarda webcam confirmada no modo Vídeo", () => {
  assert.match(main, /state\.captureMode === "video"/);
  assert.match(main, /state\.webcam\?\.enabled/);
  assert.match(main, /20_000/);
});

test("FFmpeg preserva cadência e converte faixa JPEG explicitamente", () => {
  assert.match(main, /nobuffer\+discardcorrupt/);
  assert.match(main, /use_wallclock_as_timestamps/);
  assert.match(main, /in_range=full:out_range=limited/);
  assert.match(main, /executableSupportsFilter\(ffmpeg, "zscale"\)/);
  assert.match(main, /"-fps_mode", "passthrough"/);
  assert.doesNotMatch(main, /"-r", "10"/);
});

test("formato escolhido é persistido e confirmado antes do retorno", () => {
  assert.match(html, /FORMATO DO RETORNO/);
  assert.match(html, /Horizontal 16:9/);
  assert.match(html, /Vertical 9:16/);
  assert.match(renderer, /setControl\("webcamFormat", next\)/);
  assert.match(renderer, /webcamFormatChanging/);
  assert.match(main, /state\.webcam\?\.format !== selected/);
  assert.match(main, /expectedWidth/);
  assert.match(main, /expectedHeight/);
});
