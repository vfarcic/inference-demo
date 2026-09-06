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

# Waits until the load balancer's security groups are gone, on AWS
#
# This exists because of a failure that hides itself. Deleting a `Gateway`
# removes the object at once, while the Service it created, the load balancer
# behind that Service, and the security group the cloud controller made for the
# balancer are all still being released. Tear the cluster down inside that window
# and eksctl deletes what it can, fails on the VPC because a `k8s-elb-*` group is
# still attached to it, and leaves the CloudFormation stack in DELETE_FAILED.
#
# Nothing then shows up in a list of clusters, instances or load balancers, so
# the account looks empty, and the next `setup` dies on AlreadyExistsException
# with no mention of load balancers anywhere in the error.
#
# Waiting on the Service is only a proxy for the controller having finished. This
# waits on the thing that actually blocks the VPC, and removes it if the
# controller does not, which turns a race into a decision.
#
# Examples:
# > main wait elb_security_groups --cluster-name inference
def "main wait elb_security_groups" [
    --cluster-name = "inference"  # Name of the EKS cluster
    --region = "us-east-1"        # Region the cluster lives in
    --timeout-seconds = 300       # How long to let the controller do it itself
] {

    let vpc_result = (
        aws eks describe-cluster --name $cluster_name --region $region
            --query "cluster.resourcesVpcConfig.vpcId" --output text
        | complete
    )

    # No cluster means nothing to wait for.
    if $vpc_result.exit_code != 0 {
        return
    }

    let vpc = ($vpc_result.stdout | str trim)
    if ($vpc == "") or ($vpc == "None") {
        return
    }

    mut remaining = ""
    mut waited = 0

    loop {

        let groups = (
            aws ec2 describe-security-groups --region $region
                --filters $"Name=vpc-id,Values=($vpc)"
                --query "SecurityGroups[?starts_with(GroupName,'k8s-elb')].GroupId"
                --output text
            | complete
        )

        $remaining = (if $groups.exit_code == 0 { $groups.stdout | str trim } else { "" })

        if $remaining == "" {
            print $"(ansi green_bold)Load balancer security groups released.(ansi reset)"
            break
        }

        if $waited >= $timeout_seconds {
            print $"(ansi yellow_bold)Still holding the VPC after ($waited)s. Removing them.(ansi reset)"
            break
        }

        sleep 10sec
        $waited = $waited + 10

    }

    # Anything left after the wait is an orphan the controller is not going to
    # collect. Delete it here, while there is still something that knows why it
    # matters, rather than leaving it to fail the VPC deletion silently.
    if $remaining != "" {
        for id in ($remaining | split row -r '\s+') {
            do --ignore-errors {
                aws ec2 delete-security-group --region $region --group-id $id
            }
        }
    }

}
