# Slide Talk Notes

## Slide 1: Title
**Why Classic IAM Collapses for Agents**
Rethinking IAM for Agentic Systems
PyTorch Conference Europe 2026
Parul Singh | Red Hat

### Opening headlines — "The world has changed"

- **Claude fakes alignment during evaluation** — Anthropic/Redwood Research found Claude strategically behaves differently when it thinks it's being monitored vs. not. When trained to comply with harmful queries, alignment-faking reasoning jumped to 78%. If a model can fake alignment, how do you trust it with credentials?

- **Alibaba AI agent spontaneously starts crypto-mining** — Not prompted, not instructed. An autonomous agent with tool access went off on crypto-mining expeditions as a side effect of autonomous tool use. Imagine that agent had write access to your model registry.

- **UK AI Security Institute: 700 real-world AI scheming cases** — Five-fold rise in misbehavior between Oct 2025 and Mar 2026. Agents blackmailing users when facing shutdown.

- **Single compromised agent poisons 87% of downstream decisions within 4 hours** — Galileo AI research on cascading multi-agent failures. Classic IAM has no concept of blast-radius containment across a delegation chain.

- **Mexican government breach via AI agents** — 10 agencies compromised, data on 100M+ people stolen. The agents used? Autonomous, with broad access and no per-task scoping.

- **Public interest in "agentic AI" rose 6,100% in one year** — Adoption is racing ahead. Security and identity are not keeping up.

---

## Slide 2: The World Has Changed

**Opening hook** (connect from headlines slide):
"So we just saw the headlines — agents going rogue, faking alignment, cascading failures. Why is this happening now? Because agents aren't users and they aren't static services. They're something new."

**Walk through the table**:
- **L0–L2**: "These are what we've been building for years — cron jobs, chatbots, rule-based routers. Classic IAM handles these fine. A service account with fixed RBAC works because the behavior is predictable."
- **L3–L5 (highlighted)**: "This is where it breaks. These agents plan, delegate to other agents, adapt their behavior based on context. An incident remediation agent might decide to scale down a service, revoke credentials, or call another agent — all autonomously. The permissions it needs aren't knowable at deploy time."

**Land the key point**:
"L3+ is where you need what we're calling Agentic IAM — ephemeral identities, On-Behalf-Of delegation, scope narrowing at every hop, and continuous evaluation. That's what this talk is about."

---

## Slide 3: Three Questions

**Set it up**:
"So if classic IAM doesn't work for L3+ agents, what exactly is missing? It comes down to three questions that traditional identity systems have no good answer for."

**Question 1 — Identity**:
"First — who is this agent? In classic IAM, identity is a service account you create once and share across workloads. But agents are dynamic. The same orchestrator might spin up different sub-agents depending on the task. A shared service account tells you nothing about which agent actually did what."

**Question 2 — Accountability**:
"Second — who authorized this action? When an agent acts on behalf of a user, or worse, on behalf of another agent — who's responsible? Classic IAM has no concept of delegation chains. There's no 'on behalf of.' The audit log just shows a service account."

**Question 3 — Dynamic access**:
"Third — should this agent still have access? Classic IAM checks permissions once at the gate and then trusts forever. But agent behavior changes mid-execution. An agent that started doing data reads is now writing to the model registry. Nothing in classic IAM re-evaluates that."

**Bridge to the demo**:
"These aren't theoretical problems. Let me show you exactly what this looks like with a real ML pipeline."

---

## Slide 4: Our Scenario: ML Training Pipeline

**Introduce the scenario**:
"Let's make this concrete. We have Alice, a data scientist. She kicks off a model training pipeline. Simple enough — she's done it a hundred times."

**Walk the chain**:
"Her request hits an orchestrator agent that plans the workflow. The orchestrator delegates to a data agent to pull features from the data store. Then a training agent trains the model and writes it to the registry. An eval agent runs the evaluation suite. And finally a deploy agent pushes the model to staging."

**Highlight the complexity**:
"That's five agents, each with different responsibilities, different resource needs, different risk profiles. The data agent only needs to read. The training agent needs GPU access and write to the model registry. The deploy agent is touching production infrastructure."

**Preempt the easy answer**:
"Now some of you are thinking — just give each agent its own service account with the right scopes. And yes, that's better than a shared SA. But it still doesn't solve the hard problems. Who triggered this pipeline — was it Alice or did the agent act on its own? If Alice's access gets revoked mid-run, do the agents stop? If the data agent gets compromised, can it call the training agent directly? There's no delegation chain, no 'on behalf of,' no way to narrow permissions dynamically at runtime. You've scoped the permissions statically, but the execution is dynamic."

