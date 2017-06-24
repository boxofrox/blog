extends: default.liquid

title: Debugging a Race Condition in a Release Target
date: 08 August 2017 00:00:00 -0500
start-date: 24 June 2017 00:00:00 -0500
path: /:year/:month/debugging-a-rust-release-build.html
tags: rust, debugging, rr, reverse debugger
---

Back in June, while working on a [Rust](https://rustlang.org) project, I had
the unfortunate opportunity to stumble upon a very obscure bug in a dependency.
The bug didn't occur in the debug build target at all, only the release target.
And even then, the bug didn't present itself 100%.  It hovered between 10-50%.

I'll cover the obstacles I encountered, the tools I used, and how I applied
them.  This story involves Rust stable 1.18 and nightly 1.19 along with GDB 8.0
and reverse debugger (*rr*) 4.5.0.

## What Am I Developing?

A customer of mine uses open-source software to manage their inventory and
organize the inventory with an unorthodox method. Searching with MySQL queries
against multiple fields scattered across a few tables has slowed to a crawl
(10-60 seconds) as the size of their inventory grew.  On top of that, the
search results lacked any scoring and many results were irrelevant.

So I decided to solve this problem--once and for all!!... perhaps--by writing a
custom fuzzy search daemon that will periodically fetch the searchable data
from the database and cache it, then allow the inventory software to exchange
search terms for a much shorter list of relevant search results.

I chose Rust to program the daemon, and in anticipation for orchestrating the
many tasks that will be incorporated--most of which are input/output (IO)
bound--I settled on using [*tokio*](https://crates.io/crates/tokio) async
framework along with the [*mysql_async*](https://crates.io/crates/mysql_async)
crate which provides a database API utilizing *tokio*.

I created an initial proof of concept (POC) by rewriting my [favorite fuzzy
search program](https://github.com/jhawthorn/fzy) with a scoring algorithm
relevant to my needs.  Search data was exported from the customer's database
and placed in a CSV file to avoid the complexity of database programming at
this stage.  Testing the fuzzy search showed it performed abysmally with the
debug target (upward of 5-10 seconds to match and score against 100k
candidates), while the release target operated between 11-30 milliseconds.
Also promising is that the search data used with this POC only consumed 2.5 MB.


## The Symptom

How I found this bug is a story itself, and demonstrates why monopolizing
testing against a debug target may postpone disaster until you near the end of a
project.  I prefer to identify bugs as early as possible via spot testing so
troubleshooting has less code to suspect.

As I add new features (e.g. config file, DB support, HTTP interface, endpoints,
etc), I'll test mostly against the debug target, and before moving on to
another feature, I'll check the release target to ensure performance hasn't
dropped significantly.

It was during this release target test for the database addition that
*mysql_async* first reported a `PacketOutOfOrder` error.  I retested a dozen
times or so and found the error occurred frequently, but not every time.

```shell
▶ DSN=mysql://testbot:testbot@192.168.0.162/fake_data RUST_LOG=bug_test_01=debug ./target/release/bug-test-01
DEBUG:bug_test_01: running
thread 'main' panicked at 'error resolving future: Error(PacketOutOfOrder, State { next_error: None, backtrace: None })', src/libcore/result.rs:859
note: Run with `RUST_BACKTRACE=1` for a backtrace.
```

This is a problem.  A single query will pull megabytes of data from the MySQL
server and cache that information to facilitate fast searches.  The application
can't frequently fail to pull megabytes of data and retry without putting
unwanted load on the network and database.  I must understand why the
application runs flawlessly on the slow debug target, but not on the blazingly
fast release target.

The game is afoot.

## First Steps

A long time ago, I eschewed Windows in favor of Linux.  Over the years, I
discarded integrated development environments (IDEs) and their difficult build
systems, opinionated project layouts, *\*cough\** and lack of Vim keybindings
*\*cough\**.  I've much enjoyed the command-line and its versatility and the
development tools that live there.

Except the Gnu debugger (GDB).  It has been my Kryptonite when debugging
programs and it's typically a last resort.  I just haven't paid the technical
debt to master it, or for the matter use it proficiently.

So my first-pick method for determining what my program *is* doing versus what
it *should* be doing is print statements.  Since the error originated from
*mysql_async*, I cloned the crate locally and modified it to print the MySQL
packet sequence ID it found before the error.

```diff
diff --git a/src/conn/futures/read_packet.rs b/src/conn/futures/read_packet.rs
index 33719f0..ea5fe58 100644
--- a/src/conn/futures/read_packet.rs
+++ b/src/conn/futures/read_packet.rs
@@ -46,6 +46,7 @@ impl Future for ReadPacket {
                         let packet = {
                             let conn = self.conn.as_mut().unwrap();
                             if conn.seq_id != seq_id {
+                                debug!("packet out of order.  found {}, expected {}", seq_id, conn.seq_id);
                                 return Err(ErrorKind::PacketOutOfOrder.into());
                             }
                             conn.stream = Some(stream);
```

The output from a test run confirmed the sequence did break (expected 98, found
221), and after a few more test runs, I found the error never occurs at the
same MySQL packet.  Is my program receiving garbage from my database, or is it
buggy?

```shell
▶ DSN=mysql://testbot:testbot@192.168.0.162/fake_data RUST_LOG=bug_test_01=debug,mysql_async=debug ./target/release/bug-test-01
DEBUG:bug_test_01: running

...connection handshake and query submission...

DEBUG:mysql_async::proto: Last seq id 1
DEBUG:mysql_async::proto: Last seq id 2
DEBUG:mysql_async::proto: Last seq id 3
DEBUG:mysql_async::proto: Last seq id 4
DEBUG:mysql_async::proto: Last seq id 5
DEBUG:mysql_async::proto: Last seq id 6
DEBUG:mysql_async::proto: Last seq id 7
DEBUG:mysql_async::proto: Last seq id 8
DEBUG:mysql_async::proto: Last seq id 9
DEBUG:mysql_async::proto: Last seq id 10

...sequence of repeating ids from 0 to 255...

DEBUG:mysql_async::proto: Last seq id 217
DEBUG:mysql_async::proto: Last seq id 218
DEBUG:mysql_async::proto: Last seq id 219
DEBUG:mysql_async::proto: Last seq id 220
DEBUG:mysql_async::proto: Last seq id 221
DEBUG:mysql_async::proto: Last seq id 98
DEBUG:mysql_async::conn::futures::read_packet: packet out of order.  found 98, expected 221
thread 'main' panicked at 'error resolving future: Error(PacketOutOfOrder, State { next_error: None, backtrace: None })', src/libcore/result.rs:859
note: Run with `RUST_BACKTRACE=1` for a backtrace.
```


I previously used my MySQL 5.5 database server extensively for a variety of
tests in the past without issue, so I'm not inclined to suspect it suddenly
broke.  But I don't like uncertainty hovering over my shoulder when I'm trying
to troubleshoot.  It has a tendency to accumulate.  Besides, a quick network
packet analysis with [Wireshark](https://www.wireshark.org) should confirm
whether the problem is in my application or beyond my network interface card
(NIC).  Yep.  Just a quick analysis....

Turns out Wireshark has nifty dissectors that will parse protocols within
protocols.  It has one for MySQL!  And it found a malformed MySQL packet!  Whew,
am I glad the cause isn't some random intermittent behavior in my program,
because I wasn't looking forward to that bug hunt at all.

<div class="figure">

![wireshark malformed packet](/assets/images/2017-debug-rust-release-target/wireshark-malformed-packet.png)

</div>

I've come to learn that a thorough attention to detail is essential to
troubleshoot productively.  Always look at your results from different angles
and verify they are all in accord.

So back to Wireshark I go.  I should be able to cross reference the last
sequence ID from my print statements against the Wireshark packet capture.  The
packet prior to the malformed packet has a sequence ID of 193 while my print
statements claim it parsed sequence ID 101 before finding 52.  I also get
malformed MySQL packets in Wireshark when the test run succeeds.  This is "no
bueno".  So much for quick.  Jinxed again.

```
# Ouput corresponding to Wireshark capture screenshot.
▶ DSN=mysql://testbot:testbot@192.168.0.162/fake_data RUST_LOG=bug_test_01=debug,mysql_async=debug ./target/release/bug-test-01
...
DEBUG:mysql_async::proto: Last seq id 100
DEBUG:mysql_async::proto: Last seq id 101
DEBUG:mysql_async::proto: Last seq id 52
DEBUG:mysql_async::conn::futures::read_packet: packet out of order.  found 52, expected 102
thread 'main' panicked at 'error resolving future: Error(PacketOutOfOrder, State { next_error: None, backtrace: None })', src/libcore/result.rs:859
```

At this point in my story, I took a long detour to debug Wireshark's MySQL
dissector.  I won't go into the details.  I reported the
[bug](https://bugs.wireshark.org/bugzilla/show_bug.cgi?id=13754), found a
work-around, recompiled Wireshark with a patch, and was back in business.  No
more malformed MySQL packets.

Afterwards, I captured all the MySQL packets until my program reset the TCP
connection to the database.  Wireshark shows all the sequence IDs are in order
now...  repeatedly.  I think it's safe to say my network hardware is functioning
properly along with the database.  But for good measure, I tested against a
spare MariaDB 10.1.21 database, and the application still suffers from
`PacketOutOfOrder`.

Note that this entire time I reran a single SQL query against one dataset,
so every query execution should transfer identical data from the database.

At this point, my application fails at random points while parsing the SQL
packets.  I'm certain the failure occurs on the same instruction[s], just at a
different iteration of some loop executing that instruction.  I could switch to
a debugger and stop at this random point with a breakpoint on the code that
noticed the mismatched sequence ID, but there's a couple problems with heading
in this direction now:

1.  I have to backtrack from this random point.  I'm not familiar with GDB's
    reverse debugging (running the program backwards), so I'd rather not rely
    on it at this point.  Without reverse debugging, I need the cause of the
    problem to be in the program stack when I hit the breakpoint.  Since I'm
    using futures to write asynchronous code, there's a good chance the cause
    is no longer on the program stack.

2.  I'm debugging an optimized release target.  The optimizations can prevent
    GDB from accessing variables (i.e. `print var`).  They also reorder
    instructions and program follows a different order of execution than the
    source code presents.

3.  The release target has no debugging information.  This prevents GDB from
    matching the assembly code to my source code.  Later, I found that Rust can
    build release targets with debugging information.  Just add the following to
    your `Cargo.toml` \[[3]].

      ```toml
      [profile.release]
      debug = true
      ```

[3]: http://doc.crates.io/manifest.html#the-profile-sections

Let's try to get ahead of that point in the program when it runs awry.


## What is the MySQL Parser Doing?

The [MySQL protocol][mysql-protocol] starts out rather simple.  A four-byte
header holds a three-byte length and a one-byte sequence ID.  The header is
followed by `length` bytes of data.  The data must be parsed at some point, but
I can ignore that in this case.  The data contains rows of the result set for
the SELECT query I run.  At the point my application fails, the data section
does not influence parsing the MySQL packets.

[mysql-protocol]: https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html

I added some extra print statements to *mysql_async*'s code that parsed the
network data into MySQL packets give me a brief play-by-play description of its
process to answer questions like:

1.  When does it start on a new packet?
2.  When is it waiting on bytes for the header?
3.  When does it have the header and what values did it find?
4.  When does it get the data?

With three, maybe four, print statements the error disappears.  Remove
those print statements, the error returns.  Add them, the error vanishes.  This
bug appears to be a race condition.  Those print statements delay the parsing
loop just long enough that the bug cannot manifest itself.  This severely
hampers my ability to generate clues.

Using one or two print statements to collect information isn't effective when
the bug presents at random points in the execution path.  Stepping forward
through the application with GDB will certainly delay the execution and prevent
the race condition from manifesting.  I wasn't sure sure how to debug this
further, so I asked for help.


## A Short, Self Contained, Correct Example

Asking for programming/debugging advice is fraught with peril.  Provide too few
details, and the person trying to help must fill in the blanks using their
imagination or ask 20+ questions.  The former leads to a thread of confusion and
irrelevant solutions to similar-but-different problems.  The latter can quickly
cascade into a waste of everyone's time.  It helps to imagine someone else is
asking you to help solve the problem, and consider what information you would
need from them.

On the other, hand providing too much information can make the problem difficult
to understand or identify.  The wise sages of the internet love nothing more
than to impart the correct knowledge with the least fuss.

To this end, the short, self contained, correct example
([SSCCE](http://sscce.org)) is a terrific tool that demonstrates the problem,
and allows intrepid programmers to fully understand the task at hand; find a
specific, pertinent solution; and test their solution works before submission.

It's also often the case that in generating an SSCCE (or a very detailed
question), I stumble upon the answer myself before any question is presented.
Do not underestimate the utility of this exercise, no matter how tedious.

One additional benefit of an SSCCE is that it's small and quicker to compile
than a large application.  When you're poking and prodding the source code to
see what effect that has, short compile times matter.

By the time I post my [SSCCE on
github](https://github.com/boxofrox/sscce-future-is-buggy-01), I stripped away
all my application code and what is left is a *how to use* example from the
*mysql_async* README.  My code is no longer suspect.  But how far down my software
stack do I have to go to chase this bug?


## Presenting the Reverse Debugger

On the [Rust user forum][rust-forum-post], @inejge recommended I try
[*rr*](http://rr-project.org/).  It's a nifty bit of software that records the
traffic between your program and the outside world by intercepting syscalls.
*rr* then integrates with GDB to allow you to replay a recording (henceforth
referred to as trace) in forward or reverse.  There's a chance *rr* may add too
much overhead to my application and prevent the race condition, but this will be
fantastic if it works.

[rust-forum-post]: https://users.rust-lang.org/t/debugging-advice-for-race-condition-in-database-access-using-futures-and-mysql-async-crates/11201?u=boxofrox

After installing *rr*, creating a trace is simply `rr record <program>`.  It
took a few tries, but I managed to capture a trace with the `PacketOutOrder`
error!

```
# Ouput corresponding to Wireshark capture screenshot.
▶ DSN=mysql://testbot:testbot@192.168.0.162/fake_data RUST_LOG=bug_test_01=debug,mysql_async=debug rr record ./target/release/bug-test-01
...
DEBUG:mysql_async::proto: Last seq id 255
DEBUG:mysql_async::proto: Last seq id 0
DEBUG:mysql_async::proto: Last seq id 1
DEBUG:mysql_async::proto: Last seq id 2
DEBUG:mysql_async::proto: Last seq id 3
DEBUG:mysql_async::proto: Last seq id 101
DEBUG:mysql_async::conn::futures::read_packet: packet out of order.  found 101, expected 3
thread 'main' panicked at 'error resolving future: Error(PacketOutOfOrder, State { next_error: None, backtrace: None })', src/libcore/result.rs:859
```

I still wanted to get ahead of the error before I dive into GDB.  So, after
trying one print statement in a few spots, I settled on this one.

```diff
diff --git a/src/io/mod.rs b/src/io/mod.rs
index 05d7b8b..c55c75c 100644
--- a/src/io/mod.rs
+++ b/src/io/mod.rs
@@ -146,6 +146,7 @@ impl stream::Stream for Stream {
                 new_packet
             },
             ParseResult::Incomplete(mut new_packet, needed) => {
+                debug!("data needs {} bytes", needed);
                 let buf_handle = self.buf.as_mut().unwrap();
                 let buf_len = buf_handle.len();
                 for byte in buf_handle.drain(..cmp::min(needed, buf_len)) {
diff --git a/src/proto.rs b/src/proto.rs
index 109beac..b0321a0 100644
--- a/src/proto.rs
+++ b/src/proto.rs
@@ -304,7 +304,7 @@ impl NewPacket {
             } else {
                 let length = u24_le(&*self.header).unwrap();
                 self.last_seq_id = self.header[3];
-                debug!("Last seq id {}", self.last_seq_id);
+                //debug!("Last seq id {}", self.last_seq_id);
                 self.header.clear();
                 if length == 0 {
                     return ParseResult::Done(Packet { payload: self.data }, self.last_seq_id);
```

Take a quick peek at the output below.  When the SSCCE veers off the track, it
runs through 287 more iterations of the parsing loop before the
`PacketOutOfOrder` error occurs.  That's a whole mess of code I don't have to
step over backwards, and further, I'm now confident I haven't missed some
detail lurking in that mess.  Even better, that `needed` variable jumps over
1000 consistently.  I can set a conditional breakpoint in GDB to stop when
`needed > 1000`.

```
▶ DSN=mysql://testbot:testbot@192.168.0.162/fake_data RUST_LOG=bug_test_01=debug,mysql_async=debug rr record ./target/release/bug-test-01
...hundreds of lines needing < 500 bytes

DEBUG:mysql_async::io: data needs 93 bytes
DEBUG:mysql_async::io: data needs 105 bytes
DEBUG:mysql_async::io: data needs 109 bytes
DEBUG:mysql_async::io: data needs 113 bytes
DEBUG:mysql_async::io: data needs 80 bytes
DEBUG:mysql_async::io: data needs 96 bytes
DEBUG:mysql_async::io: data needs 82 bytes

...and boom!...

DEBUG:mysql_async::io: data needs 3420429 bytes
DEBUG:mysql_async::io: data needs 3350929 bytes
DEBUG:mysql_async::io: data needs 3350929 bytes

...284 lines needing > 1000 bytes, and then a problem is detected...

DEBUG:mysql_async::conn::futures::read_packet: packet out of order.  found 50, expected 93
thread 'main' panicked at 'error resolving future: Error(PacketOutOfOrder, State { next_error: None, backtrace: None })', src/libcore/result.rs:859
```

I want to take a quick moment to point out a detail I missed.  From the start,
I wanted to determine *why the packet out of order error occurs*.  But I failed
to notice here that the answer depends on another question: *why does the
parser read a header with an invalid length field of 3420429 bytes, yet the
same header contains a sequence ID that was not out of order*?  Had I not
missed this detail, I would not later develop suspicions that the Rust
optimizer might contain an obscure bug.


## Enter GDB - Preparation

Now I'm ready fire up GDB.  It's as simple as `rr replay` to open the latest
trace in GDB.  On ArchLinux, *rr* traces are stored in `$HOME/.local/share/rr`
(I have no idea why they aren't in `$HOME/.cache/rr` per the [XDG][xdg] spec).
If you want to open an earlier replay, you can use `rr replay
$HOME/.local/share/rr/<trace dir>` to specify a particular trace.

[xdg]: https://standards.freedesktop.org/basedir-spec/basedir-spec-latest.html

I'm not a fluent reader assembly code, let alone translating assembly back into
Rust.  I wanted GDB to match the assembly with the source code that generated
it.  For that, I must tell GDB where to find my Rust source code and the
*mysql_async* fork I modified.  I'll let the current working folder of my
project establish where that source code can be found.

Let's make sure I have the Rust source code on my machine.

```
▶ rustup component list | grep src
rust-src (installed)
```

If `rust-src` had not appeared, `rustup component add rust-src` will download
and install the Rust source files.  I highly recommend *rustup* if you're not
already using it.

Inside GDB, I updated its search path.

```
GDB> directory /home/boxofrox/.config/rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/
GDB> directory /home/boxofrox/files/development/rust/crates/mysql_async
```

There's one small snag, though.  The debugging info in the application binary
says the Rust source code is under a root folder of `/checkout`.  This is
easily fixed with the `substitute-path` setting.

```
GDB> set substitute-path /checkout/src /src
GDB> show substitute-path
List of all source path substitution rules:
  `/checkout/src' -> `/src'.
```

The last thing I set up was
[gdb-dashboard](https://github.com/cyrus-and/gdb-dashboard).  This amazing
piece of software expands the usability of GDB to new horizons.  Throw in the
[Pygments](http://pygments.org/) python library (`pip install Pygments`), and
GDB starts to rival the fancy IDEs I left behind.

Now with that taken care of, it's time to start debugging.


## Assembly, Out-of-order Execution, and Optimized Variables.  Hoorah.


The area of code I focused on begins with line 149 in `src/io/mod.rs` of
*mysql_async* v0.9.3 as shown below.

```rust
131        let next_packet = match next_packet {
132            ParseResult::Done(packet, seq_id) => {
133                self.next_packet = Some(NewPacket::empty().parse());
134                return Ok(Ready(Some((packet, seq_id))));
135            },
136            ParseResult::NeedHeader(mut new_packet, needed) => {
137                let buf_handle = self.buf.as_mut().unwrap();
138                let buf_len = buf_handle.len();
139                for byte in buf_handle.drain(..cmp::min(needed, buf_len)) {
140                    new_packet.push_header(byte);
141                }
142                if buf_len != 0 {
143                    should_poll = true;
144                }
145
146                new_packet
147            },
148            ParseResult::Incomplete(mut new_packet, needed) => {
149                debug!("data needs {} bytes", needed);
150                let buf_handle = self.buf.as_mut().unwrap();
151                let buf_len = buf_handle.len();
152                for byte in buf_handle.drain(..cmp::min(needed, buf_len)) {
153                    new_packet.push(byte);
154                }
155                if buf_len != 0 {
156                    should_poll = true;
157                }
158
159                new_packet
160            },
161        };
```

The first order of business was to set the conditional breakpoint, run the
program, and break execution on line 149.

```
GDB> breakpoint src/io/mod.rs:149 if needed > 1000
GDB> continue
DEBUG:bug_test_01: running
DEBUG:mysql_async::proto: Last seq id 0
Error in testing breakpoint condition:
value has been optimized out
```

*Value has been optimized out*?!  Curses.  The value that would otherwise have a
permanent residence in some memory location named `needed` with a debug target,
is now a vagrant wandering between CPU registers and the program stack.  This is
one of the hassles I dealt with.  The other was out-of-order execution.
Converting my source code to machine code in the precise order I wrote the code
doesn't maximize the performance of the CPU.  The compiler will rearrange
instructions so long as the behavior of my program doesn't change, and I can
worry more about my source code making sense while the compiler worries about
the performance aspect.

Due to the optimization error, my breakpoint is no longer conditional, but it
still breaks on line 149.  The assembly below is GDB's AT&T-flavored assembly.
Instructions are written as `OPCODE SRC DEST`.  If you prefer Intel-flavored
assembly, there's a setting \[[1]] \[[2]] for that, too.

[1]: http://visualgdb.com/gdbreference/commands/set_disassembly-flavor
[2]: https://sourceware.org/gdb/onlinedocs/gdb/Machine-Code.html

```rust
─── Assembly ──────────────────────────────────────────────────────────────────────
  0x000056066b1aad5c ? ja     0x56066b1aade5 <mysql_async::io::{{impl}}::poll+1557>
  0x000056066b1aad62 ? mov    %r8,%rbx
  0x000056066b1aad65 ? lea    -0x168(%rbp),%rax
> 0x000056066b1aad6c ? mov    %rax,-0x1d0(%rbp)
| 0x000056066b1aad73 ? lea    0xd1306(%rip),%rax        # 0x56066b27c080 <core::fmt::num::{{impl}}::fmt>
| 0x000056066b1aad7a ? mov    %rax,-0x1c8(%rbp)
  0x000056066b1aad81 ? lea    0x364df8(%rip),%rax        # 0x56066b50fb80 <ref.ad>
─── Source ────────────────────────────────────────────────────────────────────────
  144                 }
  145
  146                 new_packet
  147             },
  148             ParseResult::Incomplete(mut new_packet, needed) => {
> 149                 debug!("data needs {} bytes", needed);
  150                 let buf_handle = self.buf.as_mut().unwrap();
  151                 let buf_len = buf_handle.len();
  152                 for byte in buf_handle.drain(..cmp::min(needed, buf_len)) {
  153                     new_packet.push(byte);
  154                 }
```

I have no idea what that assembly is doing.  Evaluating `self`, `self.buf`,
`.as_mut()`, `.unwrap()`?  I'll likely never know and half those possibilities
are probably invalid thanks to Rust's zero-cost abstractions, which I am happy
to have.

But let's not get off track.  I need to find where `needed`'s value is hiding at
this moment in the program.  Around line 149 (o'clock), I should always find it
in the same place.  Let's backtrack to line 148.

```rust
GDB> reverse-next
149                     debug!("data needs {} bytes", needed);
GDB> reverse-next
148                 ParseResult::Incomplete(mut new_packet, needed) => {
─── Assembly ──────────────────────────────────────────────────────────────────────
  0x000056066b1aace4 ? mov    %rcx,-0x40(%rbp)
> 0x000056066b1aace8 ? mov    %r13,-0x100(%rbp)
| 0x000056066b1aace8 ? mov    %r13,-0x100(%rbp)
| 0x000056066b1aacef ? mov    %r12,-0xf8(%rbp)
| 0x000056066b1aacf6 ? mov    %r8,-0xf0(%rbp)
| 0x000056066b1aacfd ? mov    %rbx,-0xe8(%rbp)
| 0x000056066b1aad04 ? mov    -0x58(%rbp),%rax
| 0x000056066b1aad08 ? mov    %rax,-0xe0(%rbp)
| 0x000056066b1aad0f ? mov    -0x68(%rbp),%rax
| 0x000056066b1aad13 ? mov    %rax,-0xd8(%rbp)
| 0x000056066b1aad1a ? movdqa -0x1c0(%rbp),%xmm0
| 0x000056066b1aad22 ? movdqa %xmm0,-0xd0(%rbp)
| 0x000056066b1aad2a ? mov    %r14,-0x168(%rbp)
  0x000056066b1aad31 ? lea    0x38f880(%rip),%rax        # 0x56066b53a5b8 <_ZN3log20MAX_LOG_LEVEL_FILTER17he494f5e9534fe154E>
─── Source ────────────────────────────────────────────────────────────────────────
  144                 }
  145
  146                 new_packet
  147             },
> 148             ParseResult::Incomplete(mut new_packet, needed) => {
  149                 debug!("data needs {} bytes", needed);
  150                 let buf_handle = self.buf.as_mut().unwrap();
  151                 let buf_len = buf_handle.len();
  152                 for byte in buf_handle.drain(..cmp::min(needed, buf_len)) {
  153                     new_packet.push(byte);
  154                 }
```

<div class="o-note">

How cool is that!  With *rr*, you can move forwards or backwards through your
running program on a whim!  GDB provides reverse commands for `continue`,
`next`, `next-instruction`, `step`, and `step-instruction`.

- `reverse-continue` (`rc`)
- `reverse-next` (`rn`)
- `reverse-next-instruction` (`rni`)
- `reverse-step` (`rs`)
- `reverse-step-instruction` (`rsi`)

</div>

Hmmm.  The program counter (PC) jumped backward from 0x---------d6c to
0x---------ce8.  There are quite a few instructions between line 148 and 149.
If I know the first value that `needed` should have, I might be able to read
the registers or stack locations in that assembly and correlate with that first
value.  According to my packet capture, the first MySQL packet received has a
packet length of 1, and that number is just too common to trust.

As luck would have it, *breeden4* and *kmc* on the #rust IRC channel informed
me of `test::black_box(var)`.  A nice bit of Rust black magic that prevents the
optimizer from touching the `var` expression inside.  There is some setup
necessary to use it.

- Must use nightly toolchain.
- Import the *test* crate.  *mysql_async* already provides this behind the
  `features = [ nightly ]` option.
- Add `use test;` at the top of `src/io/mod.rs`.

    ```rust
    #[cfg(feature = "nightly")]
    use test;
    ```

- Rebuild SSCCE with `cargo +nightly build --release`.
- Rerun SSCCE with `rr record` until error manifests.
- `rr replay` to jump into GDB and adjust the settings again. *(I should really
    see about putting the setup in a dot file or something)*

Modifying `src/io/mod.rs` pushed the code down, so the breakpoint now resides at
line 152.  I did have to remove my `debug!` statement so the error would
reappear.

```rust
GDB> breakpoint src/io/mod.rs:152
Breakpoint 1 at 0x562330bbe417: file /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs, line 152.
GDB> continue
Continuing.
warning: Could not load shared library symbols for linux-vdso.so.1.
Do you need "set solib-search-path" or "set sysroot"?
DEBUG:bug_test_01: running

Breakpoint 1, mysql_async::io::{{impl}}::poll (self=0x7f9c58e5c590) at /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs:153
153                     let buf_handle = self.buf.as_mut().unwrap();
```

Huh.  I wonder why it stopped at line 153.  The breakpoint must stop after the
line executes.  That's convenient when I want to see the effect of that line of
code.  Not so much now.

```rust
GDB> reverse-next
152                     test::black_box(&needed);
─── Assembly ──────────────────────────────────────────────────────────────────────
  0x0000562330bbe39b ? mov    %r13,0xc0(%rsp)       // line 151
  0x0000562330bbe3a3 ? mov    %rbx,0xc8(%rsp)
  0x0000562330bbe3ab ? mov    %r10,0xd0(%rsp)
  0x0000562330bbe3b3 ? mov    %r12,0xd8(%rsp)
  0x0000562330bbe3bb ? mov    0x38(%rsp),%rax
  0x0000562330bbe3c0 ? mov    %rax,0xe0(%rsp)
  0x0000562330bbe3c8 ? mov    0x40(%rsp),%rax
  0x0000562330bbe3cd ? mov    %rax,0xe8(%rsp)
  0x0000562330bbe3d5 ? movdqa 0x190(%rsp),%xmm0
  0x0000562330bbe3de ? movdqa %xmm0,0xf0(%rsp)
  0x0000562330bbe3e7 ? mov    %r14,0x148(%rsp)
  0x0000562330bbe3ef ? lea    0x148(%rsp),%rax      // $rsp+0x148 holds needed
> 0x0000562330bbe3f7 ? mov    %rax,0x200(%rsp)      // test::black_box()
| 0x0000562330bbe3ff ? lea    0x200(%rsp),%rax      // rax is never used
  0x0000562330bbe407 ? mov    0xb0(%r15),%r12
  0x0000562330bbe40e ? test   %r12,%r12
  0x0000562330bbe411 ? je     0x562330bbea65 <mysql_async::io::{{impl}}::poll+3781>
  0x0000562330bbe417 ? lea    0xa0(%r15),%rax       // rax overwritten here
─── Source ────────────────────────────────────────────────────────────────────────
  150             },
  151             ParseResult::Incomplete(mut new_packet, needed) => {
> 152                 test::black_box(&needed);
  153                 let buf_handle = self.buf.as_mut().unwrap();
  154                 let buf_len = buf_handle.len();
  155                 for byte in buf_handle.drain(..cmp::min(needed, buf_len)) {
  156                     new_packet.push(byte);
  157                 }
```

And here we are.  If I run `GDB> x/gu $rax`, GDB will show me the 64-bit
unsigned value in that memory location.  That is `needed`.  `$rax` won't help me
when it changes on line 153, so I'll use `$rsp + 0x148` instead.  Now let's set
that breakpoint!  Bear with me, we're going to visit all my mistakes.  Someone
may actually learn something from these examples.

**Strike One**

```rust
GDB> disable 1
GDB> breakpoint src/io/mod.rs:152 if *($rsp + 0x148) > 1000
Note: breakpoint 1 (disabled) also set at pc 0x562330bbe417.
Breakpoint 2 at 0x562330bbe417: file /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs, line 152.
GDB> continue
Continuing.
Error in testing breakpoint condition:
Attempt to dereference a generic pointer.

Breakpoint 2, mysql_async::io::{{impl}}::poll (self=0x7f9c58e5c988) at /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs:153
153                     let buf_handle = self.buf.as_mut().unwrap();
```

*Attempt to dereference a generic pointer.*  Hmmm.  Guess I need to cast that.
Let's fall back to my old C programming days and make that happen.


**Strike Two**

```rust
// get rid of the invalid breakpiong
GDB> delete 2
GDB> break src/io/mod.rs:152 if *((unsigned long *)($rsp + 0x148)) > 1000
syntax error in expression, near `long *)($rsp + 0x148)) > 1000'.
```

Wait, what?  How does GDB not recognize C syntax??? You mileage will vary here.
I asked on #rust, #archliux, #gdb, and #rr and the syntax worked for some and
not others.  But ultimately, it doesn't work because GDB can parse many
languages and knows it's working with Rust source code.  Rust syntax casting
will work.

**Home Run**

```rust
GDB> breakpoint src/io/mod.rs:152 if *(($rsp + 0x148) as &usize) > 1000
Note: breakpoints 1 (disabled) also set at pc 0x562330bbe417.
Breakpoint 3 at 0x562330bbe417: file /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs, line 152.
GDB> continue
Continuing.

Breakpoint 3, mysql_async::io::{{impl}}::poll (self=0x7ffcdf688fa8) at /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs:153
153                     let buf_handle = self.buf.as_mut().unwrap();
GDB> x/gu $rsp + 0x148
0x7ffcdf666688: 6698509
```

<div class="o-note is-pro-tip">

The memory at `$rsp + 0x148` was loaded with the value in `$r14`.  I could have
avoided the issues with casting by using `if $r14 > 1000`, but I felt that
stack memory would be less transient than the registers and more reliable.

</div>

The program has stopped and it looks like `needed` is 6698509.  Seems a bit high
compared to the numbers I looked at before.   How can I be sure I didn't make a
mistake and stumble upon a garbage value?  Let's enable breakpoint 1 and stop at
line 152 on the previous execution.  There should be a reasonable value there if
I have indeed found `needed`.

```rust
GDB> enable 1
GDB> reverse-continue
Continuing.

Breakpoint 1, mysql_async::io::{{impl}}::poll (self=0x7ffcdf688fa8) at /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs:153
153                     let buf_handle = self.buf.as_mut().unwrap();
GDB> x/gu $rsp + 0x148
0x7ffcdf666688: 63
```

And 63 is very reasonable.  Looks like I arrived at the correct position in the
program.  I reversed a couple more times; found 62, 61, and 60 as expected;
then continued forward to breakpoint 1 when `needed` was 63.

From here, I want to step through the program as it parses the bad packet.
Where does that start in the code?  Here is the relevant code in its entirety
with my notes.

```rust
//> src/io/mod.rs
101     fn poll(&mut self) -> Poll<Option<(Packet, u8)>, Error> {
102         // should read everything from self.endpoint
103         let mut would_block = false;
104         if !self.closed {
105             let mut buf = [0u8; 4096];
// Read as many bytes as possible from the network socket
106             loop {
107                 match self.endpoint.as_mut().unwrap().read(&mut buf[..]) {
108                     Ok(0) => {
// Nothing more to read
109                         break;
110                     },
111                     Ok(size) => {
// Any bytes read are put in long-term storage (relative to lifetime of a local
// variable buffer)
112                         let buf_handle = self.buf.as_mut().unwrap();
113                         buf_handle.extend(&buf[..size]);
114                     },
115                     Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
// Nothing more to read.  Let the program keep running instead of blocking.  Yay async.
116                         would_block = true;
117                         break;
118                     },
119                     Err(error) => {
120                         self.closed = true;
121                         return Err(Error::from(error));
122                     },
123                 };
124             }
125         } else {
126             return Ok(Ready(None));
127         }
128
129         // need to call again if there is a data in self.buf
130         // or data was written to packet parser
131         let mut should_poll = false;
132

// Regardless whether bytes were read from the network, always try to move
// parsing further.  There may be some bytes in long-term storage left to use.
// Pick up where the parsing left off last time.  This establishes a state
// machine when parsing is interrupted by lack of data from the network.
133         let next_packet = self.next_packet.take().expect("Stream.next_packet should not be None");

// Either finish a packet, or copy bytes from long-term storage into `next_packet`.
134         let next_packet = match next_packet {
135             ParseResult::Done(packet, seq_id) => {
// Packet is complete.  Set up to parse the next packet before returning the completed packet.
136                 self.next_packet = Some(NewPacket::empty().parse());
137                 return Ok(Ready(Some((packet, seq_id))));
138             },
139             ParseResult::NeedHeader(mut new_packet, needed) => {
// Parsing the header is in progress.  `needed` tells us how many more bytes are
// needed to finish the header.  It's never much as the header is four bytes in
// size.
140                 let buf_handle = self.buf.as_mut().unwrap();
141                 let buf_len = buf_handle.len();
// Copy the needed bytes from long-term storage, or what's available if supply
// is short.
142                 for byte in buf_handle.drain(..cmp::min(needed, buf_len)) {
143                     new_packet.push_header(byte);
144                 }
145                 if buf_len != 0 {
// Plan to recurse `poll()` if there are more bytes in long-term storage.
146                     should_poll = true;
147                 }
148
149                 new_packet
150             },
151             ParseResult::Incomplete(mut new_packet, needed) => {
// Collecting the data determined by the length field in the header.
// `needed` tells us how many more bytes are needed.
152                 test::black_box(&needed);
153                 let buf_handle = self.buf.as_mut().unwrap();
154                 let buf_len = buf_handle.len();
155                 for byte in buf_handle.drain(..cmp::min(needed, buf_len)) {
156                     new_packet.push(byte);
157                 }
158                 if buf_len != 0 {
// Plan to recurse `poll()` if there are more bytes in long-term storage.
159                     should_poll = true;
160                 }
161
162                 new_packet
163             },
164         };
165
// Regardless whether bytes were copied into `next_packet`, try to parse any
// bytes that were copied and arrange for the next loop iteration to pick up where
// this leaves off.  `parse()` source code provided below.
166         self.next_packet = Some(next_packet.parse());
167
// Recurse if planned, or there's a possibility to read more bytes from the
// network socket.
168         if should_poll || !would_block {
169             self.poll()
170         } else {
171             Ok(NotReady)
172         }

//> /src/proto.rs
271 #[derive(Debug)]
272 pub struct NewPacket {
273     data: Vec<u8>,
274     length: usize,
275     header: Vec<u8>,
276     last_seq_id: u8,
277 }
278
279 impl NewPacket {
...
298     pub fn parse(mut self) -> ParseResult {
// No idea what this does.  If more data exists than MAX_PAYLOAD_LEN, is it
// discarded?
299         let last_packet_part = self.data.len() % consts::MAX_PAYLOAD_LEN;
300         if last_packet_part == 0 {
// No data exists, run through the parsing checklist.
// Do we have all the bytes for the header?
301             if self.header.len() != 4 {
302                 let needed = 4 - self.header.len();
// Plan to parse the header when all bytes are available.
303                 return ParseResult::NeedHeader(self, needed);
304             } else {
// All the bytes for the header arrived.  Decompose into packet length and
// sequence ID.
305                 let length = u24_le(&*self.header).unwrap();
306                 self.last_seq_id = self.header[3];
307                 //debug!("Last seq id {}", self.last_seq_id);
308                 self.header.clear();
309                 if length == 0 {
// Plan to complete packet on the next iteration.
310                     return ParseResult::Done(Packet { payload: self.data }, self.last_seq_id);
311                 } else {
312                     self.length = length as usize;
// Plan to read more bytes for data on the next iteration.
313                     return ParseResult::Incomplete(self, length as usize);
314                 }
315             }
316         } else {
// Fast path?  Waiting for all the data bytes to arrive.
317             if last_packet_part == self.length {
318                 return ParseResult::Done(Packet { payload: self.data }, self.last_seq_id);
319             } else {
320                 let length = self.length;
321                 return ParseResult::Incomplete(self, length - last_packet_part);
322             }
323         }
324     }
325 }
```

So here's my plan.

1.  Jump forward to `src/io/mod.rs:140` when the broken packet starts getting
    parsed, then
2.  Jump backward to the top of the `poll` function.
3.  Observe how many bytes are going into long-term storage `self.buf`, and
4.  Observe how many bytes are available in `self.buf`, after reading from the
    network stops.
5.  Observe how many bytes are copied into `next_packet`.  Maybe also verify
    that the bytes read from `self.buf` were written to `next_packet` instead
    of garbage.
6.  Observe the behavior and result of `next_packet.parse()`.
7.  Repeat 3-6 until anomaly is found.

The first two steps are simple enough.

```rust
GDB> breakpoint src/io/mod.rs:140
Breakpoint 4 at 0x562330bbe10f: file /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs, line 140.
GDB> continue
Continuing.

Breakpoint 4, mysql_async::io::{{impl}}::poll (self=0x7ffcdf688fa8) at /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs:140
140                     let buf_handle = self.buf.as_mut().unwrap();
GDB> breakpoint src/io/mod.rs:101
Breakpoint 5 at 0x562330bbdbbb: file /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs, line 101.
GDB> reverse-continue
Continuing.

Breakpoint 5, mysql_async::io::{{impl}}::poll (self=0x7ffcdf688fa8) at /home/boxofrox/files/development/rust/crates/mysql_async/src/io/mod.rs:104
104             if !self.closed {
```

The remaining steps require quite a bit of work.  Not only are the variables
optimized away, but they are complex types (i.e. structs).  Rust [RFC
79](https://github.com/rust-lang/rfcs/blob/master/text/0079-undefined-struct-layout.md)
intentionally leaves memory layout unspecified for structs and enums for
optimizations.  In [Rust
1.18](https://blog.rust-lang.org/2017/06/08/Rust-1.18.html), the reorder
optimization went live.  I spent quite a bit of time trying to figure out how to
identity what memory layout the compiler used.  Turns out, `rustc -Z
print-type-sizes` will print the memory layout as well as the sizes.  There's
quite a bit of information to sift through, so I ran the following to dump all
the information relevant to the SSCCE into a file I could search.

```bash
RUSTFLAGS="-Z print-type-sizes" cargo +nightly build --release > /tmp/boxofrox/type-sizes.txt
```

Also turns out, that memory layout is only useful when a struct is kept in
memory (like in a unoptimized variable), which isn't the case here.  LLVM will
tear structs apart to optimize the fields individually.  Great for performance.
Not so great for debugging.

So what does one do in this situation?  `test::black_box()` would work if I
weren't pushing the limits with my first use of it.  Add more and the error no
longer occurs.  Stack offsets (e.g. `$rsp + 0x148`) seem to vary wildly from
build to build, so I can't move `test::black_box()` around to identify each
field at a time.

I adopted another technique I would call a choke-point method.  Basically, I
paw through the code looking for simple expressions that use or assign to the
variable I'm interested in, then cross my fingers and pray that expression
wasn't optimized away.

<div class="o-note is-note">

An rvalue assignment is only a viable choke point when backtracking through the
code.  The compiler doesn't care where a value was stored on the stack earlier
and may assign the value to a new stack location.  So finding an rvalue
assignment after your "instruction of interest" may present you with the wrong
stack location.

</div>

So how did I apply this method?  Recall that I wanted to observe the number of
bytes in `self.buf` as step 3 of my plan.  First, I characterize the variable
type so I know what part(s) I'm looking for.  `self.buf` is a
`std::collections::VecDeque<u8>`, which is composed of other types. After
digging through the rust source a bit, it breaks down into:

```plaintext
            ⎧ tail : usize
VecDeque<T> ⎨ head : usize     ⎧ ptr : Unique<T>    { pointer : NonZero<*const T>
            ⎩ buf  : RawVec<T> ⎨ cap : usize
                               ⎩ a   : Alloc = Heap
```

Or more simply:

```plaintext
            ⎧ tail : usize
VecDeque<T> ⎨ head : usize
            ⎪ ptr  : *T
            ⎩ cap  : usize
```

In the snippet below, line 112 looks like it would simplify to one or two
instructions and provide a starting address for `self.buf`, but `buf_handle` is
a temporary variable and was optimized away.  Line 113 references two
variables, so I don't know exactly which assembly opcodes pertain to which
variable.  Instead, I tried drilling down into that call to `VecDeque::extend`
since it receives `self.buf` and interacts with the `VecDeque` data.

```rust
112                         let buf_handle = self.buf.as_mut().unwrap();
113                         buf_handle.extend(&buf[..size]);
```

Eventually, I ran into the private function `VecDeque::is_full()`:

```rust
─── Assembly ──────────────────────────────────────────────────────────────────────
  0x0000562330bbdc75 ? mov    0xa8(%r15),%rdx
  0x0000562330bbdc7c ? mov    0xb8(%r15),%rbx
  0x0000562330bbdc83 ? mov    %rdx,%rax
  0x0000562330bbdc86 ? sub    0xa0(%r15),%rax
  0x0000562330bbdc8d ? lea    -0x1(%rbx),%rcx
  0x0000562330bbdc91 ? and    %rax,%rcx
> 0x0000562330bbdc94 ? mov    %rbx,%rax
| 0x0000562330bbdc97 ? sub    %rcx,%rax
  0x0000562330bbdc9a ? cmp    $0x1,%rax
─── Source ────────────────────────────────────────────────────────────────────────
  139     /// Returns `true` if and only if the buffer is at full capacity.
  140     #[inline]
  141     fn is_full(&self) -> bool {
> 142         self.cap() - self.len() == 1
  143     }
  ...
  791     #[stable(feature = "rust1", since = "1.0.0")]
  792     pub fn len(&self) -> usize {
  793         count(self.tail, self.head, self.cap())
  794     }
─── Registers ─────────────────────────────────────────────────────────────────────
  rax 0x0000000000000000       rbx 0x0000000000080000       rcx 0x0000000000000000       rdx 0x0000000000000000
  rsi 0x00007ffcdf6679a0       rdi 0x0000000000000006       rbp 0x00007ffcdf668a00       rsp 0x00007ffcdf6677a0
   r8 0x0000000000000000        r9 0x0000000000000000       r10 0x0000000000000000       r11 0x000000000000002d
  r12 0x00007ffcdf6679a0       r13 0x0000000000001000       r14 0x000000000000000d       r15 0x00007ffcdf688fa8
  rip 0x0000562330bbdc94    eflags [ PF ZF IF ]
```

According to this assembly, `$rax - $rcx` is equivalent to `self.cap() -
self.len()`.  Tracing backward, I found that `$r15 + 0xb8` holds `self.cap()` at
address `0x77ffcdf688fa8 + 0xb8` and `self.len()` is computed from `self.head -
self.tail`, and that correlates to `($r15 + 0xa8) - ($r15 + 0xa0)` in the
assembly above.  If I look at a hex-dump of the 32 bytes at the `$r15 + 0xa0`
address, I find a layout similar to the `VecDeque` characterization I created
earlier.

```
─── Memory ──────────────────────────────────────────────────────────────────────────
0x00007ffcdf689048 00 00 00 00 00 00 00 00   00 00 00 00 00 00 00 00 ................
                   tail                      head

0x00007ffcdf689058 00 61 f0 58 9c 7f 00 00   00 00 08 00 00 00 00 00 .a.X............
                   ptr ??                    cap
```

At this point, I wasn't sure I found `ptr`, but since the code is in the
process of extending an empty (`head = tail = 0`) `VecDeque` with bytes, I can
watch the 0x80000 bytes at `0x7f9c58f06100` and see that they fill with bytes
as I step through the rest of the process.  I also noted that `ptr` is subject
to change when the buffer grows, so whenever I wanted to watch the memory for
`self.buf`, I had to keep track of when `ptr` changed.

With this method in hand, I ran through my plan, paraphrasing each line of code
until I had a story that made sense up until the glitch occurred.


## A Story of an Anomaly in the Machine


At the time the application flakes out, the *mysql_async* library has read the
**last four bytes** retrieved from the `tokio_core::net::TcpStream` into an
**empty** intermediate data structure `mysql_async::proto::NewPacket`, called
`new_packet`, that is used to parse one MySQL packet as bytes become available.
These last four bytes are the 4-byte header of the next MySQL packet to parse
and they are copied into the `new_packet.header`, a `std::vec::Vec` (assertion
`new_packet.header.len() == 4`), then decomposed into an 8-bit sequence ID and
a 24-bit unsigned length.

Now that the MySQL header is read, the length indicates that 115 more bytes of
data are needed to complete the packet. Since there are no more bytes to
process, another attempt to read from `TcpStream` commences, and fails with
`Err(WouldBlock)`, at which point the *mysql_async* library schedules a future
read, then tries to reparse `new_packet` **just one more time** in case some
bytes had been read.

The `new_packet.parse()` function (in `src/proto.rs` line 298) is a state
machine transitioner that checks the current state, and with its return value,
schedules where the next bytes read from the `TcpStream` shall go when put into
`new_packet`. The program already pulled four bytes for the header, the buffer
was empty, and there are no more bytes to be had at this point. When the parse
function checks to see if the header has all its bytes, it's here that the
register--that represents `new_packet.header.len()`--contains 0x00 instead of
0x04. The code erroneously returns a `ParseResult::NeedHeader` instead of
`ParseResult::IncompleteData`, which corrupts further reading of the
`TcpStream`.

Anomaly is found.  And, damn, does the program have to run fast to trigger it.


## The Fix I Had Not Found


By the time I got this far, I had spent hours over three weeks digging through
the program and was so burnt out I couldn't see the forest through the trees.

Before I could spend hours more working backwards from the anomaly trying to
understand why that register for `new_packet.header.len()` reset to zero,
*@inejge* pointed out the culprit for me \[[4]] and saved the day.  Turns out,
line 308 in `src/proto.rs` was clearing out the contents of the
`new_packet.header` vector.

[4]: https://github.com/rust-lang/rust/issues/42610#issuecomment-309295576

```rust
// src/proto.rs
307                 //debug!("Last seq id {}", self.last_seq_id);
308                 self.header.clear();
309                 if length == 0 {
```

Oh, let me count the number of times I looked at that line of code as I stepped
through the program again and again, teasing out stack locations for optimized
variables, and not once did my mind register that line even existed.

I submitted a [pull request][pr-11] to remove line 308, which was accepted and
*mysql_async* runs all the better for it.

[pr-11]: https://github.com/blackbeam/mysql_async/pull/11


## Some Lessons Learned and Other Wisdom

1.  Attention to detail is key.
2.  Analyze from different perspectives to correlate results and verify
    conclusions are accurate.
3.  Never underestimate the utility of a second [or third] pair of eyes.
4.  Always question your assumptions, sometimes when you think you got them
    right, they're wrong.
5.  Keep your anger and frustration in check.  When asking for assistance, a
    negative tone is less inviting to a volunteer.  It's easy to misdirect
    anger at the person trying to help, and volunteers neither want nor deserve
    that.  Make an effort, at the very least, to keep a neutral tone.
6.  You can't share a *rr* trace with others.  It's tied directly to your
    hardware and OS, due to the syscall recording.  Efforts are underway to
    lift this limitation, though.
7.  Just because you're programming with Rust doesn't mean your code won't
    suffer from wierd behavior.


## Conclusion

This bug was a great opportunity to learn the grittier side of debugging.  The
unfortunate aspect was that stumbling over the "things I didn't know" was a
huge time sink when I could barely afford it.  The next time I run into a
similar problem, I'll be better equipped to handle the case.

Many thanks to @inejge, @Mark-Simulacrum for their assistance troubleshooting
this bug.  I offered @inejge a tip for a cup of coffee (or some such) for
finding the solution.  Instead he asked that I write this blog post.  You can
thank him for all this 😜.

My thanks also goes out to all the Rust devs and community, Tokio devs, and
especially @blackbeam for his work maintaining *mysql_async*.
