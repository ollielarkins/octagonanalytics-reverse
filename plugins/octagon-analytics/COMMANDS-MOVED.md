# The commands moved

The 56 slash commands that used to live in `plugins/octagon-analytics/commands/` are now in the
**octagon-plugins** repo, inside the `octagon-dashboard` plugin:

    github.com/ollielarkins/octagon-plugins
    plugins/octagon-dashboard/commands/

**Edit them there, not here.** This directory no longer holds a copy, deliberately — two copies of
the same command drift, and the one that gets edited is never the one that ships.

## Why they moved

`octagon-analytics` was never installed by anyone. Its marketplace was not registered in any
`known_marketplaces.json`, so every command written here was unreachable. `octagon-dashboard` is
the plugin the team actually has.

The stronger reason is access: installing a plugin from this repo means pointing every recruiter's
Claude at the engineering repo — Supabase migrations, edge-function source, RecruitCRM integration
detail. The octagon-plugins repo exists so that is unnecessary, and it bundles no credentials.

## What is still here

`.mcp.json` and `hooks/` remain, as the record of how the connector and the session-start dashboard
hook are configured. They are NOT bundled into the shipped plugin: it uses the org's existing
Octagon connector instead, so adding an `.mcp.json` there would define a duplicate.
