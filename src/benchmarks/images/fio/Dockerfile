FROM alpine:3.24

# Minimal, deterministic image for the benchmark:
# - Removes "setup noise" (apk add) from inside the iterations
# - Provides fio + jq for extracting metrics as JSON
RUN apk add --no-cache fio jq

CMD ["sh", "-c", "sleep 1000000"]

