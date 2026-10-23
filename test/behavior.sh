#!/usr/bin/env bash
# Build a throwaway project under test/work and exercise recurse.
# The fixture is gitignored. Re-running wipes it.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
zig build

rc="$root/zig-out/bin/recurse"
# Commands run in the fixture project unless a test cds elsewhere.
runrc() { (cd "$proj" && "$rc" "$@"); }
work="$root/test/work"
rm -rf "$work"
mkdir -p "$work/home" "$work/remotes"
export HOME="$work/home"
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
git config --global protocol.file.allow always
git config --global init.defaultBranch main

fail_with() {
  local pat="$1"
  shift
  local out code
  set +e
  out=$("$@" 2>&1)
  code=$?
  set -e
  if [[ $code -eq 0 ]]; then
    echo "expected failure: $*" >&2
    echo "$out" >&2
    exit 1
  fi
  if ! grep -q "$pat" <<<"$out"; then
    echo "expected /$pat/ from: $*" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "ok  fail  $pat"
}

# Lines must appear in order. A trailing newline keeps "committed mid"
# from matching inside "committed mid/leaf".
order_has() {
  python3 - "$1" "$2" <<'PY'
import sys
text, seq = sys.argv[1] + "\n", sys.argv[2].split("|")
pos = 0
for line in seq:
    i = text.find(line, pos)
    if i < 0:
        print("order missing:", line)
        print(text)
        sys.exit(1)
    pos = i + len(line)
print("ok  order " + " < ".join(s.strip() for s in seq))
PY
}

ident() {
  git -C "$1" config user.name T
  git -C "$1" config user.email t@example.com
}

echo "== fixture =="
git init -q -b main "$work/leaf-src"
ident "$work/leaf-src"
echo leaf > "$work/leaf-src/README"
git -C "$work/leaf-src" add README
git -C "$work/leaf-src" commit -qm init
git init -q --bare "$work/remotes/leaf.git"
git -C "$work/leaf-src" remote add origin "$work/remotes/leaf.git"
git -C "$work/leaf-src" push -q -u origin main

git init -q -b main "$work/other-src"
ident "$work/other-src"
echo other > "$work/other-src/README"
git -C "$work/other-src" add README
git -C "$work/other-src" commit -qm init
git init -q --bare "$work/remotes/other.git"
git -C "$work/other-src" remote add origin "$work/remotes/other.git"
git -C "$work/other-src" push -q -u origin main

git init -q -b main "$work/mid-src"
ident "$work/mid-src"
echo leaf > "$work/mid-src/README"
git -C "$work/mid-src" submodule add -q -b main "$work/remotes/leaf.git" leaf
git -C "$work/mid-src" add README
git -C "$work/mid-src" commit -qm "add leaf"
git init -q --bare "$work/remotes/mid.git"
git -C "$work/mid-src" remote add origin "$work/remotes/mid.git"
git -C "$work/mid-src" push -q -u origin main

git init -q -b main "$work/project-src"
ident "$work/project-src"
echo project > "$work/project-src/README"
git -C "$work/project-src" submodule add -q -b main "$work/remotes/mid.git" mid
git -C "$work/project-src" submodule add -q -b main "$work/remotes/other.git" other
git -C "$work/project-src" add README
git -C "$work/project-src" commit -qm "add nested repos"
git init -q --bare "$work/remotes/project.git"
git -C "$work/project-src" remote add origin "$work/remotes/project.git"
git -C "$work/project-src" push -q -u origin main

git clone -q --recurse-submodules "$work/remotes/project.git" "$work/project"
proj="$work/project"
for r in "$proj" "$proj/mid" "$proj/mid/leaf" "$proj/other"; do
  ident "$r"
done

echo "== status lists the nested repo =="
st=$(runrc status)
echo "$st"
grep -q "mid/leaf" <<<"$st"

echo "== unborn project prints =="
git init -q -b main "$work/empty"
st=$(cd "$work/empty" && "$rc" status)
echo "$st"
grep -q "unborn" <<<"$st"

