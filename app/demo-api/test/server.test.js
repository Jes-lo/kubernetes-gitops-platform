import assert from "node:assert/strict";
import test from "node:test";

import { createAppServer } from "../src/server.js";

async function startTestServer() {
  const app = createAppServer();

  await new Promise((resolve) => {
    app.server.listen(0, "127.0.0.1", resolve);
  });

  const address = app.server.address();

  return {
    ...app,
    baseUrl: `http://127.0.0.1:${address.port}`
  };
}

async function stopServer(server) {
  await new Promise((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }

      resolve();
    });
  });
}

test("health endpoint returns ok", async () => {
  const app = await startTestServer();

  try {
    const response = await fetch(`${app.baseUrl}/healthz`);
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.status, "ok");
  } finally {
    await stopServer(app.server);
  }
});

test("readiness endpoint reflects readiness state", async () => {
  const app = await startTestServer();

  try {
    let response = await fetch(`${app.baseUrl}/readyz`);
    assert.equal(response.status, 200);

    app.markNotReady();

    response = await fetch(`${app.baseUrl}/readyz`);
    assert.equal(response.status, 503);
  } finally {
    await stopServer(app.server);
  }
});

test("unknown route returns 404", async () => {
  const app = await startTestServer();

  try {
    const response = await fetch(`${app.baseUrl}/does-not-exist`);

    assert.equal(response.status, 404);
  } finally {
    await stopServer(app.server);
  }
});
