# A stalled vsock receiver, and what a connection costs

**Date:** 2026-08-17 · **Hardware:** MacBookPro18,4, Apple M1 Max, macOS 27.0
(26A5406e) host · **Guest:** macOS 26.6 (25G72) / 26.6.1 (25G76), 4 vCPU, 8 GB ·
**Seam:** raw `AF_VSOCK` from inside a live guest against a running Kernova
(Debug), no code change · **Tracking issue:** #891

## Summary

#891 replaces chunk-and-credit framing with one vsock connection per transfer,
carrying the archive codec straight on the socket. Two questions had to be
answered from a live VM before that design could be fixed: whether the transport
needs an in-band "ready for more" message, and whether a connection per transfer
is affordable.

1. **The VZ helper does not buffer for a stalled receiver.** With Kernova
   `SIGSTOP`ped mid-stream, the guest's blocking `syswrite` parked after ≈1 MiB
   and stayed parked for the whole 70 s window, while the helper's resident size
   held within 1.22 MB and its `phys_footprint` did not move at all. On
   `SIGCONT` the guest drained 1 → 125 MiB in 0.3 s.
   **RESULT: bounded — back-pressure reaches the guest writer, and a receiver
   that stops reading costs the host nothing.**
   **Decision:** no ready-for-more message and no app-level credit accounting.
   Flow control is the kernel's — `write(2)` blocks on a full send buffer, and
   nothing above it counts bytes.
2. **A connection costs a fraction of a millisecond.** Over 50 sequential
   connect+close from the guest to a host port: connect min 0.262, p50 0.373,
   p90 1.306, max 4.081 ms; close p50 0.027 ms. 41 of the 50 connects finished
   under 1 ms, and none failed or was refused.
   **RESULT: negligible — the worst single sample clears the ≪ 10 ms bar by
   2.5×, and the median clears it by 27×.**
   **Decision:** dial one connection per transfer. No pooling, pre-warming, or
   reuse across transfers is needed to make the design pay.

## Measurement 1 — memory under a stalled receiver

Kernova's own protocol cannot produce this state: its credit window stops the
sender long before the receiver's buffers fill. So the writer is a raw guest
process, and the receiver is stalled by suspending the whole app.

### Method

1. Start a macOS guest and let its agent connect. A feature port admits any
   guest process once the agent's control Hello has landed — admission checks
   the handshake and the capability, not the connecting process.
2. Inside the guest, suspend the agent (`kill -STOP <agent pid>`, with a
   `kill -CONT` watchdog). Without this the run cannot be held: an accepted
   connection on a feature port displaces the agent's own channel, and the agent
   redials fast enough to displace the raw connection straight back.
3. Inside the guest, run a Perl writer. It opens `socket($S, 40, SOCK_STREAM, 0)`
   (`AF_VSOCK` = 40) and connects with
   `pack("CCSLL", 12, 40, 0, 49153, 2)` — `sockaddr_vm`: length 12, family 40,
   reserved, port, `cid` 2 = the host. It first writes a 4-byte frame prefix
   `pack("N", 134217727)`, so a read landing before the stop parks waiting for a
   payload instead of closing the connection; sleeps 10 s; then `syswrite`s
   1 MiB blocks in a loop, printing cumulative MiB.
4. On the host, during that sleep: `kill -STOP <Kernova pid>`. The VM keeps
   running — its vCPUs live in the helper process, not in the app.
5. Sample once a second for ~70 s: `ps -o rss=,vsz= -p <helper pid>` and
   `footprint -p <helper pid>`, where the helper is
   `com.apple.Virtualization.VirtualMachine`.
6. `kill -CONT <Kernova pid>`, then read the guest's counter.

### Results

Two runs. "Spread" is max − min of the helper's RSS across every sample strictly
inside the stall; the sample taken at the `SIGCONT` instant belongs to the
resume, not the stall, and is excluded.

| run | stall | samples | helper RSS | spread | `phys_footprint` |
|---|---|---|---|---|---|
| 1 | 70 s | 59 | 10,236,816–10,238,064 KB | 1.22 MB | 8249–8255 MB |
| 2 | 83 s | 70 | 10,104,032–10,105,136 KB | 1.08 MB | 8249–8255 MB |

Malloc zone sizes were constant throughout both windows (Malloc Large 26 MB,
Small 19 MB, Tiny 256 KB), as was Kernova's own RSS while suspended.

Run 1's guest side is the discriminating half: its first counter line, `1 MiB`,
printed only *after* `SIGCONT` at 70.39 s — the writer had been parked in a
single `syswrite` for the entire window. It then reached 125 MiB in 0.3 s and
ended at `128 MiB err=Broken pipe`, Kernova having read the deliberately bogus
frame and closed.

That is what makes the flat RSS meaningful. Had the helper been buffering, its
resident size would track the guest's written count; instead the guest never got
more than roughly a megabyte in flight, and the helper's footprint never moved.

## Measurement 2 — connect and accept latency

### Method

1. A guest with the agent connected, and the VM's **Forward guest logs** on so
   that port 49153 is listening. 49153 is the log port: it accepts and keeps a
   connection, so a connect+close there disturbs no service.
2. Move the program into the guest over Kernova's own clipboard sharing (host
   `pbcopy` → Clipboard window → Paste from Mac → ⌘V in a guest Terminal).
   Typing it through the VZ display is not viable — several characters every
   shell path needs have no working spelling.
