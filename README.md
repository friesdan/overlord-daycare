# Merge-train coordinator for AI coding agents

A write-up of one way to run software work with AI coding agents: a single long-running coordinator agent that talks to the human and decides, worker "lanes" on various models that do the editing, and independent models that review.

- [`HOW-WE-WORK.md`](HOW-WE-WORK.md): the method and the reasoning behind it. Hand it to your agent.
- [`coordinator-skill/SKILL.md`](coordinator-skill/SKILL.md): the same method as an installable Claude Code skill. Fill in the `<<YOUR …>>` placeholders for your own setup.

It describes a method, not a product. There's no code to run, and you build your own scripts.
