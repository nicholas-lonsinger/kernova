# The Linux guest agent as built: what it is built from, its label, and what it
# must be before Kernova bundles it. Sourced, never run, by the scripts that
# build and label it.

# shellcheck shell=bash

# The most bytes a built agent may hold: about a third over its size, room for
# what later features add, and ICU's locale data alone would take it past.
LINUX_AGENT_BUDGET=$((16 * 1024 * 1024))

# The ELF section CKernovaAgentVersion holds the label in, all of it.
LINUX_AGENT_LABEL_SECTION=kernova_agent_label

# check_linux_agent <binary>: whether the binary is the agent Kernova can
# bundle — a statically linked aarch64 ELF within the budget, carrying no ICU
# data — reporting on stderr each way it is not. ICU arrives with Foundation's
# internationalization API, such as a date formatter with a locale, and not
# with the import alone; its locale data's table of contents names every item
# `icudt<version>…`. The binary is stripped, so its bytes are read rather than
# its symbols.
check_linux_agent() {
    local binary=$1 description size icu failed=0
    description="$(file -b "$binary")"
    case "$description" in
        *"ELF 64-bit LSB"*"ARM aarch64"*"statically linked"*) ;;
        *) echo "error: $binary is not a static aarch64 ELF: $description" >&2; failed=1 ;;
    esac
    size="$(wc -c <"$binary" | tr -d '[:space:]')"
    if [ "$size" -gt "$LINUX_AGENT_BUDGET" ]; then
        echo "error: $binary is $size bytes, over the $LINUX_AGENT_BUDGET-byte budget" >&2
        failed=1
    fi
    icu="$(LC_ALL=C grep -ac icudt "$binary" || true)"
    if [ "$icu" -ne 0 ]; then
        echo "error: $binary carries ICU data ($icu lines name icudt)" >&2
        failed=1
    fi
    return "$failed"
}

# linux_agent_label <binary>: prints the label the agent's label section holds.
linux_agent_label() {
    linux_agent_label_section "$1"
}

# stamp_linux_agent_label <binary> <label>: writes the label into the agent's
# label section, padded with NULs to the section's size, and changes no other
# byte. Fails, changing nothing, when the binary is not a 64-bit
# little-endian ELF with exactly one such section, or the label and its NUL
# do not fit.
stamp_linux_agent_label() {
    linux_agent_label_section "$1" "$2"
}

# linux_agent_label_section <binary> [<label>]: the reader and the writer, by
# the ELF section header table (the System V gABI's layout of an ELF64 file).
linux_agent_label_section() {
    perl -e '
        use strict;
        use warnings;
        my ($path, $name, $label) = @ARGV;
        open(my $fh, defined $label ? "+<" : "<", $path) or die "$path: $!\n";
        binmode $fh;
        sub at {
            my ($offset, $length) = @_;
            seek($fh, $offset, 0) or die "$path: $!\n";
            my $read = read($fh, my $bytes, $length);
            defined $read && $read == $length or die "$path: ends before byte " . ($offset + $length) . "\n";
            return $bytes;
        }
        my $ident = at(0, 16);
        substr($ident, 0, 4) eq "\x7fELF" or die "$path: not an ELF file\n";
        substr($ident, 4, 2) eq "\x02\x01" or die "$path: not a 64-bit little-endian ELF file\n";
        my ($table) = unpack("Q<", at(0x28, 8));
        my ($entry_size, $count, $names_index) = unpack("v3", at(0x3a, 6));
        $entry_size >= 0x40 && $names_index < $count or die "$path: its section header table is not one this reads\n";
        # sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size
        my @sections = map { [unpack("V V Q< Q< Q< Q<", at($table + $_ * $entry_size, 0x28))] } 0 .. $count - 1;
        my $names = at($sections[$names_index][4], $sections[$names_index][5]);
        my @found = grep {
            my $start = $sections[$_][0];
            my $end = index($names, "\0", $start);
            $end >= 0 && substr($names, $start, $end - $start) eq $name
        } 0 .. $#sections;
        @found == 1 or die "$path: holds " . scalar(@found) . " sections named $name, not one\n";
        my (undef, $type, undef, undef, $offset, $size) = @{$sections[$found[0]]};
        $type != 8 or die "$path: its $name section has no bytes in the file\n";  # SHT_NOBITS
        if (defined $label) {
            length($label) < $size or die "the label \"$label\" is " . length($label) . " bytes; $name holds $size with its NUL\n";
            seek($fh, $offset, 0) or die "$path: $!\n";
            print $fh $label . ("\0" x ($size - length($label))) or die "$path: $!\n";
            close($fh) or die "$path: $!\n";
        } else {
            my $bytes = at($offset, $size);
            $bytes =~ s/\0.*//s;
            print "$bytes\n";
        }
    ' "$1" "$LINUX_AGENT_LABEL_SECTION" "${@:2}"
}

# linux_agent_sources: reads KernovaKit's `swift package describe --type json`,
# as its portable manifest declares it, on stdin and prints the directory of
# every target kernova-agent is built from, one per line relative to the
# package. Fails when a dependency is not one the pins hold, or when the
# description does not place the product's own targets in it.
linux_agent_sources() {
    jq -r '
        [.dependencies[]? | select(.type != "sourceControl" and .type != "registry") | .identity] as $unpinned
        | [.products[]? | select(.name == "kernova-agent") | .targets[]] as $declared
        | [.targets[]? | select(any(.product_memberships[]?; . == "kernova-agent"))] as $members
        | if ($unpinned | length) > 0 then
            error("KernovaKit depends on \($unpinned | join(", ")), which the pins do not hold")
          elif ($declared | length) == 0 or ($declared - [$members[].name] | length) > 0 then
            error("the package description places none of, or not all of, kernova-agent'"'"'s targets in it")
          else
            $members[].path
          end'
}
