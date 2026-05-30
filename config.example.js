// brouter config — plain JavaScript, evaluated by JavaScriptCore.
//
// Define two globals:
//   1. `browsers` — the set of browsers/profiles you can route to.
//   2. `route(url, ctx)` — a function that decides where each URL goes.
//
// Edit, save, and brouter picks it up automatically (it watches mtime).
// Test changes without clicking links:
//   brouter route https://github.com/foo/bar
//   brouter validate

// ---------------------------------------------------------------------------
// 1) Browsers / profiles
//
// Each entry:
//   app:     app name ("Google Chrome"), bundle id ("com.google.Chrome"),
//            or full path ("/Applications/Foo.app")
//   profile: (optional) Chromium --profile-directory, e.g. "Default", "Profile 1"
//   args:    (optional) extra command-line args (Firefox -P, etc.)
//   label:   (optional) name shown in the Ask dialog
//
// Tip: find your Chrome profile directory names at
//   chrome://version  -> "Profile Path" (the last path component)
// ---------------------------------------------------------------------------
const browsers = {
  personal: { app: "Google Chrome", profile: "Default",   label: "Chrome — Personal" },
  work:     { app: "Google Chrome", profile: "Profile 1", label: "Chrome — Work" },
  safari:   { app: "Safari",                                label: "Safari" },
  firefox:  { app: "Firefox",                               label: "Firefox" },
  // arc:   { app: "Arc",                                    label: "Arc" },
};

// ---------------------------------------------------------------------------
// 2) Routing
//
// `ctx` contains: url, scheme, host, hostname, port, path, pathname, hash,
//                 search, query {name: value}, sourceApp {name, bundleId, path}
//
// Return one of:
//   "work"                              -> a key from `browsers`
//   { app: "Safari" }                  -> an inline browser target
//   { browser: "work" }                -> reference a key explicitly
//   { ask: true }                      -> Ask dialog with ALL browsers
//   { ask: ["work", "personal"] }      -> Ask dialog with these options
//   { ask: { options: ["work","personal"], message: "Open where?",
//            default: "work", timeout: 8 } }
//   (return nothing) -> brouter falls back to the first browser / Safari
// ---------------------------------------------------------------------------
function route(url, ctx) {
  const host = ctx.host || "";

  // Helper: does host equal or end with a domain?
  const is = (d) => host === d || host.endsWith("." + d);

  // Work stuff -> work profile
  if (is("github.com") || is("slack.com") || is("notion.so")) {
    return "work";
  }

  // Open links that came from Slack in the work profile
  if (ctx.sourceApp && ctx.sourceApp.bundleId === "com.tinyspeck.slackmacgap") {
    return "work";
  }

  // Regex example
  if (/(^|\.)(youtube|reddit)\.com$/.test(host)) {
    return "personal";
  }

  // Meetings: let me choose, defaulting to work
  if (is("zoom.us") || is("meet.google.com")) {
    return { ask: { options: ["work", "personal"], message: "Join meeting in…", default: "work" } };
  }

  // Anything ambiguous: ask among everything
  if (is("figma.com")) {
    return { ask: true };
  }

  // Default
  return "personal";
}

// vim: set ft=javascript ts=2 sw=2 et :
