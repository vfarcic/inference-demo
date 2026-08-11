#!/usr/bin/env nu

# Installs Flux and optionally configures it to sync a Git repository
#
# Examples:
# > main apply flux
# > main apply flux --git-ref episode-1 --git-ref-type tag --path kubernetes
# > main apply flux --git-url https://github.com/vfarcic/inference-demo --sync false
def "main apply flux" [
    --git-url = "",                 # Git repository to sync. Defaults to the `origin` remote of the current repo
    --git-ref = "main",             # Branch, tag, or commit to sync
    --git-ref-type = "branch",      # Type of the ref. Available options are `branch`, `tag`, and `commit`
    --path = "kubernetes",          # Path inside the repository that Flux reconciles
    --interval = "1m",              # Reconciliation interval
    --namespace = "flux-system",    # Namespace where Flux is installed
    --sync = true,                  # Whether to create the GitRepository and Kustomization resources
    --prune = true                  # Whether Flux deletes resources removed from Git
] {

    flux install --namespace $namespace

    if not $sync { return }

    let url = if $git_url == "" {
        git config --get remote.origin.url
    } else {
        $git_url
    }

    if $url == "" {
        print "Could not determine the Git URL. Use the --git-url argument."
        exit 1
    }

    let ref = match $git_ref_type {
        "branch" => { branch: $git_ref }
        "tag" => { tag: $git_ref }
        "commit" => { commit: $git_ref }
        _ => {
            print $"Unsupported --git-ref-type ($git_ref_type). Use `branch`, `tag`, or `commit`."
            exit 1
        }
    }

    mkdir flux

    {
        apiVersion: source.toolkit.fluxcd.io/v1
        kind: GitRepository
        metadata: {
            name: flux-system
            namespace: $namespace
        }
        spec: {
            interval: $interval
            url: $url
            ref: $ref
        }
    } | save flux/git-repository.yaml --force

    {
        apiVersion: kustomize.toolkit.fluxcd.io/v1
        kind: Kustomization
        metadata: {
            name: flux-system
            namespace: $namespace
        }
        spec: {
            interval: $interval
            path: $"./($path)"
            prune: $prune
            wait: true
            timeout: 10m
            sourceRef: {
                kind: GitRepository
                name: flux-system
            }
        }
    } | save flux/kustomization.yaml --force

    kubectl apply --filename flux/git-repository.yaml

    kubectl apply --filename flux/kustomization.yaml

}

# Waits until the Flux Kustomization finished reconciling
#
# Examples:
# > main wait flux
def "main wait flux" [
    --name = "flux-system",
    --namespace = "flux-system",
    --timeout = "10m"
] {

    (
        kubectl --namespace $namespace wait kustomization $name
            --for condition=Ready --timeout $timeout
    )

}

# Removes Flux and the resources it manages
#
# Examples:
# > main delete flux
def "main delete flux" [
    --namespace = "flux-system"
] {

    flux uninstall --namespace $namespace --silent

    rm --force --recursive flux

}
