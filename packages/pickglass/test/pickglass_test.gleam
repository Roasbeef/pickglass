import gleeunit
import pickglass

pub fn main() -> Nil {
  gleeunit.main()
}

// The banner is what the release smoke test compares against, so its shape
// is part of the contract rather than an incidental string.
pub fn banner_names_the_program_and_version_test() {
  assert pickglass.banner() == "pickglass " <> pickglass.version
}
