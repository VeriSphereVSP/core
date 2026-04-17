# Off-chain Read Model & Indexing Specification

## Purpose
This document defines the canonical off-chain read model for VeriSphere.
It enables deterministic, fast querying of protocol state without duplicating or redefining on-chain logic.

This specification is **descriptive, not normative**: smart contracts remain the sole authority.

---

## Authority Model

### On-chain (authoritative)
The following contracts define protocol truth:

- PostRegistry — claims and links
- LinkGraph — directed evidence graph (cycles permitted; see ScoreEngine for cycle handling)
- StakeEngine — stake custody and epoch mechanics
- ScoreEngine — base and effective Verity Score (VS)

All off-chain data **must be reproducible** from these contracts.

### Off-chain (derivative)
Indexers MAY:
- cache view calls
- denormalize state
- accelerate queries

Indexers MUST NOT:
- compute VS independently
- invent semantics
- override on-chain results

---

## Indexed Entities

### Claim
- postId
- creator
- timestamp
- text

Source:
- PostRegistry.PostCreated
- PostRegistry.getPost
- PostRegistry.getClaim

### Link
- postId (the link's own post ID)
- fromPostId (evidence provider)
- toPostId (evidence receiver)
- isChallenge

Source:
- PostRegistry.PostCreated (contentType = 1)
- PostRegistry.getLink
- LinkGraph.EdgeAdded

### Stake Summary
- postId
- supportTotal
- challengeTotal

Source:
- StakeEngine.getPostTotals

### User Stake
- postId
- userAddress
- side
- amount
- weightedPosition

Source:
- StakeEngine.getUserStake
- StakeEngine.getUserLotInfo

### Score Snapshot (cached)
- postId
- baseVSRay
- effectiveVSRay
- blockNumber

Source:
- ScoreEngine view calls

---

## Event Sources

Indexers MUST subscribe to:
- PostRegistry.PostCreated
- LinkGraph.EdgeAdded
- StakeEngine.StakeAdded
- StakeEngine.StakeWithdrawn
- StakeEngine.PostUpdated
- StakeEngine.PositionsRescaled (informational)

View calls MAY be executed after event ingestion.

---

## Query Patterns

Supported queries include:
- claim detail pages
- incoming/outgoing link graphs
- VS visualization
- stake distributions
- historical VS snapshots
- user portfolio (all positions for an address)

---

## Rebuild Guarantees

A valid indexer must be able to:
1. Start from block 0
2. Replay all events
3. Call only public view functions
4. Reconstruct indexed state exactly

Failure implies a non-compliant indexer.

---

## Artifacts

Non-textual artifacts (images, videos, PDFs):
- are optional
- are off-chain only
- have no protocol semantics
- are referenced only via claim text

Indexers may ignore them entirely.
