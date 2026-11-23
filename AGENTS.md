# Skills Chooser — Implementation Plan

## 1. Goal

Build an Emacs Lisp package, `skills-chooser.el`, that manages a project's AI skills from a grouped skill library. It will provide two interactive entry points:

1. `skills-chooser-update` scans the library and creates or refreshes `skills-list.org` in the workspace root.
2. `skills-chooser-apply` reads the current Org configuration, including unsaved changes in a visiting buffer, and makes the workspace's local skills directory match the selected entries. One workspace-wide Org checkbox chooses between linking and copying; it defaults to linking.

The local skills directory will default to `.agents/skills`. Refreshing the Org file must preserve existing choices, and applying it must be repeatable and must not delete files that Skills Chooser does not manage.

## 2. Configuration and dependencies

Define customization options with sensible defaults:

- `skills-chooser-library-directory`: the library root; initially `nil`, in which case the update command prompts for a directory and offers to save the choice.
- `skills-chooser-list-file`: `skills-list.org`, relative to the workspace root.
- `skills-chooser-target-directory`: `.agents/skills`, relative to the workspace root.

Do not add a separate global installation-method defcustom: the workspace method belongs to `skills-list.org`, so the file is the single source of truth. A newly generated file starts with linking selected.

Resolve the workspace once per command: use an explicitly supplied root for noninteractive calls, otherwise `project-root` from `project.el`, with a documented `default-directory` fallback. Both `skills-chooser-update` and `skills-chooser-apply` accept an optional workspace-root argument for programmatic use; the tests call the commands through this interface. All commands must display the workspace and library they are using so operations on the wrong project are easy to spot.

Use:

- `yaml.el` for real YAML parsing rather than a fragile regular-expression YAML parser.
- Built-in `org-element` for both reading and writing Org syntax: `org-element-parse-buffer` for parsing, `org-element-map` for extraction, org-element node accessors/constructors for transformation, and `org-element-interpret-data` for serialization. Use Org mode's checkbox commands for checkbox edits rather than inventing parallel syntax handling.
- Built-in `project`, `files`, `seq`, and `subr-x` functionality for the remaining work.

Target Emacs 29.1 or newer and declare the Emacs and `yaml` requirements in the package header. Keep filesystem policy separate from Org/YAML parsing so most behavior can be tested without interactive prompts.

## 3. Library inventory

Implement `skills-chooser--parse-front-matter` to accept complete `SKILL.md` text, parse only its delimited YAML front matter, and return a plist with normalized `:name` and `:description` values. Implement `skills-chooser--inventory` to accept a library root and return structured skill records rather than directly generating text. Each inventory record is a plist containing:

- `:name`: the YAML `name`, used both as the visible title and as the stable skill ID.
- `:group` and `:directory`: the group and skill directory names.
- `:source-directory` and `:skill-file`: absolute paths to the skill directory and its `SKILL.md`.
- `:description`: the normalized YAML `description` used for display.
- `:destination`: the proposed destination name, initially the skill directory name.

Assume this library layout:

```text
LIBRARY/
  clojure/
    clojisr/
      SKILL.md
    clojisr-plotting/
      SKILL.md
  wolfram/
    wolframite/
      SKILL.md
```

Inventory rules:

- Scan immediate, non-hidden group directories and their immediate, non-hidden skill directories; do not recursively discover arbitrary nested skills.
- Treat every immediate, non-hidden child directory of a group as a skill and require a readable `SKILL.md`. Ignore ordinary files, but report a missing skill file as a validation error with its directory path; do not silently skip a potentially misplaced or misspelled skill.
- Require front matter beginning with `---` on the first line and ending at a subsequent `---` or `...` delimiter.
- Parse only the front matter as YAML. Require nonempty string `name` and `description` values; normalize multiline descriptions to one readable line for the list.
- Rely on the library guarantee that there is exactly one example of each skill. Its YAML `name` is therefore a globally unique identity, independent of its group; group membership provides presentation and Install All behavior, not namespacing.
- Collect malformed-front-matter, missing-field, unreadable-file, and wrong-type errors with their paths. Do not overwrite an existing `skills-list.org` when discovery or validation fails.
- Sort groups and skills deterministically, using case-insensitive directory-name ordering with the original name as a tie-breaker.
- Do not execute code from the library or evaluate Emacs Lisp contained in skill files.

## 4. Org file format

