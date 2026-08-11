#!/usr/bin/env nu

source scripts/kubernetes.nu
source scripts/common.nu
source scripts/flux.nu

def main [] {}

# Creates the cluster used by the inference series
#
# The cluster has two node pools. The general pool runs system workloads like
# Flux and observability. The GPU pool is tainted so only inference workloads
# land on it, which means it can be recreated or scaled to zero without taking
# the rest of the cluster down.
#
# Examples:
# > ./dot.nu setup
# > ./dot.nu setup --gpu-max-nodes 2 --git-ref episode-1 --git-ref-type tag
def --env "main setup" [
    --provider = "google",              # Cloud provider. Only `google` is supported for now
    --name = "inference",               # Name of the cluster
    --billing-account = "",             # Billing account to link. Auto-detected when empty
    --zone = "us-east1-b",              # Zone the cluster and the GPU pool live in
    --min-nodes = 2,                    # Minimum number of general purpose nodes
    --max-nodes = 3,                    # Maximum number of general purpose nodes
    --gpu-machine-type = "g2-standard-8",  # Machine type for the GPU pool
    --gpu-accelerator = "nvidia-l4",    # Accelerator attached to each GPU node
    --gpu-min-nodes = 0,                # Minimum GPU nodes. Zero enables scale to zero
    --gpu-max-nodes = 1,                # Maximum GPU nodes
    --flux-enabled = true,              # Whether to install Flux
    --flux-sync = true,                 # Whether Flux syncs this repository
    --git-ref = "main",                 # Branch, tag, or commit Flux reconciles
    --git-ref-type = "branch"           # Type of the ref. `branch`, `tag`, or `commit`
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
        main create kubernetes google --name $name --auth false
            --billing-account $billing_account
            --min-nodes $min_nodes --max-nodes $max_nodes --node-size small
    )

    (
        main create gpu_nodes google --cluster-name $name --zone $zone
            --machine-type $gpu_machine_type --accelerator $gpu_accelerator
            --min-nodes $gpu_min_nodes --max-nodes $gpu_max_nodes
    )

    if $flux_enabled {
        (
            main apply flux --sync $flux_sync --path kubernetes
                --git-ref $git_ref --git-ref-type $git_ref_type
        )
    }

    main print source

}

# Destroys the cluster and removes generated files
#
# Examples:
# > ./dot.nu destroy
def --env "main destroy" [
    --provider = "google",   # Cloud provider. Only `google` is supported for now
    --name = "inference"     # Name of the cluster
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
        $env.KUBECONFIG = $"($env.PWD)/kubeconfig-($name).yaml"
    }

    main destroy kubernetes google --name $name

    main delete temp_files

}
