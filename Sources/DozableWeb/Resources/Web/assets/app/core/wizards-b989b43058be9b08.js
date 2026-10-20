// core/wizards — The onboarding wizard's steps (594, 599g; 634: the setup v2).


// ── onboarding (594; 634, the owner's chosen mockup onboarding-v2) ──────────
// Welcome (this Mac's checks inline) → Base image (its download starts in the host here and goes on behind every later
// step — the strip at the foot) → Models & keys (the sign-ins found; a key of any provider or gateway) → GitHub & SSH →
// Workspace rules (its Next writes the settings: POST onboarding/config {base, access, ignoreMode}) → Usage statistics
// and Stay in touch (an official build only) → First sandbox (an ordinary sandbox made the quick way, named after its
// tool — the planner's `first` purpose — or Finish without one).
// The same model as every page: facts from GET /api/v1/onboarding; changes through the typed actions (onboard,
// prepare-cancel, create) and the typed routes (onboarding/config, accounts, settings, signup). A key: the masked field
// (POST /api/v1/accounts) while ui.allow_secret_entry, else the CLI command.
export const WIZ_STEPS = ['Welcome', 'Base image', 'Models & keys', 'GitHub & SSH', 'Workspace rules', 'Usage statistics', 'Stay in touch', 'First sandbox'];
// The steps by name. Usage statistics and Stay in touch are shown only by an official build; elsewhere they are skipped.
export const WIZ = { welcome: 0, base: 1, keys: 2, access: 3, rules: 4, usage: 5, signup: 6, first: 7 };
// Each step's column (owner: "max-width step content … stay in touch should be a narrow panel because its just a form vs
// Step 3 models and keys which has a 2 column layout"): narrow 480 · medium 680 · wide 1080.
export const WIZ_SIZE = ['medium', 'medium', 'wide', 'medium', 'medium', 'narrow', 'narrow', 'wide'];
