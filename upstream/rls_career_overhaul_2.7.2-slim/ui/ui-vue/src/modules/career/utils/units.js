export const METERS_PER_MILE = 1609.344

// Odometer / route distance in the player's length unit, always the large unit (km or mi):
// units.buildString("length") drops to m/cm/mm (ft/in) for short values, so 0 would read "0 mm".
// `units` is useBridge().units; the factor comes from the game's own length conversion.
export function bigLengthUnit(units) {
  const ref = units?.length?.(1000) // { val, unit } for 1 km: { 1, "km" } or { 0.62, "mi" }
  return ref ? { perMetre: ref.val / 1000, unit: ref.unit } : { perMetre: 0.001, unit: "km" }
}

export function formatOdometer(units, metres, decimals = 0) {
  const { perMetre, unit } = bigLengthUnit(units)
  const val = Math.max(0, Number(metres) || 0) * perMetre
  const text = Intl.NumberFormat(units?.userSettings?.uiLanguage || undefined, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  }).format(val)
  return `${text} ${unit}`
}

// Vehicle shop range filters hold values in the unit the player sees (km/mi, PS/bhp/kW, kg/lbs);
// dataPerUnit turns them back into the listing fields (Mileage metres, Power PS, Weight kg).
export function shopFilterUnit(units, field) {
  if (field === "Mileage") {
    const { perMetre, unit } = bigLengthUnit(units)
    return { label: unit, dataPerUnit: 1 / perMetre }
  }
  const ref = field === "Power" ? units?.power?.(1) : field === "Weight" ? units?.weight?.(1) : null
  if (ref && ref.val > 0) return { label: ref.unit, dataPerUnit: 1 / ref.val }
  return { label: field === "Power" ? "PS" : field === "Weight" ? "kg" : "", dataPerUnit: 1 }
}

// Money in plain text (prompts, toasts, error lines). The game's units.beamBucks() returns only a
// localized number ("1,234.00") with no currency marker, and 0.39 ships no translated currency name,
// so plain text uses the currency's proper name the way a currency code is used. Markup should show
// the glyph instead (<BngIcon :type="icons.beamCurrency" /> or <BngUnit :money>).
export const CURRENCY_NAME = "BeamBucks"

export function moneyText(units, value, { decimals = 2 } = {}) {
  const n = Number(value)
  if (!Number.isFinite(n)) return `— ${CURRENCY_NAME}`
  const text = Intl.NumberFormat(units?.userSettings?.uiLanguage || undefined, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  }).format(Math.abs(n))
  // sign in front of the amount ("-1,234.50 BeamBucks"); an amount that rounds to zero has no sign
  const negative = n < 0 && Number(Math.abs(n).toFixed(decimals)) !== 0
  return `${negative ? "-" : ""}${text} ${CURRENCY_NAME}`
}
