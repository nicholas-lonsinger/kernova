# The digest of a protobuf schema, which Tools/regen-protos.sh writes beside
# the schema's generated Swift. Sourced, never run:
#
#     . Tools/lib/proto-digest.sh
#     proto_schema_digest KernovaKit/Sources/KernovaWire/Proto/kernova_v2.proto   # 0x9f3a…
#
# The schema is the file's text with every `//` comment removed and each run
# of whitespace, line breaks included, made one space, trimmed at both ends;
# the digest is the first four bytes of that text's SHA-256, big-endian, with
# the top bit set, so it is never 0 and never a hand-numbered version.

# shellcheck shell=bash

# proto_schema_digest <file> — prints the digest as 0x and eight hex digits.
proto_schema_digest() {
    local hash
    hash=$(sed -e 's://.*$::' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//' | tr -d '\n' |
        shasum -a 256) || return
    printf '0x%08x\n' $((0x${hash:0:8} | 0x80000000))
}
