# The Frugal Architect: seven laws (reference for frugal-reviewer and planner)

Source: Werner Vogels, *The Frugal Architect* (thefrugalarchitect.com, re:Invent 2023).
This file has no frontmatter on purpose. It lives outside `.opencode/agent/` because opencode loads every `.md` there as an agent.

Every cost finding must cite exactly one law, using the numeral and short name in each heading.

---

## Law I: Make cost a non-functional requirement (short name: `I – cost is an NFR`)

Cost sits alongside security, availability and latency as a design constraint from day one, not something to look at after the bill arrives.

Checks:
- A new `aws_db_instance`, `aws_eks_node_group`, `aws_nat_gateway` or `aws_opensearch_domain` arrives with no cost estimate in the PR, plan or code comments. Run `infracost diff` when it's available.
- A new EKS cluster or environment is added without a stated monthly budget or target unit cost.
- A plan or ADR lists performance and availability targets but no cost target.

## Law II: Systems that last align cost to business (short name: `II – align cost to business`)

Cost should grow with the thing the business earns from (requests, tenants, orders, transactions), not with infrastructure that sits idle.

Checks:
- A fixed `aws_eks_node_group` with `min_size = desired_size` serves batch or spiky jobs. Prefer Karpenter with scale-to-zero, Fargate or Lambda.
- DynamoDB `billing_mode = "PROVISIONED"` for unpredictable traffic, where `PAY_PER_REQUEST` would track demand.
- One cluster or database per tenant with no consolidation, so cost scales with tenant count rather than tenant usage.

## Law III: Architecting is a series of trade-offs (short name: `III – trade-offs`)

Every resilience or performance gain has a price. Make the trade-off explicit and match it to how critical the workload is.

Checks:
- `multi_az = true`, Aurora replicas or `aws_s3_bucket_replication_configuration` on dev, test or non-critical workloads with no justification.
- One `aws_nat_gateway` per AZ in non-production. A single NAT Gateway, or VPC endpoints, is often enough.
- `io2` / provisioned IOPS, or `db.r*` memory-optimised classes, with no workload evidence that they're needed.

## Law IV: Unobserved systems lead to unknown costs (short name: `IV – observe costs`)

If you can't attribute spend to an owner and a service, you can't manage it.

Checks:
- The AWS provider has no `default_tags` block, or new resources lack `CostCenter`, `Team`, `Service` and `Environment` tags. Cost allocation tags are not activated.
- No `aws_budgets_budget` or CloudWatch billing alarm covers the account or service that gains new spend.
- EKS workloads lack `team` or `cost-center` labels, so split cost allocation, Kubecost or OpenCost can't attribute them.

## Law V: Cost-aware architectures implement cost controls (short name: `V – cost controls`)

Build in the guardrails that stop spend running away, and use the cheaper purchase options where they fit.

Checks:
- `aws_cloudwatch_log_group` without `retention_in_days`; `aws_s3_bucket` without an `aws_s3_bucket_lifecycle_configuration` or Intelligent-Tiering; `aws_ecr_repository` without an `aws_ecr_lifecycle_policy`.
- HPA without a sensible `maxReplicas`, Karpenter `NodePool` without `limits.cpu`/`limits.memory`, or an ASG or node group whose `max_size` is far above any observed need.
- Stateless node groups not using Spot (`capacity_type = "SPOT"`); x86 instances (`m5`, `c5`) where Graviton (`m7g`, `c7g`) is a drop-in; steady baseline compute not covered by Savings Plans; `gp2` volumes where `gp3` fits.

## Law VI: Cost optimisation is incremental (short name: `VI – incremental`)

Optimisation is a continuous practice. Debt you defer must be tracked or it never gets paid.

Checks:
- `# TODO: downsize later`, `# temporary`, `# FIXME cost` and similar comments with no issue link (`#123`, `JIRA-456`, a URL).
- Temporary capacity overrides (`desired_size = 20 # for launch`) with no expiry date or follow-up ticket.
- No scheduled cost audit (for example `/frugal` run periodically) or cost review step in the delivery process.

## Law VII: Unchallenged success leads to assumptions (short name: `VII – challenge assumptions`)

What worked before isn't automatically right now. Re-examine defaults, sizes and retention instead of copying them forward.

Checks:
- Instance sizes, node group `min_size` or replica counts copied from production into dev or staging (`replicas: 3`, `m5.2xlarge` in a sandbox).
- Retention periods kept at maximum (`retention_in_days = 3653`, never-expire S3 objects, 35-day RDS backups) with no compliance reason stated.
- Reserved or provisioned capacity sized for a past peak and never revisited; old instance generations (`m4`, `t2`, `r4`) carried forward.
