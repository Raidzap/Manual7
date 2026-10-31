"use strict";

const $ = (id) => document.getElementById(id);

const runtime = {
  connected: false,
  preview: false,
  virtualCamera: false,
  previewURL: "",
  previewCodec: "mjpeg",
  h264Failed: false,
  state: null,
  pairingExpiresAt: 0,
  expiryTimer: null,
  pollTimer: null,
  pollBusy: false,
  pollFailures: 0,
  webcamFormatChoice: "horizontal",
  webcamFormatChanging: false,
  cameraMountChanging: false,
  webcamFormatMismatch: "",
  pendingFingerprint: "",
  phone: null,
  toastTimer: null
};

// IPv4 addresses never appear in clear text: each one becomes a button that
// reveals the address on click and hides it again after REVEAL_MS.
const IPV4_PATTERN = /\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b/g;
const IP_MASK = "•••.•••.•••.•••";
const REVEAL_MS = 10_000;
const revealTimers = new WeakMap();

// H.264 preview: access units arrive by IPC and are decoded with WebCodecs.
// The bitstream is Annex B with in-band SPS/PPS, so no avcC description is
// configured. Any decoder failure switches this session back to MJPEG.
// Software decoding: Chromium's VA-API path rejected this stream on a test
// machine while the software decoder handled every frame, and 1080p30 costs
// a desktop CPU little.
const H264_CONFIG = { codec: "avc1.640028", hardwareAcceleration: "prefer-software", optimizeForLatency: true };
const h264 = { decoder: null, waitingKeyframe: true, unsubscribe: null, decoded: 0 };

async function rendererDecodesH264() {
  if (runtime.h264Failed || typeof VideoDecoder === "undefined") return false;
  try { return (await VideoDecoder.isConfigSupported(H264_CONFIG)).supported === true; }
  catch { return false; }
}

function stopH264Decoder() {
  if (h264.unsubscribe) h264.unsubscribe();
  h264.unsubscribe = null;
  if (h264.decoder && h264.decoder.state !== "closed") h264.decoder.close();
  h264.decoder = null;
  const canvas = $("previewCanvas");
  canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
}

function startH264Decoder() {
  stopH264Decoder();
  const canvas = $("previewCanvas");
  const context = canvas.getContext("2d");
  h264.waitingKeyframe = true;
  h264.decoded = 0;
  h264.decoder = new VideoDecoder({
    output: (frame) => {
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
      }
      context.drawImage(frame, 0, 0);
      frame.close();
      if (h264.decoded++ === 0 && runtime.preview) $("liveLabel").textContent = "AO VIVO";
    },
    error: (error) => {
      if (!runtime.preview || runtime.previewCodec !== "h264") return;
      runtime.h264Failed = true;
      message(`Decodificador H.264 indisponível (${error.message}); voltando para MJPEG.`, true);
      restartPreview();
    }
  });
  h264.decoder.configure(H264_CONFIG);
  let timestamp = 0;
  h264.unsubscribe = window.manual7.onFrame(({ data, keyframe }) => {
    const decoder = h264.decoder;
    if (!decoder || decoder.state !== "configured") return;
    // A backlog means the GPU fell behind; drop to the next keyframe rather
    // than show an ever later picture.
    if (decoder.decodeQueueSize > 3) h264.waitingKeyframe = true;
    if (h264.waitingKeyframe && !keyframe) return;
    h264.waitingKeyframe = false;
    timestamp += 33_333;
    decoder.decode(new EncodedVideoChunk({ type: keyframe ? "key" : "delta", timestamp, data }));
  });
}

// The decoder listens before main subscribes, so the replayed GOP that starts
// with a keyframe is not lost.
async function attachH264Preview() {
  startH264Decoder();
  let resumed = null;
  try { resumed = await window.manual7.resumePreviewFrames(); } catch { /* restart below */ }
  if (!resumed?.ok && runtime.preview) restartPreview();
}

async function restartPreview() {
  const format = runtime.webcamFormatChoice || "horizontal";
  await stopPreview();
  if (runtime.connected) await startPreview(format);
}

function redactedIP(address) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "redacted";
  button.dataset.secret = address;
  button.textContent = IP_MASK;
  button.title = "Clique para mostrar o IP";
  button.setAttribute("aria-label", "Endereço IP oculto. Clique para mostrar.");
  button.setAttribute("aria-pressed", "false");
  return button;
}

function setRedacted(button, revealed) {
  clearTimeout(revealTimers.get(button));
  button.classList.toggle("revealed", revealed);
  button.textContent = revealed ? button.dataset.secret : IP_MASK;
  button.title = revealed ? "Clique para ocultar o IP" : "Clique para mostrar o IP";
  button.setAttribute("aria-label", revealed ? `Endereço IP ${button.dataset.secret}. Clique para ocultar.`
    : "Endereço IP oculto. Clique para mostrar.");
  button.setAttribute("aria-pressed", String(revealed));
  if (revealed) revealTimers.set(button, setTimeout(() => setRedacted(button, false), REVEAL_MS));
}