echo "== unknown path =="
fail_with "no/such: unknown submodule" runrc update no/such

echo "== retired commands =="
fail_with "Usage:" runrc sync
fail_with "Usage:" runrc checkout
fail_with "Usage:" runrc pull mid/leaf

echo "== untracked is visible and does not block sync or pull =="
touch "$proj/mid/leaf/stray.txt"
st=$(runrc status)
grep -q "untracked" <<<"$st"
runrc update >/dev/null
runrc pull >/dev/null
rm "$proj/mid/leaf/stray.txt"
echo "ok  untracked"

echo "== tracked changes block sync and pull =="
echo dirty >> "$proj/mid/leaf/README"
fail_with "mid/leaf: tracked changes" runrc update
git -C "$proj/mid/leaf" checkout -q -- README
echo dirty >> "$proj/README"
fail_with ".: tracked changes" runrc pull
git -C "$proj" checkout -q -- README

echo "== no TTY and no -m =="
echo dirty >> "$proj/README"
fail_with ".: no TTY and no -m" runrc commit
git -C "$proj" checkout -q -- README

echo "== detached nested repo reattaches, worktree matches the pin =="
git -C "$proj/mid/leaf" checkout -q --detach HEAD
runrc update >/dev/null
ref=$(git -C "$proj/mid/leaf" symbolic-ref HEAD)
[[ "$ref" == "refs/heads/main" ]]
[[ -z $(git -C "$proj/mid/leaf" status --porcelain) ]]
echo "ok  reattached $ref"

echo "== branch ahead of the gitlink refuses, and stays on the branch =="
echo ahead >> "$proj/mid/leaf/README"
git -C "$proj/mid/leaf" add README
git -C "$proj/mid/leaf" commit -qm ahead
fail_with "mid/leaf: local branch is ahead" runrc update
ref=$(git -C "$proj/mid/leaf" symbolic-ref HEAD)
[[ "$ref" == "refs/heads/main" ]]
git -C "$proj/mid/leaf" reset -q --hard HEAD~1
echo "ok  ahead refused"

echo "== commit walks deepest first =="
echo nested >> "$proj/mid/leaf/README"
out=$(runrc commit -m "nested order" 2>&1)
echo "$out"
order_has "$out" $'committed mid/leaf\n|committed mid\n|committed .\n'

echo "== PATH limits the subtree =="
echo leaf2 >> "$proj/mid/leaf/README"
echo other2 >> "$proj/other/README"
echo project2 >> "$proj/README"
out=$(runrc commit mid/leaf -m "only leaf" 2>&1)
echo "$out"
order_has "$out" $'committed mid/leaf\n|committed mid\n|committed .\n'
if grep -q "committed other" <<<"$out"; then
  echo "other was committed under a mid/leaf path" >&2
  exit 1
fi
git -C "$proj/other" diff --quiet -- README && {
  echo "other/README was swept into the path-limited commit" >&2
  exit 1
}
git -C "$proj" diff --quiet -- README && {
  echo "project README was swept into the path-limited commit" >&2
  exit 1
}
echo "ok  path filter"

echo "== missing identity names the fix and what already committed =="
git -C "$proj/mid" config --unset user.email
git -C "$proj/mid" config --unset user.name || true
echo leaf3 >> "$proj/mid/leaf/README"
echo mid3 >> "$proj/mid/README"
set +e
out=$(runrc commit -m "partial" 2>&1)
code=$?
set -e
echo "$out"
[[ $code -ne 0 ]]
grep -q "mid: set user.name and user.email" <<<"$out"
grep -q "already committed:" <<<"$out"
grep -q "mid/leaf" <<<"$out"
grep -q "superproject was not updated" <<<"$out"
echo "ok  partial commit"

echo "== push walks deepest first =="
ident "$proj/mid"
out=$(runrc commit -m "rest" 2>&1)
echo "$out"
out=$(runrc push 2>&1)
echo "$out"
order_has "$out" $'pushed mid/leaf\n|pushed mid\n|pushed other\n|pushed .\n'

