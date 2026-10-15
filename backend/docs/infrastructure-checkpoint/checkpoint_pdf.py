"""Generates Smart_Gossyculture_Infrastructure_FinalPhase_Checkpoint.pdf (reportlab)."""
import sys

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

OUT = sys.argv[1]
ss = getSampleStyleSheet()
BODY = ParagraphStyle("b", parent=ss["Normal"], fontName="Helvetica", fontSize=8.8, leading=11.4)
SMALL = ParagraphStyle("s", parent=BODY, fontSize=7.9, leading=9.9)
H1 = ParagraphStyle("h1", parent=ss["Heading1"], fontName="Helvetica-Bold", fontSize=12.5, leading=15, spaceBefore=9, spaceAfter=4, textColor=colors.HexColor("#1b4332"))
TITLE = ParagraphStyle("t", parent=ss["Title"], fontName="Helvetica-Bold", fontSize=17, leading=21, alignment=TA_CENTER)
SUB = ParagraphStyle("st", parent=TITLE, fontSize=12, leading=15)
BOX = ParagraphStyle("box", parent=BODY, fontName="Helvetica-Bold", fontSize=9.6, leading=13, textColor=colors.HexColor("#9b1c1c"))

COL = {"VALIDATED-LOCAL": "#15803d", "FIXED": "#1d4ed8", "NOT VALIDATED": "#b45309", "INCOMPLETE": "#c2410c",
       "BLOCKED": "#b91c1c", "NOT STARTED": "#475569", "DECISION NEEDED": "#be123c"}


def lab(name):
    return f'<font color="{COL[name]}" size="6.8"><b>{name}</b></font>'


def P(text, style=BODY):
    return Paragraph(text, style)


def table(rows, widths, header=True, style=SMALL):
    t = Table([[P(c, style) for c in r] for r in rows], colWidths=[w * mm for w in widths], repeatRows=1 if header else 0)
    cmds = [("GRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#cbd5e1")), ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 3), ("RIGHTPADDING", (0, 0), (-1, -1), 3), ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 2)]
    if header:
        cmds.append(("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e2e8f0")))
    t.setStyle(TableStyle(cmds))
    return t


def hdr(*c):
    return [f"<b>{x}</b>" for x in c]


S = []
A = S.append
A(P("SMART GOSSYCULTURE / BOLLBOT", TITLE))
A(P("INFRASTRUCTURE (FINAL PHASE) -- CHECKPOINT", SUB))
A(Spacer(1, 4 * mm))
A(table([
    ["Date", "1 October 2026 (state recorded at about 15:25 UTC / 20:55 IST)"],
    ["Purpose", "Records where the production-infrastructure work stopped. By the owner's roadmap change, AWS / production infrastructure is now the FINAL phase; this work is paused, not finished. Nothing here is a completion report."],
    ["Scope of results", "A local Docker-in-Docker rehearsal on the development machine: one clean Linux 'host' container that receives the same deploy bundle, settings-file layout, secret document shape and scripts an EC2 host would. No AWS account, credential, resource, domain or public certificate exists."],
    ["Project path", "C:\\Users\\agsre\\OneDrive\\Pictures\\Desktop\\Smart-Gossyculture\\backend"],
    ["Rehearsal release", "Image gossy-backend:0.3.0-rehearsal.202610011350 (runtime target, built 1 Oct 2026); bundle redeployed 14:47 UTC"],
], [32, 142], header=False, style=BODY))
A(Spacer(1, 3 * mm))
box = Table([[P("Production deployment has NOT occurred.", BOX)],
             [P("These results are from a local Docker-in-Docker rehearsal only.", BOX)],
             [P("Phase 3 infrastructure is not considered production-ready.", BOX)]], colWidths=[174 * mm])
box.setStyle(TableStyle([("BOX", (0, 0), (-1, -1), 1, colors.HexColor("#9b1c1c")), ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#fef2f2")),
                         ("LEFTPADDING", (0, 0), (-1, -1), 6), ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 2)]))
A(box)
A(Spacer(1, 2 * mm))
A(P("<b>Status labels.</b> " + " ".join(lab(k) for k in COL), SMALL))

