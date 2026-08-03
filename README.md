# Intellectual Club

**A self-hosted LLM chat frontend for power users, with advanced agentic capabilities.**

Intellectual Club is a general-purpose environment for working with language models and agents. It combines configurable models, reusable knowledge, tools, and a branching chat interface into a flexible foundation for research, writing, coding, roleplay, and other long-running tasks.

The project is designed primarily for local or self-hosted use by individuals and small teams who want direct control over the agent harness—not a black-box assistant or a centrally managed enterprise chat portal.

## Core values

### Reliability

Core workflows should keep working under adverse conditions. Tasks are designed to survive client disconnects, server restarts, and transient provider or tool failures whenever recovery is possible.

### Transparency

No hidden magic. Users should be able to understand what the system is doing and why from the interface itself, without having to inspect server logs.

### Control

Users own and manage the complete model context: system prompts, tools, knowledge, and conversation history. The goal is to include everything a task needs—and nothing it does not.

## Key concepts

- **A universal agent building kit.** Combine a model, knowledge blocks, tools, and a chat interface to create an environment for almost any task.
- **Branching conversation history.** Branches are a first-class alternative to destructive rerolls and message swipes. Explore several directions without losing the path that led to them.
- **Knowledge as a managed library.** Knowledge blocks can become parts of a system prompt, dynamically loaded skills, character cards, or reusable instructions. They live in an organized, versionable library rather than an unstructured file dump.
- **System prompts are user data.** They are editable assets, not behavior hard-coded into the application.
- **Models and bots are independent.** LLM configurations describe how to call a model; bots describe the working setup around it. Trying the same task with another model is a standard workflow.
- **Orchestration is optional and explicit.** Handoffs with context compaction, subagents, and background tasks are exposed as tools that can be enabled or disabled. The application does not decide which orchestration pattern your work requires.

## How it relates to other projects

Intellectual Club borrows useful ideas from several adjacent product categories while making different trade-offs.

### LibreChat and Open WebUI

These are the closest direct alternatives: general-purpose, self-hostable chat frontends that support multiple model providers and agentic features.

**What Intellectual Club does differently:** LibreChat is often a better fit for centrally administered environments where an administrator configures the system and most users receive a simplified interface. Intellectual Club is built first for advanced users who benefit from controlling the full harness. Shared bots and collaborative use are supported, but the intended model is a group of capable peers rather than a strict administrator–consumer split.

LibreChat and Open WebUI also offer broader catalogs of ready-made integrations, providers, and RAG features. Intellectual Club prioritizes a smaller, dependable core over maximum feature count.

**Choose them when:** you need a large integration ecosystem or a more conventional enterprise deployment model.

### Devin and OpenHands

Coding agents demonstrate that a container and a shell are often more useful than a large collection of narrowly specialized tools. Direct API access through standard command-line clients can be more flexible than a dedicated MCP integration, and mature libraries usually outperform bespoke image, document, or data-processing tools. A capable agent should be able to obtain the tools it needs instead of being limited to workflows anticipated by the application developer.

Some environments should not expose a container, so specialized tools still have a place. In practice, however, most complex agent work benefits from a general-purpose execution environment.

**What Intellectual Club does differently:** Devin and OpenHands are coding products, with interfaces and workflows optimized for software development. Intellectual Club is a general-purpose environment.

**Choose them when:** software development is your primary use case and a specialized coding UX matters more than a flexible everyday agent workspace.

### SillyTavern

SillyTavern gives users unusually deep control over context: system prompts, internal prompts, and conversation history are visible and editable. It also treats message swipes as a core interaction rather than a simple “regenerate” button. Intellectual Club extends that idea into fully branching conversation history.

**What Intellectual Club does differently:** SillyTavern is primarily a roleplay frontend and provides only basic agentic capabilities. Intellectual Club focuses on reliable generation and agent loops, a structured library of reusable and versionable knowledge blocks, and history management that remains practical across thousands of chats.

