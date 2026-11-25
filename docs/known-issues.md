# Known issues

Behavior you may run into, why it happens, and what to do. Most of it comes from the
Qumulo Terraform provider or from AWS, and the tool works around it where it can.

## A stopped spoke cluster can't be destroyed or updated

The Qumulo provider treats a cluster whose instances are stopped as nonexistent.
Terraform would then drop it from state: a `destroy` would remove nothing and leave the
cluster running untracked, and an `apply` would plan a second cluster.

The tool refuses instead. destroy-spoke's first step, and the CodeBuild run before the
cluster stage (on apply and destroy), stop with an error if any spoke cluster instance
is stopped.

**What to do:** start the spoke's instances, wait until they're running, then run the
workflow again.

## A failed cluster create can leave untracked resources

If the cluster create fails partway (for example, an organization policy denies
`RunInstances`, or the execution is aborted), the provider can leave resources that no
Terraform state tracks: its provisioner instance, security groups, IAM roles and
instance profiles, S3 buckets, log groups. A retry creates a new deployment name, so
these stay behind. An orphaned security group also blocks deleting the spoke VPC.

**What the tool does:** destroy-spoke terminates tagged instances and deletes non-default
security groups left in the spoke VPC, then `spoke/cleanup.py sweep` removes anything
else tagged for the spoke.

**What to do:** run destroy-spoke for the region. If its email lists items marked
`[needs a person]`, those match the spoke by name but not by tag. Check whether they
belong to another hub's spoke in the same region before removing them by hand.

## The provider leaves log groups behind

The provider doesn't delete its `/qumulo/<deployment>/...` log groups on destroy.
destroy-spoke notes the cluster's deployment name first and deletes those log groups
after the cluster stage. If a cluster's state was lost, they stay; delete them by hand.

## A new portal reports DEGRADED

A portal relationship's status is `ACTIVE`, or `DEGRADED` when some connections between
the two clusters are missing. A DEGRADED portal still moves data over the connections it
has.

When any portal relationship on the hub isn't ACTIVE (for example, the hub is a spoke of
another cluster that's stopped, or a relationship's peer was removed without deleting
the portal), the hub's other relationships can report DEGRADED too, including a new
spoke's.

**What the tool does:** Validate lists the hub's relationships that aren't ACTIVE in the
summary (`hub_portal_warnings`). Verify accepts a portal that's accepted and authorized
but still DEGRADED after about 2 minutes, completes the deploy, and reports it in
`portal_warning`. `portal_ping` in the summary shows each node against each host on the
other side, in both directions.

**What to do:**

1. Run `qq portal_list` on the hub. If any other relationship isn't Active or Healthy,
   bring its peer back, or delete the relationship from the correct side.
2. Check `portal_ping`, or run `qq portal_ping` on both clusters. Every node must reach
   every configured address on TCP 3713 in both directions.
3. Check that both host lists are the current node IPs: `qq portal_get_hub` and
   `qq portal_get_spoke`.

## The provider can't take a computed `allow_cidrs` list

The provider fails with "Value Conversion Error ... Received unknown value" when
`allow_cidrs` is built in configuration (`[a, b]`, `concat()`) from values that aren't
known yet. `spoke/cluster/` therefore takes `allow_cidrs` as one variable, and the
buildspec builds the list. Keep it that way if you change the cluster stack.

## Aborting a deploy leaves a state lock and possibly running resources

Stopping a deploy-spoke execution also stops its CodeBuild run, which kills Terraform
mid-apply. It leaves a state lock, and possibly the provider's provisioner instance
(still billing) and other untracked cluster resources. Later runs remove a lock older
than the build timeout (about 3 hours) on their own. destroy-spoke removes the
resources, since they carry the spoke's tags. See the
[deployment guide](deployment-guide.md#dont-abort-a-running-deploy).

## Removing the control plane can be slow

AWS keeps a VPC Lambda's network interfaces for up to about 45 minutes after the
function is deleted, which blocks deleting its security group. Before destroying the
Lambda, Terraform moves it onto the hub VPC's default security group, so its own group
deletes at once. The group also has a 45-minute delete timeout as a safety net. This
takes effect only if the control plane was last applied with the current code.

## The CodeBuild role is broader than it needs to be

The CodeBuild role has wildcard permissions on EC2, IAM, KMS, S3 and others, because the
Qumulo provider creates IAM roles, KMS keys, and buckets, and its exact needs aren't
listed. (The provider also needs `tag:GetResources` to find the cluster's buckets on
destroy.) See the [security model](architecture.md#security-model).
