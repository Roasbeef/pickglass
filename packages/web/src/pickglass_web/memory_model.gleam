//// The readings the owners, memory and process pages show from the agent's
//// ETS and binaries requests.
////
//// They are kept apart from `model` for the reason `timeline_model` is: the
//// page models there stay readable at a size one can hold in mind, and these
//// types are about one thing, how much of the node's tables and binaries a
//// reading covered. Each says what it covers, because a figure from a walk
//// that ran out of time understates, and a process that holds too many
//// binaries is refused and not summarised.
////
//// Nothing here is a number without a unit or a reason: bytes and counts are
//// `Measurement`s where a row may be unread, and the totals a walk reports
//// are plain counts of what it read.

import pickglass_core/measure.{type Measurement}

// ------------------------------------------------------------ owners

/// Whether the pass that counted ETS tables saw every table.
pub type EtsReach {
  /// Every table the node listed was read or found deleted.
  EveryTable

  /// The pass ran out of time with tables unread, so the figures understate.
  StoppedAtDeadline
}

/// What the owners page's ETS column rests on.
pub type OwnersEts {
  /// The agent's ETS pass was not read; the text says why.
  EtsNotRead(reason: String)

  /// The pass read this many tables holding this many bytes over the whole
  /// node, and found `skipped` deleted before they could be read. `owners`
  /// is how many owners the agent listed aggregates for and `tracked` how many
  /// it saw, so the column says when an owner row has no aggregate.
  EtsPassRead(
    tables: Int,
    bytes: Int,
    skipped: Int,
    reach: EtsReach,
    owners: Int,
    tracked: Int,
  )
}

/// One reference-counted binary a process holds. `address` is the binary's
/// address in hexadecimal, which names the same binary in another process.
pub type BinaryRow {
  BinaryRow(
    address: String,
    /// The binary's whole size, which a sub-binary shares.
    bytes: Measurement,
    /// How many references to it exist on the whole node.
    refc: Measurement,
  )
}

/// What the process page knows about the process's binaries.
pub type Binaries {
  /// The operator has not read them. The read is costly for a process that
  /// holds many, so it is planned and confirmed.
  BinariesNotRead

  /// The newest read: how many different binaries the process holds, their
  /// total size, how many references it holds to them, and the largest. A
  /// binary held through several references counts once, and a sub-binary
  /// counts the whole binary, so `bytes` is what the process keeps alive and
  /// not memory unique to it.
  BinariesListed(
    distinct: Int,
    bytes: Int,
    references: Int,
    largest: List(BinaryRow),
    age_ms: Int,
  )

  /// The agent refused or failed the read; the text says why, in the agent's
  /// words.
  BinariesRefused(reason: String, age_ms: Int)
}

/// One ETS table, described by properties; its contents are never read.
pub type EtsRow {
  EtsRow(
    /// The table's name when it has one, and its identifier otherwise.
    label: String,
    /// The identifier, which names an unnamed table and tells two tables of
    /// one name apart.
    id: String,
    /// The owning process.
    owner_pid: String,
    /// The owner's label, or the word `unknown`.
    owner_label: String,
    /// `set`, `ordered_set`, `bag` or `duplicate_bag`.
    kind: String,
    objects: Measurement,
    bytes: Measurement,
    /// `public`, `protected` or `private`.
    protection: String,
  )
}

/// The ETS table listing of the memory page.
pub type EtsListing {
  /// The agent's table walk has not answered: the text says why.
  EtsListingMissing(reason: String)

  /// The largest tables by memory, with what the walk covered. `total` is how
  /// many tables the node had when the walk began, `read` how many were read,
  /// `skipped` how many were deleted before they could be, and `reach`
  /// whether the walk got to the end. `bytes` and `objects` are over every
  /// table read, listed or not.
  EtsListed(
    rows: List(EtsRow),
    total: Int,
    read: Int,
    skipped: Int,
    reach: EtsReach,
    objects: Measurement,
    bytes: Measurement,
    age_ms: Int,
  )
}
