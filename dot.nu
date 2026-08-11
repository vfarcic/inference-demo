#!/usr/bin/env nu

source scripts/kubernetes.nu
source scripts/common.nu
source scripts/flux.nu

# Each episode of the series gets its own `setup` and `destroy` subcommand.
# Once an episode is published its command is frozen, since the video shows it.
# Later episodes add new subcommands that build on the earlier ones instead of
# changing them.

const CLUSTER_NAME = "inference"
const ZONE = "us-east1-b"
const MIN_NODES = 2
const MAX_NODES = 3
const GPU_MACHINE_TYPE = "g2-standard-8"
const GPU_ACCELERATOR = "nvidia-l4"
const GPU_MIN_NODES = 0
const GPU_MAX_NODES = 1

def main [] {}

# Creates the cluster used by the inference engine episode
#
# Two node pools. The general pool runs system workloads like Flux. The GPU pool
# is tainted so only inference workloads land on it, which means it can be
# recreated or scaled to zero without taking the rest of the cluster down.
#
# Examples:
# > ./dot.nu setup inference google
def --env "main setup inference" [
    provider: string          # Cloud provider. Only `google` is supported for now
    --billing-account = ""    # Billing account to link. Auto-detected when empty
] {

    if $provider != "google" {
        print $"(ansi red_bold)($provider)(ansi reset) is not supported yet. Use `google`."
        exit 1
    }

    rm --force .env

    # A leftover PROJECT_ID from a previous run would make the library reuse
    # that project instead of creating a fresh one.
    hide-env --ignore-errors PROJECT_ID

    (
        main create kubernetes google --name $CLUSTER_NAME --auth false
            --billing-account $billing_account
            --min-nodes $MIN_NODES --max-nodes $MAX_NODES --node-size small
    )

    (
        main create gpu_nodes google --cluster-name $CLUSTER_NAME --zone $ZONE
            --machine-type $GPU_MACHINE_TYPE --accelerator $GPU_ACCELERATOR
            --min-nodes $GPU_MIN_NODES --max-nodes $GPU_MAX_NODES
    )

    let branch = (git rev-parse --abbrev-ref HEAD | str trim)

    main apply flux --path kubernetes --git-ref $branch --git-ref-type branch

    main wait flux

    main print source

}

# Destroys the cluster created for the inference engine episode
#
# Deletes the cluster and the project that was created during setup.
#
# Examples:
# > ./dot.nu destroy inference google
def --env "main destroy inference" [
    provider: string   # Cloud provider. Only `google` is supported for now
] {

    if $provider != "google" {
        print $"(ansi red_bold)($provider)(ansi reset) is not supported yet. Use `google`."
        exit 1
    }

    if not ("PROJECT_ID" in $env) {
        print $"(ansi red_bold)PROJECT_ID is not set(ansi reset). Execute `source .env` first."
        exit 1
    }

    if not ("KUBECONFIG" in $env) {
        $env.KUBECONFIG = $"($env.PWD)/kubeconfig-($CLUSTER_NAME).yaml"
    }

    main destroy kubernetes google --name $CLUSTER_NAME

    main delete temp_files

}
