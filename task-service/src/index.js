require("./tracing");
const { register, httpRequestsTotal, httpRequestDurationMs } = require("./metrics");
const express = require("express");
const pino = require("pino");
const pinoHttp = require("pino-http");
const routes = require("./routes");

const logger = pino({ level: process.env.LOG_LEVEL || "info" });
const app = express();

app.use(express.json());
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
  res.json({ status: "ok", service: "task-service" }),
);

app.get("/metrics", async (req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

app.use("/tasks", routes);

const PORT = process.env.PORT || 3002;
app.listen(PORT, () => {
  logger.info({ port: PORT }, "task-service started");
});
