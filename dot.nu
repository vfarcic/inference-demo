#!/usr/bin/env nu

source scripts/kubernetes.nu
source scripts/common.nu
source scripts/flux.nu
source scripts/ingress.nu

# Each episode of the series gets its own `setup` and `destroy` subcommand.
# Once an episode is published its command is frozen, since the video shows it.
# Later episodes add new subcommands that build on the earlier ones instead of
# changing them.

const CLUSTER_NAME = "inference"
const ZONE = "us-east1-b"
const MIN_NODES = 2
const MAX_NODES = 3
# Machine type is resolved per provider by `main create gpu_nodes`: a single
# NVIDIA L4 on both Google and AWS.
# Starts at 1, not 0. Scaling from zero works, but it means the GPU node is
# absent right after setup and the first demo command waits minutes for one.
# Recreating the node between engines is done deliberately instead of relying on
# autoscaler timing. Scale to zero is episode 5's subject.
const GPU_MIN_NODES = 1
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
# > ./dot.nu setup inference aws
def --env "main setup inference" [
    provider: string          # Cloud provider. `google` or `aws`
    --billing-account = ""    # Billing account to link. Auto-detected when empty
    --auth = true             # Whether to authenticate. Set to false if already logged in
] {

    if not ($provider in ["google" "aws"]) {
        print $"(ansi red_bold)($provider)(ansi reset) is not supported yet. Use `google` or `aws`."
        exit 1
    }

    rm --force .env

    # A leftover PROJECT_ID from a previous run would make the library reuse
    # that project instead of creating a fresh one.
    hide-env --ignore-errors PROJECT_ID

    # `gcloud auth login` for Google, AWS keys from the environment or a prompt.
    if $auth { main get creds $provider }

    (
        main create kubernetes $provider --name $CLUSTER_NAME --auth false
            --billing-account $billing_account
            --min-nodes $MIN_NODES --max-nodes $MAX_NODES --node-size small
    )

    (
        main create gpu_nodes $provider --cluster-name $CLUSTER_NAME --zone $ZONE
            --min-nodes $GPU_MIN_NODES --max-nodes $GPU_MAX_NODES
    )

    let ingress = (main apply ingress traefik --provider $provider)

    main generate ingress --host $ingress.host

    let branch = (git rev-parse --abbrev-ref HEAD | str trim)

    main apply flux --path kubernetes --git-ref $branch --git-ref-type branch

    main wait flux

    # Runs `nvidia-smi` once and exits, so the episode can show what the card
    # actually reports without spending screen time on applying a Pod.
    kubectl apply --filename demo/gpu-info.yaml

    main print source

}

# Writes demo/ingress.yaml with the current load balancer address
#
# The nip.io host encodes the load balancer IP, which is only known once the
# cluster exists, so the Ingress is generated rather than committed. Setup calls
# this; the manifest is applied during the demo so that exposing the model stays
# a visible step.
#
# Examples:
# > ./dot.nu generate ingress
def "main generate ingress" [
    --name = "silly-model",   # Name of the Ingress, Service, and host prefix
    --port = 8000,            # Port the Service listens on
    --class = "traefik",      # Ingress class
    --host = ""               # Ingress host. Falls back to $INGRESS_HOST
] {

    # `main get ingress` writes INGRESS_HOST to the .env file but cannot set it
    # in the running process, so setup has to pass the value straight through.
    mut ingress_host = $host

    if $ingress_host == "" {
        if not ("INGRESS_HOST" in $env) {
            print $"(ansi red_bold)INGRESS_HOST is not set(ansi reset). Pass --host, or execute `source .env` first."
            exit 1
        }
        $ingress_host = $env.INGRESS_HOST
    }

    {
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata: {
            name: $name
            namespace: inference
        }
        spec: {
            ingressClassName: $class
            rules: [{
                host: $"($name).($ingress_host)"
                http: {
                    paths: [{
                        path: "/"
                        pathType: Prefix
                        backend: {
                            service: {
                                name: $name
                                port: { number: $port }
                            }
                        }
                    }]
                }
            }]
        }
    } | to yaml | save demo/ingress.yaml --force

    print $"Wrote (ansi yellow_bold)demo/ingress.yaml(ansi reset) for host ($name).($ingress_host)"

}

# Destroys the cluster created for the inference engine episode
#
# Deletes the cluster and everything setup created around it.
#
# Examples:
# > ./dot.nu destroy inference google
# > ./dot.nu destroy inference aws
def --env "main destroy inference" [
    provider: string   # Cloud provider. `google` or `aws`
] {

    if not ($provider in ["google" "aws"]) {
        print $"(ansi red_bold)($provider)(ansi reset) is not supported yet. Use `google` or `aws`."
        exit 1
    }

    # Only Google has a project to delete. AWS keeps its state in the eksctl
    # config file that setup wrote.
    if ($provider == "google") and (not ("PROJECT_ID" in $env)) {
        print $"(ansi red_bold)PROJECT_ID is not set(ansi reset). Execute `source .env` first."
        exit 1
    }

    if not ("KUBECONFIG" in $env) {
        $env.KUBECONFIG = $"($env.PWD)/kubeconfig-($CLUSTER_NAME).yaml"
    }

    # The load balancer behind the Ingress is created by the cloud controller
    # rather than by the cluster tooling, so deleting the cluster leaves it
    # running and paid for. On AWS it also holds network interfaces in the
    # subnets, which blocks the VPC from being deleted at all. Remove the
    # Service first, while the cluster is still alive to process it.
    do --ignore-errors { main delete ingress traefik }

    main destroy kubernetes $provider --name $CLUSTER_NAME

    main delete temp_files

}