Put one workspace-wide installation-method checkbox in the preamble, before all groups. Generate one top-level heading per group; under each heading put `Install All` first, followed by one checkbox per skill. Each skill item contains its description first and then a descriptive Org file link whose visible label is the skill title. Skill entries have no installation-method token. The generated source looks like this:

```org
#+TITLE: Project Skills
#+STARTUP: showall

- [ ] Copy skills instead of linking (whole workspace)

* clojure
- [ ] Install All
- [X] Call R from Clojure. [[file:/path/to/library/clojure/clojisr/SKILL.md][clojisr]]
- [ ] Render R plots from Clojure. [[file:/path/to/library/clojure/clojisr-plotting/SKILL.md][clojisr-plotting]]
```

The single `Copy skills instead of linking` checkbox controls every selected skill in the workspace: `[X]` means copy, while `[ ]` and `[-]` mean link. Generate it as `[ ]` in a new file, preserve its state on refresh, and normalize an intermediate `[-]` to `[ ]`. There are no per-group or per-skill method overrides.

Org's `org-link-descriptive` defaults to non-nil, so the rendered skill entries display only the description and title; the `file:` target and `SKILL.md` filename are hidden:

```text
- [X] Call R from Clojure. clojisr
- [ ] Render R plots from Clojure. clojisr-plotting
```

Use this descriptive-link format specifically to hide the source filename/path while retaining a clickable link to `SKILL.md`. When update creates or reverts a visiting buffer, set `org-link-descriptive` buffer-locally to `t` and refresh link display without changing the user's global setting. Document `org-toggle-link-display` for users who want to inspect the underlying links. Do not add property drawers or other per-skill metadata.

Use the globally unique YAML `name`, carried by the visible link label, as the stable identity when matching items to the inventory. Use the hidden file target for source validation and navigation, not as a second identity. Parse the description before the link and preserve Unicode without adding other Org markup.

Build and transform the document as an `org-element` tree, including the workspace checkbox, group headings, items, and descriptive link objects. Serialize the result with `org-element-interpret-data`; do not write a custom Org renderer or assemble headings, checkboxes, and links with regular expressions.

Add a short generated header explaining the two commands, the workspace-wide copy/link checkbox, the current library, Install All behavior, and that descriptive text and ordering may be regenerated. Do not add timestamps, so unchanged inventories produce no spurious diff.

Treat `[X]` as selected and both `[ ]` and the intermediate `[-]` state as empty/unselected. On refresh, normalize `[-]` to `[ ]`; on apply, an intermediate state must cause a currently managed skill to be removed just as an empty checkbox would. The same empty-state rule applies to `Install All`.

## 5. `skills-chooser-update`: create and refresh

Implement update as a staged pipeline: discover inventory, parse the prior document with `org-element-parse-buffer` if it exists, merge prior state into the new org-element tree, serialize that tree with `org-element-interpret-data`, then write the result. Keep all filesystem writes at the final stage and do not add custom Org parsing or printing routines.

The merge rules must be explicit:

- Match old and new entries by the globally unique YAML skill `name`, not by group, description, source path, or position.
- Preserve each existing skill checkbox when its skill still exists, treating both `[ ]` and `[-]` as an unchecked state that is rendered as `[ ]`.
- Add newly discovered skills unchecked.
- Preserve the single workspace copy/link checkbox; create it unchecked on first generation and normalize `[-]` to `[ ]` on refresh.
- Remove entries whose source skills or groups have disappeared.
- Regenerate YAML names, descriptions, hidden file-link targets, and ordering from the current library without exposing those targets in descriptive-link display.
- If a group's `Install All` is checked, keep it checked and generate all current skills in that group as checked, including newly discovered skills.
- If `Install All` is unchecked, preserve individual choices and leave new skills unchecked. Do not infer Install All merely because every child happens to be checked.

'Install All' is therefore an authoritative group-wide selection, not merely a transient convenience button. To choose a subset, the user must clear `Install All` and then select individual skills.

Write through a temporary file and rename only after successful discovery, parsing, merging, and rendering. If a visiting `skills-list.org` buffer is modified, prompt to save it before reading prior choices and abort without changing the buffer or file if the user declines. After a successful replacement, revert any visiting buffer from disk so it cannot later overwrite the new inventory with stale content. Return the list-file path and display a summary of added, removed, and retained entries.

## 6. `skills-chooser-apply`: derive desired state

