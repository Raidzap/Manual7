"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const { MultipartSplitter, StreamFanout, httpSink, boundaryFromContentType } = require("../src/lib/multipart");

function part(body, { boundary = "m7frame", keyframe } = {}) {
  const flag = keyframe === undefined ? "" : `X-Keyframe: ${keyframe ? 1 : 0}\r\n`;
  return Buffer.from(`--${boundary}\r\nContent-Type: video/h264\r\nContent-Length: ${body.length}\r\n${flag}\r\n${body}\r\n`);
}

class FakeResponse extends EventEmitter {
  constructor(accepts = () => true) {
    super();
    this.accepts = accepts;
    this.status = 0;
    this.headers = {};
    this.headersSent = false;
    this.chunks = [];
    this.ended = false;
  }
  writeHead(status, headers = {}) { this.status = status; this.headers = headers; this.headersSent = true; }
  write(chunk) { this.chunks.push(chunk.toString()); return this.accepts(); }
  end() { this.ended = true; this.emit("close"); }
}

class FakeUpstream extends EventEmitter {
  constructor() { super(); this.destroyed = false; }
  destroy() { this.destroyed = true; }
}

function fanoutWithFakeUpstream() {
  const upstreams = [];
  const fanout = new StreamFanout((onResponse) => {
    const request = new FakeUpstream();
    request.respond = (status = 200) => {
      const incoming = new EventEmitter();
      incoming.statusCode = status;
      incoming.headers = { "content-type": "multipart/x-mixed-replace; boundary=m7frame" };
      incoming.resume = () => {};
      onResponse(incoming);
      return incoming;
    };
    upstreams.push(request);
    return request;
  });
  return { fanout, upstreams };
}

function bodies(response) {
  return response.chunks.map((chunk) => /\r\n\r\n([^\r]*)\r\n$/.exec(chunk)?.[1] ?? chunk);
}

test("lê o boundary do Content-Type", () => {
  assert.equal(boundaryFromContentType("multipart/x-mixed-replace; boundary=m7frame"), "m7frame");
  assert.equal(boundaryFromContentType('multipart/x-mixed-replace; boundary="abc"'), "abc");
  assert.equal(boundaryFromContentType(""), "m7frame");
});

test("separa partes inteiras, corpo e keyframe com chunks arbitrários", () => {
  const stream = Buffer.concat([part("AAAA", { keyframe: true }), part("BB", { keyframe: false }), part("CCCCCC")]);
  for (const size of [1, 3, 7, stream.length]) {
    const splitter = new MultipartSplitter("m7frame");
    const parts = [];
    for (let offset = 0; offset < stream.length; offset += size)
      parts.push(...splitter.push(stream.subarray(offset, offset + size)));
    assert.deepEqual(parts.map((entry) => String(entry.body)), ["AAAA", "BB", "CCCCCC"]);
    assert.deepEqual(parts.map((entry) => entry.keyframe), [true, false, true]);
    assert.equal(String(parts[1].data), String(part("BB", { keyframe: false })));
  }
});

test("corpo com bytes do boundary não corta a parte", () => {
  const splitter = new MultipartSplitter("m7frame");
  const parts = splitter.push(Buffer.concat([part("x--m7frame\r\ny"), part("z")]));
  assert.deepEqual(parts.map((entry) => String(entry.body)), ["x--m7frame\r\ny", "z"]);
});

test("preview e FFmpeg compartilham uma só conexão com o iPhone", () => {
  const { fanout, upstreams } = fanoutWithFakeUpstream();
  const preview = new FakeResponse();
  const ffmpeg = new FakeResponse();
  fanout.subscribe(httpSink(preview));
  fanout.subscribe(httpSink(ffmpeg, "raw"));
  assert.equal(upstreams.length, 1);
  const incoming = upstreams[0].respond();
  assert.equal(preview.status, 200);
  assert.equal(ffmpeg.headers["Content-Type"], "application/octet-stream");
  incoming.emit("data", part("ONE", { keyframe: true }));
  assert.deepEqual(preview.chunks, [String(part("ONE", { keyframe: true }))]);
  assert.deepEqual(ffmpeg.chunks, ["ONE"]);
});