echo "== detached nested repo blocks push =="
git -C "$proj/mid/leaf" checkout -q --detach HEAD
fail_with "mid/leaf: detached HEAD" runrc push
git -C "$proj/mid/leaf" checkout -q main

echo "== verify is not a command =="
fail_with "Usage:" runrc verify

echo "== status shows the recorded pin when HEAD moved =="
recorded=$(git -C "$proj/mid" rev-parse --short=7 HEAD:leaf)
echo pinchange >> "$proj/mid/leaf/README"
git -C "$proj/mid/leaf" add README
git -C "$proj/mid/leaf" commit -qm pinchange
checkout=$(git -C "$proj/mid/leaf" rev-parse --short=7 HEAD)
st=$(runrc status)
line=$(grep "mid/leaf" <<<"$st" | head -1)
echo "$line"
grep -q "$checkout" <<<"$line"
grep -q "pin $recorded" <<<"$line"
other_line=$(grep -E '^  other([^[:alnum:]_]|$)' <<<"$st" | head -1)
if grep -q " pin " <<<"$other_line"; then
  echo "matching HEAD printed a pin: $other_line" >&2
  exit 1
fi
echo "ok  pin"

echo "== behind upstream is not a pin =="
other_at=$(git -C "$proj/other" rev-parse HEAD)
git clone -q "$work/remotes/other.git" "$work/other-up"
ident "$work/other-up"
echo upstream >> "$work/other-up/README"
git -C "$work/other-up" add README
git -C "$work/other-up" commit -qm upstream
git -C "$work/other-up" push -q origin main
git -C "$proj/other" fetch -q
st=$(runrc status)
oline=$(grep -E '^  other([^[:alnum:]_]|$)' <<<"$st" | head -1)
echo "$oline"
grep -q "behind" <<<"$oline"
if grep -q " pin " <<<"$oline"; then
  echo "behind printed a pin: $oline" >&2
  exit 1
fi
git -C "$proj/other" reset -q --hard "$other_at"
echo "ok  behind"

echo "== unpublished nested commit does not push the project =="
runrc commit -m "record pin" >/dev/null
proj_tip=$(git --git-dir "$work/remotes/project.git" rev-parse refs/heads/main)
git -C "$proj/mid/leaf" branch --unset-upstream
set +e
out=$(runrc push 2>&1)
code=$?
set -e
echo "$out"
[[ $code -ne 0 ]]
grep -q "mid/leaf: no upstream" <<<"$out"
if grep -q "pushed \." <<<"$out"; then
  echo "project was pushed" >&2
  exit 1
fi
[[ "$(git --git-dir "$work/remotes/project.git" rev-parse refs/heads/main)" == "$proj_tip" ]]
git -C "$proj/mid/leaf" branch -u origin/main
runrc push >/dev/null
echo "ok  unpublished"

echo "== a gitlink already on a remote may push the project =="
echo onlyproject >> "$proj/README"
out=$(runrc commit -m "project only" 2>&1)
echo "$out"
out=$(runrc push 2>&1)
echo "$out"
grep -q "pushed \." <<<"$out"
echo "ok  reachable"

echo "== push follows the upstream branch name =="
git init -q -b main "$work/trunk-src"
ident "$work/trunk-src"
echo t > "$work/trunk-src/f"
git -C "$work/trunk-src" add f
git -C "$work/trunk-src" commit -qm init
git init -q --bare "$work/remotes/trunk.git"
git -C "$work/trunk-src" remote add upstream "$work/remotes/trunk.git"
git -C "$work/trunk-src" push -q -u upstream main:trunk
echo more >> "$work/trunk-src/f"
git -C "$work/trunk-src" add f
git -C "$work/trunk-src" commit -qm more
(cd "$work/trunk-src" && "$rc" push)
[[ "$(git -C "$work/trunk-src" rev-parse HEAD)" == "$(git --git-dir "$work/remotes/trunk.git" rev-parse refs/heads/trunk)" ]]
if git --git-dir "$work/remotes/trunk.git" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
  echo "remote grew refs/heads/main" >&2
  exit 1