function setRedactedText(element, text) {
  const value = String(text ?? "");
  const nodes = [];
  let last = 0;
  for (const match of value.matchAll(IPV4_PATTERN)) {
    if (match.index > last) nodes.push(document.createTextNode(value.slice(last, match.index)));
    nodes.push(redactedIP(match[0]));
    last = match.index + match[0].length;
  }
  if (last < value.length) nodes.push(document.createTextNode(value.slice(last)));
  element.replaceChildren(...nodes);
}

function hideToastLater(delay = 3600) {
  clearTimeout(runtime.toastTimer);
  runtime.toastTimer = setTimeout(() => $("toast").classList.remove("show"), delay);
}

function message(text, error = false) {
  const toast = $("toast");
  setRedactedText(toast, text);
  toast.classList.toggle("error", error);
  toast.classList.add("show");
  hideToastLater(error ? 6000 : 3600);
}

function setConnection(mode, label) {
  const pill = $("connectionPill");
  pill.className = `connection-pill ${mode}`;
  pill.querySelector("b").textContent = label;
}

function formatShutter(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value <= 0) return "—";
  if (value >= 1) return `${value.toFixed(value >= 10 ? 0 : 2).replace(/\.00$/, "")} s`;
  return `1/${Math.max(1, Math.round(1 / value))}`;
}

function formatNumber(value, digits = 0) {
  return Number.isFinite(Number(value)) ? Number(value).toLocaleString("pt-BR", { maximumFractionDigits: digits }) : "—";
}

function selectSegment(id, value) {
  for (const button of $(id).querySelectorAll("button"))
    button.classList.toggle("selected", button.dataset.value === String(value));
}

function selectedSegment(id) {
  return $(id).querySelector("button.selected")?.dataset.value || "";
}

function setSegmentEnabled(id, enabled) {
  for (const button of $(id).querySelectorAll("button")) button.disabled = !enabled;
}

function untouched(input) {
  return input.dataset.dragging !== "true" && document.activeElement !== input;
}

function updateSliderLabels() {
  const limits = runtime.state?.limits || {};
  const isoPosition = Number($("isoSlider").value) / 1000;
  const minISO = Number(limits.minISO || 0), maxISO = Number(limits.maxISO || 0);
  const iso = minISO > 0 && maxISO >= minISO
    ? Math.exp(Math.log(minISO) + isoPosition * (Math.log(maxISO) - Math.log(minISO))) : 0;
  $("isoValue").textContent = formatNumber(iso);
  $("shutterValue").textContent = formatShutter(2 ** (Number($("shutterSlider").value) / 3));
  $("evValue").textContent = `${(Number($("evSlider").value) / 3).toFixed(1).replace(".", ",")} EV`;
  $("focusValue").textContent = (Number($("focusSlider").value) / 1000).toFixed(2).replace(".", ",");
  $("peakingValue").textContent = (Number($("peakingSlider").value) / 1000).toFixed(2).replace(".", ",");
}

async function setControl(control, value) {
  try {
    await window.manual7.setControl(control, value);
    $("syncLabel").textContent = "Aplicando…";
    setTimeout(pollState, 180);
  } catch (error) {
    message(error.message, true);
    await pollState();
  }
}

