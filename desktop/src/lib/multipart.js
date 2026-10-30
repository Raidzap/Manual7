"use strict";

const MAX_BUFFERED_BYTES = 8 * 1024 * 1024;
// A GOP is at most 2 s at 30 fps on the iPhone; the cap only guards memory.
const MAX_CACHED_PARTS = 90;

function boundaryFromContentType(value) {
  const match = /boundary=("?)([^";]+)\1/i.exec(String(value || ""));
  return match ? match[2] : "m7frame";
}

// Splits a multipart/x-mixed-replace byte stream into whole parts, each one
// "--boundary\r\n<headers>\r\n\r\n<body>\r\n", so a part can be forwarded to a
// subscriber that joins mid-stream without handing it half a frame. JPEG parts
// are all keyframes; H.264 parts carry X-Keyframe.
class MultipartSplitter {
  constructor(boundary) {
    this.delimiter = Buffer.from(`--${boundary}`);
    this.buffer = Buffer.alloc(0);
    this.discarded = 0;
  }

  push(chunk) {
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
    const parts = [];
    for (;;) {
      const start = this.buffer.indexOf(this.delimiter);
      if (start < 0) {
        // Keep a tail that may hold the beginning of the next delimiter.
        const keep = Math.min(this.buffer.length, this.delimiter.length - 1);
        this.discarded += this.buffer.length - keep;
        this.buffer = this.buffer.subarray(this.buffer.length - keep);
        break;
      }
      if (start > 0) {
        this.discarded += start;
        this.buffer = this.buffer.subarray(start);
      }
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) break;
      const headers = this.buffer.subarray(0, headerEnd).toString("latin1");
      const length = /\r\ncontent-length:\s*(\d+)/i.exec(headers);
      const bodyStart = headerEnd + 4;
      let bodyEnd, end;
      if (length) {
        bodyEnd = bodyStart + Number(length[1]);
        end = bodyEnd;
        if (this.buffer.length < end) break;
        if (this.buffer.subarray(end, end + 2).toString("latin1") === "\r\n") end += 2;
        else if (this.buffer.length < end + 2) break;
      } else {
        end = this.buffer.indexOf(this.delimiter, bodyStart);
        if (end < 0) break;
        bodyEnd = Math.max(bodyStart, end - 2);
      }
      const data = Buffer.from(this.buffer.subarray(0, end));
      const keyframe = /\r\nx-keyframe:\s*0\b/i.test(headers) === false;
      // Phone wall clock (s) when the part left the iPhone.
      const timestamp = Number(/\r\nx-timestamp:\s*([\d.]+)/i.exec(headers)?.[1]) || 0;
      parts.push({ data, body: data.subarray(bodyStart, bodyEnd), keyframe, timestamp });
      this.buffer = this.buffer.subarray(end);
    }
    if (this.buffer.length > MAX_BUFFERED_BYTES) {
      this.discarded += this.buffer.length;
      this.buffer = Buffer.alloc(0);
    }
    return parts;
  }
}

// An HTTP response as a fan-out subscriber: "multipart" forwards whole parts
// (the <img> preview, FFmpeg's mpjpeg demuxer), "raw" only the bodies (an
// Annex-B elementary stream for FFmpeg's h264 demuxer).
function httpSink(response, mode = "multipart") {
  return {
    start(contentType) {
      response.writeHead(200, {
        "Content-Type": mode === "raw" ? "application/octet-stream" : contentType,
        "Cache-Control": "no-store",
        "Connection": "close"
      });
    },
    write(part) { return response.write(mode === "raw" ? part.body : part.data); },
    end(status) {
      if (status && !response.headersSent) response.writeHead(status);
      response.end();
    },
    onDrain(callback) { response.once("drain", callback); },
    onClose(callback) { response.on("close", callback); }
  };
}

// One upstream connection to the iPhone shared by every local consumer.
// Subscribers start at a keyframe: the current GOP is replayed to a newcomer,
// so it shows a picture at once instead of waiting up to 2 s. A subscriber
// that cannot keep up skips parts and resumes at the next keyframe, so an
// H.264 decoder never receives a predicted frame whose reference was dropped.
class StreamFanout {
  constructor(openUpstream, { onPart } = {}) {
    this.openUpstream = openUpstream;
    this.onPart = onPart;
    this.subscribers = new Set();
    this.upstream = null;
    this.contentType = "";
    this.splitter = null;
    this.gop = [];
    this.framesReceived = 0;
    this.framesSkipped = 0;
  }

  get subscriberCount() {
    return this.subscribers.size;
  }

  subscribe(sink) {
    const subscriber = { sink, started: false, blocked: false, waitingKeyframe: true };
    this.subscribers.add(subscriber);
    sink.onClose?.(() => this.unsubscribe(subscriber));
    if (this.contentType) this.start(subscriber);
    else if (!this.upstream) this.connect();
    return () => this.unsubscribe(subscriber);
  }

  start(subscriber) {
    subscriber.started = true;
    subscriber.sink.start?.(this.contentType);
    for (const part of this.gop) this.deliver(subscriber, part);
  }

  unsubscribe(subscriber) {
    if (!this.subscribers.delete(subscriber)) return;
    if (!this.subscribers.size) this.reset();
  }

  connect() {
    const request = this.openUpstream((incoming) => {
      if (this.upstream !== request) { incoming.resume(); return; }
      if (incoming.statusCode !== 200) {
        incoming.resume();
        this.finish(incoming.statusCode || 502);
        return;
      }
      this.contentType = incoming.headers["content-type"] || "multipart/x-mixed-replace; boundary=m7frame";
      this.splitter = new MultipartSplitter(boundaryFromContentType(this.contentType));
      for (const subscriber of this.subscribers) this.start(subscriber);
      incoming.on("data", (chunk) => this.broadcast(chunk));
      incoming.on("close", () => { if (this.upstream === request) this.finish(502); });
    });
    this.upstream = request;
    request.on("error", () => { if (this.upstream === request) this.finish(502); });
  }

  deliver(subscriber, part) {
    if (subscriber.waitingKeyframe) {
      if (!part.keyframe) { ++this.framesSkipped; return; }
      subscriber.waitingKeyframe = false;
    }
    if (subscriber.blocked) {
      ++this.framesSkipped;
      subscriber.waitingKeyframe = true;
      return;
    }
    if (subscriber.sink.write(part) === false) {
      subscriber.blocked = true;
      subscriber.sink.onDrain?.(() => { subscriber.blocked = false; });
    }
  }

  broadcast(chunk) {
    for (const part of this.splitter.push(chunk)) {
      ++this.framesReceived;
      this.onPart?.(part);
      if (part.keyframe) this.gop = [part];
      else if (this.gop.length && this.gop.length < MAX_CACHED_PARTS) this.gop.push(part);
      else this.gop = [];
      for (const subscriber of this.subscribers)
        if (subscriber.started) this.deliver(subscriber, part);
    }
  }

  // Ends every subscriber; the next subscribe() opens a fresh upstream.
  finish(status) {
    const subscribers = [...this.subscribers];
    this.subscribers.clear();
    this.reset();
    for (const { sink, started } of subscribers) sink.end?.(started ? 0 : status);
  }

  reset() {
    const request = this.upstream;
    this.upstream = null;
    this.contentType = "";
    this.splitter = null;
    this.gop = [];
    if (request) request.destroy();
  }

  close() {
    this.finish(503);
  }
}

module.exports = { MultipartSplitter, StreamFanout, httpSink, boundaryFromContentType };
