#!/usr/bin/env python3
"""Pre-tool guard (bash, read, grep, glob, list) for the AWS-facing agents (iam-tightener, cost-analyst, aws-researcher),
called by .opencode/plugin/powerhouse.js.

Contract: tool-call JSON on stdin; exit 0 = allow, exit 2 = block (reason on stderr).
Anything unexpected blocks (fail closed). This is a guardrail; the real control is running
those agents with a read-only AWS profile (see README).

Everything is allowlisted. A command must be one line of simple commands joined by
|, &&, || or ;, where each simple command is:
  * `aws <service> <operation>` with the operation in AWS_OPERATIONS below (the exact read
    calls these agents need), and none of the options that redirect or read local files; or
  * one of TEXT_TOOLS on piped input only (no file arguments; files are read with the
    Read/Grep/Glob tools, which this same hook confines to the project).
No newlines, command substitution, eval, sh -c, variables or quote tricks in command
position, redirects (except to /dev/null), heredocs, background jobs, globs or ~ in paths,
recursive grep, or reads of state/env/key/.git files. Environment assignments are limited to
an empty AWS_PAGER and the region. Every aws call must run as AWS_READONLY_PROFILE (via
--profile, an AWS_PROFILE= prefix, or the inherited AWS_PROFILE); with no read-only profile
named, or with AWS_ACCESS_KEY_ID/AWS_SESSION_TOKEN in the environment, aws calls are blocked.
Read/Grep/Glob calls (same hook) may only touch the project and ~/.config/opencode/references.
"""
import json
import os
import re
import shlex
import sys

AWS_OPERATIONS = {
    "sts": {"get-caller-identity"},
    "iam": {
        "get-role", "get-user", "get-group", "get-policy", "get-policy-version", "list-policy-versions",
        "get-role-policy", "get-user-policy", "get-group-policy",
        "list-attached-role-policies", "list-role-policies", "list-attached-user-policies",
        "list-user-policies", "list-attached-group-policies", "list-group-policies",
        "list-groups-for-user", "list-roles", "list-instance-profiles-for-role",
        "generate-service-last-accessed-details", "get-service-last-accessed-details",
        "get-service-last-accessed-details-with-entities",
    },
    "accessanalyzer": {
        "start-policy-generation", "get-generated-policy", "list-policy-generations",
        "validate-policy", "check-no-new-access", "check-access-not-granted",
    },
    "cloudtrail": {"describe-trails", "get-trail", "get-trail-status", "list-trails"},
    "ce": {
        "get-cost-and-usage", "get-cost-forecast", "get-anomalies", "get-anomaly-monitors",
        "get-dimension-values", "get-tags", "list-cost-allocation-tags",
        "get-savings-plans-coverage", "get-savings-plans-utilization",
        "get-reservation-coverage", "get-reservation-utilization", "get-rightsizing-recommendation",
    },
    "budgets": {"describe-budgets", "describe-budget-performance-history"},
    "compute-optimizer": {
        "get-enrollment-status", "get-ec2-instance-recommendations", "get-ebs-volume-recommendations",
        "get-auto-scaling-group-recommendations", "get-lambda-function-recommendations",
    },
}
# Which services each agent may call (the hook passes the agent's scope as its argument).
SCOPES = {
    "iam": {"sts", "iam", "accessanalyzer", "cloudtrail"},
    "cost": {"sts", "ce", "budgets", "compute-optimizer"},
    "docs": set(),
}
SCOPE = sys.argv[1] if len(sys.argv) > 1 else ""
# Global options that take a value and are safe. Anything that points the CLI at another
# endpoint or makes it read local files is refused.
VALUE_OPTS = {"--profile", "--region", "--output", "--query", "--color", "--page-size",
              "--max-items", "--starting-token", "--cli-read-timeout", "--cli-connect-timeout"}
FORBIDDEN_OPTS = {"--endpoint-url", "--ca-bundle", "--cli-input-json", "--cli-input-yaml",
                  "--no-verify-ssl", "--generate-cli-skeleton", "--debug", "--no-sign-request",
                  "--cli-auto-prompt", "--help", "--version"}
