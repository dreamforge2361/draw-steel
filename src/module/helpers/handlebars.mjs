/**
 * Register all handlebars in Draw Steel.
 */
export function registerHandlebars() {
  Handlebars.registerHelper({
    "ds-tooltip": CONFIG.ux.TooltipManager.handlebarsHelper,
    "ds-tier": (level) => { const L = Number(level) || 1; return Math.min(5, Math.max(1, 6 - L)); },
  });
}
