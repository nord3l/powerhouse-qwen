#!/usr/bin/env python3
"""Pre-tool guard (bash, edit, write) for the security-remediator agent, called by .opencode/plugin/powerhouse.js.

Contract: tool-call JSON on stdin; exit 0 = allow, exit 2 = block (reason on stderr).
Anything unexpected blocks (fail closed). Like the push gate, this is a guardrail against
mistakes and prompt-injected findings, not a sandbox.

Bash is allowlisted, down to each tool's options. A command must be one line of simple
commands joined by |, &&, || or ;. Each simple command starts with a bare tool name from
TOOLS, its subcommand (if any) comes first, and every option must be on that tool's list
(exact names; abbreviations and unknown options are refused). Text tools run only on piped
input, never on files (the agent's Read/Grep/Glob calls go through aws-readonly-guard.py,
which keeps them inside the project and away from secret-bearing files). No newlines, backslashes, variables, $(...), backticks, redirects,
heredocs, subshells, background jobs, or unquoted globs, braces or ~. Every path-like
argument, and every cd, must resolve inside the project and away from secret-bearing files. Nothing that applies,
deploys, calls AWS, installs packages, writes to GitHub, commits, pushes or rewrites history
is on the list, and no allowed option writes a report file or loads code.

Edit/Write may not touch the guardrails: anything under .opencode/ (plugin, hooks, agents,
commands, bin, the module allowlist, the review marker) or .claude/, .git/, AGENTS.md, CLAUDE.md,
opencode.json, .mcp.json, the
repo's test workflow, and scanner config and ignore files (which could redirect a scanner's
output or suppress a finding). Edits must stay inside the project directory, and may not touch what the test step runs
(Makefile, tests/, pre-commit, Taskfile, justfile, conftest.py, .envrc, CONTRIBUTING), or CODEOWNERS.
Workflows, composite actions and scripts stay editable, because they are what most findings
are about; /remediate stage 2 shows their diffs and stops for approval before tests run. Paths are resolved (.. and symlinks)
before both checks. Matching ignores case, for case-insensitive filesystems.
"""
import json
import os
import re
import shlex
import sys

PROTECTED = re.compile(
    r"(^|/)(\.opencode(/|$)|\.claude(/|$)|\.git(/|$)|(AGENTS|CLAUDE)(\.local)?\.md$|opencode\.jsonc?$|\.mcp\.json$|\.github/workflows/test\.ya?ml$"
    r"|\.checkov\.ya?ml$|\.?trivy\.ya?ml$|\.trivyignore(\.yaml)?$|\.tflint\.hcl$|\.?gitleaks\.toml$|\.gitleaksignore$"
    r"|\.?zizmor\.ya?ml$|\.shellcheckrc$|\.terraformrc$|terraform\.rc$|\.terraform(/|$)|\.terraform\.lock\.hcl$"
    r"|\.tfsec(/|$)|\.checkov(/|\.baseline$)|\.github/actionlint\.ya?ml$|\.?gitconfig$|\.gitattributes$"
    # Files the test step runs: changing them needs a human (see /remediate stage 2).
    r"|Makefile$|GNUmakefile$|tests?/|\.pre-commit-config\.ya?ml$|\.envrc$|conftest\.py$|Taskfile\.ya?ml$|justfile$"
    # Build manifests the test step reads or runs, and kustomizations (which can pull remote bases).
    r"|package\.json$|pyproject\.toml$|setup\.cfg$|go\.mod$|\.tool-versions$|\.terraform-version$|kustomization\.ya?ml$"
    r"|[^/]*_test\.go$|[^/]*\.tftest\.hcl$|pytest\.ini$|tox\.ini$|noxfile\.py$"
    # Who must review a change, and where test-runner reads its test commands from.
    r"|CODEOWNERS$|CONTRIBUTING(\.[a-z]+)?$)",
    re.IGNORECASE)
# Files a path argument may never name, even inside the project (secrets the tools could echo).
SECRET = re.compile(r"(^|[/:])(\.env[^/]*$|[^/]*\.tfstate[^/]*$|[^/]*\.tfvars(\.json)?$|[^/]*\.(pem|key|p12|pfx)$"
                    r"|[^/]*credentials[^/]*$|id_(rsa|ecdsa|ed25519)[^/]*$|\.git(/|$)|\.terraform(/|$))", re.IGNORECASE)
