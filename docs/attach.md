# Attaching pickglass to a node

Pickglass inspects a running BEAM node (an Erlang, Elixir or Gleam program)
from outside it. This page explains what that needs, how to start your
program so pickglass can reach it, and what to watch for on the security side.
It assumes you have not used distributed Erlang before.

Checked against OTP 29 (the `erl` and `epmd` manual pages and the
`proc_lib`, `erts_alloc` and `kernel` references on erlang.org) and Elixir
1.20.4 (the `mix release` and `IEx` documentation on hexdocs.pm). Items that
could not be checked on this machine are marked "not re-verified" below.

## The short version

```sh
# Start any node with a name and a cookie file (details below).
erl -name app@127.0.0.1

# Attach, print one report, and detach.
pickglass attach --node app@127.0.0.1

# Or serve the web pages and print a one-time URL.
pickglass open --node app@127.0.0.1
```

Without `--cookie-file`, pickglass reads the cookie from `~/.erlang.cookie`,
which is where `erl` puts it for a node started under your user.

## Profiling in one step

A flame graph is one click in the pages and one command in a terminal.

In the pages, Owners, Overview, Processes and Process each have a profile
button: "Profile" on an owner row, "Profile the busiest 16", and "Profile this
process". The button pins the processes it needs and plans one stack probe over
them, and the plan appears above the page, stating the processes, how they were
chosen (for example "12 of 31 listed processes of session:abc, the busiest by
reductions/s"), the rate, the duration and the sample budget. Nothing runs
until you confirm. The plan card has buttons for another duration and rate.
When the probe ends the page shows a link to the Profile page; the page cannot
move your browser itself, so you follow the link. The pins the button took are
released when the probe ends, the plan is cancelled or it lapses; a process you
had pinned yourself stays pinned.

From a terminal:

```sh
pickglass profile --node app@127.0.0.1 --owner session:abc --seconds 10
pickglass profile --state-dir ~/.loom --top 8 --format text
pickglass profile --node app@127.0.0.1 --pid-text '<0.123.0>' --out p.json
```

`--owner` takes `unknown`, `kind:id`, or a path such as
`session:abc/strand:def`. `--top N` takes the N busiest processes by reductions
per second (at most 16, the agent's limit for one stack probe). `--format` is
`speedscope` (the default, which opens at speedscope.app), `collapsed`,
`chrome`, `pgcap` (a capture holding the profile) or `text` (the top functions
and an indented call tree, printed). The command goes through the same plan,
confirm and audit path as the pages, as the local owner, and prints the top 15
functions, the coverage and the caveats. Samples are taken at reduction safe
points, so time in long BIFs and NIFs is under-counted. A failure prints one
line, `profile failed (code): reason`, and exits non-zero.

By default only the samples taken while a process was running or runnable are
counted, because on an idle node most samples find processes waiting in
`receive` and the heaviest functions would be the waits. The summary says how
the whole set split ("3,008 samples: 412 running/runnable, 2,596 waiting"), and
`--include-waiting` counts all of them. If no sample caught a process running,
the command says every process was waiting and writes no file; the Profile page
does the same and offers the waiting samples with one button.

To trace calls instead, name the modules: `pickglass profile --node app@127.0.0.1
--top 3 --trace-calls --module my_app --seconds 5`. The agent traces calls to
the named modules in at most four processes for at most ten seconds, stops at
100,000 events or when its collector falls behind, and says so. The result is a
call tree with exact call counts and times (exclusive time is what the views
draw). Tracing every function, or a module every process calls such as `lists`,
is refused. On the pages the same probes are planned from Probes, the Process
page ("Trace calls…", "Record scheduling…"), a profile plan card ("Trace calls
instead") and owner rows ("Record"). A recording draws each traced process's
runs and garbage collections on the Timeline page with per-process totals;
both probes export as Chrome traces.

## What a distributed node is

A BEAM node can talk to other nodes: send them messages, call functions on
them, load code into them. This is called distribution, and every tool that
inspects a running node from outside (`observer`, `rpc`, remote shells) uses
it. Pickglass does too: it starts its own small, hidden node, connects to
yours, loads its agent into your node, and asks the agent for readings. When
it detaches, the agent unloads itself.

Four things have to line up for a connection.

**The node name.** A node is distributed only if it was started with a name.
The name has the form `NAME@HOST`, such as `app@127.0.0.1`. A node started
with no name cannot be attached to.

**Long and short names.** There are two naming modes, and the two cannot talk
to each other.

- `-name app@127.0.0.1` starts a node with a long name. The host part is an IP
  address or a fully qualified host name, so it contains a dot (or a colon for
  IPv6).
- `-sname app` starts a node with a short name. The host part is the
  machine's short host name, without dots, and is added for you. On a machine
  called `mybox` the full name is `app@mybox`.

Pickglass picks its own mode from the shape of the host in `--node`: a host
with a dot or a colon is a long name, a bare word is a short name. The one
case that goes wrong is `-name app@localhost`: `localhost` has no dot, so
pickglass takes it for a short name. Name that node `app@127.0.0.1` instead,
or start it with `-sname`. When the mode is wrong, pickglass says so and gives
the name it reached the node under.

**epmd.** The Erlang Port Mapper Daemon is a small program that runs on each
machine, listens on TCP port 4369, and keeps a list of the node names on that
machine and the ports they listen on. A node registers with it when it starts
(`erl` starts epmd if it is not running), and a connecting node asks it which
port to use. `epmd -names` prints the list, which is the quickest way to see
whether your node is up and what it is called.

**The cookie.** A cookie is a shared secret: a node accepts a connection only
from a node that presents the same cookie. Treat it as full trust. A node
that holds your cookie can run any code on your node, read its memory and
stop it. By default, `erl` creates `~/.erlang.cookie` with a random value the
first time it starts a distributed node, and reads it afterward. Pickglass
makes no stronger claim than the cookie does: anyone who can read the file
can control the node.

## How pickglass finds the cookie

Pickglass reads the cookie from a file and from nowhere else.

- `--cookie-file PATH` names the file.
- With no `--cookie-file`, the file is `~/.erlang.cookie`.
- The file must be readable by its owner alone (mode `0600` or `0400`).
  Pickglass refuses a file that group or others can read, and says so.

There is no `--cookie` option, and pickglass does not read an environment
variable. A command-line argument is visible to every local user in the
process table and is stored in your shell history, and the environment of a
process is readable by the same users on many systems. `pickglass attach
--cookie ...`, `--cookie=...` and `--setcookie ...` are refused with a
message that points at `--cookie-file`.

Pickglass never creates `~/.erlang.cookie`, and its own VM starts with no
cookie of its own. The cookie it reads is set for your node only.

## Which targets are allowed

For now pickglass attaches to nodes on the same machine only. The host in
`--node` must be `127.0.0.1`, `::1`, `localhost`, or this machine's own host
name. Any other host is refused with a message. The check is one function
(`check_loopback` in the `endpoint` module), so it can be relaxed later. Note
that `::1` passes the check but needs both nodes to run IPv6 distribution
(`-proto_dist inet6_tcp`), which pickglass does not set up; not re-verified.

## Starting a node so pickglass can attach

### Plain Erlang

The simplest form:

```sh
erl -name app@127.0.0.1
```

This creates `~/.erlang.cookie` if it does not exist, and pickglass will find
it. To use a particular cookie, prefer a file over `-setcookie`:

```sh
mkdir -p /path/to/homedir
(umask 077; head -c 24 /dev/urandom | base64 | tr -d '/+=\n' > /path/to/homedir/.erlang.cookie)
HOME=/path/to/homedir erl -name app@127.0.0.1    # reads $HOME/.erlang.cookie
pickglass attach --node app@127.0.0.1 --cookie-file /path/to/homedir/.erlang.cookie
```

`erl -setcookie VALUE` works, but `VALUE` is then in the process table for as
long as the node runs. `erl -nocookie` starts a node with no cookie and no
cookie file read; it cannot be attached to by cookie. For a short name use
`erl -sname app` and `--node app@$(hostname -s)`.

### Elixir

For `iex` or a script:

```sh
iex --name app@127.0.0.1     # long name
iex --sname app              # short name
```

`--sname` is in the IEx documentation (v1.20.4). `--name` and the cookie file
behavior follow the `erl` flags that `iex` passes through; not re-verified
here, since Elixir is not installed on the machine this page was written on.

For a release built with `mix release`, distribution is controlled by
environment variables read by the release script:

- `RELEASE_DISTRIBUTION` is `name` (long names), `sname` (short names) or
  `none`. The default is short names.
- `RELEASE_NODE` is the node name: `app` alone, or `app@127.0.0.1`. The name
  may contain letters, digits, underscores and hyphens.
- `RELEASE_COOKIE` sets the cookie. Without it the release writes a random
  cookie to `releases/COOKIE` on first start and reuses it.

```sh
RELEASE_DISTRIBUTION=name RELEASE_NODE=app@127.0.0.1 bin/app start
pickglass attach --node app@127.0.0.1 --cookie-file releases/COOKIE
```

Use the `releases/COOKIE` file, with owner-only permissions, in preference to
`RELEASE_COOKIE`: an environment variable is readable by other local users on
many systems, and pickglass will not take it from there anyway. Permanent
settings go in `rel/env.sh.eex` and `rel/vm.args.eex`.

### Gleam

A Gleam program is an ordinary Erlang application. The `erlang-shipment`
export ships a start script that runs `erl`, and `erl` appends the contents of
`ERL_FLAGS` to its command line:

```sh
ERL_FLAGS="-name app@127.0.0.1" ./build/erlang-shipment/entrypoint.sh run
```

The cookie rules are Erlang's: `~/.erlang.cookie` by default. The `ERL_FLAGS`
behavior is from the `erl` manual page; a shipment run was not exercised for
this page.

### What the target needs

OTP 28 or newer, and nothing else installed. Pickglass refuses an older
node with a message. It loads its agent into the node at attach time, and
unloads it at detach; if pickglass is killed, the agent notices within about
30 seconds and removes what it set up.

Two optional features improve what you see:

- `runtime_tools`. Allocator carrier data comes from the `instrument` module in
  the `runtime_tools` application, which a release must include. Without it
  the node cannot report that data.
- `+Muatags true`. This is an `erl` flag. It adds a small tag to each block
  the allocators hand out, saying what it is and who allocated it, at a cost
  of two words per allocation. It enables per-process allocation tags. In a
  release put it in `vm.args`, or pass it through `ERL_FLAGS="+Muatags true"`.
  Per-process tag readings were not exercised in the live checks for this
  page.

## Telling pickglass who owns a process

Pickglass groups processes by owner, such as a session, a request handler or a
cache. It reads the owner from the process's label (`proc_lib:set_label/1`,
OTP 27 and newer; Elixir's `Process.set_label/1` is the same since 1.17). The
convention is one tuple:

```erlang
{pickglass_owner, 1, Path, Role}
```

`Path` is a list of `{Kind, Id}` pairs of binaries, from the outermost owner
to the innermost, and `Role` is a binary. A label of any other shape, or no
label, is counted as unknown. Labels are bounded: at most 8 path elements,
printable ASCII, and 128 bytes per text. A label that fails any check is
ignored whole.

A label belongs to one process and is not inherited by processes it spawns, so
each process sets its own as its first step.

Erlang:

```erlang
init([SessionId]) ->
    proc_lib:set_label({pickglass_owner, 1,
                        [{<<"session">>, SessionId}], <<"worker">>}),
    {ok, #{}}.
```

Elixir:

```elixir
def init(session_id) do
  :proc_lib.set_label({:pickglass_owner, 1, [{"session", session_id}], "worker"})
  {:ok, %{}}
end
```

Gleam (a small external, since the Gleam standard library does not wrap it):

```gleam
@external(erlang, "proc_lib", "set_label")
fn set_label(label: #(Atom, Int, List(#(String, String)), String)) -> Nil

pub fn claim(session_id: String) -> Nil {
  set_label(#(owner_tag(), 1, [#("session", session_id)], "worker"))
}

// The atom `pickglass_owner`, made once from its name.
fn owner_tag() -> Atom {
  atom.create("pickglass_owner")
}
```

(`Atom` and `atom.create` are from `gleam/erlang/atom`.)

### Self-measurement

A process that holds a large term cannot be measured from outside without
copying it. A process can instead measure itself. It says so by adding a fifth
element to its label, a list of capability binaries:

```erlang
proc_lib:set_label({pickglass_owner, 1, [{<<"cache">>, <<"main">>}],
                    <<"store">>, [<<"measure">>]})
```

When you ask pickglass to measure that process, the agent sends it
`{pickglass_measure, BudgetMs, ReplyTo, Ref}`, and the process answers
`ReplyTo ! {pickglass_measure_reply, Ref, [{Name, Value, Unit}]}`, where
`Unit` is `<<"words">>`, `<<"bytes">>` or `<<"count">>`. At most 32 readings
are kept, and a malformed reply is refused whole. Only a process that
advertises `<<"measure">>` is ever asked.

## Security notes

- The cookie is full trust, as above. Keep it in a file with owner-only
  permissions and do not put it in argv, a shell history line, an environment
  variable, a log, or a container image.
- The node listens for distribution connections on a port that epmd hands out.
  With no setting it listens on every network interface, so another machine
  can try to connect (and would still need the cookie). Bind it to loopback
  with the `kernel` parameter `inet_dist_use_interface`, an IP address given
  in Erlang tuple form:

  ```sh
  erl -name app@127.0.0.1 -kernel inet_dist_use_interface '{127,0,0,1}'
  ```

  In a release put the same flags in `vm.args`, or in `ERL_FLAGS`.
- epmd listens on all interfaces by default as well (on this machine, `lsof`
  shows it on `*:4369`). Set `ERL_EPMD_ADDRESS=127.0.0.1` in the environment
  of whatever starts epmd. The `erl` documentation says epmd then listens only
  on the given addresses and the loopback address. It takes effect only for
  an epmd that has not started yet, so stop a running one first (`epmd -kill`
  stops it when no nodes are registered). The loopback binding was not
  exercised in the live checks for this page, because the machine's epmd was
  in use by other programs.
- The pickglass viewer opens no listening port for distribution. It joins as a
  hidden node, so it does not appear in `nodes()` for ordinary tools.
- Attaching loads code into the target, so only attach to a node you are
  allowed to run code on.

## When attaching fails

Each failure has one message.

| Message | Cause |
| --- | --- |
| `NODE is not running, or is not registered with epmd` | `epmd -names` does not list the name. The node is down, was started without `-name`/`-sname`, or the name is misspelled. |
| `NODE refused the connection: its cookie differs` | The node is registered and reachable, and the cookie in the file is not its cookie. |
| `NODE was treated as a longnames node but is not` (or shortnames) | The target uses the other naming mode. The message gives the name it answers to; pass that as `--node`. |
| `cookie file PATH: the cookie file is readable by group or others` | `chmod 600 PATH`. |
| `cookie file PATH: the cookie file cannot be read` | The file is missing or unreadable. With no `--cookie-file` the path is `~/.erlang.cookie`. |
| `the target runs OTP N; pickglass needs OTP 28 or newer` | Upgrade the target. |
| `refusing HOST: pickglass attaches to nodes on this machine only for now` | The host is not local. |
| `--node cannot be combined with --state-dir or --pid` | Pick one way to find the target. |

OTP reports a refused connection by a bare `false`, whether the cookie
differs, the naming mode differs, or the node is down. Pickglass tells these
apart by asking epmd whether the name is registered and then by retrying the
same name in the other naming mode, so a wrong-mode target is named as such
and a cookie mismatch is not misreported.

## Loom nodes

`pickglass attach` and `pickglass open` with no `--node` find a profiled Loom
daemon (`loomd --profile`) from the process table and a Loom state directory
(`--state-dir`, default `~/.loom`, and `--pid`). That is unchanged, and it is
the other way to find a target: `--node` and `--state-dir`/`--pid` cannot be
combined.
