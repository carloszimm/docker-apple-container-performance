# Alpine 3.24 package versions used by the benchmark images

Checked with `apk search -e` against `alpine:3.24`. Package revisions can change within a
release branch, so the versions actually used by an experiment run are the ones recorded by
`collect_system_info.sh` under `docs/system_info/`.

| Package | Version | Used by |
|---------|---------|---------|
| sysbench | 1.0.20-r5 | CPU and memory benchmarks (`images/sysbench`) |
| fio | 3.41-r0 | Disk I/O benchmark (`images/fio`) |
| jq | 1.8.2-r0 | Disk I/O benchmark (`images/fio`) |
| gcc | 15.2.0-r5 | STREAM benchmark (`images/stream`) |
| libgomp | 15.2.0-r5 | STREAM benchmark (OpenMP) |
| make | 4.4.1-r4 | STREAM benchmark |
| musl-dev | 1.2.6-r2 | STREAM benchmark |
| bc | 1.08.2-r1 | Math benchmark (`images/math`) |
