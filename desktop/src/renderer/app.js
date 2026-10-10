"use strict";

const $ = (id) => document.getElementById(id);

const runtime = {
  connected: false,
  preview: false,
  virtualCamera: false,
  previewURL: "",
  state: null,
  pairingExpiresAt: 0,
  expiryTimer: null,
  pollTimer: null,
  pollBusy: false,
  webcamFormatChoice: "horizontal",
  webcamFormatChanging: false,
  webcamFormatMismatch: "",
  pendingFingerprint: "",
  phone: null,
  toastTimer: null
};

function message(text, error = false) {
  const toast = $("toast");
  toast.textContent = text;
  toast.classList.toggle("error", error);
  toast.classList.add("show");
  clearTimeout(runtime.toastTimer);
  runtime.toastTimer = setTimeout(() => toast.classList.remove("show"), 3600);
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

  setSegmentEnabled("captureMode", available.captureMode);
  setSegmentEnabled("lens", available.lens);
  setSegmentEnabled("exposureMode", available.exposure);
  setSegmentEnabled("focusMode", available.focus);
  setSegmentEnabled("webcamFormat", runtime.connected && !state.webcam?.requested);

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
  $("streamFPS").textContent = streamFPS > 0 ? `${streamFPS.toFixed(1).replace(".", ",")} fps` : "— fps";
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
  } catch (error) {
    $("syncLabel").textContent = "Sem resposta";
    if (!/não está conectado/i.test(error.message)) message(error.message, true);
  } finally { runtime.pollBusy = false; }
}

function beginPolling() {
  clearInterval(runtime.pollTimer);
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
  for (const entry of list) {
    const option = document.createElement("option");
    option.value = entry.address;
    option.textContent = `${entry.name} · ${entry.address}`;
    select.append(option);
  }
  $("generateQRButton").disabled = !list.length;
  if (!list.length) $("pairingStatus").textContent = "Nenhuma rede privada foi encontrada. Conecte o notebook à mesma rede do iPhone.";
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
    $("pairingStatus").textContent = error.message;
    $("generateQRButton").disabled = false;
  }
}

function openPairing() {
  $("pairingDialog").showModal();
  loadInterfaces().then(generateQR).catch((error) => message(error.message, true));
}

