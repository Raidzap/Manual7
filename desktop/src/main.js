"use strict";

const { app, BrowserWindow, dialog, ipcMain, shell } = require("electron");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");
const fs = require("node:fs/promises");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const QRCode = require("qrcode");
const { Client } = require("ssh2");
const {
  API_BRIDGE_PORT,
  WEBCAM_BRIDGE_PORT,
  MAX_PAIRING_BODY,
  normalizeAddress,
  isPrivateIPv4,
  validatePairingPayload,
  timingSafeToken
} = require("./lib/protocol");
const { StreamFanout, httpSink } = require("./lib/multipart");
const { openUsbConnection } = require("./lib/usbmux");

const PAIRING_PATH = "/v1/pair";
const PAIRING_TIMEOUT_MS = 120_000;

let mainWindow = null;

function emit(type, detail = {}) {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send("m7:event", { type, ...detail });
}

function listen(server, host = "127.0.0.1", port = 0) {
  return new Promise((resolve, reject) => {
    const fail = (error) => reject(error);
    server.once("error", fail);
    server.listen(port, host, () => {
      server.off("error", fail);
      resolve(server.address());
    });
  });
}

function closeServer(server) {
  return new Promise((resolve) => {
    if (!server || !server.listening) return resolve();
    server.close(() => resolve());
  });
}

function jsonReply(response, status, value) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": body.length,
    "Cache-Control": "no-store",
    "Connection": "close"
  });
  response.end(body);
}

function availableInterfaces() {
  const result = [];
  for (const [name, entries] of Object.entries(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.family !== "IPv4" || entry.internal || !isPrivateIPv4(entry.address)) continue;
      result.push({ name, address: entry.address });
    }
  }
  return result;
}

async function executableOnPath(name) {
  for (const directory of String(process.env.PATH || "").split(path.delimiter)) {
    if (!directory) continue;
    const candidate = path.join(directory, name);
    try {
      await fs.access(candidate, fs.constants.X_OK);
      return candidate;
    } catch { /* continue */ }
  }
  return "";
}

function executableSupportsFilter(executable, filter) {
  if (!executable) return Promise.resolve(false);
  return new Promise((resolve) => {
    const child = spawn(executable, ["-hide_banner", "-filters"], {
      stdio: ["ignore", "pipe", "ignore"], windowsHide: true
    });
    let output = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), 3000);
    child.stdout.on("data", (chunk) => { output = `${output}${chunk}`.slice(-1024 * 1024); });
    child.once("error", () => { clearTimeout(timer); resolve(false); });
    child.once("close", (code) => {
      clearTimeout(timer);
      resolve(code === 0 && new RegExp(`\\b${filter}\\b`).test(output));
    });
  });
}

async function virtualCameraDevices() {
  let names = [];
  try { names = await fs.readdir("/dev"); } catch { return []; }
  const devices = [];
  for (const name of names.filter((value) => /^video\d+$/.test(value)).sort((a, b) =>
    Number(a.slice(5)) - Number(b.slice(5)))) {
    let label = name;
    try { label = (await fs.readFile(`/sys/class/video4linux/${name}/name`, "utf8")).trim() || name; }
    catch { /* device without sysfs label */ }
    let moduleName = "";
    try { moduleName = path.basename(await fs.realpath(`/sys/class/video4linux/${name}/device/driver/module`)); }
    catch { /* driver module is not visible */ }
    if (moduleName === "v4l2loopback" || /loopback|virtual|dummy|manual7/i.test(label))
      devices.push({ path: `/dev/${name}`, label });
  }
  return devices;
}

