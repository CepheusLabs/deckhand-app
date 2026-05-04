// Shared chrome + interactivity for Deckhand wiki
(function () {
  'use strict';

  // ---------- Topnav active state ----------
  const path = (location.pathname.split('/').pop() || 'index.html').toLowerCase();
  document.querySelectorAll('[data-nav]').forEach(a => {
    if (a.dataset.nav.toLowerCase() === path) a.classList.add('is-active');
  });

  // ---------- Sidebar active state ----------
  document.querySelectorAll('.sidebar a[data-page]').forEach(a => {
    if (a.dataset.page.toLowerCase() === path) a.classList.add('is-active');
  });

  // ---------- Build TOC from h2/h3 in .wiki-content ----------
  const tocList = document.querySelector('.toc ul');
  const content = document.querySelector('.wiki-content');
  if (tocList && content) {
    const heads = content.querySelectorAll('h2[id], h3[id]');
    heads.forEach(h => {
      const li = document.createElement('li');
      li.className = 'lvl-' + (h.tagName === 'H2' ? '2' : '3');
      const a = document.createElement('a');
      a.href = '#' + h.id;
      a.textContent = h.textContent;
      li.appendChild(a);
      tocList.appendChild(li);
    });
    // scroll spy
    const links = tocList.querySelectorAll('a');
    const spy = new IntersectionObserver((entries) => {
      entries.forEach(e => {
        if (e.isIntersecting) {
          links.forEach(l => l.classList.toggle('is-active', l.getAttribute('href') === '#' + e.target.id));
        }
      });
    }, { rootMargin: '-80px 0px -70% 0px' });
    heads.forEach(h => spy.observe(h));
  }

  // ---------- Search modal ----------
  const modal = document.getElementById('search-modal');
  const searchTrigger = document.querySelector('[data-search]');
  function openSearch() { modal && modal.classList.add('is-open'); setTimeout(() => modal?.querySelector('input')?.focus(), 30); }
  function closeSearch() { modal && modal.classList.remove('is-open'); }
  searchTrigger && searchTrigger.addEventListener('click', openSearch);
  modal && modal.addEventListener('click', (e) => { if (e.target === modal) closeSearch(); });
  document.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); openSearch(); }
    if (e.key === 'Escape') closeSearch();
  });

  // ---------- OS detect on landing ----------
  const ua = navigator.userAgent;
  let os = 'linux';
  if (/Mac/i.test(ua)) os = 'macos';
  else if (/Win/i.test(ua)) os = 'windows';
  document.querySelectorAll('[data-os-card="' + os + '"]').forEach(el => el.classList.add('is-detected'));
  const kbd = document.querySelector('.kbd-shortcut');
  if (kbd) kbd.textContent = os === 'macos' ? '⌘K' : 'Ctrl K';
})();
