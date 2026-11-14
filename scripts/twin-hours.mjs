// Parses Helsinki Service Map opening-hours text, e.g.
// "Voimassa toistaiseksi:\n– ma-ke\n  8.00-16.00\n  16.00-20.00 ajanvarauksella\n– la-su suljettu"
const dayIndex = { ma: 0, ti: 1, ke: 2, to: 3, pe: 4, la: 5, su: 6 };
function parseDays(spec) {
  const days = new Set();
  for (const part of spec.split(",").map(item => item.trim()).filter(Boolean)) {
    const [from, to] = part.split("-").map(item => dayIndex[item.trim()]);
    if (from === undefined) continue;
    for (let day = from; day <= (to ?? from); day++) days.add(day);
  }
  return [...days];
}
/** Weekly opening hours on weekdays 8–16 ("day") and outside them ("extended"), from Service Map text. */
export function weeklyHours(text) {
  const hours = { day: 0, extended: 0 };
  let days = [];
  for (const raw of text.split("\n")) {
    const line = raw.replace(/ /g, " ").trim();
    const header = line.match(/^–\s*([a-z ,-]+?)(?:\s+(\d.*)|\s+suljettu)?$/);
    if (header) days = parseDays(header[1]);
    for (const [, a, b, c, d] of line.matchAll(/(\d{1,2})\.(\d{2})\s*-\s*(\d{1,2})\.(\d{2})/g)) {
      const start = Number(a) + Number(b) / 60, end = Number(c) + Number(d) / 60;
      for (const day of days) {
        const core = day < 5 ? Math.max(0, Math.min(end, 16) - Math.max(start, 8)) : 0;
        hours.day += core;
        hours.extended += end - start - core;
      }
    }
  }
  return { day: round(hours.day, 1), extended: round(hours.extended, 1) };
}
const round = (value, digits) => Number(value.toFixed(digits));
