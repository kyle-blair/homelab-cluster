# homelab-cluster

A declarative, version-controlled kubernetes cluster managed using continuous delivery.

## prerequisites

I plan to pare down these requirements and/or provide automated, sensible defaults.

| dependency | purpose | value |
| --- | --- | --- |
| Podman | Runs Kubespray in a container while bootstrapping the kubernetes cluster. | Hides most of Kubespray's local setup complexity and keeps the bootstrap environment reproducible. |
| At least one computer with a wired network connection, passwordless `ssh` access, and passwordless `sudo` access | The kubernetes cluster deploys to and runs on the provided host(s). | The load balancer doesn't work over wifi and I haven't found a reasonable alternative to requiring ethernet on at least one node. Passwordless ssh and sudo are used to automate host prepraration, cluster creation, etcetera. |
| Certificate authority certificate and private key files | Becomes the certificate authority used by the cluster. | Lets experienced users anchor cluster certificates to an existing certificate authority while keeping certificate issuance declarative.Needs to be automated for  |
| At least two unused ip addresses on the same subnet as the wired host. | Will be used as the ingress ip address. | Lets experienced users anchor cluster certificates to an existing certificate authority while keeping certificate issuance declarative.Needs to be automated for  |

## quick start

1. Define your hosts in a hosts file.
    If the host is only reachable over a wifi network, be sure to apply the wifi
    label as seen in the [example hosts file](./infrastructure/hosts.example.yaml).

    ```shell
    cp infrastructure/hosts.example.yaml infrastructure/hosts.yaml
    $EDITOR infrastructure/hosts.yaml
    ```

2. Run the bootstrap script.

    ```shell
    /scripts/full-bootstrap.sh \
    --provision-cluster \
    --hosts infrastructure/hosts.yaml \
    --load-balancer-addresses 192.0.2.30-192.0.2.40 \
    --ca-crt path/to/intermediate-ca.crt \
    --ca-key path/to/intermediate-ca.key \
    --ssh-private-key ~/.ssh/operator \
    --ssh-known-hosts ~/.ssh/known_hosts
    ```

    Certain bootstrap behavior can be overridden with environment variables
    and script arguments.
    See the [bootstrap script](./scripts/full-bootstrap.sh) for the variables
    and their defaults.
    Use `./scripts/full-bootstrap.sh --help` for explanation of the script
    arguments.
    Be aware that the script may stop zero or more times and instruct you to
    commit and push file changes.
    After pushing, rerun the script with the same arguments to continue.

3. Once complete, you can optionally add the certificate from the
    `/infrastructure/artifacts/` directory to your client devices' trust stores.
    Cluster websites present certificates generated automatically by the
    cluster, so adding it means you will get encrypted transport and avoid
    security complaints from web browser applications.

4. Open the `./infrastructure/artifacts/bootstrap-credentials.txt` file for
    detials about the cluster, services, and default admin user.
    Configure DNS as instructed in the file.
    I plan to have the cluster provide a DNS service in the future.

5. Navigate to https://argocd.home.arpa (or replace home.arpa with your custom
    domain, if you used one).
    You should be redirected to the https://auth.home.arpa login page.

5. Login using the admin credentials from
    `infrastructure/artifacts/bootstrap-credentials.txt`.

6. You now have a declaritive cluster with "batteries included". You can add your
    own workloads and customize the cluster as needed.

