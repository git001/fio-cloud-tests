# Build fio from the upstream release tag (there is no official fio image).
# Build:  podman build -t fio-cloud-tests:3.43 .
#
# EL base instead of Debian: libaio 0.3.113 (Debian trixie) calls io_pgetevents, which
# the default seccomp profile of CRI-O/podman rejects with EPERM -> libaio jobs abort.
# EL9/EL10 ship libaio 0.3.111 (io_getevents, allowed).
# io_uring is blocked under RuntimeDefault as well, so it is not used.
# EL=10 (default) or EL=9:  podman build --build-arg EL=9 -t fio-cloud-tests:3.43-el9 .
ARG EL=10
FROM quay.io/centos/centos:stream${EL} AS build
ARG FIO_VERSION=3.43
RUN dnf -y install gcc make libaio-devel zlib-devel tar gzip \
 && dnf clean all
RUN curl -fsSL "https://github.com/axboe/fio/archive/refs/tags/fio-${FIO_VERSION}.tar.gz" | tar xz \
 && cd "fio-fio-${FIO_VERSION}" \
 && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" \
 && make install

FROM registry.access.redhat.com/ubi${EL}/ubi-minimal:latest
RUN microdnf -y install libaio zlib jq util-linux bash findutils tar rsync \
 && microdnf clean all
COPY --from=build /usr/local/bin/fio /usr/local/bin/fio
WORKDIR /fio
COPY jobs/ ./jobs/
COPY report/ ./report/
COPY run.sh ./run.sh
# OpenShift runs with a random UID and GID 0 -> group 0 needs write access
RUN chmod +x run.sh && fio --version \
 && mkdir -p /data /results \
 && chgrp -R 0 /data /results && chmod -R g=u /data /results
USER 1001
ENTRYPOINT ["/fio/run.sh"]