# Tools whose arguments are names or text, not local paths.
NON_PATH_TOOLS = {"gh", "docker", "crane"}
OPERATORS = {"|", "||", "&&", ";"}
GITHUB_API_READ = re.compile(r"^/?repos/[\w.-]+/[\w.-]+/(commits|git/refs?|git/tags|releases|tags)(/[\w.-]+)*$")
# Image references may name only these registries, or none (Docker Hub).
REGISTRIES = re.compile(r"^(docker\.io|ghcr\.io|quay\.io|registry\.k8s\.io|public\.ecr\.aws|gcr\.io"
                        r"|[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com)$")


def block(msg):
    print(f"security-remediator guard: {msg}", file=sys.stderr)
    sys.exit(2)


def parse(args, flags=(), valued=()):
    """Positional arguments if every option is in `flags` (no value) or `valued` (takes a value,
    as `--x=v` or `--x v` / `-x v`); None if any option is unknown."""
    pos, i = [], 0
    while i < len(args):
        a = args[i]
        if a.startswith("-") and a != "-":
            name, eq, _ = a.partition("=")
            if name in flags and not eq:
                i += 1
            elif name in valued:
                if not eq and (i + 1 >= len(args) or args[i + 1].startswith("-")):
                    return None  # a value never looks like an option, so no option can hide behind one
                i += 1 if eq else 2
            else:
                return None
        else:
            pos.append(a)
            i += 1
    return pos


def sub_parse(args, subs, flags=(), valued=()):
    if not args or args[0] not in subs:
        return None
    return parse(args[1:], flags, valued)


def ok(result, max_pos=None, min_pos=0):
    return result is not None and len(result) >= min_pos and (max_pos is None or len(result) <= max_pos)


def values(args, names):
    out = []
    for i, a in enumerate(args):
        name, eq, v = a.partition("=")
        if name in names:
            out.append(v if eq else (args[i + 1] if i + 1 < len(args) else ""))
    return out


# --- tools that may start a command --------------------------------------------------------

def terraform(args):
    if args and args[0].startswith("-chdir="):
        args = args[1:]
    if not args:
        return False
    if args[0] == "fmt":  # check only: the Edit tool, which is guarded, makes the changes
        return "-check" in args and ok(parse(args[1:], {"-check", "-diff", "-recursive", "-no-color"}))
    if args[0] == "validate":
        return ok(parse(args[1:], {"-json", "-no-color"}), max_pos=0)
    return args == ["version"]


def git(args):
    while args and args[0] in ("-C", "--no-pager"):
        args = args[2:] if args[0] == "-C" else args[1:]
    if not args:
        return False
    sub, rest = args[0], args[1:]
    if sub in ("diff", "log", "show"):
        return ok(parse(rest, {"--stat", "--name-only", "--name-status", "--oneline", "--cached", "--staged",
                               "--no-color", "--no-ext-diff", "--merge-base"},
                        {"-n", "--max-count"}))
    if sub == "status":
        return ok(parse(rest, {"--short", "-s", "--porcelain", "-b"}))
    if sub == "rev-parse":
        return ok(parse(rest, {"--verify", "-q", "--quiet", "--short", "--show-toplevel", "--abbrev-ref"}))
    if sub == "ls-files":
        return ok(parse(rest))
    if sub == "ls-remote":
        pos = parse(rest, {"--tags", "--heads", "--refs", "-t", "-h"})
        return ok(pos, min_pos=1) and pos[0].startswith("https://github.com/")
    return False


def gh(args):
    if not args or args[0] != "api":
        return False
    pos = parse(args[1:], {"--paginate"}, {"--jq", "-q"})
    # Plain path filters only: jq builtins such as env could print the environment.
    if not all(re.match(r"^\.[\w.\[\]]*$", v) for v in values(args, ("--jq", "-q"))):
        return False
    return ok(pos, max_pos=1, min_pos=1) and bool(GITHUB_API_READ.match(pos[0])) and ".." not in pos[0].split("/")


def image(args, sub):
    pos = sub_parse(args, {sub})
    if not ok(pos, max_pos=1, min_pos=1) or "://" in pos[0]:
        return False
    host, slash, _ = pos[0].partition("/")
    return not (slash and ("." in host or ":" in host or host == "localhost")) or bool(REGISTRIES.match(host))


def local_only(args):
    """No remote sources: URLs and git remotes could fetch code or carry data out."""
    return not any("://" in a or a.startswith("git@") or "github.com" in a for a in args)


