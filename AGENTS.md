# AGENTS.md

Instructions for AI coding agents working in this repository.

## Project overview

OS-FORGE v0.1.1 — самодостаточный автономный батник: карта среды (железо+ОС по фактам) → решение → сеть (репозиторий пунктов) → сборка актуальной ОС → готовый ISO с манифестом. Windows (cmd+PowerShell) и Linux (bash+xorriso). Ноль прав администратора.

## Commands

No build or test commands are configured at the repository root. Inspect existing
files and follow the patterns already used in this codebase before making changes.

## Conventions

- Keep changes minimal and focused; one logical change per commit.
- Never commit secrets, tokens, or credentials.
- Update README.md when behavior or structure changes.
- Run any available checks before committing.