A(P("1. Completed and validated -- LOCAL REHEARSAL ONLY", H1))
A(P("Each row passed when it was run. 'Bundle' says which version of the deploy bundle it ran against: several fixes (section 2) were made during the day, so most results predate the final code and a final clean run is still owed (section 3).", BODY))
A(table([
    hdr("Item", "Result", "Bundle / note", "Evidence file"),
    ["Terraform fmt / init / validate", "Clean for deploy/aws/bootstrap and deploy/aws/terraform (Terraform 1.16.4, aws 6.66.0, random 3.9.1)", "Re-run after the Terraform fixes. Syntax and schema only: no plan against a real account", "(console output; not saved to a file)"],
    ["Policy tests, AWS provider mocked", "7/7 with staging.tfvars and 7/7 with production.tfvars", "Final Terraform code. Checks what would be created (ports, encryption, environment separation, alarm set), not AWS behaviour", "(console output; not saved to a file)"],
    ["Pinned container image build", "runtime and dev targets build; tag 0.3.0-rehearsal.202610011350; non-root user", "No application source change today", "release_tag.txt"],
    ["Unit tests", "192/192", "Before the deploy-script fixes (which unit tests do not cover)", "(console output)"],
    ["Local rehearsal deployment", "deploy.sh succeeded on a clean host and again as in-place upgrades; last successful deploy 14:47 UTC", "Latest bundle EXCEPT the rewritten queue test scripts", "01_deploy.txt (14:17 UTC clean-host deploy)"],
    ["Five healthy services", "caddy, api, ingest, mosquitto, timescaledb healthy; readiness OK; PostgreSQL 17.11, TimescaleDB 2.30.2, schema 0002; verified again at 15:24 UTC", "Latest deployed bundle", "02_health_db.txt"],
    ["Configuration checks", "prodcheck 21/21 (staging settings)", "Every deploy, including the last", "01_deploy.txt"],
    ["Integration + edge tests", "135 passed, 3 skipped (crash-injection tests, refused outside development by design)", "Bundle before the secret-rendering and restore fixes", "03_integration.txt"],
    ["Durability scenarios", "6/6: database stopped 90 s (22/22), database restart mid-stream (42/42), broker restart, broker SIGKILL, ingest stop, ingest SIGKILL (12/12 each); no loss, no duplicate effects, no dead letters", "Same as above; first run with the unprivileged read-only broker", "07_durability.txt"],
    ["Ingestion alert states", "ok -> retrying -> prolonged -> ok; dead letter counted and stored; blocked -> ok; 0 problems. Read from the /metrics series the alarms are defined on", "Same as above. Threshold shortened to 30 s for the rehearsal (production value 300 s). CloudWatch alarms themselves not exercised", "08_alerts.txt"],
    ["Exposure / access", "Scan of 65,535 TCP ports from a separate container: only 443 and 8883 open. TLS 1.3 negotiated, TLS 1.0/1.1 refused, wrong name refused; /readyz, /metrics, /docs = 404; no/forged token = 401; anonymous, wrong-password and unknown MQTT clients refused; cross-device and non-contract publishes refused (reason 135); device receives nothing. 39 checks, 0 failed", "Bundle before the last fixes. Certificates from Caddy's internal CA with *.invalid names (no domain exists). Security groups not testable locally", "04_portscan.txt, 05_edge_probe.txt"],
    ["No plaintext secret on persistent storage", "9 secret values searched under /srv/gossy, /opt/gossy, /etc and the database files: none found (after the health-password fix); none in 31,691 container log lines", "Latest deployed bundle (log scan at 15:26 UTC)", "02b_secrets_on_disk.txt"],
    ["Monitoring consistency", "7/7 application alarms reference a series that a service exports and that the CloudWatch agent configuration publishes with the same dimensions", "Static check against live /metrics output. Does not prove alarms fire in AWS", "06_metrics_sample.txt"],
], [33, 62, 49, 30]))
A(P("Note on 02_health_db.txt: its 'secrets on persistent disk' section lists many files because of a bug in that check (an empty search pattern matched everything). It is not a finding; 02b_secrets_on_disk.txt is the corrected check.", SMALL))

