// Rendering functions — build HTML strings from data objects.
// Depends on: utils.js (must be loaded first).

/**
 * Renders a collapsible org group containing repo cards.
 * @param {string} org      - The GitHub org/owner name.
 * @param {Array}  repos    - Fleet entries belonging to this org.
 * @returns {string} HTML string for the group.
 */
function renderOrgGroup(org, repos) {
  const anyFailing = repos.some(r => r.overall === 'failure');
  const allPassing = repos.every(r => r.overall === 'success');
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
 * Renders a single repo health card as an HTML string.
 * @param {Object} repo - A fleet entry from fleet.json (augmented with _source).
 * @returns {string} HTML string for the card.
 */
function renderCard(repo) {
  const pills = Object.keys(repo.jobs || {}).sort().map(job => {
    const entry  = (repo.jobs || {})[job];
    // Support both new {status, timestamp} shape and legacy bare string.
    const result = (entry && typeof entry === 'object') ? entry.status : (entry || 'unknown');
    const ts     = (entry && typeof entry === 'object') ? entry.timestamp : null;
    const cls    = pillClass(result);
    const label  = ts
      ? `<span class="pill-time">${relativeTime(ts)}</span>`
      : '';
    const wrap    = ts ? `data-timestamp="${ts}"` : '';
    const pillUrl = (entry && entry.run_url) ? entry.run_url : repo.run_url;
    // All pills link to their own specific run when available.
    if (pillUrl) {
      return `<span class="pill-wrap" ${wrap}><a class="pill ${cls}" href="${pillUrl}" target="_blank" rel="noopener noreferrer">${job}</a>${label}</span>`;
    }
    return `<span class="pill-wrap" ${wrap}><span class="pill ${cls}">${job}</span>${label}</span>`;
  }).join('');

  const badge = repo.maturity
    ? `<span class="badge ${badgeClass(repo.maturity)}">${(repo.maturity).toLowerCase()}</span>`
    : '';

  const refLabel = repo.ref
    ? `<span class="source-label">${repo.ref}</span>`
    : '';

  const runLink = repo.pr_number
    ? `<a href="https://github.com/${repo.repository}/pull/${repo.pr_number}" target="_blank" rel="noopener noreferrer">view PR ↗</a>`
    : repo.run_url
      ? `<a href="${repo.run_url}" target="_blank" rel="noopener noreferrer">view run ↗</a>`
      : '';

  return `
    <div class="card ${statusClass(repo.overall)}">
      <div class="card-identity">
        <a href="${repoUrl(repo.repository)}" target="_blank" rel="noopener noreferrer">${repoName(repo.repository)}</a>
        ${badge}
        ${refLabel}
      </div>
      <div class="job-pills">${pills}</div>
      <div class="card-meta">
        <span title="${repo.timestamp || ''}">${relativeTime(repo.timestamp)}</span>
        <span>${runLink}</span>
      </div>
    </div>`;
}

/**
 * Populates the summary bar with pass/fail counts and a freshness timestamp.
 * Writes directly to DOM elements #summary-counts and #freshness.
 * @param {Array}  repos       - Array of repo fleet entries.
 * @param {string} generatedAt - ISO timestamp when the snapshot was built.
 */
function renderSummary(repos, generatedAt) {
  const passing = repos.filter(r => r.overall === 'success').length;
  const failing = repos.filter(r => r.overall === 'failure').length;
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
