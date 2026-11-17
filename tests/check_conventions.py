"""Check added lines for the repository vocabulary rules."""
import re
import subprocess
import sys

base = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
if base and set(base) == {"0"}:
    base = "HEAD^"
revisions = [base, *sys.argv[2:]]
diff = subprocess.check_output([
    "git", "diff", "--unified=0", *revisions, "--", ".",
    ":(exclude)tests/check_conventions.py",
], text=True)
forbidden = re.compile(r"canonical|\bgate\b|chrome|\u2014", re.IGNORECASE)
filename = ""
failures = []
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        filename = line[6:]
    elif line.startswith("+") and not line.startswith("+++") and forbidden.search(line[1:]):
        failures.append(f"{filename}: {line[1:]}")
if failures:
    print("Repository vocabulary rules failed:\n" + "\n".join(failures), file=sys.stderr)
    sys.exit(1)