test("assinante H.264 começa no keyframe e recebe o GOP atual na hora", () => {
  const { fanout, upstreams } = fanoutWithFakeUpstream();
  const first = new FakeResponse();
  fanout.subscribe(httpSink(first, "raw"));
  const incoming = upstreams[0].respond();
  incoming.emit("data", part("P0", { keyframe: false }));
  incoming.emit("data", part("K1", { keyframe: true }));
  incoming.emit("data", part("P1", { keyframe: false }));
  assert.deepEqual(first.chunks, ["K1", "P1"]);
  const late = new FakeResponse();
  fanout.subscribe(httpSink(late, "raw"));
  assert.deepEqual(late.chunks, ["K1", "P1"]);
  incoming.emit("data", part("P2", { keyframe: false }));
  assert.deepEqual(late.chunks, ["K1", "P1", "P2"]);
});

test("assinante lento pula até o próximo keyframe depois de drenar", () => {
  const { fanout, upstreams } = fanoutWithFakeUpstream();
  let accepting = false;
  const slow = new FakeResponse(() => accepting);
  fanout.subscribe(httpSink(slow, "raw"));
  const incoming = upstreams[0].respond();
  incoming.emit("data", part("K1", { keyframe: true }));
  incoming.emit("data", part("P1", { keyframe: false }));
  accepting = true;
  slow.emit("drain");
  incoming.emit("data", part("P2", { keyframe: false }));
  incoming.emit("data", part("K2", { keyframe: true }));
  assert.deepEqual(slow.chunks, ["K1", "K2"]);
  assert.equal(fanout.framesSkipped, 2);
});

test("MJPEG sem X-Keyframe trata toda parte como quadro completo", () => {
  const { fanout, upstreams } = fanoutWithFakeUpstream();
  const preview = new FakeResponse();
  fanout.subscribe(httpSink(preview));
  const incoming = upstreams[0].respond();
  incoming.emit("data", part("J1"));
  const late = new FakeResponse();
  fanout.subscribe(httpSink(late));
  incoming.emit("data", part("J2"));
  assert.deepEqual(bodies(preview), ["J1", "J2"]);
  assert.deepEqual(bodies(late), ["J1", "J2"]);
});

test("assinante por callback recebe corpo e flag de keyframe", () => {
  const { fanout, upstreams } = fanoutWithFakeUpstream();
  const received = [];
  let ended = false;
  const unsubscribe = fanout.subscribe({
    write: (entry) => { received.push([String(entry.body), entry.keyframe]); return true; },
    end: () => { ended = true; }
  });
  const incoming = upstreams[0].respond();
  incoming.emit("data", Buffer.concat([part("K", { keyframe: true }), part("P", { keyframe: false })]));
  assert.deepEqual(received, [["K", true], ["P", false]]);
  unsubscribe();
  assert.equal(upstreams[0].destroyed, true);
  assert.equal(ended, false);
});

test("último assinante saindo fecha a conexão com o iPhone", () => {
  const { fanout, upstreams } = fanoutWithFakeUpstream();
  const preview = new FakeResponse();
  fanout.subscribe(httpSink(preview));
  upstreams[0].respond();
  preview.emit("close");
  assert.equal(upstreams[0].destroyed, true);
  fanout.subscribe(httpSink(new FakeResponse()));
  assert.equal(upstreams.length, 2);
});

test("erro do iPhone é repassado e encerra os assinantes", () => {
  const { fanout, upstreams } = fanoutWithFakeUpstream();
  const preview = new FakeResponse();
  fanout.subscribe(httpSink(preview));
  upstreams[0].respond(401);
  assert.equal(preview.status, 401);
  assert.equal(preview.ended, true);
  assert.equal(fanout.subscriberCount, 0);
});

test("lê X-Timestamp e entrega cada parte ao medidor de latência", () => {
  const seen = [];
  const fanout = new StreamFanout((onResponse) => {
    const request = new FakeUpstream();
    setImmediate(() => {
      const incoming = new EventEmitter();
      incoming.statusCode = 200;
      incoming.headers = { "content-type": "multipart/x-mixed-replace; boundary=m7frame" };
      onResponse(incoming);
      incoming.emit("data", Buffer.from(
        "--m7frame\r\nContent-Type: video/h264\r\nContent-Length: 1\r\nX-Keyframe: 1\r\n" +
        "X-Timestamp: 1790000000.250000\r\n\r\nK\r\n"));
    });
    return request;
  }, { onPart: (part) => seen.push(part.timestamp) });
  fanout.subscribe(httpSink(new FakeResponse()));
  return new Promise((resolve) => setImmediate(() => {
    assert.deepEqual(seen, [1790000000.25]);
    resolve();
  }));
});