async function connectSSH(fingerprint = "") {
  const password = $("sshPassword").value;
  $("authError").textContent = "Conectando…";
  $("authConnect").disabled = true;
  setConnection("connecting", "Conectando…");
  try {
    const result = await window.manual7.connect({ password, fingerprint });
    if (result.trustRequired) {
      runtime.pendingFingerprint = result.fingerprint;
      $("fingerprint").textContent = result.fingerprint;
      $("trustPanel").hidden = false;
      $("authError").textContent = "Confirme a chave para concluir a primeira conexão.";
      $("authConnect").textContent = "Confiar e conectar";
      return;
    }
    runtime.connected = true;
    runtime.pendingFingerprint = "";
    runtime.previewURL = result.previewUrl;
    $("sshPassword").value = "";
    $("authDialog").close();
    $("connectButton").textContent = "Desconectar";
    $("diagnosticButton").disabled = false;
    $("previewButton").disabled = false;
    $("monitorTitle").textContent = `${runtime.phone?.pairing?.device || "iPhone"} · M7 ${result.version || ""}`;
    setConnection("online", `Conectado · SSH ${result.port}`);
    beginPolling();
    await refreshSystemStatus();
    message("iPhone conectado. Inicie o retorno visual quando quiser.");
  } catch (error) {
    setConnection("offline", "Falha na conexão");
    $("authError").textContent = error.message;
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
  $("viewport").classList.remove("live");
  $("liveLabel").textContent = "OFFLINE";
  $("streamFPS").textContent = "— fps";
  $("streamFormat").textContent = "16:9";
  $("liveLabel").parentElement.classList.remove("on");
  $("previewButton").textContent = "Iniciar retorno";
  stopPolling();
  setConnection("offline", "Desconectado");
  $("connectButton").textContent = "Parear iPhone";
  $("diagnosticButton").disabled = true;
  $("previewButton").disabled = true;
  $("captureButton").disabled = true;
  for (const id of ["captureMode", "lens", "exposureMode", "focusMode", "webcamFormat"])
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
  select.disabled = runtime.virtualCamera || !status.ffmpegAvailable || !status.ffmpegZscaleAvailable || !status.virtualCameras.length;
  if (!status.ffmpegAvailable) $("virtualCameraHint").textContent = "FFmpeg não foi encontrado no PATH.";
  else if (!status.ffmpegZscaleAvailable) $("virtualCameraHint").textContent = "O FFmpeg instalado não inclui o filtro zscale.";
  else if (!status.virtualCameras.length) $("virtualCameraHint").textContent = "Carregue o módulo v4l2loopback para criar /dev/video*.";
  else $("virtualCameraHint").textContent = "Disponível para OBS, Meet e outros aplicativos.";
  updateVirtualCameraUI();
}

function updateVirtualCameraUI() {
  const button = $("virtualCameraButton");
  const select = $("virtualCameraDevice");
  $("virtualCameraStatus").textContent = runtime.virtualCamera ? `Transmitindo em ${select.value}` : "Saída desativada";
  button.textContent = runtime.virtualCamera ? "Parar câmera virtual" : "Transmitir para o Linux";
  button.classList.toggle("danger", runtime.virtualCamera);
  button.disabled = !runtime.virtualCamera && (!runtime.connected || !runtime.preview || !select.value ||
    select.dataset.ffmpeg !== "true" || select.dataset.zscale !== "true");
  select.disabled = runtime.virtualCamera || !runtime.connected || !select.value ||
    select.dataset.ffmpeg !== "true" || select.dataset.zscale !== "true";
}

async function startPreview(requestedFormat = "") {
  try {
    $("previewButton").disabled = true;
    const format = requestedFormat === "vertical" ? "vertical" :
      requestedFormat === "horizontal" ? "horizontal" :
        (runtime.webcamFormatChoice || selectedSegment("webcamFormat") || "horizontal");
    selectSegment("webcamFormat", format);
    const result = await window.manual7.startPreview(format);
    const confirmedFormat = result.format === "vertical" ? "vertical" : "horizontal";
    runtime.webcamFormatChoice = confirmedFormat;
    selectSegment("webcamFormat", confirmedFormat);
    runtime.preview = true;
    runtime.previewURL = result.previewUrl;
    const image = $("previewImage");
    image.src = result.previewUrl;
    $("viewport").classList.add("live");
    $("viewport").classList.toggle("portrait", confirmedFormat === "vertical");
    $("streamFormat").textContent = confirmedFormat === "vertical" ? "9:16" : "16:9";
    $("liveLabel").textContent = "AO VIVO";
    $("liveLabel").parentElement.classList.add("on");
    $("previewButton").textContent = "Parar retorno";
    updateVirtualCameraUI();
    message(`Retorno iniciado em ${confirmedFormat === "vertical" ? "Vertical 9:16" : "Horizontal 16:9"}.`);
  } catch (error) { message(error.message, true); }
  finally { $("previewButton").disabled = !runtime.connected; }
}

async function stopPreview() {
  runtime.preview = false;
  runtime.virtualCamera = false;
  $("previewImage").removeAttribute("src");
  $("viewport").classList.remove("live");
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
    runtime.pendingFingerprint = "";
    clearInterval(runtime.expiryTimer);
    if ($("pairingDialog").open) $("pairingDialog").close();
    $("authDevice").textContent = `${event.pairing.device} · iOS ${event.pairing.systemVersion || "—"} · ${event.phoneAddress}:${event.pairing.preferredSSHPort}`;
    $("authError").textContent = "O PIN da API foi recebido pelo canal de pareamento. Falta autenticar o SSH.";
    $("trustPanel").hidden = true;
    $("authConnect").textContent = "Conectar";
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

bindControls();
updateSliderLabels();
resetDisconnectedUI();
loadInterfaces().catch(() => {});
refreshSystemStatus().catch(() => {});
