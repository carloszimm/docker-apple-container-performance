FROM alpine:3.24

# sysbench image used by the CPU and memory benchmarks.
# Tag: local/sysbench:1.0.20-alpine3.24 (sysbench 1.0.20 is the version packaged by Alpine 3.24).
# The run_cpu_performance.sh / run_memory_performance.sh scripts and
# import_images_to_apple_container.sh build this same image on demand; this file is the
# reference definition:
#   docker build -t local/sysbench:1.0.20-alpine3.24 src/benchmarks/images/sysbench/
RUN apk add --no-cache sysbench
ENTRYPOINT ["/usr/bin/sysbench"]