def checkov(args):
    return ok(parse(args, {"--compact", "--quiet", "--no-guide"},
                    {"-d", "--directory", "-f", "--file", "--framework", "--check", "-o", "--output"})) \
        and all(v in ("cli", "json") for v in values(args, ("-o", "--output")))


TOOLS = {
    "terraform": terraform, "tofu": terraform, "checkov": checkov, "git": git, "gh": gh,
    "tflint": lambda a: ok(parse(a, {"--recursive", "--no-color"},
                                 {"--chdir", "--format", "-f", "--minimum-failure-severity"})),
    "tfsec": lambda a: ok(parse(a, {"--no-color", "--concise-output"}, {"--minimum-severity"})),
    "trivy": lambda a: ok(sub_parse(a, {"config", "fs"}, {"-q", "--quiet", "--skip-db-update"},
                                    {"--severity", "-s", "--scanners"})),
    "gitleaks": lambda a: ok(sub_parse(a, {"detect", "dir"}, {"--no-git", "--redact", "--no-banner"},
                                       {"-s", "--source"})) and "--redact" in a,
    "zizmor": lambda a: "--offline" in a and local_only(a)
    and ok(parse(a, {"--offline", "-q", "--quiet", "--pedantic"}, {"--min-severity", "--format"})),
    "actionlint": lambda a: ok(parse(a, {"-oneline", "-no-color", "-color", "-verbose"})),
    "shellcheck": lambda a: ok(parse(a, {"-x", "--external-sources"},
                                     {"-S", "--severity", "-s", "--shell", "-f", "--format", "-e", "--exclude"})),
    "kubeconform": lambda a: ok(parse(a, {"-strict", "-summary", "-ignore-missing-schemas"}, {"-kubernetes-version"})),
    "helm": lambda a: ok(sub_parse(a, {"lint", "template"}, {"--strict", "--include-crds", "--quiet"},
                                   {"-f", "--values", "--set", "--set-string", "-n", "--namespace", "--kube-version"}))
    and local_only(a),
    "kubectl": lambda a: ok(sub_parse(a, {"kustomize"}), max_pos=1) and local_only(a),
    "kustomize": lambda a: ok(sub_parse(a, {"build"}), max_pos=1) and local_only(a),
    "docker": lambda a: a[:2] == ["buildx", "imagetools"] and image(a[2:], "inspect"),
    "crane": lambda a: image(a, "digest"),
    "pwd": lambda a: not a, "true": lambda a: not a,
    # One directory, never an option: cd -, -P and -L jump to OLDPWD or HOME without a path to check.
    "cd": lambda a: len(a) == 1 and not a[0].startswith("-"),
}

# Text tools: piped input only, never file arguments (files are read with the Read and Grep tools).
PIPE_TOOLS = {
    "grep": lambda a: ok(parse(a, {"-c", "-i", "-n", "-v", "-w", "-x", "-F", "-E", "-o", "-q", "-h"},
                               {"-A", "-B", "-C", "-m"}), max_pos=1, min_pos=1),
    "head": lambda a: ok(parse(a, valued={"-n"}), max_pos=0),
    "tail": lambda a: ok(parse(a, valued={"-n"}), max_pos=0),
    "wc": lambda a: ok(parse(a, {"-l", "-c", "-w"}), max_pos=0),
    "cut": lambda a: ok(parse(a, valued={"-d", "-f", "-c"}), max_pos=0),
    "tr": lambda a: ok(parse(a, {"-d", "-s"}), max_pos=2),
}


def project_root(cwd):
    root = os.environ.get("POWERHOUSE_PROJECT_DIR") or cwd or os.getcwd()
    if not os.path.isabs(root):
        block("cannot resolve the project directory.")
    root = os.path.realpath(root)
    if root in ("/", os.path.realpath(os.path.expanduser("~"))):
        block("the project directory may not be / or your home folder.")
    return root


def path_values(args):
    """Arguments and option values that could name a local path."""
    for a in args:
        if a.startswith("-"):
            if "=" in a:
                yield a.split("=", 1)[1]
        else:
            yield a


def confine(value, here, root):
    full = os.path.realpath(os.path.join(here, value))
    if os.path.commonpath([full, root]) != root:
        block(f"'{value}' is outside the project ({root}).")
    if SECRET.search(full):
        block(f"'{value}' names a file that can hold secrets (.env, state, tfvars, keys, credentials, .git).")


