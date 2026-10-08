// Illustrative, synthetic score model for the showcase. Not a real scoring algorithm.
(function () {
  const $ = (id) => document.getElementById(id);

  // Hero gauge animation
  const heroScore = 612;
  const gauge = $("heroGauge");
  requestAnimationFrame(() => {
    gauge.style.strokeDashoffset = String(252 * (1 - (heroScore - 300) / 550));
  });

  const inputs = { months: $("months"), util: $("util"), missed: $("missed"), lines: $("lines") };

  function band(score) {
    if (score >= 750) return ["Excellent", "#00b26a"];
    if (score >= 690) return ["Good", "#2fc27f"];
    if (score >= 630) return ["Fair", "#f2b33d"];
    return ["Building", "#ef7b45"];
  }

  function update() {
    const months = +inputs.months.value;
    const util = +inputs.util.value;
    const missed = +inputs.missed.value;
    const lines = +inputs.lines.value;

    $("monthsOut").textContent = months;
    $("utilOut").textContent = util + "%";
    $("missedOut").textContent = missed;
    $("linesOut").textContent = lines;

    let score = 560;
    score += Math.min(months, 36) * 4.2;
    score -= Math.max(0, util - 10) * 1.6;
    score -= missed * 38;
    score += Math.min(lines, 5) * 9;
    score = Math.round(Math.max(300, Math.min(850, score)));

    const [label, color] = band(score);
    $("score").textContent = score;
    $("band").textContent = label;
    const ring = $("ring");
    ring.style.setProperty("--pct", ((score - 300) / 550) * 100);
    ring.style.setProperty("--ring", color);

    const tips = [];
    if (util > 30) tips.push("Keep utilization under 30% (under 10% is even better).");
    if (missed > 0) tips.push("Autopay helps prevent missed payments, which weigh heavily.");
    if (months < 12) tips.push("Steady on-time payments add up. Keep going for 12+ months.");
    if (lines < 2) tips.push("Adding a second tradeline, like a Credit Builder Loan, adds credit mix.");
    if (!tips.length) tips.push("Great habits. Keep payments on time and utilization low.");
    $("tips").innerHTML = tips.map((t) => `<li>${t}</li>`).join("");
  }

  Object.values(inputs).forEach((el) => el.addEventListener("input", update));
  update();
})();
