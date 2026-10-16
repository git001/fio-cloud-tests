# fio-cloud-tests

Realistic fio workloads (fio 3.43) and a comparison mode for mirrored vs. non-mirrored
cloud storage (GCP regional PD vs. zonal PD, Azure ZRS vs. LRS).

| Job | Content |
|---|---|
| `disk-baseline` | QD1 write + fdatasync, QD1/QD32 random 4k, seq 1M – raw disk characteristics |
| `postgresql-ssd` | Isolated WAL commit; then 16 backends 8k randrw (zipf), WAL, checkpointer, seq scan |
| `mongodb-ssd` | Isolated journal; then readers 4k–64k (zipf), eviction, checkpoint burst every ~60 s, journal |
| `meilisearch-ssd` | Isolated 4k search; then search + LMDB commits + grenad tmp + update files |
| `logs-hdd` | HDD baseline; then 8 append streams, audit log with fsync, logrotate |

QD = queue depth: the number of I/Os in flight at the same time. QD1 means one request
at a time (like a single database commit). QD32 means 32 requests in parallel (like many
concurrent clients).

## Comparison

```sh
run.sh compare <dir-A> <dir-B> [workload ...]

run.sh compare /data/regional /data/normal                   # GCP; default workloads
run.sh compare /data/zrs /data/lrs disk-baseline postgresql-ssd  # Azure; selected workloads
run.sh compare /data/ceph-rbd /data/local-nvme               # works for any two directories
```

Without a workload list, `disk-baseline`, `postgresql-ssd`, `mongodb-ssd` and
`meilisearch-ssd` run. The script has no provider-specific logic: the directory basenames
(`regional`, `normal`, ...) are only labels for the table columns and result paths. If
both basenames are the same, they are prefixed with `A-` and `B-`.

The workloads run one after another on A and B, never in parallel, because both disks
would otherwise share the VM's bandwidth limit. Afterwards a table shows
`delta = (A-B)/B`, so put the mirrored disk first. Results (JSON, `compare.tsv`,
`meta.txt`) are written to `/results/compare-<A>-vs-<B>-<timestamp>/`.

Each comparison also writes `report.html`: one self-contained file (no internet needed) with
headline tiles from `disk-baseline`, a diverging bar chart per workload for latency and
throughput (red = A worse, blue = A better, gray = within ±5 % noise), hover tooltips with the
absolute values and a table view. To rebuild it from an existing result directory, e.g. one
produced by an older image:

```sh
run.sh report /results/compare-<A>-vs-<B>-<timestamp>
```

Single run: `run.sh /data/pg postgresql-ssd`

For a fair comparison:
- **Same disk type, same size:** IOPS and throughput scale with size.
- **Same node and zone:** both PVCs in the same pod, `WaitForFirstConsumer`.
- **Data files much larger than the pod's memory limit**, otherwise you measure the page cache.
- **Measure longer:** `RUNTIME=300`, ideally run twice. With short runs the noise alone
  is ±10–15 %.
- **What to expect:** synchronous replication shows up mainly in
  `qd1-write-4k-fdatasync` (w_p99, fsync_p99) and in WAL/journal latency. Reads should
  show little difference.

## Build & Kubernetes

```sh
podman build -t fio-cloud-tests:3.43 .                      # UBI 10 (default)
podman build --build-arg EL=9 -t fio-cloud-tests:3.43-el9 . # UBI 9
```

### Published image

[.github/workflows/image.yml](.github/workflows/image.yml) builds the image on every push to
`main`, on `v*` tags and weekly (to pick up UBI security updates), and pushes it to
`ghcr.io/git001/fio-cloud-tests`. Pull requests only build it.

| Tag | Meaning |
|---|---|
| `3.43` | fio version, rolling: latest build from `main` |
| `3.43-<sha>` | fixed build of one commit |
| `latest` | latest build from `main` |
| `1.2.3` | from git tag `v1.2.3` |

A `v*` tag also creates a GitHub release. Its changelog lists the commits since the
previous `v*` tag, grouped into Features (`feat:`), Fixes (`fix:`) and Other, followed by
the image digest, the verification commands and the SBOM as an attached file. Tags with
a suffix such as `v1.2.0-rc1` become pre-releases.

Each pushed image carries an SBOM and SLSA provenance (BuildKit, in the image index), GitHub
artifact attestations for both, and a keyless cosign signature. A Trivy scan reports HIGH and
CRITICAL findings under Security -> Code scanning. To verify an image:

```sh
gh attestation verify oci://ghcr.io/git001/fio-cloud-tests:3.43 --owner git001
cosign verify ghcr.io/git001/fio-cloud-tests:3.43 \
  --certificate-identity-regexp '^https://github.com/git001/fio-cloud-tests/\.github/workflows/image\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

### Running on Kubernetes / OpenShift

- Runs under `restricted-v2` with a random UID and GID 0.
- Engines are `psync` and `libaio` only: io_uring is blocked by the RuntimeDefault seccomp profile.
- EL base instead of Debian: the libaio in Debian trixie calls `io_pgetevents`, which
  seccomp blocks as well.
- Manifests: [kubernetes/compare-job.yaml](kubernetes/compare-job.yaml), StorageClasses for
  [Google](kubernetes/storageclasses-google.yaml) and [Azure](kubernetes/storageclasses-azure.yaml).

### Downloading results

[kubernetes/results-deployment.yaml](kubernetes/results-deployment.yaml) runs an idle pod
(`sleep infinity`) that mounts the `fio-results` PVC. The image contains `rsync` and `tar`:

```sh
oc apply -f kubernetes/results-deployment.yaml
POD=$(oc get pod -l app=fio-results -o jsonpath='{.items[0].metadata.name}')
oc rsync "$POD":/results/ ./results/   # incremental; uses tar if rsync is missing locally
oc cp "$POD":/results ./results        # alternative, tar only
```

The PVC is ReadWriteOnce. While the Job is still running, the pod has to be scheduled on
the Job's node; a preferred pod affinity to the Job pod takes care of that. After the
Job has finished, any node works. Scale the Deployment to 0 or delete it before the
next comparison run if the Job could land on another node.