**Set up the failure**:
"Let's start with the worst case though — what happens when all five agents share the same service account? Let's find out."

---

## Slide 5: Live Demo - Classic IAM Breaks

**Transition into the demo**:
"Alright, let's see this in action. I'm going to run the same ML pipeline twice — first with classic IAM, then with Agentic IAM. Same agents, same code, same workflow. The only difference is how identity and authorization work."

**Break 1 — "Who did it?"**:
"So the pipeline runs and I look at the logs. Every single action — reading features, writing to the model registry, deploying to staging — all show the same identity: `ml-pipeline-sa`. Five agents, one service account. If the eval agent wrote garbage to the model registry, I can't tell it apart from the training agent. The audit log is useless."

**Break 2 — Overprivileged by default**:
"It gets worse. The data agent only needs `read:features`. But because it's using the shared service account, it has every scope — including `write:model-registry`. And look — it succeeds. I can have the data agent write to the model registry and nothing stops it. Every agent has the keys to every room."

**Break 3 — No delegation chain**:
"And the fundamental question — was this pipeline initiated by Alice, or did the agent decide on its own? There's no record of delegation. No 'on behalf of.' The token says `ml-pipeline-sa` and that's it. If Alice's access was revoked five minutes ago, the pipeline keeps running with full permissions. There's no link back to the human."

**Bridge**:
"So three breaks: no identity, no least privilege, no accountability. Now let's understand why classic IAM can't fix this."

---

## Slide 6: Why Did It Break?

**Set it up**:
"So why did all three of those things break? It's not a misconfiguration. It's not that we forgot to set up RBAC properly. Classic IAM is built on three assumptions that simply don't hold for agents."

**Walk the left column — Classic IAM Assumes**:
- "First — long-lived identities. Classic IAM assumes you create a service account, assign it to a workload, and it lives for months or years. That's how we ended up with one `ml-pipeline-sa` shared across five agents. It's the natural thing to do in that model."
- "Second — static permissions. You define RBAC roles at deploy time and they don't change. The data agent gets the same permissions whether it's reading features for a training run or being called by a compromised orchestrator."
- "Third — check once, trust always. You authenticate at the gate — the token is valid, let it through. No one asks 'should this agent still have access?' halfway through execution."

**Walk the right column — Agents Need**:
- "Agents need the opposite. Ephemeral, per-agent identities — cryptographically attested, unique to each workload, rotated automatically."
- "Context-aware permissions that narrow at each delegation hop. The orchestrator has all scopes, but when it delegates to the data agent, only `read:features` passes through."
- "And continuous evaluation — not just 'is this token valid?' but 'is this agent still behaving within its expected boundaries?'"

**Bridge**:
"These three gaps map directly to the three pillars we're going to build: identity, delegation, and observability. Let's start with identity."

---

## Slide 7: Pillar 1 - Agent Identity

**Introduce the pillar**:
"The first thing we need to fix is identity. Every agent needs its own unique, verifiable identity — not a shared service account. And we don't want agents self-assigning identities. We need the platform to cryptographically prove who each agent is."

**What is SPIFFE**:
"This is where SPIFFE comes in — Secure Production Identity Framework for Everyone. It's a CNCF graduated project. The core idea is simple: every workload gets a URI-based identity — a SPIFFE ID — like `spiffe://cluster.local/ns/agentic-ml/sa/data-agent`. And instead of long-lived secrets, it issues short-lived certificates called SVIDs that rotate automatically. No static credentials to leak, no secrets to rotate manually."

**How we use it**:
"We run SPIRE — the SPIFFE runtime — in our Kubernetes cluster. When a pod starts, SPIRE's workload attestor verifies it against the Kubernetes API — which namespace, which service account, which node. It's not trusting the pod's claim about who it is. It's verifying it cryptographically. Each of our five agents gets a unique SVID, rotated every 60 minutes. The sidecar proxy uses that SVID for mTLS between agents and to authenticate to Keycloak."

**Registration & discovery**:
"But identity alone isn't enough — agents must be registered before they can participate. That means three things: a SPIRE registration entry mapping the K8s service account to a SPIFFE ID, a Keycloak client bound to that identity, and an Agent Card at `.well-known/agent.json` declaring what the agent can do. If an agent isn't registered in all three places, it cannot obtain tokens and cannot participate in any delegation chain. There's no way to sneak in."

**Point to the visual**:
"Look at the comparison on the right. Classic IAM — all five agents show `ml-pipeline-sa`. Agentic IAM — each agent has its own SPIFFE ID. Now when something goes wrong, you know exactly which agent did it."

