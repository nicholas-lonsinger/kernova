#!/usr/bin/env bash
# Fixture tests for `dead-code-sources blank` (Tools/DeadCode): what it leaves
# of each Swift lexical form, and the files it refuses. Every expected text is
# worked by hand from the lexical structure in The Swift Programming Language
# and checked against `xcrun swiftc -parse -swift-version 6`'s reading, never
# produced by the code under test.
#
# fixture reads: Tools/install-dead-code-tool.sh Tools/lib/tool-cache.sh Tools/lib/dead-code-tool.sh
# fixture reads: Tools/lib/package-pins.sh Tools/DeadCode

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/dead-code-tool.sh
. "$ROOT/Tools/lib/dead-code-tool.sh"
dead_code_sources=$(fixture_dead_code_sources) || exit 1

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# record <name> <swift source> — the kind of the record the tool writes for a
# file holding the source, a newline, and the record's last field, then `.`.
record() {
    printf '%s' "$2" >"$tmp/$1.swift"
    "$dead_code_sources" blank "$tmp/$1.swift" | perl -e '
        binmode STDIN;
        local $/;
        my $record = <STDIN>;
        my ($kind, @lengths) = $record =~ /\A(\w+) (\d+) (\d+) (\d+)\n/ or die "no record\n";
        print $kind, "\n", substr($record, $+[0] + $lengths[0] + $lengths[1], $lengths[2]), ".";
    '
}

# expect <name> <swift source> <blanked> — blanking the source gives exactly
# <blanked>, byte for byte.
expect() {
    local got
    got=$(record "$1" "$2")
    got=${got%.}
    [ "$got" = "blanked"$'\n'"$3" ] || fail "$1: got $(printf '%q' "$got"), wanted $(printf '%q' "$3")"
}

# refused <name> <swift source> [<line>] — the file is unparsed, at <line>
# when one is given.
refused() {
    local got line
    got=$(record "$1" "$2")
    got=${got%.}
    case "$got" in
        "unparsed"$'\n'"$tmp/$1.swift:"*" does not parse as Swift") ;;
        *)
            fail "$1: got $(printf '%q' "$got"), wanted it unparsed"
            return
            ;;
    esac
    line=${got#*"$1.swift:"}
    line=${line%%:*}
    [ -z "${3:-}" ] || [ "$line" = "$3" ] || fail "$1: unparsed at line $line, wanted line $3"
}

# Comments: one space each, their newlines kept.

expect line-comment $'let a = f() // a "quote" and print(x)\nlet b = 2' $'let a = f()  \nlet b = 2'

expect doc-comment $'/// print(x) and "quote"\nf()' $' \nf()'

expect block-comment-across-lines $'a /* one\n   "two */ b' $'a  \n b'

expect nested-block-comment 'let a = 1 /* x /* y */ print(z) */ + 2' 'let a = 1   + 2'

# String literals: `"…"` holding only their interpolations.

expect comment-markers-in-a-string 'let u = "http://x /* y"; print(z)' 'let u = ""; print(z)'

expect escaped-quote 'let s = "a \" b"; print(z)' 'let s = ""; print(z)'

expect escaped-backslash-before-a-parenthesis 'let s = "a\\(dump(x))"; f()' 'let s = ""; f()'

expect escapes 'f("", "\u{22}", x)' 'f("", "", x)'

expect interpolation 'let s = "a \(dump(x)) b"' 'let s = "\(dump(x))"'

expect string-in-an-interpolation 'let s = "\(flag ? "print(" : "")"' 'let s = "\(flag ? "" : "")"'

expect parenthesis-in-an-interpolated-string '"\(f(")"))" + g()' '"\(f(""))" + g()'

expect interpolation-in-an-interpolation '"\(a ? "\(b)" : "c")"' '"\(a ? "\(b)" : "")"'

