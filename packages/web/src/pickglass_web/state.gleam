//// Page-local view state.
////
//// What the operator controls in the page, as opposed to what the node
//// reports: which profile tab is open, which owner rows are expanded, which
//// box is selected, what is typed in the plan form and the filter form. It
//// is kept apart from the page models so that a fresh census, which replaces
//// a model wholesale, does not collapse the rows the operator opened.
////
//// Nothing here is authoritative. Selections hold `Key`s, and a key that the
//// current data no longer contains simply highlights nothing. The last
//// request and the notice exist so the page can say what it just did: a
//// request is only a request until the viewer answers it.
////
//// ## Reading order
////
//// `initial` builds the starting state; `app.update` replaces fields through
//// `UiEvent`s.

import gleam/option.{type Option, None}
import gleam/set.{type Set}
import pickglass_core/policy
import pickglass_web/key.{type Key}
import pickglass_web/msg

/// The plan form's fields as typed.
pub type PlanDraft {
  PlanDraft(
    /// The kind of probe chosen.
    kind: policy.ProbeKind,
    /// The module patterns as typed, not yet checked.
    modules: String,
    /// The duration chosen.
    duration: msg.DurationChoice,
    /// The target chosen, by key.
    target: Option(Key),
  )
}

/// The filter form's fields as typed.
pub type FilterDraft {
  FilterDraft(
    /// The kind of step chosen.
    kind: msg.FilterKind,
    /// The pattern as typed, not yet compiled.
    pattern: String,
  )
}

/// Everything the operator has set in the page.
pub type UiState {
  UiState(
    /// The open profile tab.
    tab: msg.ProfileTab,
    /// Expanded owner rows.
    expanded: Set(Key),
    /// The selected box or node.
    selected: Option(Key),
    /// The search text on the profile page.
    search: String,
    /// The plan form.
    plan: PlanDraft,
    /// The filter form.
    filter: FilterDraft,
    /// A sentence about the last refusal or request, shown near the control.
    notice: Option(String),
    /// The last request sent to the viewer.
    last_request: Option(msg.Request),
  )
}

/// The starting state: the flame tab, nothing expanded or selected, and
/// empty forms.
pub fn initial() -> UiState {
  UiState(
    tab: msg.FlameTab,
    expanded: set.new(),
    selected: None,
    search: "",
    plan: PlanDraft(
      kind: policy.Counters,
      modules: "",
      duration: msg.Seconds30,
      target: None,
    ),
    filter: FilterDraft(kind: msg.FocusFilter, pattern: ""),
    notice: None,
    last_request: None,
  )
}
