# Fastmail cutover: state and remaining work

The migration of `i3sec.com.au` mail from Google Workspace to Fastmail is
half done. This file records what is live, what is not, and what the
remaining cutover needs. `terraform/email.tf` points here.

Written 2026-09-17. The DNS facts below were queried from public
resolvers (1.1.1.1 and 8.8.8.8) on that date, not copied from the
Cloudflare dashboard.

## Status: sending is ready, receiving is not

Fastmail DKIM and a combined SPF record are live. MX still points at
Google Workspace. Fastmail can therefore sign and send mail as
`i3sec.com.au`, but it receives none. Every inbound message still lands
in Workspace.

The single remaining DNS step is the MX swap. That step is the point of
no return for inbound mail, so it goes in on its own, after the
prerequisites below are met.

## Live DNS on 2026-09-17

Authoritative nameservers are Cloudflare (`christina.ns.cloudflare.com`,
`rommy.ns.cloudflare.com`). Fastmail's own nameservers were never
delegated, and must not be. Cloudflare has to stay authoritative or every
`tunneled_hostnames` entry in `tunnel.tf` breaks.

MX, TTL 300:

- `10 aspmx.l.google.com.`
- `20 alt1.aspmx.l.google.com.`

Apex TXT:

- `v=spf1 include:_spf.google.com include:spf.messagingengine.com ?all`
- `google-site-verification=gC1wpu2jNrBp3P19JfvfjoPPua2-y-SaC6JLB5En8Yw`

`_dmarc` TXT, TTL 3600:

- `v=DMARC1; p=none;`

DKIM CNAMEs, TTL 3600, `fm1` / `fm2` / `fm3`, each to
`fmN.i3sec.com.au.dkim.fmhosted.com`.

`google._domainkey` returns NXDOMAIN. Workspace DKIM signing was never
turned on.

Two details worth keeping straight:

The apex TXT records answer with TTL 300, not the 3600 that `email.tf`
declares. That is not drift. All apex TXT records share one RRset TTL,
and the unmanaged `google-site-verification` record uses Cloudflare's
"Auto" TTL of 300. The lower value wins for the whole set.

Only two Google MX hosts exist. A default Workspace zone publishes five,
adding `alt2`, `alt3` and `alt4` at priority 30. The current setup is
thinner than standard. It is not broken, and the cutover removes all of
them anyway.

## What Terraform manages, and what it does not

`terraform/email.tf` manages the Fastmail DKIM CNAMEs, the apex SPF
record and the `_dmarc` record. It manages no MX record. A grep for
`"MX"` across `terraform/` returns nothing.

The Google MX records and the `google-site-verification` TXT record are
unmanaged. Someone created them in the Cloudflare dashboard, and
Terraform has never known about them.

## The unmanaged-MX trap

Adding Fastmail MX records to `email.tf` does not replace the Google
ones. Cloudflare accepts several MX records at the same name, so
Terraform creates the Fastmail pair and leaves the Google pair in place.
The result is four MX records, and inbound mail splits across two
providers by priority. Partial delivery to a mailbox nobody is reading
is worse than no cutover at all.

Remove the Google MX records in the same change window. Either import
them into Terraform state and then delete the resources, or delete them
in the Cloudflare dashboard immediately before the apply. Importing is
the better option, because it leaves a record of the deletion in the
plan output.

## Prerequisites, all outside DNS

None of these can be checked from the cluster. They live in Fastmail and
in Workspace.

1. Fastmail account active, `i3sec.com.au` added and verified there.
2. Every Workspace mailbox, alias, group and catch-all recreated in
   Fastmail. An address that exists in Workspace but not in Fastmail
   starts bouncing the moment MX moves.
3. Mail history imported. Fastmail imports from Gmail over OAuth. Large
   mailboxes take a long time. Finish the import before the flip, not
   after.
4. Calendar and contacts moved. Workspace carries both, and neither
   follows the mail import.
5. Homelab senders repointed. Anything that authenticates to Workspace
   SMTP with an app password stops working when the Workspace account
   closes. Grep `day0-bootstrap`, `day1-foundation` and `day2-services`
   for SMTP hosts and app passwords before the cutover, not after.

Google Drive is already handled. That offboarding finished 2026-08-23.

## The DNS change

1. Confirm MX TTL is still 300. It is today. A short TTL is what makes
   rollback fast.
2. Add the Fastmail MX records to `email.tf`:
   `in1-smtp.messagingengine.com` at priority 10, and
   `in2-smtp.messagingengine.com` at priority 20.
3. Remove the Google MX records in the same change. See the trap above.
4. Optionally add Fastmail's client autodiscovery records, so mail
   clients configure themselves: an `autoconfig` CNAME, and `_submission`
   and `_imap` SRV records.
5. Leave SPF and DMARC alone during the flip.
6. Later, once Workspace has genuinely stopped sending, drop
   `include:_spf.google.com` from SPF and change `?all` to `~all`.

Applying (since 2026-10-18): a push no longer applies anything. Run
`ansible-playbook cloudflare-tf-apply.yml` from `day0-infra-build` for a
plan, review it, then re-run with `-e cloudflare_tf_do_apply=true -e
cloudflare_tf_approved_plan=<PLAN_SHA>` to apply exactly that plan.

## Two fixes worth making regardless of cutover timing

**DMARC collects nothing.** The record is `v=DMARC1; p=none;` with no
`rua=` address. Monitor mode without a reporting address produces no
reports. Aggregate reports are the exact data a mail migration needs.
Add an `rua=` address before the flip.

**Plan gate: done 2026-10-18.** The apply is now plan-first and applies
only the plan fingerprint you approved, so the MX swap gets the usual
plan review before it goes live.

## Rollback

Rollback is cheap, and stays cheap as long as the two rules below hold.

MX TTL is 300, so restoring the Google MX records takes about five
minutes to propagate. Messages already delivered to Workspace stay in
Workspace. Messages already delivered to Fastmail stay in Fastmail.
Neither side loses anything on a revert.

Keep the Workspace subscription paid and receiving for several weeks
after the flip. Do not cancel it on cutover day. Cancelling is the only
irreversible act in this migration, and nothing forces it to happen
early.

## Open question blocking the sequence

Has the Fastmail side been set up at all? Account, verified domain,
mailboxes, imported mail? Or is `terraform/email.tf` the only artifact
that exists from this migration?

Everything above assumes the answer is "partly". If the answer is
"nothing yet", the prerequisites are the whole project and the DNS change
is an afternoon at the end of it.
