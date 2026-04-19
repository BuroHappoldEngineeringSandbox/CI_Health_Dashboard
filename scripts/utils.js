// Pure utility functions — no DOM access, no side effects.
// Safe to unit-test in isolation.

/**
 * Converts an ISO 8601 timestamp to a human-readable relative string
 * (e.g. "5m ago", "2h ago"). Returns '—' when the input is absent.
 */
function relativeTime(iso) {
  if (!iso) return '—';
  const s = Math.floor((Date.now() - new Date(iso)) / 1000);
  if (s < 60)    return s + 's ago';
  if (s < 3600)  return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return Math.floor(s / 86400) + 'd ago';
}

/**
 * Extracts the repo name from an "org/repo" string.
 */
function repoName(repository) {
  return repository ? repository.split('/').pop() : '—';
}

/**
 * Builds the full GitHub URL for an "org/repo" string.
 */
function repoUrl(repository) {
  return 'https://github.com/' + (repository || '');
}

/**
 * Maps a job result string to its CSS pill class.
 */
function pillClass(result) {
  switch (result) {
    case 'success':   return 'pill-success';
    case 'failure':   return 'pill-failure';
    case 'skipped':   return 'pill-skipped';
    case 'cancelled': return 'pill-skipped';
    default:          return 'pill-unknown';
  }
}

/**
 * Maps a maturity tier string to its CSS badge class.
 */
function badgeClass(maturity) {
  switch ((maturity || '').toLowerCase()) {
    case 'beta':  return 'badge-beta';
    case 'alpha': return 'badge-alpha';
    default:      return 'badge-prototype';
  }
}

/**
 * Maps an overall result to its CSS card status class.
 */
function statusClass(overall) {
  if (overall === 'success') return 'status-success';
  if (overall === 'failure') return 'status-failure';
  return '';
}
