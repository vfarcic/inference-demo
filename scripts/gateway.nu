#!/usr/bin/env nu

# Installs the Gateway API and Inference Extension custom resources
#
# Two separate APIs, and the split matters. Gateway API is the general
# Kubernetes routing API. The Inference Extension adds `InferencePool`, which is
# the piece that lets a route point at a set of model servers with a picker in
# front rather than at a Service. The extension went to v1 in September 2025, so
# this is a stable API rather than an experiment.
#
# Examples:
# > main apply gateway_api
def "main apply gateway_api" [
    --version = "1.6.0"            # Gateway API release
    --inference-version = "1.5.0"  # Gateway API Inference Extension release
] {

    # `--force-conflicts` is not optional on GKE, and this is the one place the
    # two clouds are not the same. Google ships its own Gateway API CRDs managed
    # by kube-addon-manager, so a server-side apply of the upstream release
    # collides on `.spec.versions` and the bundle-version annotation and exits
    # non-zero. EKS has no built-in copy and does not care either way. The flag
    # is what agentgateway's own install page prescribes; its inference-routing
    # page omits it, which is how this was missed the first time.
    (
        kubectl apply --server-side --force-conflicts
            --filename $"https://github.com/kubernetes-sigs/gateway-api/releases/download/v($version)/standard-install.yaml"
    )

    (
        kubectl apply
            --filename $"https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v($inference_version)/manifests.yaml"
    )

}

# Installs the agentgateway control plane
#
# agentgateway rather than an Envoy-based gateway, and the reason is that the
# alternatives moved. kgateway deprecated its Envoy-based inference extension in
# v2.1, dropped it in v2.2, and its own migration guide says to install
# agentgateway and change the gateway class. This is where that capability went.
#
# `inferenceExtension.enabled` is what makes the control plane willing to accept
# an `InferencePool` as a backend. Without it the HTTPRoute stays unresolved and
# the failure reads like a bad reference rather than a missing feature.
#
# Examples:
# > main apply agentgateway
def "main apply agentgateway" [
    --version = "v1.5.0"  # agentgateway chart version
] {

    (
        helm upgrade --install agentgateway-crds
            oci://cr.agentgateway.dev/charts/agentgateway-crds
            --namespace agentgateway-system --create-namespace
            --version $version --wait
    )

    (
        helm upgrade --install agentgateway
            oci://cr.agentgateway.dev/charts/agentgateway
            --namespace agentgateway-system
            --version $version
            --set inferenceExtension.enabled=true
            --wait
    )

}
