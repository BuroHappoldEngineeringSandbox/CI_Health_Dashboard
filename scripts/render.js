// Rendering functions — build HTML strings from data objects.
// Depends on: utils.js (must be loaded first).

/**
 * Renders a collapsible org group containing repo cards.
 * @param {string} org      - The GitHub org/owner name.
 * @param {Array}  repos    - Fleet entries belonging to this org.
 * @returns {string} HTML string for the group.
 */
function renderOrgGroup(org, repos) {
  const anyFailing = repos.some(r => repoOverall(r) === 'failure');
  const allPassing = repos.every(r => repoOverall(r) === 'success');
  const statusCls  = anyFailing ? 'org-failing' : allPassing ? 'org-passing' : '';
  const cards      = repos.map(renderCard).join('');
  return `
    <details class="org-group" open>
      <summary class="org-header ${statusCls}">
        <span class="org-chevron"></span>
        <a href="https://github.com/${org}" target="_blank" rel="noopener noreferrer">${org}</a>
        <span class="org-count">${repos.length} repo${repos.length !== 1 ? 's' : ''}</span>
      </summary>
      <div class="org-cards">${cards}</div>
    </details>`;
}

/**
 * Derives the worst overall status across all branches of a repo entry.
 */
function repoOverall(repo) {
  const statuses = Object.values(repo.branches || {}).map(b => b.overall || 'unknown');
  for (const s of ['failure', 'cancelled', 'skipped', 'success']) {
    if (statuses.includes(s)) return s;
  }
  return 'unknown';
}

/**
 * Renders the pills row for a single branch's jobs object.
 */
function renderBranchPills(jobs, repoRunUrl) {
  return Object.keys(jobs || {}).sort().map(job => {
    const entry   = jobs[job];
    const result  = (entry && typeof entry === 'object') ? entry.status : (entry || 'unknown');
    const ts      = (entry && typeof entry === 'object') ? entry.timestamp : null;
    const cls     = pillClass(result);
    const tsAttrs = ts ? `data-timestamp="${ts}" data-tooltip="${relativeTime(ts)}"` : '';
    const pillUrl = (entry && entry.run_url) ? entry.run_url : repoRunUrl;
    if (pillUrl) {
      return `<a class="pill ${cls}" href="${pillUrl}" ${tsAttrs} target="_blank" rel="noopener noreferrer">${job}</a>`;
    }
    return `<span class="pill ${cls}" ${tsAttrs}>${job}</span>`;
  }).join('');
}

/**
 * Renders a single repo health card as an HTML string.
 * Each tracked branch is shown as a separate row within the card.
 * @param {Object} repo - A fleet entry from fleet.json.
 * @returns {string} HTML string for the card.
 */
function renderCard(repo) {
  const overall = repoOverall(repo);

  const badge = repo.maturity
    ? `<span class="badge ${badgeClass(repo.maturity)}">${repo.maturity.toLowerCase()}</span>`
    : '';

  const branchRows = Object.entries(repo.branches || {}).map(([branch, data]) => {
    const pills   = renderBranchPills(data.jobs, data.run_url);
    const runLink = data.pr_number
      ? `<a href="https://github.com/${repo.repository}/pull/${data.pr_number}" target="_blank" rel="noopener noreferrer">view PR ↗</a>`
      : data.run_url
        ? `<a href="${data.run_url}" target="_blank" rel="noopener noreferrer">view run ↗</a>`
        : '';
    return `
      <div class="branch-row ${statusClass(data.overall)}">
        <span class="source-label">${branch}</span>
        <div class="job-pills">${pills}</div>
        <div class="card-meta">
          <span title="${data.timestamp || ''}">${relativeTime(data.timestamp)}</span>
          <span>${runLink}</span>
        </div>
      </div>`;
  }).join('');

  return `
    <div class="card ${statusClass(overall)}">
      <div class="card-identity">
        <a href="${repoUrl(repo.repository)}" target="_blank" rel="noopener noreferrer">${repoName(repo.repository)}</a>
        ${badge}
      </div>
      ${branchRows}
    </div>`;
}

/**
 * Populates the summary bar with pass/fail counts and a freshness timestamp.
 * Writes directly to DOM elements #summary-counts and #freshness.
 * @param {Array}  repos       - Array of repo fleet entries.
 * @param {string} generatedAt - ISO timestamp when the snapshot was built.
 */
function renderSummary(repos, generatedAt) {
  const passing = repos.filter(r => repoOverall(r) === 'success').length;
  const failing = repos.filter(r => repoOverall(r) === 'failure').length;
  const unknown = repos.length - passing - failing;

  let html = `
    <span class="summary-count"><span class="dot dot-success"></span>${passing} passing</span>
    <span class="summary-count"><span class="dot dot-failure"></span>${failing} failing</span>`;
  if (unknown > 0) {
    html += `<span class="summary-count"><span class="dot dot-unknown"></span>${unknown} unknown</span>`;
  }
  document.getElementById('summary-counts').innerHTML = html;

  const el = document.getElementById('freshness');
  if (generatedAt) {
    el.textContent = 'Updated ' + relativeTime(generatedAt);
    el.title = generatedAt;
  }
}