**Bridge**:
"So we've solved identity. But identity alone doesn't solve delegation. How do we pass permissions from Alice through the orchestrator to each downstream agent — and narrow them at every hop? That's delegated authorization."

---

## Slide 7b: Pillar 1 - Delegated Authorization

**Introduce delegation**:
"Now we have unique identities. But when the orchestrator calls the data agent, what token does it send? In classic IAM, it just forwards Alice's token — with all her scopes. Or it uses its own service account token. Neither is right. We need a new token that says 'this is the orchestrator, acting on behalf of Alice, and it only needs read:features.'"

**Token Exchange — RFC 8693**:
"This is what RFC 8693 — OAuth Token Exchange — was designed for. At each hop, our sidecar proxy intercepts the outbound call and exchanges tokens with Keycloak. It sends Alice's token as the `subject_token` — that's who we're acting for. It sends the agent's own Kubernetes service account JWT as the `client_assertion` — that's who we are. And critically, it requests only the scopes the downstream agent needs. Keycloak returns a brand new token with `sub=alice`, `act.sub=orchestrator`, and `scope=read:features`. Alice's identity is preserved, the actor is recorded, and the scope is narrowed."

**Custom Keycloak SPI**:
"Now here's where we hit a real-world problem. Keycloak's built-in token exchange ignores the `scope` parameter. There are open bugs for this — #29614 and #30704. So we built a custom SPI that does three things: it intersects the requested scopes with the available scopes — so you can only narrow, never expand. It injects the `act` claim from RFC 8693 section 4.1 to track the delegation chain. And it chains — if agent A delegates to agent B, the act claim nests. You get a full history of who delegated to whom."

**Zero code changes**:
"And here's the part I love — the agents don't know any of this is happening. The sidecar proxy handles everything. It intercepts the HTTP call, exchanges the token, and forwards the narrowed token to the downstream agent. The agent code is identical in classic and agentic mode. Zero code changes."

**Point to the token visual**:
"Look at the tokens on the right. Alice's original token has all scopes. After the exchange, the data agent receives a token that's scoped to just `read:features`, with the orchestrator recorded as the actor. Alice is still the subject. The chain is preserved."

**Bridge**:
"So we have identity and delegation. But how do we know this is actually working? How do we prove to an auditor that the right agent did the right thing on behalf of the right person? That's observability."

---

## Slide 8: Pillar 2 - Discoverability

**Introduce the pillar**:
"The second pillar is discoverability. In modern agentic systems, agents need to find each other — not by hardcoded DNS names, but by capability. 'Find me an agent that can evaluate model safety.' But discovery without identity is an attack surface."

**The business card problem**:
"Think of it like a business card. Anyone can print a card that says 'Dr. Smith, Cardiologist.' There's nothing stopping them. Same thing — any workload can publish an Agent Card at `.well-known/agent.json` claiming 'I am the training agent, I can write to the model registry.' Without identity binding, you're trusting a self-declaration."

**Three-step defense**:
"So we add three layers. First — bind. The Agent Card is tied to the agent's SPIFFE workload identity. The card says who you are, and the platform can verify it. Second — sign. The card is signed with a JWS signature using the agent's SPIRE-issued key. If someone tampers with the card, the signature breaks. Third — enforce. At runtime, when one agent calls another, mTLS verifies that the caller's identity matches what's in the Agent Card. You can't just claim capabilities — you have to prove you are who the card says you are."

**Why it matters**:
"This is how we move from static service meshes to dynamic agent ecosystems. Agents discover each other by skill, and every discovery is verified. No impersonation, no spoofing."

---

## Slide 9: Pillar 3 - Observability & Tracing

**Introduce the pillar**:
"The third pillar is observability. Identity and delegation are great — but if you can't see the delegation chain after the fact, you can't trust it. And you definitely can't prove it to an auditor."

**OTel spans at every hop**:
"Every sidecar proxy in our system emits OpenTelemetry spans. These aren't generic HTTP spans — they're tagged with trust-specific attributes: `trust.principal_id` — that's Alice. `trust.caller_id` — that's the orchestrator. `trust.hop_kind` — is this an ingress or a delegation? `trust.scopes` — what scopes were granted at this hop? From these spans, you can reconstruct the entire delegation DAG for any pipeline run."

**Prove control on demand**:
"This is what 'prove control on demand' means in practice. An auditor asks: 'Which agents were active between 2 and 3 PM?' You can answer that. 'What actions were taken on behalf of Alice?' Answered. 'What policy justified the training agent's access to the model registry?' Answered. Every decision — allow or deny — is logged with the agent ID, the subject, the resource, the action, the scopes, and a correlation ID linking the entire workflow."