Parse the documented structure entirely with `org-element`: use `org-element-parse-buffer` for the tree and `org-element-map` plus org-element accessors for headings, items, checkboxes, and link objects. Do not add regular-expression parsers for Org constructs. Report actionable errors for malformed groups, duplicate skill titles, entries without a description and descriptive skill link, or duplicate workspace method checkboxes. Read the description before the link, the stable skill name from the link label, and the hidden source target from the link path. If a buffer is visiting `skills-list.org`, parse that buffer's current contents, including unsaved modifications; otherwise parse the file on disk.

Read exactly one `Copy skills instead of linking` checkbox from the preamble. `[X]` selects copy for the entire workspace; `[ ]` and `[-]` select link. A missing checkbox in a hand-written or older file defaults to link and is inserted on the next update. Duplicate method checkboxes are invalid rather than order-dependent.

Selection and method rules:

- A checked `Install All` selects every current skill in that group. An empty or intermediate `Install All` checkbox leaves selection to the individual skills.
- Each checked skill item selects that skill by its YAML `name`; empty and intermediate skill checkboxes are both unselected.
- A skill omitted by a subsequent library refresh is no longer selected.
- Resolve selected names against a freshly validated library inventory and validate their descriptive-link targets. If a selected source is missing or stale, stop and tell the user to run `skills-chooser-update` rather than linking an unexpected path.
- Apply the single workspace method to every selected skill. There are no group or skill method exceptions.
- Build a desired destination map containing `TARGET/skill-directory` and the workspace installation method. The library's one-example-per-skill guarantee makes group namespacing and cross-group duplicate destination handling unnecessary.

The desired state is the authoritative set of managed skills plus one shared method. Previously managed entries that are now unchecked (`[ ]` or `[-]`), omitted, or in a removed group should be scheduled for removal. When the workspace method changes, every selected managed destination should be scheduled for replacement with the newly requested type.

## 7. Safe, idempotent filesystem synchronization

Keep a versioned data manifest at `.agents/skills/.skills-chooser-manifest.eld`. Store only printed Lisp data, read it back without `eval`, and include for every managed destination:

- Stable skill ID, which is the globally unique YAML `name`.
- Destination relative name.
- Absolute source path at installation time.
- Installation method used for this destination (`link` or `copy`), taken from the workspace-wide checkbox at apply time.

The tested representation starts at version 1 and uses a top-level plist with an `:entries` list. Entry methods are the symbols `link` and `copy`:

```elisp
(:version 1
 :entries ((:id "clojisr"
           :destination "clojisr"
           :source "/absolute/path/to/library/clojure/clojisr"
           :method link)))
```

The manifest distinguishes managed entries from unrelated user-installed skills. It also allows switching methods and removing skills whose source later disappeared.

Apply should perform these phases:

1. **Preflight:** Parse the Org buffer or file and old manifest, validate all selected sources and the workspace method, and compute desired installations and managed removals. Create a complete operation list before mutating anything.
2. **Conflict detection:** Refuse to overwrite or remove any destination not accounted for by the manifest, except that an existing symlink already pointing to the exact expected source may be safely adopted. Also flag a managed destination whose actual type or link target no longer agrees with its manifest record. Report all known conflicts together where practical and make no planned changes on preflight failure.
3. **Removal:** For managed deselected entries, remove symbolic links with `delete-file` and managed copied directories only after verifying the destination. Never recursively delete through a symbolic link. Leave unrelated entries in `.agents/skills` untouched.
4. **Installation:** Create the target directory and parents as needed. When the workspace checkbox is `[ ]` or `[-]`, use `make-symbolic-link` for every selected skill, creating or correcting links to absolute, expanded source directories; an already-correct link is a no-op. When it is `[X]`, copy every selected skill. Recursively compare each source and managed copied destination by relative paths, file types, and contents. Leave identical trees untouched; replace a stale manifest-owned copy with a complete new copy so changed and deleted source files are both reflected. Replace all prior managed selected installations when the workspace method changes; deselected entries follow the normal removal rule.
5. **Commit metadata:** Write the new manifest atomically after successful synchronization. On an unexpected mid-operation filesystem error, stop with the failed operation and paths in the message so the user can inspect and rerun safely.

Never follow links while removing managed entries, and reject recursive source/destination arrangements before copying. Conformance applies to skills managed by this package; unrelated user files are intentionally preserved.

