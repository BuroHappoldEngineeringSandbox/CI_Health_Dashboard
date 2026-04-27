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
 * Formats an ISO 8601 timestamp as a local-time string.
 * Shows date only when it differs from today: "Apr 26, 18:00:00" vs "18:00:00".
 */
function formatAbsTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const now = new Date();
  const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const isToday = d.toDateString() === now.toDateString();
  if (isToday) return time;
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ', ' + time;
}

/**
 * Attaches hover behaviour to all .pill-wrap[data-timestamp] elements.
 * On hover: show relative time immediately, switch to absolute after 2s.
 * On mouse leave: cancel pending switch, restore relative time.
 */
function setupPillHovers() {
  document.querySelectorAll('.pill-wrap[data-timestamp]').forEach(wrap => {
    const timeEl = wrap.querySelector('.pill-time');
    if (!timeEl) return;
    const iso = wrap.dataset.timestamp;
    let timer = null;

    wrap.addEventListener('mouseenter', () => {
      timeEl.textContent = relativeTime(iso);
      timer = setTimeout(() => {
        timeEl.textContent = formatAbsTime(iso);
      }, 2000);
    });

    wrap.addEventListener('mouseleave', () => {
      clearTimeout(timer);
      timeEl.textContent = relativeTime(iso);
    });
  });
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