function applyState(envelope) {
  const state = envelope?.state || envelope;
  if (!state) return;
  runtime.state = state;
  const actual = state.actual || {};
  const limits = state.limits || {};
  const available = state.available || {};

  selectSegment("captureMode", state.captureMode);
  selectSegment("lens", state.lens);
  selectSegment("exposureMode", state.exposureMode);
  selectSegment("focusMode", state.focusMode);
  selectSegment("videoFormat", state.videoFormat);
  const remoteWebcamFormat = state.webcam?.format === "vertical" ? "vertical" : "horizontal";
  if (!runtime.webcamFormatChanging) {
    runtime.webcamFormatChoice = remoteWebcamFormat;
    selectSegment("webcamFormat", remoteWebcamFormat);
  }
  if (!runtime.cameraMountChanging && state.cameraMount) selectSegment("cameraMount", state.cameraMount);
  if (state.frameRate) selectSegment("frameRate", state.frameRate);

  setSegmentEnabled("captureMode", available.captureMode);
  setSegmentEnabled("lens", available.lens);
  setSegmentEnabled("exposureMode", available.exposure);
  setSegmentEnabled("focusMode", available.focus);
  setSegmentEnabled("webcamFormat", runtime.connected && !state.webcam?.requested);
  // Older M7 builds have no mount setting. While the webcam streams the mount
  // is locked on the iPhone, but the Studio may stop and restart the preview.
  setSegmentEnabled("cameraMount", runtime.connected && Boolean(state.cameraMount) &&
    !state.videoRecording && !state.videoProcessing);
  // M7 0.7.10 and later; a recording keeps one rate from start to finish.
  setSegmentEnabled("frameRate", runtime.connected && Boolean(state.frameRate) && available.frameRate !== false &&
    !state.videoRecording && !state.videoProcessing);

  const isoSlider = $("isoSlider");
  if (untouched(isoSlider) && limits.minISO > 0 && limits.maxISO > limits.minISO && actual.ISO > 0) {
    isoSlider.value = Math.round(1000 * (Math.log(actual.ISO) - Math.log(limits.minISO)) /
      (Math.log(limits.maxISO) - Math.log(limits.minISO)));
  }
  isoSlider.disabled = !available.iso;

  const shutterSlider = $("shutterSlider");
  shutterSlider.min = limits.firstShutterIndex ?? -52;
  shutterSlider.max = limits.lastShutterIndex ?? -5;
  if (untouched(shutterSlider) && actual.shutterSeconds > 0)
    shutterSlider.value = Math.round(3 * Math.log2(actual.shutterSeconds));
  shutterSlider.disabled = !available.shutter;

  const evSlider = $("evSlider");
  evSlider.min = Math.ceil(Number(limits.minEV || -8) * 3);
  evSlider.max = Math.floor(Number(limits.maxEV || 8) * 3);
  if (untouched(evSlider)) evSlider.value = Number.isFinite(Number(state.evThirds)) ? state.evThirds : 0;
  evSlider.disabled = !available.ev;

  const focusSlider = $("focusSlider");
  if (untouched(focusSlider) && Number.isFinite(Number(actual.focusPosition)))
    focusSlider.value = Math.round(Number(actual.focusPosition) * 1000);
  focusSlider.disabled = !available.focusPosition;

  const peakingSlider = $("peakingSlider");
  if (untouched(peakingSlider) && Number.isFinite(Number(state.peakingThreshold)))
    peakingSlider.value = Math.round(Number(state.peakingThreshold) * 1000);
  peakingSlider.disabled = !available.peaking;

  $("peakingToggle").checked = Boolean(state.peaking);
  $("peakingToggle").disabled = !available.peaking;
  $("rawToggle").checked = Boolean(state.raw);
  $("rawToggle").disabled = !available.raw;
  $("jpegSize").value = String(state.jpegLongEdge ?? 0);
  $("jpegSize").disabled = Boolean(state.raw) || state.captureMode !== "photo" || Boolean(state.captureBusy);
  $("videoFormat").value = state.videoFormat || "both";
  $("videoFormat").disabled = !available.videoFormat;
  $("trackingToggle").checked = Boolean(state.tracking);
  $("trackingToggle").disabled = !available.tracking;

  $("hudISO").textContent = formatNumber(actual.ISO);
  $("hudShutter").textContent = formatShutter(actual.shutterSeconds);
  $("hudEV").textContent = `${Number(actual.exposureBias || 0).toFixed(1)} EV`;
  $("hudFocus").textContent = Number.isFinite(Number(actual.focusPosition)) ? Number(actual.focusPosition).toFixed(2) : "—";
  $("hudLens").textContent = state.lens === "tele" ? "2×" : "1×";
  const streamFPS = Number(state.webcam?.server?.effectiveFPS || 0);
  const publishedWidth = Number(state.webcam?.server?.lastWidth || 0);
  const publishedHeight = Number(state.webcam?.server?.lastHeight || 0);
  const publishedFormat = publishedWidth > 0 && publishedHeight > 0
    ? (publishedHeight > publishedWidth ? "vertical" : "horizontal") : remoteWebcamFormat;
  $("streamFormat").textContent = publishedFormat === "vertical" ? "9:16" : "16:9";
  const mismatch = state.webcam?.enabled && publishedWidth > 0 && publishedFormat !== remoteWebcamFormat
    ? `${remoteWebcamFormat}:${publishedWidth}x${publishedHeight}` : "";
  if (mismatch && mismatch !== runtime.webcamFormatMismatch)
    message(`Formato divergente: o iPhone anunciou ${remoteWebcamFormat}, mas publicou ${publishedWidth} × ${publishedHeight}.`, true);
  runtime.webcamFormatMismatch = mismatch;
  const latency = state.studio?.latencyMs;
  const thermal = state.webcam?.thermal?.state;
  const hot = thermal === "serious" || thermal === "critical";
  $("streamFPS").textContent = streamFPS > 0
    ? [`${streamFPS.toFixed(1).replace(".", ",")} fps`, latency !== null && latency !== undefined && runtime.preview
      ? `${latency} ms` : "", hot ? "quente" : ""].filter(Boolean).join(" · ")
    : "— fps";
  $("streamFPS").title = latency !== null && latency !== undefined
    ? `Atraso iPhone → PC (rede e SSH, ±${state.studio.clockErrorMs} ms)` : "";
  if (hot && runtime.thermal !== thermal && state.webcam?.enabled)
    message(`iPhone quente (${thermal === "critical" ? "crítico" : "alto"}): webcam limitada a ` +
      `${state.webcam.thermal.maxFPS} fps.`, true);
  runtime.thermal = thermal;
  $("lensValue").textContent = state.lens === "tele" ? "TELEOBJETIVA" : "GRANDE-ANGULAR";
  $("exposureReadout").textContent = state.exposureMode === "manual" ? "M" : state.exposureMode === "lock" ? "AE-L" : "AUTO";
  $("focusReadout").textContent = state.focusMode === "manual" ? "MF" : state.focusMode === "lock" ? "AF-L" : "AF";

  const video = state.captureMode === "video";
  const recording = Boolean(state.videoRecording);
  $("captureButton").disabled = !available.shutterButton;
  $("captureButton").classList.toggle("video", video);
  $("captureButton").classList.toggle("recording", recording);
  $("captureLabel").textContent = recording ? "Parar gravação" : video ? "Gravar vídeo" : "Fotografar";
  $("captureHint").textContent = state.captureBusy ? "Processando a captura…" :
    state.videoProcessing ? "Exportando Reframe…" : "Controle sincronizado com o iPhone.";
  $("syncLabel").textContent = `Atualizado ${new Date().toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit", second: "2-digit" })}`;
  updateSliderLabels();
}

