import http from "node:http";

const DEFAULT_PORT = 3000;

export function createAppServer() {
  let ready = true;

  const server = http.createServer((request, response) => {
    const path = request.url?.split("?")[0];

    response.setHeader("Content-Type", "application/json; charset=utf-8");
    response.setHeader("Cache-Control", "no-store");

    if (request.method !== "GET") {
      response.writeHead(405);
      response.end(JSON.stringify({ error: "method_not_allowed" }));
      return;
    }

    if (path === "/healthz") {
      response.writeHead(200);
      response.end(JSON.stringify({ status: "ok" }));
      return;
    }

    if (path === "/readyz") {
      response.writeHead(ready ? 200 : 503);
      response.end(
        JSON.stringify({
          status: ready ? "ready" : "not_ready"
        })
      );
      return;
    }

    if (path === "/version") {
      response.writeHead(200);
      response.end(
        JSON.stringify({
          version: process.env.APP_VERSION ?? "development"
        })
      );
      return;
    }

    if (path === "/") {
      response.writeHead(200);
      response.end(
        JSON.stringify({
          service: "demo-api",
          status: "running"
        })
      );
      return;
    }

    response.writeHead(404);
    response.end(JSON.stringify({ error: "not_found" }));
  });

  return {
    server,
    markNotReady() {
      ready = false;
    }
  };
}

function start() {
  const port = Number.parseInt(process.env.PORT ?? `${DEFAULT_PORT}`, 10);

  const { server, markNotReady } = createAppServer();

  server.listen(port, "0.0.0.0", () => {
    console.log(`demo-api listening on port ${port}`);
  });

  const shutdown = (signal) => {
    console.log(`${signal} received, shutting down`);

    markNotReady();

    server.close((error) => {
      if (error) {
        console.error(error);
        process.exitCode = 1;
      }
    });
  };

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  start();
}
