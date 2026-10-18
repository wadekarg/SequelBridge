**What a user notices**

**How it is tested**
- [ ] A test that failed before this change and passes after it
- [ ] `scripts/run-all-tests.sh --hermetic` green
- [ ] Full matrix green, if the change touches an engine, the planner or a write path

**Docs**
- [ ] The guide pages still describe what the app does (`scripts/check-docs.sh` green)