async function pollState() {
  if (!runtime.connected || runtime.pollBusy) return;
  runtime.pollBusy = true;
  try {
    const state = await window.manual7.state();
    applyState(state);
    runtime.pollFailures = 0;
  } catch (error) {
    $("syncLabel").textContent = "Sem resposta";
    // Report the first failure only; a dropped Wi-Fi link would otherwise
    // stack one error toast per poll.
    if (!/não está conectado/i.test(error.message) && runtime.pollFailures++ === 0) message(error.message, true);
  } finally { runtime.pollBusy = false; }
}

// Every poll costs the iPhone a state snapshot, so the poll stops while the
// window is hidden or minimized.
function beginPolling() {
  clearInterval(runtime.pollTimer);
  runtime.pollTimer = null;
  if (!runtime.connected || document.hidden) return;
  pollState();
  runtime.pollTimer = setInterval(pollState, 900);
}

function stopPolling() {
  clearInterval(runtime.pollTimer);
  runtime.pollTimer = null;
}

async function loadInterfaces() {
  const list = await window.manual7.interfaces();
  const select = $("interfaceSelect");
  select.replaceChildren();
  const names = new Map();
  for (const entry of list) names.set(entry.name, (names.get(entry.name) || 0) + 1);
  const seen = new Map();
  for (const entry of list) {
    // <option> cannot hold the reveal button, so it shows only the interface
    // name; the address appears redacted beside the select.
    const index = (seen.get(entry.name) || 0) + 1;
    seen.set(entry.name, index);
    const option = document.createElement("option");
    option.value = entry.address;
    option.textContent = names.get(entry.name) > 1 ? `${entry.name} (${index})` : entry.name;
    select.append(option);
  }
  updateInterfaceAddress();
  $("generateQRButton").disabled = !list.length;
  if (!list.length) $("pairingStatus").textContent = "Nenhuma rede privada foi encontrada. Conecte o notebook à mesma rede do iPhone.";
}

function updateInterfaceAddress() {
  const address = $("interfaceSelect").value;
  $("interfaceAddress").replaceChildren(address ? redactedIP(address) : document.createTextNode("—"));
}

async function generateQR() {
  try {
    $("generateQRButton").disabled = true;
    $("pairingStatus").textContent = "Gerando código de uso único…";
    const result = await window.manual7.startPairing({
      address: $("interfaceSelect").value,
      computerName: "Manual7 Studio"
    });
    $("qrImage").src = result.qrDataURL;
    $("qrPlaceholder").hidden = true;
    runtime.pairingExpiresAt = result.expiresAt;
    $("pairingStatus").textContent = "Aguardando o iPhone ler o código…";
    clearInterval(runtime.expiryTimer);
    runtime.expiryTimer = setInterval(() => {
      const remaining = Math.max(0, runtime.pairingExpiresAt - Date.now());
      $("expiryBar").style.width = `${remaining / 1200}%`;
      if (!remaining) {
        clearInterval(runtime.expiryTimer);
        $("pairingStatus").textContent = "O QR expirou. Gere um novo código.";
        $("generateQRButton").disabled = false;
      }
    }, 250);
  } catch (error) {
    setRedactedText($("pairingStatus"), error.message);
    $("generateQRButton").disabled = false;
  }
}

function openPairing() {
  $("pairingDialog").showModal();
  loadInterfaces().then(generateQR).catch((error) => message(error.message, true));
}

// Nothing was sent to the iPhone yet: the password only goes after the user
// approves the key shown here.
function showHostKey(result) {
  const changed = Boolean(result.keyChanged);
  runtime.pendingFingerprint = result.fingerprint;
  $("fingerprint").textContent = result.fingerprint;
  $("previousFingerprint").textContent = changed ? result.previousFingerprint : "";
  $("previousKey").hidden = !changed;
  $("trustPanel").classList.toggle("changed", changed);
  $("trustTitle").textContent = changed ? "A chave SSH do iPhone mudou" : "Chave do iPhone";
  $("trustHint").textContent = changed
    ? "Isso é esperado se você reinstalou o jailbreak ou o OpenSSH. Se não fez nada disso, cancele: outro aparelho pode estar se passando pelo iPhone. A senha ainda não foi enviada."
    : "Compare se você já conhece esta chave. Ela será lembrada neste computador.";
  $("trustPanel").hidden = false;
  $("authError").textContent = changed
    ? "Confirme a nova chave para substituir a antiga e conectar."
    : "Confirme a chave para concluir a primeira conexão.";
  $("authConnect").textContent = changed ? "Substituir chave e conectar" : "Confiar e conectar";
  $("authConnect").classList.toggle("danger", changed);
  $("authConnect").classList.toggle("primary", !changed);
}

