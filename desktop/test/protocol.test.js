"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  isPrivateIPv4,
  validatePairingPayload,
  timingSafeToken,
  shutterSeconds,
  shutterLabel,
  isoFromSlider,
  sliderFromISO
} = require("../src/lib/protocol");

const payload = () => ({
  version: "0.7.4",
  pin: "123456",
  preferredSSHPort: 22,
  availableSSHPorts: [22, 2222],
  apiBridgePort: 27839,
  webcamBridgePort: 27840,
  device: "iPhone",
  systemVersion: "15.8.3"
});

test("aceita apenas IPv4 privado ou link-local", () => {
  for (const value of ["10.0.0.2", "172.16.1.2", "192.168.18.44", "169.254.2.3", "::ffff:192.168.1.3"])
    assert.equal(isPrivateIPv4(value), true);
  for (const value of ["127.0.0.1", "8.8.8.8", "::1", "texto"])
    assert.equal(isPrivateIPv4(value), false);
});

test("valida PIN, SSH e portas fixas do bridge", () => {
  assert.equal(validatePairingPayload(payload()).preferredSSHPort, 22);
  for (const change of [
    { pin: "123" }, { availableSSHPorts: [] }, { apiBridgePort: 1234 }, { webcamBridgePort: 1234 }
  ]) assert.throws(() => validatePairingPayload({ ...payload(), ...change }));
});

test("token usa comparação exata", () => {
  assert.equal(timingSafeToken("abc", "abc"), true);
  assert.equal(timingSafeToken("abc", "abd"), false);
  assert.equal(timingSafeToken("abc", "ab"), false);
});

test("grade de shutter usa terços de stop", () => {
  assert.equal(shutterSeconds(0), 1);
  assert.ok(Math.abs(shutterSeconds(-3) - 0.5) < 1e-12);
  assert.equal(shutterLabel(1 / 125), "1/125");
});

test("slider ISO é logarítmico e reversível", () => {
  const iso = isoFromSlider(0.5, 22, 1760);
  assert.ok(Math.abs(sliderFromISO(iso, 22, 1760) - 0.5) < 1e-12);
  assert.equal(isoFromSlider(0, 22, 1760), 22);
  assert.ok(Math.abs(isoFromSlider(1, 22, 1760) - 1760) < 1e-8);
});
