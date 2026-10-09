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
  startPreview: (format) => ipcRenderer.invoke("m7:preview-start", format),
  stopPreview: () => ipcRenderer.invoke("m7:preview-stop"),
  systemStatus: () => ipcRenderer.invoke("m7:system-status"),
  startVirtualCamera: (device) => ipcRenderer.invoke("m7:virtual-camera-start", device),
  stopVirtualCamera: () => ipcRenderer.invoke("m7:virtual-camera-stop"),
  saveDiagnostic: () => ipcRenderer.invoke("m7:diagnostic-save"),
  openExternal: (url) => ipcRenderer.invoke("m7:open-external", url),
  onEvent: (callback) => {
    const handler = (_event, value) => callback(value);
    ipcRenderer.on("m7:event", handler);
    return () => ipcRenderer.removeListener("m7:event", handler);
  }
});
