# syntax=docker/dockerfile:1

# ---- build stage: has npm, never shipped ----
FROM node:22-slim@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d AS build
WORKDIR /app

# Install from the lockfile only: exact versions, no devDependencies, and no
# install scripts (a common supply-chain foothold).
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

COPY src ./src

# ---- runtime stage: Node binary and our files, nothing else ----
# Distroless: no shell, no package manager, no npm. Pinned by digest so a
# rebuild can't silently pick up a different image. Renovate/Dependabot bumps it.
FROM gcr.io/distroless/nodejs22-debian12:nonroot@sha256:13593b7570658e8477de39e2f4a1dd25db2f836d68a0ba771251572d23bb4f8e
WORKDIR /app
ENV NODE_ENV=production PORT=8080

# Files stay owned by root and read-only to the app user, so a compromised
# process can't rewrite its own code.
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/src ./src

# uid 65532, already defined by the :nonroot image. Numeric so the runtime
# can verify it's non-root without reading /etc/passwd.
USER 65532:65532
EXPOSE 8080

# No shell or curl here, so the check uses node itself. ECS uses the task
# definition's healthCheck, which runs the same command.
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:8080/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

# The image's entrypoint is already node. No secrets here: DB_PASSWORD is
# injected at container start by ECS from Secrets Manager.
CMD ["src/server.js"]
