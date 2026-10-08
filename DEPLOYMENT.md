# Kikoff Showcase — Hackweek deployment record

Static Kikoff showcase site (`site/`) served by nginx on ECS Fargate behind an
internal ALB, following [CLAUDE.md](CLAUDE.md) "ECS / static sites".

| Field | Value |
| --- | --- |
| Project slug | `kikoff-showcase` |
| Sandbox | A (`hackweek-a`, account `632472162753`) |
| Owner | _TBD: confirm company email_ |
| Deployer | _TBD: confirm company email_ |
| Cleanup deadline | _TBD: from Hackweek kickoff_ |
| HTTPS URL | `https://<person>-kikoff-showcase.a.hackweek.kikoff.dev` |
| Expected response | HTTP 200, HTML containing `hackweek-kikoff-showcase` |
| Status | **Prepared; not deployed.** SSO login works, but `GetRoleCredentials` returns `ForbiddenException: No access` for `hackweek-administrator` in sandbox A. Infra needs to add the assignment. |

## Resources (created by `deploy.sh`, IDs recorded in `deploy-state.env`)

- ECR repo `hackweek-<person>-kikoff-showcase`
- CloudWatch log group `/ecs/hackweek-<person>-kikoff-showcase` (7-day retention)
- ECS cluster and service `hackweek-<person>-kikoff-showcase` (1 × Fargate ARM64, 256 CPU / 512 MiB)
- IAM role `hw-<person>-kshow-exec` (with permissions boundary)
- Internal ALB and `ip` target group `hw-<person>-kshow`, HTTPS:443 listener using the shared cert
- Private Route 53 alias in the shared `a.hackweek.kikoff.dev` zone

All resources are tagged `project`, `owner` and `created-by`. Shared VPC, subnets,
SG, zone and certificate are reused, never created or modified.

## Deploy

```bash
bash setup-aws.sh --profile hackweek-a          # SSO login and identity check
colima start --arch aarch64                      # local Docker runtime
DEPLOYER_EMAIL=<you>@kikoff.com bash deploy.sh
```

## Verify (Twingate connected)

```bash
curl --noproxy '*' --fail --show-error --max-time 20 \
  https://<person>-kikoff-showcase.a.hackweek.kikoff.dev/ | grep hackweek-kikoff-showcase
```

## Cleanup

`bash cleanup.sh` deletes only the resources listed in `deploy-state.env`.

## Local preview

`docker build -t kikoff-showcase . && docker run --rm -p 8080:80 kikoff-showcase`, then open http://localhost:8080