class Manual7Session {
  constructor() {
    this.pairingServer = null;
    this.pairingTimer = null;
    this.pairingToken = "";
    this.pairing = null;
    this.phoneAddress = "";
    this.ssh = null;
    this.apiForward = null;
    this.webcamForward = null;
    this.apiPort = 0;
    this.webcamPort = 0;
    this.previewServer = null;
    this.previewPort = 0;
    this.previewToken = "";
    this.previewFanout = null;
    this.previewCodec = "mjpeg";
    this.rendererFrames = null;
    this.transport = "";
    this.resetLatency();
    this.pendingFingerprint = "";
    this.connectedFingerprint = "";
    this.ffmpeg = null;
    this.ffmpegStopping = false;
  }

  get knownHostsPath() {
    return path.join(app.getPath("userData"), "known-hosts.json");
  }

  async knownFingerprint(host, port) {
    try {
      const value = JSON.parse(await fs.readFile(this.knownHostsPath, "utf8"));
      return typeof value[`${host}:${port}`] === "string" ? value[`${host}:${port}`] : "";
    } catch {
      return "";
    }
  }

  async rememberFingerprint(host, port, fingerprint) {
    let value = {};
    try { value = JSON.parse(await fs.readFile(this.knownHostsPath, "utf8")); } catch { /* first host */ }
    value[`${host}:${port}`] = fingerprint;
    await fs.mkdir(path.dirname(this.knownHostsPath), { recursive: true });
    await fs.writeFile(this.knownHostsPath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  }

  async cancelPairing(reason = "cancelled") {
    if (this.pairingTimer) clearTimeout(this.pairingTimer);
    this.pairingTimer = null;
    this.pairingToken = "";
    const server = this.pairingServer;
    this.pairingServer = null;
    await closeServer(server);
    emit("pairing-stopped", { reason });
  }

  async startPairing(address, computerName) {
    await this.cancelPairing("restarted");
    if (!availableInterfaces().some((entry) => entry.address === address)) {
      throw new Error("Selecione um endereço da rede local disponível.");
    }
    this.pairing = null;
    this.phoneAddress = "";
    this.pairingToken = crypto.randomBytes(32).toString("base64url");
    const token = this.pairingToken;
    const server = http.createServer((request, response) => this.handlePairingRequest(request, response, token));
    this.pairingServer = server;
    const bound = await listen(server, address, 0);
    const name = String(computerName || os.hostname()).replace(/\s+/g, " ").trim().slice(0, 64) || "Notebook Linux";
    const callback = `http://${address}:${bound.port}${PAIRING_PATH}`;
    const query = new URLSearchParams({ callback, token, name });
    const uri = `manual7://pair?${query}`;
    const qrDataURL = await QRCode.toDataURL(uri, {
      errorCorrectionLevel: "M", width: 640, margin: 2,
      color: { dark: "#07100d", light: "#f3fff9" }
    });
    this.pairingTimer = setTimeout(() => this.cancelPairing("expired"), PAIRING_TIMEOUT_MS);
    return { qrDataURL, callback, expiresAt: Date.now() + PAIRING_TIMEOUT_MS, address };
  }

  handlePairingRequest(request, response, token) {
    const peer = normalizeAddress(request.socket.remoteAddress || "");
    if (request.method !== "POST" || request.url !== PAIRING_PATH) {
      jsonReply(response, 404, { ok: false, error: "Endpoint desconhecido." });
      return;
    }
    if (!isPrivateIPv4(peer)) {
      jsonReply(response, 403, { ok: false, error: "Origem fora da rede local." });
      return;
    }
    if (!timingSafeToken(token, request.headers["x-manual7-pairing"])) {
      jsonReply(response, 403, { ok: false, error: "Token inválido." });
      return;
    }
    if (this.pairing) {
      jsonReply(response, 409, { ok: false, error: "QR já utilizado." });
      return;
    }
    const contentType = String(request.headers["content-type"] || "").split(";", 1)[0];
    const length = Number(request.headers["content-length"] || 0);
    if (contentType !== "application/json" || !Number.isInteger(length) || length < 1 || length > MAX_PAIRING_BODY) {
      jsonReply(response, 413, { ok: false, error: "Corpo de pareamento inválido." });
      return;
    }
    const chunks = [];
    let received = 0;
    request.on("data", (chunk) => {
      received += chunk.length;
      if (received > MAX_PAIRING_BODY) request.destroy();
      else chunks.push(chunk);
    });
    request.on("end", () => {
      try {
        const pairing = validatePairingPayload(JSON.parse(Buffer.concat(chunks).toString("utf8")));
        this.pairing = pairing;
        this.phoneAddress = peer;
        jsonReply(response, 200, { ok: true, message: "Manual7 Studio reconhecido" });
        const publicPairing = { ...pairing };
        delete publicPairing.pin;
        emit("pairing-recognized", { phoneAddress: peer, pairing: publicPairing });
        this.cancelPairing("recognized");
      } catch (error) {
        jsonReply(response, 400, { ok: false, error: error.message });
      }
    });
  }

  fingerprintForKey(key) {
    return `SHA256:${crypto.createHash("sha256").update(key).digest("base64").replace(/=+$/, "")}`;
  }

  async connect(password, acceptedFingerprint = "") {
    if (!this.pairing || !this.phoneAddress) throw new Error("Leia primeiro o QR com o iPhone.");
    if (typeof password !== "string" || !password.length || password.length > 256) {
      throw new Error("Digite a senha SSH do usuário mobile.");
    }
    await this.disconnect(false);
    const host = this.phoneAddress;
    const port = this.pairing.preferredSSHPort;
    const remembered = await this.knownFingerprint(host, port);
    const trusted = acceptedFingerprint || remembered;
    this.pendingFingerprint = "";
    let client = null;
    let transport = "wifi";
    // The cable gives stable latency and keeps the iPhone charging. The host
    // key is the same sshd on either path, so the remembered fingerprint still
    // proves it is the paired phone; anything but a wrong password falls back
    // to Wi-Fi.
    const usb = await openUsbConnection(port).catch(() => null);
    if (usb) {
      try {
        client = await this.sshHandshake({ sock: usb.socket }, password, trusted);
        transport = "usb";
      } catch (error) {
        usb.socket.destroy();
        if (error.level === "client-authentication" || (this.pendingFingerprint && !trusted))
          return this.sshFailure(error, trusted, host, port);
        this.pendingFingerprint = "";
      }
    }
    if (!client) {
      try { client = await this.sshHandshake({ host, port }, password, trusted); }
      catch (error) { return this.sshFailure(error, trusted, host, port); }
    }
    this.ssh = client;
    this.transport = transport;
    this.connectedFingerprint = this.pendingFingerprint;
    if (!remembered || remembered !== this.connectedFingerprint)
      await this.rememberFingerprint(host, port, this.connectedFingerprint);
    client.on("close", () => this.handleSshClosed());
    client.on("error", (error) => emit("connection-error", { message: error.message }));
    await this.startForwarders();
    const ping = await this.apiRequest("GET", "/v1/ping", null, false);
    emit("connected", { host, port, transport, version: ping.version || this.pairing.version });
    return { ok: true, host, port, transport, version: ping.version || this.pairing.version,
      previewUrl: this.previewURL() };
  }

  // Resolves with a ready ssh2 client; pendingFingerprint holds the key seen.
  sshHandshake(target, password, trusted) {
    const client = new Client();
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        callback(value);
      };
      client.on("keyboard-interactive", (_name, _instructions, _language, prompts, done) => {
        done(prompts.map(() => password));
      });
      client.once("ready", () => finish(resolve, client));
      client.once("error", (error) => { client.end(); finish(reject, error); });
      client.once("close", () => {
        if (!settled) finish(reject, new Error("A conexão SSH foi encerrada durante a autenticação."));
      });
      client.connect({
        ...target, username: "mobile", password, tryKeyboard: true,
        readyTimeout: 15_000,
        // Wi-Fi drops otherwise leave the virtual camera frozen until TCP gives up.
        keepaliveInterval: 5_000, keepaliveCountMax: 3,
        hostVerifier: (key) => {
          const fingerprint = this.fingerprintForKey(key);
          this.pendingFingerprint = fingerprint;
          const actual = Buffer.from(fingerprint);
          const expected = Buffer.from(trusted);
          return Boolean(trusted) && actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
        }
      });
    });
  }

  sshFailure(error, trusted, host, port) {
    const fingerprint = this.pendingFingerprint;
    if (fingerprint && !trusted) return { ok: false, trustRequired: true, fingerprint, host, port };
    if (fingerprint && trusted && fingerprint !== trusted)
      throw new Error("A chave SSH do iPhone mudou. Remova a chave conhecida antes de continuar.");
    throw new Error(`Falha SSH: ${error.level === "client-authentication" ? "senha incorreta ou autenticação recusada" : error.message}`);
  }

  makeForwarder(remotePort) {
    const server = net.createServer((socket) => {
      if (!this.ssh) return socket.destroy();
      socket.setNoDelay(true);
      socket.setKeepAlive(true, 10_000);
      this.ssh.forwardOut("127.0.0.1", socket.remotePort || 0, "127.0.0.1", remotePort,
        (error, stream) => {
          if (error) return socket.destroy(error);
          socket.pipe(stream).pipe(socket);
          const close = () => { if (!stream.destroyed) stream.destroy(); };
          socket.on("error", close);
          stream.on("error", () => socket.destroy());
        });
    });
    server.on("error", (error) => emit("connection-error", { message: error.message }));
    return server;
  }

  async startForwarders() {
    this.apiForward = this.makeForwarder(API_BRIDGE_PORT);
    this.webcamForward = this.makeForwarder(WEBCAM_BRIDGE_PORT);
    this.apiPort = (await listen(this.apiForward)).port;
    this.webcamPort = (await listen(this.webcamForward)).port;
    this.previewToken = crypto.randomBytes(24).toString("base64url");
    this.resetLatency();
    this.previewFanout = new StreamFanout((onResponse) => {
      const upstream = http.request({
        host: "127.0.0.1", port: this.webcamPort, method: "GET",
        path: this.previewCodec === "h264" ? "/v1/webcam.h264" : "/v1/webcam.mjpg",
        headers: { "X-Manual7-PIN": this.pairing.pin }, timeout: 8_000
      }, onResponse);
      upstream.on("timeout", () => upstream.destroy(new Error("Timeout do preview")));
      upstream.end();
      return upstream;
    }, { onPart: (part) => this.notePartLatency(part) });
    this.previewServer = http.createServer((request, response) => this.handlePreview(request, response));
    this.previewPort = (await listen(this.previewServer)).port;
  }

  previewURL(kind = "mjpg") {
    return this.previewPort && this.previewToken
      ? `http://127.0.0.1:${this.previewPort}/preview.${kind}?token=${encodeURIComponent(this.previewToken)}`
      : "";
  }

  handlePreview(request, response) {
    let url;
    try { url = new URL(request.url, "http://127.0.0.1"); } catch { response.destroy(); return; }
    const raw = url.pathname === "/preview.h264";
    if (request.method !== "GET" || (url.pathname !== "/preview.mjpg" && !raw) ||
        !timingSafeToken(this.previewToken, url.searchParams.get("token"))) {
      response.writeHead(403); response.end(); return;
    }
    if (!this.previewFanout) { response.writeHead(503); response.end(); return; }
    // The Studio preview and FFmpeg share one iPhone stream: a second
    // upstream would double the Wi-Fi/SSH load and the A10's send work.
    this.previewFanout.subscribe(httpSink(response, raw ? "raw" : "multipart"));
  }

  resetLatency() {
    this.clockSamples = [];
    this.clockOffset = null;
    this.latency = { lastMs: 0, averageMs: 0, samples: 0 };
  }

  // Phone-to-PC delay of each part: X-Timestamp is the iPhone wall clock when
  // the part was sent, corrected by the estimated clock offset. It covers
  // Wi-Fi/USB, SSH and the bridges, not the encode before it nor the decode after.
  notePartLatency(part) {
    if (!part.timestamp || this.clockOffset === null) return;
    const milliseconds = (Date.now() / 1000 - (part.timestamp - this.clockOffset)) * 1000;
    if (!Number.isFinite(milliseconds) || milliseconds < -1000 || milliseconds > 60_000) return;
    const latency = this.latency;
    latency.lastMs = milliseconds;
    latency.averageMs = latency.samples ? latency.averageMs * 0.9 + milliseconds * 0.1 : milliseconds;
    ++latency.samples;
  }

  // GET /v1/state plus the Studio's own measurements. Each poll is a clock
  // sample; the one with the shortest round trip bounds the offset error by
  // half of that round trip.
  async remoteState() {
    const started = Date.now() / 1000;
    const envelope = await this.apiRequest("GET", "/v1/state");
    const finished = Date.now() / 1000;
    const state = envelope.state || envelope;
    const phoneNow = Number(state.now);
    let best = null;
    if (phoneNow > 0) {
      this.clockSamples.push({ rtt: finished - started, offset: phoneNow - (started + finished) / 2 });
      if (this.clockSamples.length > 20) this.clockSamples.shift();
      best = this.clockSamples.reduce((winner, sample) => sample.rtt < winner.rtt ? sample : winner);
      this.clockOffset = best.offset;
    }
    state.studio = {
      transport: this.transport, codec: this.previewCodec,
      latencyMs: this.latency.samples ? Math.round(this.latency.averageMs) : null,
      clockOffsetMs: best ? Math.round(best.offset * 1000) : null,
      clockErrorMs: best ? Math.round(best.rtt * 500) : null
    };
    return envelope;
  }

  // The renderer decodes H.264 with WebCodecs; access units travel by IPC.
  subscribeRendererFrames() {
    this.unsubscribeRendererFrames();
    if (!this.previewFanout) return;
    this.rendererFrames = this.previewFanout.subscribe({
      write: (part) => {
        if (mainWindow && !mainWindow.isDestroyed())
          mainWindow.webContents.send("m7:frame", { data: part.body, keyframe: part.keyframe });
        return true;
      },
      end: () => {
        this.rendererFrames = null;
        emit("preview-frames-ended", {});
      }
    });
  }

  unsubscribeRendererFrames() {
    const unsubscribe = this.rendererFrames;
    this.rendererFrames = null;
    if (unsubscribe) unsubscribe();
  }

  async resumeRendererFrames() {
    if (this.previewCodec !== "h264") return { ok: false, restart: true };
    const envelope = await this.apiRequest("GET", "/v1/state");
    const state = envelope.state || envelope;
    if (!state.webcam?.enabled || state.webcam?.h264?.available !== true) return { ok: false, restart: true };
    this.subscribeRendererFrames();
    return { ok: true };
  }

  apiRequest(method, route, body = null, authenticated = true) {
    if (!this.apiPort || !this.pairing) return Promise.reject(new Error("O iPhone não está conectado."));
    const data = body ? Buffer.from(JSON.stringify(body)) : null;
    return new Promise((resolve, reject) => {
      const headers = { "Accept": "application/json" };
      if (authenticated) headers["X-Manual7-PIN"] = this.pairing.pin;
      if (data) {
        headers["Content-Type"] = "application/json";
        headers["Content-Length"] = data.length;
      }
      const request = http.request({ host: "127.0.0.1", port: this.apiPort, path: route,
        method, headers, timeout: 12_000 }, (response) => {
        const chunks = [];
        let length = 0;
        response.on("data", (chunk) => {
          length += chunk.length;
          if (length > 4 * 1024 * 1024) response.destroy(new Error("Resposta remota muito grande."));
          else chunks.push(chunk);
        });
        response.on("end", () => {
          let value;
          try { value = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
          catch { reject(new Error("O iPhone retornou uma resposta inválida.")); return; }
          if ((response.statusCode || 500) >= 400 || value.ok === false)
            reject(new Error(value.error || `HTTP ${response.statusCode}`));
          else resolve(value);
        });
      });
      request.on("timeout", () => request.destroy(new Error("O M7 não respondeu a tempo.")));
      request.on("error", reject);
      if (data) request.write(data);
      request.end();
    });
  }

  async command(command, extra = {}) {
    return this.apiRequest("POST", "/v1/command", { command, ...extra });
  }

  async startPreview(format, rendererDecodesH264 = false) {
    const selected = format === "vertical" ? "vertical" : "horizontal";
    this.unsubscribeRendererFrames();
    this.previewFanout?.close();
    try { await this.command("webcam.stop"); } catch { /* already stopped */ }
    await this.command("set", { control: "webcamFormat", value: selected });
    await this.command("webcam.start");
    const deadline = Date.now() + 20_000;
    let state = null;
    while (Date.now() < deadline) {
      const envelope = await this.apiRequest("GET", "/v1/state");
      state = envelope.state || envelope;
      const webcamReady = state.captureMode === "video" && state.webcam?.enabled && state.webcam?.server?.running;
      if (webcamReady && state.webcam?.format !== selected)
        throw new Error(`O iPhone confirmou ${state.webcam?.format || "formato desconhecido"}, mas foi solicitado ${selected}.`);
      if (webcamReady) break;
      if (!state.webcam?.requested && !state.webcam?.enabled) {
        const detail = state.webcam?.lastError?.message || "O iPhone não conseguiu iniciar a webcam.";
        throw new Error(detail);
      }
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    if (!(state?.captureMode === "video" && state?.webcam?.enabled && state?.webcam?.format === selected))
      throw new Error("O iPhone não confirmou a webcam em modo Vídeo dentro de 20 segundos.");
    // H.264 needs an M7 that reports webcam.h264 and a WebCodecs decoder in the renderer; MJPEG
    // remains the fallback for either side.
    const h264 = rendererDecodesH264 && state.webcam?.h264?.available === true;
    this.previewCodec = h264 ? "h264" : "mjpeg";
    const expectedWidth = h264 ? Number(state.webcam.h264.width) : selected === "vertical" ? 720 : 1280;
    const expectedHeight = h264 ? Number(state.webcam.h264.height) : selected === "vertical" ? 1280 : 720;
    const reportedWidth = h264 ? expectedWidth : Number(state.webcam?.width);
    const reportedHeight = h264 ? expectedHeight : Number(state.webcam?.height);
    const portrait = expectedHeight > expectedWidth;
    if (reportedWidth !== expectedWidth || reportedHeight !== expectedHeight || !expectedWidth ||
        portrait !== (selected === "vertical"))
      throw new Error(`Dimensões inesperadas do iPhone: ${reportedWidth || 0} × ${reportedHeight || 0}.`);
    return { ok: true, format: state.webcam.format, width: expectedWidth,
      height: expectedHeight, captureMode: state.captureMode, codec: this.previewCodec,
      previewUrl: `${this.previewURL()}&reload=${Date.now()}` };
  }

  async stopPreview() {
    await this.stopVirtualCamera();
    this.unsubscribeRendererFrames();
    this.previewFanout?.close();
    try { return await this.command("webcam.stop"); }
    catch (error) { return { ok: false, error: error.message }; }
  }

  async systemStatus() {
    const ffmpeg = await executableOnPath("ffmpeg");
    return {
      ffmpegAvailable: Boolean(ffmpeg),
      ffmpegZscaleAvailable: await executableSupportsFilter(ffmpeg, "zscale"),
      virtualCameras: await virtualCameraDevices(),
      virtualCameraRunning: Boolean(this.ffmpeg)
    };
  }

  async startVirtualCamera(device) {
    if (!this.ssh || !this.previewPort) throw new Error("Conecte o iPhone e inicie o retorno visual primeiro.");
    if (!/^\/dev\/video\d+$/.test(String(device || ""))) throw new Error("Dispositivo de câmera virtual inválido.");
    const known = await virtualCameraDevices();
    if (!known.some((entry) => entry.path === device))
      throw new Error("O dispositivo selecionado não foi identificado como v4l2loopback.");
    const ffmpeg = await executableOnPath("ffmpeg");
    if (!ffmpeg) throw new Error("FFmpeg não foi encontrado no PATH deste computador.");
    const h264 = this.previewCodec === "h264";
    if (!h264 && !(await executableSupportsFilter(ffmpeg, "zscale")))
      throw new Error("Este FFmpeg não inclui o filtro zscale necessário para converter corretamente a faixa do MJPEG.");
    try { await fs.access(device, fs.constants.W_OK); }
    catch { throw new Error(`Sem permissão de escrita em ${device}. Verifique o grupo video.`); }
    await this.stopVirtualCamera();
    this.ffmpegStopping = false;
    // H.264 arrives as limited-range BT.709 4:2:0, already what v4l2 clients
    // expect; MJPEG is full range and needs an explicit conversion.
    const input = h264
      ? ["-probesize", "262144", "-analyzeduration", "200000", "-f", "h264", "-i", this.previewURL("h264"),
        "-an", "-pix_fmt", "yuv420p"]
      : ["-f", "mpjpeg", "-i", this.previewURL(), "-an",
        "-vf", "zscale=iw:ih:in_range=full:out_range=limited:filter=bilinear,format=yuv420p"];
    const child = spawn(ffmpeg, [
      "-hide_banner", "-loglevel", "warning", "-fflags", "nobuffer+discardcorrupt", "-flags", "low_delay",
      "-thread_queue_size", "256", "-use_wallclock_as_timestamps", "1", ...input,
      "-color_range", "tv", "-fps_mode", "passthrough", "-f", "v4l2", device
    ], { stdio: ["ignore", "ignore", "pipe"], windowsHide: true });
    this.ffmpeg = child;
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr = `${stderr}${chunk}`.slice(-4096); });
    child.once("error", (error) => emit("virtual-camera-error", { message: error.message }));
    child.once("close", (code) => {
      if (this.ffmpeg === child) this.ffmpeg = null;
      if (!this.ffmpegStopping && code !== 0) emit("virtual-camera-error", {
        message: stderr.trim().split("\n").slice(-2).join(" · ") || `FFmpeg terminou com código ${code}.`
      });
      emit("virtual-camera-stopped", { code });
    });
    emit("virtual-camera-started", { device });
    return { ok: true, device };
  }

  async stopVirtualCamera() {
    const child = this.ffmpeg;
    if (!child) return { ok: true, running: false };
    this.ffmpegStopping = true;
    this.ffmpeg = null;
    child.kill("SIGTERM");
    await new Promise((resolve) => {
      const timer = setTimeout(() => { if (child.exitCode === null) child.kill("SIGKILL"); resolve(); }, 1500);
      child.once("close", () => { clearTimeout(timer); resolve(); });
    });
    this.ffmpegStopping = false;
    return { ok: true, running: false };
  }

  async saveDiagnostic(owner) {
    const result = await this.apiRequest("GET", "/v1/diagnostic");
    const selected = await dialog.showSaveDialog(owner, {
      title: "Salvar diagnóstico Manual7",
      defaultPath: `manual7-diagnostico-${new Date().toISOString().replace(/[:.]/g, "-")}.json`,
      filters: [{ name: "JSON", extensions: ["json"] }]
    });
    if (selected.canceled || !selected.filePath) return { ok: false, canceled: true };
    await fs.writeFile(selected.filePath, `${JSON.stringify(result.report || result, null, 2)}\n`, "utf8");
    return { ok: true, path: selected.filePath };
  }

  async handleSshClosed() {
    if (!this.ssh && !this.apiForward && !this.webcamForward) return;
    await this.disconnect(false);
    emit("disconnected", { reason: "ssh-closed" });
  }

  async disconnect(notify = true) {
    await this.stopVirtualCamera();
    this.unsubscribeRendererFrames();
    this.previewFanout?.close();
    this.previewFanout = null;
    this.previewCodec = "mjpeg";
    this.transport = "";
    await Promise.all([closeServer(this.previewServer), closeServer(this.apiForward), closeServer(this.webcamForward)]);
    this.previewServer = null; this.apiForward = null; this.webcamForward = null;
    this.previewPort = 0; this.apiPort = 0; this.webcamPort = 0; this.previewToken = "";
    const client = this.ssh;
    this.ssh = null;
    if (client) client.end();
    if (notify) emit("disconnected", { reason: "user" });
  }

  async close() {
    await this.cancelPairing("app-closed");
    await this.disconnect(false);
  }
}

