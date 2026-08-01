#!/bin/zsh
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" || exit 1
mkdir -p logs

TOOLS="Read,Edit,Write,Bash(git status *),Bash(git diff *),Bash(git add *),Bash(git commit *),Bash(swift build *),Bash(swift test *),Bash(xcodebuild *)"

echo "=== resuming spec-04 at $(date) ==="
claude -p --model opus --resume 65db8b2d-cce3-4907-b2c3-e43ec77f4ede \
  --allowedTools "$TOOLS" \
  --output-format json \
  "You were interrupted by an API session limit, not an error. There is uncommitted work in the tree. Pick up exactly where you left off: finish implementing the spec-04 plan, confirm it builds and passes existing tests including what prior specs built, then extract the DECISIONS.md update based on what was actually built (flat facts, only what is binding on future specs, merge without duplicating) and commit." \
  > "logs/build-04-resume.json" 2>&1

if [ $? -ne 0 ]; then
  echo "spec-04 resume failed, stopping" >&2
  exit 1
fi
echo "=== finished spec-04 at $(date) ==="

for n in 05 06 07; do
  echo "=== starting spec-$n at $(date) ==="
  claude -p --model opus \
    --allowedTools "$TOOLS" \
    --output-format json \
    "Look in '/Users/carlostarrats/Documents/Projects/Muse/Muse App/docs/new-build' and read muse-photo-foundation.md and DECISIONS.md. Then find the file in '/Users/carlostarrats/Documents/Projects/Muse/Muse App/docs/superpowers/plans' whose name starts with '2026-07-30-spec-$n' and read it. Implement that plan — write the actual code, create/modify the files it specifies, and confirm it builds and passes existing tests, including what prior specs already built. The foundation doc and DECISIONS.md are both authoritative — where either answers something, don't ask me; DECISIONS.md wins on conflict. Read actual source files from prior specs when you need detail beyond what DECISIONS.md captures. If you hit something the plan didn't anticipate, make the reasonable call and keep going. When done, extract a DECISIONS.md update based on what was actually built, including anything that diverged. Flat facts, only what's binding on future specs. Merge into DECISIONS.md — don't duplicate, only add what's new or changed. Then commit." \
    > "logs/build-$n.json" 2>&1

  if [ $? -ne 0 ]; then
    echo "spec-$n build failed, stopping" >&2
    exit 1
  fi
  echo "=== finished spec-$n at $(date) ==="
done
echo "=== all specs complete ==="
