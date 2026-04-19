// Rendering functions — build HTML strings from data objects.
// Depends on: utils.js (must be loaded first).

// Fixed job display order — columns are always consistent across cards regardless
// of the order fields appear in the JSON payload.
const JOB_ORDER = ['format', 'compliance', 'dataset', 'build', 'unit-tests'];

/**
 * Renders a single repo health card as an HTML string.
 * @param {Object} repo - A fleet entry from fleet.json (augmented with _source).
 * @returns {string} HTML string for the card.
 */
function renderCard(repo) {
  const pills = JOB_ORDER.map(job => {
    const result = (repo.jobs || {})[job] || 'unknown';
    const cls    = pillClass(result);
    // Failing pills link directly to the run so one click reaches the evidence.
    if (result === 'failure' && repo.run_url) {
      return `<a class="pill ${cls}" href="${repo.run_url}" target="_blank" rel="noopener noreferrer">${job}</a>`;
    }
    return `<span class="pill ${cls}">${job}</span>`;
  }).join('');

  const badge = repo.maturity
    ? `<span class="badge ${badgeClass(repo.maturity)}">${(repo.maturity).toLowerCase()}</span>`
    : '';

  // _source tells us whether this record came from a branch (pr-to-branch or push) or
  // a PR against a non-protected branch. Branch records are authoritative; PR records
  // are fallback — shown only when no branch record exists for a repo yet.
  let sourceLabel = '';
  if (repo._source === 'branch') {
    sourceLabel = `<span class="source-label source-branch">${repo.ref || 'branch'}</span>`;
  } else if (repo._source === 'pr') {
    sourceLabel = `<span class="source-label">PR · ${repo.ref || '?'}</span>`;
  }

  const runLink = repo.run_url
    ? `<a href="${repo.run_url}" target="_blank" rel="noopener noreferrer">view run ↗</a>`
    : '';

  return `
    <div class="card ${statusClass(repo.overall)}">
      <div class="card-identity">
        <a href="${repoUrl(repo.repository)}" target="_blank" rel="noopener noreferrer">${repoName(repo.repository)}</a>
        ${badge}
        ${sourceLabel}
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
