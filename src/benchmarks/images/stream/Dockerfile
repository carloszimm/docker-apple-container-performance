FROM alpine:3.19

# Minimal, deterministic image for the STREAM benchmark:
# - Removes toolchain "setup noise" from inside the iterations (no apk add in the loop)
# - Keeps the STREAM compilation outside the loop (once per scenario), since STREAM_ARRAY_SIZE is a compile-time constant
RUN apk add --no-cache gcc make libc-dev musl-dev libgomp wget ca-certificates

CMD ["sh", "-c", "sleep 1000000"]