fi
echo "ok  trunk"

echo "== diverged nested branch is not moved =="
leaf_sha=$(git -C "$proj/mid/leaf" rev-parse HEAD)
other_sha=$(git -C "$proj/other" rev-parse HEAD)
git -C "$proj/mid/leaf" checkout -q --detach HEAD~1
echo diverge >> "$proj/mid/leaf/README"
git -C "$proj/mid/leaf" add README
git -C "$proj/mid/leaf" commit -qm diverge
git -C "$proj/mid/leaf" branch -f main HEAD
git -C "$proj/mid/leaf" checkout -q main
diverged=$(git -C "$proj/mid/leaf" rev-parse HEAD)
fail_with "mid/leaf: not a fast-forward" runrc update
[[ "$(git -C "$proj/mid/leaf" rev-parse HEAD)" == "$diverged" ]]
[[ "$(git -C "$proj/mid/leaf" symbolic-ref HEAD)" == "refs/heads/main" ]]
[[ "$(git -C "$proj/other" rev-parse HEAD)" == "$other_sha" ]]
git -C "$proj/mid/leaf" checkout -q -B main "$leaf_sha"
git -C "$proj/mid/leaf" branch -u origin/main
echo "ok  diverged"

echo "== update refuses to detach and does not move HEAD =="
other_sha=$(git -C "$proj/other" rev-parse HEAD)
git -C "$proj" config -f .gitmodules --unset submodule.other.branch
git -C "$proj" config --unset submodule.other.branch || true
git -C "$proj/other" checkout -q --detach HEAD
git -C "$proj/other" branch -D main
fail_with "other: would detach HEAD" runrc update other
[[ "$(git -C "$proj/other" rev-parse HEAD)" == "$other_sha" ]]
git -C "$proj/other" checkout -q -B main "$other_sha"
git -C "$proj/other" branch -u origin/main
git -C "$proj" config -f .gitmodules submodule.other.branch main
git -C "$proj" config submodule.other.branch main
echo "ok  would detach"

echo "== pull does not move the project when a nested branch is ahead of the incoming pin =="
echo aheadpin >> "$proj/mid/leaf/README"
git -C "$proj/mid/leaf" add README
git -C "$proj/mid/leaf" commit -qm aheadpin
proj_sha=$(git -C "$proj" rev-parse HEAD)
git clone -q "$work/remotes/project.git" "$work/proj-up"
ident "$work/proj-up"
echo side >> "$work/proj-up/README"
git -C "$work/proj-up" add README
git -C "$work/proj-up" commit -qm side
git -C "$work/proj-up" push -q origin main
fail_with "mid/leaf: local branch is ahead" runrc pull
[[ "$(git -C "$proj" rev-parse HEAD)" == "$proj_sha" ]]
git -C "$proj/mid/leaf" reset -q --hard HEAD~1
git --git-dir "$work/remotes/project.git" update-ref refs/heads/main "$proj_sha"
echo "ok  pull ahead"

echo "== pull does not take a path =="
mid_sha=$(git -C "$proj/mid" rev-parse HEAD)
fail_with "Usage:" runrc pull mid
[[ "$(git -C "$proj/mid" rev-parse HEAD)" == "$mid_sha" ]]
echo "ok  pull path"

echo "== pull.ff other than only is rejected =="
printf 'ff = false\n' > "$work/ff.toml"
proj_sha=$(git -C "$proj" rev-parse HEAD)
fail_with "pull.ff must be only" runrc --config "$work/ff.toml" pull
[[ "$(git -C "$proj" rev-parse HEAD)" == "$proj_sha" ]]
echo "ok  ff only"

