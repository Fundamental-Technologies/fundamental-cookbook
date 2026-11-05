# Portal Tunnel

The platform UI (`fundamental-portal.<BaseDomain>`) and API are reachable only through the PrivateLink endpoint in your consumer VPC. If you have no browser inside that VPC (no VPN, no workspace host), `portal-tunnel.sh` opens them from your laptop using **only AWS-native services**: no SSH, no VPN, no inbound rules.

| Command | What it does |
|---------|--------------|
| `./portal-tunnel.sh up [region]` | Launches a tiny relay instance in the consumer VPC, points the four platform hostnames at `127.0.0.1` in `/etc/hosts`, and forwards local port 443 to the platform endpoint over AWS Systems Manager. Blocks until Ctrl-C. |
| `./portal-tunnel.sh status [region]` | Shows the portal URL, endpoint, relay instance, and whether `/etc/hosts` and the local listener are set. |
| `./portal-tunnel.sh down [region]` | Deletes this stack's relay instance, its security group, role and instance profile in that region, and restores `/etc/hosts`. |

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
- Nothing is installed on the relay. See [Security](#security) for what it can and cannot do.

## Prerequisites

- **AWS CLI v2.9 or newer**, configured for the deployment's account (e.g. via `AWS_PROFILE`).
- The **Session Manager plugin**: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>
- **macOS or Linux** with `sudo`. Port 443 and `/etc/hosts` need root. The script asks for your password once, and the root process gets only your resolved session credentials, never your `~/.aws` files.
- **SSM connectivity from the relay**, one of: `ssm` and `ssmmessages` VPC endpoints with private DNS (their security group must allow inbound 443 from the relay's subnet or security group; `up` checks this before launching), an internet gateway on the relay subnet (the relay then gets a public IP, outbound only), or a NAT gateway. `status` shows which path is used.
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

## Security

Everything `up` creates is scoped to the one stack and region, tagged `fundamental-portal-tunnel=<STACK_NAME>`, and removed by `down`.

| Resource | Permissions |
|----------|-------------|
| Relay security group `fundamental-portal-tunnel-<STACK_NAME>` | No inbound rules. Outbound TCP 443 only. With SSM VPC endpoints, outbound goes only to the security groups of the platform endpoint and the SSM endpoints. Through an internet gateway or NAT it is 443 to `0.0.0.0/0`, because SSM's public endpoints have no fixed IP range. The default allow-all egress rule is removed, and the rules are rebuilt on every `up`. |
| Relay role `fundamental-portal-tunnel-<STACK_NAME>-<region>` | One inline policy with the five actions Session Manager needs on an instance: `ssm:UpdateInstanceInformation` and `ssmmessages:Create/OpenControlChannel`, `Create/OpenDataChannel`. No Run Command, S3, Parameter Store or CloudWatch access. Only EC2 can assume it. |
| Relay instance | Stock Amazon Linux 2023, no key pair, no user data. IMDSv2 required with a hop limit of 1, instance tags hidden from IMDS, encrypted root volume. A public IP only when an internet gateway is the relay's only path to SSM. |
| Your laptop | `/etc/hosts` gets four `127.0.0.1` lines between marker comments (backup at `/etc/hosts.fundamental-tunnel.bak`). The root process runs only `aws ssm start-session`, with your resolved session credentials and a `PATH` of the AWS CLI, the plugin and system directories. |

The relay forwards only what a Session Manager session asks for, so who can use it is decided by **your** IAM policies: anyone allowed `ssm:StartSession` on the instance can open a session through it. To limit that, allow `ssm:StartSession` only on instances tagged `fundamental-portal-tunnel` and only with the `AWS-StartPortForwardingSessionToRemoteHost` document.

The deployment's endpoint security group (`fundamental-consumer<N>-api-sg`) is part of the stack and not changed by this script.

## Troubleshooting

- **`... VPC endpoint does not accept 443 from the relay`:** your `ssm` / `ssmmessages` endpoints only admit specific sources. The script never changes them; the error prints the one rule to add, which admits only the relay's security group. Then run `up` again.
- **`... has no path to SSM`** or **`... never registered with SSM`:** the relay cannot reach SSM. Set `RELAY_SUBNET` to a subnet with an internet gateway or NAT, add `ssm` and `ssmmessages` VPC endpoints, or check the subnet's network ACL and egress firewall.
- **`something already listens on local port 443`:** an earlier tunnel is still open, or another local service uses 443. Close it and run `up` again.
- **The page does not load after the tunnel says it is open:** run `status`. `/etc/hosts` should be `set` and local 443 `listening`. Corporate DNS or VPN clients that bypass `/etc/hosts` can override it; pause them while you use the tunnel.
- **The tunnel closes after a while:** SSM ends idle sessions (20 minutes by default). Run `up` again.
- **`could not launch the relay`:** the message includes the EC2 error. Common causes are an instance type not offered in that subnet's Availability Zone (set `INSTANCE_TYPE=t3.micro`) or a policy that blocks public IPs (set `RELAY_SUBNET` to a subnet with a NAT or SSM endpoints).
- **One tunnel at a time:** the tunnel owns local port 443, so close one deployment's tunnel before opening another.
- **Cost:** the relay is one `t4g.micro` that runs until `down`. Run `down` when you are finished.
