# Governance

**Governance primitives for Modulexo: weighted governor, timelock execution, and verifiable authority boundaries.**

---

## Definition

This repository contains the governance control-plane primitives used to manage authorized changes to Modulexo contracts.

The governance model enforces:

- proposal-based decision making
- time-delayed execution
- on-chain verifiability of all actions

Governance is a control mechanism.  
It does not promise outcomes.

---

## What This Repository Contains

- **Weighted Governor** — proposal and vote management using on-chain voting power
- **Timelock** — execution delay and authorized call scheduling
- Minimal interfaces required to read voting power from the share ledger (Fund)

---

## What This Governance Does

- Accepts proposals targeting governed contracts
- Records weighted votes during a defined voting period
- Enforces quorum and proposal thresholds
- Queues approved proposals into a Timelock
- Executes queued operations only after the configured delay
- Emits proposal and execution events suitable for independent monitoring

---

## What This Governance Does NOT Do

- Does **not** execute changes instantly
- Does **not** bypass contract-defined permissions
- Does **not** modify historical ledger state
- Does **not** guarantee any governance outcome
- Does **not** provide off-chain authority

This is an on-chain control plane only.

---

## Typical Authority Flow

1. Proposal created in **Governor**
2. Voting occurs (weighted by share ledger)
3. If passed, proposal is queued in **Timelock**
4. After delay, Timelock executes the transaction on the target contract

Authority is verifiable via:

- Governor proposal lifecycle events
- Timelock operation status
- Target contract `owner()` state

---

## Scope Limitation

Governance can only call functions exposed by the governed contracts.

If a contract is not owned by the Timelock (or otherwise governed), governance cannot control it.

Control state is determined by on-chain ownership and role configuration.

---

## Deployment Status

- **Governor:** Deployed / configured per network (typically Ethereum)
- **Timelock:** Deployed with explicit delay and proposer/executor roles
- **Governed Targets:** Deployment-specific (`owner()` must point to Timelock)

Refer to GitBook for deployed addresses and verification steps.

---

## Documentation

Full documentation:

https://docs.modulexo.com