function resetHostKey() {
  runtime.pendingFingerprint = "";
  $("trustPanel").hidden = true;
  $("trustPanel").classList.remove("changed");
  $("previousKey").hidden = true;
  $("authConnect").textContent = "Conectar";
  $("authConnect").classList.remove("danger");
  $("authConnect").classList.add("primary");
}

async function connectSSH(fingerprint = "") {
  const password = $("sshPassword").value;
  $("authError").textContent = "Conectando…";
  $("authConnect").disabled = true;
  setConnection("connecting", "Conectando…");
  try {
    const result = await window.manual7.connect({ password, fingerprint });
    if (result.trustRequired) {
      showHostKey(result);
      return;
    }
    runtime.connected = true;
    resetHostKey();
    runtime.previewURL = result.previewUrl;
    $("sshPassword").value = "";
    $("authDialog").close();
    $("connectButton").textContent = "Desconectar";
    $("connectButton").classList.replace("primary", "danger");
    $("diagnosticButton").disabled = false;
    $("previewButton").disabled = false;
    $("monitorTitle").textContent = `${runtime.phone?.pairing?.device || "iPhone"} · M7 ${result.version || ""}`;
    setConnection("online", `Conectado · ${result.transport === "usb" ? "USB" : "Wi-Fi"} · SSH ${result.port}`);
    runtime.pollFailures = 0;
    beginPolling();
    await refreshSystemStatus();
    message("iPhone conectado. Inicie o retorno visual quando quiser.");
  } catch (error) {
    setConnection("offline", "Falha na conexão");
    setRedactedText($("authError"), error.message);
  } finally { $("authConnect").disabled = false; }
}

function resetDisconnectedUI() {
  runtime.connected = false;
  runtime.preview = false;
  runtime.virtualCamera = false;
  runtime.webcamFormatChoice = "horizontal";
  runtime.webcamFormatChanging = false;
  runtime.webcamFormatMismatch = "";
  selectSegment("webcamFormat", "horizontal");
  $("previewImage").removeAttribute("src");
  stopH264Decoder();
  runtime.previewCodec = "mjpeg";
  runtime.h264Failed = false;
  $("viewport").classList.remove("live", "h264");
  $("liveLabel").textContent = "OFFLINE";
  $("streamFPS").textContent = "— fps";
  $("streamFormat").textContent = "16:9";
  $("liveLabel").parentElement.classList.remove("on");
  $("previewButton").textContent = "Iniciar retorno";
  stopPolling();
  setConnection("offline", "Desconectado");
  $("connectButton").textContent = "Parear iPhone";
  $("connectButton").classList.replace("danger", "primary");
  $("diagnosticButton").disabled = true;
  $("previewButton").disabled = true;
  $("captureButton").disabled = true;
  for (const id of ["captureMode", "lens", "exposureMode", "focusMode", "webcamFormat", "cameraMount", "frameRate"])
    setSegmentEnabled(id, false);
  for (const id of ["isoSlider", "shutterSlider", "evSlider", "focusSlider", "peakingSlider",
    "peakingToggle", "rawToggle", "jpegSize", "videoFormat", "trackingToggle"])
    $(id).disabled = true;
  $("monitorTitle").textContent = "Aguardando conexão";
  $("syncLabel").textContent = "Sem sincronização";
  updateVirtualCameraUI();
}

async function disconnect() {
  if (runtime.preview) await stopPreview();
  runtime.connected = false;
  await window.manual7.disconnect();
  resetDisconnectedUI();
}

async function refreshSystemStatus() {
  const status = await window.manual7.systemStatus();
  const select = $("virtualCameraDevice");
  const previous = select.value;
  select.replaceChildren();
  if (!status.virtualCameras.length) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = "Nenhum v4l2loopback encontrado";
    select.append(option);
  } else {
    for (const device of status.virtualCameras) {
      const option = document.createElement("option");
      option.value = device.path;
      option.textContent = `${device.path} · ${device.label}`;
      select.append(option);
    }
    if ([...select.options].some((option) => option.value === previous)) select.value = previous;
  }
  select.dataset.ffmpeg = status.ffmpegAvailable ? "true" : "false";
  select.dataset.zscale = status.ffmpegZscaleAvailable ? "true" : "false";
  select.disabled = runtime.virtualCamera || !status.ffmpegAvailable || !zscaleSatisfied() || !status.virtualCameras.length;
  if (!status.ffmpegAvailable) $("virtualCameraHint").textContent = "FFmpeg não foi encontrado no PATH.";
  else if (!zscaleSatisfied()) $("virtualCameraHint").textContent = "O FFmpeg instalado não inclui o filtro zscale.";
  else if (!status.virtualCameras.length) $("virtualCameraHint").textContent = "Carregue o módulo v4l2loopback para criar /dev/video*.";
  else $("virtualCameraHint").textContent = "Disponível para OBS, Meet e outros aplicativos.";
  updateVirtualCameraUI();
}

