#!/usr/bin/env bash
# Fixture tests for Tools/lib/swift-source.pm: what `SwiftSource::blank` leaves
# of each Swift lexical form. Every expected text is worked by hand from the
# lexical structure in The Swift Programming Language, never produced by the
# code under test.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

# expect <name> <swift source> <blanked> — blanking the source gives exactly
# <blanked>, byte for byte.
expect() {
    local got
    got=$(printf '%s' "$2" | perl -e 'require $ARGV[0]; local $/; print SwiftSource::blank(scalar <STDIN>), "."' "$ROOT/Tools/lib/swift-source.pm")
    got=${got%.}
    [ "$got" = "$3" ] || fail "$1: got $(printf '%q' "$got"), wanted $(printf '%q' "$3")"
}

# Comments: one space each, their newlines kept.

expect line-comment $'let a = f() // a "quote" and print(x)\nlet b = 2' $'let a = f()  \nlet b = 2'

expect doc-comment $'/// print(x) and "quote"\nf()' $' \nf()'

expect block-comment-across-lines $'a /* one\n   "two */ b' $'a  \n b'

expect nested-block-comment 'a /* x /* y */ print(z) */ b' 'a   b'

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

# Extended regex literals: `""`, their newlines kept.

expect regex-literal-holding-a-quote 'let r = #/"/#; print(x); let s = "a"' 'let r = ""; print(x); let s = ""'

expect regex-literal-holding-slashes 'let r = #/https?://\w+/#; print(x)' 'let r = ""; print(x)'

expect multi-line-regex-literal 'let r = #/
    a " b
    /#
print(x)' 'let r = ""


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

if [ "$FAIL" -gt 0 ]; then
    printf 'swift-source fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'swift-source fixtures: all passed\n'
