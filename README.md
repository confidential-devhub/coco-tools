# Introduction

Container image with confidential containers (CoCo) related tools.

## Build

```sh
export image=quay.io/<user>/coco-tools
podman build -t $image -f Containerfile .
```

## Tools

### Veritas

Computes RVPS reference values for Trustee. Requires a registry pull secret.

```sh
podman run --rm -v /path/to/pull-secret.json:/tmp/auth.json:z \
  $image veritas --platform baremetal --tee tdx \
  --ocp-version 4.20.15 --authfile /tmp/auth.json
```

See [veritas](https://github.com/confidential-devhub/veritas) for full usage.