# The profile may only be the read-only one the user named when starting opencode.
READONLY_PROFILE = os.environ.get("AWS_READONLY_PROFILE", "")
# Project files that commonly hold secrets.
SENSITIVE = re.compile(
    r"(^|/)(\.git(/|$)|\.terraform(/|$)|\.aws(/|$)|\.ssh(/|$)|\.kube(/|$)|\.docker(/|$)|\.gnupg(/|$)"
    r"|\.env[^/]*$|[^/]*\.tfstate[^/]*$|[^/]*\.tfvars(\.json)?$|[^/]*\.(pem|key|p12|pfx)$"
    r"|\.config(/|$)|serviceaccount(/|$)|[^/]*credentials[^/]*$|[^/]*\.tfrc(\.json)?$"
    r"|\.npmrc$|\.netrc$|\.pypirc$|id_(rsa|ecdsa|ed25519)[^/]*$|settings\.local\.json$)")
# The only long options grep and ls may use (exact names; abbreviations are refused).
GREP_LONG = {"--count", "--ignore-case", "--line-number", "--invert-match", "--word-regexp", "--line-regexp",
             "--fixed-strings", "--extended-regexp", "--only-matching", "--quiet", "--no-filename",
             "--with-filename", "--max-count", "--color", "--colour", "--no-messages"}
# Global AWS CLI flags without a value that are allowed before the service name.
GLOBAL_FLAGS = {"--no-paginate", "--no-cli-pager", "--no-cli-auto-prompt"}
# Text tools; they work on piped input only (see check_tool).
TEXT_TOOLS = {"jq", "grep", "head", "tail", "wc", "cut", "tr", "echo", "printf", "sleep", "true"}
SAFE_ENV = {"AWS_REGION", "AWS_DEFAULT_REGION", "AWS_DEFAULT_OUTPUT"}
OPERATORS = {"|", "&&", "||", ";"}
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
JQ_FORBIDDEN = re.compile(r"\benv\b|\$ENV|input_filename|\$__|\binputs?\b|\bdebug\b|\bstderr\b"
                          r"|\bimport\b|\binclude\b|\bmodulemeta\b|\bget_search_list\b")


class Blocked(Exception):
    pass


class Context:
    def __init__(self, root, cwd):
        self.root = os.path.realpath(root)
        self.cwd = os.path.realpath(cwd)

    def inside(self, path):
        if any(c in path for c in "*?[]~{}") or path.startswith("-"):
            return False
        full = os.path.realpath(os.path.join(self.cwd, path))
        return full == self.root or full.startswith(self.root + os.sep)


def check_profile(value):
    if not READONLY_PROFILE or value != READONLY_PROFILE:
        raise Blocked("choosing the AWS profile %r (only AWS_READONLY_PROFILE=%r is allowed)" % (value, READONLY_PROFILE))