`skills-chooser-apply` must use a visiting `skills-list.org` buffer's current contents whenever that buffer exists, even when it has unsaved modifications. It must not save, revert, or otherwise modify that buffer or require the user to save before applying. The on-disk Org file may consequently differ from the last applied configuration until the user saves it; the summary should mention when unsaved buffer contents were used. If no visiting buffer exists, read the file from disk. A second apply with unchanged inputs should perform no destructive work and produce the same manifest and destinations. Finish with counts of linked/copied, refreshed, removed, unchanged, and skipped-unmanaged entries.

## 8. Code organization

Keep the initial implementation small and navigable, using internal functions grouped in this order in `skills-chooser.el`:

1. Customization, constants, and small path/error helpers.
2. Front-matter extraction and YAML validation.
3. Library inventory.
4. Org tree extraction, choice merging, and org-element tree construction, followed by serialization with `org-element-interpret-data`.
5. Manifest reading/writing and operation planning.
6. Filesystem execution.
7. The two interactive commands and user-facing summaries.

Keep Org syntax handling inside Org mode. Use `org-element-parse-buffer` and `org-element-map` to read, org-element node constructors/accessors to build and transform nodes, `org-element-interpret-data` to emit the document, and existing Org commands such as `org-toggle-checkbox` for interactive checkbox changes. Use Org link helpers where appropriate rather than hand-escaping links. Do not create custom Org text serializers, heading/list/checkbox regular expressions, or parallel link-formatting logic. Skills Chooser should only translate between its inventory/configuration data and org-element trees, then delegate syntax to Org.

Prefer immutable intermediate inventories/plans and small functions over a single command that mixes scanning, transformation, serialization, and deletion. No separate manifest UI or background watcher is needed in the first version.

## 9. Tests

The initial ERT specification now exists in `test/skills-chooser-test.el` and contains 26 tests, with no production implementation yet. It establishes the command, parser, inventory, and manifest contracts documented above. Continue using ERT and temporary directory fixtures, test pure parsers/planners directly, and exercise filesystem operations only inside temporary workspaces. The test helpers inspect and transform sample documents with `org-element` and use `org-toggle-checkbox` for checkbox edits; descriptive-link display and the Org helpers have independent batch checks.

### Inventory and Org tests

- Extract valid front matter, quoted values, multiline descriptions, Unicode, and paths containing spaces.
- Reject missing delimiters, malformed YAML, and missing/wrong-type name or description without replacing an existing Org file.
- Discover only the supported layout and produce deterministic sorted output.
- Create exactly one workspace copy/link checkbox, unchecked for a new file, plus the expected groups and Install All items. Render skill description first and then a descriptive file link with the skill title as its label, with no per-skill method token. With descriptive-link display enabled, no source path or `SKILL.md` filename is visible.
- Match skills by globally unique YAML title and preserve checked and unchecked skills across refreshes; add ordinary new skills unchecked and new skills under checked Install All groups checked.
- Preserve the workspace copy/link choice across refreshes; normalize its `[-]` state to `[ ]`, just as for skill and Install All checkboxes.
- Drop removed skills/groups, retain group-level Install All state, and update changed descriptions and hidden link targets without losing selections or the workspace method.
- Reject duplicate skill titles, duplicate workspace method checkboxes, and malformed entries with actionable errors; treat an omitted workspace checkbox as link and insert it on refresh.
- Serialize exclusively through `org-element-interpret-data`. Parse the generated output again with `org-element-parse-buffer` and verify equivalent groups, checkbox states, descriptions, skill labels, and link targets.

### Apply and safety tests

- With the workspace method checkbox `[ ]` or `[-]`, all selected skills become symbolic links whose targets point to the correct source directories. A new file defaults to this state.
- With the workspace method checkbox `[X]`, all selected skills become real directories. Copies propagate changed and deleted source content on later applies and leave identical managed copies untouched.
- Unchecking a previously managed skill removes only its managed destination. Cleanup also succeeds when a source has disappeared: refresh the inventory to omit that source, then apply to remove its still-managed installation.
- Checked Install All installs the whole group using the one workspace method; clearing it returns control to individual selection checkboxes without changing the workspace method.
- Applying twice is idempotent and nondestructive when inputs are unchanged. Toggling the single workspace checkbox replaces every selected managed destination with the newly requested type and updates all affected manifest records; removals still depend only on skill selection.
- An intermediate skill checkbox removes its currently managed installation, an intermediate Install All checkbox leaves selection to child items, and an intermediate workspace method checkbox means link.
- When the disk file and a modified visiting buffer contain different skill choices or workspace methods, apply uses the unsaved buffer contents, synchronizes those selections with that one installation type, and leaves both the buffer's modified state and the disk file unchanged.
- Missing selected sources, malformed Org data, and invalid manifests abort during preflight without partial planned changes.
- Existing unmanaged files, directories, and conflicting symlinks are never overwritten or deleted. An exact pre-existing expected symlink is adopted and recorded in the manifest.
- Removing a symbolic link never affects the source skill, including when path names contain spaces.
- The manifest accurately records additions, removals, method changes, and adopted links.