const session = new Manual7Session();

function installIPC() {
  ipcMain.handle("m7:interfaces", () => availableInterfaces());
  ipcMain.handle("m7:pairing-start", (_event, options) =>
    session.startPairing(String(options?.address || ""), String(options?.computerName || "")));
  ipcMain.handle("m7:pairing-cancel", () => session.cancelPairing("user"));
  ipcMain.handle("m7:connect", (_event, credentials) =>
    session.connect(String(credentials?.password || ""), String(credentials?.fingerprint || "")));
  ipcMain.handle("m7:disconnect", () => session.disconnect());
  ipcMain.handle("m7:state", () => session.remoteState());
  ipcMain.handle("m7:command", (_event, value) => session.command(String(value?.command || ""), value?.extra || {}));
  ipcMain.handle("m7:set", (_event, value) => session.command("set", {
    control: String(value?.control || ""), value: value?.value
  }));
  ipcMain.handle("m7:preview-start", (_event, value) => session.startPreview(
    String(value?.format ?? value ?? ""), value?.h264 === true));
  ipcMain.handle("m7:preview-frames-resume", () => session.resumeRendererFrames());
  ipcMain.handle("m7:preview-stop", () => session.stopPreview());
  ipcMain.handle("m7:system-status", () => session.systemStatus());
  ipcMain.handle("m7:virtual-camera-start", (_event, device) => session.startVirtualCamera(String(device || "")));
  ipcMain.handle("m7:virtual-camera-stop", () => session.stopVirtualCamera());
  ipcMain.handle("m7:diagnostic-save", (event) => session.saveDiagnostic(BrowserWindow.fromWebContents(event.sender)));
  ipcMain.handle("m7:open-external", (_event, url) => {
    const parsed = new URL(String(url));
    if (parsed.protocol !== "https:") throw new Error("Somente links HTTPS são permitidos.");
    return shell.openExternal(parsed.toString());
  });
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1440, height: 920, minWidth: 720, minHeight: 560,
    backgroundColor: "#07100d", title: "Manual7 Studio",
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  mainWindow.removeMenu();
  mainWindow.loadFile(path.join(__dirname, "renderer", "index.html"));
  mainWindow.once("ready-to-show", () => mainWindow.show());
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  mainWindow.webContents.on("will-navigate", (event) => event.preventDefault());
  mainWindow.on("closed", () => { mainWindow = null; });
}

if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on("second-instance", () => {
    if (!mainWindow) return;
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  });
  app.whenReady().then(() => { installIPC(); createWindow(); });
  app.on("window-all-closed", () => app.quit());
  app.on("before-quit", (event) => {
    if (app.__manual7Closing) return;
    event.preventDefault();
    app.__manual7Closing = true;
    session.close().finally(() => app.quit());
  });
}
