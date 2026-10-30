"use strict";

// Minimal usbmuxd client: lists iPhones on USB and opens a TCP connection to
// a port on the phone through the cable, which then carries SSH. Same
// protocol libimobiledevice's iproxy uses, without the external binary.

const net = require("node:net");

const HEADER_LENGTH = 16;
const PLIST_VERSION = 1;
const PLIST_MESSAGE = 8;
const MAX_RESPONSE = 1024 * 1024;
const PROGRAM = "Manual7 Studio";

function socketAddress(env = process.env) {
  const value = String(env.USBMUXD_SOCKET_ADDRESS || "");
  if (value.startsWith("UNIX:")) return { path: value.slice(5) };
  const tcp = /^([^:]+):(\d+)$/.exec(value);
  if (tcp) return { host: tcp[1], port: Number(tcp[2]) };
  return { path: "/var/run/usbmuxd" };
}

function escapeXML(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function encodePlist(value) {
  const encode = (item) => {
    if (Number.isInteger(item)) return `<integer>${item}</integer>`;
    if (typeof item === "boolean") return item ? "<true/>" : "<false/>";
    if (typeof item === "string") return `<string>${escapeXML(item)}</string>`;
    if (Array.isArray(item)) return `<array>${item.map(encode).join("")}</array>`;
    return `<dict>${Object.entries(item).map(([key, entry]) =>
      `<key>${escapeXML(key)}</key>${encode(entry)}`).join("")}</dict>`;
  };
  return '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
    `<plist version="1.0">${encode(value)}</plist>\n`;
}

function unescapeXML(value) {
  return value.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'").replace(/&amp;/g, "&");
}

// Parses the XML plists usbmuxd sends: dict, array, key, string, integer,
// real, true, false, data and date.
function parsePlist(xml) {
  const tokens = [];
  const pattern = /<(\/?)([A-Za-z]+)[^>]*?(\/?)>|([^<]+)/g;
  const body = String(xml).replace(/<\?xml[^>]*\?>|<!DOCTYPE[^>]*>/g, "");
  for (let match; (match = pattern.exec(body));) {
    if (match[4] !== undefined) { if (match[4].trim()) tokens.push({ text: match[4] }); continue; }
    tokens.push({ close: match[1] === "/", name: match[2], empty: match[3] === "/" });
  }
  let index = 0;
  const text = (name) => {
    let value = "";
    if (tokens[index]?.text !== undefined) value = tokens[index++].text;
    const end = tokens[index++];
    if (!end?.close || end.name !== name) throw new Error(`plist inválido em <${name}>`);
    return unescapeXML(value);
  };
  const value = () => {
    const token = tokens[index++];
    if (!token || token.close || token.text !== undefined) throw new Error("plist inválido");
    switch (token.name) {
      case "true": return true;
      case "false": return false;
      case "string": case "date": return token.empty ? "" : text(token.name);
      case "data": return token.empty ? Buffer.alloc(0) : Buffer.from(text("data").replace(/\s+/g, ""), "base64");
      case "integer": return Number.parseInt(text("integer"), 10);
      case "real": return Number.parseFloat(text("real"));
      case "array": {
        const items = [];
        if (token.empty) return items;
        while (!(tokens[index]?.close && tokens[index].name === "array")) items.push(value());
        ++index;
        return items;
      }
      case "dict": {
        const entries = {};
        if (token.empty) return entries;
        while (!(tokens[index]?.close && tokens[index].name === "dict")) {
          const key = tokens[index++];
          if (key?.name !== "key") throw new Error("plist inválido: chave ausente");
          entries[text("key")] = value();
        }
        ++index;
        return entries;
      }
      case "plist": {
        const result = value();
        ++index;
        return result;
      }
      default: throw new Error(`plist: tipo não suportado <${token.name}>`);
    }
  };
  return value();
}

function frame(message, tag) {
  const payload = Buffer.from(encodePlist({
    ClientVersionString: PROGRAM, ProgName: PROGRAM, ...message }), "utf8");
  const header = Buffer.alloc(HEADER_LENGTH);
  header.writeUInt32LE(HEADER_LENGTH + payload.length, 0);
  header.writeUInt32LE(PLIST_VERSION, 4);
  header.writeUInt32LE(PLIST_MESSAGE, 8);
  header.writeUInt32LE(tag, 12);
  return Buffer.concat([header, payload]);
}

// Sends one request and resolves with the parsed response and the socket.
// Bytes past the response belong to the tunnel and are pushed back.
function exchange(message, { timeout = 1500, env = process.env } = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketAddress(env));
    let buffer = Buffer.alloc(0);
    const fail = (error) => { socket.destroy(); reject(error); };
    socket.setTimeout(timeout, () => fail(new Error("usbmuxd não respondeu.")));
    socket.once("error", fail);
    socket.once("connect", () => socket.write(frame(message, 1)));
    const onData = (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length < HEADER_LENGTH) return;
      const length = buffer.readUInt32LE(0);
      if (length < HEADER_LENGTH || length > MAX_RESPONSE) return fail(new Error("Resposta inválida do usbmuxd."));
      if (buffer.length < length) return;
      socket.off("data", onData);
      socket.off("error", fail);
      socket.setTimeout(0);
      let response;
      try { response = parsePlist(buffer.subarray(HEADER_LENGTH, length).toString("utf8")); }
      catch (error) { return fail(error); }
      socket.pause();
      if (buffer.length > length) socket.unshift(buffer.subarray(length));
      resolve({ response, socket });
    };
    socket.on("data", onData);
  });
}

async function listUsbDevices(options) {
  const { response, socket } = await exchange({ MessageType: "ListDevices" }, options);
  socket.destroy();
  return (Array.isArray(response?.DeviceList) ? response.DeviceList : [])
    .map((entry) => entry?.Properties || {})
    .filter((properties) => properties.ConnectionType === "USB" && Number.isInteger(properties.DeviceID))
    .map((properties) => ({ deviceId: properties.DeviceID, serial: String(properties.SerialNumber || "") }));
}

// usbmuxd expects the port in network byte order inside a host integer.
function muxPort(port) {
  return ((port & 0xff) << 8) | ((port >> 8) & 0xff);
}

async function connectDevice(deviceId, port, options) {
  const { response, socket } = await exchange(
    { MessageType: "Connect", DeviceID: deviceId, PortNumber: muxPort(port) }, options);
  if (response?.MessageType !== "Result" || response.Number !== 0) {
    socket.destroy();
    throw new Error(`O iPhone recusou a conexão USB na porta ${port} (usbmuxd ${response?.Number ?? "?"}).`);
  }
  socket.resume();
  return socket;
}

// Resolves with a socket to `port` on the only iPhone attached by USB, or
// null when there is none, more than one, or no usbmuxd at all.
async function openUsbConnection(port, options) {
  let devices;
  try { devices = await listUsbDevices(options); }
  catch { return null; }
  if (devices.length !== 1) return null;
  const socket = await connectDevice(devices[0].deviceId, port, options);
  return { socket, serial: devices[0].serial };
}

module.exports = { socketAddress, encodePlist, parsePlist, muxPort, frame, listUsbDevices,
  connectDevice, openUsbConnection };