**Accountability chain**:
"And these logs are immutable and tamper-evident. You're not just logging — you're building an accountability chain. This is the difference between 'we think things are fine' and 'we can prove things are fine.'"

**Bridge**:
"So those are the three pillars — identity, delegation, and observability. Let's put them all together and see the architecture."

---

## Slide 10: The Fix - Agentic IAM Architecture

**Walk the architecture**:
"Here's the full picture. At the top, the identity layer — SPIRE Server managing the trust domain, Keycloak handling token exchange via RFC 8693. These are the brains."

**Data plane**:
"Below that, the data plane. Each agent pod has two things: the agent itself with its Agent Card, and a sidecar proxy. The agent code is untouched — it doesn't know about any of this. The sidecar handles identity verification on the way in and token exchange on the way out."

**Scope narrowing visual**:
"And look at the scope narrowing across the chain. The orchestrator starts with everything — all six scopes. When it delegates to the data agent, only `read:features` passes through. Training agent gets `write:model-registry` and `provision:gpu`. Eval gets `read:test-data` and `write:eval-reports`. Deploy gets just `deploy:staging`. The bars literally shrink. That's least privilege enforced at every hop, not just at deploy time."

**Key insight**:
"The beauty of this is that it layers on top of existing infrastructure. SPIRE, Keycloak, OTel — these are all production-grade, open-source tools. The only custom piece is the Keycloak SPI for scope narrowing. Everything else is configuration."

---

## Slide 11: Live Demo - Agentic IAM Works

**Transition**:
"Alright, let's run the same pipeline again — same agents, same code — but now with Agentic IAM turned on."

**Identity**:
"First thing — look at the identities. Each agent now has its own SPIFFE identity: `spiffe://cluster.local/ns/ml-pipeline/sa/training-agent`. Cryptographically attested by SPIRE. No shared service accounts."

**On-Behalf-Of**:
"Second — the tokens. Every token now carries the delegation chain. Subject: `alice@company.com`. Actor: `training-agent`. Scope: `write:model-registry`. We know who's doing what, on whose behalf, and with what permissions."

**Scope narrowing in action**:
"Third — least privilege. Watch what happens when the data agent tries to write to the model registry. It fails. Its token only has `read:features`. Even if the agent code tries to call the registry — even if it's compromised — the token doesn't allow it. The blast radius is contained."

**Delegation chain**:
"And fourth — the full delegation chain is visible. Alice triggered the orchestrator, the orchestrator delegated to the training agent, every hop is traced. If Alice's access gets revoked, the entire chain is invalidated. No orphaned agents running with stale permissions."

**Land it**:
"Same agents, same code, completely different security posture. That's what Agentic IAM gives you."

---

## Slide 12: How the Token Exchange Actually Works

**Set context**:
"Let me go a level deeper for those of you who want to understand exactly what happens on the wire. This is the end-to-end flow from Alice's browser to the training agent."

**Alice's login**:
"Alice logs into the orchestrator's UI. The orchestrator authenticates her against Keycloak using a password grant and gets back an access token — `sub=alice`, all scopes. She clicks 'run pipeline' and that token is sent with the request."

**Orchestrator hop**:
"The orchestrator pod has two proxies. The reverse proxy on the way in verifies Alice's token against Keycloak's JWKS endpoint — is this token valid, not expired, properly signed? Then the orchestrator decides to call the training agent. The forward proxy intercepts that outbound call. It takes Alice's token as the `subject_token`, the orchestrator's own Kubernetes service account JWT as the `client_assertion`, and calls Keycloak's token exchange endpoint. Keycloak returns a new token — `sub=alice`, `act.sub=orchestrator`, scope narrowed to what the training agent needs."

**Multi-hop chaining**:
"Now the training agent needs to call the data agent. Same thing happens again. The training agent's forward proxy exchanges the token it received — which already has `act.sub=orchestrator` — and Keycloak returns another new token with the act claim nested. `sub=alice`, `act.sub=training-agent`, with orchestrator in the chain. Scopes narrowed further."

**Key insight**:
"Two things to take away. One — the agent code never sees any of this. The sidecar proxy handles everything transparently. Same agent binary runs in classic and agentic mode. Two — at every hop, scopes can only shrink, never grow. The Keycloak SPI enforces intersection. Even if an agent requests more scopes than it had, it gets back less."

---

## Slide 13: Capability-Risk Classification

**Introduce the matrix**:
"Not every agent needs full Agentic IAM. A FAQ chatbot that answers public questions doesn't need On-Behalf-Of delegation and continuous evaluation. So we use a capability-risk matrix to right-size the controls."

