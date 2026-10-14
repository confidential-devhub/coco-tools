FROM quay.io/fedora/fedora:44 AS build-container

RUN dnf install -y \
    git \
    tss2-devel \
    protobuf-compiler \
    tpm2-tss-devel \
    perl-core \
    cmake \
    clang


## Install Rust toolchain
# COCO_RUST_VERSION: default toolchain, used by snpguest (MSRV 1.86), snphost
#   (MSRV 1.85) and tdx-measure, which do not pin one. guest-components,
#   trustee and kata-containers ship a rust-toolchain.toml and rustup installs
#   the pinned toolchain automatically when cargo runs inside their trees.
ARG COCO_RUST_VERSION=1.90.0
ENV COCO_RUST_VERSION=${COCO_RUST_VERSION}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${COCO_RUST_VERSION}
ENV PATH=$PATH:/root/.cargo/bin

# Directory to keep all the tools
RUN mkdir /tools

# Copy source trees from submodules instead of cloning, so this image uses
# the same downstream sources as Containerfile.ubi
COPY snpguest /workdir/snpguest
COPY snphost /workdir/snphost
COPY guest-components /workdir/guest-components
COPY trustee /workdir/trustee
COPY kata-containers /workdir/kata-containers
COPY tdx-measure /workdir/tdx-measure

# Build different binaries

# Build snpguest
WORKDIR /workdir/snpguest
RUN cargo build -r
RUN cp target/release/snpguest /tools/snpguest

# Build snphost
WORKDIR /workdir/snphost
RUN cargo build -r
RUN cp target/release/snphost /tools/snphost

# Build trustee-attester
WORKDIR /workdir/guest-components/attestation-agent/kbs_protocol
# all-attesters minus nvidia-attester, which needs the NVIDIA attestation C++ SDK (libnvat)
RUN cargo build -p kbs_protocol --bin trustee-attester --locked --release --no-default-features --features background_check,passport,openssl,tdx-attester,sgx-attester,az-snp-vtpm-attester,az-tdx-vtpm-attester,snp-attester,csv-attester,hygon-dcu-attester,cca-attester,se-attester,tpm-attester,nvidia-dpu-attester,bin
RUN cp /workdir/guest-components/target/release/trustee-attester /tools/trustee-attester

# oneshot CDH
WORKDIR /workdir/guest-components/confidential-data-hub/hub
RUN cargo build --release --no-default-features --features "bin,ttrpc,kbs" --bin ttrpc-cdh
RUN cp /workdir/guest-components/target/release/ttrpc-cdh /tools/ttrpc-cdh

# sealed secret client
WORKDIR /workdir/guest-components/confidential-data-hub/hub
RUN cargo build --release --no-default-features --features "bin,cli" --bin secret
RUN cp /workdir/guest-components/target/release/secret /tools/secret

# Build kbs-client
WORKDIR /workdir/trustee/tools/kbs-client
RUN cargo build -p kbs-client --locked --release --features "all-attesters"
RUN cp /workdir/trustee/target/release/kbs-client /tools/kbs-client

# genpolicy
WORKDIR /workdir/kata-containers/src/tools/genpolicy
RUN make LIBC=gnu
RUN cp /workdir/kata-containers/target/$(uname -m)-unknown-linux-gnu/release/genpolicy /tools/genpolicy

# Build tdx-measure (used by veritas for TDX RTMR computation)
WORKDIR /workdir/tdx-measure/cli
RUN cargo build -r
RUN cp target/release/tdx-measure /tools/tdx-measure

FROM quay.io/fedora/fedora:44 AS tools-container

RUN dnf install -y tpm2-tss openssl-libs libgcc zlib-ng-compat skopeo

ARG COSIGN_VERSION=v3.0.6
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -sLo /usr/local/bin/cosign \
        "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${ARCH}" && \
    chmod +x /usr/local/bin/cosign

# Install tdx deps from custom copr for now
RUN dnf install -y tdx-attest-libs

# Python + oc CLI for veritas
RUN dnf install -y python3 python3-pip git cpio
RUN curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar xzf - -C /usr/local/bin oc

# Install PCS Client from a pinned upstream revision with the local patch.
ARG PCSCLIENT_REF=64b78f3766e7196d3d2c60e401540f0f853b2deb
ARG PCSCLIENT_SHA256=7a383de6d019688c91e8c02bf19270f22e4750ae01992c7ff86afd61bbbd6a62
COPY pcsclient-package /tmp/pcsclient-package
RUN curl -sL \
        "https://github.com/intel/confidential-computing.tee.dcap/archive/${PCSCLIENT_REF}.tar.gz" \
        -o /tmp/pcsclient.tar.gz && \
    echo "${PCSCLIENT_SHA256}  /tmp/pcsclient.tar.gz" | sha256sum -c - && \
    mkdir /tmp/pcsclient-source && \
    tar xzf /tmp/pcsclient.tar.gz --strip-components=1 -C /tmp/pcsclient-source && \
    cd /tmp/pcsclient-source && \
    git apply --unidiff-zero /tmp/pcsclient-package/serialize-identities.patch && \
    cp /tmp/pcsclient-package/pyproject.toml tools/PcsClientTool/ && \
    pip install --no-cache-dir tools/PcsClientTool

# Install veritas with SNP and TDX support.
# Base install covers TDX (uses tdx-measure binary); [snp] extra adds sev-snp-measure for SNP
ARG VERITAS_REF=v0.1.2
RUN pip install --no-cache-dir \
    "veritas[snp] @ git+https://github.com/confidential-devhub/veritas.git@${VERITAS_REF}"

COPY --from=build-container /tools /tools
ENV PATH="/tools:${PATH}"
