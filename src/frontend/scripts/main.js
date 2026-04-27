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

    // Failures first within each org, then alphabetical by repo name.
    repos.sort((a, b) => {
      const rank = { failure: 0, success: 1 };
      const diff = (rank[repoOverall(a)] ?? 2) - (rank[repoOverall(b)] ?? 2);
      if (diff !== 0) return diff;
      return (a.repository || '').localeCompare(b.repository || '');
    });

    // Group by org (owner part of "org/repo").
    const byOrg = new Map();
    for (const repo of repos) {
      const org = (repo.repository || '').split('/')[0] || 'unknown';
      if (!byOrg.has(org)) byOrg.set(org, []);
      byOrg.get(org).push(repo);
    }

    fleet.innerHTML = Array.from(byOrg.entries())
      .map(([org, orgRepos]) => renderOrgGroup(org, orgRepos))
      .join('');
    setupPillHovers();
    setupOrgCollapse();

  } catch (err) {
    fleet.innerHTML = `
      <div class="state-message">
        <h2>Could not load fleet data</h2>
        <p>${err.message}</p>
      </div>`;
  }
}

init();

// Animate org group open/close — native <details> doesn't support CSS transitions.
function setupOrgCollapse() {
  document.querySelectorAll('.org-group').forEach(details => {
    const cards = details.querySelector('.org-cards');
    if (!cards) return;

    details.addEventListener('click', e => {
      if (!e.target.closest('summary')) return;
      e.preventDefault();

      if (details.open) {
        // Closing: fix height, then animate to 0.
        cards.style.height = cards.scrollHeight + 'px';
        cards.offsetHeight; // force reflow
        cards.style.height = '0';
        cards.addEventListener('transitionend', () => {
          details.removeAttribute('open');
          cards.style.height = '';
        }, { once: true });
      } else {
        // Opening: add open first, animate from 0 to full height.
        details.setAttribute('open', '');
        cards.style.height = '0';
        cards.offsetHeight; // force reflow
        cards.style.height = cards.scrollHeight + 'px';
        cards.addEventListener('transitionend', () => {
          cards.style.height = '';
        }, { once: true });
      }
    });
  });
}
