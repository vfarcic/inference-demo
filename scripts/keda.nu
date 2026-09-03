#!/usr/bin/env nu

# Installs KEDA and its HTTP add-on
#
# KEDA is the controller the autoscaling episode drives, in the same way Flux is
# the controller that delivers manifests. Installing it is plumbing, so setup
# does it. The resources that steer it stay visible in the manuscript.
#
# The HTTP add-on adds the interceptor proxy, which is the piece that makes
# scale from zero possible at all: something has to accept a request while there
# are no replicas to serve it.
#
# Examples:
# > main apply keda
def "main apply keda" [
    --version = "2.18.1"       # KEDA chart version
    --http-version = "0.15.0"  # HTTP add-on chart version
] {

    helm repo add kedacore https://kedacore.github.io/charts

    helm repo update

    (
        helm upgrade --install keda kedacore/keda
            --namespace keda --create-namespace
            --version $version --wait
    )

    # `responseHeaderTimeout` is the time the interceptor waits for the model to
    # answer once traffic is forwarded. The default is five minutes, which a
    # cold vLLM replica can exceed while it is still loading weights, so the
    # episode raises it rather than letting the wall show up as a 504 that has
    # nothing to do with the model.
    (
        helm upgrade --install http-add-on kedacore/keda-add-ons-http
            --namespace keda
            --version $http_version
            --set interceptor.responseHeaderTimeout=1800s
            --set interceptor.replicas.min=1
            --set interceptor.replicas.max=3
            --wait
    )

}

# Installs the Kubernetes Cluster Autoscaler on EKS
#
# Google runs the cluster autoscaler as part of the GKE control plane, so
# `--enable-autoscaling` on the node pool is all it takes there. On EKS nothing
# scales the node groups unless something is installed to do it, so the two
# providers only look the same after this runs.
#
# The node group's instance role already carries the autoscaler policy, granted
# by `iam.withAddonPolicies.autoScaler` when the group was created, so the
# controller needs no IRSA of its own.
#
# Examples:
# > main apply cluster_autoscaler --cluster-name inference
def "main apply cluster_autoscaler" [
    --cluster-name = "inference"  # Name of the EKS cluster
    --region = "us-east-1"        # Region the cluster lives in
    --version = "9.51.0"          # Chart version
] {

    helm repo add autoscaler https://kubernetes.github.io/autoscaler

    helm repo update

    (
        helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler
            --namespace kube-system
            --version $version
            --set $"autoDiscovery.clusterName=($cluster_name)"
            --set $"awsRegion=($region)"
            --set extraArgs.scale-down-unneeded-time=5m
            --set extraArgs.scale-down-delay-after-add=5m
            --set extraArgs.balance-similar-node-groups=false
            --wait
    )

}
