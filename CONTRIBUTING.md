# Contributing

First off, thank you so much for considering a contribution to this project. We welcome contributions from everyone!

<br/>

## Table of Contents

-   [1. How can I contribute?](#1-how-can-i-contribute)
-   [2. Guidelines](#2-guidelines)
    -   [2.1 Git commit messages](#21-git-commit-messages)
    -   [2.2 Coding style guide](#22-coding-style-guide)
-   [3. Code Review Process](#3-code-review-process)
-   [4. Community and Communication](#4-community-and-communication)
-   [5. Releasing](#releasing)

<br/>

[//]: # '## 1. How can I contribute?'

## How to Contribute?

Contributing is simple. Here's how you can do it:

1. **Identify an Issue**: Look for existing [Issues](https://github.com/stoicswe/Endfield_FineWine/issues) or create your own explaining the feature or fix.
2. **Fork the Repository**: Click on the fork button in the top right corner.
3. **Clone the Repository**: After forking, clone the repo to your local machine to make changes.
4. **Set up Your Environment**: Set up the repository by following the Quick Start section of the [README.md](README.md).
5. **Create a New Branch**: Before making any changes, switch to a new branch:
    ```bash
    # For bugs:
    git checkout -b bug/your-new-branch-name
    
    # For features:
    git checkout -b feature/your-new-branch-name
    ```
6. **Make Changes**: Implement your feature or fix.
7. **Run Tests**: Ensure your changes do not break any existing functionality.
8. **Write Commit Messages**: Please try to make your commit messages adequately descriptive.
9. **Push to GitHub**: After committing your changes, push them to GitHub:
    ```
    git push origin your-new-branch-name
    ```
10. **Submit a Pull Request**: Go to your repository on GitHub and click the 'Compare & pull request' button. Fill in the details and submit.

<br/>

[//]: # '## 2. Guidelines'

## Guidelines

[//]: # '### 2.1 Git commit messages'

### Commit Messages

While we do not have a distinct commit message style, it is best to ensure that your commit message contains enough description as to what the goal of the commit is.

[//]: # '### 2.2 Coding style guide'

### Coding Style Guide

We follow the standard practice for C++ coding styles.

```cpp
namespace MyNameSpace {
  class MyClass {
  
  public:
    void myFunction() {
      // Do something
    }
  }
}
```

<br/>

[//]: # '## 3. Code Review Process'

### Code Review

All submissions, including submissions by project maintainers, require review. We use GitHub pull requests for this process. If your pull request is particularly urgent, please mention this in the request.

<br/>

[//]: # '## 4. Community and Communication'

### Community and Communication

Follow discussions in the [GitHub Issues](https://github.com/{username}/{repo}/issues) section of our repository.

<br/>

[//]: # '## 5. Releasing'

## Releasing

Full releases are cut from a `release/<version>` branch. Pushing to one (for example
`release/1.0.1`) runs [`.github/workflows/release.yml`](.github/workflows/release.yml), which
builds the complete artifact set (patched Wine + MoltenVK + `FineWine Patcher.app`) and publishes
a full GitHub Release:

-   **Tag:** `<version>` (bare, matching the existing `1.0.0` tag — no `v` prefix).
-   **Title:** `Endfield FineWine <version>`.
-   **Assets:** `FineWine.Patcher.app.zip`, `endfield-wine-modules.tar.gz` (Wine + MoltenVK, for
    `scripts/apply-modules.sh`), and `SHA256SUMS.txt`.
-   **Notes:** a human-readable summary of the commits since the previous release, generated with
    the same OpenRouter/LLM backend as the wiki (`OPENROUTER_API_KEY` secret; model from
    `.git-wiki-builder.yml`). If the model is unavailable it falls back to the raw commit list, so a
    flaky free-tier model never blocks a release.

The `.app`'s `CFBundleShortVersionString` is set from the branch version, so it reports the version
it was released as.

To cut a release:

```bash
git checkout main && git pull
git checkout -b release/1.0.1
git push origin release/1.0.1      # triggers the release workflow
```

Then watch the run under **Actions → release**; the published release appears at
`https://github.com/stoicswe/Endfield_FineWine/releases/tag/1.0.1`.

Notes:

-   The version must be `x.y.z`. The previous release is detected from the numeric git tags, so
    always tag releases as bare versions (`1.0.1`, not `v1.0.1`).
-   Re-pushing to the same `release/<version>` branch refreshes the existing release in place.
-   To publish an explicit version without a branch, use **Actions → release → Run workflow** with
    the `version` input.
-   Nightly snapshots are separate: every nightly run publishes a new prerelease whose tag
    mirrors its title, `nightly_<CrossOver version>.<UTC date>_<commit>`, so each snapshot
    keeps its own assets; see
    [`.github/workflows/nightly.yml`](.github/workflows/nightly.yml).
