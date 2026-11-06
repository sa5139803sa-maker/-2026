import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

const host = "http://127.0.0.1:3111";
const readyUrl = `${host}/api/admin/accounts`;
const server = spawn(
  "npm",
  ["run", "start", "--", "--hostname", "127.0.0.1", "--port", "3111"],
  { stdio: ["ignore", "pipe", "pipe"], env: process.env },
);

let output = "";
server.stdout.on("data", (chunk) => { output += chunk.toString(); });
server.stderr.on("data", (chunk) => { output += chunk.toString(); });

async function waitForServer() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (server.exitCode !== null) {
      throw new Error(`Next.js server exited early (${server.exitCode}).\n${output.slice(-6000)}`);
    }
    try {
      const response = await fetch(readyUrl, { redirect: "manual" });
      if (response.status === 405) return;
    } catch {
      // The production server may still be binding its local port.
    }
    await delay(500);
  }
  throw new Error(`Next.js server did not become ready.\n${output.slice(-6000)}`);
}

async function post(body, headers = {}) {
  return fetch(readyUrl, {
    method: "POST",
    headers,
    body,
    redirect: "manual",
  });
}

try {
  await waitForServer();

  const getResponse = await fetch(readyUrl, { redirect: "manual" });
  assert.equal(getResponse.status, 405, "GET must not be accepted by the admin accounts endpoint");

  const wrongOrigin = await post(JSON.stringify({ action: "list_users" }), {
    "content-type": "application/json",
    origin: "https://attacker.invalid",
  });
  assert.equal(wrongOrigin.status, 403, "cross-origin POST must be rejected before auth");

  const missingOrigin = await post(JSON.stringify({ action: "list_users" }), {
    "content-type": "application/json",
  });
  assert.equal(missingOrigin.status, 403, "POST without Origin must be rejected");

  const wrongContentType = await post(JSON.stringify({ action: "list_users" }), {
    "content-type": "text/plain",
    origin: host,
  });
  assert.equal(wrongContentType.status, 415, "non-JSON POST must be rejected");

  const malformedJson = await post("{", {
    "content-type": "application/json",
    origin: host,
  });
  assert.equal(malformedJson.status, 400, "malformed JSON must be rejected");

  const oversized = await post("x".repeat(9_000), {
    "content-type": "application/json",
    origin: host,
  });
  assert.equal(oversized.status, 413, "oversized POST must be rejected");

  const unauthenticated = await post(JSON.stringify({ action: "list_users" }), {
    "content-type": "application/json",
    origin: host,
  });
  assert.equal(unauthenticated.status, 401, "valid same-origin request without a session must return 401");
  assert.match(
    unauthenticated.headers.get("cache-control") ?? "",
    /private,\s*no-store/i,
    "authorization response must not be cached",
  );

  console.log(JSON.stringify({
    result: "PASS",
    checks: {
      getMethodRejected: getResponse.status,
      crossOriginRejected: wrongOrigin.status,
      missingOriginRejected: missingOrigin.status,
      contentTypeRejected: wrongContentType.status,
      malformedJsonRejected: malformedJson.status,
      oversizedBodyRejected: oversized.status,
      unauthenticatedPostRejected: unauthenticated.status,
    },
  }));
} catch (error) {
  console.error(output.slice(-6000));
  throw error;
} finally {
  if (server.exitCode === null) {
    server.kill("SIGTERM");
    await new Promise((resolve) => {
      const timeout = setTimeout(resolve, 3_000);
      server.once("exit", () => {
        clearTimeout(timeout);
        resolve();
      });
    });
  }
}