**Choose SillyTavern when:** frontend customization and compatibility with its large ecosystem of presets and character cards are the priority. Intellectual Club intentionally avoids making opaque third-party presets the center of the workflow: control is only useful when users can understand what they have added to the context.

### OpenClaw and Hermes

These projects show how useful a highly autonomous agent can become when it receives enough access to handle a wide range of everyday personal and professional tasks.

**What Intellectual Club does differently:** OpenClaw and Hermes favor a more “magical,” personality-driven autonomous-assistant experience. Intellectual Club favors inspectability: context, tools, progress, and orchestration should remain explicit enough to understand and correct.

**Choose them when:** you want a proactive autonomous assistant and prefer minimal manual involvement. Choose Intellectual Club when dependable execution and visibility matter more, and you are willing to do a modest amount of context management.

## Deliberately out of scope

- **Compensating for weak models.** The project does not accumulate prompt tricks and workflow workarounds solely to make underpowered models usable.
- **Fixed workflows and pipelines.** Intellectual Club is not an n8n or Dify replacement. Repeatable workflows can be implemented through tools without making a visual pipeline the core abstraction.
- **A zero-learning-curve interface.** Productive control over LLMs and agents requires some understanding of how they work. The interface targets capable users rather than hiding every important concept for casual use.
- **Full-scale multi-tenant SaaS.** Enterprise SSO and deployments with large, isolated tenant populations are not current goals. The focus is local or self-hosted use and collaboration within small teams.
- **Built-in RAG.** Retrieval systems can be connected through tools when needed.
- **Container and environment lifecycle management.** For now, users or administrators choose how execution environments are provided—for example, by running an outlet on a desktop, inside a container, or against a remote machine over SSH.

## Architecture

### Technology stack

| Layer | Technology |
| --- | --- |
| Database | PostgreSQL |
| Backend | Elixir, Phoenix, and Ash |
| Frontend | Vue 3 and TypeScript SPA |
| Native tools | Rust |

### Design decisions

- **Polling instead of WebSockets for browser streaming.** Because the project does not target hyperscale cloud deployments, it can trade a modest increase in web-server load for simpler recovery, predictable snapshots, and fewer state synchronization edge cases.
- **Outlets invert the usual MCP topology.** An outlet tool runner acts as a client of the Intellectual Club server instead of requiring every tool to expose a server endpoint. This keeps network infrastructure simple: only the main application server needs to be reachable. Outlet transport is polling-based for the same reliability reasons as browser streaming.
- **BEAM processes provide lightweight concurrency.** Generation and background-task workers run under OTP supervisors, while durable lifecycle state is stored in PostgreSQL through Ash and recovered after restarts. No separate job queue or scheduler is required, which simplifies installation.
- **The desktop launcher uses portable PostgreSQL rather than SQLite.** SQLite support was removed because maintaining a second database backend imposed substantial complexity. The launcher manages PostgreSQL while preserving a desktop-style experience.
- **Ash is the access-control and integrity boundary.** Policies, validations, and data access live in Ash resources. The generic JSON API is safe by construction, the BFF remains thin, and direct database access is prohibited except for narrowly justified and encapsulated cases.

For a more detailed description, see [System Design](docs/system-design.md) and the [Outlet Architecture](docs/outlets.md).

## Project status

The architecture is stable. The current version is a complete rewrite informed by the development and production operation of the original Python/Django implementation.

The system is largely feature-complete. Ongoing work focuses on additional tools and model providers, UX improvements, bug fixes, and refactoring.

Potential major future features include:

- a containerless code interpreter with programmatic tool calling;
- built-in container and execution-environment management;
- complete self-management tools, making everything visible or actionable in the user interface available to agents as well.

Intellectual Club is actively used in production, but by a relatively small user base. The least-tested areas are native tools on Windows, the mobile frontend on Android, less common LLM providers, and installations with hundreds of concurrent users.
