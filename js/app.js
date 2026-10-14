// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  app.js
//  devgentic-site
//
//  Binds the page to site.config.js, drives the interactive Voice Orb, and runs the tabs, FAQ and
//  copy buttons.
//
//  ⚠️ THE PAGE DEFAULTS TO "PRE-RELEASE" IN MARKUP (`<html data-release="pending">`). This script
//  only ever flips it to "published" when the config says so, so a script failure can never
//  expose a download link that does not exist.
//

import { SITE_CONFIG } from '../site.config.js';

document.addEventListener('DOMContentLoaded', () => {
  hydrateSiteConfig();
  initVoiceOrb();
  initShowcaseTabs();
  initCopyButtons();
  initFaqAccordion();
});

// MARK: - Hydrate Site Config
function hydrateSiteConfig() {
  const { release, links } = SITE_CONFIG;
  const published = release.published === true && Boolean(release.version);
  document.documentElement.dataset.release = published ? 'published' : 'pending';

  document.querySelectorAll('[data-bind="version"]').forEach(el => { el.textContent = published ? `v${release.version}` : ''; });
  document.querySelectorAll('[data-bind="repo"]').forEach(el => { el.href = links.repo; });
  document.querySelectorAll('[data-bind="releases"]').forEach(el => { el.href = links.releases; });
  document.querySelectorAll('[data-bind="download"]').forEach(el => { el.href = links.latestDmg; });
  document.querySelectorAll('[data-bind="issues"]').forEach(el => { el.href = links.issues; });
  document.querySelectorAll('[data-bind="sponsor"]').forEach(el => { el.href = links.sponsor; });
  document.querySelectorAll('[data-bind="author"]').forEach(el => { el.href = links.author; });
  document.querySelectorAll('[data-bind="linkedin"]').forEach(el => { el.href = links.linkedin; });

  const sha = document.getElementById('shaValue');
  const shaRow = document.getElementById('shaRow');
  if (sha && shaRow) {
    if (published && release.sha256) { sha.textContent = release.sha256; shaRow.hidden = false; }
    else { shaRow.hidden = true; }
  }
}

// MARK: - Interactive Voice Orb Controller
function initVoiceOrb() {
  const orb = document.getElementById('voiceOrb');
  const stage = document.getElementById('orbStage');
  const specular = document.querySelector('.orb-specular');
  const statusPill = document.getElementById('orbStatusPill');
  const statusLabel = document.getElementById('orbStatusText');
  const statusDot = document.getElementById('orbStatusDot');

  if (!orb || !stage) return;

  const states = [
    { class: '', label: 'STANDBY', dot: 'var(--cyan)' },
    { class: 'listening', label: 'LISTENING', dot: '#38bdf8' },
    { class: 'thinking', label: 'THINKING', dot: 'var(--amber)' },
    { class: 'speaking', label: 'SPEAKING', dot: '#f472b6' }
  ];

  let stateIndex = 0;

  function setVoiceState(index) {
    stateIndex = index;
    const st = states[stateIndex];

    // Reset state classes on stage
    stage.classList.remove('listening', 'thinking', 'speaking');
    if (st.class) {
      stage.classList.add(st.class);
    }

    if (statusLabel) statusLabel.textContent = st.label;
    if (statusDot) {
      statusDot.style.background = st.dot;
      statusDot.style.boxShadow = `0 0 8px ${st.dot}`;
    }
  }

  // Click on Orb or Status Pill to cycle through states
  function cycleState() {
    // Subtle tactile spring bounce
    orb.style.transform = 'scale(0.92)';
    setTimeout(() => {
      orb.style.transform = '';
    }, 150);

    const nextIndex = (stateIndex + 1) % states.length;
    setVoiceState(nextIndex);
  }

  orb.addEventListener('click', cycleState);
  if (statusPill) statusPill.addEventListener('click', cycleState);

  // Keyboard accessibility
  orb.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      cycleState();
    }
  });

  // 3D Mouse Parallax & Specular Highlight Tracking
  let targetTiltX = 0;
  let targetTiltY = 0;
  let currentTiltX = 0;
  let currentTiltY = 0;
  let isHovering = false;

  stage.addEventListener('mousemove', (e) => {
    isHovering = true;
    const rect = orb.getBoundingClientRect();
    const orbCenterX = rect.left + rect.width / 2;
    const orbCenterY = rect.top + rect.height / 2;

    const deltaX = (e.clientX - orbCenterX) / (rect.width / 2);
    const deltaY = (e.clientY - orbCenterY) / (rect.height / 2);

    targetTiltX = -Math.max(-1, Math.min(1, deltaY)) * 14;
    targetTiltY = Math.max(-1, Math.min(1, deltaX)) * 14;
  });

  stage.addEventListener('mouseleave', () => {
    isHovering = false;
    targetTiltX = 0;
    targetTiltY = 0;
  });

  function updatePhysics() {
    currentTiltX += (targetTiltX - currentTiltX) * 0.1;
    currentTiltY += (targetTiltY - currentTiltY) * 0.1;

    if (isHovering) {
      orb.style.transform = `perspective(800px) rotateX(${currentTiltX.toFixed(2)}deg) rotateY(${currentTiltY.toFixed(2)}deg) scale(1.05)`;
      if (specular) {
        const specOffsetX = (currentTiltY * 1.5).toFixed(1);
        const specOffsetY = (-currentTiltX * 1.5).toFixed(1);
        specular.style.transform = `rotate(-14deg) translate(${specOffsetX}px, ${specOffsetY}px)`;
      }
    } else {
      orb.style.transform = '';
      if (specular) specular.style.transform = 'rotate(-14deg)';
    }

    requestAnimationFrame(updatePhysics);
  }

  requestAnimationFrame(updatePhysics);
}

// MARK: - Showcase Tab Switching
function initShowcaseTabs() {
  const tabs = document.querySelectorAll('.tab-btn');
  const panels = document.querySelectorAll('.tab-panel');

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      const targetId = tab.getAttribute('data-tab');

      tabs.forEach(t => t.classList.remove('active'));
      panels.forEach(p => p.classList.remove('active'));

      tab.classList.add('active');
      const targetPanel = document.getElementById(`panel-${targetId}`);
      if (targetPanel) {
        targetPanel.classList.add('active');
      }
    });
  });
}

// MARK: - Copy Buttons
function initCopyButtons() {
  document.querySelectorAll('.copy-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const text = btn.getAttribute('data-copy');
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
        const original = btn.textContent;
        btn.textContent = 'Copied';
        btn.classList.add('copied');
        setTimeout(() => { btn.textContent = original; btn.classList.remove('copied'); }, 2000);
      } catch (err) {
        console.error('Copy failed', err);
      }
    });
  });
}

// MARK: - FAQ Accordion
function initFaqAccordion() {
  const items = document.querySelectorAll('.faq-item');

  items.forEach(item => {
    const question = item.querySelector('.faq-question');
    question.addEventListener('click', () => {
      const isOpen = item.classList.contains('open');
      items.forEach(i => i.classList.remove('open'));
      if (!isOpen) {
        item.classList.add('open');
      }
    });
  });
}
