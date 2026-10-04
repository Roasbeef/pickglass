import gleam/list
import pg_data_gen as gen
import pickglass_core/identity
import pickglass_core/measure.{
  Counter, DeltaOverInterval, Gauge, Known, Missing, OneShot,
}
import pickglass_core/provenance.{
  type Provenance, Budget, BuildField, CadenceField, DirectionAllowed,
  DirectionWithheld, Method, Role, RuntimeField, Warmup, WorkloadField,
}

fn base() -> Provenance {
  gen.sample_provenance()
}

pub fn identical_provenance_is_comparable_test() {
  let result = provenance.comparability(base(), base())

  assert provenance.blocking_fields(result) == []
  assert provenance.verdict_for(result, Gauge) == DirectionAllowed
  assert provenance.verdict_for(result, Counter) == DirectionAllowed
}

// The build under test and the node's own incarnation are expected to
// differ and must not block a comparison.
pub fn build_and_incarnation_differences_are_expected_test() {
  let candidate = base()
  let assert Ok(boot) = identity.boot_id("bbbb") as "valid boot id"
  let candidate =
    provenance.Provenance(
      ..candidate,
      build: provenance.Build("loom", "1.1", "def456", "1.19"),
      target: provenance.Target(
        ..candidate.target,
        incarnation: identity.NodeIncarnation("digest", 2, boot),
        os: identity.OsProcess(200, identity.PreciseStart("u")),
      ),
    )
  let result = provenance.comparability(base(), candidate)

  assert list.key_find(result.fields, BuildField)
    == Ok(provenance.DiffersExpected)
  assert provenance.blocking_fields(result) == []
  assert provenance.verdict_for(result, Gauge) == DirectionAllowed
}

fn blocked_by(candidate: Provenance, field: provenance.Field) -> Nil {
  let result = provenance.comparability(base(), candidate)

  assert provenance.blocking_fields(result) == [field]
  assert provenance.verdict_for(result, Gauge) == DirectionWithheld([field])
  assert provenance.compare_measurements(result, Gauge, Known(1), Known(2))
    == provenance.Withheld([field])
}

pub fn a_different_method_blocks_test() {
  let b = base()
  blocked_by(
    provenance.Provenance(
      ..b,
      collection: provenance.Collection(..b.collection, method: "other"),
    ),
    Method,
  )
}

pub fn a_different_runtime_blocks_test() {
  let b = base()
  blocked_by(
    provenance.Provenance(
      ..b,
      runtime: provenance.Runtime(..b.runtime, otp_release: "28"),
    ),
    RuntimeField,
  )
}

pub fn different_emulator_flags_block_test() {
  let b = base()
  blocked_by(
    provenance.Provenance(
      ..b,
      runtime: provenance.Runtime(..b.runtime, flags: ["+Muatags false"]),
    ),
    RuntimeField,
  )
}

// Flags are a set; listing them in another order is not a difference.
pub fn flag_order_does_not_block_test() {
  let b = base()
  let reordered =
    provenance.Provenance(
      ..b,
      runtime: provenance.Runtime(
        ..b.runtime,
        flags: list.reverse(b.runtime.flags),
      ),
    )

  assert provenance.blocking_fields(provenance.comparability(b, reordered))
    == []
}

pub fn a_different_budget_blocks_test() {
  let b = base()
  blocked_by(
    provenance.Provenance(
      ..b,
      collection: provenance.Collection(
        ..b.collection,
        budgets: provenance.Budgets(..b.collection.budgets, top_k: 10),
      ),
    ),
    Budget,
  )
}

pub fn a_different_workload_blocks_test() {
  let b = base()
  blocked_by(
    provenance.Provenance(
      ..b,
      workload: provenance.Workload(..b.workload, label: "busy"),
    ),
    WorkloadField,
  )
  blocked_by(
    provenance.Provenance(
      ..b,
      workload: provenance.Workload(..b.workload, sessions: [#("sessions", 13)]),
    ),
    WorkloadField,
  )
}

// Notes are for people and are never compared.
pub fn workload_notes_do_not_block_test() {
  let b = base()
  let noted =
    provenance.Provenance(
      ..b,
      workload: provenance.Workload(..b.workload, notes: "rerun"),
    )

  assert provenance.blocking_fields(provenance.comparability(b, noted)) == []
}

pub fn a_different_warmup_blocks_test() {
  let b = base()
  blocked_by(
    provenance.Provenance(
      ..b,
      workload: provenance.Workload(..b.workload, warmup_ms: 1),
    ),
    Warmup,
  )
}

pub fn a_different_role_blocks_test() {
  let b = base()
  blocked_by(
    provenance.Provenance(
      ..b,
      target: provenance.Target(..b.target, role: "other"),
    ),
    Role,
  )
}

// A cadence mismatch makes rates incomparable but not levels.
pub fn cadence_blocks_rates_but_not_gauges_test() {
  let b = base()
  let candidate =
    provenance.Provenance(
      ..b,
      collection: provenance.Collection(..b.collection, cadence: OneShot),
    )
  let result = provenance.comparability(b, candidate)

  assert provenance.verdict_for(result, Gauge) == DirectionAllowed
  assert provenance.verdict_for(result, Counter)
    == DirectionWithheld([CadenceField])
  assert provenance.verdict_for(result, DeltaOverInterval)
    == DirectionWithheld([CadenceField])
}

pub fn comparable_readings_report_a_direction_test() {
  let result = provenance.comparability(base(), base())

  assert provenance.compare_measurements(result, Gauge, Known(1), Known(2))
    == provenance.Moved(provenance.Increased)
  assert provenance.compare_measurements(result, Gauge, Known(2), Known(1))
    == provenance.Moved(provenance.Decreased)
  assert provenance.compare_measurements(result, Gauge, Known(2), Known(2))
    == provenance.Moved(provenance.Unchanged)
}

// A missing reading is not zero: comparing 5 to a missing value must not
// read as a decrease.
pub fn absent_readings_give_no_direction_test() {
  let result = provenance.comparability(base(), base())

  assert provenance.compare_measurements(
      result,
      Gauge,
      Known(5),
      Missing(measure.ProcessExited),
    )
    == provenance.NoReading
  assert provenance.compare_measurements(
      result,
      Gauge,
      measure.NotApplicable,
      Known(5),
    )
    == provenance.NoReading
}

// Whatever two provenances are, a direction is stated only when no field
// blocks.
pub fn property_direction_requires_no_blocking_field_test() {
  use #(a, b) <- gen.check(gen.tuple2(gen.provenance(), gen.provenance()))
  let result = provenance.comparability(a, b)

  case provenance.compare_measurements(result, Gauge, Known(1), Known(2)) {
    provenance.Moved(_) -> {
      assert list.filter(provenance.blocking_fields(result), fn(f) {
          f != CadenceField
        })
        == []
    }
    provenance.Withheld(fields) -> {
      assert fields != []
    }
    provenance.NoReading -> panic as "both readings are known"
  }
}

pub fn property_a_provenance_is_comparable_with_itself_test() {
  use p <- gen.check(gen.provenance())

  assert provenance.blocking_fields(provenance.comparability(p, p)) == []
}