A(P("2. Fixes completed during the rehearsal " + lab("FIXED"), H1))
A(table([
    hdr("Fix", "Problem found", "Change", "Validated?"),
    ["Terraform expression", "coalesce(var.acme_email, \"\") fails when the value is null, so a real apply with the shipped tfvars would have failed. terraform validate did not catch it; the mocked plan test did", "Explicit null checks in compute.tf (also for deploy_bundle_key)", "Yes: policy tests 7/7 x 2"],
    ["SSM-based host settings", "Non-secret host settings were written by EC2 user-data, which runs only on first boot: a later change (e.g. hostnames once U-6 is decided) would never reach a running host", "Settings kept in SSM parameter /gossy/&lt;env&gt;/host-env; new bin/render-config.sh refreshes /etc/gossy/gossy.env at every deploy; IAM statement; user_data ignored after first boot", "Terraform side: policy tests. Host side: only the 'no parameter' path ran (rehearsal has no AWS)"],
    ["tmpfs broker health-check password", "The broker health-check account's password was copied in plaintext to the persistent data volume", "Rendered into its own tmpfs directory owned by the broker user; mounted read-only", "Yes: disk search found none; broker healthy"],
    ["Unprivileged / read-only broker", "Mosquitto (internet-facing) ran with default capabilities and a writable root filesystem", "user 1883, read_only, cap_drop ALL in deploy/prod/compose.yaml", "Yes: durability 6/6 incl. broker restart and kill"],
    ["Safe secret rendering", "render-secrets.sh deleted the rendered secrets before validating the new document; the document was passed as a process argument", "Validate first, then replace; document passed in the environment", "Partly: deploys at 14:47 UTC succeeded; the refusal path has not been run"],
    ["Restore failure behaviour", "A refused restore (non-empty database) had already stopped the running stack and rewritten the release file", "Emptiness check before anything is stopped; release file untouched; dump removed on exit", "No: restore.sh not run since the change"],
], [34, 58, 50, 32]))
A(P("Also changed: rehearsal host's Docker daemon now listens on its local socket only (the Docker-in-Docker image default opened TCP 2376); corrected comments in backup.sh and the env examples; gossy-secrets.service ordered before docker.service (not testable without systemd).", SMALL))

A(P("3. Completed but not validated " + lab("NOT VALIDATED"), H1))
A(table([
    hdr("Item", "State"),
    ["Fixed restore.sh", "Code changed; no restore has been executed with it. The previous session's restore attempt (30 Sep) restored the data but failed to start the application; that defect was patched then and has not been re-run either."],
    ["Rewritten queue test scripts", "deploy/prod/rehearsal/queue-overflow.sh and queue_overflow.py rewritten into two parts (throughput vs depth; behaviour at a lowered bound). Never executed; not installed on the rehearsal host."],
    ["Final clean end-to-end run", "Planned: one run of every check on a freshly provisioned host with the final code. Not done; results in section 1 come from intermediate bundle versions."],
    ["Final unauthorized-access evidence", "The 39-check outside-in probe passed at 14:33 UTC, before the secret-rendering and restore changes. It has not been repeated on the latest bundle."],
    ["AWS-specific code", "Terraform resources, EC2 user-data, IAM policies, security groups, systemd units and timers, CloudWatch agent configuration and alarms, awslogs logging, Let's Encrypt issuance, S3 / Secrets Manager / SSM access: written and statically checked only. None has run."],
    ["docs/deployment.md", "Updated to the current procedure. The procedure itself has only been rehearsed locally."],
], [42, 132]))

A(P("4. Incomplete " + lab("INCOMPLETE"), H1))
A(table([
    hdr("Item", "State"),
    ["Queue-bound test", "One run with the unchanged production broker settings (max_queued_messages 10000, store saved after every change). The publisher's 600 s limit expired first: 9,516 of 10,300 messages were acknowledged in 603 s (about 16 per second on average, slowing as the queue grew) with the broker at its 0.5-CPU limit; 9,518 reached the database with 0 duplicates. The 782 others were never acknowledged to the test client -- the bound was NOT reached, so behaviour at the bound (what is dropped, what the device is told) is still unmeasured. Evidence: 09_queue.txt. The cause of the slowdown is believed to be the full store rewrite per message; that explanation has not been separately confirmed."],
    ["Queue capacity calculation", "Not written. Formula: message rate x device count x maximum outage duration x safety margin. Device count, message rate and outage target are not decided (U-15, U-20) " + lab("DECISION NEEDED") + ". The 10,000 limit has not been changed."],
], [42, 132]))

A(P("5. Blocked " + lab("BLOCKED"), H1))
A(table([
    hdr("Item", "Blocked by"),
    ["AWS deployment (staging or production)", "U-5: no AWS account, credentials, budget or IAM administrators. U-6: no domain and no certificate source, so no publicly trusted TLS. The AWS CLI and Terraform are not installed on this machine (Terraform runs from a container image)."],
], [42, 132]))

A(P("6. Not started " + lab("NOT STARTED"), H1))
A(table([
    hdr("Item", "Note"),
    ["Second-host backup / restore drill", "Drill scripts drafted (unrun). No backup has been taken today."],
    ["Host reboot recovery", "Drill script drafted (unrun). systemd ordering cannot be rehearsed locally."],
    ["Secret rotation", "Drill script drafted (unrun)."],
    ["Production-config refusal test", "Drill script drafted (unrun). Unit tests of prodcheck pass, but the refusal has not been demonstrated on the deployed stack."],
    ["Final log / resource verification", "Drill script drafted (unrun). Only the secret-in-logs scan in section 1 was done."],
    ["Dev crash-injection validation", "Crash-injection tests A/B/C run only on the development stack; not re-run since ingest/consumer.py and ingest/service.py were modified on 30 Sep."],
    ["Cost estimate", "Not prepared."],
    ["Final infrastructure README", "backend/README.md still describes Phase 2."],
    ["Full Phase 3 infrastructure report", "Smart_Gossyculture_Phase3_Production_Infrastructure_Report.pdf has not been produced."],
], [52, 122]))