// zscale only converts the full-range MJPEG; the H.264 stream needs no filter.
function zscaleSatisfied() {
  return runtime.previewCodec === "h264" || $("virtualCameraDevice").dataset.zscale === "true";
}

function updateVirtualCameraUI() {
  const button = $("virtualCameraButton");
  const select = $("virtualCameraDevice");
  $("virtualCameraStatus").textContent = runtime.virtualCamera ? `Transmitindo em ${select.value}` : "Saída desativada";
  button.textContent = runtime.virtualCamera ? "Parar câmera virtual" : "Transmitir para o Linux";
  button.classList.toggle("danger", runtime.virtualCamera);
  button.disabled = !runtime.virtualCamera && (!runtime.connected || !runtime.preview || !select.value ||
    select.dataset.ffmpeg !== "true" || !zscaleSatisfied());
  select.disabled = runtime.virtualCamera || !runtime.connected || !select.value ||
    select.dataset.ffmpeg !== "true" || !zscaleSatisfied();
}

async function startPreview(requestedFormat = "") {
  try {
    $("previewButton").disabled = true;
    const format = requestedFormat === "vertical" ? "vertical" :
      requestedFormat === "horizontal" ? "horizontal" :
        (runtime.webcamFormatChoice || selectedSegment("webcamFormat") || "horizontal");
    selectSegment("webcamFormat", format);
    const result = await window.manual7.startPreview(format, await rendererDecodesH264());
    const confirmedFormat = result.format === "vertical" ? "vertical" : "horizontal";
    runtime.webcamFormatChoice = confirmedFormat;
    selectSegment("webcamFormat", confirmedFormat);
    runtime.preview = true;
    runtime.previewURL = result.previewUrl;
    runtime.previewCodec = result.codec === "h264" ? "h264" : "mjpeg";
    if (runtime.previewCodec === "h264") attachH264Preview();
    else $("previewImage").src = result.previewUrl;
    $("viewport").classList.toggle("h264", runtime.previewCodec === "h264");
    $("viewport").classList.add("live");
    $("viewport").classList.toggle("portrait", confirmedFormat === "vertical");
    $("streamFormat").textContent = confirmedFormat === "vertical" ? "9:16" : "16:9";
    $("liveLabel").textContent = "AO VIVO";
    $("liveLabel").parentElement.classList.add("on");
    $("previewButton").textContent = "Parar retorno";
    updateVirtualCameraUI();
    message(`Retorno iniciado em ${confirmedFormat === "vertical" ? "Vertical 9:16" : "Horizontal 16:9"} · ` +
      `${result.width} × ${result.height} ${runtime.previewCodec === "h264" ? "H.264" : "MJPEG"}.`);
  } catch (error) { message(error.message, true); }
  finally { $("previewButton").disabled = !runtime.connected; }
}
async function stopPreview() {
  runtime.preview = false;
  runtime.virtualCamera = false;
  $("previewImage").removeAttribute("src");
  stopH264Decoder();
  $("viewport").classList.remove("live", "h264");
  $("liveLabel").textContent = "OFFLINE";
  $("streamFPS").textContent = "— fps";
  $("liveLabel").parentElement.classList.remove("on");
  $("previewButton").textContent = "Iniciar retorno";
  updateVirtualCameraUI();
  try { await window.manual7.stopPreview(); } catch (error) { message(error.message, true); }
}

