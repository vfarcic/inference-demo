#!/usr/bin/env nu

source scripts/kubernetes.nu
source scripts/common.nu
source scripts/flux.nu
source scripts/ingress.nu
source scripts/openai-load.nu
source scripts/keda.nu

# Each episode of the series gets its own `setup` and `destroy` subcommand.
# Once an episode is published its command is frozen, since the video shows it.
# Later episodes add new subcommands that build on the earlier ones instead of
# changing them.

const CLUSTER_NAME = "inference"
const ZONE = "us-east1-b"
const AWS_ZONE = "us-east-1d"
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
# The autoscaling episode is the one that lets the pool empty out. Zero is the
# point of the episode, and two is what a second replica needs, since one L4
# holds exactly one copy of the model.
const AUTOSCALING_GPU_MIN_NODES = 0
const AUTOSCALING_GPU_MAX_NODES = 2

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
    --gpu-min-nodes = -1      # Smallest GPU pool size. Defaults to the series value
    --gpu-max-nodes = -1      # Largest GPU pool size. Defaults to the series value
] {

    if not ($provider in ["google" "aws"]) {
        print $"(ansi red_bold)($provider)(ansi reset) is not supported yet. Use `google` or `aws`."
        exit 1
    }

    # Episodes one to three run a fixed single GPU node. The autoscaling episode
    # passes its own bounds. Defaulting to the constants keeps the published
    # commands behaving exactly as their videos show.
    let min_gpu = if $gpu_min_nodes < 0 { $GPU_MIN_NODES } else { $gpu_min_nodes }
    let max_gpu = if $gpu_max_nodes < 0 { $GPU_MAX_NODES } else { $gpu_max_nodes }

    rm --force .env

    # A leftover PROJECT_ID from a previous run would make the library reuse
    # that project instead of creating a fresh one.
    hide-env --ignore-errors PROJECT_ID

    # `gcloud auth login` for Google, AWS keys from the environment or a prompt.
    if $auth { main get creds $provider }

    let zone = if $provider == "aws" { $AWS_ZONE } else { $ZONE }

    (
        main create kubernetes $provider --name $CLUSTER_NAME --auth false
            --billing-account $billing_account
            --min-nodes $MIN_NODES --max-nodes $MAX_NODES --node-size small
            --zone $zone
    )

    (
        main create gpu_nodes $provider --cluster-name $CLUSTER_NAME --zone $zone
            --min-nodes $min_gpu --max-nodes $max_gpu
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

# Creates the cluster used by the inference engine comparison episode
#
# Builds on the infrastructure introduced in the inference episode while giving
# this episode its own command, which can be frozen independently once published.
#
# Examples:
# > ./dot.nu setup engines google
# > ./dot.nu setup engines aws
def --env "main setup engines" [
    provider: string          # Cloud provider. `google` or `aws`
    --billing-account = ""    # Billing account to link. Auto-detected when empty
    --auth = true             # Whether to authenticate. Set to false if already logged in
] {

    (
        main setup inference $provider --billing-account $billing_account
            --auth $auth
    )

    kubectl apply --filename demo/ingress.yaml

}

# Creates the cluster used by the inference batching episode
#
# Builds on the common inference infrastructure while giving the batching
# episode its own command, which can be frozen independently once published.
#
# Examples:
# > ./dot.nu setup batching google
# > ./dot.nu setup batching aws
def --env "main setup batching" [
    provider: string          # Cloud provider. `google` or `aws`
    --billing-account = ""    # Billing account to link. Auto-detected when empty
    --auth = true             # Whether to authenticate. Set to false if already logged in
] {

    (
        main setup inference $provider --billing-account $billing_account
            --auth $auth
    )

    kubectl apply --filename demo/ingress.yaml

}

# Creates the cluster used by the inference autoscaling episode
#
# Builds on the common inference infrastructure, but lets the GPU pool empty
# out. The pool starts with one node and may drop to zero or grow to two, which
# is what makes both scale to zero and a second replica observable.
#
# Also installs KEDA and its HTTP add-on. KEDA is a controller, in the same
# category as Flux: setup puts it there, and the resources that steer it stay
# visible in the episode. On AWS the cluster autoscaler comes with it, because
# nothing on EKS resizes a node group otherwise.
#
# Examples:
# > ./dot.nu setup autoscaling google
# > ./dot.nu setup autoscaling aws
def --env "main setup autoscaling" [
    provider: string          # Cloud provider. `google` or `aws`
    --billing-account = ""    # Billing account to link. Auto-detected when empty
    --auth = true             # Whether to authenticate. Set to false if already logged in
] {

    (
        main setup inference $provider --billing-account $billing_account
            --auth $auth
            --gpu-min-nodes $AUTOSCALING_GPU_MIN_NODES
            --gpu-max-nodes $AUTOSCALING_GPU_MAX_NODES
    )

    main apply keda

    if $provider == "aws" {
        main apply cluster_autoscaler --cluster-name $CLUSTER_NAME
    }

    # `main setup inference` writes INGRESS_HOST to `.env` but cannot export it
    # into this process, so read it back rather than asking for a second call.
    let ingress_host = (
        open .env
            | lines
            | where ($it | str starts-with "export INGRESS_HOST=")
            | first
            | split row "="
            | last
            | str trim
    )

    main generate autoscaling --host $ingress_host

    kubectl apply --filename demo/ingress.yaml

    # The always-on server everything in the episode is measured against. One
    # replica, weights pulled from Hugging Face on every start, no autoscaler
    # involved yet.
    kubectl apply --filename demo/autoscaling-vllm.yaml

    (
        kubectl --namespace inference rollout status deployment/vllm
            --timeout 45m
    )

    let response = (
        curl --fail --silent --show-error
            --header "Content-Type: application/json"
            --data-binary "@demo/batching-request.json"
            $"http://silly-model.($ingress_host)/v1/chat/completions"
        | from json
    )

    if (($response | get choices? | default [] | length) == 0) {
        print $"(ansi red_bold)The warm-up request did not return a completion.(ansi reset)"
        exit 1
    }

    print $"(ansi green_bold)The always-on server is ready and warm.(ansi reset)"

}

# Makes one inference engine the active server for Qwen3-8B
#
# Removes the current serving workload, recreates the GPU node to clear its host
# cache, deploys the requested engine, waits for the model, and warms it once.
# The measured load test remains a separate, visible command.
#
# Examples:
# > ./dot.nu use engine ollama-default aws
# > ./dot.nu use engine vllm-default google
def --env "main use engine" [
    engine: string            # Engine configuration. `ollama-default` or `vllm-default`
    provider: string          # Cloud provider. `google` or `aws`
] {

    if not ($provider in ["google" "aws"]) {
        print $"(ansi red_bold)($provider)(ansi reset) is not supported. Use `google` or `aws`."
        exit 1
    }

    if not ($engine in ["ollama-default" "vllm-default"]) {
        print $"(ansi red_bold)($engine)(ansi reset) is not supported. Use `ollama-default` or `vllm-default`."
        exit 1
    }

    if not ("INGRESS_HOST" in $env) {
        print $"(ansi red_bold)INGRESS_HOST is not set(ansi reset). Execute `source .env` first."
        exit 1
    }

    (
        kubectl --namespace inference delete deployment
            --selector app=silly-model --ignore-not-found=true --wait=true
    )
    (
        kubectl --namespace inference delete service
            --selector app=silly-model --ignore-not-found=true
    )

    let zone = if $provider == "aws" { $AWS_ZONE } else { $ZONE }
    (
        main recreate gpu_nodes $provider --cluster-name $CLUSTER_NAME
            --zone $zone --min-nodes $GPU_MIN_NODES
            --max-nodes $GPU_MAX_NODES
    )

    kubectl apply --filename $"demo/($engine).yaml"

    let deployment = if $engine == "ollama-default" { "ollama" } else { "vllm" }
    (
        kubectl --namespace inference rollout status
            $"deployment/($deployment)" --timeout 45m
    )

    if $engine == "ollama-default" {
        (
            kubectl --namespace inference exec deployment/ollama
                -- ollama pull qwen3:8b
        )
        (
            kubectl --namespace inference exec deployment/ollama
                -- ollama cp qwen3:8b qwen3-8b
        )
    }

    let response = (
        curl --fail --silent --show-error
            --header "Content-Type: application/json"
            --data-binary "@demo/request.json"
            $"http://silly-model.($env.INGRESS_HOST)/v1/chat/completions"
        | from json
    )

    if (($response | get choices? | default [] | length) == 0) {
        print $"(ansi red_bold)The warm-up request did not return a completion.(ansi reset)"
        exit 1
    }

    print $"(ansi green_bold)($engine) is ready and warm.(ansi reset)"

}

# Makes one batching configuration the active Qwen3-8B server
#
# Removes a different active engine, ensures Ollama model storage exists,
# deploys the requested configuration, waits for the model, and warms it once.
# Measured requests remain separate, visible manuscript commands.
#
# Examples:
# > ./dot.nu use batching ollama-one aws
# > ./dot.nu use batching ollama-four google
# > ./dot.nu use batching vllm-four aws
def --env "main use batching" [
    configuration: string     # `ollama-one`, `ollama-four`, or `vllm-four`
    provider: string          # Cloud provider. `google` or `aws`
] {

    if not ($provider in ["google" "aws"]) {
        print $"(ansi red_bold)($provider)(ansi reset) is not supported. Use `google` or `aws`."
        exit 1
    }

    let configurations = ["ollama-one" "ollama-four" "vllm-four"]
    if not ($configuration in $configurations) {
        print $"(ansi red_bold)($configuration)(ansi reset) is not supported. Use `ollama-one`, `ollama-four`, or `vllm-four`."
        exit 1
    }

    if not ("INGRESS_HOST" in $env) {
        print $"(ansi red_bold)INGRESS_HOST is not set(ansi reset). Execute `source .env` first."
        exit 1
    }

    let deployment = if ($configuration | str starts-with "ollama") {
        "ollama"
    } else {
        "vllm"
    }
    let previous_deployment = if $deployment == "ollama" { "vllm" } else { "ollama" }
    (
        kubectl --namespace inference delete $"deployment/($previous_deployment)"
            --ignore-not-found=true --wait=true
    )

    if $deployment == "ollama" {
        kubectl apply --filename demo/ollama-models.yaml
    }

    kubectl apply --filename $"demo/($configuration).yaml"

    (
        kubectl --namespace inference rollout status
            $"deployment/($deployment)" --timeout 45m
    )

    if $deployment == "ollama" {
        (
            kubectl --namespace inference exec deployment/ollama
                -- ollama pull qwen3:8b-fp16
        )
        (
            kubectl --namespace inference exec deployment/ollama
                -- ollama cp qwen3:8b-fp16 qwen3-8b
        )
    }

    let response = (
        curl --fail --silent --show-error
            --header "Content-Type: application/json"
            --data-binary "@demo/batching-request.json"
            $"http://silly-model.($env.INGRESS_HOST)/v1/chat/completions"
        | from json
    )

    if (($response | get choices? | default [] | length) == 0) {
        print $"(ansi red_bold)The warm-up request did not return a completion.(ansi reset)"
        exit 1
    }

    print $"(ansi green_bold)($configuration) is ready and warm.(ansi reset)"

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

# Writes the two manifests that put the interceptor in front of the model
#
# Both need the load balancer address, which only exists once the cluster does,
# so they are generated rather than committed, exactly like demo/ingress.yaml.
#
# The Ingress lives in the `keda` namespace because an Ingress can only name a
# Service in its own namespace, and the interceptor proxy runs there. The
# InterceptorRoute lives next to the model it scales.
#
# Examples:
# > ./dot.nu generate autoscaling
def "main generate autoscaling" [
    --name = "silly-model",   # Name of the Service and host prefix
    --port = 8000,            # Port the model Service listens on
    --class = "traefik",      # Ingress class
    --concurrency = 16,       # In-flight requests per replica the plain route targets
    --request-rate = 10,      # Requests per second per replica the placeholder route targets
    --host = ""               # Ingress host. Falls back to $INGRESS_HOST
] {

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
            namespace: keda
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
                                name: "keda-add-ons-http-interceptor-proxy"
                                port: { number: 8080 }
                            }
                        }
                    }]
                }
            }]
        }
    } | to yaml | save demo/autoscaling-ingress.yaml --force

    {
        apiVersion: http.keda.sh/v1beta1
        kind: InterceptorRoute
        metadata: {
            name: vllm
            namespace: inference
        }
        spec: {
            target: {
                service: $name
                port: $port
            }
            rules: [{
                hosts: [$"($name).($ingress_host)"]
            }]
            scalingMetric: {
                concurrency: {
                    targetValue: $concurrency
                }
            }
        }
    } | to yaml | save demo/autoscaling-route.yaml --force

    # Same route with a placeholder response. Without one the interceptor holds
    # the connection open for as long as the cold start takes; with one it
    # answers immediately and lets the caller decide whether to wait.
    #
    # The scaling metric has to change with it, and this is not optional.
    # `concurrency` counts requests that are in flight, and a placeholder is
    # answered in under a second, so concurrency never leaves zero, KEDA never
    # activates, and every caller gets a 503 forever while the model stays
    # asleep. Verified on 2026-09-03: ten requests, ten 503s, no Pod. Counting
    # requests instead of in-flight time is what makes the wake-up survive
    # answering immediately.
    {
        apiVersion: http.keda.sh/v1beta1
        kind: InterceptorRoute
        metadata: {
            name: vllm
            namespace: inference
        }
        spec: {
            target: {
                service: $name
                port: $port
            }
            rules: [{
                hosts: [$"($name).($ingress_host)"]
            }]
            scalingMetric: {
                requestRate: {
                    targetValue: $request_rate
                    window: "1m"
                    granularity: "1s"
                }
            }
            coldStart: {
                placeholder: {
                    response: {
                        statusCode: 503
                        headers: {
                            "Retry-After": "60"
                            "Content-Type": "application/json"
                        }
                        body: '{"error":{"message":"The model is starting up. Retry in about a minute.","type":"model_cold_start"}}'
                    }
                }
            }
        }
    } | to yaml | save demo/autoscaling-route-placeholder.yaml --force

    print $"Wrote (ansi yellow_bold)demo/autoscaling-ingress.yaml(ansi reset), (ansi yellow_bold)demo/autoscaling-route.yaml(ansi reset) and (ansi yellow_bold)demo/autoscaling-route-placeholder.yaml(ansi reset) for host ($name).($ingress_host)"

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