echo "== path commit refuses a staged project file =="
echo staged >> "$proj/README"
git -C "$proj" add README
proj_sha=$(git -C "$proj" rev-parse HEAD)
fail_with ".: staged changes outside this path" runrc commit mid/leaf -m "nope"
[[ "$(git -C "$proj" rev-parse HEAD)" == "$proj_sha" ]]
git -C "$proj" diff --cached --quiet && {
  echo "staged project file was not left staged" >&2
  exit 1
}
git -C "$proj" reset -q -- README
git -C "$proj" checkout -q -- README
echo "ok  staged project"

echo "== path commit refuses a staged file in the containing repo =="
echo staged >> "$proj/mid/README"
git -C "$proj/mid" add README
mid_sha=$(git -C "$proj/mid" rev-parse HEAD)
fail_with "mid: staged changes outside this path" runrc commit mid/leaf -m "nope"
[[ "$(git -C "$proj/mid" rev-parse HEAD)" == "$mid_sha" ]]
git -C "$proj/mid" diff --cached --quiet && {
  echo "staged mid file was not left staged" >&2
  exit 1
}
git -C "$proj/mid" reset -q -- README
git -C "$proj/mid" checkout -q -- README
echo "ok  staged mid"

echo "== missing identity does not stage the edit =="
git -C "$proj/mid/leaf" config --unset user.email
git -C "$proj/mid/leaf" config --unset user.name || true
echo nostage >> "$proj/mid/leaf/README"
fail_with "mid/leaf: set user.name and user.email" runrc commit -m "nope"
git -C "$proj/mid/leaf" diff --cached --quiet
git -C "$proj/mid/leaf" diff -- README | grep -q nostage
git -C "$proj/mid/leaf" checkout -q -- README
ident "$proj/mid/leaf"
echo "ok  identity"

echo "== git pull in a submodule, rc commit records the gitlink =="
git clone -q "$work/remotes/leaf.git" "$work/leaf-upstream"
ident "$work/leaf-upstream"
echo absorbed >> "$work/leaf-upstream/README"
git -C "$work/leaf-upstream" add README
git -C "$work/leaf-upstream" commit -qm absorbed
git -C "$work/leaf-upstream" push -q origin main
git -C "$proj/mid/leaf" pull -q
leaf_sha=$(git -C "$proj/mid/leaf" rev-parse HEAD)
out=$(runrc commit -m "record leaf" 2>&1)
echo "$out"
[[ "$(git -C "$proj/mid" rev-parse HEAD:leaf)" == "$leaf_sha" ]]
mid_sha=$(git -C "$proj/mid" rev-parse HEAD)
[[ "$(git -C "$proj" rev-parse HEAD:mid)" == "$mid_sha" ]]
echo "ok  record pin"

echo "== upstream remote is not hardcoded to origin =="
git init -q -b main "$work/tracked"
ident "$work/tracked"
echo x > "$work/tracked/f"
git -C "$work/tracked" add f
git -C "$work/tracked" commit -qm init
git init -q --bare "$work/remotes/tracked.git"
git -C "$work/tracked" remote add upstream "$work/remotes/tracked.git"
git -C "$work/tracked" push -q -u upstream main
out=$(cd "$work/tracked" && "$rc" pull 2>&1)
echo "$out"
grep -q "pulled ." <<<"$out"
echo "ok  upstream remote"

echo "== no upstream names the repo =="
git init -q -b main "$work/noup"
ident "$work/noup"
echo x > "$work/noup/f"
git -C "$work/noup" add f
git -C "$work/noup" commit -qm init
cd "$work/noup"
fail_with ".: no upstream" "$rc" pull
cd "$proj"

echo "== recurse.toml is found from a subdirectory =="
printf 'recursive = false\n' > "$proj/recurse.toml"
mkdir -p "$proj/notes"
st=$(cd "$proj/notes" && "$rc" status)
echo "$st"
if grep -q "mid/leaf" <<<"$st"; then
  echo "recursive=false still listed mid/leaf" >&2
  exit 1
fi
grep -q "mid" <<<"$st"
echo "ok  config"

echo
echo "behavior: passed ($work)"
