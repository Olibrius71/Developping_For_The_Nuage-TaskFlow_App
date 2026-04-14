require("./tracing");
const { register, upstreamErrorsTotal, httpRequestsTotal, httpRequestDurationMs } = require("./metrics");
const express = require("express");
const { createProxyMiddleware } = require("http-proxy-middleware");
const pino = require("pino");
const pinoHttp = require("pino-http");
const authMiddleware = require("./auth");

const logger = pino({ level: process.env.LOG_LEVEL || "info" });
const app = express();

const USER_SERVICE_URL =
  process.env.USER_SERVICE_URL || "http://localhost:3001";
const TASK_SERVICE_URL =
  process.env.TASK_SERVICE_URL || "http://localhost:3002";
const NOTIFICATION_SERVICE_URL =
  process.env.NOTIFICATION_SERVICE_URL || "http://localhost:3003";

const ERROR_CODE = 400;

app.use(
  pinoHttp({
    logger,
    customLogLevel: (req, res) => {
      if (res.statusCode >= ERROR_CODE) return "error";
      return "info";
    },
    customSuccessMessage: (req, res) => {
      if (res.statusCode >= 400) return req.errorMessage ?? `request failed`;
      return `${req.method} completed`;
    },
    customErrorMessage: (req, res, err) => `request failed : ${err.message}`,
  }),
);

// Metrics middleware
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - start;
    const route = req.route ? req.route.path : req.path;
    httpRequestsTotal.labels(req.method, route, res.statusCode.toString()).inc();
    httpRequestDurationMs.labels(req.method, route, res.statusCode.toString()).observe(duration);
  });
  next();
});

app.get("/health", (req, res) =>
  res.json({
    status: "ok",
    service: "api-gateway",
    upstream: { USER_SERVICE_URL, TASK_SERVICE_URL, NOTIFICATION_SERVICE_URL },
  }),
);

app.get("/metrics", async (req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

app.use(authMiddleware);

// Proxy to user-service
app.use(
  "/api/users",
  createProxyMiddleware({
    target: USER_SERVICE_URL,
    changeOrigin: true,
    pathRewrite: { "^/api/users": "/users" },
    on: {
      error: (err, req, res) => {
        logger.error({ err }, "user-service proxy error");
        upstreamErrorsTotal.labels("user-service").inc();
        res.status(502).json({ error: "user-service unavailable" });
      },
    },
  }),
);

// Proxy to task-service
app.use(
  "/api/tasks",
  createProxyMiddleware({
    target: TASK_SERVICE_URL,
    changeOrigin: true,
    pathRewrite: { "^/api/tasks": "/tasks" },
    on: {
      error: (err, req, res) => {
        logger.error({ err }, "task-service proxy error");
        upstreamErrorsTotal.labels("task-service").inc();
        res.status(502).json({ error: "task-service unavailable" });
      },
    },
  }),
);

// Proxy to notification-service
app.use(
  "/api/notifications",
  createProxyMiddleware({
    target: NOTIFICATION_SERVICE_URL,
    changeOrigin: true,
    pathRewrite: { "^/api/notifications": "/notifications" },
    on: {
      error: (err, req, res) => {
        logger.error({ err }, "notification-service proxy error");
        upstreamErrorsTotal.labels("notification-service").inc();
        res.status(502).json({ error: "notification-service unavailable" });
      },
    },
  }),
);

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  logger.info({ port: PORT }, "api-gateway started");
});
