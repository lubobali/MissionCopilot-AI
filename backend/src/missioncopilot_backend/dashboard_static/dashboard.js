// MissionCopilot manager dashboard (#174): passkey sign-in and registration. The server makes
// every challenge and checks every answer; this file only hands them to the browser's WebAuthn.
"use strict";

const b64 = {
  decode(text) {
    const plain = text.replace(/-/g, "+").replace(/_/g, "/");
    const padded = plain + "=".repeat((4 - (plain.length % 4)) % 4);
    return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0)).buffer;
  },
  encode(buffer) {
    const bytes = String.fromCharCode(...new Uint8Array(buffer));
    return btoa(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
};

async function post(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: "same-origin",
  });
  if (!response.ok) throw new Error(String(response.status));
  return response.json();
}

function creationOptions(json) {
  if (PublicKeyCredential.parseCreationOptionsFromJSON) return PublicKeyCredential.parseCreationOptionsFromJSON(json);
  return { ...json, challenge: b64.decode(json.challenge), user: { ...json.user, id: b64.decode(json.user.id) },
    excludeCredentials: (json.excludeCredentials || []).map((c) => ({ ...c, id: b64.decode(c.id) })) };
}

function requestOptions(json) {
  if (PublicKeyCredential.parseRequestOptionsFromJSON) return PublicKeyCredential.parseRequestOptionsFromJSON(json);
  return { ...json, challenge: b64.decode(json.challenge),
    allowCredentials: (json.allowCredentials || []).map((c) => ({ ...c, id: b64.decode(c.id) })) };
}

function asJSON(credential) {
  if (credential.toJSON) return credential.toJSON();
  const r = credential.response, out = { id: credential.id, rawId: b64.encode(credential.rawId), type: credential.type,
    clientExtensionResults: credential.getClientExtensionResults(), response: { clientDataJSON: b64.encode(r.clientDataJSON) } };
  if (r.attestationObject) out.response.attestationObject = b64.encode(r.attestationObject);
  if (r.authenticatorData) out.response.authenticatorData = b64.encode(r.authenticatorData);
  if (r.signature) out.response.signature = b64.encode(r.signature);
  if (r.userHandle) out.response.userHandle = b64.encode(r.userHandle);
  return out;
}

function say(card, words, problem) {
  const status = card.querySelector(".status");
  status.textContent = words;
  status.classList.toggle("problem", Boolean(problem));
}

async function signIn(button) {
  const options = await post("/v1/dashboard/sign-in/options");
  const credential = await navigator.credentials.get({ publicKey: requestOptions(options) });
  await post("/v1/dashboard/sign-in/verify", { credential: asJSON(credential) });
}

async function register(button) {
  const options = await post("/v1/dashboard/register/options", { code: button.dataset.code });
  const credential = await navigator.credentials.create({ publicKey: creationOptions(options) });
  await post("/v1/dashboard/register/verify", { credential: asJSON(credential) });
}

document.addEventListener("click", async (event) => {
  const button = event.target.closest('button[data-action="sign-in"], button[data-action="register"]');
  if (!button) return;
  const card = button.closest("section");
  if (!window.PublicKeyCredential) return say(card, "This browser cannot use passkeys. Use Safari or Chrome.", true);
  button.disabled = true;
  say(card, "Waiting for Touch ID…");
  try {
    await (button.dataset.action === "register" ? register(button) : signIn(button));
    say(card, "Signed in.");
    location.assign("/dashboard");
  } catch (error) {
    const cancelled = error && error.name === "NotAllowedError";
    say(card, cancelled ? "Not signed in: you cancelled, or the time ran out. Try again."
      : button.dataset.action === "register" ? "That invite did not work. Ask for a new one; it works once, for 15 minutes."
      : "Not signed in. Try again.", true);
    button.disabled = false;
  }
});

// #175: the inner pages. Numbers count up into place; Command-K opens the palette; a clicked
// mission's title flows into the next page (cross-document View Transitions). Reduced motion: still.
const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function countUp(element) {
  const target = Number(element.dataset.count);
  if (still || !Number.isFinite(target) || target === 0) return;
  const start = performance.now(), time = 900;
  const step = (now) => {
    const done = Math.min(1, (now - start) / time);
    element.textContent = String(Math.round(target * (1 - Math.pow(1 - done, 3))));
    if (done < 1) requestAnimationFrame(step);
  };
  element.textContent = "0";
  requestAnimationFrame(step);
}

function palette() {
  const dialog = document.getElementById("palette");
  if (!dialog) return null;
  const input = dialog.querySelector("input"), empty = dialog.querySelector(".palette-empty");
  const items = [...dialog.querySelectorAll("li")];
  input.addEventListener("input", () => {
    const words = input.value.trim().toLowerCase();
    let shown = 0;
    for (const item of items) {
      const match = item.textContent.toLowerCase().includes(words);
      item.hidden = !match;
      shown += match ? 1 : 0;
    }
    empty.hidden = shown > 0;
  });
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      const first = items.find((item) => !item.hidden);
      if (first) first.querySelector("a").click();
    }
  });
  return () => { input.value = ""; input.dispatchEvent(new Event("input")); dialog.showModal(); input.focus(); };
}

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-count]").forEach(countUp);
  const open = palette();
  if (!open) return;
  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      open();
    }
  });
  document.querySelectorAll('[data-action="palette"]').forEach((button) => button.addEventListener("click", open));
  document.querySelectorAll(".mission-link").forEach((link) =>
    link.addEventListener("click", () => { link.style.viewTransitionName = "mission"; }));
});

// The report page's Print button (#177): the browser's print, with report.css's paper look.
document.addEventListener("click", (event) => {
  if (event.target.closest('button[data-action="print"]')) window.print();
});
