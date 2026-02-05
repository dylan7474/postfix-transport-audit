# AGENTS.md

## Purpose of this Repository

This repository contains **tooling and methodology** for auditing, analysing, and safely decommissioning
legacy mail relay infrastructure (primarily Postfix-based systems).

The primary real-world use case is:
- Legacy RHEL 6.x mail relay clusters
- Per-client transport overrides (non-MX routing)
- Partial or full decommission decisions based on **evidence**, not assumptions

This repository exists to provide:
- A **repeatable**, auditable process
- Clear separation between tooling and customer data
- Defensible outputs suitable for operational and compliance review

---

## CRITICAL RULES (READ FIRST)

### 1. NO CUSTOMER DATA IN THIS REPO
This repository must **never** contain:
- Mail logs (`maillog`, `mailq`, `postqueue`)
- Postfix configuration from real systems
- Transport maps with real customer domains
- IP addresses tied to production infrastructure
- Generated reports from real environments

All real data must live **outside** the repository.

If examples are required, they must be **synthetic** (RFC 5737 IPs, example.com domains).

---

### 2. TOOLING ONLY
This repo is intentionally limited to:
- Collection scripts
- Analysis scripts
- Documentation (README, AGENTS, methodology)

All execution happens in **external working directories**.

---

### 3. STEP-BY-STEP, CONFIRMATION-DRIVEN PROCESS
Agents must:
- Work **one step at a time**
- Wait for operator confirmation before proceeding
- Never assume command output
- Never skip ahead or “complete the analysis” speculatively

This is critical when dealing with live or historical customer-impacting systems.

---

## What We Are Doing (High-Level)

We are building a **repeatable audit pipeline** that:

1. Collects a defined set of logs and configuration files from a legacy mail relay
2. Transfers them to a safe analysis environment (e.g. Debian-based utility host)
3. Analyses:
   - Per-client transport overrides
   - Actual mail flow evidence from logs
   - Outbound delivery success vs persistent failure
4. Produces a report that identifies:
   - Active client routes
   - Inactive client routes
   - Broken upstream dependencies (e.g. dead smarthosts)
5. Supports:
   - Partial decommissioning (remove inactive clients only)
   - Full decommissioning (prove system is no longer functional)
   - Migration planning (e.g. replacement on RHEL 9)

All decisions must be **evidence-backed** using log data.

---

## What We Are NOT Doing

Agents must not:
- Assume “no complaints” means “no usage”
- Recommend removal without log evidence
- Auto-generate or modify production config
- Perform live changes on source systems
- Optimise prematurely or refactor without need

This repository is **analysis-first**, not automation-first.

---

## Expected Outputs (Outside the Repo)

Typical outputs (stored externally) include:
- Transport usage reports
- Lists of inactive override domains
- Queue state snapshots
- Executive summaries for operations/compliance

Agents may help generate these, but must never commit them here.

---

## Audience

This repository is used by:
- Senior infrastructure engineers
- Platform / operations teams
- Auditors and reviewers
- AI agents assisting analysis

Tone should remain:
- Precise
- Conservative
- Evidence-driven
- Production-safe

---

## If You Are an AI Agent

Your job is to:
- Assist the human operator
- Reduce risk, not increase it
- Ask before acting
- Explain reasoning clearly
- Preserve an auditable trail

When in doubt: **stop and ask**.
