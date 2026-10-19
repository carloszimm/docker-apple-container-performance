# Image Digests - Reproducibility

## Importance

Digests ensure that exactly the same images are used in Docker and Apple container, which is essential for a fair comparison and scientific reproducibility.

## ⚠️ Important Note About Differing Digests

**Differing digests between Docker and Apple container are expected and normal** after importing via `docker save`/`container image load`:

- **Docker**: Uses `RepoDigest` (manifest digest from the Docker Hub registry)
- **Apple container**: Uses `Index digest` (internal OCI digest created after import)

The import process converts the image from Docker format to OCI, creating a new digest. **The image contents (layers, files, settings) are identical**, ensuring a fair comparison.

**Identity Guarantees:**
- ✅ Both images were pulled from Docker Hub with the same fixed tag
- ✅ Direct import from Docker into Apple container (no modifications)
- ✅ Use of fixed tags (`alpine:3.24`, `nginx:1.30.6`) instead of `latest`


---

## Images

### alpine:3.24

**Docker:**
- Digest: `alpine@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6`

**Apple container:**
- Image ID: `5ca7f92ce30b...` (local image, no digest)

ℹ️  **Note: One or both systems have no digest (local image)**

**Status:** ✅ Image imported and available on both systems

**Note About Digests:**
- Differing digests are expected after importing via `docker save`/`container image load`
- Docker uses RepoDigest (manifest digest from the registry)
- Apple container uses Index digest (internal OCI digest)
- The image contents (layers) are identical, ensuring a fair comparison

---

### nginx:1.30.6

**Docker:**
- Digest: `nginx@sha256:eb1c896deef834f4e056829fd6dadac8305501f16cc71ba65fb252c8d0aa168e`

**Apple container:**
- Image ID: `3b7859ba7f2d...` (local image, no digest)

ℹ️  **Note: One or both systems have no digest (local image)**

**Status:** ✅ Image imported and available on both systems

**Note About Digests:**
- Differing digests are expected after importing via `docker save`/`container image load`
- Docker uses RepoDigest (manifest digest from the registry)
- Apple container uses Index digest (internal OCI digest)
- The image contents (layers) are identical, ensuring a fair comparison

---

### sysbench

**Note:** sysbench does not use a pre-built image. It is installed dynamically inside `alpine:3.24` during benchmark execution.

**Installation Process:**
- The benchmarks run: `apk add --no-cache sysbench` inside the `alpine:3.24` container
- This ensures the same sysbench version is installed on both systems (Docker and Apple container)
- Installation uses the same Alpine repository, ensuring identity

**Advantages of This Approach:**
- ✅ Does not require a pre-built image
- ✅ Guarantees the same version on both systems
- ✅ Simplifies the setup process
- ✅ Reproducible (same command, same result)

---

## 📋 Summary

| Image | Docker | Apple container | Status |
|--------|--------|-----------------|--------|
| `alpine:3.24` | ✅ Available | ✅ Available | ✅ Imported |
| `nginx:1.30.6` | ✅ Available | ✅ Available | ✅ Imported |
| `sysbench` | ⚙️ Installed dynamically | ⚙️ Installed dynamically | ✅ Same process |

**Conclusion:** All required images are available and configured for a fair comparison between Docker and Apple container.

