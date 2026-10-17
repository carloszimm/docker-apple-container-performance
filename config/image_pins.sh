# Pinned base images (single source of truth for the experiment).
# Sourced by setup_environment.sh and verify_experiment_requirements.sh.
# The digests are the multi-arch index digests as reported by RepoDigests.
# Local tags (ALPINE_TAG / NGINX_TAG) are the names every benchmark script uses; setup pulls the
# image by digest and tags it with that name, so the tag always points at the pinned image.
ALPINE_TAG="alpine:3.24"
ALPINE_DIGEST="sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6"
NGINX_VERSION="1.30.6"
NGINX_TAG="nginx:1.30.6"
NGINX_DIGEST="sha256:eb1c896deef834f4e056829fd6dadac8305501f16cc71ba65fb252c8d0aa168e"
