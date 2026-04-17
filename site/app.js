// Small progressive enhancement — highlight the download card that
// matches the visitor's detected OS.
(function () {
  const ua = navigator.userAgent || '';
  const platform = navigator.platform || '';
  let os = null;
  if (/Windows/i.test(ua) || /Win/i.test(platform)) os = 'windows';
  else if (/Mac/i.test(platform) || /Macintosh/i.test(ua)) os = 'macos';
  else if (/Linux/i.test(platform) || /X11/i.test(platform)) os = 'linux';

  if (!os) return;
  const target = document.querySelector(`.download-card[data-os="${os}"]`);
  if (!target) return;

  target.style.borderColor = 'var(--accent)';
  target.style.boxShadow = '0 0 0 2px rgba(122, 162, 255, 0.2)';

  // Nudge the primary CTA at the top.
  const primary = document.querySelector('.btn-primary');
  if (primary) {
    primary.textContent =
      os === 'windows' ? 'Download for Windows' :
      os === 'macos' ? 'Download for macOS' :
      'Download for Linux';
  }
})();
