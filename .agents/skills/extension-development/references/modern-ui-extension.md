Put standalone screens under their package's `FrontendSources/screen/src/development/screens/<Module>/<ScreenID>/`. Put product screens under deployed `FrontendSources/screen/src/screens/<Module>/<ScreenID>/`. Published customization output is under `customizationScreens/<Tenant>/screens/<Module>/<ScreenID>/`, or the older unscoped `customizationScreens/screens/<Module>/<ScreenID>/`. Inspect both published layouts when tracing an existing site. Do not mix roots in a standalone package. Modern-only screens have no ASPX.

1. Inventory screen IDs, graph type, primary view, public views, and actions.
2. Map C# graph/view/action members through `@graphInfo`, `@viewInfo`, `createSingle`, `createCollection`, and `PXActionState`.
3. Match HTML `view.bind` and `state.bind` to TS property names exactly.
4. Use framework controls for ordinary date, datetime, text, and selector fields.
5. Run the package binding audit after graph, TS, or HTML changes.

Use tabs, double quotes, and no `any`. Do not import `.html` without a proven runtime need. Do not add empty template shims or loader hacks. For missing views or bindings, compare public C# members, TS bindings, and HTML binds; derive only required template changes from a current neighboring screen.
