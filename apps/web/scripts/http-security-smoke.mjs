import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

const host = "http://127.0.0.1:3111";
const endpoint = `${host}/api/admin/accounts`;
const server = spawn(
  "npm",
  ["run", "start", "--", "--hostname", "0.0.0.0", "--port", "3111"],
  { stdio: ["ignore", "pipe", "pipe"], env: process.env },
);

let output = "";
server.stdout.on("data", (chunk) => { output += chunk.toString(); });
server.stderr.on("data", (chunk) => { output += chunk.toString(); });

async function request(init = {}) {
  return fetch(endpoint, {
    ...init,
    redirect: "manual",
    signal: AbortSignal.timeout(5_000),
  });
}

async function waitForServer() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (server.exitCode !== null) {
      throw new Error(`Next.js server exited early (${server.exitCode}).\n${output.slice(-6000)}`);
    }
    try {
      const response = await request({ method: "GET" });
      if (response.status === 405) return;
    } catch {
      // The production server may still be binding its local port.
    }
    await delay(500);
  }
  throw new Error(`Next.js server did not become ready.\n${output.slice(-6000)}`);
}

try {
  await waitForServer();

  const getResponse = await request({ method: "GET" });
  assert.equal(getResponse.status, 405, "GET must not be accepted by the admin accounts endpoint");

  const crossOrigin = await request({
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: "https://attacker.invalid",
    },
    body: JSON.stringify({ action: "list_users" }),
  });
  assert.equal(crossOrigin.status, 403, "cross-origin POST must be rejected");

  const missingOrigin = await request({
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action: "list_users" }),
  });
  assert.equal(missingOrigin.status, 403, "POST without Origin must be rejected");

  for (const response of [crossOrigin, missingOrigin]) {
    assert.match(
      response.headers.get("cache-control") ?? "",
      /private,\s*no-store/i,
      "rejected account requests must not be cached",
    );
  }

  console.log(JSON.stringify({
    result: "PASS",
    checks: {
      getMethodRejected: getResponse.status,
      crossOriginPostRejected: crossOrigin.status,
      missingOriginPostRejected: missingOrigin.status,
      rejectedResponsesNotCached: true,
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
