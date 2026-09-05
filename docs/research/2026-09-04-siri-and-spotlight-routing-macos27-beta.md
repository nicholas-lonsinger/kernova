# What reaches Kernova's intents from Siri and Spotlight on a macOS 27 beta

**Date:** 2026-09-04 · **Host:** macOS 27.0 beta (26A5425a) with Apple Intelligence on, Xcode 27.0 SDK, Debug build 765 installed in `/Applications`, deployment target 26.0 · **Library:** six VMs, one named `peanut`

## Read this first

Everything below was observed on one beta of macOS 27 on one Mac, in one
evening. It describes how that build of Siri and Spotlight behaved, not how
either is specified to behave, and nothing here was reproduced on a second
machine, on the release OS, or on macOS 26. Treat every statement as
"observed once, on a beta". A later OS can change any of it, and the retest
recipe at the end exists so the next reader re-observes rather than trusts.

## Summary

- Every intent that was actually invoked ran correctly. No request that
  reached Kernova failed inside Kernova.
- Spotlight showed a Run row when the typed text matched an intent's
  **title**. It showed none for an App Shortcut phrase, with or without an
  entity slot.
- Spotlight found a VM by name through the entity index. Return on that
  result launched the app and did nothing else.
- Siri did not invoke any Kernova intent by any route tried: spoken, typed,
  a phrase with an entity slot, a phrase without one, or a Siri-suggestion row
  in Spotlight. Each request was interpreted by Siri's own orchestrator.
- The App Shortcuts Kernova declared at the time were donated by `linkd` on
  every launch and nothing observed ever executed one.

## Observations

| Input | Where it went | Outcome |
|---|---|---|
| Shortcuts app, any Kernova action | Shortcuts runner → intent | ran |
| Spotlight, "Start Virtual Machine", pick a VM | Run row → intent | ran |
| Spotlight, "ping Kernova" (control intent titled "Ping Kernova") | Run row → intent | ran; `PingIntent.perform()` logged |
| Spotlight, "Say hello in Kernova" (a phrase of the same control shortcut) | no Run row | only Siri-suggestion rows |
| Spotlight, "start peanut in kernova" | no Kernova row | web and Finder rows only |
| Spotlight, "virtual machine" | Run rows | every intent whose title contains it, App Shortcut or not |
| Spotlight, "peanut", Return | entity record → app launch | app opened, VM not selected |
| Siri, spoken "Start peanut in Kernova", three attempts | search tool, then app launch | app opened, no intent |
| Siri, typed "start peanut in Kernova" | in-app search | "I can't search within Kernova." |
| Siri, spoken "Ping Kernova" | Find My | wrong app |
| Siri, spoken "Say hello in Kernova" | language answer | no app |
| `linkd`, every launch | donation | "Generated 5 AppShortcuts with 44 total phrases … donating to Siri" |
| System Settings → Kernova → Learn from this application | on | — |

The control shortcut was added for the evening and removed afterwards.

## What the logs showed for the spoken request

Captured with `log stream` over `process == "Kernova" OR process == "linkd" OR
process == "searchtoold" OR process == "assistantd"`. The narrower capture
used first, `linkd` and `assistantd` plus Kernova's own subsystem, could not
see either the search tool's query or the App Intents framework's lines inside
Kernova's process, and read as "nothing reached Kernova" without saying why.

1. `assistantd` opened a session and handed the request to its orchestrator.
2. `searchtoold` ran an app-entity Spotlight query for the VM name
   (`isAppEntitySearch=1`) with this filter, verbatim:

   ```
   (_kMDItemBundleID="com.apple.*" || _kMDItemAppEntitySchema=* || kMDItemFileProviderID=* || _kMDItemFileName=*)
   ```

   and logged `No results to rank`. Kernova's VM records carry none of those
   attributes: the entity conforms to `IndexedEntity` and to no
   `AppEntitySchema`, and the SDK's schema domains (Books, Browser, Camera,
   Files, Journal, Mail, Photos, Presentation, Reader, Spreadsheet, System,
   Visual Intelligence, Whiteboard, Word Processor) have no shape a VM fits.
3. `searchtoold` ran a plain app-name search (`isAppEntitySearch=0`), found
   the app, and `assistantd`'s `SiriAppLaunchSnippetProvider` launched it.
4. Kernova logged a user-style launch and the App Intents framework's
   per-launch parameter refresh. No `perform()` of any intent was invoked.

The typed request went through the `system.search` schema instead, which maps
to `ShowInAppSearchResultsIntent`; Kernova declares none, hence the reply.

## Method notes worth keeping

- App Intents framework lines inside the app (`com.apple.appintents:Execution`,
  "Invoking X.perform()") are debug-level. They appear only while a stream is
  running; `log show` after the fact does not have them.
- `linkd` re-donates App Shortcuts on every launch and on every library
  change; its `Generated N AppShortcuts with M total phrases` line is the
  phrase-template count times the VM count, and confirms the slot was filled
  with live names.
- A build must be installed in `/Applications` and launched once before
  Spotlight or Siri will see its intents at all.

## Retest

On a later macOS build, install the app in `/Applications`, launch it once,
start the four-process `log stream` above, and repeat the table's inputs in
order. The two rows most likely to change with the OS are the spoken "Start
⟨vm⟩ in Kernova" and Return on a Spotlight VM result; a change in either one
is a reason to revisit what Kernova declares, not a reason to trust this note.