function bindControls() {
  for (const group of document.querySelectorAll(".segmented[data-control]")) {
    group.addEventListener("click", async (event) => {
      const button = event.target.closest("button[data-value]");
      if (!button || button.disabled) return;
      const previous = selectedSegment(group.id);
      const next = button.dataset.value;
      selectSegment(group.id, next);
      if (group.dataset.control === "webcamFormat") {
        runtime.webcamFormatChanging = true;
        try {
          const wasPreviewing = runtime.preview;
          if (wasPreviewing) await stopPreview();
          await window.manual7.setControl("webcamFormat", next);
          runtime.webcamFormatChoice = next;
          if (wasPreviewing) await startPreview(next);
          else {
            await pollState();
            message(`Formato selecionado: ${next === "vertical" ? "Vertical 9:16" : "Horizontal 16:9"}.`);
          }
        } catch (error) {
          runtime.webcamFormatChoice = previous || "horizontal";
          selectSegment(group.id, runtime.webcamFormatChoice);
          message(error.message, true);
        } finally {
          runtime.webcamFormatChanging = false;
        }
        return;
      }
      if (group.dataset.control === "frameRate") {
        if (next === previous) return;
        try {
          // The preview keeps running: the iPhone restarts the H.264 stream on a keyframe.
          await window.manual7.setControl("frameRate", Number(next));
          message(next === "24" ? "24 fps fixos, visual de cinema. Para o borrão natural, use obturador perto de 1/50." :
            "30 fps fixos.");
          setTimeout(pollState, 180);
        } catch (error) {
          selectSegment(group.id, previous);
          message(error.message, true);
        }
        return;
      }
      if (group.dataset.control === "cameraMount") {
        runtime.cameraMountChanging = true;
        try {
          const wasPreviewing = runtime.preview;
          if (wasPreviewing) await stopPreview();
          await window.manual7.setControl("cameraMount", next);
          if (wasPreviewing) await startPreview(runtime.webcamFormatChoice);
          else await pollState();
          message(`Montagem: ${next === "portrait" ? "retrato (9:16 nativo)" :
            next === "landscape" ? "paisagem, Home à direita (16:9 nativo)" : "paisagem, Home à esquerda (16:9 nativo)"}.`);
        } catch (error) {
          selectSegment(group.id, previous);
          message(error.message, true);
        } finally {
          runtime.cameraMountChanging = false;
        }
        return;
      }
      try { await setControl(group.dataset.control, next); }
      catch { selectSegment(group.id, previous); }
    });
  }

  const sliders = [$("isoSlider"), $("shutterSlider"), $("evSlider"), $("focusSlider"), $("peakingSlider")];
  for (const slider of sliders) {
    slider.addEventListener("pointerdown", () => { slider.dataset.dragging = "true"; });
    slider.addEventListener("pointerup", () => { slider.dataset.dragging = "false"; });
    slider.addEventListener("pointercancel", () => { slider.dataset.dragging = "false"; });
    slider.addEventListener("input", updateSliderLabels);
  }
  $("isoSlider").addEventListener("change", () => {
    const limits = runtime.state?.limits || {};
    const position = Number($("isoSlider").value) / 1000;
    const iso = Math.exp(Math.log(limits.minISO) + position * (Math.log(limits.maxISO) - Math.log(limits.minISO)));
    setControl("iso", Math.round(iso));
  });
  $("shutterSlider").addEventListener("change", () => setControl("shutterSeconds", 2 ** (Number($("shutterSlider").value) / 3)));
  $("evSlider").addEventListener("change", () => setControl("evThirds", Number($("evSlider").value)));
  $("focusSlider").addEventListener("change", () => setControl("focusPosition", Number($("focusSlider").value) / 1000));
  $("peakingSlider").addEventListener("change", () => setControl("peakingThreshold", Number($("peakingSlider").value) / 1000));
  $("peakingToggle").addEventListener("change", () => setControl("peaking", $("peakingToggle").checked));
  $("rawToggle").addEventListener("change", () => setControl("raw", $("rawToggle").checked));
  $("jpegSize").addEventListener("change", () => setControl("jpegLongEdge", Number($("jpegSize").value)));
  $("videoFormat").addEventListener("change", () => setControl("videoFormat", $("videoFormat").value));
  $("trackingToggle").addEventListener("change", () => setControl("tracking", $("trackingToggle").checked));
}

window.manual7.onEvent((event) => {
  if (event.type === "pairing-recognized") {
    runtime.phone = event;
    resetHostKey();
    clearInterval(runtime.expiryTimer);
    if ($("pairingDialog").open) $("pairingDialog").close();
    setRedactedText($("authDevice"), `${event.pairing.device} · iOS ${event.pairing.systemVersion || "—"} · ${event.phoneAddress}:${event.pairing.preferredSSHPort}`);
    $("authError").textContent = "O PIN da API foi recebido pelo canal de pareamento. Falta autenticar o SSH.";
    $("authDialog").showModal();
    $("sshPassword").focus();
  } else if (event.type === "pairing-stopped" && event.reason === "expired") {
    $("pairingStatus").textContent = "O QR expirou. Gere um novo código.";
    $("generateQRButton").disabled = false;
  } else if (event.type === "virtual-camera-started") {
    runtime.virtualCamera = true;
    updateVirtualCameraUI();
  } else if (event.type === "virtual-camera-stopped") {
    runtime.virtualCamera = false;
    updateVirtualCameraUI();
  } else if (event.type === "virtual-camera-error") {
    runtime.virtualCamera = false;
    updateVirtualCameraUI();
    message(event.message, true);
  } else if (event.type === "preview-frames-ended") {
    if (!runtime.preview || runtime.previewCodec !== "h264") return;
    $("liveLabel").textContent = "RECONECTANDO";
    setTimeout(async () => {
      if (runtime.preview && runtime.previewCodec === "h264") attachH264Preview();
    }, 1200);
  } else if (event.type === "disconnected") {
    resetDisconnectedUI();
  } else if (event.type === "connection-error") {
    if (event.message) message(event.message, true);
  }
});

