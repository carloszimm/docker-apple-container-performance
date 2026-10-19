FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Minimal, deterministic image for the math (PI) benchmark:
# - bc is installed at build time, so no package installation or network access happens
#   inside the measured runs
RUN apk add --no-cache bc

CMD ["sh", "-c", "sleep 1000000"]
