"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const usbmux = require("../src/lib/usbmux");

test("codifica e lê plists XML do usbmuxd", () => {
  const xml = usbmux.encodePlist({ MessageType: "Connect", DeviceID: 7, PortNumber: 5632, Flag: true });
  assert.deepEqual(usbmux.parsePlist(xml), { MessageType: "Connect", DeviceID: 7, PortNumber: 5632, Flag: true });
  const list = usbmux.parsePlist(`<?xml version="1.0"?><plist version="1.0"><dict>
    <key>DeviceList</key><array><dict><key>DeviceID</key><integer>3</integer>
    <key>Properties</key><dict><key>ConnectionType</key><string>USB</string>
    <key>SerialNumber</key><string>abc&amp;1</string><key>Empty</key><dict/></dict></dict></array>
    </dict></plist>`);
  assert.equal(list.DeviceList[0].Properties.SerialNumber, "abc&1");
  assert.deepEqual(list.DeviceList[0].Properties.Empty, {});
});

test("porta vai em ordem de rede e o cabeçalho é little-endian", () => {
  assert.equal(usbmux.muxPort(22), 0x1600);
  assert.equal(usbmux.muxPort(2222), 0xae08);
  const packet = usbmux.frame({ MessageType: "ListDevices" }, 9);
  assert.equal(packet.readUInt32LE(0), packet.length);
  assert.equal(packet.readUInt32LE(4), 1);
  assert.equal(packet.readUInt32LE(8), 8);
  assert.equal(packet.readUInt32LE(12), 9);
});

test("endereço do socket respeita USBMUXD_SOCKET_ADDRESS", () => {
  assert.deepEqual(usbmux.socketAddress({}), { path: "/var/run/usbmuxd" });
  assert.deepEqual(usbmux.socketAddress({ USBMUXD_SOCKET_ADDRESS: "UNIX:/tmp/mux" }), { path: "/tmp/mux" });
  assert.deepEqual(usbmux.socketAddress({ USBMUXD_SOCKET_ADDRESS: "127.0.0.1:27015" }),
    { host: "127.0.0.1", port: 27015 });
});

function reply(socket, message) {
  const payload = Buffer.from(usbmux.encodePlist(message));
  const header = Buffer.alloc(16);
  header.writeUInt32LE(16 + payload.length, 0);
  header.writeUInt32LE(1, 4); header.writeUInt32LE(8, 8); header.writeUInt32LE(1, 12);
  return Buffer.concat([header, payload]);
}

function fakeUsbmuxd(devices) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "m7-usbmux-"));
  const socketPath = path.join(directory, "usbmuxd");
  const requests = [];
  const server = net.createServer((socket) => {
    let buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length < 16 || buffer.length < buffer.readUInt32LE(0)) return;
      const request = usbmux.parsePlist(buffer.subarray(16, buffer.readUInt32LE(0)).toString());
      requests.push(request);
      buffer = Buffer.alloc(0);
      if (request.MessageType === "ListDevices") {
        socket.end(reply(socket, { DeviceList: devices.map((properties) => ({
          DeviceID: properties.DeviceID, MessageType: "Attached", Properties: properties })) }));
      } else if (request.MessageType === "Connect") {
        // The SSH banner may share a packet with the result.
        socket.write(Buffer.concat([reply(socket, { MessageType: "Result", Number: 0 }),
          Buffer.from("SSH-2.0-test\r\n")]));
        socket.on("data", (data) => socket.write(data));
      }
    });
  });
  return new Promise((resolve) => server.listen(socketPath, () => resolve({
    env: { USBMUXD_SOCKET_ADDRESS: `UNIX:${socketPath}` }, requests,
    close: () => { server.close(); fs.rmSync(directory, { recursive: true, force: true }); }
  })));
}

test("abre túnel USB para a porta SSH do único iPhone conectado", async () => {
  const mux = await fakeUsbmuxd([
    { DeviceID: 4, ConnectionType: "USB", SerialNumber: "phone" },
    { DeviceID: 5, ConnectionType: "Network", SerialNumber: "wifi" }
  ]);
  try {
    const connection = await usbmux.openUsbConnection(22, { env: mux.env });
    assert.equal(connection.serial, "phone");
    const received = await new Promise((resolve) => {
      let text = "";
      connection.socket.on("data", (chunk) => {
        text += chunk;
        if (text.includes("ping")) resolve(text);
      });
      connection.socket.write("ping");
    });
    connection.socket.destroy();
    assert.equal(received, "SSH-2.0-test\r\nping");
    const connect = mux.requests.find((request) => request.MessageType === "Connect");
    assert.equal(connect.DeviceID, 4);
    assert.equal(connect.PortNumber, usbmux.muxPort(22));
  } finally { mux.close(); }
});

test("sem iPhone, com dois iPhones ou sem usbmuxd não usa USB", async () => {
  const none = await fakeUsbmuxd([]);
  try { assert.equal(await usbmux.openUsbConnection(22, { env: none.env }), null); }
  finally { none.close(); }
  const two = await fakeUsbmuxd([
    { DeviceID: 1, ConnectionType: "USB", SerialNumber: "a" },
    { DeviceID: 2, ConnectionType: "USB", SerialNumber: "b" }
  ]);
  try { assert.equal(await usbmux.openUsbConnection(22, { env: two.env }), null); }
  finally { two.close(); }
  assert.equal(await usbmux.openUsbConnection(22,
    { env: { USBMUXD_SOCKET_ADDRESS: "UNIX:/nonexistent/m7-usbmuxd" } }), null);
});
