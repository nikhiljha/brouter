// brouter config. Plain JavaScript, evaluated by JavaScriptCore.
// brouter reloads this file when it changes.
//
// Test without clicking links:
//   brouter route https://github.com/foo/bar
//   brouter validate

// ---------------------------------------------------------------------------
// Browsers
//
//   app:     app name, bundle ID, or path
//   profile: (optional) Chromium profile directory, e.g. "Default", "Profile 1"
//   args:    (optional) extra command-line arguments
//   label:   (optional) name shown in the picker
//
// Chrome shows the profile directory at chrome://version under "Profile Path".
// ---------------------------------------------------------------------------
const browsers = {
  personal: { app: "Google Chrome", profile: "Default",   label: "Personal" },
  work:     { app: "Google Chrome", profile: "Profile 1", label: "Work" },
  safari:   { app: "Safari" },
  firefox:  { app: "Firefox" },
};

// ---------------------------------------------------------------------------
// Custom URL schemes (optional)
//
// brouter handles links with these schemes after `make install` and
// `brouter register-schemes`. Route them in route() below.
// ---------------------------------------------------------------------------
const schemeHandlers = [
  // { schemes: ["myapp"], target: { app: "com.example.myapp", label: "Open in My App" } },
];
const schemes = schemeHandlers.flatMap(h => h.schemes);

// ---------------------------------------------------------------------------
// Routing
//
// ctx: url, scheme, host, hostname, port, path, pathname, hash, search,
//      query, sourceApp { name, bundleId, path }
//
// Return one of:
//   "work"                          open in a browser from `browsers`
//   { browser: "work" }             same as above
//   { app: "Safari" }               open in an app not listed in `browsers`
//   { copy: true }                  copy the URL to the clipboard
//   { ask: true }                   pick from all browsers
//   { ask: ["work", "personal"] }   pick from these options
//   { ask: { options, message, default } }
//   nothing                         open in the first browser, or Safari
//
// `ask` options can also include { copy: true } and app targets. `default` is
// an option index or browser key.
// ---------------------------------------------------------------------------
function route(url, ctx) {
  const handler = schemeHandlers.find(h => h.schemes.includes(ctx.scheme));
  if (handler) {
    return { ask: { options: [{ copy: true }, handler.target], default: 0 } };
  }

  const is = (d) => ctx.host === d || ctx.host.endsWith("." + d);

  if (is("github.com") || is("slack.com") || is("notion.so")) return "work";
  if (ctx.sourceApp?.bundleId === "com.tinyspeck.slackmacgap") return "work";
  if (/(^|\.)(youtube|reddit)\.com$/.test(ctx.host)) return "personal";

  if (is("zoom.us") || is("meet.google.com")) {
    return { ask: { options: ["work", "personal"], message: "Join meeting in…", default: "work" } };
  }
  if (is("figma.com")) return { ask: true };

  return "personal";
}

// vim: set ft=javascript ts=2 sw=2 et :
