FROM alpine:3.24

# Minimal, deterministic image for the STREAM benchmark:
# - Removes toolchain "setup noise" from inside the iterations (no apk add in the loop)
# - Keeps the STREAM compilation outside the loop (once per scenario), since STREAM_ARRAY_SIZE is a compile-time constant
# - Ships a vendored copy of stream.c (v5.10, jeffhammond/STREAM commit
#   4dbce1d0fdb7410e8f21b48f3381bc0a1341967f) so no network access is needed at run time
RUN apk add --no-cache gcc make libc-dev musl-dev libgomp

WORKDIR /opt/stream
COPY stream.c /opt/stream/stream.c

CMD ["sh", "-c", "sleep 1000000"]