A(P("7. Open decisions that affect this phase " + lab("DECISION NEEDED"), H1))
A(P("U-5 AWS account and budget; U-6 domain and certificate source; U-7 production device credential type (only temporary sim-* password accounts exist, staging only); U-15 pilot scale, message rate and retention; U-16 monitoring tooling (CloudWatch assumed in the code); U-17 IaC tool and registry (Terraform and ECR assumed in the code); U-20 recovery targets; administrator authentication; broker high availability. Also on record: the ingest service's manual acknowledgement relies on a private attribute of the aiomqtt library (pinned and unit-tested; re-verify on upgrade), and the project still has no git repository of its own, so none of this infrastructure code is under version control.", BODY))

A(P("8. What was preserved and how to resume", H1))
A(table([
    hdr("What", "Where"),
    ["Evidence files (01-09, release tag)", "backend/docs/infrastructure-checkpoint/evidence/"],
    ["Rehearsal container logs (all inner containers, 31,691 lines, scanned: no secret values)", "backend/docs/infrastructure-checkpoint/container-logs/rehearsal-container-logs.tgz"],
    ["Drafted, unrun drill and probe scripts", "backend/docs/infrastructure-checkpoint/pending-drill-scripts/"],
    ["Infrastructure code and host bundle", "backend/deploy/aws/ and backend/deploy/prod/ (unchanged by this checkpoint)"],
    ["Rehearsal host", "Container gossy-rehearsal-host: stopped, not removed. Its data (database, broker store, loaded images) stays inside the stopped container. Its secrets were in memory (tmpfs) and are gone, by design."],
    ["Images and volumes", "gossy-backend:0.3.0-rehearsal.202610011350, gossy-backend:dev, gossy-rehearsal-host, gossy-report-tools; volumes gossy-rehearsal-offhost, gossy-tf-plugins. Not deleted."],
], [62, 112]))
A(P("To resume in the final phase: provision a fresh rehearsal host (run-rehearsal.sh up, as in docs/deployment.md) rather than restarting the stopped one, run every check once on the final code, then the items in sections 3-6. The remaining runs are memory-heavy on this machine (the queue test was stopped once for low memory).", BODY))
A(Spacer(1, 3 * mm))
A(P("<b>Files created today (infrastructure):</b> deploy/aws/terraform/tests/policy.tftest.hcl, deploy/aws/check-monitoring.py, deploy/prod/bin/render-config.sh, deploy/prod/rehearsal/queue-overflow.sh, deploy/prod/rehearsal/queue_overflow.py, docs/infrastructure-checkpoint/ (evidence only). "
    "<b>Modified today:</b> deploy/aws/terraform/compute.tf, iam.tf, user_data.sh.tftpl; deploy/prod/compose.yaml; deploy/prod/bin/deploy.sh, render-secrets.sh, restore.sh, backup.sh (comment); deploy/prod/mosquitto/init-broker.sh; deploy/prod/systemd/gossy-secrets.service; deploy/prod/env/*.env.example; deploy/prod/rehearsal/run-rehearsal.sh; docs/deployment.md. "
    "<b>Deleted:</b> none. <b>Application source (src/, tests/, migrations/, Flutter):</b> not modified today.", SMALL))
A(Spacer(1, 2 * mm))
A(P("<b>End of checkpoint. Infrastructure work is paused. No test listed as incomplete, unvalidated or not started is claimed to have passed.</b>", BODY))


def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 7)
    canvas.setFillColor(colors.HexColor("#64748b"))
    canvas.drawString(18 * mm, 10 * mm, "Smart Gossyculture / BOLLBOT -- Infrastructure (final phase) checkpoint -- local rehearsal only; no production deployment")
    canvas.drawRightString(192 * mm, 10 * mm, f"1 Oct 2026   Page {doc.page}")
    canvas.restoreState()


SimpleDocTemplate(OUT, pagesize=A4, leftMargin=18 * mm, rightMargin=18 * mm, topMargin=15 * mm, bottomMargin=17 * mm,
                  title="Smart Gossyculture - Infrastructure Final-Phase Checkpoint", author="Smart Gossyculture project").build(S, onFirstPage=footer, onLaterPages=footer)
print("written", OUT)
