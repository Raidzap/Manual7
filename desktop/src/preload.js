"use strict";

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("manual7", {
  interfaces: () => ipcRenderer.invoke("m7:interfaces"),
  startPairing: (options) => ipcRenderer.invoke("m7:pairing-start", options),
  cancelPairing: () => ipcRenderer.invoke("m7:pairing-cancel"),
  connect: (credentials) => ipcRenderer.invoke("m7:connect", credentials),
  disconnect: () => ipcRenderer.invoke("m7:disconnect"),
  state: () => ipcRenderer.invoke("m7:state"),
  command: (command, extra = {}) => ipcRenderer.invoke("m7:command", { command, extra }),
  setControl: (control, value) => ipcRenderer.invoke("m7:set", { control, value }),
  startPreview: (format, h264 = false) => ipcRenderer.invoke("m7:preview-start", { format, h264 }),
  resumePreviewFrames: () => ipcRenderer.invoke("m7:preview-frames-resume"),
  stopPreview: () => ipcRenderer.invoke("m7:preview-stop"),
  systemStatus: () => ipcRenderer.invoke("m7:system-status"),
  startVirtualCamera: (device) => ipcRenderer.invoke("m7:virtual-camera-start", device),
  stopVirtualCamera: () => ipcRenderer.invoke("m7:virtual-camera-stop"),
  saveDiagnostic: () => ipcRenderer.invoke("m7:diagnostic-save"),
  openExternal: (url) => ipcRenderer.invoke("m7:open-external", url),
  onFrame: (callback) => {
    const handler = (_event, value) => callback(value);
    ipcRenderer.on("m7:frame", handler);
    return () => ipcRenderer.removeListener("m7:frame", handler);
  },
  onEvent: (callback) => {
    const handler = (_event, value) => callback(value);
    ipcRenderer.on("m7:event", handler);
    return () => ipcRenderer.removeListener("m7:event", handler);
  }
});
