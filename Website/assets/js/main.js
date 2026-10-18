/* Swift Engine Ferox: site behaviour. Progressive enhancement; the page works without it. */
(() => {
  'use strict';

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const finePointer = window.matchMedia('(hover: hover) and (pointer: fine)');
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  /* ---------- Loading screen: hide on window load, or after 2.5 s at most ---------- */
  const loader = $('#loader');
  if (loader) {
    let hidden = false;
    const hideLoader = () => {
      if (hidden) return;
      hidden = true;
      loader.classList.add('is-hidden');
      loader.setAttribute('aria-hidden', 'true');
    };
    if (document.readyState === 'complete') hideLoader();
    else window.addEventListener('load', hideLoader, { once: true });
    setTimeout(hideLoader, 2500);
  }

  /* ---------- Navigation: frosted glass on scroll, accessible mobile menu ---------- */
  const header = $('.site-header');
  const toggle = $('.nav-toggle');
  const menu = $('#nav-menu');

  if (header) {
    const onScroll = () => header.classList.toggle('is-scrolled', window.scrollY > 12);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  if (toggle && menu) {
    const isOpen = () => toggle.getAttribute('aria-expanded') === 'true';

    const setOpen = (open) => {
      toggle.setAttribute('aria-expanded', String(open));
      toggle.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
      menu.classList.toggle('is-open', open);
    };

    toggle.addEventListener('click', () => {
      const open = !isOpen();
      setOpen(open);
      if (open) {
        const first = menu.querySelector('a');
        if (first) first.focus();
      }
    });

    menu.addEventListener('click', (event) => {
      if (event.target.closest('a')) setOpen(false);
    });

    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && isOpen()) {
        setOpen(false);
        toggle.focus();
      }
    });

    // Close the menu when keyboard focus leaves the header or a click lands outside it.
    header.addEventListener('focusout', (event) => {
      if (isOpen() && !header.contains(event.relatedTarget)) setOpen(false);
    });
    document.addEventListener('click', (event) => {
      if (isOpen() && !header.contains(event.target)) setOpen(false);
    });

    // Reset the mobile state when the layout switches to the desktop bar.
    const desktop = window.matchMedia('(min-width: 760px)');
    const onLayoutChange = () => { if (desktop.matches) setOpen(false); };
    if (desktop.addEventListener) desktop.addEventListener('change', onLayoutChange);
    else if (desktop.addListener) desktop.addListener(onLayoutChange);
  }

  /* ---------- Scroll reveal via IntersectionObserver ---------- */
  const reveals = $$('.reveal');
  reveals.forEach((el) => {
    const siblings = el.parentElement
      ? Array.from(el.parentElement.children).filter((c) => c.classList.contains('reveal'))
      : [];
    const index = siblings.indexOf(el);
    if (index > 0) el.style.setProperty('--delay', Math.min(index, 5) * 90 + 'ms');
  });

  if ('IntersectionObserver' in window && !reduceMotion.matches) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.15, rootMargin: '0px 0px -8% 0px' });
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add('is-visible'));
  }

  /* ---------- Hero canvas: drifting ember particle field ---------- */
  const canvas = $('.hero-canvas');
  const ctx = canvas && canvas.getContext ? canvas.getContext('2d') : null;

  if (canvas && ctx) {
    const COLOURS = ['255,179,71', '240,81,56', '139,92,246', '179,157,255'];
    const rand = (min, max) => min + Math.random() * (max - min);
    let width = 0;
    let height = 0;
    let particles = [];
    let frameId = 0;
    let running = false;
    let inView = true;
    let time = 0;
    let lastFrame = 0;

    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      width = rect.width;
      height = rect.height;
      canvas.width = Math.max(1, Math.round(width * dpr));
      canvas.height = Math.max(1, Math.round(height * dpr));
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const count = Math.max(36, Math.min(110, Math.round((width * height) / 16000)));
      particles = Array.from({ length: count }, () => ({
        x: rand(0, width),
        y: rand(0, height),
        r: rand(0.6, 2.2),
        vx: rand(-0.14, 0.14),
        vy: rand(-0.42, -0.1),
        phase: rand(0, Math.PI * 2),
        alpha: rand(0.25, 0.9),
        colour: COLOURS[Math.floor(Math.random() * COLOURS.length)],
      }));
    };

    const step = (dt) => {
      time += dt;
      particles.forEach((p) => {
        p.x += (p.vx + Math.sin(p.phase + time * 0.01) * 0.12) * dt;
        p.y += p.vy * dt;
        if (p.y < -6) { p.y = height + 6; p.x = rand(0, width); }
        if (p.x < -6) p.x = width + 6;
        if (p.x > width + 6) p.x = -6;
      });
    };

    const draw = () => {
      ctx.clearRect(0, 0, width, height);
      particles.forEach((p) => {
        ctx.beginPath();
        ctx.fillStyle = 'rgba(' + p.colour + ',' + p.alpha.toFixed(2) + ')';
        ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
        ctx.fill();
      });
    };

    const loop = (now) => {
      if (!running) return;
      const dt = Math.min(2, (now - (lastFrame || now)) / 16.67);
      lastFrame = now;
      step(dt);
      draw();
      frameId = requestAnimationFrame(loop);
    };

    const start = () => {
      if (running || reduceMotion.matches || document.hidden || !inView) return;
      running = true;
      lastFrame = 0;
      frameId = requestAnimationFrame(loop);
    };

    const stop = () => {
      running = false;
      cancelAnimationFrame(frameId);
    };

    resize();
    draw();
    start();

    document.addEventListener('visibilitychange', () => {
      if (document.hidden) stop();
      else start();
    });

    if ('IntersectionObserver' in window) {
      new IntersectionObserver((entries) => {
        inView = entries[0].isIntersecting;
        if (inView) start();
        else stop();
      }).observe(canvas);
    }

    let resizeTimer = 0;
    window.addEventListener('resize', () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => {
        resize();
        if (!running) draw();
      }, 150);
    });

    const onMotionPreference = () => {
      if (reduceMotion.matches) { stop(); draw(); } else { start(); }
    };
    if (reduceMotion.addEventListener) reduceMotion.addEventListener('change', onMotionPreference);
    else if (reduceMotion.addListener) reduceMotion.addListener(onMotionPreference);
  }

  /* ---------- Feature cards: pointer tilt and glow (fine pointers only) ---------- */
  if (finePointer.matches && !reduceMotion.matches) {
    $$('.card').forEach((card) => {
      card.addEventListener('pointermove', (event) => {
        const rect = card.getBoundingClientRect();
        const px = (event.clientX - rect.left) / rect.width;
        const py = (event.clientY - rect.top) / rect.height;
        card.style.setProperty('--ry', ((px - 0.5) * 10).toFixed(2) + 'deg');
        card.style.setProperty('--rx', ((0.5 - py) * 8).toFixed(2) + 'deg');
        card.style.setProperty('--mx', (px * 100).toFixed(1) + '%');
        card.style.setProperty('--my', (py * 100).toFixed(1) + '%');
      });
      card.addEventListener('pointerleave', () => {
        card.style.removeProperty('--rx');
        card.style.removeProperty('--ry');
      });
    });
  }

  /* ---------- Copy quick-start commands ---------- */
  const copyButton = $('#copy-btn');
  const codeBlock = $('#qs-code');
  const status = $('#copy-status');

  const copyText = async (text) => {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (error) {
      // Fall through to the selection-based fallback below.
    }
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.top = '0';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (error) { ok = false; }
    area.remove();
    return ok;
  };

  if (copyButton && codeBlock) {
    let resetTimer = 0;
    copyButton.addEventListener('click', async () => {
      const ok = await copyText(codeBlock.textContent.trim());
      copyButton.textContent = ok ? 'Copied' : 'Copy failed';
      copyButton.classList.toggle('is-copied', ok);
      copyButton.classList.toggle('is-failed', !ok);
      if (status) {
        status.textContent = ok
          ? 'Quick-start commands copied to the clipboard.'
          : 'Copying failed. Select the commands and copy them by hand.';
      }
      clearTimeout(resetTimer);
      resetTimer = setTimeout(() => {
        copyButton.textContent = 'Copy';
        copyButton.classList.remove('is-copied', 'is-failed');
        if (status) status.textContent = '';
      }, 2200);
    });
  }
})();