3. Run it. It writes `/tmp/m2-out.txt` and copies that file to the guest
   clipboard, so the numbers return over the same path with no further typing.
4. Read the host's accept lines over the run window:
   `/usr/bin/log show --start "<t0>" --end "<t1>" --info --predicate
   'subsystem BEGINSWITH "app.kernova" AND processID == <pid>'`.

The program, in full:

```perl
#!/usr/bin/perl
# kernova #891 stage 0, measurement 2: vsock connect/accept latency from a macOS guest.
# 50 sequential connect+close to the host (cid 2) on Kernova's log port 49153.
use strict;
use warnings;
use Socket;
use Time::HiRes qw(gettimeofday tv_interval usleep);

my $AF_VSOCK = 40;      # AF_VSOCK on macOS
my $PORT     = 49153;   # Kernova log port
my $CID      = 2;       # VMADDR_CID_HOST
my $N        = 50;
my $GAP_US   = 50000;   # 50 ms between iterations, so the agent's displaced log
                        # channel has redialled before the next connect

$SIG{PIPE} = 'IGNORE';
my $OUT = "/tmp/m2-out.txt";
open(my $fh, '>', $OUT) or die "open $OUT: $!";
sub emit { my $l = shift; print "$l\n"; print $fh "$l\n"; }

my (@conn, @clos);
for my $i (1 .. $N) {
    my $S;
    unless (socket($S, $AF_VSOCK, SOCK_STREAM, 0)) {
        emit(sprintf("%02d socket_failed=%s", $i, "$!"));
        next;
    }
    my $sa = pack("CCSLL", 12, $AF_VSOCK, 0, $PORT, $CID);
    my $t0 = [gettimeofday];
    my $ok = connect($S, $sa);
    my $t1 = [gettimeofday];
    my $err = $ok ? "" : " connect_err=$!";
    close($S);
    my $t2 = [gettimeofday];
    my $cu = tv_interval($t0, $t1) * 1e6;
    my $ku = tv_interval($t1, $t2) * 1e6;
    push @conn, $cu if $ok;
    push @clos, $ku if $ok;
    emit(sprintf("%02d connect_us=%.1f close_us=%.1f%s", $i, $cu, $ku, $err));
    usleep($GAP_US) if $i < $N;
}

sub summary {
    my ($label, @v) = @_;
    return "$label n=0" unless @v;
    my @s = sort { $a <=> $b } @v;
    my $n = scalar @s;
    my $sum = 0;
    $sum += $_ for @s;
    my $pick = sub { $s[int($_[0] * ($n - 1) + 0.5)] };
    sprintf("%s n=%d min=%.3f p50=%.3f p90=%.3f max=%.3f mean=%.3f (ms)",
        $label, $n, $s[0] / 1000, $pick->(0.5) / 1000, $pick->(0.9) / 1000,
        $s[-1] / 1000, ($sum / $n) / 1000);
}
emit(summary("CONNECT", @conn));
emit(summary("CLOSE  ", @clos));
close($fh);
system("/usr/bin/pbcopy < $OUT");
```

`connect(2)` and `close(2)` are timed separately; neither interval contains the
other, and neither contains the inter-iteration sleep. The gap exists so each
sample is a cold dial rather than a measurement of a loop, which is what a
per-transfer connection actually is.

### Results

50 of 50 connects succeeded. Times in milliseconds, guest-observed:

| | n | min | p50 | p90 | max | mean |
|---|---|---|---|---|---|---|
| connect | 50 | 0.262 | 0.373 | 1.306 | 4.081 | 0.620 |
| close | 50 | 0.014 | 0.027 | 0.053 | 0.118 | 0.030 |

41 samples finished under 1 ms; the remaining 9 spread from 1.02 to 4.08 ms.

Host side, the log shows 51 accepts on 49153 for the 50 connects, each iteration
reading `Accepted vsock connection` → `Guest log service started` → `Guest log
channel closed`, ~55 ms apart. Kernova's own accept-to-admitted span is 30–250 µs
in every iteration — a small fraction of each guest-observed sample, so the bulk
of the connect time is the guest → hypervisor → host path rather than the app's
handler.

The 51st accept is the agent restoring its own log channel, **2.536 s after the
last sample's accept** — displaced by iteration 01, and back only when it next
had records to forward. No redial interleaved with the run, so no sample is
inflated by one. (An earlier note on this technique recorded a ~1 ms redial;
that was a different agent build. Only the timing above is established here, not
whether the agent redials lazily or backs off.)

## Caveats

- **Debug build.** Host-side accept work is an upper bound.
- **Guest-observed round trips, not host accept cost.** The two are separated
  above only by the log's accept-to-admitted span.
- **Port 49153 stands in for the real thing.** #891's data ports do not exist
  yet, so this measures the shared accept path every vsock port uses.
- **n = 50, single run.** The nine-sample tail above 1 ms is real; its cause was
  not investigated.
- **The two measurements ran against different guest instances** of the same
  macOS version, on the same host.
- **≈1 MiB is an observation, not a contract.** It is where the writer parked
  with today's socket options, not a documented buffer size — the finding that
  transfers is that the parking point is bounded and small, not its value.
