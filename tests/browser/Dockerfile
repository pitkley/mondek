# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Match the npm version exactly; this manifest includes Linux ARM64 and AMD64.
FROM mcr.microsoft.com/playwright:v1.63.0-noble@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27
WORKDIR /tests
COPY tests/browser/package.json tests/browser/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund && npm cache clean --force
COPY tests/browser/playwright.config.mjs ./
COPY tests/browser/specs ./specs
COPY tests/browser/support ./support
CMD ["npm", "test"]
