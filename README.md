# Inference Demo

Companion repository for the DevOps Toolkit series on running LLM inference on Kubernetes.

Each episode has a tag. Check out the tag for the episode you are watching, and the setup below reconstitutes exactly that state.

## Setup

```sh
git clone https://github.com/vfarcic/inference-demo

cd inference-demo
```

> Watch [Nix for Everyone: Unleash Devbox for Simplified Development](https://youtu.be/WiFLtcBvGMU) if you are not familiar with Devbox. Alternatively, you can skip Devbox and install all the tools listed in `devbox.json` yourself.

```sh
devbox shell
```

> The setup currently works only with Google Cloud. Support for AWS and Azure is not implemented yet.

```sh
gcloud auth login

chmod +x dot.nu

./dot.nu setup

source .env
```

The setup creates a **new Google Cloud project** named `dot-<timestamp>`, links it to your billing account, and builds the cluster inside it. Destroying removes the whole project, so nothing is left behind. If you have more than one billing account, pass `--billing-account`.

## Cluster layout

Two node pools:

* **General pool** runs system workloads. Flux, and later the observability stack and admission policies.
* **GPU pool** is tainted with `nvidia.com/gpu=present:NoSchedule` so only inference workloads land on it. It can be recreated or scaled to zero without disturbing anything else.

That split matters. Comparing inference engines fairly means recreating the GPU node between runs, so that a warm host page cache does not make the second engine look like it loads faster than the first.

## Destroy

```sh
./dot.nu destroy
```

This deletes the cluster and then the project that was created during setup.