expect multi-line-interpolation 'let s = """
    text \(dump(x)) "quoted"
    """' 'let s = "
\(dump(x))
"'

expect multi-line-escaped-delimiter 'let s = """
    a \""" b
    """
print(x)
let t = """
    c
    """' 'let s = "

"
print(x)
let t = "

"'

expect multi-line-line-continuation 'let s = """
    a \
    b
    """' 'let s = "


"'

# Raw strings: the `#`s set the closing delimiter and the interpolation.

expect raw-string 'let s = #"a "b" \(dump(x)) // c"#; f()' 'let s = ""; f()'

expect raw-interpolation 'let s = #"a \#(dump(x)) b"#' 'let s = "\(dump(x))"'

expect raw-string-two-hashes 'let s = ##"a "# \#(x) b"##; f()' 'let s = ""; f()'

expect multi-line-raw-string 'let s = #"""
    a "#tag" \#(dump(x))
    """#
print(y)
let t = """
    c
    """' 'let s = "
\(dump(x))
"
print(y)
let t = "

"'

# `#"""` opens a multi-line raw string only when a newline follows it; with a
# `"#` later on its line it is a single-line raw string starting with quotes.

expect raw-string-of-two-quotes 'let a = #""""#; print(x)' 'let a = ""; print(x)'

expect raw-string-starting-with-quotes 'let b = #"""quoted" word"#; print(y)' 'let b = ""; print(y)'

# Regex literals: `"…"`, their newlines kept. A bare one (`/…/`) where Swift
# reads one; a `/` after an operand is division.

expect regex-literal-holding-a-quote 'let r = #/"/#; print(x); let s = "a"' 'let r = ""; print(x); let s = ""'

expect regex-literal-holding-slashes 'let r = #/https?://\w+/#; print(x)' 'let r = ""; print(x)'

expect multi-line-regex-literal 'let r = #/
    a " b
    /#
print(x)' 'let r = "

"
print(x)'

expect bare-regex-holding-quotes 'let m = s.firstMatch(of: /key="([^"]*)"/); print(y)' 'let m = s.firstMatch(of: ""); print(y)'

expect bare-regex-holding-escaped-slashes 'let r = /a\/\/b/; print(x)' 'let r = ""; print(x)'

expect bare-regexes-in-an-array 'let rs = [/a"/, /b/]; print(x)' 'let rs = ["", ""]; print(x)'

expect bare-regex-returned 'func f() -> Regex<Substring> { return /x"/ }
print(x)' 'func f() -> Regex<Substring> { return "" }
print(x)'

expect division 'let q = a / b / c
let p = x/2/y' 'let q = a / b / c
let p = x/2/y'

# Raw identifiers: a name between backticks is code, kept as written.

expect raw-identifier 'func `matches /* glob`() {}
print(x)' 'func `matches /* glob`() {}
print(x)'

expect raw-identifier-holding-a-quote 'func `says "hi`() {}
print(x)' 'func `says "hi`() {}
print(x)'

# Directives are code, every branch of a conditional block included.

expect directives '#if DEBUG
print(x)
#elseif os(Linux)
dump(y)
#else
let s = #selector(f)
#endif' '#if DEBUG
print(x)
#elseif os(Linux)
dump(y)
#else
let s = #selector(f)
#endif'

# A file that does not parse is refused whole: at the line where a single-line
# literal cannot close, at the `/*` of a comment that never closes, and
# anywhere for a multi-line string the file's end leaves open.

refused unterminated-string 'let a = 1
let s = "never closed
print(x)' 2

refused unterminated-raw-string 'let s = #"never closed"
print(x)' 1

refused unterminated-multi-line-string 'let s = """
    never closed
print(x)'

refused unterminated-block-comment 'let a = 1
/* never closed
print(x)' 2

refused unterminated-regex-literal 'let r = #/never closed
print(x)' 1

if [ "$FAIL" -gt 0 ]; then
    printf 'swift-source fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'swift-source fixtures: all passed\n'
