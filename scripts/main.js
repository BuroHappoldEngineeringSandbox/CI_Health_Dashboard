// Entry point — fetches fleet.json and orchestrates rendering.
// Depends on: utils.js, render.js (must be loaded first).

async function init() {
  const fleet = document.getElementById('fleet');
  try {
    const resp = await fetch('public/fleet.json');
    if (!resp.ok) throw new Error('HTTP ' + resp.status);
    const data = await resp.json();
    const repos = Array.isArray(data.repos) ? data.repos : [];

    renderSummary(repos, data.generated_at);

    if (repos.length === 0) {
      fleet.innerHTML = `
        <div class="state-message">
          <h2>No data yet</h2>
          <p>Waiting for the first CI run to report in. Re-run any PR on a repo using the orchestrator to trigger ingest.</p>
        </div>`;
      return;
    }

    // Failures first, then alphabetical by repo name.
    repos.sort((a, b) => {
      const rank = { failure: 0, success: 1 };
      const diff = (rank[a.overall] ?? 2) - (rank[b.overall] ?? 2);
      if (diff !== 0) return diff;
      return (a.repository || '').localeCompare(b.repository || '');
    });

    fleet.innerHTML = repos.map(renderCard).join('');

  } catch (err) {
    fleet.innerHTML = `
      <div class="state-message">
        <h2>Could not load fleet data</h2>
        <p>${err.message}</p>
      </div>`;
  }
}

init();
