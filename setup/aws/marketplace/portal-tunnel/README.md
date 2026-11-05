# Portal Tunnel

The platform UI (`fundamental-portal.<BaseDomain>`) and API are reachable only through the PrivateLink endpoint in your consumer VPC. If you have no browser inside that VPC (no VPN, no workspace host), `portal-tunnel.sh` opens them from your laptop using **only AWS-native services**: no SSH, no VPN, no inbound rules.

| Command | What it does |
|---------|--------------|
| `./portal-tunnel.sh up [region]` | Launches a tiny relay instance in the consumer VPC, points the four platform hostnames at `127.0.0.1` in `/etc/hosts`, and forwards local port 443 to the platform endpoint over AWS Systems Manager. Blocks until Ctrl-C. |
| `./portal-tunnel.sh status [region]` | Shows the portal URL, endpoint, relay instance, and whether `/etc/hosts` and the local listener are set. |
| `./portal-tunnel.sh down [region]` | Deletes the relay instance, its security group, role and instance profile, and restores `/etc/hosts`. |

## How it works

```
your laptop                          consumer VPC
+--------------------+   SSM    +-----------------+   443   +--------------------+
| browser -> :443    |--------->|  relay EC2      |-------->| PrivateLink        |
| (/etc/hosts ->     | (Systems |  (stock AL2023, |         | endpoint -> portal,|
|  127.0.0.1)        | Manager) |  no inbound)    |         | API, sign-in       |
+--------------------+          +-----------------+         +--------------------+
```

- The script reads everything it needs from your stack: the hostnames, the endpoint and the consumer VPC. You pass only the region.
- The browser connects to `https://fundamental-portal.<BaseDomain>` as usual. `/etc/hosts` sends it to `127.0.0.1:443`, and SSM carries the bytes to the relay, which forwards them to the endpoint. TLS runs end to end with the platform's own certificate, so there are no browser warnings and the relay never sees plaintext.
- The tunnel targets the endpoint's own DNS name, so it works even before your private DNS records exist.
- The relay has **no inbound rules** and outbound 443 only. Nothing is installed on it, and its role has only `AmazonSSMManagedInstanceCore`.

## Prerequisites

- **AWS CLI v2.9 or newer**, configured for the deployment's account (e.g. via `AWS_PROFILE`).
- The **Session Manager plugin**: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>
- **macOS or Linux** with `sudo`. Port 443 and `/etc/hosts` need root. The script asks for your password once, and the root process gets only your resolved session credentials, never your `~/.aws` files.
- **SSM connectivity from the relay subnet**: an internet gateway (the relay then gets a public IP for outbound only), a NAT gateway, or `ssm`, `ssmmessages` and `ec2messages` VPC endpoints. `status` shows which path the subnet has.
- Permissions to create an EC2 instance, a security group, and an IAM role and instance profile.

## Usage

```bash
AWS_PROFILE=<your-profile> ./portal-tunnel.sh up <region>
```

Leave that terminal open and browse to the URL it prints. On the first sign-in, use user `admin` with password `admin`; you are asked to set a new password right away.

The SDK works through the same tunnel:

```bash
export FUNDAMENTAL_API_URL=https://fundamental-api.<BaseDomain>
```

Press **Ctrl-C** to close the tunnel. Re-running `up` reuses the relay. When you are done:

```bash
AWS_PROFILE=<your-profile> ./portal-tunnel.sh down <region>
```

### Options (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `STACK_NAME` | `fundamental` | Root stack name (your `DeploymentName`). |
| `CONSUMER` | `1` | Which consumer VPC to tunnel through (`ConsumerVpc<N>`). |
| `RELAY_SUBNET` | first endpoint subnet | Subnet for the relay. Set it when the endpoint subnets have no path to SSM. |
| `INSTANCE_TYPE` | `t4g.micro` | Relay instance type. The matching Amazon Linux 2023 AMI architecture is picked automatically. |

The region may also come from `AWS_REGION` / `AWS_DEFAULT_REGION`.

## Troubleshooting

- **`... never registered with SSM`:** the relay subnet has no path to SSM. Set `RELAY_SUBNET` to a subnet with an internet gateway or NAT, or add the SSM VPC endpoints.
- **`something already listens on local port 443`:** an earlier tunnel is still open, or another local service uses 443. Close it and run `up` again.
- **The page does not load after the tunnel says it is open:** run `status`. `/etc/hosts` should be `set` and local 443 `listening`. Corporate DNS or VPN clients that bypass `/etc/hosts` can override it; pause them while you use the tunnel.
- **The tunnel closes after a while:** SSM ends idle sessions (20 minutes by default). Run `up` again.
- **`admin` / `admin` is rejected:** the initial password was already changed, or the sign-in page you used is not the platform's. Use `org-admin.sh` (below) to check and reset it.

## Reset the portal admin password

`org-admin.sh` reads or resets the org admin user directly in the platform's sign-in service over the private EKS API. If your IAM role has no EKS access entry, the script adds one with cluster-admin rights.

```bash
AWS_PROFILE=<your-profile> ./org-admin.sh check <region>   # user state, lockout, setup job
AWS_PROFILE=<your-profile> ./org-admin.sh reset <region>   # prompts for a new password
```

It needs `kubectl` in addition to the prerequisites above.