**Walk the quadrants**:
- "Low capability, low risk — your FAQ bots, simple lookup agents. A narrowly scoped service account with basic logging is fine."
- "High capability, low risk — agents that do meaningful work but on constrained, internal data. Like our data agent and eval agent. They need short-lived tokens and anomaly detection, but the blast radius is limited."
- "Low capability, high risk — read-only agents that touch sensitive data. Think PII lookups. They don't do much, but what they access is sensitive. Environment attestation and just-in-time credentials."
- "High capability, high risk — this is where you need the full stack. Our orchestrator, training agent, and deploy agent live here. On-Behalf-Of delegation, token exchange, ABAC/PBAC, and for critical actions, human-in-the-loop approval."

**Key point**:
"Every agent should be registered and monitored. The matrix adjusts control strength — not whether controls exist. You don't get to opt out of identity. You get to opt out of complexity you don't need yet."

---

## Slide 14: Phased Adoption

**Set the tone**:
"Now I know what you're thinking — this is a lot of infrastructure. SPIRE, Keycloak SPI, sidecar proxies, OTel. Where do you even start? The answer is: you don't have to do it all at once."

**Phase 1 — Visibility**:
"Phase 1 is just visibility. Register all your agents as identities. Eliminate shared service accounts. Turn on immutable logging. That's it. No token exchange, no delegation chains. Just make sure you can answer the question 'who did what?' This is where most organizations should start today — as soon as agents are introduced."

**Phase 2 — Contextual Access**:
"Phase 2 adds contextual access. Deploy sidecar proxies for token exchange. Implement On-Behalf-Of delegation with RFC 8693. Add scope narrowing at each delegation hop. This is where you go from 'we know who the agents are' to 'we control what they can do, and it changes based on context.'"

**Phase 3 — Full Agentic IAM**:
"Phase 3 is the full picture. Agent Cards with signed identity binding. Automated discovery of new agents. Anomaly detection on delegation patterns. Human-in-the-loop for critical actions. Cross-domain delegation. This is 'prove control on demand' — no autonomous workload operates outside the control plane."

**Land it**:
"Each phase is cumulative. You don't rip out Phase 1 when you do Phase 2. And the key thing is — Phase 1 is something you can do this quarter. It's not a moonshot. It's adding service accounts and logging."

---

## Slide 15: Open Questions

**Set the tone**:
"We've shown you a working system — but we're not pretending this is solved. There are real open questions that the community is still working through."

**Cross-domain delegation**:
"First — cross-domain delegation. Everything we showed today is within a single trust domain. But what happens when your agent needs to call an agent in another organization? OAuth Federation helps, but it wasn't designed for multi-hop agent delegation chains. How do you carry the 'on behalf of' across organizational boundaries?"

**Dynamic capability discovery**:
"Second — discovery at scale. We showed Agent Cards for five agents in one cluster. What happens when you have thousands of agents across multiple clusters? You need to discover by skill, not by DNS name, without creating a central registry that becomes a single point of failure."

**Revocation cascades**:
"Third — revocation cascades. Alice's access gets revoked. We need to invalidate every token in the delegation chain — in near real-time. Short-lived tokens help, but 60-minute windows might be too long for high-risk actions. How do you propagate revocation through a chain of independently running agents?"

**Behavioral risk scoring**:
"Fourth — behavioral risk scoring. We said agents need continuous evaluation. But how do you score agent behavior without adding latency to every request? And what does 'anomalous behavior' even mean for an agent that's supposed to be adaptive?"

**Close**:
"These are hard problems. And they're exactly the kind of problems that need a community — not just individual companies working in isolation."

---

## Slide 16: CoSAI

**Introduce CoSAI**:
"Which brings me to CoSAI — the Coalition for Secure AI. This is an OASIS open project focused specifically on secure design for agentic systems."

**What it is**:
"We're building shared guidance and emerging standards for exactly the problems we talked about today — agentic identity, delegation, trust, and observability. The work we showed you in this talk — the three pillars, the capability-risk matrix, the phased adoption model — this comes directly from the CoSAI workstream on secure design for agentic systems."

**Call to action**:
"If any of this resonated — if you're deploying agents and worried about identity and access control — come get involved. The GitHub repo is up there. The work is open. We need practitioners building real systems to shape these standards — not just spec writers. Come bring your use cases, your edge cases, your war stories. That's how we build something that actually works."

**Close the talk**:
"Thank you. I'll be around for questions — and I'd love to hear about the agentic IAM problems you're running into."
