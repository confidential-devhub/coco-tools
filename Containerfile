#FROM registry.access.redhat.com/ubi9/ubi:latest
FROM quay.io/fedora/fedora:43 AS build-container

RUN dnf install -y \
    git \
    tss2-devel \
    protobuf-compiler \
    tpm2-tss-devel \
    perl-core \
    cmake \
    clang

# Install tdx deps from custom copr for now
RUN dnf install -y 'dnf-command(copr)' && \
    dnf copr enable -y berrange/sgx-ng && \
    dnf install -y tdx-attest-devel sgx-devel

## Install rust
ARG COCO_RUST_VERSION=stable
ENV COCO_RUST_VERSION=${COCO_RUST_VERSION}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${COCO_RUST_VERSION}
ENV PATH=$PATH:/root/.cargo/bin

# Directory to keep all the tools
RUN mkdir /tools

# Build different binaries
# Build trustee-attester

ARG GUEST_COMPONENTS_REF=v0.11.0
ENV GUEST_COMPONENTS_REF=${GUEST_COMPONENTS_REF}
RUN git clone --single-branch --branch ${GUEST_COMPONENTS_REF} https://github.com/confidential-containers/guest-components.git
# cargo build -p kbs_protocol --bin trustee-attester --locked --release --no-default-features --features background_check,passport,openssl,az-snp-vtpm-attester,az-tdx-vtpm-attester,snp-attester,bi
RUN cd /guest-components/attestation-agent/kbs_protocol/ && \
    cargo build -p kbs_protocol --bin trustee-attester --locked --release --no-default-features --features background_check,passport,openssl,all-attesters,bin
# Copy trustee-attester
RUN cp /guest-components/target/release/trustee-attester /tools/trustee-attester

# oneshot CDH
RUN cd /guest-components/confidential-data-hub/hub && \
    cargo build --release --no-default-features --features "bin,ttrpc,kbs" --bin ttrpc-cdh
# Copy oneshot CDH
RUN cp /guest-components/target/release/ttrpc-cdh /tools/ttrpc-cdh

# sealed secret client
RUN cd /guest-components/confidential-data-hub/hub && \
    cargo build --release -p confidential-data-hub --bin secret
# Copy sealed secret client
RUN cp /guest-components/target/release/secret /tools/secret


# Build kbs-client
ARG TRUSTEE_REF=v0.11.0
ENV TRUSTEE_REF=${TRUSTEE_REF}

RUN git clone --single-branch --branch ${TRUSTEE_REF} https://github.com/confidential-containers/trustee.git
# cargo build -p kbs-client --locked --release --no-default-features --features "kbs_protocol/background_check,kbs_protocol/passport,kbs_protocol/openssl,kbs_protocol/az-snp-vtpm-attester,kbs_protocol/az-tdx-vtpm-attester,kbs_protocol/snp-attester,kbs_protocol/tdx-attester"
RUN cd /trustee/tools/kbs-client/ && \
    cargo build -p kbs-client --locked --release --no-default-features --features "sample_only,all-attesters"
# Copy kbs-client
RUN cp /trustee/target/release/kbs-client /tools/kbs-client


# genpolicy
ARG KATA_REF=3.13.0
ENV KATA_REF=${KATA_REF}
ARG KATA_RUST_VERSION=1.75.0
ENV KATA_RUST_VERSION=${KATA_RUST_VERSION}
RUN rustup default ${KATA_RUST_VERSION}
RUN git clone --single-branch --branch ${KATA_REF} https://github.com/kata-containers/kata-containers.git
RUN cd /kata-containers/src/tools/genpolicy && \
    COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null) && \
    sed -e "s|@COMMIT_INFO@|$COMMIT_HASH|g" "src/version.rs.in" > "src/version.rs" && \
    cargo build --release
# Copy genpolicy
RUN cp /kata-containers/src/tools/genpolicy/target/release/genpolicy /tools/genpolicy

#FROM registry.access.redhat.com/ubi9/ubi:latest
FROM quay.io/fedora/fedora:43 as tools-container

RUN dnf install -y tpm2-tss openssl-libs libgcc zlib-ng-compat

# Install tdx deps from custom copr for now
RUN dnf install -y 'dnf-command(copr)' && \
    dnf copr enable -y berrange/sgx-ng && \
    dnf install -y tdx-attest-libs

COPY --from=build-container /tools /tools
ENV PATH="/tools:${PATH}"