def check_bash(cmd, cwd):
    root = project_root(cwd)
    here = os.path.realpath(cwd) if cwd and os.path.isabs(cwd) else root
    if os.path.commonpath([here, root]) != root:
        block("the shell is outside the project.")
    if not cmd.strip():
        block("empty command.")
    if re.search(r"[\n\r$`\\\x00-\x08\x0b-\x1f\x7f]", cmd):
        block("one line only, with no backslashes, control characters, variables, $(...) or backticks.")
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""  # the shell only starts a comment at a word boundary; # is refused below
        tokens = list(lex)
        raw = shlex.shlex(cmd, posix=False, punctuation_chars=True)
        raw.whitespace_split = True
        raw.commenters = ""
        raw_tokens = list(raw)
    except ValueError as e:
        block(f"could not parse the command ({e}).")
    for t in raw_tokens:
        if re.search(r"[{}*?\[\]~!#]", re.sub(r"'[^']*'|\"[^\"]*\"", "", t)):
            block(f"'{t}': quote globs, braces, ~, ! and # (the shell would expand or reinterpret them).")
    segments, cur, op = [], [], None
    for t in tokens:
        if t in OPERATORS:
            segments.append((op, cur))
            cur, op = [], t
        elif t and all(c in "();<>|&" for c in t):
            block(f"'{t}' is not allowed (no redirects, subshells or background jobs).")
        else:
            cur.append(t)
    segments.append((op, cur))
    raw_words = set(raw_tokens)
    for op, seg in segments:
        if not seg:
            block("empty command segment.")
        name, args = seg[0], seg[1:]
        if name not in raw_words:
            block(f"'{name}' must be written as a bare command name.")
        if name in PIPE_TOOLS:
            if op != "|":
                block(f"'{name}' may only read piped input. Use the Read and Grep tools for files.")
            check = PIPE_TOOLS[name]
        elif name in TOOLS:
            check = TOOLS[name]
        else:
            block(f"'{name}' is not on the remediator's allowlist. Local checks and read-only lookups only.")
        if not check(args):
            block(f"'{' '.join(seg)}' is not allowed: only the listed subcommands and options are. "
                  "If you need something else, report it under Manual follow-up.")
        if name not in NON_PATH_TOOLS:
            for v in path_values(args):
                if SECRET.search(v):  # also catches rev:path forms such as HEAD:.env
                    block(f"'{v}' names a file that can hold secrets (.env, state, tfvars, keys, credentials, .git).")
                if v.startswith(("/", ".")) or "/" in v or os.path.lexists(os.path.join(here, v)):
                    confine(v, here, root)
        if name == "cd":
            here = os.path.realpath(os.path.join(here, args[0]))


def check_path(path, cwd):
    root = project_root(cwd)
    full = os.path.realpath(os.path.join(cwd or root, os.path.expanduser(path)))
    if os.path.commonpath([full, root]) != root:
        block(f"{path} is outside the project ({root}). The remediator only edits files in the repository.")
    for p in (path, full):
        if PROTECTED.search(p.replace(os.sep, "/")):
            block(f"{path} is a guardrail (.opencode/, .git/, AGENTS.md, opencode.json, .mcp.json, the test workflow, a build "
                  "manifest, a test-step file, CODEOWNERS, or a scanner config or ignore file). Report the change under Manual follow-up instead.")
    if SECRET.search(full.replace(os.sep, "/")):
        block(f"{path} can hold secrets (.env, state, tfvars, keys, credentials). Describe the change under "
              "Manual follow-up instead.")


def main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input")
        if not isinstance(tool_input, dict):
            raise ValueError
    except Exception:
        block("could not read the tool call; blocking.")
    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else ""
    if "file_path" in tool_input and "command" in tool_input:
        block("a tool call with both a command and a file_path; blocking.")
    if "file_path" in tool_input:
        path = tool_input["file_path"]
        if not isinstance(path, str) or not path:
            block("bad file_path.")
        check_path(path, cwd)
    elif "command" in tool_input:
        if not isinstance(tool_input["command"], str):
            block("bad command.")
        check_bash(tool_input["command"], cwd)
    else:
        block("unrecognised tool call.")
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # exit 1 would let the call through, so anything unexpected blocks
        block(f"could not check this call ({type(e).__name__}); blocking.")