$("connectButton").addEventListener("click", () => runtime.connected ? disconnect() : openPairing());
$("generateQRButton").addEventListener("click", generateQR);
$("authConnect").addEventListener("click", () => connectSSH(runtime.pendingFingerprint));
$("authCancel").addEventListener("click", () => { $("authDialog").close(); setConnection("offline", "Desconectado"); });
$("sshPassword").addEventListener("keydown", (event) => { if (event.key === "Enter") connectSSH(runtime.pendingFingerprint); });
$("previewButton").addEventListener("click", () => runtime.preview ? stopPreview() : startPreview());
$("virtualCameraButton").addEventListener("click", async () => {
  $("virtualCameraButton").disabled = true;
  try {
    if (runtime.virtualCamera) {
      await window.manual7.stopVirtualCamera();
      runtime.virtualCamera = false;
      message("Câmera virtual interrompida.");
    } else {
      await window.manual7.startVirtualCamera($("virtualCameraDevice").value);
      runtime.virtualCamera = true;
      message(`Transmitindo para ${$("virtualCameraDevice").value}.`);
    }
  } catch (error) { message(error.message, true); }
  finally { updateVirtualCameraUI(); }
});
$("captureButton").addEventListener("click", async () => {
  try { await window.manual7.command("capture"); setTimeout(pollState, 200); }
  catch (error) { message(error.message, true); }
});
$("diagnosticButton").addEventListener("click", async () => {
  try { const result = await window.manual7.saveDiagnostic(); if (result.ok) message(`Diagnóstico salvo em ${result.path}`); }
  catch (error) { message(error.message, true); }
});
for (const button of document.querySelectorAll("[data-close]")) button.addEventListener("click", async () => {
  const dialog = $(button.dataset.close);
  if (dialog.id === "pairingDialog") await window.manual7.cancelPairing();
  dialog.close();
});
$("previewImage").addEventListener("error", () => {
  if (!runtime.preview) return;
  $("liveLabel").textContent = "RECONECTANDO";
  setTimeout(() => {
    if (runtime.preview) $("previewImage").src = `${runtime.previewURL}${runtime.previewURL.includes("?") ? "&" : "?"}retry=${Date.now()}`;
  }, 1200);
});
$("previewImage").addEventListener("load", () => { if (runtime.preview) $("liveLabel").textContent = "AO VIVO"; });
// Click-to-focus: the point is sent normalized to the published frame, so the
// letterbox around an object-fit: contain image is excluded.
function focusAtPreviewPoint(event) {
  const element = event.currentTarget;
  const naturalWidth = element.naturalWidth ?? element.width;
  const naturalHeight = element.naturalHeight ?? element.height;
  if (!runtime.preview || !runtime.state?.available?.focusPoint || !naturalWidth || !naturalHeight) return;
  const box = element.getBoundingClientRect();
  const scale = Math.min(box.width / naturalWidth, box.height / naturalHeight);
  const width = naturalWidth * scale, height = naturalHeight * scale;
  const left = box.left + (box.width - width) / 2, top = box.top + (box.height - height) / 2;
  const x = (event.clientX - left) / width, y = (event.clientY - top) / height;
  if (x < 0 || x > 1 || y < 0 || y > 1) return;
  const ring = $("focusRing");
  const viewport = $("viewport").getBoundingClientRect();
  ring.style.left = `${event.clientX - viewport.left}px`;
  ring.style.top = `${event.clientY - viewport.top}px`;
  ring.classList.remove("show");
  void ring.offsetWidth;
  ring.classList.add("show");
  setControl("focusPoint", { x: Number(x.toFixed(4)), y: Number(y.toFixed(4)) });
}
$("previewImage").addEventListener("click", focusAtPreviewPoint);
$("previewCanvas").addEventListener("click", focusAtPreviewPoint);
$("interfaceSelect").addEventListener("change", () => { updateInterfaceAddress(); generateQR(); });

document.addEventListener("click", (event) => {
  const button = event.target.closest(".redacted");
  if (!button) return;
  event.preventDefault();
  setRedacted(button, !button.classList.contains("revealed"));
  if (button.closest("#toast")) hideToastLater(REVEAL_MS);
});
$("toast").addEventListener("mouseenter", () => clearTimeout(runtime.toastTimer));
$("toast").addEventListener("mouseleave", () => hideToastLater(2000));

document.addEventListener("visibilitychange", () => {
  if (document.hidden) stopPolling();
  else beginPolling();
});

function toggleFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  else $("viewport").requestFullscreen().catch((error) => message(error.message, true));
}
$("fullscreenButton").addEventListener("click", toggleFullscreen);
$("viewport").addEventListener("dblclick", (event) => { if (!event.target.closest("button")) toggleFullscreen(); });
document.addEventListener("fullscreenchange", () => {
  $("fullscreenButton").setAttribute("aria-label", document.fullscreenElement ? "Sair da tela cheia" : "Tela cheia");
});

// Space shoots, F toggles fullscreen and P starts or stops the return.
// Ignored while typing or while a dialog is open.
document.addEventListener("keydown", (event) => {
  if (event.ctrlKey || event.metaKey || event.altKey || event.repeat) return;
  if (event.target.closest("input, select, textarea, button, [contenteditable]")) return;
  if (document.querySelector("dialog[open]")) return;
  const key = event.key.toLowerCase();
  if (key === " " && !$("captureButton").disabled) { event.preventDefault(); $("captureButton").click(); }
  else if (key === "f") toggleFullscreen();
  else if (key === "p" && !$("previewButton").disabled) $("previewButton").click();
});

bindControls();
updateSliderLabels();
resetDisconnectedUI();
loadInterfaces().catch(() => {});
refreshSystemStatus().catch(() => {});
