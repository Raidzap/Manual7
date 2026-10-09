"use strict";

const crypto = require("node:crypto");
const net = require("node:net");

const API_BRIDGE_PORT = 27839;
const WEBCAM_BRIDGE_PORT = 27840;
const MAX_PAIRING_BODY = 16 * 1024;

function normalizeAddress(value) {
  if (typeof value !== "string") return "";
  return value.startsWith("::ffff:") ? value.slice(7) : value;
}

function isPrivateIPv4(value) {
  const address = normalizeAddress(value);
  if (net.isIP(address) !== 4) return false;
  const octets = address.split(".").map(Number);
  return octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168) ||
    (octets[0] === 169 && octets[1] === 254);
}

function validatePairingPayload(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Resposta de pareamento inválida.");
  }
  if (typeof value.pin !== "string" || !/^\d{6}$/.test(value.pin)) {
    throw new Error("PIN remoto inválido.");
  }
  const ports = Array.isArray(value.availableSSHPorts)
    ? value.availableSSHPorts.filter((port) => Number.isInteger(port) && port > 0 && port <= 65535)
    : [];
  let preferredSSHPort = Number(value.preferredSSHPort);
  if (!ports.includes(preferredSSHPort)) preferredSSHPort = ports[0] || 0;
  if (!preferredSSHPort) throw new Error("O iPhone não encontrou o OpenSSH ativo.");
  if (value.apiBridgePort !== API_BRIDGE_PORT || value.webcamBridgePort !== WEBCAM_BRIDGE_PORT) {
    throw new Error("O bridge do iPhone não é compatível com esta versão do Manual7 Studio.");
  }
  return {
    version: String(value.version || ""),
    pin: value.pin,
    preferredSSHPort,
    availableSSHPorts: ports,
    apiBridgePort: API_BRIDGE_PORT,
    webcamBridgePort: WEBCAM_BRIDGE_PORT,
    device: String(value.device || "iPhone").slice(0, 80),
    systemVersion: String(value.systemVersion || "").slice(0, 80)
  };
}

function timingSafeToken(expected, supplied) {
  if (typeof expected !== "string" || typeof supplied !== "string") return false;
  const left = Buffer.from(expected);
  const right = Buffer.from(supplied);
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function shutterSeconds(index) {
  return 2 ** (Number(index) / 3);
}

function shutterLabel(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value <= 0) return "—";
  if (value >= 1) return `${value.toFixed(value >= 10 ? 0 : 2).replace(/\.00$/, "")} s`;
  return `1/${Math.max(1, Math.round(1 / value))}`;
}

function isoFromSlider(position, minimum, maximum) {
  const p = Math.min(1, Math.max(0, Number(position)));
  const min = Number(minimum);
  const max = Number(maximum);
  if (!(min > 0 && max >= min)) return min || 0;
  if (p === 0) return min;
  if (p === 1) return max;
  return Math.exp(Math.log(min) + p * (Math.log(max) - Math.log(min)));
}

function sliderFromISO(iso, minimum, maximum) {
  const min = Number(minimum);
  const max = Number(maximum);
  const value = Math.min(max, Math.max(min, Number(iso)));
  if (!(min > 0 && max > min && value > 0)) return 0;
  return (Math.log(value) - Math.log(min)) / (Math.log(max) - Math.log(min));
}

module.exports = {
  API_BRIDGE_PORT,
  WEBCAM_BRIDGE_PORT,
  MAX_PAIRING_BODY,
  normalizeAddress,
  isPrivateIPv4,
  validatePairingPayload,
  timingSafeToken,
  shutterSeconds,
  shutterLabel,
  isoFromSlider,
  sliderFromISO
};