# Destroys the cluster created for the inference engine comparison episode
#
# Examples:
# > ./dot.nu destroy engines google
# > ./dot.nu destroy engines aws
def --env "main destroy engines" [
    provider: string   # Cloud provider. `google` or `aws`
] {

    main destroy inference $provider

}

# Destroys the cluster created for the inference batching episode
#
# Examples:
# > ./dot.nu destroy batching google
# > ./dot.nu destroy batching aws
def --env "main destroy batching" [
    provider: string   # Cloud provider. `google` or `aws`
] {

    if not ("KUBECONFIG" in $env) {
        $env.KUBECONFIG = $"($env.PWD)/kubeconfig-($CLUSTER_NAME).yaml"
    }

    # Release the claim before deleting it so the CSI controller can remove the
    # cloud disk while the cluster is still available.
    do --ignore-errors {
        (
            kubectl --namespace inference delete deployment ollama
                --ignore-not-found=true --wait=true
        )
    }

    # Delete the claim while the CSI controller is still available so its cloud
    # disk is not orphaned when the cluster disappears.
    do --ignore-errors {
        (
            kubectl --namespace inference delete pvc ollama-models
                --ignore-not-found=true --wait=true --timeout 10m
        )
    }

    main destroy inference $provider

}

# Destroys the cluster created for the inference autoscaling episode
#
# Examples:
# > ./dot.nu destroy autoscaling google
# > ./dot.nu destroy autoscaling aws
def --env "main destroy autoscaling" [
    provider: string   # Cloud provider. `google` or `aws`
] {

    if not ("KUBECONFIG" in $env) {
        $env.KUBECONFIG = $"($env.PWD)/kubeconfig-($CLUSTER_NAME).yaml"
    }

    # The ScaledObject would otherwise keep putting the Deployment back while
    # the disk is being released.
    do --ignore-errors {
        (
            kubectl --namespace inference delete scaledobject vllm
                --ignore-not-found=true
        )
    }

    do --ignore-errors {
        (
            kubectl --namespace inference delete deployment vllm
                --ignore-not-found=true --wait=true
        )
    }

    # Delete the claim while the CSI controller is still available so its cloud
    # disk is not orphaned when the cluster disappears.
    do --ignore-errors {
        (
            kubectl --namespace inference delete pvc model-weights
                --ignore-not-found=true --wait=true --timeout 10m
        )
    }

    main destroy inference $provider

}