Run ERT, byte compilation, `checkdoc`, and `package-lint` before considering the implementation complete. Byte compilation and lint findings should be fixed rather than silenced broadly.

## 10. Documentation and definition of done

Add a concise `README.md` with installation of `yaml`, customization examples, the expected library layout, sample Org source and descriptive-link display, both command entry points, the single workspace-wide copy/link checkbox, and safety limitations. Explain that unchecked or intermediate means link and checked means copy for all selected skills, and that Org's own parser and serializer handle the configuration syntax. Include a typical workflow:

1. Set the library and run `M-x skills-chooser-update`.
2. Edit skill checkboxes and, if desired, toggle the one `Copy skills instead of linking` workspace checkbox in `skills-list.org`; saving before apply is optional. Descriptive-link display hides source filenames and paths.
3. Run `M-x skills-chooser-apply`, which uses the visiting buffer's current contents when available and applies the workspace method to every selected skill.
4. Repeat update/apply after editing selections or changing the library.

The feature is done when both commands work in a clean temporary project, refresh preserves selections, repeated applies are idempotent, managed removals work after sources disappear, all conflict cases fail safely without touching unmanaged content, and the automated tests and Emacs package checks pass.

## 11. Remaining implementation tasks

This is the recovery checklist for the interrupted implementation. The last
completed ERT run before the header-editing loop reported **26 passed, 0 failed**.
Do not treat that checkpoint as verification of the current edits: the document
constructor and update call must be repaired and the whole suite rerun before
declaring completion.

- [ ] Repair `skills-chooser--document` around its `library-path` and `preamble`
  bindings. Keep exactly one Org `section` containing the generated comments
  and one paragraph with a descriptive link to the current library. Remove the
  leftover `inventory)))` fragment and any duplicated preamble. Check
  `check-parens`, then reload the source. The header must still leave the
  library path invisible under descriptive-link display.
- [ ] Update the `skills-chooser-update` call site to invoke
  `(skills-chooser--document library inventory previous)`, matching the
  constructor's three arguments. Keep `skills-chooser--read-disk-configuration`
  for refresh choices; apply must still prefer the current visiting buffer
  through the canonical `file-truename` comparison.
- [ ] Restore safe manifest reader bindings around parsing and validation:
  `(read-eval nil)` and `(read-circle nil)`. Reject malformed or cyclic data,
  use proper-list checks for the manifest and entries, and preserve the rule
  that printed Lisp data is never evaluated.
- [ ] Add a preflight guard in `skills-chooser--plan` for two distinct selected
  skill IDs resolving to the same destination. Report the conflict before any
  filesystem mutation, while continuing to preserve exact expected-symlink
  adoption and managed cleanup after source removal.
- [ ] Run all 26 ERT tests again, including invalid/executable manifest input,
  descriptive-link hiding, unsaved-buffer apply, and update save refusal. If
  there are failures, report their names and minimal reproductions rather than
  changing the tested contracts.
- [ ] Run byte compilation, `checkdoc`, and `package-lint` on the actual final
  source. Resolve findings rather than disabling warnings broadly. For
  package-lint, load real package archive metadata: the local archive provides
  `yaml` 1.2.1. An empty live archive cache is an environment issue, not a
  reason to hide source findings.
- [ ] Re-read the delivered source for duplicated bindings, undefined
  variables, unused arguments, and stale references after the recovery edits.
  Check editor and Emacs diagnostics, and remove generated `.elc` files if they
  are only verification artifacts.
- [ ] Keep `README.md`, which now exists, consistent with the final behavior:
  installation and customization, library layout, both commands, descriptive
  links, the single workspace-wide method, unsaved buffers, and safety limits.
  Note the current library's clickable descriptive header link, with paths
  shown by the commands and hidden by descriptive-link rendering.
- [ ] Perform one final temporary-workspace workflow: update, choose a skill,
  apply twice, toggle the method, deselect, refresh after source deletion, and
  apply again. Confirm idempotence, accurate manifest records, safe removal,
  and preservation of unrelated destination entries before marking the feature
  done.
