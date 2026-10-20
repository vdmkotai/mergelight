# Mergelight

Your GitHub pull requests in the macOS menu bar, with CI, reviews and merge state as separate signals, and a Merge button right in the row.

```
 ⑂ ●1 ●2 ●2          ready to merge · need attention · CI running

 WORK · ACME  7                                  1 ready · 1 failing · 2 running
                                               CI       REVIEW      MERGE
 ▌ #2591 fix(migrations): merge the heads…    ✔ 14       (A)✓     [ Squash ▾ ]
 ▌ #2578 feat: keep old addresses as…         ◔ 9/14   (C)…(D)…   Needs review
 ▌ #2589 feat(chat): fold interim narration   ✖ 2 failed (A)±(B)✓  Changes req.
 ▌ #2514 feat(chat): drafts an accountant…    ✔ 14     (A)✓(D)✓   Behind
```

## Features

- **Three columns per PR.** CI shows passed / running / failed counts with a progress ring. Review shows reviewer avatars with approved / changes requested / pending badges. Merge shows what's blocking: ready, behind, conflicts, CI failing, needs review, auto-merge, draft.
- **Click a row** to open the PR in your default browser. ⌥-click, or the chevron on hover, shows its checks and reviewers instead.
- **Merge from the menu bar.** Hover a ready PR and click Merge, or pick squash / merge / rebase from the split button. Asks for confirmation by default; one-click mode is a setting. Merges send the head commit, so GitHub refuses if someone pushed in the meantime.
- **Other actions.** Update branch, re-run failed GitHub Actions jobs, enable or disable auto-merge, mark ready for review, admin merge (always confirmed), open, and copy branch or link.
- **Sections.** Each section is a GitHub search query with a name, color and position. Defaults: one per organization, Personal, Elsewhere (contributions to other people's repos) and Review requests. Per section you can include or exclude repositories, hide it when empty, and choose whether it counts in the menu bar.
- **An honest count.** A PR you merge from the app disappears immediately. A PR merged in the browser disappears on the next status refresh (10–30 s), even while GitHub's search index still lists it.
- **Notifications** for CI failed or passed, approvals, requested changes, merge conflicts, auto-merges and new review requests. Clicking one opens the PR.
- **Fast.** Native AppKit + SwiftUI, about 3 MB. The panel opens instantly from a cached snapshot and refreshes in the background.

## Install

Build from source (Xcode 26 or newer, macOS 14 or newer to run):

```sh
git clone https://github.com/vdmkotai/mergelight.git
cd mergelight
scripts/build-app.sh --run      # builds dist/Mergelight.app and launches it
```

The script signs with your Developer ID if the keychain has one, otherwise ad-hoc. Move `dist/Mergelight.app` to `/Applications` and turn on **Launch at login** in Settings.

## Sign in

Click the menu bar icon and pick one:

- **Use GitHub CLI login.** Takes the token from `gh auth token`. Easiest if you use `gh`.
- **Paste a token.** A classic personal access token with `repo` and `read:org` scopes.
- **Sign in with GitHub.** OAuth device flow. Available in builds made with `GITHUB_CLIENT_ID` set: register an OAuth App under GitHub → Settings → Developer settings, enable *Device Flow*, then `GITHUB_CLIENT_ID=Iv1… scripts/build-app.sh`. Organizations that restrict third-party OAuth apps have to approve it first.

The token lives in your login keychain. Mergelight talks only to `api.github.com` and caches the last dashboard in `~/Library/Application Support/Mergelight`.

## How refreshing works

Two kinds of refresh keep the count accurate without wasting API budget:

| | What it does | When |
|---|---|---|
| **Status** | Re-reads the PRs already shown via `nodes(ids:)`, in batches of 10 | Every 30 s by default; every 15 s while CI runs; every 10 s while the panel is open |
| **Full** | Runs each section's search in parallel (IDs only), then loads each distinct PR once | At least every 60 s, when the panel opens on data older than 20 s, after wake and when the network returns |

A typical refresh costs 2–8 of the 5,000 GraphQL points per hour. On errors the app backs off up to 5 minutes and keeps showing cached data; near the rate limit it waits for the reset.

## Development

```sh
swift build
swift test --skip LiveTests                                  # offline, uses a fake GitHub
MERGELIGHT_LIVE_TOKEN=$(gh auth token) swift test --filter LiveTests   # read-only, real API
```

- `Sources/MergelightKit`: everything testable without a window server. Domain models, the GraphQL client and its queries, mapping from wire types, dashboard derivation, notification diffing, refresh policy, snapshot cache and auth.
- `Sources/Mergelight`: the app shell. `AppModel` is the single observable source of truth; `RefreshScheduler` serializes refreshes; `PanelController` hosts the SwiftUI panel in a non-activating `NSPanel`; `StatusItemController` renders the menu bar title.

Debug builds accept `-SignInWithGitHubCLI YES` and `-OpenPanelOnLaunch YES` as launch arguments.

## License

[MIT](LICENSE)
