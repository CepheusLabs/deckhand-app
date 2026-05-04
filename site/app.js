// Deckhand landing page — download manifest consumer.
//
// On page load we fetch the release manifest produced by
// scripts/build_manifest.py (attached as a GitHub release asset named
// `manifest.json`). The manifest gives us the real filename, sha256
// digest, and detached-signature URL for every platform's installer.
//
// This replaces the previous approach of hitting the unauthenticated
// GitHub REST API on every page load (rate-limited) and scraping
// sha256 digests out of release-notes text (brittle).
//
// Design goals:
//   1. No build tooling. Vanilla JS, one file, no bundler.
//   2. Graceful degradation. If the manifest fetch fails (network, 404,
//      malformed JSON), we leave the existing hard-coded cards in place
//      with a quiet notice pointing to the releases page.
//   3. sessionStorage cache so that an in-page reload is instant and
//      doesn't re-hit GitHub.
//   4. No eval, no innerHTML of untrusted content — we only set text
//      and href/src via properties, and we validate url schemes before
//      writing them into the DOM.
(function () {
  'use strict';

  const MANIFEST_URL =
    'https://github.com/CepheusLabs/deckhand/releases/latest/download/manifest.json';
  const RELEASES_BASE =
    'https://github.com/CepheusLabs/deckhand/releases/latest/download/';
  const RELEASES_PAGE =
    'https://github.com/CepheusLabs/deckhand/releases/latest';
  const CACHE_KEY = 'deckhand.manifest.v1';
  // 10 minutes is short enough that a fresh release propagates fast
  // but long enough to save the network round-trip on tab reopens.
  const CACHE_TTL_MS = 10 * 60 * 1000;

  // ---- Platform detection --------------------------------------------------

  function detectPlatform() {
    const ua = navigator.userAgent || '';
    const platform = navigator.platform || '';
    if (/Windows/i.test(ua) || /Win/i.test(platform)) return 'windows';
    if (/Mac/i.test(platform) || /Macintosh/i.test(ua)) return 'macos';
    if (/Linux/i.test(platform) || /X11/i.test(platform)) return 'linux';
    return null;
  }

  // ---- Manifest fetch + cache ---------------------------------------------

  function readCache() {
    try {
      const raw = sessionStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      const entry = JSON.parse(raw);
      if (!entry || typeof entry.ts !== 'number' || !entry.manifest) return null;
      if (Date.now() - entry.ts > CACHE_TTL_MS) return null;
      return entry.manifest;
    } catch (_) {
      return null;
    }
  }

  function writeCache(manifest) {
    try {
      sessionStorage.setItem(
        CACHE_KEY,
        JSON.stringify({ ts: Date.now(), manifest })
      );
    } catch (_) {
      // sessionStorage can throw in private mode or when full. Non-fatal.
    }
  }

  async function fetchManifest() {
    const cached = readCache();
    if (cached) return cached;
    const res = await fetch(MANIFEST_URL, {
      // 'follow' so GitHub's redirect to the asset blob resolves.
      redirect: 'follow',
      // We want a fresh copy when the sessionStorage cache has expired.
      cache: 'no-cache',
    });
    if (!res.ok) throw new Error('manifest HTTP ' + res.status);
    const manifest = await res.json();
    if (!manifest || manifest.schema !== 'deckhand.release/1') {
      throw new Error('unexpected manifest schema: ' + (manifest && manifest.schema));
    }
    if (!Array.isArray(manifest.artifacts)) {
      throw new Error('manifest.artifacts is not an array');
    }
    writeCache(manifest);
    return manifest;
  }

  // ---- Rendering ----------------------------------------------------------

  // resolveURL turns a manifest entry's url/filename into an absolute
  // URL. Manifests built without --download-base store relative paths;
  // since release assets are uploaded flat, we join against the known
  // releases/latest/download/ prefix using the filename field.
  function resolveURL(entry) {
    if (!entry) return null;
    // Absolute URL in the manifest? Trust only http(s).
    if (entry.url && /^https?:\/\//i.test(entry.url)) return entry.url;
    if (entry.filename) return RELEASES_BASE + encodeURIComponent(entry.filename);
    return null;
  }

  function resolveSignatureURL(entry) {
    if (!entry) return null;
    if (entry.signature_url && /^https?:\/\//i.test(entry.signature_url)) {
      return entry.signature_url;
    }
    if (entry.filename) {
      return RELEASES_BASE + encodeURIComponent(entry.filename + '.asc');
    }
    return null;
  }

  // pickArtifact chooses the best entry for a given platform. We prefer
  // architectures in this order: arm64 on macOS (Apple Silicon is the
  // majority), x64 everywhere else, then universal as a fallback.
  function pickArtifact(artifacts, os) {
    const forOS = artifacts.filter(function (a) { return a.platform === os; });
    if (!forOS.length) return null;
    const preferred = os === 'macos'
      ? ['arm64', 'x64', 'universal']
      : ['x64', 'arm64', 'universal'];
    for (let i = 0; i < preferred.length; i++) {
      const hit = forOS.find(function (a) { return a.arch === preferred[i]; });
      if (hit) return hit;
    }
    return forOS[0];
  }

  function formatSize(bytes) {
    if (typeof bytes !== 'number' || bytes <= 0) return '';
    const mb = bytes / (1024 * 1024);
    if (mb < 1) return (bytes / 1024).toFixed(0) + ' KB';
    if (mb < 1024) return mb.toFixed(1) + ' MB';
    return (mb / 1024).toFixed(2) + ' GB';
  }

  function shortHash(hex) {
    if (typeof hex !== 'string' || hex.length < 12) return hex || '';
    return hex.slice(0, 12) + '…';
  }

  // renderCard populates a .download-card in place. We never use
  // innerHTML — values go through textContent / setAttribute to keep
  // the flow safe even if a malicious manifest ever lands on our CDN.
  function renderCard(card, entry, manifest) {
    const url = resolveURL(entry);
    const sigURL = resolveSignatureURL(entry);

    if (url) card.setAttribute('href', url);

    const fileSpan = card.querySelector('.dl-file');
    if (fileSpan && entry.filename) {
      fileSpan.textContent = entry.filename;
    }

    // Size (optional).
    let meta = card.querySelector('.dl-meta');
    if (!meta) {
      meta = document.createElement('span');
      meta.className = 'dl-meta';
      card.appendChild(meta);
    }
    const parts = [];
    if (manifest.version) parts.push('v' + manifest.version);
    if (entry.arch) parts.push(entry.arch);
    const size = formatSize(entry.size);
    if (size) parts.push(size);
    meta.textContent = parts.join(' · ');

    // sha256 display.
    let sha = card.querySelector('.dl-sha');
    if (!sha) {
      sha = document.createElement('span');
      sha.className = 'dl-sha';
      card.appendChild(sha);
    }
    if (entry.sha256) {
      sha.textContent = 'sha256: ' + shortHash(entry.sha256);
      sha.setAttribute('title', entry.sha256);
    } else {
      sha.textContent = '';
      sha.removeAttribute('title');
    }

    // Signature link (opens SHA256SUMS.asc in a new tab). We put it on
    // the .dl-verify span rather than making the whole card a verify
    // link — the primary action is download.
    let verify = card.querySelector('.dl-verify');
    if (!verify) {
      verify = document.createElement('a');
      verify.className = 'dl-verify';
      verify.setAttribute('rel', 'noopener');
      verify.setAttribute('target', '_blank');
      // Stop the click from bubbling to the card's navigation (the
      // whole card is an <a>).
      verify.addEventListener('click', function (ev) { ev.stopPropagation(); });
      card.appendChild(verify);
    }
    if (sigURL) {
      verify.textContent = 'signature (.asc)';
      verify.setAttribute('href', sigURL);
      verify.style.display = '';
    } else {
      verify.textContent = '';
      verify.removeAttribute('href');
      verify.style.display = 'none';
    }
  }

  function renderAll(manifest) {
    const cards = document.querySelectorAll('.download-card[data-os]');
    let rendered = 0;
    cards.forEach(function (card) {
      const os = card.getAttribute('data-os');
      const entry = pickArtifact(manifest.artifacts, os);
      if (!entry) {
        // No artifact for this platform in the current release — leave
        // the hard-coded fallback href (releases/latest) in place and
        // note it.
        const file = card.querySelector('.dl-file');
        if (file) file.textContent = 'not available in this release';
        return;
      }
      renderCard(card, entry, manifest);
      rendered++;
    });

    if (rendered > 0) {
      showChecksumNote(manifest);
    }
  }

  // showChecksumNote adds a single line under the download grid telling
  // users where to get the signed SHA256SUMS file for cross-verification.
  function showChecksumNote(manifest) {
    const container = document.getElementById('download-verify-note');
    if (!container) return;
    const sumsURL = RELEASES_BASE + encodeURIComponent(manifest.sha256sums || 'SHA256SUMS');
    const sigURL = RELEASES_BASE + encodeURIComponent(manifest.sha256sums_signature || 'SHA256SUMS.asc');

    // Clear prior children (idempotent if renderAll runs twice).
    while (container.firstChild) container.removeChild(container.firstChild);

    const prefix = document.createTextNode('Verify any download against ');
    const a1 = document.createElement('a');
    a1.href = sumsURL;
    a1.textContent = 'SHA256SUMS';
    a1.setAttribute('rel', 'noopener');
    const mid = document.createTextNode(' (signed: ');
    const a2 = document.createElement('a');
    a2.href = sigURL;
    a2.textContent = 'SHA256SUMS.asc';
    a2.setAttribute('rel', 'noopener');
    const suffix = document.createTextNode(').');

    container.appendChild(prefix);
    container.appendChild(a1);
    container.appendChild(mid);
    container.appendChild(a2);
    container.appendChild(suffix);
  }

  function showFallback(reason) {
    // We couldn't read the manifest — leave the hard-coded cards alone
    // and append a small notice so the user still has a path forward.
    const container = document.getElementById('download-verify-note');
    if (!container) return;
    while (container.firstChild) container.removeChild(container.firstChild);
    const txt = document.createTextNode(
      'Live download metadata unavailable — see '
    );
    const a = document.createElement('a');
    a.href = RELEASES_PAGE;
    a.textContent = 'the releases page';
    a.setAttribute('rel', 'noopener');
    const dot = document.createTextNode(' for the latest signed installers.');
    container.appendChild(txt);
    container.appendChild(a);
    container.appendChild(dot);
    if (reason && window.console) {
      // Helpful for bug reports, not shown to users.
      console.info('[deckhand] manifest fallback:', reason);
    }
  }

  // ---- Platform highlight (kept from previous version) --------------------

  function highlightPlatform(os) {
    if (!os) return;
    const target = document.querySelector('.download-card[data-os="' + os + '"]');
    if (!target) return;
    target.classList.add('is-detected');

    const primary = document.querySelector('.btn-primary');
    if (primary) {
      primary.textContent =
        os === 'windows' ? 'Download for Windows' :
        os === 'macos' ? 'Download for macOS' :
        'Download for Linux';
    }
  }

  // ---- Main ---------------------------------------------------------------

  function init() {
    const os = detectPlatform();
    highlightPlatform(os);

    fetchManifest()
      .then(function (manifest) { renderAll(manifest); })
      .catch(function (err) { showFallback(err && err.message); });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