def check_aws(args, env_profile=None):
    if args == ["--version"]:
        return
    if not READONLY_PROFILE:
        raise Blocked("AWS calls before a read-only profile is named (start opencode with AWS_READONLY_PROFILE=<profile>)")
    if any(os.environ.get(v) for v in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN")):
        raise Blocked("AWS calls while AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_SESSION_TOKEN are set "
                      "(they override the read-only profile)")
    explicit = None
    for k, a in enumerate(args):
        name = a.split("=", 1)[0]
        # Also catch abbreviations of forbidden options and of --profile (--en, --deb, --prof, ...).
        if name.startswith("--") and len(name) > 2 and any(f.startswith(name) for f in FORBIDDEN_OPTS | {"--profile"}) and name != "--profile":
            raise Blocked("aws %s" % name)
        if a == "help":
            raise Blocked("aws help")
        if name == "--profile":
            explicit = a.split("=", 1)[1] if "=" in a else (args[k + 1] if k + 1 < len(args) else "")
            check_profile(explicit)
        if "file://" in a or "fileb://" in a:
            raise Blocked("aws reading a local file (%s)" % a)
    effective = explicit or env_profile or os.environ.get("AWS_PROFILE", "")
    if effective != READONLY_PROFILE:
        raise Blocked("an AWS call that would use the profile %r instead of %r (add --profile %s)"
                      % (effective or "default credentials", READONLY_PROFILE, READONLY_PROFILE))
    words, i = [], 0
    while i < len(args):
        a = args[i]
        name = a.split("=", 1)[0]
        if len(words) < 2:
            if a.startswith("-"):
                # Before the service name only exact, known global options are accepted.
                if name not in VALUE_OPTS and name not in GLOBAL_FLAGS:
                    raise Blocked("the aws global option %r" % name)
                i += 2 if (name in VALUE_OPTS and "=" not in a) else 1
                continue
            words.append(a)
        i += 1
    if len(words) < 2:
        raise Blocked("an aws call without a service and operation")
    service, op = words
    if SCOPE and service not in SCOPES.get(SCOPE, set()):
        raise Blocked("aws %s calls from the %r agent (outside its scope)" % (service, SCOPE))
    if op not in AWS_OPERATIONS.get(service, ()):
        raise Blocked("aws %s %s (not on this agent's list of read-only operations)" % (service, op))


def short_flags(args):
    """Every single-letter flag, including ones bundled like -nf or -rnf."""
    return {c for a in args if a.startswith("-") and not a.startswith("--") for c in a[1:]}


def long_opts(args):
    return {a.split("=", 1)[0] for a in args if a.startswith("--")}


def check_tool(ctx, base, args):
    """Text tools work on piped input only: no file arguments, so no file can be read through them.
    (The agents read files with the Read/Grep/Glob tools, which have their own path allowlist.)"""
    if base == "jq":
        if short_flags(args) & set("fL") or long_opts(args) & {"--from-file", "--rawfile", "--slurpfile",
                                                               "--args", "--jsonargs", "--library-path"}:
            raise Blocked("jq reading files, modules or extra arguments")
        nonopt = [a for a in args if not a.startswith("-")]
        if len(nonopt) > 1:
            raise Blocked("jq with file arguments (pipe input into jq instead)")
        if nonopt and JQ_FORBIDDEN.search(nonopt[0]):
            raise Blocked("jq reading the environment or input files")
        return
    if base in ("echo", "printf", "sleep", "true", "tr"):
        return  # never read files
    positional = [a for a in args if not a.startswith("-") or a == "-"]
    if base == "grep":
        if long_opts(args) - GREP_LONG:
            raise Blocked("grep %s (only exact, known long options are allowed)" % sorted(long_opts(args) - GREP_LONG)[0])
        if short_flags(args) & set("efrRdD") or long_opts(args) & {"--regexp", "--file"}:
            raise Blocked("grep -e/-f/-r (give the pattern as the only argument, on piped input)")
        if len(positional) != 1:
            raise Blocked("grep with file arguments or option values (use piped input and attached values like -A2)")
        return
    # head, tail, wc, cut: options only, with values attached (-n5, -c20, -d, -f1).
    if long_opts(args):
        raise Blocked("%s %s (long options are not allowed)" % (base, sorted(long_opts(args))[0]))
    if positional:
        raise Blocked("%s with file arguments or detached option values (pipe input in; write -n5, not -n 5)" % base)
    if base == "tail" and "f" in short_flags(args) or base == "tail" and "F" in short_flags(args):
        raise Blocked("tail -f")


def check_simple(ctx, words):
    env_profile = None
    while words and ASSIGN.match(words[0]):
        name, value = ASSIGN.match(words[0]).groups()
        if name == "AWS_PROFILE":
            check_profile(value)
            env_profile = value
        elif not (name in SAFE_ENV or (name == "AWS_PAGER" and value == "")):
            raise Blocked("setting %s=%s" % (name, value))
        words = words[1:]
    if not words:
        return
    cmd, args = words[0], words[1:]
    if cmd == "aws":
        check_aws(args, env_profile)
    elif cmd in TEXT_TOOLS:
        check_tool(ctx, cmd, args)
    else:
        raise Blocked("the command %r (not on this agent's allowlist)" % cmd)


def check(command, ctx):
    if not command.strip():
        return
    if "\n" in command or "\r" in command:
        raise Blocked("multi-line commands (run one line at a time)")
    for bad, what in (("$(", "command substitution"), ("`", "command substitution"), ("<(", "process substitution"),
                      (">(", "process substitution"), ("<<", "heredocs"), ("$", "shell variables")):
        if bad in command:
            raise Blocked(what)
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|<>()")
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        tokens = list(lex)
    except ValueError as e:
        raise Blocked("a command it could not parse (%s)" % e)
    simple, i = [], 0
    while i < len(tokens):
        t = tokens[i]
        if t in OPERATORS:
            check_simple(ctx, simple)
            simple = []
        elif t and set(t) <= set(";&|<>()"):
            # An operator token that isn't |, &&, || or ;: only plain > or >& are tolerated,
            # and only to /dev/null or another stream. Covers >|, >>, &>, <, (, ), & and the rest.
            target = tokens[i + 1] if i + 1 < len(tokens) else ""
            if t == ">" and target == "/dev/null" or t == ">&" and target in ("1", "2"):
                pass
            else:
                raise Blocked("the shell operator %r" % t)
            if simple and simple[-1] in ("1", "2"):
                simple.pop()
            i += 1
        else:
            simple.append(t)
        i += 1
    check_simple(ctx, simple)


# A Grep over a directory searches file contents recursively, so it must be limited to file
# types that don't hold secrets (Grep's `glob` or `type` filter).
SAFE_GREP_GLOB = re.compile(r"^(\*\*/)?\*\.(tf|hcl|md|ya?ml|tpl)$|^\*\.\{(tf|hcl|md|ya?ml|tpl)(,(tf|hcl|md|ya?ml|tpl))*\}$")
SAFE_GREP_TYPES = {"terraform", "tf", "hcl", "md", "markdown", "yaml"}


def allowed_read_roots(cwd):
    project = os.path.realpath(os.environ.get("POWERHOUSE_PROJECT_DIR") or cwd)
    if project in ("/", os.path.realpath(os.path.expanduser("~"))):
        raise Blocked("file access when the project directory is / or your home directory")
    return [project, os.path.realpath(os.path.expanduser("~/.config/opencode/references"))]


def check_file_tool(tool_name, tool_input, cwd):
    """Read/Grep/Glob: only the project and the shared references, and never secret-bearing files."""
    roots = allowed_read_roots(cwd)
    for key in ("file_path", "path"):
        value = tool_input.get(key)
        if value is None:
            continue
        if not isinstance(value, str):
            raise Blocked("an unexpected %s" % key)
        full = os.path.realpath(os.path.join(cwd, os.path.expanduser(value)))
        root = next((r for r in roots if full == r or full.startswith(r + os.sep)), None)
        if root is None:
            raise Blocked("%s outside the project (%r)" % (tool_name, value))
        # Judged relative to its root, so the references under ~/.config/opencode stay readable.
        if SENSITIVE.search(os.path.relpath(full, root)):
            raise Blocked("%s of %r (state, env, key, credential or .git files can hold secrets)" % (tool_name, value))
    if tool_name == "Glob":
        pattern = tool_input.get("pattern", "")
        if not isinstance(pattern, str) or pattern.startswith(("/", "~")) or ".." in pattern.split("/"):
            raise Blocked("a Glob pattern outside the project (%r)" % pattern)
        if SENSITIVE.search(pattern):
            raise Blocked("a Glob for secret-bearing files (%r)" % pattern)
    if tool_name == "Grep":
        target = os.path.realpath(os.path.join(cwd, os.path.expanduser(tool_input.get("path") or ".")))
        if not any(target == r or target.startswith(r + os.sep) for r in roots):
            raise Blocked("Grep outside the project")
        if not os.path.isfile(target):
            glob, ftype = tool_input.get("glob"), tool_input.get("type")
            if not ((isinstance(glob, str) and SAFE_GREP_GLOB.match(glob)) or
                    (isinstance(ftype, str) and ftype in SAFE_GREP_TYPES)):
                raise Blocked("grep across a directory without a safe file filter (set include: \"*.tf\", "
                              "\"*.hcl\", \"*.md\" or \"*.yaml\"), so .env, state "
                              "and credential files aren't searched")


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name") in ("Read", "Grep", "Glob"):
            cwd = data.get("cwd") if isinstance(data.get("cwd"), str) and data.get("cwd") else os.getcwd()
            check_file_tool(data["tool_name"], data["tool_input"], cwd)
            return 0
        command = data["tool_input"]["command"]
        if not isinstance(command, str):
            raise TypeError("command is not a string")
        cwd = data.get("cwd") if isinstance(data.get("cwd"), str) and data.get("cwd") else os.getcwd()
        root = os.environ.get("POWERHOUSE_PROJECT_DIR") or cwd
        check(command, Context(root, cwd))
        return 0
    except Blocked as b:
        print("Blocked by aws-readonly-guard: %s. This agent may run only its listed read-only AWS calls "
              "and simple text tools on project files, one plain line at a time (no $..., eval, sh -c, "
              "redirects or interpreters). Use literal values, and propose changes instead of making them." % b,
              file=sys.stderr)
        return 2
    except Exception as e:  # anything unexpected blocks
        print("aws-readonly-guard: could not check this command (%s); blocking." % type(e).__name__, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
